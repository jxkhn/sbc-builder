# shellcheck shell=bash
# U-Boot stage: mainline U-Boot + Rockchip DDR blob (TPL) + BL31 -> u-boot-rockchip.bin,
# packaged as <prefix>-u-boot-<board> with an installer for updates on the device.

TFA_REPO=${TFA_REPO:-https://github.com/ARM-software/arm-trusted-firmware.git}

rkbin_dir() {
	local slug
	slug=$(sed -E 's#^https?://##; s#\.git$##; s#[^A-Za-z0-9]+#-#g' <<<"$RKBIN_REPO")
	echo "$CACHE/rkbin/$slug"
}

rkbin_fetch() {
	local d
	d=$(rkbin_dir)
	if [[ ! -d $d/.git ]]; then
		step "Fetching rkbin ($RKBIN_REPO)"
		as_user mkdir -p "${d%/*}"
		as_user git clone -q --depth 1 "$RKBIN_REPO" "$d"
	elif [[ ${RKBIN_UPDATE:-no} == yes ]]; then
		as_user git -C "$d" pull -q --ff-only
	fi
}

# rkbin_pick "<pattern> [<pattern>...]" - first pattern with a match wins, newest version within it.
rkbin_pick() {
	local d pat m
	d=$(rkbin_dir)
	for pat in $1; do
		m=$(compgen -G "$d/$pat" | sort -V | tail -n1) || true
		if [[ -n $m ]]; then
			echo "$m"
			return 0
		fi
	done
	die "No file in $RKBIN_REPO matches: $1"
}

tfa_build() {
	local tag src out
	tag=$(resolve_git_tag "$TFA_REPO" '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' "$TFA_VERSION")
	src="$CACHE/tf-a/$tag"
	git_fetch_tag "$TFA_REPO" "$tag" "$src"
	out="$src/build/$TFA_PLAT/release/bl31/bl31.elf"
	if [[ ! -f $out ]]; then
		step "Building TF-A $tag (PLAT=$TFA_PLAT)"
		as_user make -C "$src" -j"$(nproc)" CROSS_COMPILE="$CROSS_COMPILE" PLAT="$TFA_PLAT" bl31 >&2
	fi
	echo "$out"
}

uboot_stage() {
	if [[ -z $UBOOT_DEFCONFIG ]]; then
		warn "Board $BOARD defines no U-Boot - skipping"
		return 0
	fi
	local tag tpl bl31
	tag=$(resolve_git_tag "$UBOOT_REPO" '^v[0-9]{4}\.[0-9]{2}$' "$UBOOT_VERSION")
	rkbin_fetch
	# Empty RKBIN_TPL / TPL_SOURCE=uboot: let U-Boot build its own DRAM init (only some SoCs, e.g. RK3328)
	if [[ -n $RKBIN_TPL && ${TPL_SOURCE:-rkbin} == rkbin ]]; then
		tpl=$(rkbin_pick "$RKBIN_TPL")
	else
		tpl=""
	fi
	case $BL31_SOURCE in
		rkbin) bl31=$(rkbin_pick "$RKBIN_BL31") ;;
		tfa) bl31=$(tfa_build) ;;
	esac

	local outdir="$OUT/debs/$BOARD" hash
	as_user mkdir -p "$outdir"
	hash=$(hash_inputs "$tag" "$UBOOT_DEFCONFIG" "$BL31_SOURCE" "$PKG_PREFIX" "$UBOOT_AUTOUPDATE" \
		-- ${tpl:+"$tpl"} "$bl31" "$SRC/userpatches/u-boot/common" "$SRC/userpatches/u-boot/$BOARD" \
		"$SRC/userpatches/u-boot/$BOARD.config" "$SRC/bsp/tools/u-boot-install.in")
	if stamp_ok "$outdir/.stamp-u-boot" "$hash" && [[ -f $outdir/LATEST-u-boot ]]; then
		step "U-Boot $tag already built from identical inputs - skipping"
		return 0
	fi

	local src="$CACHE/u-boot/$tag" build="$WORK/u-boot/$BOARD"
	git_fetch_tag "$UBOOT_REPO" "$tag" "$src"
	rm -rf "$build"
	as_user mkdir -p "${build%/*}"
	as_user cp -a "$src" "$build"
	rm -rf "$build/.git"

	local d p
	for d in "$SRC/userpatches/u-boot/common" "$SRC/userpatches/u-boot/$BOARD"; do
		[[ -d $d ]] || continue
		while IFS= read -r p; do
			step "U-Boot patch: ${p##*/}"
			as_user patch -d "$build" -p1 -N --batch -s <"$p" || die "U-Boot patch failed: $p"
		done < <(find "$d" -maxdepth 1 -name '*.patch' | LC_ALL=C sort)
	done

	local mk=(make -C "$build" CROSS_COMPILE="$CROSS_COMPILE")
	step "Configuring $UBOOT_DEFCONFIG"
	as_user "${mk[@]}" -s "$UBOOT_DEFCONFIG"
	if [[ -f $SRC/userpatches/u-boot/$BOARD.config ]]; then
		(cd "$build" && as_user ./scripts/kconfig/merge_config.sh -m .config "$SRC/userpatches/u-boot/$BOARD.config" >/dev/null)
		as_user "${mk[@]}" -s olddefconfig
	fi
	local -a envv=(BL31="$bl31")
	[[ -n $tpl ]] && envv+=(ROCKCHIP_TPL="$tpl")
	local tpl_label="U-Boot open-source DRAM init"
	[[ -n $tpl ]] && tpl_label=${tpl##*/}
	step "Building U-Boot $tag  (TPL $tpl_label, BL31 ${bl31##*/})"
	as_user env "${envv[@]}" "${mk[@]}" -j"$(nproc)"
	[[ -f $build/$UBOOT_BIN ]] || die "U-Boot build did not produce $UBOOT_BIN"

	uboot_package "$build" "$tag" "$tpl" "$bl31" "$outdir"
	stamp_write "$outdir/.stamp-u-boot" "$hash"
}

uboot_package() {
	local build=$1 tag=$2 tpl=$3 bl31=$4 outdir=$5
	local pkg="${PKG_PREFIX}-u-boot-${BOARD}" ver="${tag#v}-${BUILD_ID}" stage f
	stage=$(mktemp -d)
	local lib="$stage/usr/lib/${PKG_PREFIX}-u-boot/$BOARD"
	mkdir -p "$lib" "$stage/DEBIAN" "$stage/usr/sbin" "$stage/etc/default"
	for f in "$UBOOT_BIN" u-boot-rockchip-spi.bin idbloader.img u-boot.itb; do
		[[ -f $build/$f ]] && cp "$build/$f" "$lib/"
	done
	cat >"$lib/BUILDINFO" <<EOF
board=$BOARD
u-boot=$tag ($UBOOT_DEFCONFIG)
tpl=${tpl:+${tpl##*/} (from $RKBIN_REPO)}${tpl:-u-boot (open source)}
bl31=$BL31_SOURCE:${bl31##*/}
offset_sectors=$UBOOT_OFFSET_SECTORS
built=$BUILD_ID
EOF
	sed -e "s|@PREFIX@|$PKG_PREFIX|g" -e "s|@BOARD@|$BOARD|g" -e "s|@BIN@|$UBOOT_BIN|g" \
		-e "s|@OFFSET@|$UBOOT_OFFSET_SECTORS|g" "$SRC/bsp/tools/u-boot-install.in" >"$stage/usr/sbin/${PKG_PREFIX}-u-boot-install"
	chmod 755 "$stage/usr/sbin/${PKG_PREFIX}-u-boot-install"
	cat >"$stage/etc/default/${PKG_PREFIX}-u-boot" <<EOF
# yes = write the new bootloader to the boot device whenever this package is upgraded
UBOOT_AUTOUPDATE=$UBOOT_AUTOUPDATE
EOF
	cat >"$stage/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ] && [ -r /etc/default/${PKG_PREFIX}-u-boot ]; then
	. /etc/default/${PKG_PREFIX}-u-boot
	# never touch a disk while an image is being built (chroot)
	if [ "\${UBOOT_AUTOUPDATE:-no}" = yes ] && [ ! -e /etc/${PKG_PREFIX}-image-build ] \\
	   && ! systemd-detect-virt -q --chroot 2>/dev/null; then
		/usr/sbin/${PKG_PREFIX}-u-boot-install --yes || echo "WARNING: U-Boot update failed" >&2
	fi
fi
exit 0
EOF
	cat >"$stage/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: arm64
Maintainer: $PKG_MAINTAINER
Section: admin
Priority: optional
Description: mainline U-Boot $tag for $BOARD_NAME
 u-boot-rockchip.bin built from $UBOOT_REPO ($UBOOT_DEFCONFIG).
 Install to the boot device with ${PKG_PREFIX}-u-boot-install.
EOF
	local deb="${pkg}_${ver}_arm64.deb"
	rm -f "$outdir/${pkg}_"*.deb
	build_deb "$stage" "$outdir/$deb"
	rm -rf "$stage"
	echo "$deb" >"$outdir/LATEST-u-boot"
	own "$outdir/LATEST-u-boot"
	info "U-Boot packaged: $deb"
}
