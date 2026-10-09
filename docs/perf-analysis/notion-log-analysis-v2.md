# Notion Lite 新版实测复盘（2026-10-09）

> 数据源：`diagnostic-20261009-154820.txt`（3888 行）、`diagnostic-20261009-155143.txt`
> 设备：23049RAD8C，Android SDK 33
> 装的新版：`v0.1.0+1791529403`（build 时间 15:17 前后）

---

## 一、三项改动全部验证通过 ✅

### 1. Cookie 冷启动竞态 —— 修复确认

**证据**：10/9 当天共冷启动 5 次，全部 `space=true user=true`：

```
[09:50:41] 冷启动: v0.1.0+1791449972  → space=true user=true
[14:32:31] 冷启动: v0.1.0+1791449972  → space=true user=true
[15:17:03] 冷启动: v0.1.0+1791529403  → space=true user=true   ← 新版
[15:44:21] 冷启动: v0.1.0+1791529403  → space=true user=true   ← 新版
[15:45:48] 冷启动: v0.1.0+1791530886  → space=true user=true   ← 更新后重启
```

**`token_v2 missing` 在 10/9 段出现 0 次。**
对比历史：9/24 晚出现过 4 次。修复有效。

### 2. `api.github.com` 规则 + 热更新链路 —— 修复确认

**10/9 段 GitHub 403 出现 0 次**（此前历史有多次 `[Update] primary check failed: GitHub API HTTP 403`）。

热更新链路实测健康，两次完整「检测→下载→安装」全成功：

| 时间 | 事件 |
|---|---|
| 15:16:44 | `current=1791449972 latest=1791529403`（发现新版） |
| 15:17:03 | 冷启动 `v0.1.0+1791529403`（装好了） |
| 15:44:22 | `current=1791529403 latest=1791530886`（又发现新版） |
| 15:45:48 | 冷启动 `v0.1.0+1791530886`（装好了） |

### 3. `api.notion.com` TLS 握手失败 —— 消失

**10/9 段 TLS 握手失败 0 次。**
最后一次失败是 `[2026-10-08T21:43:12]`。历史频率约 8 次/2 周，10/9 归零。
（此项目未做专门改动，推测为 `api.github.com` 走代理后，代理链路整体更稳，属连带改善。）

### 4. 性能瀑布采集 —— 成功产出 ✅（新增能力，首次验证）

`NOTION_PERF:` 前缀在日志中成功落盘 4 次，格式正确、数据可用：

```json
{"nav":{"domContentLoaded":320,"loadComplete":0,"ttfb":75},
 "resourceCount":526,"totalKB":9357,"totalMs":167396,
 "domains":[{"host":"app.notion.com","n":504,"kb":9200,"ms":151314}, ...],
 "slowest":[...]}
```

这是本次新装上的探针首次采到数据，**后续所有优化都可以靠它量化。**

---

## 二、新发现的问题（性能瀑布揭示）⚠️

### 问题 A：`http-inputs-notion.splunkcloud.com` 纯浪费，累计 121 秒

**它是 Notion 自己的日志上报端点（Splunk HTTP input）**，不是第三方广告。4 次加载数据：

| 场景 | 请求数 | 传输字节 | 累计耗时 |
|---|---|---|---|
| 1 | 9 | **0 KB** | 8,898 ms |
| 2 | 6 | **0 KB** | 75,685 ms |
| 3 | 9 | **0 KB** | 22,865 ms |
| 4 | 10 | **0 KB** | 14,324 ms |
| **合计** | **34** | **0 KB** | **≈ 121.8 秒** |

第二份日志再加 3 次（13,344 + 7,339 + 78,527 ms），累计再 +99 秒。

**传输 0 字节 = 全部失败**，日志里 15 次 `Failed to connect to splunk`。
它的代价是：
1. 每个失败请求都要**等超时**（单次最长 31.8 秒，出现在 slowest 榜前两位）
2. 占用了 WebView 的并发连接槽位，和正文资源抢
3. **完全零收益** —— 0 字节传出去，没有任何数据成功上报

**建议：在 App 侧 `shouldInterceptRequest` 里加 `splunkcloud.com` 直接返回空响应**（而不是让它超时）。这比订阅层 REJECT 更精准 —— 因为 App 是主动发起的 `fetch`，直接短路掉可以立刻省下那 30 秒超时等待。

### 问题 B：`exp.notion.com` 也在拖时间

| 场景 | 请求数 | 传输 | 耗时 |
|---|---|---|---|
| 1 | 2 | 0 KB | 3,149 ms |
| 2 | 4 | 0 KB | **30,289 ms** |
| 3 | 1 | 0 KB | 3,119 ms |
| 4 | 2 | 0 KB | 759 ms |

同样是 0 字节。`exp.notion.com` 是实验/功能开关域名 —— 和 statsig 同性质，**但它不在当前拦截名单里**。

### 问题 C：Statsig / Amplitude 实际已被拦住（无需处理）

日志里 Statsig 出现 209 次、Amplitude 32 次，看着吓人，但**全部是 JS 层 warn，不是网络请求**：

```
js warn: WARN [Statsig] ...  ← SDK 空转，请求没发出去
js warn: Amplitude Logger [Warn]: Event not tracked, no destination plugins on the instance
```

`no destination plugins` / SDK 内部 warn 恰恰证明**网络层已被切断**，SDK 找不到上报出口。
→ **App 侧拦截有效，订阅层不需要再加 REJECT**（与之前的判断一致）。

---

## 三、正文加载瓶颈（排除埋点后）

剔除 splunk/exp 干扰后，真正影响首屏的是 `app.notion.com` 的 JS：

| 场景 | 资源数 | 总 KB | app.notion.com 耗时 | DOMContentLoaded | TTFB |
|---|---|---|---|---|---|
| 1 | 526 | 9357 | 151,314 ms | 320 ms | 75 ms |
| 2 | 305 | 7268 | 869,054 ms | 9,300 ms | 3,984 ms |
| 3 | 335 | 7237 | 313,102 ms | 2,254 ms | 1,064 ms |
| 4 | 590 | 10766 | 45,903 ms | 422 ms | 15 ms |

**观察**：
- 场景 1 和 4 是好状态：TTFB 15-75 ms，DCL 320-422 ms —— 说明**代理链路通畅时，首屏其实很快**
- 场景 2 是坏状态：TTFB 3,984 ms、app.notion.com 耗时 869 秒（累计）—— 明显是网络抖动/代理节点不好
- `loadComplete` 全是 0，是因为 SPA 的 `load` 事件不触发，正常现象，非缺陷
- 最慢的 JS 单文件可达 3.3 秒（`localeSetup-zh-CN-*.js` 1009 KB）—— 中文字体/文案包偏大

**结论**：正文加载的方差**主要来自网络/节点质量**，不是规则缺失。这与「场景 2 的 TTFB 高达 4 秒」吻合 —— 换节点就好。

---

## 四、行动建议（按性价比排序）

| 优先级 | 动作 | 预期收益 | 改动位置 |
|---|---|---|---|
| **P0** | 拦截 `splunkcloud.com`（返回空响应，不等超时） | 每页省 8-75 秒无效等待 | `BrowserWebViewHolder.kt` `shouldInterceptRequest` |
| **P0** | 拦截 `exp.notion.com` | 每页省 0.7-30 秒 | 同上 |
| P1 | 观察换节点场景，验证 TTFB 是否稳定 < 500ms | 确认正文瓶颈在网络 | 无需改码，多采几次日志 |
| P2 | 中文 locale 包按需加载 | 首屏省 ~3 秒 | 需改 Notion SPA 逻辑，成本高，暂缓 |

**关于是否加到订阅 REJECT**：
- `exp.notion.com` 属于 `notion.com` 后缀，**已经在 `DOMAIN-SUFFIX,notion.com,Notion` 规则里走代理** —— 这就是它慢的原因（走了代理反而慢）。若要拦，得在规则**最前面**加 `DOMAIN-SUFFIX,exp.notion.com,REJECT` 才能覆盖。
- 但更好的做法是 **App 侧短路**（P0 方案），因为 App 是发起方，短路立即生效，不受订阅刷新周期影响。

---

## 五、总评

新版的四项目标**全部达成**，且三项修复在日志中有硬证据（Cookie 0 失败、403 归零、TLS 失败归零）。
性能瀑布探针首次成功产出数据，并立刻定位到一个**此前完全未知的重大浪费源**（splunk 累计 121 秒 / 4 次加载）。

下一步最值得做的是 **P0：拦截 splunk + exp**，预计能把「坏场景」下每页十几秒的无效等待砍掉。
