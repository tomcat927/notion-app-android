# Notion Android App

轻量、稳定、无 AI 的 Notion Android 客户端，基于 Flutter 构建。

## 核心特点
- Token 登录，无需 Notion 账号密码
- 解决官方 Android App 固定页面跳转问题
- 移除所有 AI 功能
- 内嵌 Android WebView 打开 Notion 官方网页编辑器

## 获取 Notion Token

1. 访问 [Notion Integrations](https://www.notion.so/my-integrations) 页面
2. 点击 **"新建集成"**（New integration）
3. 填写名称（如 "Notion Lite"），选择关联的工作区
4. 创建后在 **"Secrets"** 区域复制 **Internal Integration Secret**（以 `ntn_` 或 `secret_` 开头）
5. 进入你需要操作的 Notion 页面，点击右上角 `...` → **连接** → 选择刚创建的集成
6. 将 Token 粘贴到 App 登录页面即可

## 登录与会话（API Token 与网页会话）

App 有两条相互独立的身份通道：

- **API 通道**：登录页填入的 Notion Token（内部集成密钥，或个人访问令牌），走 `api.notion.com`，用于页面列表、编辑等。
- **网页通道**：App 内嵌 WebView 登录 Notion 网页版后留下的 cookie（`token_v2` 等），用于全文搜索等网页接口。

**更换 API Token 不需要重新登录 Notion 网页版。** 在「设置 → 退出登录」后重新填入 Token，只会清除 API Token（`notion_token`），不会清除 WebView 的 cookie，也不会清掉缓存的网页会话（`notion_web_token_v2`）。设置里的「清理缓存」同样不清 cookie。

以下情况才会让网页会话失效、需要在内嵌 WebView 中重新登录 Notion 网页版：

- 卸载 App 或清除 App 数据；
- cookie 因 Notion 服务端原因自然过期（长期未用、改密码、安全登出等），此时会提示「Notion web 会话未就绪（缺少 cookie）」；
- 代码显式调用 `NotionWebSession.clear()`（目前没有任何 UI 触发；注意它内部是 secure storage 全量清除）。

注意：网页会话绑定的是你在 WebView 中登录的 Notion 账号，与 API Token 无关。若换成另一个账号的 API Token，会出现「API 用 A、网页搜索用 B」的错配。

## 技术栈
- Flutter (Dart)
- Notion API（`api.notion.com` REST 接口，用于页面列表和旧版轻量编辑）
- webview_flutter（内嵌 Android WebView，用于页面详情和官方编辑器）
- shared_preferences（Token 本地存储）

## 编辑能力

- 可编辑段落、三级标题、项目符号列表、编号列表、待办、折叠块、引用、标注和代码块
- 可读取并编辑嵌套块，可在页面末尾新增段落
- 图片、文件、数据库等暂不支持修改的块会以只读方式显示
- 仅修改待办状态不会影响原文本格式；修改带行内格式的文本会将该块转换为纯文本，保存前界面会提示

## 网络问题

遇到 `HandshakeException` 表示与 `api.notion.com` 的 TLS 连接在 HTTP 请求发出前被中断。App 会自动使用新连接重试 3 次；如果仍然失败，请切换 Wi-Fi/移动网络，并确认代理或 VPN 对该 App 生效。浏览器或 WebView 能打开 Notion，不代表 App 的 API 连接使用了同一条代理链路。

## 快速开始

```bash
git clone https://github.com/tomcat927/notion-app-android.git
cd notion-app-android
flutter pub get
flutter run
```

## 构建

```bash
# APK（分架构）
flutter build apk --release --split-per-abi

# App Bundle
flutter build appbundle --release
```

## 版本号

使用中国时区时间（`Asia/Shanghai`）自动生成构建时间，格式 `YYYYMMDDHHmmss`。

- App 内显示：`0.1.0 (YYYYMMDD HHmmss)`
- Release/APK 标签：`v0.1.0-YYYYMMDDHHmmss`
- Android 内部 `versionCode` 继续使用秒级 Unix 时间戳，以满足 Android 的整数范围限制并保持新旧版本比较可靠。

## 项目结构

```
lib/
├── app/theme/          # 主题管理
├── core/               # 核心功能（认证、API 客户端、日志）
│   ├── notion_auth.dart    # Token 存取
│   ├── notion_client.dart  # Notion API 客户端
│   └── app_logger.dart     # 调试日志（设备持久化）
├── features/
│   ├── auth/           # Token 登录
│   ├── browser/        # 内嵌 WebView 详情页
│   ├── editor/         # API 块编辑器
│   └── home/           # 页面列表、阅读视图 + 设置
└── main.dart           # 入口（无 Token 进登录页，有 Token 进主页）
```

> 说明：页面列表通过 **Notion Integration Token + REST API** 获取；点击页面详情时使用内嵌 Android WebView 加载 Notion 网页编辑器。Integration Token 不是网页登录凭据，首次在 WebView 中访问页面时仍需要完成 Notion 网页登录。

## License
MIT
