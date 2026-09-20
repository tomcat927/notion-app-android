# 应用内调试 / 崩溃日志

本项目只保留一个桌面入口：`Notion Lite`。日志查看能力已经收回到主 App 的设置页，避免安装后出现第二个 `Notion Logs` 图标造成混淆。

## 入口

打开 App 后进入：

```text
设置 → 查看调试 / 崩溃日志
```

这里可以查看、复制和清空应用内日志。

## 能看到什么

应用内日志包含：

- Flutter/应用日志：`notion_app_debug.log`。
- 原生崩溃日志：`notion_app_native_crash.log`。
- Android 11+ 历史退出原因：由主进程下次启动时通过 `ApplicationExitInfo` 写入原生崩溃日志。
- WebView renderer 崩溃/OOM：原生 `BrowserActivity` 会在 `onRenderProcessGone` 中记录并拦截，尽量避免系统直接杀死 App。

## 使用流程

1. 正常打开 `Notion Lite`。
2. 复现异常或闪退。
3. 重新打开 `Notion Lite`。
4. 进入 `设置 → 查看调试 / 崩溃日志`。
5. 复制日志文本发给排查者。

## 边界

应用内日志不是系统 logcat，无法保证捕获所有 native/WebView/系统层崩溃。如果应用内日志仍没有 `FATAL EXCEPTION`、`Fatal signal`、`chromium`、`WebView`、`RenderProcess` 等关键线索，继续使用 ADB 采集：

```powershell
powershell -ExecutionPolicy Bypass -File tools\collect_android_crash_logs.ps1 -Clear -Follow
```
