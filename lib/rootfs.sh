# shellcheck shell=bash
# Rootfs stage: plain Debian via mmdebstrap, then lib/hooks/customize.sh inside it.

rootfs_dir() { echo "$WORK/rootfs/$BOARD"; }

rootfs_package_list() {
	local f line
	local -a files=("$SRC/config/packages/minimal.list")
	[[ $VARIANT != minimal ]] && files+=("$SRC/config/packages/$VARIANT.list")
	[[ -f $SRC/userpatches/packages.list ]] && files+=("$SRC/userpatches/packages.list")
	for f in "${files[@]}"; do
		[[ -f $f ]] || die "Package list not found: $f"
		while IFS= read -r line; do
			line=${line%%#*}
			for line in $line; do echo "$line"; done
		done <"$f"
	done
	for line in $BOARD_PACKAGES $EXTRA_PACKAGES; do echo "$line"; done
	case $NETWORK in
		networkd) echo systemd-resolved ;;
		networkmanager) echo network-manager ;;
		ifupdown)
			echo ifupdown
			if [[ $RELEASE == bookworm ]]; then echo isc-dhcp-client; else echo dhcpcd-base; fi
			;;
	esac
	return 0
}

# Local .debs to install: bsp, u-boot, kernel (+ metapackage).
rootfs_local_debs() {
	local d f
	d="$OUT/debs/$BOARD"
	[[ -f $d/LATEST-bsp ]] || die "No BSP package for $BOARD - run the bsp stage first"
	echo "$d/$(<"$d/LATEST-bsp")"
	if [[ -n $UBOOT_DEFCONFIG ]]; then
		[[ -f $d/LATEST-u-boot ]] || die "No U-Boot package for $BOARD - run the uboot stage first"
		echo "$d/$(<"$d/LATEST-u-boot")"
	fi
	case $KERNEL_SOURCE in
		mainline)
			d="$OUT/debs/kernel-$KERNEL_FAMILY"
			[[ -f $d/LATEST ]] || die "No kernel built for $KERNEL_FAMILY - run the kernel stage first"
			while IFS= read -r f; do echo "$d/$f"; done <"$d/LATEST"
			;;
		prebuilt)
			for f in "$KERNEL_PREBUILT_DIR"/linux-image-*.deb; do echo "$f"; done
			;;
	esac
	return 0
}

rootfs_stage() {
	require_root
	validate_login
	local root envf debdir k
	root=$(rootfs_dir)
	envf="$WORK/rootfs/$BOARD.env"
	debdir="$WORK/rootfs/$BOARD.debs"
	mkdir -p "$WORK/rootfs"
	umount_below "$root"
	rm -rf --one-file-system "$root" "$debdir"
	mkdir -p "$debdir"

	local -a pkgs debs
	mapfile -t pkgs < <(rootfs_package_list | awk 'NF && !seen[$0]++')
	mapfile -t debs < <(rootfs_local_debs)
	for k in "${debs[@]}"; do
		[[ -f $k ]] || die "Missing package: $k"
		cp "$k" "$debdir/"
	done

	ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
	echo "$ROOT_UUID" >"$WORK/rootfs/$BOARD.uuid"

	# Everything the hook needs, exported.
	{
		for k in "${OPT_KEYS[@]}" "${BOARD_VARS[@]}" SRC BUILD_ID ROOT_UUID; do
			printf 'export %s=%q\n' "$k" "${!k-}"
		done
		printf 'export DEBDIR=%q\n' "$debdir"
	} >"$envf"
	chmod 600 "$envf"

	step "mmdebstrap: Debian $RELEASE arm64, ${#pkgs[@]} packages + ${#debs[@]} local .debs"
	mmdebstrap --mode=root --architectures=arm64 --variant=minbase \
		--components="main contrib non-free non-free-firmware" \
		--include="$(
			IFS=,
			echo "${pkgs[*]}"
		)" \
		--customize-hook="bash '$SRC/lib/hooks/customize.sh' \"\$1\" '$envf'" \
		"$RELEASE" "$root" "$MIRROR"

	rootfs_finalize "$root"
	rm -f "$envf"
	rm -rf "$debdir"
	info "Rootfs ready: ${root#"$SRC"/} ($(du -sxh "$root" | cut -f1))"
}

# Files mmdebstrap manages itself during the build are set after it finishes.
rootfs_finalize() {
	local root=$1 hn
	hn=${IMAGE_HOSTNAME//\{MAC\}/}
	hn=${hn%-}
	hn=${hn#-}
	[[ -n $hn ]] || hn=$BOARD
	echo "$hn" >"$root/etc/hostname"
	cat >"$root/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$hn
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF
	rm -f "$root/etc/resolv.conf"
	if [[ $NETWORK == networkd ]]; then
		ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
	else
		: >"$root/etc/resolv.conf"
	fi
}
