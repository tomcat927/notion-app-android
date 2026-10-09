# Notion App 日志分析与代理优化报告

> 生成时间：2026-10-09
> 数据来源：腾讯云服务器 `/data/openlist/notion-app/logs/install-e67405c2eea6/`
> 分析样本：`diagnostic-20261008-155551.txt`（10月8日，2877 行）+ 10月8日 10:40 一份
> 配合分析：`notion-app-android` 源码（commit `42ea632`）、`cf-pref-sub-gen` 订阅仓库

---

## 零、先纠正三个认知误区

### 1. 日志不需要 OpenList API —— SSH 直连即可读取

我最初尝试登录 OpenList（5245）拉日志，连续用错密码触发了它的**应用层 429 限流**。但这是 OpenList 自己的登录保护，与服务器 fail2ban 完全无关。

**关键事实**：日志文件的真实路径是 `/data/openlist/notion-app/logs/install-e67405c2eea6/`，
通过 SSH（`tencent-ssh.pem`）直连服务器 `cat`/`sftp get` 就能读，**完全绕过 OpenList 登录**。

> 以后拉日志直接用 SSH，别再走 OpenList API —— 那条路既有登录限流，又只多了个无谓的中间层。

### 2. fail2ban 没有封禁你 —— 我这次 SSH 全程成功

- 你的出口 IP `182.42.224.90` **不在任何 ban 列表**
- fail2ban 服务 `active`，共 **10 个 jail** 正常工作
- SSH 登录走的是 **publickey**（`tencent_ssh.pem`），不是密码 —— 密码爆破类封禁天然碰不到你

### 3. 服务器上有 **3 套独立封禁机制**（不是一套）

| 层 | 机制 | 端口 | 当前封禁 |
|---|---|---|---|
| A | **YJ-FIREWALL-INPUT**（手工链，独立于 fail2ban） | 22 | `77.91.71.92`、`124.40.252.3` |
| B | fail2ban `sshd-bruteforce` / `sshd-conn` | 22 | 3 个 + 1 个 IP |
| C | fail2ban `sub2api-auth` system | 8080 | **652 个 IP**（API 被爆破，与 SSH 无关） |

**A 层最危险**：它不在 `fail2ban-client status` 里，排查封禁时最容易漏掉。若哪天你 SSH 突然连不上，务必先查 `iptables -L YJ-FIREWALL-INPUT -n`。

---

## 一、日志揭示的真实问题（比"域名漏网"严重得多）

### 问题 1：Notion API 的 TLS 握手**间歇性失败**（8 次/2周）

```
[HTTP] api.notion.com TLS 握手失败，500ms 后进行第 2 次连接:
       HandshakeException: Connection terminated during handshake
```

- 时间点：09-25、09-29×2、10-04×2、10-08×3
- **10月8日一天内就发生 3 次**（10:13、10:13、10:17）
- 这是 `api.notion.com` 直连被 TLS 层中断 —— **典型的代理链路不稳定**（不是域名没覆盖）

### 问题 2：Cookie 提取失败 → 搜索降级（**仅冷启动，已修复**）

```
[WebSession] token_v2 missing in cookie manager;
             available: cf_redirect_migration,__ps_r,...,_cfuvid,__cf_bm
[PrivateSearch] search(http) failed, fallback to webview: Bad state: 需要登录 Notion
```

> **⚠️ 修正（2026-10-09 复查）**：此项**原先被高估**。精确定量后：
> - `loaded from storage: space=true user=true` → **277 次（96%，正常）**
> - `loaded from storage: space=false user=false` → 15 次
> - `token_v2 missing` → **仅 4 次，且全部集中在 9/24 首日晚 15:23–16:42**，此后 2 周未再出现
> - `refreshed from cookie manager` → 1 次，且**成功**（拿到了完整 cookie 含 token_v2）
>
> **真实性质**：不是持续缺陷，而是**冷启动竞态**——`home_screen.dart` 里 `_prewarmWebSession()`（读 cookie）
> 与 `prewarmWebView()`（加载 notion.so 写 cookie）**并发执行**，刷新常早于 cookie 落盘 → 读到空。
> 首次登录时最明显（本地存储 + WebView cookie 都是空的）。
>
> **已修复**（commit `c1aa27c`）：改为先触发预热 WebView → 等 3s 让 cookie 落盘 → 再读；
> `private_search_screen.dart` 冷启动直进搜索页也加了同样防护。
>
> **残留影响**：弱网下 3s 可能仍不够（走 `refreshFromCookieManager` 兜底，会再失败一次才降级）。

### 问题 3：搜索 API 返回 403（17 次）

```
[PrivateSearch] http error: 403 url=[URL]   ← 17 次
[PrivateSearch] http error: 500 url=[URL]   ← 2 次
```

`app.notion.com/api/v3/search` 被 403 —— 大概率是 Cookie 不全 / Cloudflare 校验。

### 问题 4：热更新域名解析到**回环地址**

```
[Update] manifest check failed: Connection refused, address = 127.57.44.31, port=41530
[Update] primary check failed: Exception: GitHub API HTTP 403   ← api.github.com 被限流
[Update] download/verify failed: Exception: SHA-256 校验失败
[Update] manifest check failed: TimeoutException after 0:00:20
```

- `127.57.44.31` 是 **Clash fake-ip 段**，不是公网 IP → 说明当时 **Clash 没开或代理残留**
- `api.github.com HTTP 403` → **GitHub API 限流**（未认证的匿名请求限制 60次/小时）
- 这印证了上次分析：`api.github.com` **不在你的 Clash 规则里**，走「漏网之鱼」更容易触发限流

### 问题 5：UI 事件循环卡顿（Watchdog）

```
[Watchdog] UI 事件循环卡顿: 1502339ms   ← 25 分钟
[Watchdog] UI 事件循环卡顿: 1525152ms
[Watchdog] UI 事件循环卡顿: 1383859ms
```

> ⚠️ 这些"百万毫秒"数值**不是真的卡顿** —— 对照 `[Lifecycle] AppLifecycleState.paused`，
> 这是 **App 被切到后台挂起**的时长，Watchdog 把挂起时间误记成了"卡顿"。
> 真正的卡顿是 `[Watchdog]` 中 2000–4000ms 的那些（10-08 13:52–13:53 连续 6 次）。

**建议**：Watchdog 应在 `AppLifecycleState.paused` 时暂停计时，否则日志里全是噪音，掩盖真实卡顿。

---

## 二、回答你的原始三问

### Q1：还有哪些域名没覆盖？

**结论：核心域名已覆盖，缺口很小。** 基于源码（权威）+ 日志（实证）：

| 域名 | 用途 | 现有规则 | 建议 |
|---|---|---|---|
| `notion.com` / `notion.so` | 页面、API | ✅ | 保持 |
| `app.notion.com` | 内部 v3 API | ⚠️ 日志显示曾落「漏网之鱼」 | **必须确认已命中** |
| `notionusercontent.com` / `notion-static.com` | 图片、静态 | ✅ | 保持 |
| `gh-proxy.com` / `github.com` | 热更新 | ⚠️ 曾落「漏网之鱼」 | 确认命中 |
| **`api.github.com`** | 热更新查版本 | ❌ **缺失** | **补上**（已实证 403） |
| `objects.githubusercontent.com` / `release-assets.githubusercontent.com` | 下载 APK | ✅ | 保持 |
| `transcend-cdn.com` / `splunkcloud.com` | 合规/日志上报 | ❌ | 可选，加速可加 |

**无需担心"漏网域名"** —— 日志反复出现的是"规则配置没生效"（落到漏网之鱼），不是"新域名不知道"。**把那 3 个 Notion 域名 + `api.github.com` 配准，比找新域名重要得多。**

### Q2：哪些请求可以 ban？

源码已在 `BrowserWebViewHolder.kt` 硬编码拦截 4 个埋点域名。**建议下沉到 Clash 全局 REJECT**：

```yaml
# 确定性拦截（App 已代码级验证安全）
DOMAIN-SUFFIX,amplitude.com,REJECT
DOMAIN-SUFFIX,statsig.com,REJECT
DOMAIN-SUFFIX,featuregates.org,REJECT
```

**效果**：DNS/连接层就断，省掉 WebView 拦截器的 TLS 握手开销。
**注意**：`statsig` / `amplitude` 是 A/B 实验和功能开关，ban 掉**理论上有极小概率**影响 Notion 灰度功能。你已在 App 内 ban 了 2 周无异常，风险可控。

> ⚠️ 但**别指望这个能大幅提速** —— 埋点请求很小，ban 掉省的是几十 KB。

### Q3：有没有必要采集更多日志？

**有必要，但方向要改 —— 采"页面加载瀑布"，不是"更多域名"。**

现状：日志**信息量已经很大**（2877 行/次），但**没有一项记录页面加载耗时分解**。

**建议加采集**（这是真正有用的）：

```
1. BrowserActivity: onPageStarted / onPageFinished / onReceivedTitle 时间戳
   → 已有部分，建议结构化输出「open→finish 耗时」

2. JS 注入 performance.getEntriesByType('resource')
   → 采集每个资源的：域名、大小、耗时
   → 这才能告诉你「哪个域名/资源最拖后腿」

3. 记录 FCP（首次内容渲染）和 DOMContentLoaded
```

**不需要**采集的：全量连接日志（你已有域名清单，重复采集只是噪音）。

---

## 三、优先级行动清单

| 优先级 | 行动 | 收益 | 成本 |
|---|---|---|---|
| **P0** | Clash 补 `api.github.com` + 确认 `app.notion.com`/`gh-proxy.com` 命中 | 修热更新失败 | 5 分钟 |
| **P0** | 排查 `api.notion.com` TLS 握手失败（换节点/测长连接） | 修 API 间歇中断 | 10 分钟 |
| **P1** | Clash 加 `amplitude/statsig/featuregates` REJECT | 减埋点流量 | 5 分钟 |
| **P1** | 修 Cookie 提取（`token_v2 missing` → 搜索降级） | 搜索提速 | 需改码 |
| **P2** | 加 `performance.getEntriesByType` 瀑布采集 | 拿到真实瓶颈 | 需改码 |
| **P2** | Watchdog 在 paused 时暂停计时 | 去日志噪音 | 需改码 |

---

## 四、日志拉的 3 条可行路径（备忘）

```bash
# 路径 1：SSH 直连读文件（推荐，无限流）
# 凭据：tencent_ssh.pem，119.91.136.173:22，root
sftp root@119.91.136.173:/data/openlist/notion-app/logs/install-e67405c2eea6/*.txt

# 路径 2：OpenList API（有 429 限流，不推荐）
# https://119.91.136.173:5245/api/fs/list  （需先登录，账号 logger）

# 路径 3：App 内手动上传（用户操作）
# App → 设置 → 远程日志 → 上传
```

**最新日志**：`diagnostic-20261008-155551.txt`（10月8日 15:55）
