import json, sys, urllib.request, urllib.error, time, os

REPO = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-04-52\notion-mcp-setup"
cfg = json.load(open(os.path.join(REPO, "notion.json"), encoding="utf-8-sig"))
TOKEN = cfg["token"]
VER = cfg.get("notion_version") or "2022-06-28"

def req(path, method="GET", payload=None, version=None, retries=3):
    url = path if path.startswith("http") else "https://api.notion.com/v1" + path
    data = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Notion-Version": version or VER,
        "Content-Type": "application/json",
    })
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            return {"__error__": f"HTTP {e.code}: {e.read().decode('utf-8','replace')[:200]}"}
        except Exception as e:
            last = e; time.sleep(1)
    return {"__error__": str(last)}

# 统计每个页面的 block 类型（递归）
def stat_blocks(bid, depth=0, acc=None, maxdepth=6):
    if acc is None:
        acc = {"code": 0, "image": 0, "text": 0, "total": 0, "by_type": {}}
    if depth > maxdepth:
        return acc
    cursor = None
    children = []
    while True:
        q = f"/blocks/{bid}/children?page_size=100"
        if cursor:
            q += f"&start_cursor={cursor}"
        res = req(q)
        if "__error__" in res:
            acc.setdefault("errors", []).append(res["__error__"])
            break
        children.extend(res.get("results", []))
        if not res.get("has_more"):
            break
        cursor = res.get("next_cursor")
    for b in children:
        t = b.get("type", "?")
        acc["total"] += 1
        acc["by_type"][t] = acc["by_type"].get(t, 0) + 1
        if t == "code":
            acc["code"] += 1
        elif t in ("image", "video", "file", "pdf"):
            acc["image"] += 1
        if b.get("has_children") and t in ("toggle", "column_list", "column", "synced_block", "template"):
            stat_blocks(b["id"], depth + 1, acc, maxdepth)
    return acc

PAGES = {
    "223d47e84ecd45aa94058fb8c53f9177": "刷机全攻略，root、面具、xp框架安装心得",
    "26804cb8350380269d35f74bff7a6f59": "京东云路由器刷机",
    "3f404cb83503818dba7ddb14ad2ea146": "测试777",
    "3ea04cb8350381ebb6b4c410ed8976ea": "远程日志（OpenList）",
    "3ec04cb83503811baa1de3af07eacc83": "Notion 数据导出避坑指南",
    "33704cb83503807ba24be49ee816d9f7": "[]热点机-脚本",
    "3df04cb8350380199e9fdb9be6b4f5c7": "网易云app开发",
    "3ec04cb835038001b67ff333ddbe7bb8": "图床app开发",
}

print(f"{'pageId':34} {'标题':30} {'code':>5} {'img':>5} {'total':>6}")
print("-" * 90)
for pid, title in PAGES.items():
    st = stat_blocks(pid)
    if "errors" in st and st["total"] == 0:
        # 页面可能未授权，尝试作为 page 读取标题
        info = req(f"/pages/{pid}")
        note = info.get("__error__", "?")[:40] if "__error__" in info else "ok"
        print(f"{pid:34} {title:30} {'ERR':>5} {'-':>5} {'-':>6}   {note}")
        continue
    disp = title
    print(f"{pid:34} {disp:30} {st['code']:>5} {st['image']:>5} {st['total']:>6}")
    # 打印 code block 的语言分布
    if st["code"] > 0:
        print(f"    └ by_type: {json.dumps(st['by_type'], ensure_ascii=False)}")
