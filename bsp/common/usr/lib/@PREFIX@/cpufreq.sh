#!/bin/sh
# Apply the CPU frequency governor from /etc/default/@PREFIX@-cpufreq to every policy.
GOVERNOR=default
[ -r /etc/default/@PREFIX@-cpufreq ] && . /etc/default/@PREFIX@-cpufreq
[ "$GOVERNOR" = default ] && exit 0
modprobe -q "cpufreq_$GOVERNOR" 2>/dev/null || true
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -w "$p/scaling_governor" ] || continue
	if grep -qw "$GOVERNOR" "$p/scaling_available_governors"; then
		echo "$GOVERNOR" >"$p/scaling_governor"
	else
		echo "governor $GOVERNOR not available for $(basename "$p")" >&2
	fi
done
exit 0
