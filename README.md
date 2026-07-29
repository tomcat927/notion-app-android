# Notion Android App

轻量、稳定、无 AI 的 Notion Android 客户端，基于 Flutter 构建。

## 核心特点
- Token 登录，无需 Notion 账号密码
- 解决官方 Android App 固定页面跳转问题
- 移除所有 AI 功能
- 块级编辑体验

## 获取 Notion Token

推荐使用 **Personal Access Token（推荐）**，直接用你的 Notion 账户权限，无需逐个页面分享：

1. 访问 [Notion Personal Access Tokens](https://www.notion.so/profile/integrations) 页面
2. 点击 **"新建 Token"**（New token）
3. 填写名称，勾选所需能力（至少勾选 **Read content**、**Update content**、**Insert content**）
4. 复制生成的 Token（以 `nup_` 开头）
5. 粘贴到 App 登录页面即可，你的所有页面都能直接访问

如果使用 Internal Integration Token（`ntn_` 开头），需要额外在 Notion 页面右上角 `...` → **连接** → 选择集成，比较繁琐。

## 技术栈
- Flutter (Dart)
- Notion API
- flutter_secure_storage（Token 安全存储）

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
├── core/               # 核心功能（认证、API 客户端）
├── features/           # 功能模块
│   ├── auth/           # 登录
│   ├── home/           # 主界面
│   └── editor/         # 编辑器
├── widgets/            # 自定义组件
└── main.dart           # 入口
```

## License
MIT
