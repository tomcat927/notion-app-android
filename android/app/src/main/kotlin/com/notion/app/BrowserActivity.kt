package com.notion.app

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipboardManager
import android.content.ClipData
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Typeface
import android.text.TextUtils
import android.net.Uri
import android.os.Build
import android.util.TypedValue
import android.os.Bundle
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.ConsoleMessage
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.io.ByteArrayInputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class BrowserActivity : Activity() {
    private lateinit var titleView: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var content: LinearLayout
    private lateinit var outlineButton: Button
    private var webView: WebView? = null
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var openExternalLinksInApp: Boolean = false
    private var showElementInspectorToolbar: Boolean = false
   private var elementInspectorActive: Boolean = false
    private var highlightBlockId: String = ""
    private var highlightSnippet: String = ""
   private val rendererGoneTimestamps = mutableListOf<Long>()
   private var rendererGoneCount = 0
    private val idleReleaseHandler = Handler(Looper.getMainLooper())
    private val idleReleaseRunnable = Runnable {
        writeBrowserLog("idle release timeout, finishing activity")
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        openExternalLinksInApp =
            intent.getBooleanExtra(EXTRA_OPEN_EXTERNAL_LINKS_IN_APP, false)
       showElementInspectorToolbar =
           intent.getBooleanExtra(EXTRA_SHOW_ELEMENT_INSPECTOR, false)
        highlightBlockId = intent.getStringExtra(EXTRA_BLOCK_ID).orEmpty()
        highlightSnippet = intent.getStringExtra(EXTRA_SNIPPET).orEmpty()
       title = intent.getStringExtra(EXTRA_TITLE).takeUnless { it.isNullOrBlank() } ?: "Notion"
        setContentView(createContentView())
        createWebView()
        loadInitialPage()
    }

    override fun onDestroy() {
        idleReleaseHandler.removeCallbacks(idleReleaseRunnable)
        fileChooserCallback?.onReceiveValue(null)
        fileChooserCallback = null
        elementInspectorActive = false
        destroyWebView()
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val currentWebView = webView
        if (currentWebView != null && currentWebView.canGoBack()) {
            currentWebView.goBack()
            return
       }
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        }
        startActivity(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        idleReleaseHandler.removeCallbacks(idleReleaseRunnable)
        val newPageId = intent.getStringExtra(EXTRA_PAGE_ID)?.orEmpty()?.trim()?.replace("-", "")
        if (newPageId.isNullOrEmpty()) return
        highlightBlockId = intent.getStringExtra(EXTRA_BLOCK_ID).orEmpty()
        highlightSnippet = intent.getStringExtra(EXTRA_SNIPPET).orEmpty()
        val newTitle = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        if (newTitle.isNotBlank()) {
            titleView.text = newTitle
            title = newTitle
        }
        showElementInspectorToolbar = intent.getBooleanExtra(EXTRA_SHOW_ELEMENT_INSPECTOR, false)
        val currentWebView = webView
        if (currentWebView != null) {
            val url = "https://www.notion.so/$newPageId"
            writeBrowserLog("reuse webview: pageId=$newPageId title=$newTitle blockId=$highlightBlockId")
            currentWebView.clearHistory()
            currentWebView.loadUrl(url)
        } else {
            writeBrowserLog("webview null, recreating: $newPageId")
            createWebView()
            loadInitialPage()
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        idleReleaseHandler.removeCallbacks(idleReleaseRunnable)
        idleReleaseHandler.postDelayed(idleReleaseRunnable, IDLE_RELEASE_DELAY_MS)
    }

    override fun onResume() {
        super.onResume()
        idleReleaseHandler.removeCallbacks(idleReleaseRunnable)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == FILE_CHOOSER_REQUEST_CODE) {
            val result = if (resultCode == RESULT_OK) {
                WebChromeClient.FileChooserParams.parseResult(resultCode, data)
            } else {
                null
            }
            fileChooserCallback?.onReceiveValue(result)
            fileChooserCallback = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun createContentView(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFFF7F8FA.toInt())
        }

        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, dp(4), 0)
            setBackgroundColor(0xFFFFFFFF.toInt())
        }

        toolbar.addView(
            createToolbarIconButton(
                R.drawable.ic_toolbar_back,
                "返回",
            ) { onBackPressed() },
            LinearLayout.LayoutParams(dp(48), dp(48)),
        )

        if (showElementInspectorToolbar) {
            toolbar.addView(
                Button(this).apply {
                    text = "控件"
                    textSize = 13f
                    isAllCaps = false
                    setOnClickListener { toggleElementInspector() }
                },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
       }

        titleView = TextView(this).apply {
            text = title
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(0xFF37352F.toInt())
            setSingleLine(true)
            ellipsize = TextUtils.TruncateAt.END
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, dp(4), 0)
        }
        toolbar.addView(
            titleView,
            LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.MATCH_PARENT,
                1f,
            ),
        )

        toolbar.addView(
            createToolbarIconButton(
                R.drawable.ic_toolbar_search,
                "搜索",
            ) { showInPageSearch() },
            LinearLayout.LayoutParams(dp(48), dp(48)),
        )

        toolbar.addView(
            createToolbarIconButton(
                R.drawable.ic_toolbar_refresh,
                "刷新",
            ) { webView?.reload() },
            LinearLayout.LayoutParams(dp(48), dp(48)),
        )

        root.addView(
            toolbar,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(48),
            ),
        )

        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progress = 0
        }
        root.addView(
            progressBar,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(2)),
        )

        val browserContainer = FrameLayout(this)
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        browserContainer.addView(
            content,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        outlineButton = Button(this).apply {
            text = "大纲"
            textSize = 13f
            isAllCaps = false
            visibility = View.GONE
            setOnClickListener { showOutline() }
        }
        browserContainer.addView(
            outlineButton,
            FrameLayout.LayoutParams(dp(72), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.END or Gravity.BOTTOM
                setMargins(dp(12), dp(12), dp(16), dp(20))
            },
        )
        root.addView(
            browserContainer,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        return root
    }

    private fun createToolbarIconButton(
        drawableRes: Int,
        description: String,
        onClick: () -> Unit,
    ): ImageButton {
        return ImageButton(this).apply {
            contentDescription = description
            setImageResource(drawableRes)
            scaleType = ImageView.ScaleType.FIT_CENTER
            setPadding(dp(12), dp(12), dp(12), dp(12))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val backgroundValue = TypedValue()
                theme.resolveAttribute(
                    android.R.attr.selectableItemBackgroundBorderless,
                    backgroundValue,
                    true,
                )
                if (backgroundValue.resourceId != 0) {
                    setBackgroundResource(backgroundValue.resourceId)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setTooltipText(description)
            }
            setOnClickListener { onClick() }
        }
    }

    private fun createWebView() {
        val view = WebView(this)
        webView = view
        content.removeAllViews()
        content.addView(
            view,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

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
       CookieManager.getInstance().setAcceptCookie(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        }
        view.webViewClient = createWebViewClient()
        view.webChromeClient = createWebChromeClient()
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
           titleView.text = view.title?.takeIf { it.isNotBlank() } ?: title
           view.evaluateJavascript(HIDE_NOTION_FLOATERS_SCRIPT, null)
           view.evaluateJavascript(INSTALL_OUTLINE_SCRIPT, null)
            view.evaluateJavascript(HIGHLIGHT_STYLE_SCRIPT, null)
            if (highlightBlockId.isNotEmpty()) {
                view.evaluateJavascript(buildHighlightBlockScript(), null)
            }
           if (elementInspectorActive) {
                installElementInspector()
            }
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (request.isForMainFrame) {
                writeBrowserLog("main frame error: ${error.errorCode} ${error.description}")
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
            if (canAutoRecoverRenderer()) {
                writeBrowserLog("renderer auto-recover: attempt=$rendererGoneCount")
                recreateWebView()
                Toast.makeText(this@BrowserActivity, "页面已自动恢复", Toast.LENGTH_SHORT).show()
            } else {
                showRendererGoneView(didCrash)
            }
            return true
        }
    }

    private fun canAutoRecoverRenderer(): Boolean {
        val now = SystemClock.elapsedRealtime()
        rendererGoneTimestamps.removeAll { now - it > AUTO_RECOVER_WINDOW_MS }
        rendererGoneCount = rendererGoneTimestamps.size
        return rendererGoneCount < MAX_AUTO_RECOVERS
    }

    private fun recreateWebView() {
        elementInspectorActive = false
        rendererGoneTimestamps.add(SystemClock.elapsedRealtime())
        rendererGoneCount = rendererGoneTimestamps.size
        createWebView()
        loadInitialPage()
    }

   private fun showOutline() {
       webView?.evaluateJavascript("window.__notionShowOutline && window.__notionShowOutline();", null)
   }

    private fun showInPageSearch() {
        webView?.evaluateJavascript(INSTALL_IN_PAGE_SEARCH_SCRIPT, null)
    }

    private fun buildHighlightBlockScript(): String {
        val blockId = highlightBlockId.replace("\\", "\\\\").replace("\"", "\\\"")
        val snippet = highlightSnippet.replace("\\", "\\\\").replace("\"", "\\\"")
        return """
(function() {
  var blockId = "$blockId";
  var snippet = "$snippet";

  function highlightElement(el) {
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    el.classList.add('notion-search-highlight-pulse');
    setTimeout(function() {
      el.classList.remove('notion-search-highlight-pulse');
    }, 3000);
  }

  function expandToggles(block) {
    var toggle = block.closest('.notion-toggle-block');
    if (!toggle) return;
    var btn = toggle.querySelector('.notion-toggle');
    if (btn) {
      var children = toggle.querySelector('.notion-toggle-block__children');
      if (children && children.offsetParent === null) {
        btn.click();
      }
    }
  }

  var attempts = 0;
  function tryHighlight() {
    attempts++;
    if (blockId) {
      var block = document.querySelector('[data-block-id="' + blockId + '"]');
      if (block) {
        expandToggles(block);
        setTimeout(function() { highlightElement(block); }, 150);
        return;
      }
    }
    if (snippet && snippet.length > 2) {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode: function(node) {
          var parent = node.parentElement;
          if (!parent) return NodeFilter.FILTER_REJECT;
          var tag = parent.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
          if (node.textContent.indexOf(snippet) < 0) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      while (walker.nextNode()) {
        highlightElement(walker.currentNode.parentElement);
        return;
      }
    }
    if (attempts < 12) {
      setTimeout(tryHighlight, 500);
    }
  }
  tryHighlight();
})();
        """.trimIndent()
    }

    private inner class OutlineBridge {
        @JavascriptInterface
        fun setVisible(visible: Boolean) {
            runOnUiThread { outlineButton.visibility = if (visible) View.VISIBLE else View.GONE }
        }
    }

    private inner class InPageSearchBridge {
        @JavascriptInterface
        fun log(message: String) {
            writeBrowserLog("in-page search: $message")
        }
    }

    private fun createWebChromeClient(): WebChromeClient = object : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            progressBar.progress = newProgress
            progressBar.visibility = if (newProgress >= 100) {
                android.view.View.GONE
            } else {
                android.view.View.VISIBLE
            }
        }

        override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
            when (consoleMessage.messageLevel()) {
                ConsoleMessage.MessageLevel.ERROR -> writeBrowserLog(
                    "js error: ${consoleMessage.message()} " +
                        "(${consoleMessage.sourceId()}:${consoleMessage.lineNumber()})",
                )
                ConsoleMessage.MessageLevel.WARNING -> writeBrowserLog(
                    "js warn: ${consoleMessage.message()}",
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
            fileChooserCallback?.onReceiveValue(null)
            fileChooserCallback = filePathCallback
            return try {
                startActivityForResult(fileChooserParams.createIntent(), FILE_CHOOSER_REQUEST_CODE)
                true
            } catch (_: ActivityNotFoundException) {
                fileChooserCallback = null
                Toast.makeText(this@BrowserActivity, "没有可用的文件选择器", Toast.LENGTH_SHORT).show()
                false
            }
        }
    }

    private fun shouldOverrideNavigation(uri: Uri): Boolean {
        if (isNotionUri(uri)) return false
        if (openExternalLinksInApp && isWebUri(uri)) {
            writeBrowserLog("open external web link in app: $uri")
            return false
        }
        if (!isExternalUri(uri)) return true
        writeBrowserLog("open external link: $uri")
        openExternally(uri)
        return true
    }

    private fun isNotionUri(uri: Uri): Boolean {
        val host = uri.host?.lowercase(Locale.US) ?: return false
        return matchesDomain(host, "notion.so") ||
            matchesDomain(host, "notion.com") ||
            matchesDomain(host, "notion.co") ||
            matchesDomain(host, "notion.site") ||
            matchesDomain(host, "notionusercontent.com")
    }

    private fun matchesDomain(host: String, domain: String): Boolean {
        return host == domain || host.endsWith(".$domain")
    }

    private fun isExternalUri(uri: Uri): Boolean {
        val scheme = uri.scheme?.lowercase(Locale.US) ?: return false
        return isWebUri(uri) ||
            scheme == "mailto" ||
            scheme == "tel" ||
            scheme == "sms"
    }

    private fun isWebUri(uri: Uri): Boolean {
        val scheme = uri.scheme?.lowercase(Locale.US) ?: return false
        return scheme == "http" || scheme == "https"
    }

    private fun openExternally(uri: Uri): Boolean {
        return try {
            startActivity(
                Intent(Intent.ACTION_VIEW, uri).apply {
                    addCategory(Intent.CATEGORY_BROWSABLE)
                },
            )
            true
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, "无法打开链接：$uri", Toast.LENGTH_SHORT).show()
            false
        }
    }

    private fun toggleElementInspector() {
        if (webView == null) return
        if (elementInspectorActive) {
            stopElementInspector()
            Toast.makeText(this, "已关闭控件诊断", Toast.LENGTH_SHORT).show()
            return
        }

        elementInspectorActive = true
        installElementInspector()
        Toast.makeText(this, "请点击要查看的网页控件", Toast.LENGTH_LONG).show()
    }

    private fun stopElementInspector() {
        elementInspectorActive = false
        webView?.evaluateJavascript(
            "window.__notionElementInspectorCleanup && " +
                "window.__notionElementInspectorCleanup();",
            null,
        )
    }

    private fun installElementInspector() {
        webView?.evaluateJavascript(
            ELEMENT_INSPECTOR_SCRIPT,
            null,
        )
    }

    private fun showInspectedElement(payload: String) {
        elementInspectorActive = false
        val textView = TextView(this).apply {
            text = payload
            textSize = 11f
            setPadding(dp(16), dp(8), dp(16), dp(8))
            setTextIsSelectable(true)
        }
        val scrollView = android.widget.ScrollView(this).apply {
            addView(textView)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("网页控件信息")
            .setView(scrollView)
            .setNegativeButton("关闭", null)
            .setNeutralButton("复制全部") { _, _ ->
                val clipboard = getSystemService(ClipboardManager::class.java)
                clipboard?.setPrimaryClip(ClipData.newPlainText("网页控件信息", payload))
                Toast.makeText(this, "控件信息已复制", Toast.LENGTH_SHORT).show()
            }
            .create()
        dialog.show()
    }

    private inner class ElementInspectorBridge {
        @JavascriptInterface
        fun postMessage(payload: String) {
            runOnUiThread {
                stopElementInspector()
                showInspectedElement(payload)
            }
        }
    }

    private fun loadInitialPage() {
        val pageId = intent.getStringExtra(EXTRA_PAGE_ID).orEmpty().trim().replace("-", "")
        if (pageId.isEmpty()) {
            showErrorView("缺少页面 ID")
            return
        }
        val url = "https://www.notion.so/$pageId"
        writeBrowserLog(
            "open page: $pageId url=$url " +
                "openExternalLinksInApp=$openExternalLinksInApp " +
                "title=${intent.getStringExtra(EXTRA_TITLE).orEmpty()}",
        )
        webView?.loadUrl(url)
    }

    private fun showRendererGoneView(didCrash: Boolean) {
        showErrorView(
            if (didCrash) {
                "Notion WebView 渲染进程已崩溃，已拦截系统杀 App。"
            } else {
                "Notion WebView 渲染进程被系统回收，已拦截系统杀 App。"
            },
        )
    }

    private fun showErrorView(message: String) {
        content.removeAllViews()
        content.addView(
            TextView(this).apply {
                text = "$message\n\n可以点返回回到主 App，再重新打开页面。"
                textSize = 15f
                setTextColor(0xFF4B5563.toInt())
                gravity = Gravity.CENTER
                setPadding(dp(24), dp(24), dp(24), dp(24))
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    private fun destroyWebView(clearPage: Boolean = true) {
        val view = webView ?: return
        webView = null
        try {
            content.removeView(view)
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

    private fun writeBrowserLog(message: String) {
        try {
            val file = File(filesDir, "notion_app_native_crash.log")
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

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_PAGE_ID = "pageId"
        const val EXTRA_TITLE = "title"
        const val EXTRA_OPEN_EXTERNAL_LINKS_IN_APP = "openExternalLinksInApp"
       const val EXTRA_SHOW_ELEMENT_INSPECTOR = "showElementInspector"
        const val EXTRA_BLOCK_ID = "blockId"
        const val EXTRA_SNIPPET = "snippet"
        private const val FILE_CHOOSER_REQUEST_CODE = 9031
        private const val MAX_BROWSER_LOG_BYTES = 256 * 1024
        private const val MAX_AUTO_RECOVERS = 1
       private const val AUTO_RECOVER_WINDOW_MS = 5 * 60 * 1000L
        private const val IDLE_RELEASE_DELAY_MS = 5 * 60 * 1000L
        private const val MOBILE_USER_AGENT = "Mozilla/5.0 (Linux; Android 10; K) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/141.0.0.0 Mobile Safari/537.36"

        private const val HIDE_NOTION_FLOATERS_SCRIPT = """
(() => {
  const styleId = 'notion-floaters-hide-style';
  let style = document.getElementById(styleId);
  if (!style) {
    style = document.createElement('style');
    style.id = styleId;
    document.head.appendChild(style);
  }
  style.textContent = [
    '.notion-assistant-corner-origin-container,',
    '.notion-ai-button,',
    'img[alt="Notion AI face"],',
    '.notion-help-button,',
    '.notion-upgrade-button,',
    '.notion-default-ai-container,',
    '.notion-template-button,',
    '.notion-ai-card,',
    '.notion-ai-banner {',
    '  display: none !important;',
    '  visibility: hidden !important;',
    '}',
    '.notion-topbar {',
    '  padding: 0 4px !important;',
    '  min-height: 36px !important;',
    '}',
    '.notion-page-content {',
    '  max-width: 100% !important;',
    '  padding-left: 8px !important;',
    '  padding-right: 8px !important;',
    '}',
    '.notion-page-view-title-row {',
    '  padding-left: 8px !important;',
    '  padding-right: 8px !important;',
    '}'
  ].join('\n');
})();
"""

        private const val INSTALL_OUTLINE_SCRIPT = """
(() => {
  const collect = () => Array.from(document.querySelectorAll('h1, h2, h3'))
  const collect = () => {
    if (!document.querySelector('.notion-page-content')) return [];
    return Array.from(document.querySelectorAll('h1, h2, h3'))
    .filter(node => (node.innerText || node.textContent || '').trim())
    .map((node, index) => {
      if (!node.dataset.notionOutlineId) {
        node.dataset.notionOutlineId = 'notion-outline-' + index;
      }
      return {
        id: node.dataset.notionOutlineId,
        level: Number(node.tagName.substring(1)),
        text: (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim()
      };
    });
  };

  let lastCount = -1;
  let scheduled = false;
  const updateVisibility = () => {
    scheduled = false;
    if (!document.body || !document.querySelector('.notion-page-content')) return;
    const count = document.querySelectorAll('h1, h2, h3').length;
    if (count === lastCount) return;
    lastCount = count;
    collect();
    if (window.NotionOutline) {
      window.NotionOutline.setVisible(count > 0);
    }
  };
  const scheduleUpdate = () => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(updateVisibility, 300);
  };

  window.__notionShowOutline = () => {
    const headings = collect();
    if (!headings.length) return;
    let panel = document.getElementById('notion-native-outline');
    if (panel) panel.remove();
    panel = document.createElement('div');
    panel.id = 'notion-native-outline';
    panel.style.cssText = 'position:fixed;left:12px;right:12px;bottom:12px;max-height:65vh;overflow:auto;z-index:2147483647;background:#fff;color:#111827;border-radius:16px;box-shadow:0 8px 32px rgba(0,0,0,.28);padding:12px;font-family:sans-serif';

    const title = document.createElement('div');
    title.textContent = '页面大纲';
    title.style.cssText = 'font-size:18px;font-weight:700;padding:8px 10px 12px';
    panel.appendChild(title);

    headings.forEach(heading => {
      const item = document.createElement('button');
      item.type = 'button';
      item.textContent = heading.text;
      item.style.cssText = 'display:block;width:100%;border:0;background:transparent;text-align:left;padding:10px 10px 10px ' + (10 + (heading.level - 1) * 20) + 'px;font-size:15px;color:#111827';
     item.addEventListener('click', () => {
       const target = document.querySelector('[data-notion-outline-id="' + heading.id + '"]');
       panel.remove();
       if (!target) return;
       target.scrollIntoView({behavior:'smooth', block:'start'});
       setTimeout(function() { target.scrollIntoView({behavior:'smooth', block:'start'}); }, 500);
       setTimeout(function() { target.scrollIntoView({behavior:'smooth', block:'start'}); }, 1500);
     });
      panel.appendChild(item);
    });

    const close = document.createElement('button');
    close.type = 'button';
    close.textContent = '关闭';
    close.style.cssText = 'display:block;width:100%;border:0;border-top:1px solid #e5e7eb;background:transparent;padding:12px;font-size:15px;color:#2563eb';
    close.addEventListener('click', () => panel.remove());
    panel.appendChild(close);
   if (!document.body) return;
   document.body.appendChild(panel);
  };

  updateVisibility();
  if (window.__notionOutlineObserver) window.__notionOutlineObserver.disconnect();
  window.__notionOutlineObserver = new MutationObserver(scheduleUpdate);
  if (document.body) {
    window.__notionOutlineObserver.observe(document.body, {childList:true, subtree:true});
  }
})();
"""

        private const val ELEMENT_INSPECTOR_SCRIPT = """
(() => {
  if (window.__notionElementInspectorCleanup) {
    window.__notionElementInspectorCleanup();
  }

  const isElement = value => value && value.nodeType === 1;
  const describe = (element, includeHtml = true) => {
    if (!isElement(element)) return null;
    const attributes = {};
    for (const attribute of Array.from(element.attributes || [])) {
      attributes[attribute.name] = attribute.value;
    }
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    return {
      tag: element.tagName.toLowerCase(),
      id: element.id || '',
      className: typeof element.className === 'string'
        ? element.className
        : String(element.className || ''),
      role: element.getAttribute('role') || '',
      ariaLabel: element.getAttribute('aria-label') || '',
      title: element.getAttribute('title') || '',
      text: (element.innerText || element.textContent || '')
        .replace(/\s+/g, ' ')
        .trim()
        .substring(0, 1000),
      attributes,
      position: style.position,
      display: style.display,
      rect: {
        left: Math.round(rect.left),
        top: Math.round(rect.top),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      },
      outerHTML: includeHtml
        ? (element.outerHTML || '').substring(0, 12000)
        : ''
    };
  };
  const findInteractive = element => {
    let current = isElement(element) ? element : null;
    for (let depth = 0; current && depth < 10; depth++) {
      if (current.matches(
        'button, a, [role="button"], [aria-label], [data-testid], [title]'
      )) {
        return current;
      }
      current = current.parentElement;
    }
    return isElement(element) ? element : document.body;
  };
  const ancestorDescriptions = element => {
    const result = [];
    let current = element;
    for (let depth = 0; current && depth < 8; depth++) {
      result.push(describe(current, false));
      current = current.parentElement;
    }
    return result;
  };
  const handler = event => {
    const eventTarget = isElement(event.target)
      ? event.target
      : event.target?.parentElement;
    const interactiveTarget = findInteractive(eventTarget);
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    const payload = {
      eventTarget: describe(eventTarget),
      interactiveTarget: describe(interactiveTarget),
      ancestors: ancestorDescriptions(interactiveTarget),
      url: window.location.href
    };
    if (window.NotionElementInspector) {
      window.NotionElementInspector.postMessage(JSON.stringify(payload, null, 2));
    }
    window.__notionElementInspectorCleanup();
  };
  window.__notionElementInspectorCleanup = () => {
    document.removeEventListener('click', handler, true);
    window.__notionElementInspectorCleanup = null;
  };
 document.addEventListener('click', handler, true);
})();
"""
        private const val HIGHLIGHT_STYLE_SCRIPT = """
(function() {
  if (document.getElementById('notion-search-highlight-style')) return;
  var style = document.createElement('style');
  style.id = 'notion-search-highlight-style';
  style.textContent = [
    '@keyframes notion-highlight-pulse {',
    '  0% { background-color: rgba(255, 213, 79, 0.8); }',
    '  30% { background-color: rgba(255, 213, 79, 0.45); }',
    '  100% { background-color: transparent; }',
    '}',
    '.notion-search-highlight-pulse {',
    '  animation: notion-highlight-pulse 3s ease-out forwards;',
    '  border-radius: 4px;',
    '}',
    '.notion-search-overlay {',
    '  position: fixed;',
    '  background: rgba(255, 213, 79, 0.5);',
    '  border: 2px solid rgba(255, 193, 7, 0.8);',
    '  border-radius: 3px;',
    '  pointer-events: none;',
    '  z-index: 99999;',
    '  transition: opacity 0.4s ease-out;',
    '}'
  ].join('\n');
  document.head.appendChild(style);
})();
"""

        private const val INSTALL_IN_PAGE_SEARCH_SCRIPT = """
(function() {
  var existing = document.getElementById('notion-in-page-search-panel');
  if (existing) { existing.remove(); return; }

  var panel = document.createElement('div');
  panel.id = 'notion-in-page-search-panel';
  panel.style.cssText = 'position:fixed;left:0;right:0;bottom:0;max-height:60vh;z-index:2147483647;background:#fff;color:#111827;border-radius:16px 16px 0 0;box-shadow:0 -4px 24px rgba(0,0,0,.18);display:flex;flex-direction:column;font-family:sans-serif;';

  var header = document.createElement('div');
  header.style.cssText = 'padding:12px 16px;border-bottom:1px solid #e5e7eb;display:flex;align-items:center;gap:8px;';

  var input = document.createElement('input');
  input.type = 'text';
  input.placeholder = '在当前页面搜索';
  input.style.cssText = 'flex:1;border:1px solid #d1d5db;border-radius:8px;padding:8px 12px;font-size:15px;outline:none;';

  var closeBtn = document.createElement('button');
  closeBtn.textContent = 'X';
  closeBtn.style.cssText = 'border:0;background:transparent;font-size:18px;color:#6b7280;padding:4px 8px;cursor:pointer;';
  closeBtn.onclick = function() { panel.remove(); };

  header.appendChild(input);
  header.appendChild(closeBtn);
  panel.appendChild(header);

  var resultsList = document.createElement('div');
  resultsList.style.cssText = 'flex:1;overflow:auto;padding:4px 0;max-height:40vh;';
  panel.appendChild(resultsList);

  var countLabel = document.createElement('div');
  countLabel.style.cssText = 'padding:8px 16px;border-top:1px solid #e5e7eb;font-size:13px;color:#6b7280;';
  panel.appendChild(countLabel);

  document.body.appendChild(panel);
  input.focus();

  var ranges = [];

  function clearResults() {
    ranges = [];
    resultsList.innerHTML = '';
    countLabel.textContent = '';
  }

  function performSearch(query) {
    clearResults();
    if (!query || query.length < 1) return;
    var lowerQuery = query.toLowerCase();
    var maxResults = 100;

    var searchRoot = document.querySelector('.notion-page-content') || document.body;
    var walker = document.createTreeWalker(searchRoot, NodeFilter.SHOW_TEXT, {
      acceptNode: function(node) {
        var parent = node.parentElement;
        if (!parent) return NodeFilter.FILTER_REJECT;
        var tag = parent.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
        var text = node.textContent;
        if (!text || text.trim().length < 1) return NodeFilter.FILTER_REJECT;
        if (text.toLowerCase().indexOf(lowerQuery) < 0) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    var lastContext = '';
    while (walker.nextNode() && ranges.length < maxResults) {
      var text = walker.currentNode.textContent;
      var lowerText = text.toLowerCase();
      var pos = 0;
      while ((pos = lowerText.indexOf(lowerQuery, pos)) >= 0) {
        if (ranges.length >= maxResults) break;
        var contextStart = Math.max(0, pos - 40);
        var contextEnd = Math.min(text.length, pos + query.length + 40);
        var prefix = contextStart > 0 ? '\u2026' : '';
        var suffix = contextEnd < text.length ? '\u2026' : '';
        var context = prefix + text.substring(contextStart, contextEnd) + suffix;

        if (context === lastContext) { pos += query.length; continue; }
        lastContext = context;

        var range = document.createRange();
        range.setStart(walker.currentNode, pos);
        range.setEnd(walker.currentNode, pos + query.length);
        ranges.push(range);

        var item = document.createElement('div');
        item.style.cssText = 'padding:10px 16px;cursor:pointer;border-bottom:1px solid #f3f4f6;font-size:14px;line-height:1.4;word-break:break-all;';
        item.textContent = context;
        item.onmouseover = function() { this.style.backgroundColor = '#f9fafb'; };
        item.onmouseout = function() { this.style.backgroundColor = ''; };

    let rangeIndex = ranges.length - 1;
    item.onclick = function() { scrollToMatch(rangeIndex); };

        resultsList.appendChild(item);
        pos += query.length;
      }
    }
    countLabel.textContent = ranges.length + ' 个结果';
  }

  function scrollToMatch(index) {
    var range = ranges[index];
    if (!range) return;
    var el = range.startContainer;
    if (el.nodeType === Node.TEXT_NODE) {
      el = el.parentElement;
    }
    if (el) {
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }

    var overlays = document.querySelectorAll('.notion-search-overlay');
    for (var i = 0; i < overlays.length; i++) { overlays[i].remove(); }

    setTimeout(function() {
      var newRect = range.getBoundingClientRect();
      var overlay = document.createElement('div');
      overlay.className = 'notion-search-overlay';
      overlay.style.cssText =
        'position:fixed;' +
        'left:' + newRect.left + 'px;' +
        'top:' + newRect.top + 'px;' +
        'width:' + newRect.width + 'px;' +
        'height:' + Math.max(newRect.height, 4) + 'px;' +
        'background:rgba(255,213,79,0.5);' +
        'border:2px solid rgba(255,193,7,0.8);' +
        'border-radius:3px;' +
        'pointer-events:none;' +
        'z-index:99999;' +
        'transition:opacity 0.4s ease-out;';
      document.body.appendChild(overlay);
      setTimeout(function() {
        overlay.style.opacity = '0';
        setTimeout(function() { overlay.remove(); }, 500);
      }, 2000);
    }, 400);
  }

  var debounceTimer;
  input.oninput = function() {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(function() {
      performSearch(input.value);
    }, 400);
  };

  input.onkeydown = function(e) {
    if (e.key === 'Enter') {
      clearTimeout(debounceTimer);
      performSearch(input.value);
    }
    if (e.key === 'Escape') {
      panel.remove();
    }
  };
})();
"""
    }
}
