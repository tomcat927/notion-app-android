import json, urllib.request, urllib.error, time, os

REPO = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-04-52\notion-mcp-setup"
cfg = json.load(open(os.path.join(REPO, "notion.json"), encoding="utf-8-sig"))
TOKEN = cfg["token"]; VER = cfg.get("notion_version") or "2022-06-28"

def req(path, retries=3):
    url = "https://api.notion.com/v1" + path
    r = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {TOKEN}", "Notion-Version": VER})
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            return {"__e__": f"HTTP {e.code}"}
        except Exception as e:
            last = e; time.sleep(1)
    return {"__e__": str(last)}

def stat(pid, depth=0, acc=None):
    if acc is None:
        acc = {"code": 0, "media": 0, "total": 0, "types": {}, "err": None}
    if depth > 6:
        return acc
    cur = None; kids = []
    while True:
        q = f"/blocks/{pid}/children?page_size=100" + (f"&start_cursor={cur}" if cur else "")
        res = req(q)
        if "__e__" in res:
            if acc["total"] == 0:
                acc["err"] = res["__e__"]
            break
        kids.extend(res.get("results", []))
        if not res.get("has_more"):
            break
        cur = res.get("next_cursor")
    for b in kids:
        t = b.get("type", "?")
        acc["total"] += 1
        acc["types"][t] = acc["types"].get(t, 0) + 1
        if t == "code":
            acc["code"] += 1
        if t in ("image", "video", "file", "pdf", "audio"):
            acc["media"] += 1
        if b.get("has_children") and t in ("toggle", "column_list", "column", "synced_block"):
            stat(b["id"], depth + 1, acc)
    return acc

# 日志中出现过的全部页面
PAGES = {
    "223d47e84ecd45aa94058fb8c53f9177": "刷机全攻略，root、面具、xp框架安装心得",
    "26804cb8350380269d35f74bff7a6f59": "京东云路由器刷机",
    "3f404cb83503818dba7ddb14ad2ea146": "测试777",
    "3ea04cb8350381ebb6b4c410ed8976ea": "远程日志（OpenList）",
    "3ea04cb8350380b0b9b9cac0dee23138": "远程日志专用openlist账号密码(已删)",
    "3ec04cb83503811baa1de3af07eacc83": "Notion 数据导出避坑指南",
    "33704cb83503807ba24be49ee816d9f7": "[]热点机-脚本",
    "3df04cb8350380199e9fdb9be6b4f5c7": "网易云app开发",
    "3ec04cb835038001b67ff333ddbe7bb8": "图床app开发",
    "1f504cb8350380bbb413f7ce7ce2955f": "Android安卓.长截图",
    "2ea0c22bf73f4a288951f2a9177df92a": "【全】邮箱账号数据",
    "2f804cb8350380b488eadcddd4308323": "[]出租房物品放置的位置",
    "36904cb8350380cebdf9d1d839f0dd01": "[]cloudflare的Account ID和API Token",
    "3ac04cb835038012b8f8fe9310d4d1e3": "notion token",
    "3ec04cb8350380239667cb84a254dc10": "智谱ai使用",
    "3f004cb83503803e80c5dd2c1eaff0b7": "ipv6 / 宽带 ipv6问题处理",
    "3f104cb83503807a9e7fd1a80271ba7d": "自动短信获取验证码",
    "3ec04cb8350381c7a8b4df8738ebbba3": "imgink-uploader 签名密钥备份",
    "3f404cb8350381e1bc7bd77bae9bf46f": "6666",
}

rows = []
for pid, title in PAGES.items():
    st = stat(pid)
    rows.append((title, st))

print(f"{'标题':38} {'code':>5} {'media':>6} {'total':>6}  {'状态'}")
print("-" * 78)
for title, st in sorted(rows, key=lambda r: -r[1]["code"]):
    if st["err"]:
        print(f"{title:38} {'-':>5} {'-':>6} {'-':>6}  {st['err']}(未授权/已删)")
    else:
        mark = "  ★含代码块" if st["code"] > 0 else ""
        print(f"{title:38} {st['code']:>5} {st['media']:>6} {st['total']:>6}{mark}")

ok = [s for _, s in rows if not s["err"]]
print()
print(f"可读页面: {len(ok)}/{len(rows)}")
print(f"含 code block 的页面: {sum(1 for s in ok if s['code']>0)}")
print(f"code block 总数: {sum(s['code'] for s in ok)}")
