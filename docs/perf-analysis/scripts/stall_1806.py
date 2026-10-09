import re

log = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-22-23\notion-logs\diagnostic-20261009-180606.txt"

# 提取每篇的完整 slowest（判断是否有"集体同耗时"的 stall 特征）
print("=== 完整采样的 slowest：找'集体同耗时'特征 ===\n")
lines = open(log, encoding="utf-8", errors="replace").read().split("\n")
import json
for i, ln in enumerate(lines):
    if "page perf:" not in ln: continue
    m = re.search(r"page perf:\s*(\{.*\})", ln)
    if not m: continue
    try:
        d = json.loads(m.group(1))
    except Exception:
        continue
    sl = d.get("slowest", [])
    ms = [x["ms"] for x in sl]
    # 判断是否有 3+ 个请求耗时相近（±5%）= 集体 stall
    stall = False
    if len(ms) >= 3:
        top = ms[:5]
        if max(top) - min(top) < max(top) * 0.05 and min(top) > 10000:
            stall = True
    print(f"L{i+1:5} res={d['resourceCount']:>4} KB={d['totalKB']:>6} totalMs={d['totalMs']:>9}  "
          f"{'⚠ 集体stall' if stall else ''}")
    if stall:
        print(f"        前5慢: {[x['file'][:40]+'='+str(x['ms']) for x in sl[:5]]}")
