#!/usr/bin/env bash
#
# Debian SBC image builder
#   mainline kernel + mainline U-Boot + plain Debian (mmdebstrap)
#   -> bootable SD image with no vendor/distro runtime ties.
#
# Usage: sudo ./build.sh                      interactive menu
#        sudo ./build.sh build CONFIG=<name>  non-interactive, from userpatches/config-<name>.conf
#        ./build.sh options                   list every option
#
set -Eeuo pipefail

SRC=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ORIG_PWD=$PWD
export SRC ORIG_PWD

# shellcheck source=lib/common.sh
source "$SRC/lib/common.sh"
# shellcheck source=lib/options.sh
source "$SRC/lib/options.sh"
# shellcheck source=lib/menu.sh
source "$SRC/lib/menu.sh"
# shellcheck source=lib/hostdeps.sh
source "$SRC/lib/hostdeps.sh"
# shellcheck source=lib/kernel.sh
source "$SRC/lib/kernel.sh"
# shellcheck source=lib/uboot.sh
source "$SRC/lib/uboot.sh"
# shellcheck source=lib/bsp.sh
source "$SRC/lib/bsp.sh"
# shellcheck source=lib/rootfs.sh
source "$SRC/lib/rootfs.sh"
# shellcheck source=lib/image.sh
source "$SRC/lib/image.sh"
# shellcheck source=lib/armbian-import.sh
source "$SRC/lib/armbian-import.sh"

ALL_STAGES="kernel uboot bsp rootfs image"

usage() {
	cat <<EOF
${CB}Debian SBC image builder${C0}

Usage: sudo ./build.sh [command] [CONFIG=<name>] [KEY=value ...]

Commands:
  (none)           Interactive menu when run in a terminal, then build
  build            Build without the menu (stages: STAGES="$ALL_STAGES")
  kernel | uboot | bsp | rootfs | image
                   Run a single stage
  armbian-import   Step 2 (optional): import kernel patches, device trees,
                   overlays and kernel config from Armbian's build repo
  options          Show the option tree with defaults and choices
  clean            Remove work/ (build trees, rootfs). clean-all also removes cache/

Configs are plain shell files: userpatches/config-<name>.conf (save them from the menu).
Command-line KEY=value overrides the config file.

Examples:
  sudo ./build.sh
  sudo ./build.sh build CONFIG=zero3e
  sudo ./build.sh build BOARD=radxa-zero3e KERNEL_VERSION=7.2.8 USER_NAME=admin \\
       USER_SSH_KEYS=~/.ssh/id_ed25519.pub
  sudo ./build.sh armbian-import CONFIG=zero3e
  sudo ./build.sh kernel CONFIG=zero3e FORCE=yes
EOF
}

needs_root() {
	local s
	for s in "$@"; do [[ $s == rootfs || $s == image ]] && return 0; done
	return 1
}

run_stage() {
	local s=$1
	check_host_deps "$s"
	info "Stage: $s  [$BOARD]"
	case $s in
		kernel) kernel_stage ;;
		uboot) uboot_stage ;;
		bsp) bsp_stage ;;
		rootfs) rootfs_stage ;;
		image) image_stage ;;
		*) die "Unknown stage '$s' (valid: $ALL_STAGES)" ;;
	esac
}

main() {
	local cmd="" cfg="" a
	local -a kv=()
	for a in "$@"; do
		case $a in
			-h | --help | help) usage; exit 0 ;;
			CONFIG=*) cfg=${a#CONFIG=} ;;
			*=*) kv+=("$a") ;;
			*) [[ -z $cmd ]] && cmd=$a || die "Unexpected argument '$a' (see ./build.sh help)" ;;
		esac
	done

	[[ -n $cfg ]] && load_config "$cfg"
	for a in "${kv[@]}"; do set_option "${a%%=*}" "${a#*=}"; done
	apply_defaults
	[[ -n ${BOARD:-} ]] && load_board

	case $cmd in
		options) list_options; exit 0 ;;
		clean | clean-all)
			info "Removing work/"
			umount_below "$WORK"
			rm -rf --one-file-system "$WORK"
			[[ $cmd == clean-all ]] && { info "Removing cache/"; rm -rf "$CACHE"; }
			exit 0 ;;
		"")
			if [[ -t 0 && -t 1 && ${MENU:-yes} != no ]]; then
				menu_run || exit 0
			fi
			cmd=build ;;
	esac

	[[ -n ${BOARD:-} ]] || die "No board selected. Use BOARD=<name>. Available: $(list_board_names)"
	load_board
	finalize_options

	local -a stages
	case $cmd in
		build) read -r -a stages <<<"${STAGES:-$ALL_STAGES}" ;;
		kernel | uboot | bsp | rootfs | image) stages=("$cmd") ;;
		armbian-import) stages=() ;;
		*) die "Unknown command '$cmd' (see ./build.sh help)" ;;
	esac
	if needs_root "${stages[@]}"; then
		require_root
		validate_login
	fi

	init_dirs
	start_log
	info "Board: $BOARD_NAME | Debian $RELEASE | kernel: $KERNEL_SOURCE ${KERNEL_VERSION:-} | build $BUILD_ID"

	if [[ $cmd == armbian-import ]]; then
		check_host_deps common
		armbian_import
	else
		local s
		for s in "${stages[@]}"; do run_stage "$s"; done
	fi
	own "$OUT" "$SRC/userpatches"
	info "Done. Log: ${LOG_FILE#"$SRC"/}"
}

main "$@"
