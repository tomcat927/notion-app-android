# Clash 推荐规则

本文说明 Notion Lite 在 Clash 中的推荐分流规则。App 的 API 请求、内嵌 Notion 编辑器和热更新请求都会使用 Android 系统代理，因此流量会先进入 Clash，再由规则决定走哪个策略组。

## 需要代理的域名

在你的自定义规则区加入：

```yaml
DOMAIN-SUFFIX,notion.com,Notion
DOMAIN-SUFFIX,notion.so,Notion
DOMAIN-SUFFIX,notion.site,Notion
DOMAIN-SUFFIX,notionusercontent.com,Notion
DOMAIN-SUFFIX,notion-static.com,Notion
```

这些是 Notion 页面、API、资源、上传和编辑器静态资源使用的主要域名。

> **注意 `notion.com` 这条必须放在规则表靠前位置**。实测日志里 `app.notion.com`、`msgstore-002.app.notion.com` 曾落到「漏网之鱼」，说明当时规则没命中——检查你的规则集里是否有更靠前的 `GEOSITE`/`DOMAIN-KEYWORD` 把它抢先匹配走了。

## 热更新域名

App 的版本检查和 APK 下载优先使用 GitHub 加速代理：

```text
gh-proxy.com
github.com
objects.githubusercontent.com
release-assets.githubusercontent.com
api.github.com
```

如果希望热更新稳定，可以单独建一个 `GitHub` 策略组，或直接让它们也走 `Notion`：

```yaml
DOMAIN-SUFFIX,gh-proxy.com,Notion
DOMAIN-SUFFIX,github.com,Notion
DOMAIN-SUFFIX,objects.githubusercontent.com,Notion
DOMAIN-SUFFIX,release-assets.githubusercontent.com,Notion
DOMAIN-SUFFIX,api.github.com,Notion
```

如果你的规则里已有 `GitHub` 分组，把上面的策略名从 `Notion` 改成你的分组名即可。

> **`api.github.com` 是 2026-10-09 新补的**。App 的 `UpdateService` 除了走 `gh-proxy.com` 的 `latest.json`，还会直接调 `api.github.com/repos/.../releases/latest` 作为回退（见 `lib/core/update_service.dart:60`）。日志里出现过 `[Update] primary check failed: Exception: GitHub API HTTP 403`——匿名请求 `api.github.com` 有 60 次/小时的限流，未代理时更容易触发。补上这条可显著改善热更新成功率。

## 分析/埋点域名（建议 REJECT，不要代理）

App 已在代码层拦截以下埋点域名（`android/.../BrowserWebViewHolder.kt:183-188` 的 `shouldInterceptRequest` 返回空响应）：

```text
api.amplitude.com
api.statsig.com
featuregates.org
prod.web-sdk.amplitude.com
```

**建议在 Clash 层也一并 REJECT**，好处是：DNS/连接层就断掉，省下 WebView 拦截器里的 TLS 握手与请求往返开销，把带宽让给正文加载。

```yaml
DOMAIN-SUFFIX,amplitude.com,REJECT
DOMAIN-SUFFIX,statsig.com,REJECT
DOMAIN-SUFFIX,featuregates.org,REJECT
```

> 这 3 条只覆盖上面 4 个域名所在的根域（`amplitude.com` 同时覆盖 `api.amplitude.com` 和 `prod.web-sdk.amplitude.com`）。
>
> **风险提示**：`statsig` / `amplitude` 承载 A/B 实验与功能开关。REJECT 后 Notion 仍会正常渲染（SDK 已容错），但理论上极小概率影响灰度功能下发。App 内已拦截约两周，未观察到异常，可放心在 Clash 层加重。

## 第三方域名

Notion 编辑器可能会请求少量第三方服务。你日志里出现过这些：

```text
transcend-cdn.com
http-inputs-notion.splunkcloud.com
```

它们分别与页面合规组件和日志上报有关。不代理通常也能用；如果你希望 App 内编辑器加载更快，可以加入：

```yaml
DOMAIN-SUFFIX,transcend-cdn.com,Notion
DOMAIN-SUFFIX,splunkcloud.com,Notion
```

## 示例策略组

如果你的 Clash 配置支持策略组，可以用这种方式组织：

```yaml
proxy-groups:
  - name: Notion
    type: select
    proxies:
      - 自动选择
      - 手动选择
      - DIRECT
```

`自动选择` 和 `手动选择` 请替换成你配置里已有的节点或节点组。

## 完整规则（可直接粘贴）

按 `REJECT → Notion → GitHub/热更新 → 第三方` 的顺序排列：

```yaml
rules:
  # --- 埋点/分析：直接拒绝 ---
  - DOMAIN-SUFFIX,amplitude.com,REJECT
  - DOMAIN-SUFFIX,statsig.com,REJECT
  - DOMAIN-SUFFIX,featuregates.org,REJECT

  # --- Notion 核心：走代理 ---
  - DOMAIN-SUFFIX,notion.com,Notion
  - DOMAIN-SUFFIX,notion.so,Notion
  - DOMAIN-SUFFIX,notion.site,Notion
  - DOMAIN-SUFFIX,notionusercontent.com,Notion
  - DOMAIN-SUFFIX,notion-static.com,Notion

  # --- 热更新 / GitHub：走代理 ---
  - DOMAIN-SUFFIX,gh-proxy.com,Notion
  - DOMAIN-SUFFIX,github.com,Notion
  - DOMAIN-SUFFIX,api.github.com,Notion
  - DOMAIN-SUFFIX,objects.githubusercontent.com,Notion
  - DOMAIN-SUFFIX,release-assets.githubusercontent.com,Notion

  # --- 第三方（可选）---
  - DOMAIN-SUFFIX,transcend-cdn.com,Notion
  - DOMAIN-SUFFIX,splunkcloud.com,Notion
```

## 当前日志说明

你之前的日志显示：

```text
www.notion.so -> DomainSuffix(notion.so) -> Notion
app.notion.com -> Match -> 漏网之鱼
msgstore-002.app.notion.com -> Match -> 漏网之鱼
gh-proxy.com -> Match -> 漏网之鱼
```

说明规则已经部分生效，但 `notion.com` 和热更新域名没有精确命中，最后都落到了「漏网之鱼」。加入上面的 `DOMAIN-SUFFIX` 规则后，Notion API、编辑器资源和热更新下载都会按预期分流。

## 注意事项

- Clash 必须开启 VPN/TUN 模式，仅 HTTP 代理模式下系统代理虽然可被 App 读取，但分应用代理不一定接管 App 流量。
- 如果使用分应用代理，请把 `com.notion.app` 加入代理列表。
- 修改规则后建议重启 Clash，并完全退出后重新打开 App。
- 如果换节点，优先测试延迟低且稳定支持长连接的节点；Cloudflare 优选节点不一定适合 Notion 编辑器和同步连接。
- **代理残留排查**：日志里若出现 `Connection refused ... 127.x.x.x`（如 `127.57.44.31`）这类地址，是 Clash 的 fake-ip 段。通常意味着 Clash 已关闭但 App 仍缓存了代理配置——完全退出 App 或重启手机可清。
- **`api.notion.com` TLS 握手失败**：日志里出现过 `HandshakeException: Connection terminated during handshake`。这是长连接被中途掐断，常见于节点不稳定或 MTU 问题。优先换延迟低、稳定支持长连接的节点，而非单纯追求低延迟。
