package com.notion.app

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipboardManager
import android.content.ClipData
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class BrowserActivity : Activity() {
    private lateinit var titleView: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var content: LinearLayout
    private var webView: WebView? = null
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var openExternalLinksInApp: Boolean = false
    private var elementInspectorActive: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        openExternalLinksInApp =
            intent.getBooleanExtra(EXTRA_OPEN_EXTERNAL_LINKS_IN_APP, false)
        title = intent.getStringExtra(EXTRA_TITLE).takeUnless { it.isNullOrBlank() } ?: "Notion"
        setContentView(createContentView())
        createWebView()
        loadInitialPage()
    }

    override fun onDestroy() {
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
        super.onBackPressed()
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
            setPadding(dp(8), dp(6), dp(8), dp(6))
            setBackgroundColor(0xFFFFFFFF.toInt())
        }

        toolbar.addView(
            Button(this).apply {
                text = "返回"
                textSize = 13f
                isAllCaps = false
                setOnClickListener { onBackPressed() }
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

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

        titleView = TextView(this).apply {
            text = title
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(0xFF111827.toInt())
            setSingleLine(true)
            setPadding(dp(8), 0, dp(8), 0)
        }
        toolbar.addView(
            titleView,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )

        toolbar.addView(
            Button(this).apply {
                text = "刷新"
                textSize = 13f
                isAllCaps = false
                setOnClickListener { webView?.reload() }
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        root.addView(
            toolbar,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
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

        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(
            content,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        return root
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
            userAgentString = MOBILE_USER_AGENT
        }
        view.addJavascriptInterface(ElementInspectorBridge(), "NotionElementInspector")
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

        override fun onPageFinished(view: WebView, url: String) {
            titleView.text = view.title?.takeIf { it.isNotBlank() } ?: title
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
            showRendererGoneView(didCrash)
            return true
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
        private const val FILE_CHOOSER_REQUEST_CODE = 9031
        private const val MOBILE_USER_AGENT = "Mozilla/5.0 (Linux; Android 10; K) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/141.0.0.0 Mobile Safari/537.36"

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
    }
}
