package com.notion.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val channelName = "com.notion.app/browser"
    private val browserPackages = listOf(
        "com.android.chrome",
        "com.chrome.beta",
        "com.microsoft.emmx",
        "com.sec.android.app.sbrowser",
        "org.mozilla.firefox"
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            if (call.method != "openInBrowser") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val url = call.argument<String>("url")
            if (url.isNullOrBlank()) {
                result.error("invalid_url", "URL is empty", null)
                return@setMethodCallHandler
            }

            result.success(openInPreferredBrowser(url))
        }
    }

    private fun openInPreferredBrowser(url: String): Boolean {
        val uri = Uri.parse(url)
        for (packageName in browserPackages) {
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage(packageName)
                addCategory(Intent.CATEGORY_BROWSABLE)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            try {
                startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                continue
            }
        }

        return false
    }
}
