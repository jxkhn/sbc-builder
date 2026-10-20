# shellcheck shell=bash
# Step 2 (optional): harvest Armbian's kernel work as plain source inputs.
#
# Copies from armbian/build - nothing at runtime, only build inputs:
#   patch/kernel/archive/<family>-<X.Y>/*.patch, dt/, overlay/  -> userpatches/armbian/kernel/<family>-<X.Y>/
#   config/kernel/linux-<family>-<branch>.config                -> userpatches/armbian/kernel/
# and writes an inventory that sorts every patch into board / generic / other-board,
# plus a suggested exclude list for the patches that only touch other boards.
#
# ARMBIAN_REF=auto finds the newest Armbian commit that still carries patches for
# your kernel series (Armbian drops old series quickly; 7.2 was replaced by 7.3).

ARMBIAN_REPO=${ARMBIAN_REPO:-https://github.com/armbian/build.git}

armbian_series() {
	if [[ $KERNEL_SOURCE == mainline ]]; then
		kernel_majmin "$(resolve_kernel_version)"
	else
		die "Armbian import only makes sense with KERNEL_SOURCE=mainline"
	fi
}
armbian_patch_dir() { echo "$SRC/userpatches/armbian/kernel/${ARMBIAN_FAMILY}-$1"; }
armbian_kernel_config() { echo "$SRC/userpatches/armbian/kernel/linux-${ARMBIAN_FAMILY}-${ARMBIAN_KERNEL_BRANCH}.config"; }

armbian_import() {
	[[ -n $ARMBIAN_FAMILY ]] || die "Board $BOARD has no ARMBIAN_FAMILY"
	local series repo ref
	series=$(armbian_series)
	repo=${ARMBIAN_DIR:-$CACHE/armbian-build}
	info "Armbian import: family $ARMBIAN_FAMILY, kernel series $series, config branch $ARMBIAN_KERNEL_BRANCH"

	if [[ ! -d $repo/.git ]]; then
		[[ -z $ARMBIAN_DIR ]] || die "ARMBIAN_DIR=$ARMBIAN_DIR is not a git checkout"
		step "Cloning armbian/build (history only, files on demand)"
		as_user git clone -q --filter=blob:none --no-checkout "$ARMBIAN_REPO" "$repo"
	elif [[ ${ARMBIAN_UPDATE:-yes} == yes ]]; then
		as_user git -C "$repo" fetch -q origin || warn "git fetch failed - using what is cached"
	fi

	local pdir="patch/kernel/archive/${ARMBIAN_FAMILY}-${series}"
	local head
	head=$(as_user git -C "$repo" rev-parse --verify -q origin/HEAD || as_user git -C "$repo" rev-parse HEAD)
	if [[ $ARMBIAN_REF == auto ]]; then
		if as_user git -C "$repo" cat-file -e "$head:$pdir" 2>/dev/null; then
			ref=$head
		else
			local gone
			gone=$(as_user git -C "$repo" log -1 --format=%H --diff-filter=D "$head" -- "$pdir") || true
			[[ -n $gone ]] || die "Armbian has never had $pdir. Available now: $(armbian_available "$repo" "$head")"
			ref=$(as_user git -C "$repo" rev-parse "$gone^")
			step "Series $series was dropped in $(as_user git -C "$repo" log -1 --format='%h (%cs) "%s"' "$gone")"
		fi
	else
		ref=$(as_user git -C "$repo" rev-parse --verify -q "$ARMBIAN_REF^{commit}" ||
			as_user git -C "$repo" rev-parse --verify -q "origin/$ARMBIAN_REF^{commit}") ||
			die "Unknown ARMBIAN_REF '$ARMBIAN_REF'"
		as_user git -C "$repo" cat-file -e "$ref:$pdir" 2>/dev/null ||
			die "$pdir does not exist at $ARMBIAN_REF. Available there: $(armbian_available "$repo" "$ref"). Try ARMBIAN_REF=auto"
	fi
	step "Using armbian/build $(as_user git -C "$repo" log -1 --format='%h (%cs) %s' "$ref")"

	local base="$SRC/userpatches/armbian" dest
	dest=$(armbian_patch_dir "$series")
	as_user mkdir -p "$base/kernel"
	rm -rf "$dest"
	as_user mkdir -p "$dest"
	as_user git -C "$repo" archive "$ref" "$pdir" | as_user tar -x -C "$dest" --strip-components=4

	local cfg="config/kernel/linux-${ARMBIAN_FAMILY}-${ARMBIAN_KERNEL_BRANCH}.config"
	if as_user git -C "$repo" cat-file -e "$ref:$cfg" 2>/dev/null; then
		as_user git -C "$repo" show "$ref:$cfg" | as_user tee "$(armbian_kernel_config)" >/dev/null
		step "Kernel config: ${cfg##*/}"
		local cver
		cver=$(sed -n 's/^# Linux.* \([0-9][0-9.]*\) Kernel Configuration/\1/p' "$(armbian_kernel_config)" | head -n1)
		[[ -n $cver && $(kernel_majmin "$cver") != "$series" ]] &&
			warn "That config was made for $cver, you build $series - olddefconfig will fill the gaps"
	else
		warn "$cfg not found at that commit"
	fi

	armbian_inventory "$dest" "$series"

	cat >"$base/IMPORTED-${ARMBIAN_FAMILY}-${series}.txt" <<EOF
source:   $ARMBIAN_REPO
commit:   $(as_user git -C "$repo" log -1 --format='%H (%cs) %s' "$ref")
imported: $(date -Is)
patches:  ${dest#"$SRC"/}  ($(find "$dest" -maxdepth 1 -name '*.patch' | wc -l) patches, $(find "$dest/dt" -name '*.dts' 2>/dev/null | wc -l) extra DTS, $(find "$dest/overlay" -name '*.dtso' 2>/dev/null | wc -l) overlays)
config:   $cfg
EOF
	own "$base"
	info "Imported into ${base#"$SRC"/}. Review inventory-${ARMBIAN_FAMILY}-${series}.tsv, then set KERNEL_ARMBIAN_PATCHES=yes (and KERNEL_CONFIG=armbian for their config)."
}

armbian_available() {
	as_user git -C "$1" ls-tree -d --name-only "$2" patch/kernel/archive/ |
		sed -n "s#.*/\(${ARMBIAN_FAMILY}-[0-9.]*\)\$#\1#p" | tr '\n' ' '
}

# Classify every patch by the files it touches:
#   board        touches your board's DTS or your SoC's dtsi        -> keep
#   soc          code (drivers, clk, ...) mentioning your SoC         -> keep
#   generic      other code changes - read before excluding
#   other-board  only device trees, none of them yours               -> suggested exclude
armbian_inventory() {
	local dest=$1 series=$2 base="$SRC/userpatches/armbian"
	local inv="$base/inventory-${ARMBIAN_FAMILY}-${series}.tsv" sug="$base/exclude-suggested-${BOARD}.list"
	local dre=${PATCH_DTS_REGEX:-$BOARD} sre=${PATCH_SOC_REGEX:-$BOARD}
	local p name subj files dtsfiles hint nb=0 ns=0 ng=0 no=0
	{
		echo "# Patches/DTS for other boards only - not $BOARD_NAME."
		echo "# Review, then copy the lines you agree with to userpatches/kernel/exclude.list"
	} >"$sug"
	printf 'class\tpatch\tsubject\tfiles\n' >"$inv"
	while IFS= read -r p; do
		name=${p##*/}
		subj=$(grep -m1 '^Subject:' "$p" | sed 's/^Subject: *//; s/^\[[^]]*\] *//' || true)
		files=$(grep -E '^\+\+\+ b/' "$p" | sed 's#^+++ b/##' | sort -u || true)
		dtsfiles=$(grep -E '^arch/arm64/boot/dts/' <<<"$files" || true)
		if [[ -n $dtsfiles ]] && grep -qE "$dre" <<<"$dtsfiles"; then
			hint=board; nb=$((nb + 1))
		elif [[ -n $files ]] && ! grep -qvE '^arch/arm64/boot/dts/|^Documentation/devicetree/' <<<"$files"; then
			hint=other-board; no=$((no + 1))
			echo "$name" >>"$sug"
		elif grep -qiE "$sre" <<<"$name"$'\n'"$subj"$'\n'"$files"; then
			hint=soc; ns=$((ns + 1))
		else
			hint=generic; ng=$((ng + 1))
		fi
		printf '%s\t%s\t%s\t%s\n' "$hint" "$name" "$subj" "$(tr '\n' ' ' <<<"$files")" >>"$inv"
	done < <(list_patches "$dest")
	echo "# Extra board DTS files (dt/) that are not yours:" >>"$sug"
	for p in "$dest"/dt/*.dts; do
		[[ -f $p ]] || continue
		grep -qE "$dre" <<<"/${p##*/}" || echo "${p##*/}" >>"$sug"
	done
	own "$inv" "$sug"
	step "Inventory: $nb board, $ns SoC, $ng generic, $no other-board-only -> ${sug#"$SRC"/}"
}
