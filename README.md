# Notion Android App

轻量、稳定、无 AI 的 Notion Android 客户端，基于 Flutter 构建。

## 核心特点
- Token 登录，无需 Notion 账号密码
- 解决官方 Android App 固定页面跳转问题
- 移除所有 AI 功能
- 块级编辑体验

## 获取 Notion Token

1. 访问 [Notion Integrations](https://www.notion.so/my-integrations) 页面
2. 点击 **"新建集成"**（New integration）
3. 填写名称（如 "Notion App"），选择关联的工作区
4. 创建后在 **"Secrets"** 区域复制 **Internal Integration Secret**（以 `ntn_` 或 `secret_` 开头）
5. 进入你需要操作的 Notion 页面，点击右上角 `...` → **连接** → 选择刚创建的集成
6. 将 Token 粘贴到 App 登录页面即可

## 技术栈
- Flutter (Dart)
- Notion API（`api.notion.com` REST 接口，不依赖网页加载）
- shared_preferences（Token 本地存储）

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

使用中国时区时间（`Asia/Shanghai`）自动生成版本号，格式 `YYYYMMDD`。

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
│   └── home/           # 页面列表 + 设置
└── main.dart           # 入口（无 Token 进登录页，有 Token 进主页）
```

> 说明：本项目采用 **Notion Integration Token + REST API** 方案，不内嵌 WebView 加载 `app.notion.com`。该网页加载方案在 `develop` 分支试验后因 Notion 浏览器指纹检测而废弃（见 `git log` WebView 相关提交）。

## License
MIT
