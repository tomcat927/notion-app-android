package com.notion.app

import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Environment
import android.os.Message
import android.os.SystemClock
import android.provider.MediaStore
import android.util.LruCache
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import com.github.chrisbanes.photoview.PhotoView
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * 笔记页图片查看：注入脚本拦截内容图片的点击，交给原生全屏缩放查看器；
 * 长按图片提供"查看大图 / 保存图片"菜单。
 */
class ImageLightbox(private val activity: Activity) {

    private inner class Bridge {
        @JavascriptInterface
        fun openImage(url: String) {
            activity.runOnUiThread { show(url) }
        }

        @JavascriptInterface
        fun onSmallImage(url: String) {
            activity.runOnUiThread { showSmallImageHint() }
        }
    }

    private fun showSmallImageHint() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastSmallImageHintAt < SMALL_IMAGE_HINT_INTERVAL_MS) return
        lastSmallImageHintAt = now
        Toast.makeText(activity, "图片较小，可长按查看大图或保存", Toast.LENGTH_SHORT).show()
    }

    fun install(webView: WebView) {
        webView.addJavascriptInterface(Bridge(), JS_BRIDGE_NAME)
        webView.setOnLongClickListener { view ->
            handleLongPress(view as WebView)
        }
    }

    fun injectClickScript(webView: WebView) {
        webView.evaluateJavascript(CLICK_INTERCEPT_SCRIPT, null)
    }

    fun show(url: String) {
        val cachedBytes = imageCache.get(url)
        val cookie = if (cachedBytes == null) readCookie(url) else null

        val container = FrameLayout(activity).apply {
            setBackgroundColor(Color.BLACK)
        }
        val photoView = PhotoView(activity)
        container.addView(
            photoView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        val progress = ProgressBar(activity)
        container.addView(
            progress,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )
        val closeButton = TextView(activity).apply {
            text = "✕"
            textSize = 20f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }
        container.addView(
            closeButton,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.END,
            ).apply { topMargin = dp(28) },
        )

        val dialog = Dialog(activity)
        dialog.window?.apply {
            setBackgroundDrawableResource(android.R.color.black)
            setLayout(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            statusBarColor = Color.BLACK
        }
        dialog.setContentView(container)
        var dismissed = false
        dialog.setOnDismissListener { dismissed = true }
        photoView.setOnViewTapListener { _, _, _ ->
            // 放大状态下点按留给手势处理，仅在未放大时点按关闭。
            if (photoView.scale <= 1.05f) dialog.dismiss()
        }
        closeButton.setOnClickListener { dialog.dismiss() }
        dialog.show()

        fetchBitmap(url, cachedBytes, cookie) { bitmap ->
            activity.runOnUiThread {
                if (dismissed) return@runOnUiThread
                progress.visibility = View.GONE
                if (bitmap == null) {
                    Toast.makeText(activity, "图片加载失败", Toast.LENGTH_SHORT).show()
                    dialog.dismiss()
                } else {
                    photoView.setImageBitmap(bitmap)
                }
            }
        }
    }

    fun save(url: String) {
        val cachedBytes = imageCache.get(url)
        val cookie = if (cachedBytes == null) readCookie(url) else null
        ioExecutor.execute {
            val bytes = try {
                cachedBytes ?: fetchBytes(url, cookie).also { imageCache.put(url, it) }
            } catch (ignored: Exception) {
                null
            }
            activity.runOnUiThread {
                if (bytes == null) {
                    Toast.makeText(activity, "图片下载失败", Toast.LENGTH_SHORT).show()
                    return@runOnUiThread
                }
                val saved = try {
                    writeToStorage(bytes)
                } catch (ignored: Exception) {
                    false
                }
                Toast.makeText(
                    activity,
                    if (saved) "图片已保存" else "图片保存失败",
                    Toast.LENGTH_SHORT,
                ).show()
            }
        }
    }

    private fun handleLongPress(webView: WebView): Boolean {
        val hit = webView.hitTestResult
        val url = when (hit.type) {
            WebView.HitTestResult.IMAGE_TYPE -> hit.extra
            WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE -> {
                val message = Message.obtain()
                try {
                    webView.requestFocusNodeHref(message)
                    message.data?.getString("src")
                } finally {
                    message.recycle()
                }
            }
            else -> null
        }
        if (url.isNullOrBlank()) return false
        AlertDialog.Builder(activity)
            .setItems(arrayOf("查看大图", "保存图片")) { _, which ->
                if (which == 0) show(url) else save(url)
            }
            .show()
        return true
    }

    private fun writeToStorage(bytes: ByteArray): Boolean {
        val imageType = detectImageType(bytes)
        val fileName = "notion-" +
            SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) +
            ".${imageType.extension}"
        val resolver = activity.contentResolver
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, imageType.mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return false
            resolver.openOutputStream(uri)?.use { output -> output.write(bytes) }
                ?: return false
            true
        } else {
            val dir = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: return false
            File(dir, fileName).writeBytes(bytes)
            true
        }
    }

    private fun readCookie(url: String): String? {
        return try {
            CookieManager.getInstance().getCookie(url)
        } catch (ignored: Exception) {
            null
        }
    }

    private fun fetchBitmap(
        url: String,
        cachedBytes: ByteArray?,
        cookie: String?,
        callback: (Bitmap?) -> Unit,
    ) {
        ioExecutor.execute {
            val bitmap = try {
                val bytes = cachedBytes
                    ?: fetchBytes(url, cookie).also { imageCache.put(url, it) }
                decodeDownsampled(bytes)
            } catch (ignored: Exception) {
                null
            }
            callback(bitmap)
        }
    }

    private fun fetchBytes(url: String, cookie: String?): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.instanceFollowRedirects = true
            if (!cookie.isNullOrBlank()) {
                connection.setRequestProperty("Cookie", cookie)
            }
            connection.setRequestProperty("User-Agent", DOWNLOAD_USER_AGENT)
            val code = connection.responseCode
            if (code !in 200..299) throw IllegalStateException("HTTP $code")
            return connection.inputStream.use { input ->
                val buffer = ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(chunk)
                    if (read < 0) break
                    total += read
                    if (total > MAX_IMAGE_BYTES) throw IllegalStateException("图片过大")
                    buffer.write(chunk, 0, read)
                }
                buffer.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun decodeDownsampled(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val longSide = maxOf(bounds.outWidth, bounds.outHeight)
        if (longSide <= 0) return null
        var sample = 1
        while (longSide / (sample * 2) >= TARGET_LONG_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    private fun detectImageType(bytes: ByteArray): ImageType {
        val isPng = bytes.size >= 4 &&
            bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte()
        val isGif = bytes.size >= 3 &&
            bytes[0] == 0x47.toByte() && bytes[1] == 0x49.toByte() && bytes[2] == 0x46.toByte()
        val isJpeg = bytes.size >= 3 &&
            bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()
        val isWebp = bytes.size >= 12 &&
            bytes[0] == 0x52.toByte() && bytes[8] == 0x57.toByte()
        return when {
            isPng -> ImageType("image/png", "png")
            isGif -> ImageType("image/gif", "gif")
            isJpeg -> ImageType("image/jpeg", "jpg")
            isWebp -> ImageType("image/webp", "webp")
            else -> ImageType("application/octet-stream", "bin")
        }
    }

    private fun dp(value: Int): Int =
        (value * activity.resources.displayMetrics.density).toInt()

    private class ImageType(val mime: String, val extension: String)

    companion object {
        const val JS_BRIDGE_NAME = "NotionImageLightbox"
        private const val MAX_IMAGE_BYTES = 64L * 1024 * 1024
        private const val TARGET_LONG_SIDE = 2560
        private const val DOWNLOAD_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/141.0.0.0 Mobile Safari/537.36"

        private val ioExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "image-lightbox")
        }

        // 按 URL 缓存原始图片字节：同一进程内重复打开/保存不再重新下载。
        private val imageCache = object : LruCache<String, ByteArray>(cacheMaxBytes()) {
            override fun sizeOf(key: String, value: ByteArray): Int = value.size
        }

        private fun cacheMaxBytes(): Int {
            val heap = Runtime.getRuntime().maxMemory()
            return (heap / 8).toInt().coerceIn(16 * 1024 * 1024, 64 * 1024 * 1024)
        }

        private val CLICK_INTERCEPT_SCRIPT = """
(function() {
  if (window.__notionImageLightboxInstalled) return;
  window.__notionImageLightboxInstalled = true;
  document.addEventListener('click', function(event) {
    var target = event.target;
    if (!target || target.tagName !== 'IMG') return;
    if (target.closest && target.closest('a[href]')) return;
    if (target.closest && target.closest('.notion-emoji, [class*="mention"]')) return;
    var src = target.currentSrc || target.src;
    if (!src || src.indexOf('data:') === 0) return;
    if (target.naturalWidth && target.naturalWidth < 40) {
      if (window.NotionImageLightbox && window.NotionImageLightbox.onSmallImage) {
        window.NotionImageLightbox.onSmallImage(src);
      }
      return;
    }
    if (window.NotionImageLightbox && window.NotionImageLightbox.openImage) {
      event.preventDefault();
      event.stopImmediatePropagation();
      window.NotionImageLightbox.openImage(src);
    }
  }, true);
})();
""".trimIndent()

        private const val SMALL_IMAGE_HINT_INTERVAL_MS = 3_000L
        private var lastSmallImageHintAt = 0L
    }
}
