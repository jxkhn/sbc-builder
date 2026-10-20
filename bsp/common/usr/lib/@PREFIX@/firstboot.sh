#!/bin/sh
# One-time setup on the first boot of a freshly flashed image:
#   grow the root partition, set the hostname, create SSH host keys, run local hooks.
set -u
STAMP=/var/lib/@PREFIX@/firstboot.done
[ -e "$STAMP" ] && exit 0

GROWFS=yes
HOSTNAME_PATTERN=""
[ -r /etc/default/@PREFIX@-firstboot ] && . /etc/default/@PREFIX@-firstboot

log() { echo "@PREFIX@-firstboot: $*"; }

# 1. Grow root to the whole card
if [ "$GROWFS" = yes ]; then
	src=$(findmnt -n -o SOURCE /)
	disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)
	part=$(cat "/sys/class/block/$(basename "$src")/partition" 2>/dev/null)
	if [ -n "$disk" ] && [ -n "$part" ]; then
		if growpart "/dev/$disk" "$part" >/dev/null 2>&1; then
			log "grew /dev/$disk partition $part"
			resize2fs "$src" >/dev/null 2>&1 && log "resized $src"
		fi
	fi
fi

# 2. Hostname from pattern, e.g. zero3e-{MAC} -> zero3e-a1b2c3
if [ -n "$HOSTNAME_PATTERN" ]; then
	mac=""
	for n in /sys/class/net/*; do
		name=$(basename "$n")
		[ "$name" = lo ] && continue
		[ -e "$n/device" ] || continue
		[ -e "$n/wireless" ] && continue
		mac=$(tr -d ':\n' <"$n/address")
		break
	done
	[ -n "$mac" ] || mac=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
	suffix=$(printf '%s' "$mac" | tail -c 6)
	hn=$(printf '%s' "$HOSTNAME_PATTERN" | sed "s/{MAC}/$suffix/g")
	echo "$hn" >/etc/hostname
	echo "$hn" >/proc/sys/kernel/hostname
	if grep -q '^127\.0\.1\.1' /etc/hosts; then
		sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$hn/" /etc/hosts
	else
		printf '127.0.1.1\t%s\n' "$hn" >>/etc/hosts
	fi
	log "hostname set to $hn"
fi

# 3. SSH host keys (removed from the image so every board gets its own)
if [ -x /usr/bin/ssh-keygen ] && ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
	ssh-keygen -A >/dev/null && log "SSH host keys generated"
fi

# 4. Local hooks: executables in /etc/@PREFIX@/firstboot.d/
for f in /etc/@PREFIX@/firstboot.d/*; do
	[ -f "$f" ] && [ -x "$f" ] && { log "running $f"; "$f" || log "$f failed"; }
done

mkdir -p "${STAMP%/*}"
date -Is >"$STAMP"
systemctl disable @PREFIX@-firstboot.service >/dev/null 2>&1 || true
exit 0
