# 性能排查交接文档（HANDOFF）

> **给下一个会话/设备的 Agent：** 本文是 Notion Android App「笔记加载慢 / 代码块加载慢」排查的完整交接。
> 请**先读完本文**，再动手。所有结论都有日志实证，不要凭直觉推翻。

最后更新：2026-10-09 18:47（北京时间）

---

## 0. 一句话现状

**结论已定：代码块不是慢的原因；瓶颈是 Clash 代理链路的"集体 stall"。**
**下一步待做：改 `cf-pref-sub-gen/server.py` 给 `app.notion.com` 加独立策略，然后用 adb 自测验证是否改善。**

---

## 1. 项目背景

用户有一个自研的 Android Notion 客户端 `notion-app-android`（Flutter + WebView 壳），
配套一个 Cloudflare 优选订阅生成器 `cf-pref-sub-gen`。

**App 的本质**：只是 WebView 容器。页面渲染、代码块语法高亮**全部由 Notion 官方 SPA 完成**，
App 内**没有任何**代码块渲染逻辑（已全库搜索 `code_block`/`prism`/`highlight`/`shiki`/`monaco`/`codemirror`，零命中）。

---

## 2. 已确认的结论（有实证，勿推翻）

### 2.1 代码块与"慢"无关

用**同一 App 会话**内交替访问含/不含代码块的 5 篇笔记（2026-10-09 18:06 实测）：

| 笔记 | code 数 | 资源数 | totalMs |
|---|---|---|---|
| 刷机全攻略 | 5 | 352 | 148,933 |
| []热点机-脚本 | 0 | 831 | 125,009 |
| 【全】邮箱账号数据 | 7 | 270 | 26,608 |
| **[]出租房物品放置** | **0** | **983** | **1,496,369** |
| 图床app开发 | 2 | 995 | 1,225,555 |

**无代码块的笔记资源反而最多（983 vs 270）。**

### 2.2 决定性证据：「集体 stall」

多个**互不相关**的请求在毫秒级窗口内以**几乎相同**的耗时返回 = 链路停顿后同时恢复。
这不是"某个资源慢"能产生的模式。

最严重的一次发生在 **code=0** 的笔记上：

```
[]出租房物品放置的位置（code=0）— stall 42.9 秒
  82852-*.js                = 42,991ms
  getTranscriptionUsage     = 42,973ms
  getEduVerificationData    = 42,886ms
  getCustomerOffersReceived = 42,885ms
  getSubscriptionBanner     = 42,879ms   ← 5 个请求相差仅 112ms
```

### 2.3 网络状况波动极大

| 轮次 | `syncRecordValue` 超时次数 |
|---|---|
| 17:13 轮 | **244 次**（3 秒内爆发） |
| 18:06 轮 | **18 次** |

即便在"较好"的 18:06 轮，仍有 42.9s / 69.5s 的 stall → **代理链路是主要变量**。

---

## 3. 关键技术事实

| 项 | 值 |
|---|---|
| **Clash 订阅真正生效处** | `cf-pref-sub-gen/server.py` 的 `build_clash()`（rules 段） |
| **注意** | 改 `notion-app-android/docs/clash-rules.md` **不生效**！那只是说明文档 |
| **部署方式** | 无 CI，手工 scp + `systemctl restart cf-pref-sub-gen` |
| **服务器** | `root@119.91.136.173:22`（密钥见 ssh-mcp-setup 仓库的 `tencent_ssh.pem`） |
| **部署路径** | `/opt/cf-pref-sub-gen/server.py` |
| **出站代理组名** | **`🚀节点选择`**（不是 `Notion`） |
| **订阅地址** | `https://119.91.136.173:9443/clash` |
| **日志路径** | `/data/openlist/notion-app/logs/install-e67405c2eea6/` |

### 3.1 `DOMAIN-SUFFIX` 匹配陷阱（踩过）

`DOMAIN-SUFFIX,github.com` **匹配不到** `api.github.com`。必须单列，且排在主域名之前。

### 3.2 日志机制（已确认）

- `notion_app_debug.log`（Dart 层）：`FileMode.append` 追加，无上限
- `notion_app_native_crash.log`（NativeCrash + BrowserWebView）：`appendText` 追加，
  >256KB 时 NativeCrash 清空重写 / BrowserWebView 保留后半段
- **崩溃重启不丢日志**；上传是只读（`readLogs()` 不删本地）
- ⚠️ **日志文件是全量历史 + 按原始时间追加** → 同一文件混杂多个 App 版本，
  **必须按时间戳切分版本**，`awk NR>=行号` 会误纳旧记录

### 3.3 性能探针（`BrowserActivity.kt` 的 `PERF_COLLECT_SCRIPT`）

- 在 `onBrowserPageFinished` 注入，`setTimeout(run, 5000)` 首次采样
- 采集 `performance.getEntriesByType('resource')`，按域名聚合 + top10 slowest
- 输出格式：`page perf: {"nav":{...},"resourceCount":N,...,"slowest":[...]}`
- 局限：只采 2 次（5s + 一次延迟），无法追踪"页面加载完成后才有的事件"

### 3.4 App 已拦截的域名（`BrowserWebViewHolder.kt`）

```kotlin
private val BLOCKED_HOSTS = listOf(
    "api.amplitude.com", "prod.web-sdk.amplitude.com",
    "api.statsig.com", "featuregates.org",
    "splunkcloud.com",   // 实测省下 121.8s
    "exp.notion.com",    // 单次最长省 30s
)
```
实测效果：splunk 单次 78,527ms → 3,582ms（-95%）；exp 95,995ms → 802ms（-99%）。

### 3.5 已修复的 bug（`edb1f6f`）

返回键在历史仍指向同一笔记时直接退出。**不要回退此改动。**

---

## 4. 下一步工作（按优先级）

### P0 — 给 `app.notion.com` 加独立策略（待做）

**目标**：验证"专属节点/直连"能否减少 stall。

1. clone `cf-pref-sub-gen`，改 `server.py` 的 `build_clash()`
2. 在 rules 段**前置**加一条针对 `app.notion.com` 的策略（选低延迟节点或 DIRECT）
3. 部署：
   ```bash
   scp server.py root@119.91.136.173:/opt/cf-pref-sub-gen/server.py.new
   # SSH 进去：
   cp server.py server.py.bak-$(date +%s) && mv server.py.new server.py \
     && rm -rf __pycache__ && systemctl restart cf-pref-sub-gen
   ```
4. 验证订阅渲染：`curl -k https://119.91.136.173:9443/clash | grep app.notion.com`
5. **然后用新设备的 adb 跑同一套清单自测，对比 stall 是否减少**

### P1 — 探针增强

现在只能采 2 次。建议增加：
- `syncRecordValue` 的成功/失败/耗时分布（P50/P95）
- "页面上有多少 block 长时间未渲染" → 直接验证代码块是否真延迟
- 文件：`android/app/src/main/kotlin/com/notion/app/BrowserActivity.kt`（`PERF_COLLECT_SCRIPT`）

### P2 — 补样本

3 篇页面读不到 block（Notion API 返回 404 `object_not_found`，"未授权"非"不存在"）：
- 京东云路由器刷机（t. 26804cb8350380269d35f74bff7a6f59）
- 测试777（3f404cb83503818dba7ddb14ad2ea146）
- 远程日志专用openlist账号密码（3ea04cb8350380b0b9b9cac0dee23138）

需在 Notion 页面的"Connections"里给集成授权，才能读 blocks。

---

## 5. 复现实验：标准测试清单

**在同一 App 会话内**依次访问（含/不含代码块交替）：

| 顺序 | 笔记 | 真实 code | 真实 img |
|---|---|---|---|
| ① | 刷机全攻略，root 、面具 、xp框架安装心得 | 5 | 6 |
| ② | []热点机-脚本 | 0 | 1 |
| ③ | 【全】邮箱账号数据 | 7 | 2 |
| ④ | []出租房物品放置的位置 | 0 | 0 |
| ⑤ | 图床app开发 | 2 | 0 |

**每篇动作**：点进 → 等完全加载 → 滑到底部 → 返回。

---

## 6. 工具与环境

### 6.1 用 Notion API 读真实 block 数

凭据在 `notion-mcp-setup` 仓库（`notion.json`，含 token）。脚本见
`docs/perf-analysis/scripts/verify_blocks_all.py`。

```python
GET /v1/blocks/{page_id}/children?page_size=100   # 递归下钻 toggle/column
统计 type == "code" 的块数
```

### 6.2 用 adb 采集设备日志

仓库已有工具：`tools/collect_android_crash_logs.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\collect_android_crash_logs.ps1 -Clear -Follow
# 复现问题后 Ctrl+C
powershell -ExecutionPolicy Bypass -File tools\collect_android_crash_logs.ps1
```
输出在 `artifacts\adb-crash-logs\YYYYMMDD-HHMMSS`。

### 6.3 ⚠️ AGENTS.md 硬约束

**本仓库不要安装 Flutter/Android/Gradle，不要本地编译。编译验证交给 GitHub Actions。**
（adb 采集设备日志是允许的，见 `docs/adb-crash-logs.md`）

### 6.4 拉远程日志

```bash
scp -i <ssh-mcp-setup>/tencent_ssh.pem \
  root@119.91.136.173:/data/openlist/notion-app/logs/install-e67405c2eea6/<file> ./
```
方向：**SSH 直连读文件，不要走 OpenList API**（有 429 限流）。

---

## 7. 相关仓库

| 仓库 | 用途 |
|---|---|
| `tomcat927/notion-app-android` | App 本体（本仓库） |
| `tomcat927/cf-pref-sub-gen` | Clash 订阅生成器（**改规则在这里**） |
| `tomcat927/ssh-mcp-setup` | 服务器凭据（servers.json + tencent_ssh.pem） |
| `tomcat927/notion-mcp-setup` | Notion API 凭据（读 block 用） |

---

## 8. 已有分析产物（本目录）

```
docs/perf-analysis/
├── HANDOFF.md                          ← 本文
├── notion-codeblock-perf-analysis.md   ← v1/v2 对照分析（含修订说明）
├── notion-codeblock-test-v3.md         ← v3 用户实测轮报告（最新）
├── notion-log-analysis.md              ← 第一轮日志分析
├── notion-log-analysis-v2.md           ← 新版实测复盘
├── notion-log-analysis-v3.md           ← 第二轮复盘（拦截对比 + 返回栈 bug）
├── scripts/
│   ├── verify_blocks.py / verify_blocks_all.py   ← 读真实 block 数
│   ├── cross_check.py / correlate.py             ← 交叉对照
│   ├── timeline_1806.py / latency_1806.py         ← 时序对齐
│   └── analyze_1806.py / stall_1806.py            ← 实测轮分析 + stall 检测
└── logs/
    └── perf-evidence-20261009-1806.txt  ← 【本轮实测】脱敏证据（perf 采样 + 关键事件）
```

> ⚠️ **原始日志未入库**：完整 `diagnostic-*.txt` 含个人笔记标题（`loadRecentPages` 的 debug 输出里），
> 为避免个人内容进 git 历史，只保留了脱敏摘录。
> 需要完整日志时，用 §6.4 的命令从服务器重新拉取（服务器上保留全部原始文件）。

---

## 9. 方法论教训（避免重蹈覆辙）

1. **断言"某页面含/不含 X"前，必须读真实数据** —— 标题推测 60% 会错。
2. **修 UI 交互 bug 要在"交互发生的那一刻"判定**，不要依赖事后异步检测/补偿。
3. **验证修复要看"新代码独有特征"**（如新增的日志字段），而非笼统看行为。
4. **日志分析要按时间戳切分版本**，行号切分不可靠。
5. **改 Clash 规则要改 `server.py`**，不是文档。
