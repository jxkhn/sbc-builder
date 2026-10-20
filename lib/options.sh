# shellcheck shell=bash
# shellcheck disable=SC2016  # SHOW-IF conditions are evaluated later on purpose
# The option tree. Every user-facing setting is declared here once; the menu,
# `./build.sh options`, config files and KEY=value overrides are all driven by it.
#
#   opt KEY  CATEGORY  TYPE  DEFAULT  "CHOICES"  "DESCRIPTION"  [SHOW-IF]
#
# TYPE: choice | string | bool | password | board
# SHOW-IF: bash test; the option is hidden in the menu when it is false (that is
#          what turns the flat list into a tree).

declare -a OPT_KEYS=()
declare -A OPT_CAT=() OPT_TYPE=() OPT_DEFAULT=() OPT_CHOICES=() OPT_DESC=() OPT_SHOWIF=()

opt() {
	local k=$1
	OPT_KEYS+=("$k")
	OPT_CAT[$k]=$2 OPT_TYPE[$k]=$3 OPT_DEFAULT[$k]=$4 OPT_CHOICES[$k]=$5 OPT_DESC[$k]=$6 OPT_SHOWIF[$k]=${7:-}
}

CATEGORIES=("Target" "Kernel" "Bootloader" "Root filesystem" "Users & access" "Tweaks" "Image" "Armbian import")

# ---------------------------------------------------------------- Target
opt BOARD          "Target" board  ""  ""  "Board (config/boards/*.conf, userpatches/boards/*.conf)"
opt RELEASE        "Target" choice trixie "trixie bookworm forky sid" "Debian release"
opt MIRROR         "Target" string "http://deb.debian.org/debian" "" "Debian mirror (an apt-cacher URL works too)"
opt PKG_PREFIX     "Target" string sbc "" "Prefix for generated packages/files: <prefix>-bsp-<board>, <prefix>-u-boot-<board>"
opt PKG_MAINTAINER "Target" string "SBC image builder <root@localhost>" "" "Maintainer field of generated packages"

# ---------------------------------------------------------------- Kernel
opt KERNEL_SOURCE  "Kernel" choice mainline "mainline debian debian-backports prebuilt" \
	"mainline = build kernel.org source here | debian(-backports) = Debian's linux-image-arm64 | prebuilt = your own .debs"
opt KERNEL_VERSION "Kernel" string stable "" "kernel.org version: stable | longterm | X.Y.Z (e.g. 7.2.8)" \
	'[[ $KERNEL_SOURCE == mainline ]]'
opt KERNEL_CONFIG  "Kernel" choice defconfig "defconfig armbian file" \
	"Base config: arm64 defconfig | imported Armbian config | a file (e.g. zcat /proc/config.gz from a fleet unit). Fragments are merged on top." \
	'[[ $KERNEL_SOURCE == mainline ]]'
opt KERNEL_CONFIG_FILE "Kernel" string "" "" "Path to a kernel .config (may be .gz)" \
	'[[ $KERNEL_SOURCE == mainline && $KERNEL_CONFIG == file ]]'
opt KERNEL_ARMBIAN_PATCHES "Kernel" bool no "" "Apply the imported Armbian patch set + extra device trees (run 'armbian-import' first)" \
	'[[ $KERNEL_SOURCE == mainline ]]'
opt KERNEL_OVERLAYS "Kernel" bool yes "" "Build the imported Armbian DT overlays (.dtbo) and enable overlay symbols (-@)" \
	'[[ $KERNEL_SOURCE == mainline && $KERNEL_ARMBIAN_PATCHES == yes ]]'
opt KERNEL_PATCH_FAIL "Kernel" choice abort "abort continue" "What to do when a patch does not apply" \
	'[[ $KERNEL_SOURCE == mainline ]]'
opt KERNEL_MENUCONFIG "Kernel" bool no "" "Open menuconfig before compiling (result is saved to userpatches/kernel/)" \
	'[[ $KERNEL_SOURCE == mainline ]]'
opt KERNEL_LOCALVERSION "Kernel" string "" "" "Release suffix, e.g. -fleet -> 7.2.8-fleet (empty = -<kernel family>)" \
	'[[ $KERNEL_SOURCE == mainline ]]'
opt KERNEL_HEADERS "Kernel" choice auto "auto yes no" \
	"Also build linux-headers (for DKMS). auto = only on arm64 hosts; cross builds need libssl-dev:arm64" \
	'[[ $KERNEL_SOURCE == mainline ]]'
opt KERNEL_PREBUILT_DIR "Kernel" string "" "" "Directory containing linux-image-*.deb" \
	'[[ $KERNEL_SOURCE == prebuilt ]]'

# ---------------------------------------------------------------- Bootloader
opt UBOOT_VERSION  "Bootloader" string board "" "Mainline U-Boot tag: board (version pinned in the board config, else latest) | latest | vYYYY.MM"
opt UBOOT_REPO     "Bootloader" string "https://source.denx.de/u-boot/u-boot.git" "" "U-Boot git repository"
opt TPL_SOURCE     "Bootloader" choice rkbin "rkbin uboot" "DRAM init: Rockchip blob from rkbin | U-Boot's open-source TPL (RK3328 and older only; board must set TPL_OPEN=yes)"
opt BL31_SOURCE    "Bootloader" choice rkbin "rkbin tfa" "BL31: Rockchip binary from rkbin | built from upstream TF-A (if the SoC is supported)"
opt TFA_VERSION    "Bootloader" string board "" "TF-A tag: board (pinned in the board config, else latest) | latest | vX.Y.Z" '[[ $BL31_SOURCE == tfa ]]'
opt RKBIN_REPO     "Bootloader" string "" "" "rkbin repo for the DDR/TPL (and BL31) blobs (empty = board default, usually rockchip-linux/rkbin)"
opt UBOOT_AUTOUPDATE "Bootloader" bool no "" "Write new U-Boot to the boot device automatically when the u-boot package is upgraded"

# ---------------------------------------------------------------- Root filesystem
opt VARIANT        "Root filesystem" choice server "minimal server" "Package set (config/packages/<variant>.list; minimal is always included)"
opt EXTRA_PACKAGES "Root filesystem" string "" "" "Extra Debian packages, space separated"
opt NETWORK        "Root filesystem" choice networkd "networkd networkmanager ifupdown" "Network stack (DHCP on wired interfaces)"
opt IMAGE_HOSTNAME "Root filesystem" string "" "" "Hostname. {MAC} = last 6 hex digits of the first NIC, set on first boot (e.g. zero3e-{MAC}). Empty = board name"
opt LOCALE         "Root filesystem" string en_US.UTF-8 "" "System locale"
opt TIMEZONE       "Root filesystem" string Etc/UTC "" "Timezone (e.g. Europe/Berlin)"
opt NO_RECOMMENDS  "Root filesystem" bool yes "" "Don't install Recommends by default on the device (lean, like Armbian)"
opt APT_BACKPORTS  "Root filesystem" bool no "" "Add <release>-backports to apt sources"
opt UNATTENDED_UPGRADES "Root filesystem" bool no "" "Install and enable unattended-upgrades"
opt FLEET_REPO_URL "Root filesystem" string "" "" "Your own apt repo for kernel/u-boot/bsp updates (empty = none)"
opt FLEET_REPO_SUITE "Root filesystem" string "" "" "Suite in your repo (empty = release name)" '[[ -n $FLEET_REPO_URL ]]'
opt FLEET_REPO_KEY "Root filesystem" string "" "" "Public key of your repo (.asc or .gpg file)" '[[ -n $FLEET_REPO_URL ]]'

# ---------------------------------------------------------------- Users & access
opt USER_NAME      "Users & access" string "" "" "Default user, member of sudo (empty = none)"
opt USER_PASSWORD  "Users & access" password "" "" "User password (stored as SHA-512 hash). Empty + SSH keys = key-only login, passwordless sudo" \
	'[[ -n $USER_NAME ]]'
opt USER_SSH_KEYS  "Users & access" string "" "" "authorized_keys file for the user" '[[ -n $USER_NAME ]]'
opt ROOT_PASSWORD  "Users & access" password "" "" "Root password (stored as hash; empty = root account locked)"
opt ROOT_SSH_KEYS  "Users & access" string "" "" "authorized_keys file for root"
opt SSH_PASSWORD_AUTH "Users & access" choice yes "yes no" "Allow SSH password logins"
opt SSH_ROOT_LOGIN "Users & access" choice prohibit-password "no prohibit-password yes" "sshd PermitRootLogin"

# ---------------------------------------------------------------- Tweaks
opt ZRAM           "Tweaks" bool yes "" "Compressed swap in RAM (systemd-zram-generator)"
opt ZRAM_SIZE      "Tweaks" string "ram / 2" "" "zram size expression" '[[ $ZRAM == yes ]]'
opt RAMLOG         "Tweaks" choice volatile "off volatile" "volatile = systemd journal kept in RAM only (spares the SD card)"
opt CPU_GOVERNOR   "Tweaks" choice default "default schedutil ondemand performance powersave" "CPU frequency governor applied at boot"
opt GROWFS         "Tweaks" bool yes "" "Grow the root partition to the full card on first boot"
opt MOTD           "Tweaks" bool yes "" "Short system summary at login"
opt FDT_OVERLAYS   "Tweaks" string "" "" "DT overlays to enable, e.g. rockchip-rk3566-spi3-m0-cs0-spidev.dtbo (editable later in /etc/u-boot-menu/conf.d/)"

# ---------------------------------------------------------------- Image
opt IMAGE_SIZE     "Image" string auto "" "Image size in MiB (auto = content + 25% + 256 MiB; grows on first boot anyway)"
opt PART_TABLE     "Image" choice gpt "gpt msdos" "Partition table"
opt ROOTFS_LABEL   "Image" string rootfs "" "Root filesystem label"
opt COMPRESS       "Image" choice xz "xz zstd none" "Image compression"
opt OUTPUT_NAME    "Image" string auto "" "Image file name without extension (auto = <prefix>-<board>-<release>-<kernel>-<date>)"

# ---------------------------------------------------------------- Armbian import (step 2, optional)
opt ARMBIAN_DIR    "Armbian import" string "" "" "Existing armbian/build checkout (empty = clone into cache/)"
opt ARMBIAN_REF    "Armbian import" string auto "" "auto = newest commit that still has patches for your kernel series | branch | tag | commit"
opt ARMBIAN_KERNEL_BRANCH "Armbian import" choice edge "edge current bleedingedge" "Which Armbian kernel config to import (linux-<family>-<branch>.config)"

# Non-menu knobs accepted on the command line / in config files.
EXTRA_KEYS="FORCE STAGES MENU INSTALL_DEPS INSTALL_SHIM RKBIN_UPDATE ARMBIAN_UPDATE CROSS_COMPILE TFA_REPO"

# Board config variables (reset whenever a board is loaded).
BOARD_VARS=(BOARD_NAME SOC KERNEL_FAMILY ARMBIAN_FAMILY DTB DTS_VENDOR DTB_MAKE_COND KERNEL_CMDLINE
	UBOOT_DEFCONFIG UBOOT_BIN UBOOT_OFFSET_SECTORS RKBIN_TPL RKBIN_BL31 BOARD_RKBIN_REPO BOARD_UBOOT_VERSION BOARD_TFA_VERSION TPL_OPEN TFA_PLAT
	BOARD_PACKAGES PATCH_DTS_REGEX PATCH_SOC_REGEX BOARD_NOTES)

PATH_OPTS="KERNEL_CONFIG_FILE KERNEL_PREBUILT_DIR FLEET_REPO_KEY USER_SSH_KEYS ROOT_SSH_KEYS ARMBIAN_DIR"

hash_password() { openssl passwd -6 -stdin <<<"$1"; }

set_option() {
	local k=$1 v=$2
	if [[ -z ${OPT_TYPE[$k]+x} ]]; then
		[[ " $EXTRA_KEYS " == *" $k "* ]] || die "Unknown option '$k' (see ./build.sh options)"
	else
		case ${OPT_TYPE[$k]} in
			choice) [[ " ${OPT_CHOICES[$k]} " == *" $v "* ]] || die "$k must be one of: ${OPT_CHOICES[$k]}" ;;
			bool) [[ $v == yes || $v == no ]] || die "$k must be yes or no" ;;
			password) [[ -n $v && ${v:0:1} != '$' ]] && v=$(hash_password "$v") ;;
		esac
	fi
	printf -v "$k" '%s' "$v"
}

apply_defaults() {
	local k
	for k in "${OPT_KEYS[@]}"; do
		[[ -n ${!k+x} ]] || printf -v "$k" '%s' "${OPT_DEFAULT[$k]}"
	done
}

config_path() {
	local n=$1
	if [[ -f $n ]]; then readlink -f "$n"
	elif [[ -f $ORIG_PWD/$n ]]; then readlink -f "$ORIG_PWD/$n"
	else echo "$SRC/userpatches/config-$n.conf"; fi
}

load_config() {
	local f
	f=$(config_path "$1")
	[[ -f $f ]] || die "Config not found: $1 (looked for $f)"
	# shellcheck disable=SC1090
	source "$f"
	CONFIG_NAME=$(basename "$f" .conf)
	CONFIG_NAME=${CONFIG_NAME#config-}
}

save_config() {
	local f=$1 k
	{
		echo "# build.sh configuration - written $(date -Is)"
		echo "# Any value can be overridden on the command line: ./build.sh build CONFIG=<name> KEY=value"
		for k in "${OPT_KEYS[@]}"; do
			printf '%s=%q\n' "$k" "${!k-}"
		done
	} >"$f"
	chmod 600 "$f" # may contain password hashes
	own "$f"
}

list_board_names() {
	local f
	for f in "$SRC"/config/boards/*.conf "$SRC"/userpatches/boards/*.conf; do
		[[ -f $f ]] && printf '%s ' "$(basename "$f" .conf)"
	done
	return 0
}

# "name|description" per board
list_boards() {
	local f n d
	for f in "$SRC"/config/boards/*.conf "$SRC"/userpatches/boards/*.conf; do
		[[ -f $f ]] || continue
		n=$(basename "$f" .conf)
		d=$(sed -n 's/^BOARD_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -n1)
		echo "$n|${d:-$n}"
	done
	return 0
}

load_board() {
	local f="$SRC/userpatches/boards/$BOARD.conf" v
	[[ -f $f ]] || f="$SRC/config/boards/$BOARD.conf"
	[[ -f $f ]] || die "Unknown board '$BOARD'. Available: $(list_board_names)"
	for v in "${BOARD_VARS[@]}"; do unset "$v"; done
	# shellcheck disable=SC1090
	source "$f"
	for v in "${BOARD_VARS[@]}"; do [[ -n ${!v+x} ]] || printf -v "$v" '%s' ""; done
	: "${BOARD_NAME:=$BOARD}" "${DTS_VENDOR:=rockchip}" "${DTB_MAKE_COND:=CONFIG_ARCH_ROCKCHIP}"
	: "${UBOOT_BIN:=u-boot-rockchip.bin}" "${UBOOT_OFFSET_SECTORS:=64}"
	[[ -n $KERNEL_FAMILY ]] || die "Board $BOARD does not set KERNEL_FAMILY"
	[[ -n $DTB ]] || die "Board $BOARD does not set DTB"
}

# Computed values that depend on the board.
finalize_options() {
	local k v
	[[ -n $KERNEL_LOCALVERSION ]] || KERNEL_LOCALVERSION="-$KERNEL_FAMILY"
	[[ $KERNEL_LOCALVERSION == -* ]] || KERNEL_LOCALVERSION="-$KERNEL_LOCALVERSION"
	[[ -n $IMAGE_HOSTNAME ]] || IMAGE_HOSTNAME=$BOARD
	[[ -n $FLEET_REPO_SUITE ]] || FLEET_REPO_SUITE=$RELEASE
	[[ $UBOOT_VERSION == board ]] && UBOOT_VERSION=${BOARD_UBOOT_VERSION:-latest}
	[[ $TFA_VERSION == board ]] && TFA_VERSION=${BOARD_TFA_VERSION:-latest}
	[[ -n $RKBIN_REPO ]] || RKBIN_REPO=${BOARD_RKBIN_REPO:-https://github.com/rockchip-linux/rkbin.git}
	[[ $PKG_PREFIX =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || die "PKG_PREFIX must be a valid Debian package name prefix"
	# shellcheck disable=SC2034
	[[ $KERNEL_SOURCE == mainline && $KERNEL_ARMBIAN_PATCHES != yes ]] && KERNEL_OVERLAYS=no
	# Resolve relative paths against the directory build.sh was started from, then the builder dir.
	for k in $PATH_OPTS; do
		v=${!k}
		[[ -z $v ]] && continue
		# shellcheck disable=SC2088  # matching a literal "~/" typed into the menu
		[[ $v == "~/"* ]] && v="$(user_home)/${v#\~/}"
		if [[ $v != /* ]]; then
			if [[ -e $ORIG_PWD/$v ]]; then v="$ORIG_PWD/$v"; else v="$SRC/$v"; fi
		fi
		printf -v "$k" '%s' "$v"
	done
	for k in USER_SSH_KEYS ROOT_SSH_KEYS FLEET_REPO_KEY; do
		[[ -z ${!k} || -f ${!k} ]] || die "$k: file not found: ${!k}"
	done
	if [[ $TPL_SOURCE == uboot && $TPL_OPEN != yes ]]; then
		die "TPL_SOURCE=uboot: mainline U-Boot has no open-source DRAM init for $BOARD_NAME. Use TPL_SOURCE=rkbin."
	fi
	if [[ $BL31_SOURCE == tfa && -z $TFA_PLAT ]]; then
		die "BL31_SOURCE=tfa: upstream TF-A has no platform for $BOARD_NAME. Use BL31_SOURCE=rkbin."
	fi
	return 0
}

validate_login() {
	if [[ -z $USER_NAME && -z $ROOT_PASSWORD && -z $ROOT_SSH_KEYS ]]; then
		die "Nobody could log in to this image: set USER_NAME (+ USER_PASSWORD or USER_SSH_KEYS), or ROOT_PASSWORD / ROOT_SSH_KEYS"
	fi
	if [[ -n $USER_NAME && -z $USER_PASSWORD && -z $USER_SSH_KEYS ]]; then
		die "User '$USER_NAME' has neither a password nor SSH keys"
	fi
	[[ -z $USER_NAME || $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid USER_NAME '$USER_NAME'"
}

opt_visible() {
	local cond=${OPT_SHOWIF[$1]}
	[[ -z $cond ]] || eval "$cond"
}

opt_value_display() {
	local k=$1 v=${!1-}
	if [[ ${OPT_TYPE[$k]} == password ]]; then
		[[ -n $v ]] && v="(set)" || v="(none)"
	fi
	[[ -n $v ]] || v="-"
	printf '%s' "$v"
}

list_options() {
	local cat k
	printf '%sOption tree%s  (current value, then choices; indented = only shown when relevant)\n' "$CB" "$C0"
	for cat in "${CATEGORIES[@]}"; do
		printf '\n%s%s%s\n' "$CB" "$cat" "$C0"
		for k in "${OPT_KEYS[@]}"; do
			[[ ${OPT_CAT[$k]} == "$cat" ]] || continue
			local ind="  "
			[[ -n ${OPT_SHOWIF[$k]} ]] && ind="    "
			printf '%s%-24s = %-22s' "$ind" "$k" "$(opt_value_display "$k")"
			[[ -n ${OPT_CHOICES[$k]} ]] && printf ' [%s]' "${OPT_CHOICES[$k]// /|}"
			[[ ${OPT_TYPE[$k]} == bool ]] && printf ' [yes|no]'
			[[ ${OPT_TYPE[$k]} == board ]] && printf ' [%s]' "$(list_board_names | sed 's/ $//; s/ /|/g')"
			printf '\n%s    %s%s%s\n' "$ind" "$CC" "${OPT_DESC[$k]}" "$C0"
		done
	done
	printf '\nAlso accepted: %s\n' "$EXTRA_KEYS"
}
