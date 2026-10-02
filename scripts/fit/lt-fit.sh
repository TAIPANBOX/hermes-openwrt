#!/bin/sh
# lt-fit.sh MODEL [COUNTS] -- how many Hermes agents fit next to the running gateway, two ways:
#   threads: N conversations as threads of one process (how the gateway serves a chat)
#   procs:   N separate agents, each its own `hermes chat` process and Python interpreter
# Everything joins the hermes-agent service cgroup, so the service's memory ceiling
# (mem_max_mb) is what is being filled, never the router's own services.
# Needs: /tmp/lt-home with an openai-codex login, lt-threads.py and lt-sampler.sh beside it.
MODEL=${1:-gpt-5.6-luna}; COUNTS=${2:-"1 2 3 4"}
D=$(cd "$(dirname "$0")" && pwd); OUT=$D/out; mkdir -p "$OUT"
export HERMES_HOME=/tmp/lt-home HERMES_DISABLE_LAZY_INSTALLS=1 PYTHONDONTWRITEBYTECODE=1 LT_TASK=$D/task.txt
cat > "$LT_TASK" <<'T'
You are on an OpenWrt router. Using the terminal tool, find out the uptime, the 1-minute load average, MemAvailable from /proc/meminfo, the default route, and how many dnsmasq processes run. Run the commands, do not guess. Answer in two lines.
T
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT/steps.log"; }
gw() { for p in $(pgrep -f 'gateway run'); do tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q 'main.py gateway run' && { echo $p; return; }; done; }

say "modes ${MODES:-threads procs}, mem_max_mb $(uci -q get hermes.main.mem_max_mb); router $(cat /proc/sys/kernel/hostname), $(apk list -I 2>/dev/null | grep -o '^hermes-agent-[0-9.r-]*' | head -1), model $MODEL, counts $COUNTS"
/etc/init.d/hermes-agent start
i=0; while [ -z "$(gw)" ] && [ $i -lt 90 ]; do sleep 1; i=$((i + 1)); done
G=$(gw); [ -n "$G" ] || { say "NO GATEWAY"; exit 1; }
CG=/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/$G/cgroup)
say "gateway pid $G in $CG, memory.max $(cat $CG/memory.max); settling 60 s"
sleep 60
say "gateway at rest: RSS $(awk '/VmRSS/{print int($2/1024)}' /proc/$G/status) MB, cgroup $(( $(cat $CG/memory.current) / 1048576 )) MB, MemAvailable $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MB"
sed -i "s#^CG=.*#CG=$CG#" "$D/lt-sampler.sh"
(setsid sh "$D/lt-sampler.sh" "$OUT/samples.csv" </dev/null >/dev/null 2>&1 &)
# Guard (LT_GUARD_MB, default 120): when MemAvailable falls below it, kill the test agents
# (never the gateway) before the kernel has to pick a victim among the router's services.
GUARD_KB=$(( ${LT_GUARD_MB:-120} * 1024 ))
(setsid sh -c 'while :; do a=$(awk "/^MemAvailable:/{print \$2}" /proc/meminfo); if [ "$a" -lt "$1" ]; then for p in $(pgrep -f "[h]ermes_cli/main.py chat|[l]t-threads.py"); do kill -9 $p; done; echo "$(date +%s) $a" >> "$2/guard.txt"; fi; usleep 300000 2>/dev/null || sleep 1; done' x "$GUARD_KB" "$OUT" </dev/null >/dev/null 2>&1 &)

for mode in ${MODES:-threads procs}; do for n in $COUNTS; do
	tag=$mode-$n; t0=$(date +%s); oom0=$(awk '/^oom_kill /{print $2}' $CG/memory.events)
	kl0=$(dmesg | grep -c -i 'out of memory')
	if [ $mode = threads ]; then
		python3 "$D/lt-threads.py" "$CG/cgroup.procs" "$n" "$MODEL" > "$OUT/$tag.json" 2> "$OUT/$tag.err"
		ok=$(sed -n 's/^{"ok": \([0-9]*\).*/\1/p' "$OUT/$tag.json")
	else
		k=1; while [ $k -le $n ]; do
			sh -c 'echo $$ > "$1/cgroup.procs"; shift; exec hermes chat --run-budget 300 -q "$(cat "$LT_TASK")" -Q --oneshot --provider openai-codex -m "$1" -t terminal --max-turns 8' \
				x "$CG" "$MODEL" > "$OUT/$tag.$k.out" 2> "$OUT/$tag.$k.err" &
			k=$((k + 1)); done
		wait; ok=0; k=1; while [ $k -le $n ]; do [ -s "$OUT/$tag.$k.out" ] && ok=$((ok + 1)); k=$((k + 1)); done
	fi
	t1=$(date +%s)
	echo "$tag $t0 $t1 ${ok:-0} $(( $(awk '/^oom_kill /{print $2}' $CG/memory.events) - oom0 )) $(( $(dmesg | grep -c -i 'out of memory') - kl0 )) $([ "$(gw)" = "$G" ] && echo same || echo gone:$(gw))" >> "$OUT/runs.txt"
	say "$tag: $((t1 - t0)) s, ${ok:-0}/$n answered"
	sleep 30
done; done
kill $(pgrep -f lt-sampler.sh) $(pgrep -f "while :; do a=") 2>/dev/null
/etc/init.d/hermes-agent stop
say "done, gateway stopped"
python3 - "$OUT" <<'PY' | tee "$OUT/summary.txt"
import csv, sys
d = sys.argv[1]
rows = list(csv.DictReader(open(f"{d}/samples.csv")))
for line in open(f"{d}/runs.txt"):
    tag, t0, t1, ok, cgoom, kmsg, gw = line.split()
    w = [r for r in rows if int(t0) <= int(r["t"]) <= int(t1)]
    num = lambda k: [int(r[k]) for r in w if r[k].lstrip("-").isdigit()]
    cg, av, tc = num("cg_mem"), num("memavail_kb"), num("temp_mc")
    n = int(tag.split("-")[1])
    g = [l.split() for l in open(f"{d}/guard.txt")] if __import__("os").path.exists(f"{d}/guard.txt") else []
    gf = sum(1 for x in g if int(t0) <= int(x[0]) <= int(t1))
    print(f"{tag}: guard fired {gf}x, wall {int(t1) - int(t0)} s, {ok}/{n} answered, all of Hermes (cgroup) peak "
          f"{max(cg) // 1048576 if cg else '-'} MB, MemAvailable low {min(av) // 1024 if av else '-'} MB, "
          f"cgroup OOM kills {cgoom}, kernel OOM lines {kmsg}, gateway {gw}, temp max {max(tc) / 1000 if tc else '-'} C")
PY
