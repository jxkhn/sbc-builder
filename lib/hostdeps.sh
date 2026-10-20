# shellcheck shell=bash
# Host package checks (Debian/Ubuntu build hosts).

declare -A HOST_DEPS=(
	[common]="git curl ca-certificates python3 xz-utils zstd openssl"
	[kernel]="build-essential bc bison flex libssl-dev libelf-dev libdw-dev cpio kmod rsync dpkg-dev debhelper libncurses-dev"
	[uboot]="build-essential bc bison flex python3-pyelftools python3-setuptools swig libgnutls28-dev uuid-dev libssl-dev device-tree-compiler dpkg-dev"
	[bsp]="dpkg-dev"
	[rootfs]="mmdebstrap debian-archive-keyring arch-test"
	[image]="e2fsprogs fdisk util-linux"
)

check_host_deps() {
	local stage=$1 p list missing=()
	command -v dpkg-query >/dev/null || die "A Debian or Ubuntu build host is required"
	list="${HOST_DEPS[common]} ${HOST_DEPS[$stage]:-}"
	if [[ ($stage == kernel || $stage == uboot) && -n $CROSS_COMPILE ]]; then
		list+=" gcc-aarch64-linux-gnu"
	fi
	for p in $list; do
		dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
	done
	if ((${#missing[@]})); then
		if is_root && [[ ${INSTALL_DEPS:-ask} != no ]] &&
			{ [[ ${INSTALL_DEPS:-ask} == yes ]] || confirm "Install missing host packages: ${missing[*]}?"; }; then
			apt-get update -qq
			DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
		else
			die "Missing host packages: ${missing[*]}  ->  sudo apt install ${missing[*]}"
		fi
	fi
	if [[ $stage == kernel && $KERNEL_SOURCE == mainline && -n $CROSS_COMPILE && $KERNEL_HEADERS == yes ]] &&
		! dpkg-query -W -f='${Status}' libssl-dev:arm64 2>/dev/null | grep -q "ok installed"; then
		die "KERNEL_HEADERS=yes on a cross host needs libssl-dev:arm64 (sudo dpkg --add-architecture arm64 && sudo apt update && sudo apt install libssl-dev:arm64), or use KERNEL_HEADERS=auto"
	fi
	if [[ $stage == rootfs && $(uname -m) != aarch64 ]] && ! arch-test arm64 >/dev/null 2>&1; then
		die "This host cannot run arm64 binaries. Install qemu-user-binfmt (Debian trixie or newer) or qemu-user-static + binfmt-support (bookworm/Ubuntu)."
	fi
	return 0
}
