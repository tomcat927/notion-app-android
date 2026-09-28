# Notion App Android — 对话记录与技术分析

## 项目背景

- 仓库：`notion-app-android`（GitHub: tomcat927/notion-app-android）
- 技术栈：Flutter + Kotlin 原生
- 定位：Android 优先的 Notion 轻量客户端，Token 登录，无 AI
- 架构：首页列表用 Flutter + Notion API（`api.notion.com/v1`），笔记浏览用原生 `BrowserActivity`（WebView 加载 Notion 网页），全文搜索用隐藏 WebView 调内部 API（`app.notion.com/api/v3`）
- 构建约束：本地不装 Flutter/Android SDK，不编译不打包，交给 GitHub Actions（Build & Release workflow）

## 核心文件结构

```
lib/
  main.dart                           — 启动入口，加载 WebSession
  core/
    notion_client.dart                — Notion 公开 API 客户端（Bearer token, api.notion.com/v1）
    notion_auth.dart                  — Token 存取（SharedPreferences）
    notion_web_session.dart           — 【新增】Cookie 提取 + 纯 HTTP 调内部 API
    app_logger.dart                   — 日志（写入 applicationDocumentsDirectory）
    remote_log_service.dart           — 远程日志上传到 OpenList
    native_browser.dart               — 调用原生 BrowserActivity 的 MethodChannel
  features/
    auth/login_screen.dart            — Token 登录页
    home/home_screen.dart             — 首页（列表 + 数据源切换 + 全文搜索入口）
    search/
      private_search_bridge.dart      — 隐藏 WebView 搜索桥（HTTP 优先 + WebView 回退）
      private_search_screen.dart      — 全文搜索 UI
      private_search_models.dart      — 搜索结果模型与解析
      recent_pages_service.dart       — 最近访问页面缓存
    editor/editor_screen.dart         — Flutter 原生块编辑器（段落/标题/列表/待办）
    browser/
      notion_page_browser_screen.dart — WebView 备用浏览器（Flutter 侧）
      in_page_search.dart              — 【9/28 新增】页面内搜索模型 + JS 脚本生成器
android/app/src/main/kotlin/com/notion/app/
  MainActivity.kt                     — Flutter 主 Activity，多个 MethodChannel
  BrowserActivity.kt                  — 原生 WebView 浏览器 Activity
```

## 已完成的改动（本次对话期间）

> 以下 4 项为 9/26 对话的工作，9/28 对话的改动见下方「9/28 新增」节。

### 1. 方案 A：Cookie 提取 + 纯 HTTP 搜索（提交 `0568ac3`）

**问题**：全文搜索每次点击都触发"正在连接 Notion"，隐藏 WebView 常驻 100-200MB 内存。

**根因**：搜索用的是隐藏 WebView 加载完整 Notion SPA 来调 `app.notion.com/api/v3/search`，每次释放后要重新加载页面。

**方案**：
- Kotlin 侧新增 `com.notion.app/cookie` MethodChannel → `CookieManager.getInstance().getCookie(url)` 读取 HttpOnly 的 `token_v2`
- Dart 侧新增 `NotionWebSession` 单例（`lib/core/notion_web_session.dart`，445 行）：
  - `refreshFromCookieManager()` 从原生 CookieManager 取 cookie，写 `flutter_secure_storage`
  - `_fetchSpaceId()` 调 `POST /api/v3/getSpaces` 解析 spaceId 并缓存
  - `search(query)` / `loadRecentPages()` 纯 `package:http` 调 `app.notion.com/api/v3`，带完整 cookie 头 + `x-notion-*` headers
  - `_withAutoRefresh()` 统一处理 401/403 → 自动刷新 cookie → 重试
- `private_search_bridge.dart` 新增 `searchViaHttp()` / `loadRecentPagesViaHttp()`，原有 WebView 路径保留为回退
- `private_search_screen.dart` 搜索/加载最近页优先走 HTTP，失败才回退 WebView
- `main.dart` 启动时 `loadFromStorage()`，`home_screen.dart` `initState` 后台预热 cookie

### 2. Cookie 多域扫描修复（提交 `f5e182c`）

**问题**：日志显示 `token_v2 missing in cookie manager; available: cf_redirect_migration,__ps_r,...`——只读了 `https://www.notion.so` 一个域，拿不到 Notion 的登录 cookie。

**修复**：`NotionWebSession._cookieUrls` 从单个 URL 改为扫描 4 个域：
```dart
static const List<String> _cookieUrls = [
  'https://www.notion.so',
  'https://notion.so',
  'https://app.notion.com',
  'https://www.app.notion.com',
];
```
合并所有域的 cookie，转发完整 cookie 头（排除 Cloudflare 的 `__cf_bm`/`_cfuvid` 等）。

**验证**：日志确认 `refreshed from cookie manager: space=true user=true sources=...,token_v2`，之后所有启动都是 `loaded from storage: space=true user=true`。

### 3. WebView JS 错误日志 + 大纲 observer 防抖（提交 `04beadb`）

**问题**：BrowserActivity 没有记录 JS console 错误，单选属性菜单不弹时无法诊断；大纲脚本 MutationObserver 全页面监听导致主线程卡顿。

**改动**：
- `WebChromeClient.onConsoleMessage`：ERROR/WARNING 级 JS 消息写入原生日志（含 sourceId:lineNumber）
- `writeBrowserLog` 加 256KB 文件大小上限（超限截取后半段）
- 大纲 observer：300ms 防抖 + 标题数量不变时跳过 `collect()` + 移除 `characterData` 订阅

### 4. 渲染进程自动恢复（提交 `3ca994f` + `f6f493e`）

**问题**：日志显示 `WebView renderer gone: didCrash=false priorityAtExit=2` 频繁出现，用户看到"渲染进程被系统回收"错误页。

**改动**：`BrowserActivity.onRenderProcessGone` 不再直接显示错误页，改为：
- 首次回收 → 自动销毁旧 WebView → 重建 → 重新加载当前页面 + toast"页面已自动恢复"
- 5 分钟窗口内第二次回收 → 才退回手动错误页
- 时间戳列表派生计数器，窗口过后自动归零

## 9/28 新增：全文搜索跳转定位 + 笔记页面内检索

### 5. 搜索跳转定位 — block 级精确定位（提交 `dbfe928` + `ac9d8cc`）

**需求**：类似 PC 端，全文搜索点击结果后跳转到笔记页面对应 block 位置并高亮。

**根因**：搜索结果数据已包含 `primaryBlockId`（来自 Notion API 的 `highlightBlockId`）和 `primarySnippet`（命中文本），但 `_openPage` 只传 `pageId` + `title`，定位信息被丢弃。

**改动**（全链路传递 + JS 注入定位）：
- `PrivateSearchScreen._openHit(hit)` → `_openPage(pageId, title, blockId: hit.primaryBlockId, snippet: hit.primarySnippet)`
- `NativeBrowser.openPage()` 新增 `blockId` / `snippet` 可选参数，通过 MethodChannel 传递
- `MainActivity.openPageBrowser()` 读取参数 → `Intent` extras `EXTRA_BLOCK_ID` / `EXTRA_SNIPPET`
- `BrowserActivity` 从 Intent 读取 → `onPageFinished` 注入 `buildHighlightBlockScript()`
- `NotionPageBrowserScreen` 新增 `highlightBlockId` / `highlightSnippet` 字段 → `onPageFinished` 注入定位 JS
- 新建 `in_page_search.dart` 提供 `buildHighlightBlockScript()` — 优先 `[data-block-id]` 精确定位，找不到则 snippet 文本兜底

### 6. Block 高亮重试机制（提交 `1901ef7`）

**问题**：`onPageFinished` 触发时 Notion React 页面尚未渲染 block DOM，`querySelector('[data-block-id=...]')` 返回 null。

**修复**：`buildHighlightBlockScript` 增加 `tryHighlight()` 重试函数，每 500ms 重试一次，最多 12 次（6 秒窗口）。同时修复 `_currentMatchIndex` 未使用字段（`flutter analyze` warning → CI 失败）。

### 7. 页面内搜索功能（提交 `dbfe928`）

**需求**：笔记页面内输入关键词搜索，显示结果列表，点击跳转到对应位置。

**两条路径**：
- **Flutter WebView**（`NotionPageBrowserScreen`）：AppBar 新增搜索图标 → 底部弹出搜索面板（`StatefulBuilder` + `showModalBottomSheet`）→ JS TreeWalker 搜索文本节点 → 结果通过 `NotionInPageSearch` JS Channel 回传 Flutter → 列表展示带高亮上下文 → 点击结果 `scrollIntoView` + overlay 高亮
- **原生 BrowserActivity**：工具栏新增「搜索」按钮 → 注入 `INSTALL_IN_PAGE_SEARCH_SCRIPT` JS 面板（自包含 DOM 浮层，类似大纲面板模式）→ TreeWalker 搜索 → 结果列表内联展示 → 点击结果 `scrollIntoView` + overlay 高亮

**共用基础设施**（`in_page_search.dart`）：
- `kHighlightStyleScript` — CSS 注入（pulse 动画 + overlay 样式）
- `buildHighlightBlockScript()` — block 定位（需求一）
- `buildInPageSearchScript()` — TreeWalker 搜索 + Range 存储（需求二）
- `buildScrollToMatchScript()` — 滚动 + overlay 高亮
- `InPageSearchMatch` / `InPageSearchResult` — 数据模型

### 8. scrollIntoView + 闭包修复（提交 `1901ef7` + `e34d7d0`）

**Bug A：`window.scrollTo()` 对 Notion 无效**
- Notion 使用自定义滚动容器（`.notion-scroller`），`window.scrollTo` 滚的是 `document.body`，内容在另一个容器里
- 改用 `el.scrollIntoView({ behavior: 'smooth', block: 'center' })` — 原生 API 自动遍历 DOM 树找到正确的可滚动容器
- overlay 从 `position: absolute`（依赖 `window.scrollX/Y`）改为 `position: fixed`（直接用 `getBoundingClientRect()` 视口坐标）

**Bug B：`var rangeIndex` 闭包陷阱**
- `INSTALL_IN_PAGE_SEARCH_SCRIPT` 中 `var rangeIndex` 在 while 循环内声明，JavaScript `var` 是函数作用域，所有 `onclick` 闭包共享同一个变量
- 循环结束后 `rangeIndex` 是最后一次迭代的值，导致点击任何结果都跳到最后一条匹配
- 改为 `let rangeIndex`（块作用域），每次迭代创建独立绑定

### 9. 搜索结果去重 + 分析请求拦截（提交 `e34d7d0` + `aff43dd`）

**Bug C：搜索结果重复**
- TreeWalker 搜 `document.body` 会命中 Notion 在多个 DOM 容器中渲染的相同内容副本（虚拟滚动、响应式布局、隐藏预渲染容器）
- 限制搜索根节点到 `.notion-page-content`（Notion 主内容容器），找不到则回退 `document.body`
- 新增 `lastContext` 连续去重：相同上下文的匹配跳过
- Dart 侧和原生侧同时修复

**页面加载优化**：
- `BrowserActivity.shouldInterceptRequest()` 拦截 `api.amplitude.com`、`api.statsig.com`、`featuregates.org`、`prod.web-sdk.amplitude.com` 的网络请求，返回空响应
- Notion 分析 SDK 代码仍会执行（作为 JS bundle 的一部分加载），但网络请求被阻断，省下带宽给正文加载
- 日志验证：拦截后 `Amplitude Logger [Warn]: Event not tracked` 确认 SDK 发不出数据；renderer 崩溃消失

## 日志分析结论

### 远程日志基础设施
- OpenList 服务：`https://119.91.136.173:5245`（HTTPS），用户名 `notion-app-logger`，密码 `qwer@345`
- 日志路径：`/data/openlist/notion-app/logs/install-e67405c2eea6/diagnostic-<timestamp>.txt`
- 也可直接 SSH 到 `tencent-01` 读取 `/data/openlist/notion-app/logs/...`

### 性能分析（9/26 日志）

**App 自身开销极小**：
| 操作 | 耗时 |
|---|---|
| 点击页面 → BrowserActivity 启动 | 50–96ms |
| 浏览器返回 → 列表刷新完成 | 634ms–1s |
| 全文搜索（HTTP 路径） | 1.7–4.5s |

**慢在 Notion SPA 加载**（4–20 秒，极不稳定）：
| 时刻 | 页面 | open→JS首条 | JS首条→就绪 | 总计 |
|---|---|---|---|---|
| 00:25 | 待办 | 6s | 7s | 13s |
| 15:16 | 待办 | 4.3s | 13.4s | 17.7s |
| 16:28 | 待办 | 7s | 11s | 18s |
| 20:14 | 短信转发 | 4.5s | 15s | 19.5s |

- `open→JS首条`（2–7s）：下载 Notion HTML + JS bundle，纯网络
- `JS首条→就绪`（3–15s）：React SPA 初始化（拉数据、websocket、Statsig/Amplitude）

### 遗留问题
- ~~渲染进程回收仍发生~~ → **9/28 已缓解**：auto-recover 已安装并工作（日志确认 `renderer auto-recover: attempt=0`）；新增分析请求拦截后最新日志零 renderer 崩溃
- ~~`auto-recover` 日志 0 条~~ → **9/28 已解决**：自动恢复已安装到手机，日志中有 `renderer auto-recover: attempt=0` 记录
- Notion SPA 自身的 JS 错误：`ResizeObserver loop`、`touchstart cancelable=false`（无害，仍存在）
- `manifest check failed: TimeoutException after 0:00:20`（GitHub 更新检查超时，网络问题，仍偶发）
- **9/28 新增已解决问题**：页面内搜索闭包陷阱（`var`→`let`）、`window.scrollTo` 无效（→`scrollIntoView`）、搜索结果重复（`.notion-page-content` 限制 + 去重）、block 高亮时机（重试机制）

## 架构分析与下一步方向

### 当前架构的定位
```
WebView 方案        = 功能 100% + 开发量小 + 速度慢（5-20s）
Flutter 原生渲染    = 功能受限 + 开发量大 + 速度快（1-2s）
官方 App            = 原生渲染 + 几十人团队 + 几年开发
```

### "Notion SPA" 是什么
SPA = Single Page Application（单页应用）。Notion 网页版打开时先下载几 MB 的 JavaScript 包（包含整个前端：React 组件、编辑器、数据库视图、属性面板），然后 JS 调 API 拿数据渲染。慢就慢在每次都要下载+执行这个 JS 包。官方 App 快是因为不走 SPA，原生代码直接调 API + 原生 UI 渲染。

### `webview_flutter` 替换原生 BrowserActivity 能提速吗？
**不能**。`webview_flutter` 在 Android 上底层用的就是同一个 `android.webkit.WebView`——同一个 Chromium 渲染器、加载同一个 Notion SPA。换了之后速度完全不变甚至略慢（平台视图合成开销）。

### 唯一能提速的方向：Flutter 原生渲染替换 WebView

**已有雏形**：`EditorScreen`（`lib/features/editor/editor_screen.dart`）已经用 `NotionClient` 调 API 拿 block 列表，用 Flutter 原生 `TextField`/`Text` 渲染，速度快。但目前只支持段落、标题、列表、待办等少数 block 类型。

**渐进路线**：
- **阶段 1**：`EditorScreen` 扩展为"快速阅读模式"——支持 image、callout、code、toggle、子页面、顶部属性标签（只读）；打开页面时先秒开 Flutter 原生视图（1-2s），底部留"用完整编辑器打开"按钮按需加载 WebView。覆盖 80% 的"看一眼"场景。
- **阶段 2**：属性可编辑——select/multiselect 用 Flutter 下拉 + API 更新；date 用日期选择器 + API 更新。覆盖 90% 日常操作。
- **阶段 3**：复杂 block 编辑——行内格式、数据库视图。覆盖 95%+，WebView 退居回退。

### 不推荐的方向
- **adb 抓包官方 App**：官方 App 是 release 版日志极少，TLS pinning 抓不到包，且 API 我们已在用。官方 App 快的秘密不是 API 而是"原生渲染"，不值得逆向。

## 关键代码位置

| 功能 | 文件 | 行号 |
|---|---|---|
| Cookie MethodChannel（Kotlin） | `android/.../MainActivity.kt` | 80, 223 |
| Cookie 多域扫描 | `lib/core/notion_web_session.dart` | `_cookieUrls` 常量 |
| HTTP 搜索（bridge 层） | `lib/features/search/private_search_bridge.dart` | `searchViaHttp()`, `loadRecentPagesViaHttp()` |
| HTTP 优先 + WebView 回退 | `lib/features/search/private_search_screen.dart` | `_loadRecentFromApi()`, `_search()` |
| JS console 日志 | `android/.../BrowserActivity.kt` | `onConsoleMessage()` |
| 大纲 observer 防抖 | `android/.../BrowserActivity.kt` | `INSTALL_OUTLINE_SCRIPT` |
| 渲染进程自动恢复 | `android/.../BrowserActivity.kt` | `onRenderProcessGone()`, `canAutoRecoverRenderer()`, `recreateWebView()` |
| Flutter 原生编辑器 | `lib/features/editor/editor_screen.dart` | 全文件 |
| Block 高亮 + 页面内搜索 JS 生成器 | `lib/features/browser/in_page_search.dart` | `buildHighlightBlockScript()`, `buildInPageSearchScript()`, `buildScrollToMatchScript()` |
| 搜索结果 blockId 全链路传递 | `lib/features/search/private_search_screen.dart` | `_openHit()`, `_openPage()` |
| NativeBrowser blockId 参数 | `lib/core/native_browser.dart` | `openPage()` |
| NotionPageBrowserScreen 页面内搜索 | `lib/features/browser/notion_page_browser_screen.dart` | `_showInPageSearchSheet()`, `_performInPageSearch()`, `_applyHighlightBlock()` |
| BrowserActivity block 定位 + 搜索面板 + 分析拦截 | `android/.../BrowserActivity.kt` | `buildHighlightBlockScript()`, `INSTALL_IN_PAGE_SEARCH_SCRIPT`, `shouldInterceptRequest()` |
| MainActivity blockId/snippet 传递 | `android/.../MainActivity.kt` | `openPageBrowser()`, `EXTRA_BLOCK_ID`, `EXTRA_SNIPPET` |

## 最近提交历史

```
aff43dd  fix: 页面内搜索结果重复 — 限制搜索范围 + 上下文去重
e34d7d0  fix: 闭包陷阱导致页面内搜索点击无法跳转 + 拦截分析追踪加速页面加载
1901ef7  fix: block 高亮重试机制 + 页面内搜索 scrollIntoView 替换 window.scrollTo
ac9d8cc  fix: 移除未使用的 _currentMatchIndex 字段
dbfe928  feat: 全文搜索跳转定位 + 笔记页面内检索
f6f493e  fix: qualify Toast context in renderer auto-recover
3ca994f  feat: auto-recover BrowserActivity WebView after renderer reclaim
04beadb  feat: log WebView JS errors and debounce outline observer
f5e182c  fix: scan all Notion cookie domains for token_v2
0568ac3  feat: search via HTTP cookie extraction, drop resident WebView
```

## 环境信息

- 工作目录：`C:\data\vscode\android\notion-app-android`
- Git 分支：`main`
- 开发机：Windows，无 Flutter/Android SDK（按 AGENTS.md 约束不本地编译）
- 构建：GitHub Actions（Build & Release workflow），push 后检查
- Git push：直连被墙，通过 `socks5://127.0.0.1:7897` 代理
- SSH 服务器 `tencent-01`：腾讯云公网，119.91.136.173，存放 OpenList 日志
