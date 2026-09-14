package com.notion.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.webkit.WebView
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.system.exitProcess

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installCrashHandler()
        super.onCreate(savedInstanceState)
        writeHistoricalProcessExits()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installUpdate" -> installUpdate(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/proxy")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSystemProxy" -> result.success(getSystemProxy())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/webview")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFileUri" -> getFileUri(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/browser")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openPage" -> openPageBrowser(
                        call.argument<String>("pageId"),
                        call.argument<String>("title"),
                        call.argument<Boolean>("openExternalLinksInApp"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/crash_logs")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readNativeCrashLog" -> result.success(readNativeCrashLog())
                    "clearNativeCrashLog" -> {
                        clearNativeCrashLog()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/cache_cleanup")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "clearWebViewCache" -> clearWebViewCache(result)
                    else -> result.notImplemented()
                }
            }

        applyWebViewProxy()
    }

    private fun installCrashHandler() {
        if (crashHandlerInstalled) return
        crashHandlerInstalled = true

        val appContext = applicationContext
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            writeNativeCrashLog(
                appContext,
                buildString {
                    appendLine("source=uncaughtException")
                    appendLine("thread=${thread.name}")
                    appendLine("exception=${throwable.javaClass.name}: ${throwable.message ?: ""}")
                    appendLine(stackTraceToString(throwable))
                },
            )
            if (previousHandler != null) {
                previousHandler.uncaughtException(thread, throwable)
            } else {
                exitProcess(10)
            }
        }
    }

    private fun writeHistoricalProcessExits() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

        try {
            val activityManager = getSystemService(ActivityManager::class.java) ?: return
            val prefs = getSharedPreferences("native_crash_log_state", Context.MODE_PRIVATE)
            val lastTimestamp = prefs.getLong("last_exit_timestamp", 0L)
            var newestTimestamp = lastTimestamp

            activityManager.getHistoricalProcessExitReasons(packageName, 0, 10)
                .sortedBy { it.timestamp }
                .forEach { info ->
                    if (info.timestamp <= lastTimestamp) return@forEach
                    if (!shouldLogExitReason(info.reason)) return@forEach
                    newestTimestamp = maxOf(newestTimestamp, info.timestamp)

                    val trace = readExitTrace(info)
                    writeNativeCrashLog(
                        applicationContext,
                        buildString {
                            appendLine("source=historicalProcessExit")
                            appendLine("reason=${exitReasonLabel(info.reason)}")
                            appendLine("status=${info.status}")
                            appendLine("importance=${info.importance}")
                            appendLine("processName=${info.processName ?: ""}")
                            appendLine("description=${info.description ?: ""}")
                            if (trace.isNotBlank()) {
                                appendLine("--- trace ---")
                                appendLine(trace)
                            }
                        },
                    )
                }

            if (newestTimestamp > lastTimestamp) {
                prefs.edit().putLong("last_exit_timestamp", newestTimestamp).apply()
            }
        } catch (ignored: Exception) {
            // Historical process-exit logging is best-effort only.
        }
    }

    private fun shouldLogExitReason(reason: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return reason == ApplicationExitInfo.REASON_CRASH ||
            reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
            reason == ApplicationExitInfo.REASON_ANR ||
            reason == ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE
    }

    private fun exitReasonLabel(reason: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return reason.toString()
        return when (reason) {
            ApplicationExitInfo.REASON_CRASH -> "CRASH"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
            ApplicationExitInfo.REASON_ANR -> "ANR"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
            else -> reason.toString()
        }
    }

    private fun readExitTrace(info: ApplicationExitInfo): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return ""
        return try {
            info.traceInputStream?.bufferedReader()?.use { reader ->
                reader.readText().take(MAX_TRACE_CHARS)
            } ?: ""
        } catch (ignored: Exception) {
            ""
        }
    }

    private fun readNativeCrashLog(): String {
        val file = nativeCrashLogFile(applicationContext)
        return try {
            if (file.isFile) file.readText() else ""
        } catch (ignored: Exception) {
            ""
        }
    }

    private fun clearNativeCrashLog() {
        try {
            val file = nativeCrashLogFile(applicationContext)
            if (file.exists()) file.delete()
        } catch (ignored: Exception) {
            // Best-effort cleanup.
        }
    }

    private fun clearWebViewCache(result: MethodChannel.Result) {
        try {
            WebView(this).apply {
                clearCache(true)
                destroy()
            }
            result.success(true)
        } catch (error: Exception) {
            result.error(
                "webview_cache_cleanup_failed",
                error.message ?: "无法清理 WebView 缓存",
                null,
            )
        }
    }

    private fun getSystemProxy(): Map<String, String?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return mapOf("host" to null, "port" to null)
        }

        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val proxy = connectivityManager?.defaultProxy
        val host = proxy?.host
        val port = proxy?.port?.toString()

        return mapOf("host" to host, "port" to port)
    }

    private fun getFileUri(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_argument", "缺少文件路径", null)
            return
        }

        val file = File(path)
        if (!file.isFile) {
            result.error("file_not_found", "文件不存在: $path", null)
            return
        }

        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            result.success(uri.toString())
        } catch (error: Exception) {
            result.error("file_uri_failed", error.message ?: "无法生成 content URI", null)
        }
    }

    private fun openPageBrowser(
        pageId: String?,
        title: String?,
        openExternalLinksInApp: Boolean?,
        result: MethodChannel.Result,
    ) {
        if (pageId.isNullOrBlank()) {
            result.error("invalid_argument", "缺少页面 ID", null)
            return
        }

        try {
            val intent = Intent(this, BrowserActivity::class.java).apply {
                putExtra(BrowserActivity.EXTRA_PAGE_ID, pageId)
                putExtra(BrowserActivity.EXTRA_TITLE, title.orEmpty())
                putExtra(
                    BrowserActivity.EXTRA_OPEN_EXTERNAL_LINKS_IN_APP,
                    openExternalLinksInApp == true,
                )
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("browser_open_failed", error.message ?: "无法打开内嵌浏览器", null)
        }
    }

    private fun applyWebViewProxy() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) return

        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val proxy = connectivityManager?.defaultProxy
        val host = proxy?.host ?: return
        val port = proxy?.port ?: return

        try {
            val proxyConfig = ProxyConfig.Builder()
                .addProxyRule("$host:$port")
                .build()

            ProxyController.getInstance().setProxyOverride(
                proxyConfig,
                Executors.newSingleThreadExecutor(),
                Runnable {},
            )
        } catch (_: Exception) {
            // WebView proxy support is best-effort; the page can still load directly.
        }
    }

    private fun installUpdate(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_argument", "缺少更新包路径", null)
            return
        }

        val apkFile = File(path)
        if (!apkFile.isFile) {
            result.error("file_not_found", "更新包不存在", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        .setData(Uri.parse("package:$packageName")),
                )
                result.error("permission_required", "需要允许安装未知应用", null)
            } catch (_: ActivityNotFoundException) {
                result.error("permission_unavailable", "设备不支持安装权限设置入口", null)
            }
            return
        }

        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apkFile)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("install_failed", error.message ?: "无法启动安装器", null)
        }
    }

    companion object {
        private const val MAX_NATIVE_CRASH_LOG_BYTES = 256 * 1024
        private const val MAX_TRACE_CHARS = 40_000
        @Volatile
        private var crashHandlerInstalled = false

        private fun nativeCrashLogFile(context: Context): File =
            File(context.filesDir, "notion_app_native_crash.log")

        private fun writeNativeCrashLog(context: Context, message: String) {
            try {
                val file = nativeCrashLogFile(context)
                if (file.length() > MAX_NATIVE_CRASH_LOG_BYTES) {
                    file.writeText("")
                }
                val timestamp = SimpleDateFormat(
                    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                    Locale.US,
                ).format(Date())
                file.appendText("[$timestamp] [NativeCrash]\n$message\n\n")
            } catch (ignored: Exception) {
                // Never throw from crash logging.
            }
        }

        private fun stackTraceToString(throwable: Throwable): String {
            val writer = StringWriter()
            throwable.printStackTrace(PrintWriter(writer))
            return writer.toString()
        }
    }

}
