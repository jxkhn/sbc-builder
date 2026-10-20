# shellcheck shell=bash
# Shared helpers.

CACHE=${CACHE:-$SRC/cache}   # downloads, git checkouts (safe to keep between builds)
WORK=${WORK:-$SRC/work}      # build trees, rootfs (disposable)
OUT=${OUT:-$SRC/output}      # packages, images, logs

if [[ -t 2 ]]; then
	C0=$'\e[0m' CB=$'\e[1m' CR=$'\e[31m' CG=$'\e[32m' CY=$'\e[33m' CC=$'\e[36m'
else
	C0='' CB='' CR='' CG='' CY='' CC=''
fi

info() { printf '%s==>%s %s%s%s\n' "$CG" "$C0" "$CB" "$*" "$C0" >&2; }
step() { printf '%s  ->%s %s\n' "$CC" "$C0" "$*" >&2; }
warn() { printf '%sWARN:%s %s\n' "$CY" "$C0" "$*" >&2; }
die() {
	printf '%sERROR:%s %s\n' "$CR" "$C0" "$*" >&2
	exit 1
}
trap 'die "command failed (exit $?) at ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}"' ERR

is_root() { [[ $EUID -eq 0 ]]; }
require_root() { is_root || die "Building the rootfs/image needs root. Re-run with sudo."; }

invoking_user() { [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] && echo "$SUDO_USER"; }

# Run as the user who invoked sudo, so caches and build trees stay user-owned.
as_user() {
	local u
	if is_root && u=$(invoking_user); then
		sudo -u "$u" -H -- "$@"
	else
		"$@"
	fi
}

# Workaround for the uutils (Rust coreutils) `install -D` race, default on Ubuntu 26.04+
# (LP: #2151166, uutils/coreutils#12355): parallel `install -D` calls sharing a parent
# directory fail with "cannot create directory". The kernel's dtbs_install does exactly
# that. Canonical serialises dtbs_install in their own kernels; we put a retrying
# `install` first in PATH instead, so the rest of the build stays parallel.
# Prints the directory to prepend to PATH (empty when not needed). INSTALL_SHIM=yes|no|auto
install_shim_dir() {
	local real dir
	real=$(command -v install) || return 0
	case ${INSTALL_SHIM:-auto} in
		no) return 0 ;;
		auto) "$real" --version 2>&1 | head -n1 | grep -qi uutils || return 0 ;;
	esac
	dir="$WORK/shims"
	as_user mkdir -p "$dir"
	cat >"$dir/install.tmp" <<EOF
#!/bin/sh
# Retry wrapper around $real - see install_shim_dir() in lib/common.sh
n=0
while :; do
	if err=\$("$real" "\$@" 2>&1); then
		[ -n "\$err" ] && printf '%s\n' "\$err" >&2
		exit 0
	fi
	n=\$((n + 1))
	if [ \$n -ge 5 ]; then
		printf '%s\n' "\$err" >&2
		exit 1
	fi
	sleep 0.\$n
done
EOF
	chmod 755 "$dir/install.tmp"
	mv "$dir/install.tmp" "$dir/install"
	own "$dir"
	echo "$dir"
}

# Hand files created by root back to the invoking user.
own() {
	local u
	if is_root && u=$(invoking_user); then chown -R "$u:" "$@" 2>/dev/null || true; fi
}

user_home() {
	local u
	if u=$(invoking_user); then getent passwd "$u" | cut -d: -f6; else echo "$HOME"; fi
}

confirm() {
	local a
	(: </dev/tty) 2>/dev/null || return 1
	read -r -p "$1 [y/N] " a </dev/tty || return 1
	[[ $a == [yY]* ]]
}

# arm64 is the only target; cross-compile unless we're on arm64 already.
if [[ -z ${CROSS_COMPILE+x} ]]; then
	if [[ $(uname -m) == aarch64 ]]; then CROSS_COMPILE=""; else CROSS_COMPILE="aarch64-linux-gnu-"; fi
fi

BUILD_ID=${BUILD_ID:-$(date -u +%Y%m%d%H%M)}

init_dirs() {
	local d
	for d in "$CACHE" "$WORK" "$OUT" "$OUT/logs" "$OUT/debs" "$OUT/images" "$SRC/userpatches"; do
		[[ -d $d ]] || as_user mkdir -p "$d"
	done
}

start_log() {
	LOG_FILE="$OUT/logs/build-${BOARD}-${BUILD_ID}.log"
	exec > >(tee -a "$LOG_FILE") 2>&1
}

# hash_inputs <string>... -- <file-or-dir>...
# Fingerprint of everything that feeds a stage, used to skip unchanged rebuilds.
hash_inputs() {
	local strings=1 a
	{
		for a in "$@"; do
			if [[ $a == -- ]]; then strings=0; continue; fi
			if ((strings)); then
				printf 's:%s\n' "$a"
			elif [[ -d $a ]]; then
				printf 'd:%s\n' "$a"
				find "$a" -type f -print0 | sort -z | xargs -0 -r sha256sum
			elif [[ -f $a ]]; then
				printf 'f:%s\n' "$a"
				sha256sum <"$a"
			else
				printf 'none:%s\n' "$a"
			fi
		done
	} | sha256sum | cut -c1-16
}

stamp_ok() { [[ ${FORCE:-no} != yes && -f $1 && $(<"$1") == "$2" ]]; }
stamp_write() { printf '%s\n' "$2" >"$1"; own "$1"; }

# resolve_git_tag <repo> <regex> <wanted>   ("latest" -> highest tag matching regex)
resolve_git_tag() {
	local repo=$1 re=$2 want=$3 t
	if [[ $want != latest ]]; then
		echo "$want"
		return 0
	fi
	t=$(git ls-remote --tags --refs "$repo" | sed 's#.*refs/tags/##' | grep -E "$re" | sort -V | tail -n1) || true
	[[ -n $t ]] || die "Could not resolve the latest tag of $repo"
	echo "$t"
}

# git_fetch_tag <repo> <tag> <dest>  (shallow, cached)
git_fetch_tag() {
	local repo=$1 tag=$2 dest=$3
	[[ -d $dest/.git ]] && return 0
	step "Fetching $repo @ $tag"
	rm -rf "$dest.tmp"
	as_user mkdir -p "${dest%/*}"
	as_user git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$repo" "$dest.tmp"
	as_user mv "$dest.tmp" "$dest"
}

# build_deb <staging-dir> <output-file>; staging must contain DEBIAN/control.
# Files under /etc become conffiles.
build_deb() {
	local stage=$1 out=$2
	(cd "$stage" && { find etc -type f 2>/dev/null || true; } | sed 's#^#/#' | sort) >"$stage/DEBIAN/conffiles"
	[[ -s $stage/DEBIAN/conffiles ]] || rm -f "$stage/DEBIAN/conffiles"
	chmod 0755 "$stage/DEBIAN"
	local f
	for f in preinst postinst prerm postrm; do [[ -f $stage/DEBIAN/$f ]] && chmod 0755 "$stage/DEBIAN/$f"; done
	dpkg-deb --root-owner-group -Zxz --build "$stage" "$out" >/dev/null
	own "$out"
}

umount_below() {
	local dir=$1 m
	[[ -d $dir ]] || return 0
	dir=$(readlink -f "$dir")
	while read -r m; do
		[[ -n $m ]] && umount -l "$m" 2>/dev/null || true
	done < <(awk -v d="$dir/" 'index($2, d) == 1 {print $2}' /proc/mounts | sort -r)
}
