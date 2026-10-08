#!/bin/sh
# router_check.sh -- the router's numbers for the hourly watch in docs/use.md.
#
# Copy it to /srv/hermes/scripts/router_check.sh. A scheduled job runs it as the user hermes and
# hands its output to the model in one call, so it prints plain lines and needs no tool.
# Edit TARGETS for the hosts you care about.
TARGETS=${TARGETS:-"1.1.1.1 $(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"}

echo "time: $(date '+%Y-%m-%d %H:%M %Z')"
for t in $TARGETS; do
	out=$(ping -c 3 -W 2 "$t" 2>&1)
	loss=$(echo "$out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
	avg=$(echo "$out" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
	if [ -n "$loss" ]; then
		echo "ping $t: loss ${loss}%, average ${avg:-n/a} ms"
	else
		echo "ping $t: failed: $(echo "$out" | tail -n 1)"
	fi
done
if nslookup openwrt.org >/dev/null 2>&1; then echo "dns: openwrt.org resolves"; else echo "dns: openwrt.org does NOT resolve"; fi
awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "memory: %d MB available of %d MB\n", a/1024, t/1024}' /proc/meminfo
df -m / | awk 'NR==2 {print "flash: " $4 " MB free of " $2 " MB"}'
for z in /sys/class/thermal/thermal_zone*/temp; do
	[ -r "$z" ] && awk '{printf "temperature: %.1f C\n", $1/1000}' "$z" && break
done
echo "uptime: $(uptime | sed 's/^ *//')"
