package com.notion.app

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class LogViewerActivity : Activity() {
    private lateinit var logTextView: TextView
    private var lastSnapshot: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Notion Logs"
        setContentView(createContentView())
        refreshLogs()
    }

    private fun createContentView(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setBackgroundColor(0xFFF7F8FA.toInt())
        }

        root.addView(
            TextView(this).apply {
                text = "Notion Logs"
                textSize = 22f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(0xFF111827.toInt())
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        root.addView(
            TextView(this).apply {
                text = "这是随主 App 安装的日志查看入口。主界面闪退后，直接打开这个图标查看已落盘日志和系统历史退出原因。"
                textSize = 13f
                setTextColor(0xFF4B5563.toInt())
                setPadding(0, dp(4), 0, dp(8))
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        root.addView(createButtonRow())

        logTextView = TextView(this).apply {
            textSize = 12f
            typeface = Typeface.MONOSPACE
            setTextColor(0xFF111827.toInt())
            setTextIsSelectable(true)
            setPadding(dp(10), dp(10), dp(10), dp(10))
        }

        val scrollView = ScrollView(this).apply {
            setBackgroundColor(0xFFFFFFFF.toInt())
            addView(
                logTextView,
                ScrollView.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }

        root.addView(
            scrollView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ).apply {
                topMargin = dp(10)
            },
        )

        return root
    }

    private fun createButtonRow(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(createButton("刷新") { refreshLogs() }, buttonLayoutParams())
            addView(createButton("复制") { copyLogs() }, buttonLayoutParams())
            addView(createButton("分享") { shareLogs() }, buttonLayoutParams())
            addView(createButton("清空") { clearLogs() }, buttonLayoutParams())
        }
    }

    private fun buttonLayoutParams(): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
            marginEnd = dp(6)
        }

    private fun createButton(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 13f
            isAllCaps = false
            setOnClickListener { action() }
        }

    private fun refreshLogs() {
        lastSnapshot = readLogSnapshot()
        logTextView.text = lastSnapshot
    }

    private fun copyLogs() {
        if (lastSnapshot.isBlank()) refreshLogs()
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Notion Logs", lastSnapshot))
        Toast.makeText(this, "日志已复制", Toast.LENGTH_SHORT).show()
    }

    private fun shareLogs() {
        if (lastSnapshot.isBlank()) refreshLogs()
        try {
            val exportDir = File(cacheDir, "log_exports").apply { mkdirs() }
            val timestamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
            val file = File(exportDir, "notion_app_logs_$timestamp.txt")
            file.writeText(lastSnapshot)

            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "Notion App 日志")
                putExtra(Intent.EXTRA_TEXT, "Notion App 日志已附加。")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "分享日志"))
        } catch (error: ActivityNotFoundException) {
            Toast.makeText(this, "没有可用的分享应用", Toast.LENGTH_SHORT).show()
        } catch (error: Exception) {
            Toast.makeText(this, "分享失败：${error.message ?: "未知错误"}", Toast.LENGTH_LONG).show()
        }
    }

    private fun clearLogs() {
        val deleted = mutableListOf<String>()
        logFileCandidates().forEach { file ->
            if (file.exists() && file.delete()) deleted.add(file.name)
        }
        val message = if (deleted.isEmpty()) {
            "没有可清空的 App 文件日志"
        } else {
            "已清空：${deleted.joinToString()}"
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        refreshLogs()
    }

    private fun readLogSnapshot(): String {
        val sections = mutableListOf<String>()
        sections.add(
            buildString {
                appendLine("采集时间=${formatTime(System.currentTimeMillis())}")
                appendLine("包名=$packageName")
                appendLine("进程=${currentProcessName()}")
            }.trimEnd(),
        )

        val flutterLog = flutterDebugLogFile()
        val flutterLogText = readTextTail(flutterLog, MAX_APP_LOG_BYTES)
        sections.add(
            if (flutterLogText.isBlank()) {
                "--- Flutter/应用日志 ---\n暂无日志\n路径=${flutterLog.absolutePath}"
            } else {
                "--- Flutter/应用日志 ---\n路径=${flutterLog.absolutePath}\n$flutterLogText"
            },
        )

        val nativeLog = nativeCrashLogFile()
        val nativeLogText = readTextTail(nativeLog, MAX_NATIVE_LOG_BYTES)
        sections.add(
            if (nativeLogText.isBlank()) {
                "--- 原生/崩溃日志 ---\n暂无日志\n路径=${nativeLog.absolutePath}"
            } else {
                "--- 原生/崩溃日志 ---\n路径=${nativeLog.absolutePath}\n$nativeLogText"
            },
        )

        sections.add("--- Android 历史退出原因 ---\n${historicalExitInfo()}")
        sections.add(
            "--- 提示 ---\n" +
                "如果这里仍没有 Fatal signal / FATAL EXCEPTION，上一次崩溃可能发生在系统或 WebView 层；这时继续用 tools/collect_android_crash_logs.ps1 抓 ADB 日志。",
        )

        return sections.joinToString("\n\n").trimEnd()
    }

    private fun historicalExitInfo(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return "当前 Android 版本低于 11，系统不提供 ApplicationExitInfo。"
        }

        return try {
            val activityManager = getSystemService(ActivityManager::class.java)
                ?: return "无法获取 ActivityManager。"
            val exits = activityManager.getHistoricalProcessExitReasons(packageName, 0, 10)
                .sortedByDescending { it.timestamp }

            if (exits.isEmpty()) {
                return "暂无历史退出记录。"
            }

            exits.joinToString("\n\n") { info ->
                buildString {
                    appendLine("[${formatTime(info.timestamp)}]")
                    appendLine("reason=${exitReasonLabel(info.reason)}")
                    appendLine("status=${info.status}")
                    appendLine("importance=${info.importance}")
                    appendLine("processName=${info.processName ?: ""}")
                    appendLine("description=${info.description ?: ""}")
                    readExitTrace(info).takeIf { it.isNotBlank() }?.let { trace ->
                        appendLine("--- trace ---")
                        appendLine(trace)
                    }
                }.trimEnd()
            }
        } catch (error: Exception) {
            "读取失败：${error.message ?: error.javaClass.name}"
        }
    }

    private fun readExitTrace(info: ApplicationExitInfo): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return ""
        return try {
            info.traceInputStream?.bufferedReader()?.use { reader ->
                reader.readText().take(MAX_EXIT_TRACE_CHARS)
            } ?: ""
        } catch (ignored: Exception) {
            ""
        }
    }

    private fun exitReasonLabel(reason: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return reason.toString()
        return when (reason) {
            ApplicationExitInfo.REASON_CRASH -> "CRASH"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
            ApplicationExitInfo.REASON_ANR -> "ANR"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
            ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
            else -> reason.toString()
        }
    }

    private fun readTextTail(file: File, maxBytes: Int): String {
        if (!file.isFile) return ""
        return try {
            if (file.length() <= maxBytes) {
                file.readText()
            } else {
                RandomAccessFile(file, "r").use { reader ->
                    val offset = file.length() - maxBytes
                    reader.seek(offset)
                    val buffer = ByteArray(maxBytes)
                    val read = reader.read(buffer)
                    "(日志过长，仅显示最后 $maxBytes bytes)\n" +
                        String(buffer, 0, read.coerceAtLeast(0))
                }
            }
        } catch (error: Exception) {
            "读取失败：${error.message ?: error.javaClass.name}"
        }.trimEnd()
    }

    private fun logFileCandidates(): List<File> = listOf(
        flutterDebugLogFile(),
        nativeCrashLogFile(),
    )

    private fun flutterDebugLogFile(): File {
        val dataDir = filesDir.parentFile ?: filesDir
        return File(dataDir, "app_flutter/notion_app_debug.log")
    }

    private fun nativeCrashLogFile(): File = File(filesDir, "notion_app_native_crash.log")

    private fun currentProcessName(): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                Application.getProcessName()
            } else {
                packageName
            }
        } catch (ignored: Exception) {
            packageName
        }
    }

    private fun formatTime(timestamp: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(timestamp))

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val MAX_APP_LOG_BYTES = 512 * 1024
        private const val MAX_NATIVE_LOG_BYTES = 256 * 1024
        private const val MAX_EXIT_TRACE_CHARS = 40_000
    }
}
