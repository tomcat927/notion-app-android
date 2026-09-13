# Android 闪退日志采集

应用内的 `调试 / 崩溃日志` 可以捕获大多数 Flutter/Dart 异常，以及下次启动时 Android 11+ 提供的历史退出原因。但如果 WebView/native 进程直接杀死 App，应用可能来不及把日志写入文件，这时需要用 ADB 抓系统日志。

## 前提

- 手机开启 USB 调试，并授权当前电脑。
- 电脑已有 `adb`，并且 `adb` 在 `PATH` 中。
- 本仓库不要安装或运行本地 Flutter / Android / Gradle 构建；这里只采集设备日志。

## 推荐流程

1. 清空旧 logcat，并开始实时采集：

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\collect_android_crash_logs.ps1 -Clear -Follow
   ```

2. 不要关闭上面的 PowerShell 窗口，在手机上打开 App 并复现闪退。

3. 闪退发生后，回到 PowerShell 按 `Ctrl+C` 停止实时采集。

4. 再导出一次系统状态、dropbox 和历史退出原因：

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\collect_android_crash_logs.ps1
   ```

5. 把生成的目录或 `.zip` 发给排查者。默认输出在：

   ```text
   artifacts\adb-crash-logs\YYYYMMDD-HHMMSS
   ```

## 输出内容

- `logcat-live.txt`：实时采集日志，最适合抓“瞬间闪退”。
- `logcat-full.txt`：当前 logcat 缓冲区完整导出。
- `logcat-crash-context.txt`：围绕关键字截取的崩溃上下文。
- `dumpsys-activity-exit-info.txt`：Android 11+ 的历史退出原因。
- `dumpsys-dropbox-crashes.txt`：系统 dropbox 中的 Java/native crash 或 ANR 记录。
- `app-pid.txt`、`device-getprop.txt`、`dumpsys-package.txt`：设备和应用环境信息。

## 重点看什么

优先搜索这些关键字：

```text
FATAL EXCEPTION
Fatal signal
SIGSEGV
SIGABRT
crash_dump
AndroidRuntime
chromium
WebView
RenderProcess
ANR
com.notion.app
```

如果应用内日志只有 `Breadcrumb/BrowserOpen`，但没有 `Crash` 或 `原生/系统崩溃日志`，通常说明崩溃发生在 Flutter 捕获范围之外，ADB 日志更可靠。
