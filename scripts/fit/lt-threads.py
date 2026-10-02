#!/usr/bin/python3
# lt-threads.py CGPROCS N MODEL -- N concurrent agent turns as threads of ONE process, the way
# the gateway runs conversations, on the openai-codex (ChatGPT subscription) login in
# $HERMES_HOME. The process joins the service cgroup first, so its ceiling covers it.
import json, os, sys, threading, time

cgprocs, n, model = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(cgprocs, "w") as f:
    f.write(str(os.getpid()))
sys.path.insert(0, "/usr/lib/hermes-agent/site-packages")
from hermes_cli.runtime_provider import resolve_runtime_provider  # noqa: E402
from run_agent import AIAgent  # noqa: E402

TASK = open(os.environ["LT_TASK"]).read()
rt = resolve_runtime_provider(requested="openai-codex", target_model=model)
results = [None] * n


def one(i):
    t0 = time.time()
    try:
        agent = AIAgent(base_url=rt["base_url"], api_key=rt["api_key"], provider=rt["provider"],
                        api_mode=rt.get("api_mode"), model=model, enabled_toolsets=["terminal"],
                        quiet_mode=True, session_id="lt-%d-%d" % (os.getpid(), i), max_iterations=8)
        out = agent.chat(TASK) or ""
        results[i] = {"i": i, "ok": bool(out.strip()), "s": round(time.time() - t0, 1),
                      "answer": " ".join(out.split())[:200]}
    except Exception as e:  # a failed turn is a result, not a crash of the harness
        results[i] = {"i": i, "ok": False, "s": round(time.time() - t0, 1), "error": repr(e)[:200]}


threads = [threading.Thread(target=one, args=(i,)) for i in range(n)]
for t in threads:
    t.start()
for t in threads:
    t.join()
hwm = 0
with open("/proc/self/status") as f:
    for line in f:
        if line.startswith("VmHWM:"):
            hwm = int(line.split()[1])
print(json.dumps({"ok": sum(1 for r in results if r and r["ok"]), "proc_peak_kb": hwm, "results": results}))
