package com.notion.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebViewClient
import android.webkit.WebView
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
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
        startMainThreadWatchdog()
        if (intent?.getBooleanExtra("install_update", false) == true) {
            Handler(Looper.getMainLooper()).postDelayed({ installPendingUpdate() }, 1500)
        }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // UI_HIDDEN 是每次退到后台的正常信号，交给生命周期日志；这里只记录内存压力。
        if (level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) return
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            // 浏览器 WebView 未挂载时可直接回收，挂载中（用户正在看笔记）则保留。
            BrowserWebViewHolder.onMemoryPressure()
            writeNativeCrashLog(
                applicationContext,
                buildString {
                    appendLine("source=trimMemory")
                    appendLine("level=$level")
                },
            )
        }
    }

    private val mainThreadWatchHandler = Handler(Looper.getMainLooper())
    private var mainThreadWatchScheduledAt = 0L
    private val mainThreadWatchRunnable: Runnable = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val delayMs = now - mainThreadWatchScheduledAt
            if (mainThreadWatchScheduledAt > 0 &&
                delayMs > MAIN_THREAD_WATCH_DELAY_THRESHOLD_MS
            ) {
                writeNativeCrashLog(
                    applicationContext,
                    buildString {
                        appendLine("source=mainThreadWatchdog")
                        appendLine("delayMs=$delayMs")
                    },
                )
            }
            mainThreadWatchScheduledAt = now
            mainThreadWatchHandler.postDelayed(this, MAIN_THREAD_WATCH_INTERVAL_MS)
        }
    }

    private fun startMainThreadWatchdog() {
        mainThreadWatchScheduledAt = SystemClock.elapsedRealtime()
        mainThreadWatchHandler.postDelayed(
            mainThreadWatchRunnable,
            MAIN_THREAD_WATCH_INTERVAL_MS,
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra("install_update", false)) {
            installPendingUpdate()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installUpdate" -> installUpdate(call.argument<String>("path"), result)
                    "showUpdateNotification" -> {
                        showUpdateNotification()
                        result.success(true)
                    }
                    "enqueueUpdateDownload" -> enqueueUpdateDownload(call, result)
                    "queryUpdateDownload" -> queryUpdateDownload(call, result)
                    "processUpdateDownload" -> processUpdateDownload(call, result)
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
                       call.argument<Boolean>("showElementInspector"),
                        call.argument<String>("blockId"),
                        call.argument<String>("snippet"),
                       result,
                   )
                    "prewarm" -> {
                        prewarmWebView()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.notion.app/cookie")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCookies" -> result.success(getCookies(call.argument<String>("url")))
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
        return when (reason) {
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_ANR,
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
            ApplicationExitInfo.REASON_SIGNALED,
            ApplicationExitInfo.REASON_LOW_MEMORY,
            ApplicationExitInfo.REASON_USER_REQUESTED,
            ApplicationExitInfo.REASON_USER_STOPPED,
            ApplicationExitInfo.REASON_OTHER,
            -> true
            else -> false
        }
    }

    private fun exitReasonLabel(reason: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return reason.toString()
        return when (reason) {
            ApplicationExitInfo.REASON_CRASH -> "CRASH"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
            ApplicationExitInfo.REASON_ANR -> "ANR"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
            ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
            ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
            ApplicationExitInfo.REASON_OTHER -> "OTHER"
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

    private fun getCookies(url: String?): Map<String, String> {
        if (url.isNullOrBlank()) {
            return emptyMap()
        }

        return try {
            val cookieManager = CookieManager.getInstance()
            val rawCookieHeader = cookieManager.getCookie(url) ?: ""
            val cookies = mutableMapOf<String, String>()
            for (pair in rawCookieHeader.split(";")) {
                val trimmed = pair.trim()
                if (trimmed.isEmpty()) continue
                val eqIndex = trimmed.indexOf("=")
                if (eqIndex <= 0) continue
                val name = trimmed.substring(0, eqIndex).trim()
                val value = trimmed.substring(eqIndex + 1).trim()
                if (name.isNotEmpty() && value.isNotEmpty()) {
                    cookies[name] = value
                }
            }
            cookies
        } catch (error: Exception) {
            emptyMap()
        }
    }

    private var prewarmWebView: WebView? = null
    private var prewarmAttempt = 0
    private val prewarmHandler = Handler(Looper.getMainLooper())

    /**
     * 当前有效的轮询链编号。
     *
     * `onPageFinished` 在 SPA 上会**触发多次**（实测 2–3 次：主文档、客户端路由、
     * 以及 chunk 加载引起的后续回调）。早期实现每次都开一条新轮询链，且多条链
     * **共用**计数状态 —— 3 条链时每 3s 窗口内 idle 会被累加 3 次，
     * 只需一轮「静默」就凑满释放判据，页面稍微喘口气就被误判为加载完毕而提前释放
     * （实测出现过只加载 362 个资源就释放的异常轮次）。
     *
     * 这里改为单调自增的 token：每次 `onPageFinished` 作废旧链，只保留最新一条，
     * 且计数状态沿链传递（函数参数），不再共享字段。
     */
    private var prewarmPollToken = 0

    /** logcat 标签：`adb logcat -s NotionPrewarm` 可直接看预热生命周期。 */
    private val prewarmTag = "NotionPrewarm"

    /**
     * 预热 WebView 的起始 URL。
     *
     * 必须与笔记页**同源**：笔记最终加载的是 `app.notion.com`
     * （`www.notion.so/<pageId>` 会 302 跳过来），SPA 的 ~900 个 chunk 也全在
     * `app.notion.com` 上。
     *
     * 历史上这里写的是 `https://www.notion.so`（营销站，与笔记**不同源**），
     * 实测它返回 200 且不跳转 —— 预热它只会写 cookie，**一个 SPA chunk 都灌不进缓存**，
     * 等于白预热。证据见 docs/perf-analysis/notion-log-analysis-v5-cold-cache-ab.md。
     */
    private val prewarmUrl = "https://app.notion.com"

    /**
     * `onPageFinished` 之后**不再用固定等待**，改为轮询「还有没有新资源加载完」。
     *
     * SPA 的 `onPageFinished` 只代表「主文档 + 同步子资源」完成；真正的懒加载 chunk
     * 是在这之后才开始下载的。若在 `onPageFinished` 里立刻 `destroy()`，
     * 这些在途请求会被一并掐断，chunk 落不进 HTTP 缓存，预热依然无效。
     *
     * **为什么不能用固定 10s**（实测，见 docs §7.5）：预热能灌进多少 chunk 完全取决于
     * 「链路速度 × 等待时长」。同一段代码、只因链路快慢不同，实测缓存条目数在
     * **197 ~ 618 之间摆动（3 倍差距）**：
     *   - 快链路：`onPageFinished` 1.5s，10s 内就灌满 618 条；
     *   - 慢链路：`onPageFinished` 3.5s，10s 到点时只灌进 ~250 条就被掐断。
     * 而一篇笔记实际要用 ~950 个资源 —— 慢链路下预热只覆盖了 1/3，这正是 stall 仍在的原因。
     * 所以判据必须是「加载真的停了」，而不是「等够了」。
     * （改成自适应后稳定在 ~920 个资源，见 §7.5。）
     */
    private val prewarmPollIntervalMs = 3_000L

    /** 连续这么多次轮询都没有新资源完成，才认为加载停了（3 × 3s ≈ 9s 静默）。 */
    private val prewarmIdlePollsToRelease = 3

    /**
     * 静默判据的**下限保护**：从首次 `onPageFinished` 起，至少等这么久才允许释放。
     *
     * 单靠「9s 静默」仍可能被骗：SPA 是分波加载的，若两波之间的空档超过 9s，
     * 会被误判为加载完毕而提前释放。实测出现过只加载 362 个资源就释放的轮次。
     * 正常轮次在 onPageFinished 后约 19s 才静默，故取 20s 作下限 —— 对正常路径
     * 几乎无影响，只用于拦掉过早释放。
     */
    private val prewarmMinSettleMs = 20_000L

    /** 本轮预热首次 `onPageFinished` 的时刻（`SystemClock.elapsedRealtime`）。 */
    private var prewarmFirstFinishedAtMs = 0L

    /**
     * 兜底：单次预热最多存活这么久。
     *
     * 实测预热本身也是一次完整 SPA 冷加载，会撞上链路抖动。这是**绝对上限**，
     * 大多数情况会先被「静默释放」触发（快链路约 20–30s 就静默）。
     *
     * 120s 曾不够：实测慢链路一轮在 120s 到点时资源数仍在以约 5 个/秒的速度增长
     * （648 个），被硬掐断后只灌进 592 条；按增速推算要 ~175s 才能到 ~920。
     * 故放宽到 240s。
     *
     * 放宽的代价可控：预热下载的就是笔记打开时本来也要下载的那批 chunk（同一批资源），
     * 只是提前下载；且用户一旦打开笔记会立即释放预热（见 openPageBrowser），不会抢带宽。
     */
    private val prewarmMaxLifetimeMs = 240_000L

    /**
     * 预热失败（主文档加载出错）时的重试次数与间隔。
     *
     * 实测预热成功率约 7/10：失败时缓存停在 64K，笔记退回冷加载。
     * 且失败**成簇**出现（与网络/节点状态相关），重试可覆盖这类瞬时故障。
     */
    private val prewarmMaxAttempts = 3
    private val prewarmRetryDelayMs = 3_000L

    private fun prewarmWebView() {
        if (prewarmWebView != null) return
        startPrewarmAttempt()
    }

    private fun startPrewarmAttempt() {
        prewarmAttempt += 1
        val attempt = prewarmAttempt
        prewarmFirstFinishedAtMs = 0L
        val webView = WebView(this)
        prewarmWebView = webView
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            cacheMode = WebSettings.LOAD_CACHE_ELSE_NETWORK
            // 必须与 BrowserWebViewHolder.MOBILE_USER_AGENT 完全一致：
            // 若响应带 Vary: User-Agent，UA 不一致会让预热灌的缓存命中不到。
            userAgentString = "Mozilla/5.0 (Linux; Android 10; K) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/141.0.0.0 Mobile Safari/537.36"
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                // 迟到的回调：这个 WebView 已被重试替换/释放，忽略。
                val target = view ?: return
                if (prewarmWebView !== target) return
                Log.i(prewarmTag, "attempt $attempt onPageFinished: $url")
                // 不能立刻 destroy：chunk 还在下载，掐断就白预热了。
                // 改为轮询「还有没有新资源完成」，静默后才释放（见 prewarmPollIntervalMs 注释）。
                if (prewarmFirstFinishedAtMs == 0L) {
                    prewarmFirstFinishedAtMs = SystemClock.elapsedRealtime()
                }
                // 作废旧链（onPageFinished 会触发多次），只保留最新一条。
                prewarmPollToken += 1
                Log.i(prewarmTag, "attempt $attempt start poll chain=$prewarmPollToken")
                postPrewarmPoll(target, attempt, prewarmPollToken, -1, 0)
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?,
            ) {
                if (request?.isForMainFrame != true) return
                if (prewarmWebView !== view) return
                val detail = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    "code=${error?.errorCode} desc=${error?.description}"
                } else {
                    "unknown"
                }
                Log.w(prewarmTag, "attempt $attempt main-frame error: $detail")
                schedulePrewarmRetry(attempt, detail)
            }
        }
        Log.i(prewarmTag, "attempt $attempt loadUrl $prewarmUrl")
        webView.loadUrl(prewarmUrl)
        prewarmHandler.postDelayed({ releasePrewarmWebView("max-lifetime") }, prewarmMaxLifetimeMs)
    }

    /**
     * 轮询 SPA 的「已完成资源数」，连续 N 次不再增长就释放预热 WebView。
     *
     * `performance.getEntriesByType('resource')` 只统计**已完成**的资源，
     * 所以它的长度不再变化 == 页面已经没有在飞的请求了 —— 这正是我们要的释放时机。
     */
    private fun postPrewarmPoll(
        view: WebView,
        attempt: Int,
        token: Int,
        lastCount: Int,
        idlePolls: Int,
    ) {
        prewarmHandler.postDelayed(
            {
                // 迟到的回调：WebView 已被重试替换/释放，或本链已被更新的链取代。
                if (prewarmWebView !== view) return@postDelayed
                if (token != prewarmPollToken) {
                    Log.i(prewarmTag, "attempt $attempt poll chain=$token superseded")
                    return@postDelayed
                }
                val script = "(function(){try{" +
                    "return performance.getEntriesByType('resource').length;" +
                    "}catch(e){return -1}})()"
                view.evaluateJavascript(script) { raw ->
                    if (prewarmWebView !== view) return@evaluateJavascript
                    if (token != prewarmPollToken) return@evaluateJavascript
                    val count = raw?.trim()?.trim('"')?.toIntOrNull() ?: -1
                    val nextIdle = if (count > 0 && count == lastCount) idlePolls + 1 else 0
                    val nextLast = if (count > 0) count else lastCount
                    Log.i(
                        prewarmTag,
                        "attempt $attempt chain=$token resources=$count idle=${nextIdle}x",
                    )
                    val settled =
                        SystemClock.elapsedRealtime() - prewarmFirstFinishedAtMs >= prewarmMinSettleMs
                    if (nextIdle >= prewarmIdlePollsToRelease && settled) {
                        releasePrewarmWebView(
                            "idle ${nextIdle * prewarmPollIntervalMs}ms @ $count resources",
                        )
                    } else {
                        if (nextIdle >= prewarmIdlePollsToRelease) {
                            // 静默够了但还没到下限：继续等，别被两波之间的空档骗了。
                            Log.i(prewarmTag, "attempt $attempt idle but not settled yet")
                        }
                        postPrewarmPoll(view, attempt, token, nextLast, nextIdle)
                    }
                }
            },
            prewarmPollIntervalMs,
        )
    }

    private fun schedulePrewarmRetry(attempt: Int, reason: String) {
        // 先释放（顺带取消 pending 的 settle / max-lifetime 回调），再挂重试，
        // 顺序不能反 —— releasePrewarmWebView 会清掉 handler 上的所有回调。
        releasePrewarmWebView(reason)
        if (attempt >= prewarmMaxAttempts) {
            Log.w(prewarmTag, "giving up after $attempt attempt(s), last=$reason")
            return
        }
        prewarmHandler.postDelayed({ startPrewarmAttempt() }, prewarmRetryDelayMs)
    }

    private fun releasePrewarmWebView(reason: String) {
        prewarmHandler.removeCallbacksAndMessages(null)
        prewarmWebView?.destroy()
        prewarmWebView = null
        Log.i(prewarmTag, "released ($reason)")
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
       showElementInspector: Boolean?,
        blockId: String?,
        snippet: String?,
       result: MethodChannel.Result,
   ) {
        if (pageId.isNullOrBlank()) {
            result.error("invalid_argument", "缺少页面 ID", null)
            return
        }

        // 用户要开笔记了：立刻停掉后台预热，避免它和笔记页抢同一条链路的带宽。
        // 此时预热该灌的 chunk 已经灌得差不多了（实测 4s 就有 ~250 条、11s 到 ~580 条），
        // 继续跑只会互相拖慢。
        if (prewarmWebView != null) {
            releasePrewarmWebView("page opening")
        }

        try {
            val intent = Intent(this, BrowserActivity::class.java).apply {
                putExtra(BrowserActivity.EXTRA_PAGE_ID, pageId)
                putExtra(BrowserActivity.EXTRA_TITLE, title.orEmpty())
                putExtra(
                    BrowserActivity.EXTRA_OPEN_EXTERNAL_LINKS_IN_APP,
                    openExternalLinksInApp == true,
                )
               putExtra(
                   BrowserActivity.EXTRA_SHOW_ELEMENT_INSPECTOR,
                   showElementInspector == true,
               )
                putExtra(BrowserActivity.EXTRA_BLOCK_ID, blockId.orEmpty())
                putExtra(BrowserActivity.EXTRA_SNIPPET, snippet.orEmpty())
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

        val host = proxy?.host
        val port = proxy?.port

        if (host == null || port == null) {
            // No system proxy detected — clear any previously set proxy override
            // (e.g., Clash was closed but left WebView proxy stale).
            try {
                ProxyController.getInstance().clearProxyOverride(
                    Executors.newSingleThreadExecutor(),
                    Runnable {},
                )
            } catch (_: Exception) {
                // Best-effort; WebView can still load directly.
            }
            return
        }

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

    private fun showUpdateNotification() {
        UpdateDownloadManager.showUpdateReadyNotification(this)
    }

    private fun enqueueUpdateDownload(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val sha256 = call.argument<String>("sha256")
        val title = call.argument<String>("title")
        if (url.isNullOrBlank() || sha256.isNullOrBlank()) {
            result.error("invalid_argument", "缺少下载参数", null)
            return
        }
        try {
            result.success(
                UpdateDownloadManager.enqueue(this, url, sha256, title ?: "Notion Lite 更新包"),
            )
        } catch (error: Exception) {
            result.error("enqueue_failed", error.message ?: "无法启动系统下载", null)
        }
    }

    private fun queryUpdateDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = (call.argument<Any?>("id") as? Number)?.toLong() ?: -1L
        try {
            result.success(UpdateDownloadManager.query(this, id))
        } catch (error: Exception) {
            result.error("query_failed", error.message ?: "查询下载状态失败", null)
        }
    }

    private fun processUpdateDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = (call.argument<Any?>("id") as? Number)?.toLong() ?: -1L
        try {
            UpdateDownloadManager.processCompleted(this, id)
            result.success(true)
        } catch (error: Exception) {
            result.error("process_failed", error.message ?: "处理下载完成失败", null)
        }
    }

    private fun installPendingUpdate() {
        val apkFile = File(cacheDir, "apk_updates/notion-app-update.apk")
        if (!apkFile.exists()) return
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apkFile)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (_: Exception) {}
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
        private const val MAIN_THREAD_WATCH_INTERVAL_MS = 5_000L
        private const val MAIN_THREAD_WATCH_DELAY_THRESHOLD_MS = 10_000L
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
