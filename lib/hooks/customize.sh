#!/usr/bin/env bash
# mmdebstrap --customize-hook: configures the target rootfs.
# Runs on the build host as root:  customize.sh <rootfs> <env-file>
set -Eeuo pipefail
R=$1
# shellcheck disable=SC1090
source "$2"

step() { printf '  -> %s\n' "$*" >&2; }
die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}
trap 'die "customize hook failed at line $LINENO: $BASH_COMMAND"' ERR

in_chroot() {
	chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C \
		DEBIAN_FRONTEND=noninteractive "$@"
}
apt_install() {
	in_chroot apt-get -q -y --no-install-recommends \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install "$@"
}

# Never start services in the chroot; marker stops package scripts touching disks.
own_policy=no
if [[ ! -e $R/usr/sbin/policy-rc.d ]]; then
	printf '#!/bin/sh\nexit 101\n' >"$R/usr/sbin/policy-rc.d"
	chmod 755 "$R/usr/sbin/policy-rc.d"
	own_policy=yes
fi
touch "$R/etc/${PKG_PREFIX}-image-build"

# ------------------------------------------------------------- APT sources
step "APT sources"
rm -f "$R/etc/apt/sources.list"
suites=$RELEASE
case $RELEASE in
	bookworm | trixie)
		suites+=" $RELEASE-updates"
		[[ $APT_BACKPORTS == yes || $KERNEL_SOURCE == debian-backports ]] && suites+=" $RELEASE-backports"
		;;
esac
cat >"$R/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $suites
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
if [[ $RELEASE != sid ]]; then
	cat >>"$R/etc/apt/sources.list.d/debian.sources" <<EOF

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $RELEASE-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi
if [[ -n $FLEET_REPO_URL ]]; then
	signed="Trusted: yes"
	if [[ -n $FLEET_REPO_KEY ]]; then
		ext=gpg
		[[ $FLEET_REPO_KEY == *.asc ]] && ext=asc
		install -m 644 "$FLEET_REPO_KEY" "$R/usr/share/keyrings/${PKG_PREFIX}-fleet.$ext"
		signed="Signed-By: /usr/share/keyrings/${PKG_PREFIX}-fleet.$ext"
	else
		echo "WARNING: FLEET_REPO_URL without FLEET_REPO_KEY - repo is trusted unsigned" >&2
	fi
	cat >"$R/etc/apt/sources.list.d/${PKG_PREFIX}-fleet.sources" <<EOF
Types: deb
URIs: $FLEET_REPO_URL
Suites: $FLEET_REPO_SUITE
Components: main
$signed
EOF
fi
if [[ $NO_RECOMMENDS == yes ]]; then
	printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\n' >"$R/etc/apt/apt.conf.d/71-no-recommends"
fi
in_chroot apt-get -q update
in_chroot apt-get -q -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade

# ------------------------------------------------------------- base config
step "fstab, locale, timezone"
cat >"$R/etc/fstab" <<EOF
# <file system>                            <mount point> <type> <options>                                        <dump> <pass>
UUID=$ROOT_UUID  /             ext4   defaults,noatime,commit=600,errors=remount-ro    0      1
EOF
if [[ $LOCALE != C.UTF-8 && $LOCALE != C ]]; then
	line="$LOCALE ${LOCALE##*.}"
	[[ $LOCALE == *.* ]] || line="$LOCALE ISO-8859-1"
	grep -Fqx "$line" "$R/etc/locale.gen" 2>/dev/null || echo "$line" >>"$R/etc/locale.gen"
	in_chroot locale-gen >/dev/null
fi
in_chroot update-locale "LANG=$LOCALE"
[[ -f $R/usr/share/zoneinfo/$TIMEZONE ]] || die "Unknown TIMEZONE '$TIMEZONE'"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
echo "$TIMEZONE" >"$R/etc/timezone"

# ------------------------------------------------------------- packages
# BSP + U-Boot first, so the kernel install hooks and boot config exist before the kernel lands.
mkdir -p "$R/tmp/local-debs"
cp "$DEBDIR"/*.deb "$R/tmp/local-debs/"
first=() rest=()
for f in "$R"/tmp/local-debs/*.deb; do
	n=${f##*/}
	case $n in
		"$PKG_PREFIX"-bsp-* | "$PKG_PREFIX"-u-boot-*) first+=("$n") ;;
		*) rest+=("$n") ;;
	esac
done
if ((${#first[@]})); then
	step "Installing ${first[*]}"
	apt_install "${first[@]/#//tmp/local-debs/}"
fi
case $KERNEL_SOURCE in
	debian)
		step "Installing Debian kernel"
		apt_install linux-image-arm64
		;;
	debian-backports)
		step "Installing Debian backports kernel"
		apt_install -t "$RELEASE-backports" linux-image-arm64
		;;
esac
if ((${#rest[@]})); then
	step "Installing ${rest[*]}"
	apt_install "${rest[@]/#//tmp/local-debs/}"
fi
rm -rf "$R/tmp/local-debs"

# ------------------------------------------------------------- boot config
step "Boot configuration (u-boot-menu)"
if [[ -n $FDT_OVERLAYS ]]; then
	mkdir -p "$R/etc/u-boot-menu/conf.d"
	cat >"$R/etc/u-boot-menu/conf.d/50-overlays.conf" <<EOF
# Device tree overlays from /boot/dtbo/. Edit, then run: sudo u-boot-update
U_BOOT_FDT_OVERLAYS="$FDT_OVERLAYS"
EOF
	for o in $FDT_OVERLAYS; do
		[[ -f $R/boot/dtbo/$o ]] || echo "WARNING: overlay $o not found in /boot/dtbo" >&2
	done
fi
in_chroot u-boot-update
[[ -f $R/boot/extlinux/extlinux.conf ]] || die "u-boot-update did not create /boot/extlinux/extlinux.conf"
compgen -G "$R/usr/lib/linux-image-*/$DTB" >/dev/null || die "Kernel package has no $DTB"
ls "$R"/boot/vmlinuz-* >/dev/null 2>&1 || die "No kernel installed"

# ------------------------------------------------------------- network
step "Network: $NETWORK"
case $NETWORK in
	networkd)
		cat >"$R/etc/systemd/network/20-wired.network" <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
		in_chroot systemctl enable systemd-networkd.service systemd-resolved.service
		;;
	networkmanager)
		in_chroot systemctl enable NetworkManager.service
		;;
	ifupdown)
		mkdir -p "$R/etc/network/interfaces.d"
		cat >"$R/etc/network/interfaces.d/wired" <<EOF
allow-hotplug end0
iface end0 inet dhcp

allow-hotplug eth0
iface eth0 inet dhcp
EOF
		;;
esac

# ------------------------------------------------------------- users & ssh
step "Users and SSH"
if [[ -n $ROOT_PASSWORD ]]; then
	in_chroot usermod -p "$ROOT_PASSWORD" root
else
	in_chroot passwd -l root >/dev/null
fi
if [[ -n $ROOT_SSH_KEYS ]]; then
	install -d -m 700 "$R/root/.ssh"
	install -m 600 "$ROOT_SSH_KEYS" "$R/root/.ssh/authorized_keys"
fi
if [[ -n $USER_NAME ]]; then
	groups=""
	for g in sudo adm dialout plugdev netdev video audio input render i2c gpio spi systemd-journal; do
		in_chroot getent group "$g" >/dev/null && groups+="${groups:+,}$g"
	done
	in_chroot useradd -m -s /bin/bash -G "$groups" "$USER_NAME"
	if [[ -n $USER_PASSWORD ]]; then
		in_chroot usermod -p "$USER_PASSWORD" "$USER_NAME"
	else
		echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" >"$R/etc/sudoers.d/90-$USER_NAME"
		chmod 440 "$R/etc/sudoers.d/90-$USER_NAME"
	fi
	if [[ -n $USER_SSH_KEYS ]]; then
		uid=$(in_chroot id -u "$USER_NAME")
		gid=$(in_chroot id -g "$USER_NAME")
		install -d -m 700 -o "$uid" -g "$gid" "$R/home/$USER_NAME/.ssh"
		install -m 600 -o "$uid" -g "$gid" "$USER_SSH_KEYS" "$R/home/$USER_NAME/.ssh/authorized_keys"
	fi
fi
mkdir -p "$R/etc/ssh/sshd_config.d"
cat >"$R/etc/ssh/sshd_config.d/50-${PKG_PREFIX}.conf" <<EOF
PermitRootLogin $SSH_ROOT_LOGIN
PasswordAuthentication $SSH_PASSWORD_AUTH
EOF
rm -f "$R"/etc/ssh/ssh_host_* # regenerated per board on first boot

# ------------------------------------------------------------- updates
if [[ $UNATTENDED_UPGRADES == yes ]]; then
	step "unattended-upgrades"
	apt_install unattended-upgrades
	printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
		>"$R/etc/apt/apt.conf.d/20auto-upgrades"
	if [[ -n $FLEET_REPO_URL ]]; then
		host=$(sed -E 's#^[a-z]+://##; s#[/:].*##' <<<"$FLEET_REPO_URL")
		printf 'Unattended-Upgrade::Origins-Pattern { "site=%s"; };\n' "$host" \
			>"$R/etc/apt/apt.conf.d/51unattended-upgrades-${PKG_PREFIX}-fleet"
	fi
fi

# ------------------------------------------------------------- first boot
in_chroot systemctl enable "${PKG_PREFIX}-firstboot.service"
: >"$R/etc/machine-id"
rm -f "$R/var/lib/dbus/machine-id"
[[ -d $R/var/lib/dbus ]] && ln -s /etc/machine-id "$R/var/lib/dbus/machine-id"

# ------------------------------------------------------------- your additions
if [[ -d $SRC/userpatches/overlay ]]; then
	step "Copying userpatches/overlay/"
	cp -a --no-preserve=ownership "$SRC/userpatches/overlay/." "$R/"
fi
if [[ -f $SRC/userpatches/customize.sh ]]; then
	step "Running userpatches/customize.sh"
	ROOTFS=$R bash "$SRC/userpatches/customize.sh" "$R"
fi

# ------------------------------------------------------------- cleanup
in_chroot apt-get -q clean
rm -rf "$R"/var/lib/apt/lists/* "$R"/var/cache/apt/*.bin
find "$R/var/log" -type f \( -name '*.log' -o -name '*.gz' \) -delete
rm -f "$R/etc/${PKG_PREFIX}-image-build"
[[ $own_policy == yes ]] && rm -f "$R/usr/sbin/policy-rc.d"
exit 0
