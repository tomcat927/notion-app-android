package com.notion.app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
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

        applyWebViewProxy()
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
}
