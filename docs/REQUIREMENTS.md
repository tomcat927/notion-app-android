# Notion Android App - 需求文档

**版本**：v0.1  
**状态**：需求设计阶段  
**平台**：Android（优先开发）  
**核心目标**：解决官方 Android App 的“固定页面跳转”顽疾 + 移除 AI 功能

## 1. 产品愿景

构建一个**轻量、稳定、无 AI** 的 Notion Android 客户端，对标官方 App 的阅读/编辑体验，解决官方版卡顿、固定页面跳转等问题。

## 2. 核心功能

### 2.1 登录
- 支持 **Notion Internal Integration Token** 登录（推荐方式）。
- 支持从 Notion 网页版复制 Token 并粘贴登录。
- 登录后自动获取用户空间 + 页面列表。

### 2.2 主界面
- **Tab 式主页**（推荐使用 TabLayout + ViewPager2，类似官方 App）。
- **左侧/顶部侧边栏**：空间列表、最近页面、收藏、搜索。
- **主内容区**：支持页面预览 + 编辑（块级编辑）。
- **底部导航栏**：首页、搜索、我的。

### 2.3 编辑体验
- 支持 **块级编辑**（标题、段落、列表、表格等）。
- 支持 **Markdown 切换**（可选）。
- 支持 **图片上传**（相册/拍照）。
- 支持 **代码块**、**数据库** 等基础渲染。
- 支持 **撤销/重做**、**格式刷** 等常用操作。

### 2.4 其他必备功能
- **多标签**（可选，允许在同一页面打开多个页面）。
- **搜索**：快速搜索页面和内容。
- **收藏/归档**：收藏重要页面。
- **离线缓存**：支持缓存页面内容（可选）。
- **自动保存**：编辑内容自动保存到 Notion。
- **更新提示**：自动检查 App 更新。

### 2.5 不包含的功能
- AI 相关功能（ChatGPT、Notion AI）。
- 网页登录方式（仅 Token 方式）。
- Windows 桌面端（暂不开发）。

## 3. 技术选型建议（Android 端）

**推荐栈**：
- **框架**：Flutter（推荐）或 Jetpack Compose（Android 原生）
- **语言**：Kotlin（Compose）或 Dart（Flutter）
- **UI 组件**：Material 3 + custom theme
- **API 客户端**：notion-api-utils（Dart）或 notion-java-client（Java/Kotlin）
- **渲染引擎**：支持 Markdown + Notion 块级渲染（flutter_markdown 或类似）

**为什么推荐 Flutter？**
- 开发效率高（跨平台，但你只要求 Android）。
- 社区已有 Notion 相关 Flutter 插件（如 notion-flutter）。
- 比原生 Compose 开发更快。

## 4. 非功能需求
- **性能**：页面加载 < 600ms，编辑流畅。
- **稳定性**：解决官方 App 的固定页面跳转问题（使用稳定 WebView + Token 机制）。
- **安全性**：Token 只在本地存储（AES 加密），不上传云端。
- **可维护性**：代码结构清晰，注释详尽。

## 5. 优先级（推荐开发顺序）
1. Token 登录 + 空间列表 + 基本页面预览（MVP）
2. 主界面 Tab + 页面编辑核心功能
3. 搜索、收藏、快捷操作
4. 离线缓存、自动保存
5. 优化性能（解决固定跳转）

## 6. 参考项目
- https://github.com/puneetsl/lotion （Electron 桌面版参考）
- https://github.com/0xZhangKe/NotionLight （Android 轻量级 App 参考）

## 7. 版本号管理
- 使用 **中国时区时间** 生成版本号（格式：`YYYYMMDD`）。
- 例如：2026-07-29 → `20260729`
- 每次发布前检查 `pubspec.yaml` 中的版本号。

---
*此文档由 AI 生成，供后续开发参考*
