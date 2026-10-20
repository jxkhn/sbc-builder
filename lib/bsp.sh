# shellcheck shell=bash
# BSP stage: builds <prefix>-bsp-<board>, your replacement for armbian-bsp-cli.
# Everything that should be updatable over apt across the fleet lives here:
# first-boot setup, kernel install hook, boot config, zram, journald, governor, motd.
#
# Sources (later overrides earlier): bsp/common/  bsp/boards/<board>/  userpatches/bsp/
# "@PREFIX@" in file names and contents is replaced with PKG_PREFIX.

bsp_stage() {
	local pkg="${PKG_PREFIX}-bsp-${BOARD}" ver="1.${BUILD_ID}" outdir="$OUT/debs/$BOARD"
	local stage d
	stage=$(mktemp -d)
	as_user mkdir -p "$outdir"
	for d in "$SRC/bsp/common" "$SRC/bsp/boards/$BOARD" "$SRC/userpatches/bsp"; do
		[[ -d $d ]] && cp -a "$d/." "$stage/"
	done
	mkdir -p "$stage/DEBIAN" "$stage/etc/default" "$stage/usr/lib/@PREFIX@" "$stage/usr/share/u-boot-menu/conf.d"
	[[ $MOTD == yes ]] || rm -f "$stage"/etc/update-motd.d/*@PREFIX@*

	# --- generated configuration -------------------------------------------
	# Boot entry settings. u-boot-menu reads this fragment on every kernel install;
	# root= comes from /etc/fstab automatically.
	cat >"$stage/usr/share/u-boot-menu/conf.d/50-@PREFIX@-board.conf" <<EOF
# $BOARD_NAME - shipped by $pkg. Local overrides: /etc/u-boot-menu/conf.d/*.conf
U_BOOT_FDT="$DTB"
U_BOOT_FDT_DIR="/usr/lib/linux-image-"
U_BOOT_FDT_OVERLAYS_DIR="/boot/dtbo/"
U_BOOT_PARAMETERS="rootwait $KERNEL_CMDLINE"
U_BOOT_TIMEOUT="10"
U_BOOT_ENTRIES="2"
EOF

	cat >"$stage/etc/default/@PREFIX@-firstboot" <<EOF
# Read once by @PREFIX@-firstboot.service on the first boot.
GROWFS=$GROWFS
# {MAC} is replaced by the last 6 hex digits of the first wired NIC
HOSTNAME_PATTERN="$([[ $IMAGE_HOSTNAME == *"{MAC}"* ]] && echo "$IMAGE_HOSTNAME")"
EOF
	cat >"$stage/etc/default/@PREFIX@-cpufreq" <<EOF
# CPU frequency governor applied at boot (default = leave the kernel's choice)
GOVERNOR=$CPU_GOVERNOR
EOF

	local depends="u-boot-menu, initramfs-tools, kmod"
	if [[ $ZRAM == yes ]]; then
		mkdir -p "$stage/etc/systemd"
		cat >"$stage/etc/systemd/zram-generator.conf" <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
swap-priority = 100
EOF
		depends+=", systemd-zram-generator"
	fi
	if [[ $RAMLOG == volatile ]]; then
		mkdir -p "$stage/etc/systemd/journald.conf.d"
		cat >"$stage/etc/systemd/journald.conf.d/50-@PREFIX@-volatile.conf" <<EOF
# Keep the journal in RAM only - no log writes to the SD card.
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF
	fi
	[[ $GROWFS == yes ]] && depends+=", cloud-guest-utils"

	cat >"$stage/usr/lib/@PREFIX@/build-info" <<EOF
board=$BOARD
board_name=$BOARD_NAME
release=$RELEASE
kernel_source=$KERNEL_SOURCE
build=$BUILD_ID
builder=$(cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || echo unversioned)
EOF

	cat >"$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
	if [ -z "$2" ]; then
		systemctl enable @PREFIX@-cpufreq.service >/dev/null 2>&1 || true
	fi
	if [ -d /run/systemd/system ]; then
		systemctl daemon-reload || true
	fi
	# regenerate extlinux.conf with the current board settings
	if [ -x /usr/sbin/u-boot-update ] && ls /boot/vmlinuz-* >/dev/null 2>&1; then
		u-boot-update || true
	fi
fi
exit 0
EOF
	cat >"$stage/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: all
Maintainer: $PKG_MAINTAINER
Depends: $depends
Section: admin
Priority: optional
Description: board support for $BOARD_NAME
 First-boot setup, kernel install hook, boot configuration and system
 tweaks for $BOARD_NAME on plain Debian.
EOF

	# @PREFIX@ substitution in contents and paths
	grep -rlI '@PREFIX@' "$stage" | xargs -r sed -i "s/@PREFIX@/$PKG_PREFIX/g"
	local p
	while IFS= read -r p; do
		mv "$p" "$(dirname "$p")/$(basename "$p" | sed "s/@PREFIX@/$PKG_PREFIX/g")"
	done < <(find "$stage" -depth -name '*@PREFIX@*')
	find "$stage/usr/lib/$PKG_PREFIX" -name "*.sh" -exec chmod 755 {} +
	find "$stage/etc/kernel" "$stage/etc/update-motd.d" -type f -exec chmod 755 {} + 2>/dev/null || true

	local deb="${pkg}_${ver}_all.deb"
	rm -f "$outdir/${pkg}_"*.deb
	build_deb "$stage" "$outdir/$deb"
	rm -rf "$stage"
	echo "$deb" >"$outdir/LATEST-bsp"
	own "$outdir/LATEST-bsp"
	info "BSP packaged: $deb"
}
