#!/bin/sh
# lt-sampler.sh OUT -- one CSV line a second until killed:
# epoch, cpu user nice system idle iowait irq softirq (jiffies), MemAvailable kB,
# load1, temp mC, hermes cgroup memory.current, its oom_kill count, softnet drops.
CG=/sys/fs/cgroup/services/hermes-agent/instance1
OUT=$1
echo "t,user,nice,sys,idle,iowait,irq,softirq,memavail_kb,load1,temp_mc,cg_mem,cg_oom_kill,softnet_drop" > "$OUT"
while :; do
	set -- $(head -1 /proc/stat)
	cpu="$2,$3,$4,$5,$6,$7,$8"
	ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
	l1=$(cut -d' ' -f1 /proc/loadavg)
	tc=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo -)
	cm=$(cat $CG/memory.current 2>/dev/null || echo -)
	ok=$(awk '/^oom_kill /{print $2}' $CG/memory.events 2>/dev/null || echo -)
	sd=$(awk '{s += ("0x" $2) + 0} END {print s + 0}' /proc/net/softnet_stat 2>/dev/null)
	echo "$(date +%s),$cpu,$ma,$l1,$tc,$cm,$ok,$sd" >> "$OUT"
	sleep 1
done
