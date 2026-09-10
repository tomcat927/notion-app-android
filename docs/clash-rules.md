# Clash 推荐规则

本文说明 Notion App 在 Clash 中的推荐分流规则。App 的 API 请求、内嵌 Notion 编辑器和热更新请求都会使用 Android 系统代理，因此流量会先进入 Clash，再由规则决定走哪个策略组。

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

## 热更新域名

App 的版本检查和 APK 下载优先使用 GitHub 加速代理：

```text
gh-proxy.com
github.com
objects.githubusercontent.com
release-assets.githubusercontent.com
```

如果希望热更新稳定，可以单独建一个 `GitHub` 策略组，或直接让它们也走 `Notion`：

```yaml
DOMAIN-SUFFIX,gh-proxy.com,Notion
DOMAIN-SUFFIX,github.com,Notion
DOMAIN-SUFFIX,objects.githubusercontent.com,Notion
DOMAIN-SUFFIX,release-assets.githubusercontent.com,Notion
```

如果你的规则里已有 `GitHub` 分组，把上面的策略名从 `Notion` 改成你的分组名即可。

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
