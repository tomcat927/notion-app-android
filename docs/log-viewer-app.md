# 附带日志查看入口

本项目在同一个 APK 内提供第二个桌面入口：`Notion Logs`。

## 为什么不是完全独立的第二个 APK

Android 普通应用不能静默安装另一个 APK；真正拆成两个 package 后，监控 App 也不能直接读取主 App 私有目录。为了让安装主 App 后自动带上日志查看能力，并且能读取同一份私有日志，当前实现采用“同包第二 launcher activity”。

效果上，桌面会出现两个图标：

- `Notion App`：正常使用入口。
- `Notion Logs`：独立原生活动，运行在 `:logviewer` 进程，用于查看、复制、分享、清空日志。

## 能看到什么

`Notion Logs` 会读取：

- Flutter/应用日志：`notion_app_debug.log`。
- 原生崩溃日志：`notion_app_native_crash.log`。
- Android 11+ 历史退出原因：`ApplicationExitInfo`，包括 `CRASH`、`CRASH_NATIVE`、`ANR`、`LOW_MEMORY` 等。

## 使用流程

1. 正常打开 `Notion App`。
2. 复现闪退。
3. 回到桌面，打开 `Notion Logs`。
4. 点 `刷新` 查看最新日志。
5. 点 `复制` 或 `分享` 发出日志文本。

## 边界

`Notion Logs` 不是系统应用，不能直接读取完整系统 logcat。如果日志查看入口里仍然没有 `FATAL EXCEPTION`、`Fatal signal`、`chromium`、`WebView` 等关键线索，继续使用 ADB 采集：

```powershell
powershell -ExecutionPolicy Bypass -File tools\collect_android_crash_logs.ps1 -Clear -Follow
```
