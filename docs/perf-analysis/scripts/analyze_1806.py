import json, re, os

log = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-22-23\notion-logs\diagnostic-20261009-180606.txt"

CODE = {
    "刷机全攻略，root 、面具 、xp框架安装心得": 5,
    "[]热点机-脚本": 0,
    "【全】邮箱账号数据": 7,
    "[]出租房物品放置的位置": 0,
    "图床app开发": 2,
}
MEDIA = {"刷机全攻略，root 、面具 、xp框架安装心得": 6, "[]热点机-脚本": 1,
         "【全】邮箱账号数据": 2, "[]出租房物品放置的位置": 0, "图床app开发": 0}

rows = []
cur = None
for line in open(log, encoding="utf-8", errors="replace"):
    m = re.search(r"open page:\s*([0-9a-f]+).*?title=(.+?)\s*$", line)
    if m:
        cur = m.group(2).strip(); continue
    if "page perf:" in line:
        g = lambda k: (re.search(rf'"{k}":(\d+)', line) or [None, None])[1]
        rows.append({
            "title": cur, "res": int(g("resourceCount")), "kb": int(g("totalKB")),
            "totalMs": int(g("totalMs")), "ttfb": int(g("ttfb")),
            "dcl": int(g("domContentLoaded")), "load": int(g("loadComplete")),
            "code": CODE.get(cur, "?"), "media": MEDIA.get(cur, "?"),
        })

print("=== 本轮实测（同一 App 会话，17:55~18:05）===\n")
print(f"{'笔记':26} {'code':>4} {'img':>4} {'res':>5} {'KB':>6} {'ttfb':>6} {'DCL':>6} {'load':>7} {'totalMs':>9}")
print("-" * 92)
for r in rows:
    print(f"{r['title'][:24]:26} {str(r['code']):>4} {str(r['media']):>4} {r['res']:>5} {r['kb']:>6} {r['ttfb']:>6} {r['dcl']:>6} {r['load']:>7} {r['totalMs']:>9}")

# 按笔记聚合（取每篇最大值=完整加载）
print("\n=== 按笔记聚合（每篇取最完整采样）===")
by = {}
for r in rows:
    by.setdefault(r["title"], []).append(r)
print(f"{'笔记':26} {'code':>4} {'res':>5} {'KB':>6} {'DCL':>6} {'load(s)':>8} {'totalMs':>9}")
print("-" * 76)
for t, rs in by.items():
    best = max(rs, key=lambda x: x["res"])
    print(f"{t[:24]:26} {str(best['code']):>4} {best['res']:>5} {best['kb']:>6} {best['dcl']:>6} {best['load']/1000:>8.1f} {best['totalMs']:>9}")
