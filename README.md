# Notion Android App

轻量、稳定、无 AI 的 Notion Android 客户端，基于 Flutter + WebView 构建。

## 核心特点
- 使用 Notion 官方网页登录，保留完整编辑能力
- Notion 域名留在 App 内打开，外部链接跳系统浏览器
- WebView 不兼容时可通过 Chrome Custom Tabs 兼容入口打开
- 移除所有 AI 功能
- 支持 Notion 网页版的富文本、图片、数据库等能力

## 登录方式

App 内置 WebView 加载 Notion 官方登录页：

```text
https://app.notion.com/login
```

用户直接使用 Notion 账号登录。登录态由 WebView Cookie 保存，浏览器里的登录态不会自动同步到 App 内。

## 链接打开规则

- `notion.com`、`notion.so` 及其子域名在 App 内打开
- 其他外部链接交给 Android 系统浏览器打开

## WebView 兼容性

Notion Web 对浏览器内核要求较高。部分基于系统 WebView 的轻量浏览器或旧版 Android System WebView 会提示：

```text
Your browser is not compatible with Notion.
```

App 提供“兼容浏览器打开”入口，使用 Android Custom Tabs 调用设备上的兼容浏览器访问 Notion。

## 技术栈
- Flutter (Dart)
- webview_flutter
- url_launcher
- shared_preferences

## 快速开始

```bash
git clone https://github.com/tomcat927/notion-app-android.git
cd notion-app-android
flutter pub get
flutter run
```

## 构建

```bash
# APK
flutter build apk --release --split-per-abi
```

项目当前只构建 APK，GitHub Actions 会把 APK 直接上传到 GitHub Releases。

## 版本号

开发测试版本从 `develop` 分支生成 Test Release，正式版本从 `main` 分支生成 Release。

## 项目结构

```
lib/
├── app/theme/          # 主题管理
├── core/               # 核心功能（日志等）
├── features/           # 功能模块
│   ├── home/           # 主界面
│   ├── logs/           # 调试日志
│   └── settings/       # 设置
├── widgets/            # 自定义组件
└── main.dart           # 入口
```

## License
MIT
