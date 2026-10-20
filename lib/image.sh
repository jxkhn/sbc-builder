# shellcheck shell=bash
# Image stage: rootfs -> ext4 (mkfs -d, no loop devices) -> partitioned .img with
# U-Boot at sector 64 -> compressed + sha256.
#
#   sector 0      partition table
#   sector 64     U-Boot (idbloader + u-boot.itb in one u-boot-rockchip.bin)
#   16 MiB        root partition (ext4, /boot lives on it)

mke2fs_has_orphan_file() {
	local v
	v=$(mke2fs -V 2>&1 | awk 'NR == 1 {print $2}')
	[[ $(printf '%s\n1.47.0\n' "$v" | sort -V | head -n1) == 1.47.0 ]]
}

image_stage() {
	require_root
	local root uuid
	root=$(rootfs_dir)
	[[ -f $root/etc/os-release ]] || die "No rootfs for $BOARD - run the rootfs stage first"
	uuid=$(<"$WORK/rootfs/$BOARD.uuid")
	local krel
	krel=$(find "$root/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -n1)

	local name=$OUTPUT_NAME
	[[ $name == auto ]] && name="${PKG_PREFIX}-${BOARD}-${RELEASE}-${krel:-nokernel}-${BUILD_ID}"
	local wdir="$WORK/image" idir="$OUT/images"
	mkdir -p "$wdir" "$idir"

	local used fs_mb start_mb=16
	used=$(du -sxm "$root" | cut -f1)
	if [[ $IMAGE_SIZE == auto ]]; then
		fs_mb=$((used * 125 / 100 + 256))
	else
		[[ $IMAGE_SIZE =~ ^[0-9]+$ ]] || die "IMAGE_SIZE must be 'auto' or MiB"
		fs_mb=$((IMAGE_SIZE - start_mb - 1))
	fi
	((fs_mb > used + 64)) || die "IMAGE_SIZE too small: rootfs needs about $((used + start_mb + 64)) MiB"

	local fsimg="$wdir/$BOARD-rootfs.ext4" img="$wdir/$name.img"
	rm -f "$fsimg" "$img"
	# mainline U-Boot's ext4 driver rejects these newer features
	local feats="^metadata_csum_seed"
	mke2fs_has_orphan_file && feats+=",^orphan_file"
	step "ext4 root filesystem: ${fs_mb} MiB (content ${used} MiB)"
	truncate -s "${fs_mb}M" "$fsimg"
	mkfs.ext4 -q -F -L "$ROOTFS_LABEL" -U "$uuid" -O "$feats" -m 1 -d "$root" "$fsimg"

	truncate -s "$((start_mb + fs_mb + 1))M" "$img"
	local start=$((start_mb * 2048)) size=$((fs_mb * 2048))
	step "Partition table: $PART_TABLE"
	if [[ $PART_TABLE == gpt ]]; then
		printf 'label: gpt\nunit: sectors\n\nstart=%d, size=%d, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="%s", attrs="LegacyBIOSBootable"\n' \
			"$start" "$size" "$ROOTFS_LABEL"
	else
		printf 'label: dos\nunit: sectors\n\nstart=%d, size=%d, type=83, bootable\n' "$start" "$size"
	fi | sfdisk -q "$img"

	if [[ -n $UBOOT_DEFCONFIG ]]; then
		local ubin="$root/usr/lib/${PKG_PREFIX}-u-boot/$BOARD/$UBOOT_BIN"
		[[ -f $ubin ]] || die "U-Boot binary missing in rootfs: $ubin"
		local bytes
		bytes=$(stat -c %s "$ubin")
		((UBOOT_OFFSET_SECTORS * 512 + bytes <= start * 512)) || die "U-Boot ($bytes bytes) overlaps the root partition"
		step "U-Boot -> sector $UBOOT_OFFSET_SECTORS ($((bytes / 1024)) KiB)"
		dd if="$ubin" of="$img" seek="$UBOOT_OFFSET_SECTORS" conv=notrunc status=none
	else
		warn "No U-Boot for $BOARD - the image is not bootable on its own"
	fi
	dd if="$fsimg" of="$img" bs=1M seek="$start_mb" conv=notrunc,sparse status=none
	rm -f "$fsimg"

	local final=$img
	case $COMPRESS in
		xz)
			step "Compressing (xz)"
			xz -T0 -6 -f "$img"
			final=$img.xz
			;;
		zstd)
			step "Compressing (zstd)"
			zstd -T0 -12 -q -f --rm "$img"
			final=$img.zst
			;;
	esac
	mv -f "$final" "$idir/"
	final="$idir/${final##*/}"
	(cd "$idir" && sha256sum "${final##*/}" >"${final##*/}.sha256")
	own "$idir"
	info "Image: ${final#"$SRC"/} ($(du -h "$final" | cut -f1))"
	step "Flash: xzcat/zstdcat <image> | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress  (or bmaptool / Etcher)"
}
