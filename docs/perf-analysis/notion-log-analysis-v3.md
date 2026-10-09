# Notion Lite 第二轮实测复盘（2026-10-09 16:18 日志）

> 数据源：`diagnostic-20261009-161842.txt`（约 4900 行，全量历史 9/24 ~ 10/9）  
> 新版：`v0.1.0+1791532889`，冷启动于 `2026-10-09T16:15:53`  
> 拦截验证分界线：日志行号 4206（新版装后首次 perf 采样）



---

## 一、拦截改动效果显著 ✅

新增 `blockedLog` 节流日志已生效，日志中可见 **7 条** `blocked request`（每 20 次打一条，累计 121+ 次拦截）。

### 关键性能对比（同一天、同一设备、新版 vs 旧版）

| 指标              | 旧版（未拦截）    | 新版（已拦截）       | 降幅         |
| --------------- | ---------- | ------------- | ---------- |
| splunk 单次最长     | 78,527 ms  | **3,582 ms**  | **-95.4%** |
| splunk 累计       | 220,982 ms | **12,585 ms** | **-94.3%** |
| exp.notion 单次最长 | 95,995 ms  | **802 ms**    | **-99.2%** |
| exp.notion 累计   | 135,718 ms | **3,720 ms**  | **-97.3%** |

**解读**：耗时从"秒/十秒级干等超时"降到"毫秒级"，说明请求被短路在本地、根本没发出去。  
残余的 800ms-3.5s 是 Notion SPA 自身的重试/等待逻辑开销（非网络），已达此方案上限。

**注意**：新版装后 splunk/exp 仍出现在 perf 的 `domains` 列表里，这是**正常的** —  
`shouldInterceptRequest` 返回空响应，请求仍会被 Resource Timing 记录，只是不再走网络。  
判断依据应是**耗时数量级**（8 万 ms → 3 千 ms），而非"是否出现"。

---

## 二、新发现：删除笔记后返回键钻回已删页面 🐛（已修复）

### 用户描述

把笔记移入垃圾箱后，SPA 容器自动跳到列表视图；此时点 App 右上角返回按钮，  
会先进入**刚刚删除的笔记页面**，再点一次返回才回到 App 页签。

### 日志佐证（完美复现）

```
[16:18:37.738] [Lifecycle] app state: inactive
[16:18:37.800] [Lifecycle] app state: resumed
[16:18:38.402] [Home] 返回后刷新单条记录: reason=browser_return pageId=[UUID]
[16:18:40.860] [Home] 检测到记录已删除并从列表移除: reason=browser_return:page_response pageId=3ea04cb8350380b0b9b9cac0dee23138

back pressed: action=goBack  canGoBack=true  loadingPageId=3ea0...3138   ← 第一次：钻回已删笔记
back pressed: action=finish  canGoBack=false loadingPageId=3ea0...3138   ← 第二次：才退出
```

### 根因分析

1. 用户删除笔记 → Notion SPA 内部 `pushState` 跳到列表视图
2. WebView 历史栈变成 `[笔记页] → [列表视图]`
3. 用户点返回 → `canGoBack=true` → `goBack()` → **回到已删笔记页**
4. 代码侧 `BrowserActivity.onBackPressed`（第 90-93 行）：
   ```kotlin
   if (currentWebView != null && !isPageLoadPending && canGoBack) {
       currentWebView.goBack()   // ← 钻回已删页面
       return
   }
   finish()
   ```

**为什么现有清历史逻辑没兜住**：  
`onBrowserPageFinished` 里有 `view.clearHistory()`，但它**只在 `loadUrl` 加载完成后触发**。  
SPA 内部的 `pushState` 不触发 `onPageFinished`，所以删除产生的历史条目无人清理。

### 修复（commit `a0149ef`）

删除检测确认后，Dart 主动通知原生清空历史栈：

| 层                         | 改动                                                            |
| ------------------------- | ------------------------------------------------------------- |
| `home_screen.dart`        | `_removeDeletedPage()` 里调用 `NativeBrowser.resetPageHistory()` |
| `native_browser.dart`     | 新增 `resetPageHistory()`，走 `com.notion.app/browser` 通道         |
| `MainActivity.kt`         | 新增 `resetPageHistory` 分支，转调 ViewHolder                        |
| `BrowserWebViewHolder.kt` | 新增 `resetHistoryToCurrent()`，调 `clearHistory()` + 记日志         |

清栈后 `canGoBack()` 变 false，返回键一步 `finish()` 退出。

**安全性论证**：清栈时机选在"删除确认"这一刻，是因为此时能确定当前 SPA 会话的  
历史顶部指向一篇已删页面，清栈是**有据可依**的、不会误伤正常导航历史。  
清栈后用户在列表里点开其它笔记，SPA 仍会正常 `pushState` 累积新的历史。

---

## 三、其它观察

### 3.1 第三方追踪域仍在（低优先）

新日志的 perf 采样里出现了此前没注意的域：

```
track.customer.io / assets.customer.io   ← 用户行为分析
o324374.ingest.sentry.io                 ← 错误上报
code.gist.build                          ← ?
aif.notion.so                            ← 单次 3.2s~22.6s，偶发偏慢
```

其中 `aif.notion.so` 在两次采样里达 3,243ms / 22,657ms，**值得关注**（是 AI 功能相关页面）。  
customer.io / sentry 属第三方埋点，若要拦可后续加，但目前耗时都是毫秒级，收益有限。

### 3.2 核心链路健康

- 10/9 冷启动全部 `space=true user=true`（Cookie 竞态修复保持有效）
- GitHub 403 持续为 0
- `api.notion.com` TLS 握手失败 10/9 为 0

---

## 四、行动建议

| 优先级 | 动作                              | 状态                       |
| --- | ------------------------------- | ------------------------ |
| —   | 拦截 splunkcloud + exp.notion.com | ✅ 已完成并验证（降幅 94-99%）      |
| —   | 修复删除后返回栈钻回 bug                  | ✅ 已修复（`a0149ef`），待用户装了验证 |
| P2  | 观察 `aif.notion.so` 偶发 22s 慢加载   | 待更多样本                    |
| P3  | 是否拦 customer.io / sentry        | 收益低，可暂缓                  |

**下一步**：装 `a0149ef` 版本，复现"删除笔记 → 点返回"场景，确认一步退出即修复成功。
