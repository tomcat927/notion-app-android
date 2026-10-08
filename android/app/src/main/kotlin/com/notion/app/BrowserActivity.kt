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
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import java.util.Locale

class BrowserActivity : Activity() {
    private lateinit var titleView: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var content: LinearLayout
    private lateinit var outlineButton: Button
    private lateinit var browserLoadingOverlay: FrameLayout
    private lateinit var browserLoadingSpinner: ProgressBar
    private lateinit var browserLoadingMessage: TextView
    private lateinit var browserLoadingRetryButton: Button
    private var webView: WebView? = null
    private var loadingPageId: String = ""
    private var isPageLoadPending: Boolean = false
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var openExternalLinksInApp: Boolean = false
    private var showElementInspectorToolbar: Boolean = false
   private var elementInspectorActive: Boolean = false
    private var highlightBlockId: String = ""
    private var highlightSnippet: String = ""

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
        attachWebView()
        loadInitialPage()
    }

    override fun onDestroy() {
        writeBrowserLog("browser destroyed")
        fileChooserCallback?.onReceiveValue(null)
        fileChooserCallback = null
        elementInspectorActive = false
        detachWebView()
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val currentWebView = webView
        if (currentWebView != null && currentWebView.canGoBack()) {
            currentWebView.goBack()
            return
       }
        // 单 task 内嵌浏览器：返回即销毁页面，WebView 由 BrowserWebViewHolder 留用。
        finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        BrowserWebViewHolder.cancelIdleRelease()
        openExternalLinksInApp = intent.getBooleanExtra(EXTRA_OPEN_EXTERNAL_LINKS_IN_APP, false)
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
            showPageLoading(newPageId)
            currentWebView.stopLoading()
            currentWebView.clearHistory()
            currentWebView.loadUrl(url)
        } else {
            writeBrowserLog("webview null, recreating: $newPageId")
            attachWebView()
            loadInitialPage()
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        writeBrowserLog(
            "browser to background, idle release in ${BrowserWebViewHolder.IDLE_RELEASE_DELAY_MS / 1000}s",
        )
        BrowserWebViewHolder.startIdleRelease()
    }

    override fun onResume() {
        super.onResume()
        writeBrowserLog("browser resumed")
        BrowserWebViewHolder.cancelIdleRelease()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        BrowserWebViewHolder.cancelIdleRelease()
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

        browserLoadingSpinner = ProgressBar(this).apply {
            isIndeterminate = true
        }
        browserLoadingMessage = TextView(this).apply {
            text = "正在加载笔记…"
            textSize = 15f
            setTextColor(0xFF4B5563.toInt())
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(12), dp(16), dp(8))
        }
        browserLoadingRetryButton = Button(this).apply {
            text = "重试"
            visibility = View.GONE
            setOnClickListener { retryPendingPage() }
        }
        val loadingContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(
                browserLoadingSpinner,
                LinearLayout.LayoutParams(dp(36), dp(36)),
            )
            addView(
                browserLoadingMessage,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            addView(
                browserLoadingRetryButton,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        browserLoadingOverlay = FrameLayout(this).apply {
            setBackgroundColor(0xFFF7F8FA.toInt())
            isClickable = true
            isFocusable = true
            visibility = View.GONE
            addView(
                loadingContent,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER,
                ),
            )
        }
        browserContainer.addView(
            browserLoadingOverlay,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
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

    private fun attachWebView() {
        val view = BrowserWebViewHolder.obtain(this)
        webView = view
        content.removeAllViews()
        content.addView(
            view,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    private fun detachWebView() {
        BrowserWebViewHolder.detach(this)
        webView = null
    }

    /** WebViewClient 已移至 BrowserWebViewHolder，页面事件经此回调路由到当前 Activity。 */
    internal fun onBrowserPageFinished(view: WebView, url: String) {
        if (view !== webView) return
        if (isPageLoadPending) {
            if (!urlMatchesLoadingPage(url)) {
                writeBrowserLog("ignore stale page finish while loading $loadingPageId: $url")
                return
            }
            isPageLoadPending = false
            browserLoadingOverlay.visibility = View.GONE
            progressBar.visibility = View.GONE
        }

        titleView.text = view.title?.takeIf { it.isNotBlank() } ?: title
        view.evaluateJavascript(HIDE_NOTION_FLOATERS_SCRIPT, null)
        view.evaluateJavascript(INSTALL_OUTLINE_SCRIPT, null)
        view.evaluateJavascript(HIGHLIGHT_STYLE_SCRIPT, null)
        BrowserWebViewHolder.injectImageClickScript(view)
        if (highlightBlockId.isNotEmpty()) {
            view.evaluateJavascript(buildHighlightBlockScript(), null)
        }
        if (elementInspectorActive) {
            installElementInspector()
        }
    }

    internal fun onBrowserPageError(view: WebView, url: String, description: String) {
        if (view !== webView || !isPageLoadPending || !urlMatchesLoadingPage(url)) return
        writeBrowserLog("target page load failed: $loadingPageId url=$url error=$description")
        browserLoadingSpinner.visibility = View.GONE
        browserLoadingMessage.text = "笔记加载失败，请检查网络后重试"
        browserLoadingRetryButton.visibility = View.VISIBLE
        progressBar.visibility = View.GONE
    }

    internal fun onBrowserProgress(newProgress: Int) {
        progressBar.progress = newProgress
        progressBar.visibility = if (newProgress >= 100) {
            View.GONE
        } else {
            View.VISIBLE
        }
    }

    internal fun onRendererAutoRecover() {
        elementInspectorActive = false
        Toast.makeText(this, "页面已自动恢复", Toast.LENGTH_SHORT).show()
        attachWebView()
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

    internal fun setOutlineVisible(visible: Boolean) {
        outlineButton.visibility = if (visible) View.VISIBLE else View.GONE
    }

    internal fun onShowFileChooser(
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
            Toast.makeText(this, "没有可用的文件选择器", Toast.LENGTH_SHORT).show()
            false
        }
    }

    internal fun shouldOverrideNavigation(uri: Uri): Boolean {
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

    internal fun onInspectedElement(payload: String) {
        elementInspectorActive = false
        showInspectedElement(payload)
    }

    private fun showPageLoading(pageId: String) {
        val normalizedPageId = pageId.trim().replace("-", "").lowercase(Locale.US)
        if (normalizedPageId.isEmpty()) return

        loadingPageId = normalizedPageId
        isPageLoadPending = true
        browserLoadingMessage.text = "正在加载笔记…"
        browserLoadingSpinner.visibility = View.VISIBLE
        browserLoadingRetryButton.visibility = View.GONE
        browserLoadingOverlay.visibility = View.VISIBLE
        progressBar.progress = 0
        progressBar.visibility = View.VISIBLE
    }

    private fun urlMatchesLoadingPage(url: String): Boolean {
        if (loadingPageId.isEmpty()) return false
        return try {
            Uri.parse(url).pathSegments.any { segment ->
                segment.replace("-", "").lowercase(Locale.US).contains(loadingPageId)
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun retryPendingPage() {
        val pageId = loadingPageId
        val currentWebView = webView
        if (pageId.isEmpty() || currentWebView == null) return
        showPageLoading(pageId)
        currentWebView.stopLoading()
        currentWebView.loadUrl("https://www.notion.so/$pageId")
    }

    private fun loadInitialPage() {
        val pageId = intent.getStringExtra(EXTRA_PAGE_ID).orEmpty().trim().replace("-", "")
        if (pageId.isEmpty()) {
            showErrorView("缺少页面 ID")
            return
        }
        val url = "https://www.notion.so/$pageId"
        showPageLoading(pageId)
        writeBrowserLog(
            "open page: $pageId url=$url " +
                "openExternalLinksInApp=$openExternalLinksInApp " +
                "title=${intent.getStringExtra(EXTRA_TITLE).orEmpty()}",
        )
        webView?.loadUrl(url)
    }

    internal fun onRendererGoneView(didCrash: Boolean) {
        showErrorView(
            if (didCrash) {
                "Notion WebView 渲染进程已崩溃，已拦截系统杀 App。"
            } else {
                "Notion WebView 渲染进程被系统回收，已拦截系统杀 App。"
            },
        )
    }

    private fun showErrorView(message: String) {
        isPageLoadPending = false
        browserLoadingOverlay.visibility = View.GONE
        progressBar.visibility = View.GONE
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

    private fun writeBrowserLog(message: String) {
        BrowserWebViewHolder.writeBrowserLog(message)
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
