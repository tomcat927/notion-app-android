package com.notion.app

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Debug
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * 诊断日志文件（`notion_app_native_crash.log`）的共享写锁。
 *
 * 该文件有三个写入方（`[NativeCrash]` / `[BrowserWebView]` / `[Memory]`），各自线程不同；
 * 轮转逻辑是「读全文 → 截半 → 覆写」，并发会互相丢数据，故统一加锁串行化。
 */
internal val APP_DIAG_LOG_LOCK = Any()

/**
 * 内存诊断。
 *
 * 背景：日志里出现过 `reason=SIGNALED status=9`（SIGKILL）且 `importance=100`（前台）——
 * 这是**外部杀进程**（LMK / MIUI / Thanox 之类），App 自身抓不到 Java/native 异常，
 * 也就看不到原因。唯一能自证的办法是**在关键节点把内存水位记下来**，事后看趋势。
 *
 * 输出写入 `notion_app_native_crash.log`（tag `[Memory]`），与 `[NativeCrash]`/`[BrowserWebView]`
 * 同文件，上传诊断日志时会一并带出。
 *
 * 记录项：
 * - 系统：`availMemKB` / `totalMemKB` / `thresholdKB` / `lowMemory`
 * - 本进程：`pssKB`（总 PSS）、`nativeHeapKB`、`javaHeapUsedKB` / `javaHeapMaxKB`
 * - 可选 `extra`：调用方附加上下文（如是否还有常驻 WebView / 预热 WebView）。
 */
internal object MemoryDiagnostics {
    private const val MAX_LOG_BYTES = 256 * 1024
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "memory-diag") }

    fun snapshot(context: Context, label: String, extra: String? = null) {
        val appContext = context.applicationContext
        executor.execute {
            try {
                val am = appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                val memInfo = ActivityManager.MemoryInfo()
                am?.getMemoryInfo(memInfo)

                val debugInfo = Debug.MemoryInfo()
                Debug.getMemoryInfo(debugInfo)
                val pssKb = debugInfo.totalPss

                val runtime = Runtime.getRuntime()
                val javaUsedKb = (runtime.totalMemory() - runtime.freeMemory()) / 1024
                val javaMaxKb = runtime.maxMemory() / 1024

                val nativeHeapKb = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    Debug.getNativeHeapAllocatedSize() / 1024
                } else {
                    -1L
                }

                val sb = StringBuilder()
                sb.appendLine("label=$label")
                if (extra != null) sb.appendLine("extra=$extra")
                if (am != null) {
                    sb.appendLine("availMemKB=${memInfo.availMem / 1024}")
                    sb.appendLine("totalMemKB=${memInfo.totalMem / 1024}")
                    sb.appendLine("thresholdKB=${memInfo.threshold / 1024}")
                    sb.appendLine("lowMemory=${memInfo.lowMemory}")
                }
                sb.appendLine("pssKB=$pssKb")
                sb.appendLine("nativeHeapKB=$nativeHeapKb")
                sb.appendLine("javaHeapUsedKB=$javaUsedKb")
                sb.appendLine("javaHeapMaxKB=$javaMaxKb")

                append(appContext, sb.toString())
            } catch (ignored: Exception) {
                // 诊断永不抛异常。
            }
        }
    }

    private fun append(context: Context, message: String) {
        synchronized(APP_DIAG_LOG_LOCK) {
            val file = File(context.filesDir, "notion_app_native_crash.log")
            if (file.length() > MAX_LOG_BYTES) {
                // 保留后半段，避免历史被一次性清空（与 BrowserWebViewHolder 的轮转策略一致）。
                val content = file.readText()
                file.writeText(content.substring(content.length / 2))
            }
            val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US).format(Date())
            file.appendText("[$timestamp] [Memory]\n$message\n\n")
        }
    }
}
