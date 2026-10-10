# Notion 内置大纲 / 标题 DOM 调研

> **状态：部分验证。** 公开页已用无头浏览器实测；**登录态工作区笔记页尚未验证**，需要设备端 MCP 浏览器补齐（见 §5）。

本调研服务于一个具体问题：笔记详情页（原生 `BrowserActivity`）里那个自建「大纲」按钮，有没有必要自己做——**能不能直接复用 Notion 官方的页面级大纲**，从而少写少维护？

---

## 1. 背景

- 笔记详情页主链路是**原生 `BrowserActivity`**，WebView 直接加载 `https://www.notion.so/<pageId>`（**真·Notion 网页**，非自研渲染器）。
- App 通过注入 JS（`INSTALL_OUTLINE_SCRIPT`）抓 `h1/h2/h3` 自建悬浮大纲面板。
- 触发本次调研的两件事：
  1. 大纲里**混进了笔记标题**（已修，见 §6）。
  2. 想确认**能否复用 Notion 内置大纲**来省代码。

---

## 2. 结论速览

| 问题 | 结论 | 证据强度 |
|---|---|---|
| 笔记标题为什么会被当成大纲条目 | 标题本身就是一个 `<h1>`，且位于 `.notion-page-content` **之外**；而原查询是全文档的 | ✅ 公开页实测 |
| 移动端 web 有没有内置「页面级大纲」可复用 | **没有** | ⚠️ 仅公开页实测 |
| 能否用 Notion 内置大纲替代自建方案 | **不能**（没有可复用的东西） | ⚠️ 同上 |
| 那 Notion 官方帮助里说的"右侧页面级目录"呢 | 是**桌面端**能力（悬停展开、可在页面设置里按页关闭），移动端 web 不渲染 | 文档 + 公开页实测 |

---

## 3. ⚠️ 证据边界（先读这段）

**已覆盖**：公开页 —— `*.notion.site`、`www.notion.so/help`。这类页面**匿名即可访问，不需要任何 token**，所以无凭据也能渲染并读 DOM。

**未覆盖**：**登录态的工作区笔记页**（即 App 实际加载的那种）。理论上是同一个客户端、同一套移动端布局，但没有 100% 确认。

**为什么没做登录态验证**：

- DOM 渲染需要 `notion.so` 的**登录态 cookie**，而 App 的 cookie 存在设备上，本机拿不到。
- 手上的 Notion 凭据是 **API token（integration token）**，它只能通过 API 读 **block 数据**，**不能渲染 web UI**。**API token ≠ web session cookie**，两者不是一回事，别混用。

**结论：§2 中标注 ⚠️ 的两条，只能算"公开页成立"，需要 §5 的设备验证来收口。**

---

## 4. 方法（可复现）

### 4.1 为什么不能直接 curl

Notion 是纯 SPA。`curl` 拿到的 HTML 只有外壳：实测 `bytes=20167`，其中
`notion-page-content` / `<h1` / `contenteditable` / `notion-app-inner` **全部为 0 次命中**。
必须**执行 JS** 才能看到真实 DOM。

### 4.2 正确做法：无头浏览器

脚本：`tools/probe_notion_dom.js`（Playwright + 本机已缓存的 Chromium）

关键参数（缺一不可）：

| 项 | 值 | 说明 |
|---|---|---|
| UA | `Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36` | 与 App 的 `MOBILE_USER_AGENT` 保持一致 |
| viewport | `412x915`，`isMobile:true`，`hasTouch:true` | 走移动端布局 |
| 代理 | **必须显式传** `proxy:{server: HTTPS_PROXY}` | 本机环境走 `http://127.0.0.1:13197`；不传直接 `ERR_CONNECTION_CLOSED` |
| `ignoreHTTPSErrors` | `true` | 代理会做 MITM |
| 等待 | `waitForTimeout(9000)` | SPA 渲染需要时间 |
| Chromium | `.../ms-playwright/chromium-1243/chrome-win64/chrome.exe` | 可用 `CHROMIUM_PATH` 覆盖 |

### 4.3 运行

```bash
export NODE_PATH="<全局 node_modules>"
node tools/probe_notion_dom.js "https://help-support.notion.site/c765fdbb83a442fd99d8ead0ac76e6f8"
```

### 4.4 实测原始数据（2026-10-10）

页面：`https://help-support.notion.site/c765fdbb83a442fd99d8ead0ac76e6f8`（标题「侧边栏导航」）

**标题节点**

```json
{
  "tag": "H1",
  "cls": "content-editable-leaf-rtl",
  "text": "侧边栏导航",
  "insidePageContent": false,
  "inTitleRow": false,
  "chain": "DIV.notion-selectable.notion-page-block < DIV. < DIV. < DIV."
}
```

→ 结论：**标题就是 `<h1>`，父节点是 `.notion-selectable.notion-page-block`，且在 `.notion-page-content` 之外。**
→ 这正是"标题混进大纲"的根因；也说明**把查询限定在 `.notion-page-content` 内即可修好**。
→ 附带发现：该布局下标题祖先链**没有** `.notion-page-view-title-row`（但 App 自己的 CSS 引用了这个类，说明登录态布局可能不同 → 列入 §5 采集清单）。

**TOC 相关**

```json
{
  "tocishCount": 1,
  "tocish": [{
    "tag": "DIV",
    "cls": "notion-selectable notion-table_of_contents-block",
    "insidePageContent": true
  }]
}
```

→ 页面上唯一的"目录"是**作者手动插入的 `/toc` 区块**，父节点正是 `.notion-page-content`，**在正文流内、随内容滚动**，不是悬浮大纲。

**fixed / sticky 元素（内置悬浮大纲若存在必然在此）**

```json
{
  "floatingCount": 3,
  "floating": [
    { "cls": "notion-print-ignore", "pos": "fixed", "text": "跳至内容" },
    { "cls": "xixxii4 ... notion-overlay-container notion-de", "pos": "fixed", "w": 412, "h": 915, "text": "" },
    { "cls": "", "pos": "fixed", "right": 392, "w": 20, "h": 20, "text": "" }
  ],
  "ariaToc": []
}
```

→ **没有任何右侧悬浮目录**；`[aria-label]` 中也没有提到"目录 / 大纲 / outline"的元素。

**一个无效尝试（记录以免重走）**：`https://www.notion.so/help/columns-headings-and-dividers` 是 Notion 的**营销/帮助站点**（顶部是 `globalNavigation` + "Get Notion free"），**不是工作区页面**，`hasTocBlock: false`，对该问题没有参考价值。

---

## 5. 待办：用设备 MCP 浏览器验证登录态页面

设备上有 MCP 可以操控 Chrome 访问**真实登录态 Notion 页面**——这正好补上 §3 的缺口。

### 5.1 目标

在**登录态、移动端布局**下回答：Notion 到底渲不渲染页面级大纲？页面标题的 DOM 位置与公开页是否一致？

### 5.2 采集清单

打开一篇**有 ≥2 个标题**的笔记（这样页面级目录才可能触发），执行：

```js
(() => {
  const cls = el => (el.className && el.className.toString ? el.className.toString() : '').slice(0, 120);
  const heads = Array.from(document.querySelectorAll('h1,h2,h3'));
  const floating = [];
  document.querySelectorAll('*').forEach(el => {
    const cs = getComputedStyle(el);
    if (cs.position !== 'fixed' && cs.position !== 'sticky') return;
    const r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) return;
    floating.push({
      cls: cls(el), pos: cs.position,
      right: Math.round(window.innerWidth - r.right),
      w: Math.round(r.width), h: Math.round(r.height),
      text: (el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 40),
    });
  });
  return {
    url: location.href,
    hasPageContent: !!document.querySelector('.notion-page-content'),
    titleHeading: heads[0] && {
      tag: heads[0].tagName, cls: cls(heads[0]),
      insidePageContent: !!heads[0].closest('.notion-page-content'),
      inTitleRow: !!heads[0].closest('.notion-page-view-title-row'),
      parent: heads[0].parentElement ? heads[0].parentElement.tagName + '.' + cls(heads[0].parentElement) : null,
    },
    headingCount: heads.length,
    tocish: Array.from(document.querySelectorAll('[class]'))
      .filter(el => /toc|table_of_contents|outline/i.test(cls(el)))
      .map(el => ({ cls: cls(el), insidePageContent: !!el.closest('.notion-page-content') })),
    floating,
    ariaToc: Array.from(document.querySelectorAll('[aria-label]'))
      .filter(el => /目录|大纲|outline|table of contents|toc/i.test(el.getAttribute('aria-label') || ''))
      .map(el => ({ cls: cls(el), label: el.getAttribute('aria-label') })),
  };
})()
```

### 5.3 判断标准

| 观察 | 判定 |
|---|---|
| 出现 `position:fixed/sticky`、贴右侧、内容为标题列表的元素 | **存在**内置页面级大纲 → 需评估复用（见 5.4） |
| `floating` 里只有 Notion 自身的浮层（帮助按钮等），无标题列表 | **不存在** → 维持自建方案，本调研收口 |
| 标题 `insidePageContent` 为 `true`（与公开页相反） | 说明登录态布局不同 → 需在 `headingNodes()` 里补更强的排除条件 |
| 出现 `.notion-page-view-title-row` | 与公开页不同 → 记录实际布局差异 |

同时**视觉确认**：页面右侧是否出现一条细目录条（公开页没有）。

### 5.4 若真的存在，复用评估要点

即便存在，也要先过这几关再决定是否替换自建方案：

1. **交互**：官方是"悬停展开"，触屏无 hover，展开方式是否可用？
2. **可控性**：它是**页面级设置**，用户可在 `••• → 自定义页面` 里关掉 → 一旦关掉，App 的大纲就没了，**不可靠**。
3. **耦合成本**：驱动它意味着依赖 Notion 私有 DOM / 交互；而当前自建方案只是**只读**地读 `h1/h2/h3`，脆弱性低得多。
4. **兜底**：若保留自建作为兜底，等于两套逻辑并存，未必省代码。

---

## 6. 相关代码与提交

| 内容 | 位置 |
|---|---|
| 大纲注入脚本 / `headingNodes()` / toggle 逻辑 | `android/app/src/main/kotlin/com/notion/app/BrowserActivity.kt`（`INSTALL_OUTLINE_SCRIPT`） |
| 移动端 UA 常量 | `android/app/src/main/kotlin/com/notion/app/BrowserWebViewHolder.kt`（`MOBILE_USER_AGENT`） |
| 对照：已正确限定作用域的写法 | 同文件「页面内搜索」的 `searchRoot`；Flutter 侧 `lib/features/browser/notion_page_browser_screen.dart` |
| 探针脚本 | `tools/probe_notion_dom.js` |

| 提交 | 内容 |
|---|---|
| `b3f02f5` | 大纲按钮改为同层自洽浮层，修复二次点击无法收起 |
| `ae605e6` | 移除大纲面板底部「关闭」按钮（已冗余） |
| `dd4506e` | 大纲不再收录笔记标题（selector 未限定作用域） |
