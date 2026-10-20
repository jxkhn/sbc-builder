# shellcheck shell=bash
# whiptail/dialog front-end over the option registry in options.sh.

DIALOG=${DIALOG:-}
BACKTITLE="Debian SBC image builder  -  mainline kernel + mainline U-Boot + plain Debian"

_dlg() { "$DIALOG" --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

menu_init() {
	if [[ -z $DIALOG ]]; then
		if command -v whiptail >/dev/null; then DIALOG=whiptail
		elif command -v dialog >/dev/null; then DIALOG=dialog
		else die "The menu needs whiptail (apt install whiptail). Or run non-interactively: ./build.sh build KEY=value ..."; fi
	fi
	if [[ $DIALOG == whiptail ]]; then OKL=--ok-button CANL=--cancel-button; else OKL=--ok-label CANL=--cancel-label; fi
	local lines cols
	lines=$(tput lines 2>/dev/null || echo 24)
	cols=$(tput cols 2>/dev/null || echo 80)
	MH=$((lines - 4 > 26 ? 26 : lines - 4))
	MW=$((cols - 4 > 110 ? 110 : cols - 4))
	ML=$((MH - 8))
}

category_summary() {
	local cat=$1 k out=() n=0
	for k in "${OPT_KEYS[@]}"; do
		[[ ${OPT_CAT[$k]} == "$cat" ]] || continue
		opt_visible "$k" || continue
		out+=("$(opt_value_display "$k")")
		n=$((n + 1))
		((n >= 3)) && break
	done
	local s
	s=$(printf '%s | ' "${out[@]}")
	s=${s% | }
	((${#s} > MW - 30)) && s="${s:0:$((MW - 33))}..."
	printf '%s' "$s"
}

menu_run() {
	menu_init
	local choice i cat
	while true; do
		local items=()
		i=0
		for cat in "${CATEGORIES[@]}"; do
			i=$((i + 1))
			items+=("$i" "$(printf '%-16s %s' "$cat" "$(category_summary "$cat")")")
		done
		items+=("" "" "S" "Save configuration..." "L" "Load configuration..." "B" ">>> Build" "Q" "Quit")
		local title="Board: ${BOARD_NAME:-<none selected>}"
		[[ -n ${CONFIG_NAME:-} ]] && title+="   Config: $CONFIG_NAME"
		choice=$(_dlg --title " Debian SBC image builder " $OKL Select $CANL Quit \
			--menu "$title\n\nPick a section to change its options." "$MH" "$MW" "$ML" "${items[@]}") || return 1
		case $choice in
			"") ;;
			[0-9]*) menu_category "${CATEGORIES[$((choice - 1))]}" ;;
			S) menu_save ;;
			L) menu_load ;;
			B) menu_build && return 0 ;;
			Q) return 1 ;;
		esac
	done
}

menu_category() {
	local cat=$1 k choice
	while true; do
		local items=()
		for k in "${OPT_KEYS[@]}"; do
			[[ ${OPT_CAT[$k]} == "$cat" ]] || continue
			opt_visible "$k" || continue
			local label=$k
			[[ -n ${OPT_SHOWIF[$k]} ]] && label="  $k"
			items+=("$label" "$(opt_value_display "$k")")
		done
		[[ $cat == "Armbian import" ]] && items+=("" "" ">> RUN" "Import now (needs network)")
		choice=$(_dlg --title " $cat " $OKL Change $CANL Back \
			--menu "Indented options depend on the one above them." "$MH" "$MW" "$ML" "${items[@]}") || return 0
		choice=${choice# }
		choice=${choice# }
		case $choice in
			"") ;;
			">> RUN") menu_armbian_import ;;
			*) edit_option "$choice" ;;
		esac
	done
}

edit_option() {
	local k=$1 cur=${!1-} new desc=${OPT_DESC[$1]} c d
	case ${OPT_TYPE[$k]} in
		choice | board)
			local list=()
			if [[ ${OPT_TYPE[$k]} == board ]]; then
				while IFS='|' read -r c d; do
					list+=("$c" "$d" "$([[ $c == "$cur" ]] && echo ON || echo OFF)")
				done < <(list_boards)
			else
				for c in ${OPT_CHOICES[$k]}; do
					list+=("$c" "" "$([[ $c == "$cur" ]] && echo ON || echo OFF)")
				done
			fi
			new=$(_dlg --title " $k " --radiolist "$desc" "$MH" "$MW" "$ML" "${list[@]}") || return 0
			[[ -n $new ]] || return 0
			;;
		bool)
			local def=()
			[[ $cur == no ]] && def=(--defaultno)
			if _dlg --title " $k " "${def[@]}" --yes-button yes --no-button no --yesno "$desc\n\nCurrent: $cur" 12 "$MW"; then
				new=yes
			else
				new=no
			fi
			;;
		string)
			new=$(_dlg --title " $k " --inputbox "$desc" 12 "$MW" "$cur") || return 0
			;;
		password)
			local p1 p2
			p1=$(_dlg --title " $k " --passwordbox "$desc\n\n(empty = clear)" 12 "$MW") || return 0
			if [[ -n $p1 ]]; then
				p2=$(_dlg --title " $k " --passwordbox "Repeat" 10 "$MW") || return 0
				if [[ $p1 != "$p2" ]]; then
					_dlg --msgbox "Passwords do not match." 8 40
					return 0
				fi
				new=$(hash_password "$p1")
			else
				new=""
			fi
			;;
	esac
	printf -v "$k" '%s' "$new"
	[[ $k == BOARD && -n $new ]] && load_board
	return 0
}

menu_save() {
	local name
	name=$(_dlg --title " Save configuration " --inputbox \
		"Name (saved as userpatches/config-<name>.conf):" 10 "$MW" "${CONFIG_NAME:-${BOARD:-default}}") || return 0
	if [[ ! $name =~ ^[A-Za-z0-9._-]+$ ]]; then
		_dlg --msgbox "Use letters, digits, . _ - only." 8 50
		return 0
	fi
	as_user mkdir -p "$SRC/userpatches"
	save_config "$SRC/userpatches/config-$name.conf"
	CONFIG_NAME=$name
	_dlg --msgbox "Saved userpatches/config-$name.conf\n\nRebuild later without the menu:\n  sudo ./build.sh build CONFIG=$name" 12 "$MW"
}

menu_load() {
	local list=() f n
	for f in "$SRC"/userpatches/config-*.conf; do
		[[ -f $f ]] || continue
		n=$(basename "$f" .conf)
		n=${n#config-}
		list+=("$n" "" OFF)
	done
	if ((${#list[@]} == 0)); then
		_dlg --msgbox "No saved configurations in userpatches/." 8 50
		return 0
	fi
	n=$(_dlg --title " Load configuration " --radiolist "Choose:" "$MH" "$MW" "$ML" "${list[@]}") || return 0
	[[ -n $n ]] || return 0
	load_config "$n"
	apply_defaults
	[[ -n $BOARD ]] && load_board
	return 0
}

menu_armbian_import() {
	if [[ -z $BOARD ]]; then
		_dlg --msgbox "Select a board first." 8 40
		return 0
	fi
	clear
	(
		finalize_options
		init_dirs
		check_host_deps common
		armbian_import
	) || true
	read -r -p "Press Enter to return to the menu" _ </dev/tty
	if [[ $KERNEL_ARMBIAN_PATCHES != yes ]] && _dlg --yesno "Apply the imported Armbian patches in kernel builds?\n(Kernel > KERNEL_ARMBIAN_PATCHES)" 10 "$MW"; then
		KERNEL_ARMBIAN_PATCHES=yes
	fi
}

menu_build() {
	if [[ -z $BOARD ]]; then
		_dlg --msgbox "Select a board first (Target > BOARD)." 8 50
		return 1
	fi
	local sel s list=()
	for s in $ALL_STAGES; do
		local d
		case $s in
			kernel) d="compile kernel -> .deb (skipped if inputs unchanged)" ;;
			uboot) d="compile U-Boot -> .deb" ;;
			bsp) d="board support package (firstboot, zram, motd, boot config)" ;;
			rootfs) d="Debian rootfs with mmdebstrap (needs root)" ;;
			image) d="partition + bootloader -> .img (needs root)" ;;
		esac
		list+=("$s" "$d" ON)
	done
	sel=$(_dlg --title " Build " --separate-output --checklist "Stages to run:" "$MH" "$MW" "$ML" "${list[@]}") || return 1
	STAGES=$(echo "$sel" | tr '\n' ' ')
	[[ -n ${STAGES// /} ]] || return 1
	if _dlg --yesno "Save this configuration before building?" 8 60; then menu_save; fi
	clear
	return 0
}
