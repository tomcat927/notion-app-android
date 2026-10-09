import re

log = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-22-23\notion-logs\diagnostic-20261009-180606.txt"
lines = open(log, encoding="utf-8", errors="replace").read().split("\n")

ts_re = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)\+\d+\]")
events = []
cur_ts = None
for i, ln in enumerate(lines):
    m = ts_re.match(ln)
    if m:
        cur_ts = m.group(1)[11:]  # HH:MM:SS.ms
        continue
    if ln.startswith("open page:"):
        t = re.search(r"title=(.+)$", ln)
        events.append((cur_ts, "OPEN", t.group(1).strip() if t else "?"))
    elif ln.startswith("target page committed"):
        events.append((cur_ts, "COMMIT", ""))
    elif ln.startswith("back pressed:"):
        a = re.search(r"action=(\S+)", ln)
        events.append((cur_ts, "BACK", a.group(1) if a else ""))
    elif ln.startswith("page perf:"):
        rc = re.search(r'"resourceCount":(\d+)', ln)
        tm = re.search(r'"totalMs":(\d+)', ln)
        lc = re.search(r'"loadComplete":(\d+)', ln)
        events.append((cur_ts, "PERF", f"res={rc.group(1) if rc else '?'} totalMs={tm.group(1) if tm else '?'} load={lc.group(1) if lc else '?'}"))

print(f"{'时间':14} {'事件':8} 详情")
print("-" * 80)
for ts, ev, d in events:
    print(f"{ts:14} {ev:8} {d}")
