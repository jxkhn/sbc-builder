# shellcheck shell=bash
# Kernel stage: kernel.org tarball -> (patches) -> config -> `make bindeb-pkg`.
# Output: output/debs/kernel-<family>/ with linux-image/headers/libc-dev + a
# "<prefix>-linux-image-<family>" metapackage that always points at the newest build.

KERNEL_ORG=${KERNEL_ORG:-https://cdn.kernel.org/pub/linux/kernel}

resolve_kernel_version() {
	case $KERNEL_VERSION in
		stable | latest | longterm)
			local json
			json=$(curl -fsSL https://www.kernel.org/releases.json) ||
				die "Cannot reach kernel.org to resolve KERNEL_VERSION=$KERNEL_VERSION (set an explicit X.Y.Z)"
			python3 -c '
import json, sys
d = json.load(sys.stdin)
if sys.argv[1] == "longterm":
    print(next(r["version"] for r in d["releases"] if r["moniker"] == "longterm"))
else:
    print(d["latest_stable"]["version"])
' "$KERNEL_VERSION" <<<"$json"
			;;
		*)
			[[ $KERNEL_VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Invalid KERNEL_VERSION '$KERNEL_VERSION'"
			echo "$KERNEL_VERSION"
			;;
	esac
}

kernel_majmin() { cut -d. -f1-2 <<<"$1"; }

fetch_kernel() {
	local ver=$1 major=${1%%.*}
	local dir="$CACHE/kernel" url="$KERNEL_ORG/v${major}.x"
	local tb="$dir/linux-$ver.tar.xz" sums want
	as_user mkdir -p "$dir"
	if [[ ! -s $tb ]]; then
		step "Downloading linux-$ver.tar.xz"
		as_user curl -fL --retry 3 -o "$tb.part" "$url/linux-$ver.tar.xz" >&2
		as_user mv "$tb.part" "$tb"
	fi
	if sums=$(curl -fsSL "$url/sha256sums.asc"); then
		want=$(awk -v f="linux-$ver.tar.xz" '$2 == f {print $1}' <<<"$sums")
		if [[ -z $want ]]; then
			warn "kernel.org lists no checksum for linux-$ver.tar.xz - not verified"
		elif [[ $(sha256sum "$tb" | cut -d' ' -f1) != "$want" ]]; then
			rm -f "$tb"
			die "Checksum mismatch for linux-$ver.tar.xz (deleted - re-run to download again)"
		else
			step "sha256 verified against kernel.org"
		fi
	else
		warn "Could not fetch sha256sums.asc - tarball not verified"
	fi
	echo "$tb"
}

kernel_fragments() {
	local f
	for f in "$SRC/config/kernel/fragments/common.config" \
		"$SRC/config/kernel/fragments/net-server.config" \
		"$SRC/config/kernel/fragments/$KERNEL_FAMILY.config" \
		"$SRC/userpatches/kernel/$KERNEL_FAMILY.fragment"; do
		[[ -f $f ]] && echo "$f"
	done
	return 0
}

# Patch directories in application order. Armbian first, your own last.
kernel_patch_dirs() {
	local majmin=$1 d
	if [[ $KERNEL_ARMBIAN_PATCHES == yes ]]; then
		d=$(armbian_patch_dir "$majmin")
		[[ -d $d ]] || die "No imported Armbian patches for ${ARMBIAN_FAMILY:-?}-$majmin ($d). Run: ./build.sh armbian-import CONFIG=..."
		echo "$d"
	fi
	# builder-shipped fixes (patch/kernel/), then yours (userpatches/kernel/)
	for d in "$SRC/patch/kernel/$KERNEL_FAMILY" "$SRC/patch/kernel/$KERNEL_FAMILY-$majmin" \
		"$SRC/userpatches/kernel/$KERNEL_FAMILY" "$SRC/userpatches/kernel/$KERNEL_FAMILY-$majmin"; do
		[[ -d $d ]] && echo "$d"
	done
	return 0
}

kernel_base_config() {
	case $KERNEL_CONFIG in
		defconfig) echo "" ;;
		armbian)
			local f
			f=$(armbian_kernel_config)
			[[ -f $f ]] || die "No imported Armbian kernel config ($f). Run: ./build.sh armbian-import"
			echo "$f"
			;;
		file)
			[[ -f $KERNEL_CONFIG_FILE ]] || die "KERNEL_CONFIG_FILE not found: '$KERNEL_CONFIG_FILE'"
			echo "$KERNEL_CONFIG_FILE"
			;;
	esac
}

patch_excluded() {
	local name=$1 list=$2 pat
	[[ -f $list ]] || return 1
	while IFS= read -r pat; do
		pat=${pat%%#*}
		pat="${pat#"${pat%%[![:space:]]*}"}"
		pat="${pat%"${pat##*[![:space:]]}"}"
		[[ -n $pat ]] || continue
		# shellcheck disable=SC2053
		[[ $name == $pat ]] && return 0
	done <"$list"
	return 1
}

# Top-level *.patch files, sorted (Armbian's order); series.conf is honoured if present.
list_patches() {
	local d=$1 line
	if [[ -f $d/series.conf ]]; then
		while IFS= read -r line; do
			line=${line%%#*}
			line="${line#"${line%%[![:space:]]*}"}"
			line="${line%"${line##*[![:space:]]}"}"
			[[ -z $line || $line == -* ]] && continue
			[[ -f $d/$line ]] && echo "$d/$line"
		done <"$d/series.conf"
	else
		find "$d" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort
	fi
	return 0
}

kernel_patch() {
	local tree=$1
	shift
	(($#)) || return 0
	local report="$WORK/kernel/patch-report-$BOARD.txt" excl="$SRC/userpatches/kernel/exclude.list"
	local d p name ok=0 failed=0 skipped=0
	as_user mkdir -p "${report%/*}"
	: >"$report"
	as_user git -C "$tree" init -q # lets `git apply` handle renames/binary hunks
	for d in "$@"; do
		step "Patches from ${d#"$SRC"/}"
		while IFS= read -r p; do
			name=${p##*/}
			if patch_excluded "$name" "$excl"; then
				echo "SKIP  $name" >>"$report"
				skipped=$((skipped + 1))
				continue
			fi
			if as_user git -C "$tree" apply --whitespace=nowarn "$p" 2>/dev/null ||
				{ as_user patch -d "$tree" -p1 -N --batch -F3 -s --dry-run <"$p" >/dev/null 2>&1 &&
					as_user patch -d "$tree" -p1 -N --batch -F3 -s <"$p" >/dev/null 2>&1; }; then
				echo "OK    $name" >>"$report"
				ok=$((ok + 1))
			elif as_user git -C "$tree" apply --reverse --check "$p" 2>/dev/null; then
				# same change already applied by an earlier patch set (e.g. Armbian's)
				echo "SKIP  $name (already applied)" >>"$report"
				skipped=$((skipped + 1))
			else
				echo "FAIL  $name" >>"$report"
				failed=$((failed + 1))
				[[ $KERNEL_PATCH_FAIL == continue ]] ||
					die "Patch does not apply: $p
       Add '$name' to userpatches/kernel/exclude.list, or set KERNEL_PATCH_FAIL=continue. Report: $report"
				warn "Patch failed, continuing: $name"
			fi
		done < <(list_patches "$d")
		kernel_add_dts "$tree" "$d"
	done
	rm -rf "$tree/.git"
	own "$report"
	step "Patches: $ok applied, $failed failed, $skipped excluded  (${report#"$SRC"/})"
}

# Copy extra board device trees (dt/) and overlays (overlay/) into the tree and
# register them in the Makefiles - the same thing Armbian's patcher does.
kernel_add_dts() {
	local tree=$1 d=$2 f base
	local dtsdir="$tree/arch/arm64/boot/dts/$DTS_VENDOR"
	local mk="$dtsdir/Makefile"
	if [[ -d $d/dt ]]; then
		local n=0
		for f in "$d"/dt/*.dts "$d"/dt/*.dtsi; do
			[[ -f $f ]] || continue
			base=${f##*/}
			[[ $base == *.dts ]] && patch_excluded "$base" "$SRC/userpatches/kernel/exclude.list" && continue
			as_user cp "$f" "$dtsdir/"
			if [[ $base == *.dts ]] && ! grep -q "${base%.dts}.dtb" "$mk"; then
				echo "dtb-\$($DTB_MAKE_COND) += ${base%.dts}.dtb" | as_user tee -a "$mk" >/dev/null
			fi
			n=$((n + 1))
		done
		step "Added $n device tree files from dt/"
	fi
	if [[ $KERNEL_OVERLAYS == yes && -d $d/overlay ]]; then
		local odir="$dtsdir/overlay" n=0
		as_user mkdir -p "$odir"
		[[ -f $odir/Makefile ]] || as_user touch "$odir/Makefile"
		for f in "$d"/overlay/*.dtso "$d"/overlay/*.dts; do
			[[ -f $f ]] || continue
			base=${f##*/}
			base=${base%.dts*}
			patch_excluded "$base.dtso" "$SRC/userpatches/kernel/exclude.list" && continue
			as_user cp "$f" "$odir/$base.dtso"
			grep -q "$base.dtbo" "$odir/Makefile" ||
				echo "dtb-\$($DTB_MAKE_COND) += $base.dtbo" | as_user tee -a "$odir/Makefile" >/dev/null
			n=$((n + 1))
		done
		# other files (README, fixup scripts) are kept for reference only
		grep -q '^subdir-y += overlay' "$mk" || echo 'subdir-y += overlay' | as_user tee -a "$mk" >/dev/null
		# overlays need __symbols__ in the base DTBs
		grep -q '^DTC_FLAGS ?= -@' "$mk" || as_user sed -i '1i DTC_FLAGS ?= -@' "$mk"
		step "Added $n DT overlays from overlay/"
	fi
	return 0
}

kernel_configure() {
	local tree=$1 base=$2
	shift 2
	local mk=(make -C "$tree" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE")
	if [[ -z $base ]]; then
		step "Base config: arm64 defconfig"
		as_user "${mk[@]}" -s defconfig
	else
		step "Base config: ${base#"$SRC"/}"
		if [[ $base == *.gz ]]; then
			zcat "$base" | as_user tee "$tree/.config" >/dev/null
		else
			as_user cp "$base" "$tree/.config"
		fi
	fi
	if (($#)); then
		step "Merging fragments: $(printf '%s ' "${@##*/}")"
		(cd "$tree" && as_user env ARCH=arm64 ./scripts/kconfig/merge_config.sh -m .config "$@" >/dev/null)
	fi
	as_user "${mk[@]}" -s olddefconfig
	if [[ $KERNEL_MENUCONFIG == yes ]]; then
		if [[ -r /dev/tty ]]; then
			as_user "${mk[@]}" menuconfig </dev/tty >/dev/tty 2>&1
			local save="$SRC/userpatches/kernel/$KERNEL_FAMILY-menuconfig.config"
			as_user mkdir -p "${save%/*}"
			as_user cp "$tree/.config" "$save"
			step "Saved to ${save#"$SRC"/} - reuse with KERNEL_CONFIG=file KERNEL_CONFIG_FILE=${save#"$SRC"/}"
		else
			warn "KERNEL_MENUCONFIG=yes but there is no terminal - skipped"
		fi
	fi
}

kernel_meta_deb() { # krel pkgver outdir
	local krel=$1 pkgver=$2 outdir=$3 stage name
	name="${PKG_PREFIX}-linux-image-${KERNEL_FAMILY}"
	stage=$(mktemp -d)
	mkdir -p "$stage/DEBIAN" "$stage/usr/share/doc/$name"
	cat >"$stage/DEBIAN/control" <<EOF
Package: $name
Version: $pkgver
Architecture: arm64
Maintainer: $PKG_MAINTAINER
Depends: linux-image-$krel (= $pkgver)
Section: kernel
Priority: optional
Description: newest ${KERNEL_FAMILY} kernel ($krel)
 Metapackage that always depends on the latest kernel built for
 ${KERNEL_FAMILY} boards, so 'apt upgrade' moves the fleet forward.
EOF
	echo "built $BUILD_ID from kernel.org linux-$KERNEL_VERSION_RESOLVED" >"$stage/usr/share/doc/$name/README"
	build_deb "$stage" "$outdir/${name}_${pkgver}_arm64.deb"
	rm -rf "$stage"
	echo "${name}_${pkgver}_arm64.deb"
}

kernel_stage() {
	case $KERNEL_SOURCE in
		debian | debian-backports)
			step "Using Debian's linux-image-arm64 - nothing to build"
			return 0
			;;
		prebuilt)
			compgen -G "$KERNEL_PREBUILT_DIR/linux-image-*.deb" >/dev/null ||
				die "No linux-image-*.deb in KERNEL_PREBUILT_DIR=$KERNEL_PREBUILT_DIR"
			step "Using prebuilt kernel packages from $KERNEL_PREBUILT_DIR"
			return 0
			;;
	esac

	local ver majmin
	ver=$(resolve_kernel_version)
	majmin=$(kernel_majmin "$ver")
	KERNEL_VERSION_RESOLVED=$ver
	# Build name; the real kernelrelease is read from the tree later
	# (7.3 -> "7.3.0-<suffix>": .0 releases get a SUBLEVEL).
	local name="${ver}${KERNEL_LOCALVERSION}" krel
	local outdir="$OUT/debs/kernel-$KERNEL_FAMILY"
	local base
	base=$(kernel_base_config)
	local -a frags pdirs
	mapfile -t frags < <(kernel_fragments)
	mapfile -t pdirs < <(kernel_patch_dirs "$majmin")

	local hash
	hash=$(hash_inputs "$ver" "$KERNEL_CONFIG" "$KERNEL_LOCALVERSION" "$KERNEL_OVERLAYS" "$KERNEL_HEADERS" "$PKG_PREFIX" \
		-- ${base:+"$base"} "${frags[@]}" "${pdirs[@]}" "$SRC/userpatches/kernel/exclude.list")
	if stamp_ok "$outdir/.stamp-$name" "$hash" && [[ -f $outdir/LATEST ]]; then
		step "Kernel $name already built from identical inputs - skipping (FORCE=yes rebuilds)"
		return 0
	fi

	local tb
	tb=$(fetch_kernel "$ver")
	local wdir="$WORK/kernel" tree="$WORK/kernel/linux-$name"
	as_user mkdir -p "$wdir" "$outdir"
	rm -rf "$tree" "$wdir"/*.deb "$wdir"/*.buildinfo "$wdir"/*.changes
	as_user mkdir -p "$tree"
	step "Extracting linux-$ver"
	as_user tar -xf "$tb" -C "$tree" --strip-components=1

	kernel_patch "$tree" "${pdirs[@]}"
	kernel_configure "$tree" "$base" "${frags[@]}"
	krel=$(as_user make -s -C "$tree" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
		LOCALVERSION="$KERNEL_LOCALVERSION" kernelrelease)
	[[ -n $krel ]] || die "Could not determine the kernel release"
	local shim path=$PATH
	shim=$(install_shim_dir)
	if [[ -n $shim ]]; then
		path="$shim:$PATH"
		step "Using a retrying 'install' wrapper (uutils install -D race, Ubuntu LP#2151166)"
	fi

	local pkgver="${ver}-${BUILD_ID}" profiles=""
	if [[ $KERNEL_HEADERS == no || ($KERNEL_HEADERS == auto && -n $CROSS_COMPILE) ]]; then
		profiles="pkg.linux-upstream.nokernelheaders"
		step "Skipping linux-headers (KERNEL_HEADERS=$KERNEL_HEADERS)"
	fi
	step "Compiling $krel with $(nproc) jobs - this takes a while"
	as_user env PATH="$path" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$KERNEL_LOCALVERSION" \
		KDEB_PKGVERSION="$pkgver" DEB_BUILD_PROFILES="$profiles" KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST="$PKG_PREFIX" \
		make -C "$tree" -j"$(nproc)" bindeb-pkg

	local -a debs=() install=()
	local d
	for d in "$wdir"/linux-image-"$krel"_*.deb "$wdir"/linux-headers-"$krel"_*.deb "$wdir"/linux-libc-dev_*.deb; do
		[[ -f $d ]] && debs+=("$d")
	done
	((${#debs[@]})) || die "bindeb-pkg produced no packages in $wdir"
	as_user cp "${debs[@]}" "$outdir/"
	as_user cp "$tree/.config" "$outdir/config-$krel"
	for d in "$wdir"/linux-image-"$krel"_*.deb; do install+=("${d##*/}"); done
	install+=("$(kernel_meta_deb "$krel" "$pkgver" "$outdir")")
	printf '%s\n' "${install[@]}" >"$outdir/LATEST"
	own "$outdir/LATEST"
	stamp_write "$outdir/.stamp-$name" "$hash"
	info "Kernel $krel packaged in ${outdir#"$SRC"/}"
}
