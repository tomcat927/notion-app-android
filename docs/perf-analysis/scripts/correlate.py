import json, re, os

logdir = r"C:\Users\Administrator\WorkBuddy AI\2026-10-09-14-22-23\notion-logs"

# 真实 code block 数（前面 MCP 查得）
CODE = {
    "刷机全攻略，root 、面具 、xp框架安装心得": 5,
    "京东云路由器刷机": None,
    "远程日志（OpenList）": 1,
    "测试777": None,
    "6666": None,
    "远程日志专用openlist 账号密码": None,
    "notion token": 1,
    "【全】邮箱账号数据": 7,
    "[]cloudflare的Account ID和API Token.cf令牌": 5,
    "imgink-uploader 签名密钥备份": 3,
    "图床app开发": 2,
    "自动短信获取验证码": 2,
    "宽带 ipv6问题处理": 1,
    "Notion 数据导出避坑指南": 0,
    "[]热点机-脚本": 0,
    "网易云app开发": 0,
    "Android安卓.长截图": 0,
    "[]出租房物品放置的位置": 0,
    "智谱ai使用": 0,
}

# 逐文件按行序，把 open page 与后续 page perf 配对
rows = []
for fn in sorted(os.listdir(logdir)):
    if not fn.endswith(".txt"): continue
    cur_title = None
    cur_pid = None
    for line in open(os.path.join(logdir, fn), encoding="utf-8", errors="replace"):
        m = re.search(r"open page:\s*([0-9a-f]+).*?title=(.+?)\s*$", line)
        if m:
            cur_pid, cur_title = m.group(1), m.group(2).strip()
            continue
        if "page perf:" in line:
            rc = re.search(r'"resourceCount":(\d+)', line)
            kb = re.search(r'"totalKB":(\d+)', line)
            tm = re.search(r'"totalMs":(\d+)', line)
            lc = re.search(r'"loadComplete":(\d+)', line)
            if rc and tm:
                rows.append({
                    "file": fn[-12:-4], "title": cur_title, "pid": cur_pid,
                    "res": int(rc.group(1)), "kb": int(kb.group(1)) if kb else 0,
                    "totalMs": int(tm.group(1)),
                    "loadComplete": int(lc.group(1)) if lc else 0,
                    "code": CODE.get(cur_title, "?") if cur_title else "?",
                })

# 去重（同一批采样在多个文件重复）
seen = set(); uniq = []
for r in rows:
    key = (r["res"], r["kb"], r["totalMs"])
    if key in seen: continue
    seen.add(key); uniq.append(r)

print(f"{'文件':10} {'标题':30} {'code':>4} {'res':>5} {'KB':>6} {'totalMs':>9} {'load':>7}")
print("-" * 82)
for r in uniq:
    t = (r["title"] or "?")[:28]
    print(f"{r['file']:10} {t:30} {str(r['code']):>4} {r['res']:>5} {r['kb']:>6} {r['totalMs']:>9} {r['loadComplete']:>7}")

# 分组统计（只看有 code 数的）
A = [r for r in uniq if isinstance(r["code"], int) and r["code"] > 0]
B = [r for r in uniq if isinstance(r["code"], int) and r["code"] == 0]
def avg(xs, k): return sum(x[k] for x in xs) / len(xs) if xs else 0
print()
print(f"【A组 含代码块】n={len(A)}  平均 res={avg(A,'res'):.0f} KB={avg(A,'kb'):.0f} totalMs={avg(A,'totalMs'):.0f}")
print(f"【B组 无代码块】n={len(B)}  平均 res={avg(B,'res'):.0f} KB={avg(B,'kb'):.0f} totalMs={avg(B,'totalMs'):.0f}")
