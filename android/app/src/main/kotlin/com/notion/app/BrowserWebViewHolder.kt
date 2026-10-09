package com.notion.app

import android.content.Context
import android.content.MutableContextWrapper
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * App 级 WebView 持有器：把 WebView 生命周期与 BrowserActivity 解耦。
 *
 * 后台任务合并为单 task 后，BrowserActivity 随返回键正常销毁；WebView 常驻在
 * 这里，重新打开页面时复用已加载的 SPA 客户端（秒开），空闲 5 分钟自动销毁释放。
 *
 * 约束：JS Bridge 一旦注入就随已加载页面存续（removeJavascriptInterface 摘不掉
 * 存活页面 window 上的旧对象），因此所有 Bridge（含图片查看器）都驻留本单例、
 * 经 currentActivity 路由回调，绝不直接持有 Activity，否则 WebView 复用时会
 * 回调到已销毁的 Activity 实例。
 */
internal object BrowserWebViewHolder {

    private var appContext: Context? = null
    private var webView: WebView? = null
    private var contextWrapper: MutableContextWrapper? = null
    private var lightbox: ImageLightbox? = null

    internal var currentActivity: BrowserActivity? = null
        private set

    internal val mainHandler = Handler(Looper.getMainLooper())
    private val rendererGoneTimestamps = mutableListOf<Long>()
    private val logExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "browser-log")
    }

    private val idleReleaseRunnable = Runnable {
        writeBrowserLog("idle release timeout, releasing webview")
        destroyWebView()
        // WebView 被释放时 Activity 可能还挂在后台任务里，一并结束避免留下空白页。
        currentActivity?.finish()
    }

    /**
     * 取出常驻 WebView（不存在则创建），并绑定到当前 Activity。
     * 返回后由 Activity 挂进自己的视图树。
     */
    internal fun obtain(activity: BrowserActivity): WebView {
        cancelIdleRelease()
        if (appContext == null) appContext = activity.applicationContext
        val previous = currentActivity
        if (previous != null && previous !== activity) {
            writeBrowserLog("obtain: previous activity still bound, replacing")
        }
        currentActivity = activity
        var view = webView
        if (view == null) {
            view = createWebView()
        }
        (view.parent as? ViewGroup)?.removeView(view)
        contextWrapper?.setBaseContext(activity)
        return view
    }

    /** Activity 销毁时解绑：WebView 摘下来留用，并启动空闲释放计时。 */
    internal fun detach(activity: BrowserActivity) {
        if (currentActivity !== activity) return
        currentActivity = null
        val view = webView ?: return
        (view.parent as? ViewGroup)?.removeView(view)
        val context = appContext
        if (context != null) {
            contextWrapper?.setBaseContext(context)
        }
        startIdleRelease()
    }

    internal fun startIdleRelease() {
        if (webView == null) return
        mainHandler.removeCallbacks(idleReleaseRunnable)
        mainHandler.postDelayed(idleReleaseRunnable, IDLE_RELEASE_DELAY_MS)
    }

    internal fun cancelIdleRelease() {
        mainHandler.removeCallbacks(idleReleaseRunnable)
    }

    /** 系统内存压力回调（来自 MainActivity.onTrimMemory）：只回收未挂载的 WebView。 */
    internal fun onMemoryPressure() {
        if (currentActivity != null) return
        destroyWebView()
    }

    internal fun injectImageClickScript(view: WebView) {
        lightbox?.injectClickScript(view)
    }

    internal fun writeBrowserLog(message: String) {
        logExecutor.execute {
            val context = appContext ?: return@execute
            try {
                val file = File(context.filesDir, "notion_app_native_crash.log")
                if (file.length() > MAX_BROWSER_LOG_BYTES) {
                    val content = file.readText()
                    file.writeText(content.substring(content.length / 2))
                }
                val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US).format(Date())
                file.appendText("[$timestamp] [BrowserWebView]\n$message\n\n")
            } catch (ignored: Exception) {
                // Never fail because of diagnostics.
            }
        }
    }

    private fun createWebView(): WebView {
        val wrapper = MutableContextWrapper(appContext!!)
        contextWrapper = wrapper
        val view = WebView(wrapper)
        webView = view

        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            cacheMode = WebSettings.LOAD_CACHE_ELSE_NETWORK
            userAgentString = MOBILE_USER_AGENT
        }
        view.addJavascriptInterface(ElementInspectorBridge(), "NotionElementInspector")
        view.addJavascriptInterface(OutlineBridge(), "NotionOutline")
        view.addJavascriptInterface(InPageSearchBridge(), "NotionInPageSearchNative")
        val box = ImageLightbox { currentActivity }
        lightbox = box
        box.install(view)
        CookieManager.getInstance().setAcceptCookie(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        }
        view.webViewClient = createWebViewClient()
        view.webChromeClient = createWebChromeClient()
        return view
    }

    private fun createWebViewClient(): WebViewClient = object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && !request.isForMainFrame) {
                return false
            }
            return shouldOverrideNavigation(request.url)
        }

        @Deprecated("Deprecated in Java")
        override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
            return shouldOverrideNavigation(Uri.parse(url))
        }

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url?.toString() ?: return null
            if (url.contains("api.amplitude.com") ||
                url.contains("api.statsig.com") ||
                url.contains("featuregates.org") ||
                url.contains("prod.web-sdk.amplitude.com")
            ) {
                return WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
            }
            return null
        }

        override fun onPageFinished(view: WebView, url: String) {
            currentActivity?.onBrowserPageFinished(view, url)
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (request.isForMainFrame) {
                writeBrowserLog("main frame error: ${error.errorCode} ${error.description}")
                currentActivity?.onBrowserPageError(
                    view,
                    request.url.toString(),
                    error.description.toString(),
                )
            }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            val didCrash = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                detail.didCrash()
            } else {
                false
            }
            writeBrowserLog("WebView renderer gone: didCrash=$didCrash priorityAtExit=${rendererPriority(detail)}")
            destroyWebView(clearPage = false)
            val activity = currentActivity ?: return true
            if (tryBeginRendererRecovery()) {
                writeBrowserLog("renderer auto-recover: attempt=${rendererGoneTimestamps.size}")
                activity.onRendererAutoRecover()
            } else {
                activity.onRendererGoneView(didCrash)
            }
            return true
        }
    }

    private fun shouldOverrideNavigation(uri: Uri): Boolean {
        val activity = currentActivity ?: return false
        return activity.shouldOverrideNavigation(uri)
    }

    private fun tryBeginRendererRecovery(): Boolean {
        val now = SystemClock.elapsedRealtime()
        rendererGoneTimestamps.removeAll { now - it > AUTO_RECOVER_WINDOW_MS }
        if (rendererGoneTimestamps.size >= MAX_AUTO_RECOVERS) return false
        rendererGoneTimestamps.add(now)
        return true
    }

    private fun createWebChromeClient(): WebChromeClient = object : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            currentActivity?.onBrowserProgress(newProgress)
        }

        override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
            val message = consoleMessage.message()
            // 性能瀑布采集回传：识别专用前缀，先于日志级别判断
            if (message.startsWith("NOTION_PERF:")) {
                writeBrowserLog("page perf: ${message.removePrefix("NOTION_PERF:")}")
                return true
            }
            when (consoleMessage.messageLevel()) {
                ConsoleMessage.MessageLevel.ERROR -> writeBrowserLog(
                    "js error: $message " +
                        "(${consoleMessage.sourceId()}:${consoleMessage.lineNumber()})",
                )
                ConsoleMessage.MessageLevel.WARNING -> writeBrowserLog(
                    "js warn: $message",
                )
                else -> Unit
            }
            return true
        }

        override fun onShowFileChooser(
            webView: WebView,
            filePathCallback: ValueCallback<Array<Uri>>,
            fileChooserParams: WebChromeClient.FileChooserParams,
        ): Boolean {
            val activity = currentActivity ?: return false
            return activity.onShowFileChooser(filePathCallback, fileChooserParams)
        }
    }

    private fun destroyWebView(clearPage: Boolean = true) {
        cancelIdleRelease()
        val view = webView ?: return
        webView = null
        try {
            (view.parent as? ViewGroup)?.removeView(view)
            view.stopLoading()
            view.webChromeClient = null
            view.webViewClient = WebViewClient()
            if (clearPage) {
                view.loadUrl("about:blank")
            }
            view.removeAllViews()
            view.destroy()
        } catch (ignored: Exception) {
            // Best-effort cleanup.
        }
    }

    private fun rendererPriority(detail: RenderProcessGoneDetail): Int? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                detail.rendererPriorityAtExit()
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
    }

    private class OutlineBridge {
        @JavascriptInterface
        fun setVisible(visible: Boolean) {
            BrowserWebViewHolder.mainHandler.post {
                BrowserWebViewHolder.currentActivity?.setOutlineVisible(visible)
            }
        }
    }

    private class ElementInspectorBridge {
        @JavascriptInterface
        fun postMessage(payload: String) {
            BrowserWebViewHolder.mainHandler.post {
                BrowserWebViewHolder.currentActivity?.onInspectedElement(payload)
            }
        }
    }

    private class InPageSearchBridge {
        @JavascriptInterface
        fun log(message: String) {
            BrowserWebViewHolder.writeBrowserLog("in-page search: $message")
        }
    }

    internal const val IDLE_RELEASE_DELAY_MS = 5 * 60 * 1000L
    private const val MAX_BROWSER_LOG_BYTES = 256 * 1024
    private const val MAX_AUTO_RECOVERS = 1
    private const val AUTO_RECOVER_WINDOW_MS = 5 * 60 * 1000L
    private const val MOBILE_USER_AGENT = "Mozilla/5.0 (Linux; Android 10; K) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/141.0.0.0 Mobile Safari/537.36"
}
