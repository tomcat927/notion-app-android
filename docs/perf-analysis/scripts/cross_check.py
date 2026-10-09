import json, urllib.request, urllib.error, time, os, re

REPO = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-04-52\notion-mcp-setup"
cfg = json.load(open(os.path.join(REPO, "notion.json"), encoding="utf-8-sig"))
TOKEN = cfg["token"]; VER = cfg.get("notion_version") or "2022-06-28"

def req(path, retries=3):
    r = urllib.request.Request("https://api.notion.com/v1" + path, headers={
        "Authorization": f"Bearer {TOKEN}", "Notion-Version": VER})
    for i in range(retries):
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            return {"__e__": f"HTTP {e.code}"}
        except Exception:
            time.sleep(1)
    return {"__e__": "net"}

def stat(pid, depth=0, acc=None):
    if acc is None: acc = {"code": 0, "media": 0, "total": 0}
    if depth > 6: return acc
    cur = None
    while True:
        res = req(f"/blocks/{pid}/children?page_size=100" + (f"&start_cursor={cur}" if cur else ""))
        if "__e__" in res: break
        for b in res.get("results", []):
            t = b.get("type", "?")
            acc["total"] += 1
            if t == "code": acc["code"] += 1
            if t in ("image","video","file","pdf","audio"): acc["media"] += 1
            if b.get("has_children") and t in ("toggle","column_list","column","synced_block"):
                stat(b["id"], depth+1, acc)
        if not res.get("has_more"): break
        cur = res.get("next_cursor")
    return acc

# 从日志抽出 open page: pageId ... title=
logdir = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-22-23\notion-logs"
opened = {}
for fn in os.listdir(logdir):
    if not fn.endswith(".txt"): continue
    for line in open(os.path.join(logdir, fn), encoding="utf-8", errors="replace"):
        m = re.search(r"open page:\s*([0-9a-f]+).*?title=(.+?)\s*$", line)
        if m:
            pid, title = m.group(1), m.group(2).strip()
            opened[pid] = title

print("=== 日志中被打开过的笔记 × 真实 code block 统计 ===\n")
print(f"{'标题':40} {'code':>5} {'media':>6} {'blocks':>7}  分组")
print("-" * 82)
grp_code, grp_nocode = [], []
for pid, title in opened.items():
    st = stat(pid)
    if st["total"] == 0:
        print(f"{title:40} {'?':>5} {'?':>6} {'?':>7}  未授权/已删")
        continue
    grp = "A-含代码块" if st["code"] > 0 else "B-无代码块"
    (grp_code if st["code"] > 0 else grp_nocode).append((title, st))
    print(f"{title:40} {st['code']:>5} {st['media']:>6} {st['total']:>7}  {grp}")

print()
print(f"【A组 含代码块】{len(grp_code)} 篇 — 平均 {sum(s['code'] for _,s in grp_code)/max(1,len(grp_code)):.1f} 个 code / 篇")
for t, s in grp_code: print(f"   · {t}  (code={s['code']}, total={s['total']})")
print(f"\n【B组 无代码块】{len(grp_nocode)} 篇")
for t, s in grp_nocode: print(f"   · {t}  (code=0, total={s['total']})")
