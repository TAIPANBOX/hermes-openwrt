#!/bin/sh
# lt-clean.sh "SERVICES" COUNTS -- run lt-fit.sh (separate agents, no ceiling) with the
# router's non-OpenWrt services stopped, then start again exactly those that were running.
SVC=$1; COUNTS=${2:-"1 2 3 4 5"}
D=$(cd "$(dirname "$0")" && pwd)
was=""
for s in $SVC; do
	[ -x /etc/init.d/$s ] || continue
	ubus call service list "{\"name\":\"$s\"}" 2>/dev/null | grep -q '"running": true' && was="$was $s"
done
echo "$was" > "$D/stopped-services.txt"
restore() { for s in $was; do /etc/init.d/$s start; done; echo "$(date +%H:%M:%S) restarted:$was" >> "$D/clean.log"; }
trap restore EXIT INT TERM
for s in $was; do /etc/init.d/$s stop; done
sleep 5
echo "$(date +%H:%M:%S) stopped:$was; MemAvailable $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MB; left:$(for p in $(ls /proc | grep -E '^[0-9]+$'); do r=$(awk '/^VmRSS/{print $2}' /proc/$p/status 2>/dev/null); [ -n "$r" ] && [ "$r" -gt 3000 ] && printf ' %s=%sM' "$(cat /proc/$p/comm)" $((r / 1024)); done)" >> "$D/clean.log"
MODES=procs sh "$D/lt-fit.sh" gpt-5.6-luna "$COUNTS"
