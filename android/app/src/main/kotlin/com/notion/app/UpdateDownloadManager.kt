package com.notion.app

import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.io.File
import java.security.MessageDigest

/**
 * 更新包系统下载：交给 DownloadManager 后台下载，App 进程冻结/被杀都不中断。
 *
 * 流程：Dart 侧 enqueue（附带期望 SHA-256）→ 系统后台下载 → 完成后由
 * [UpdateDownloadReceiver]（或前台轮询兜底）触发 [processCompleted]：
 * 流式计算 SHA-256，校验通过才落盘到内部 cacheDir/apk_updates/notion-app-update.apk
 * （外部文件仅作下载中转，校验后即清理），并发"更新就绪"通知。
 */
internal object UpdateDownloadManager {
    private const val PREFS = "update_download_state"
    private const val KEY_DOWNLOAD_ID = "download_id"
    private const val KEY_DOWNLOAD_URL = "download_url"
    private const val KEY_EXPECTED_SHA256 = "expected_sha256"
    private const val KEY_VERIFIED_SHA256 = "verified_sha256"
    private const val KEY_LAST_ERROR = "last_error"
    private const val EXTERNAL_SUB_PATH = "apk_updates/notion-app-update.apk"
    private const val INTERNAL_PART_NAME = "notion-app-update.apk.part"
    // Flutter 侧"下载完成通知"开关存放在 FlutterSharedPreferences（flutter. 前缀）。
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val FLUTTER_KEY_NOTIFICATION = "flutter.update_notification"

    internal fun canonicalApk(context: Context): File =
        File(File(context.cacheDir, "apk_updates"), "notion-app-update.apk")

    internal fun isTrackedDownload(context: Context, downloadId: Long): Boolean {
        if (downloadId <= 0) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getLong(KEY_DOWNLOAD_ID, -1) == downloadId
    }

    /**
     * 交给系统下载器。同一链接的已有任务直接复用（运行中/暂停/已完成待校验
     * 都交给轮询和 processCompleted 收尾），换链接才清掉旧任务重新排队。
     */
    internal fun enqueue(
        context: Context,
        url: String,
        expectedSha256: String,
        displayName: String,
    ): Long {
        val dm = context.getSystemService(Context.DOWNLOAD_SERVICE) as? DownloadManager
            ?: throw IllegalStateException("DownloadManager 不可用")
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existingId = prefs.getLong(KEY_DOWNLOAD_ID, -1)
        if (existingId > 0 && prefs.getString(KEY_DOWNLOAD_URL, null) == url) {
            prefs.edit().putString(KEY_EXPECTED_SHA256, expectedSha256).apply()
            return existingId
        }
        if (existingId > 0) {
            try {
                dm.remove(existingId)
            } catch (_: Exception) {
            }
        }
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(displayName)
            .setDescription("Notion Lite 更新包")
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setDestinationInExternalFilesDir(context, null, EXTERNAL_SUB_PATH)
        val id = dm.enqueue(request)
        prefs.edit()
            .putLong(KEY_DOWNLOAD_ID, id)
            .putString(KEY_DOWNLOAD_URL, url)
            .putString(KEY_EXPECTED_SHA256, expectedSha256)
            .remove(KEY_VERIFIED_SHA256)
            .remove(KEY_LAST_ERROR)
            .apply()
        return id
    }

    internal fun query(context: Context, downloadId: Long): Map<String, Any> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        var status = DownloadManager.STATUS_FAILED
        var bytes = 0L
        var total = 0L
        val dm = context.getSystemService(Context.DOWNLOAD_SERVICE) as? DownloadManager
        if (dm != null && downloadId > 0) {
            try {
                dm.query(DownloadManager.Query().setFilterById(downloadId)).use { cursor ->
                    if (cursor.moveToFirst()) {
                        status = cursor.getInt(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                        )
                        bytes = cursor.getLong(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                        )
                        total = cursor.getLong(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                        )
                    }
                }
            } catch (_: Exception) {
                status = DownloadManager.STATUS_FAILED
            }
        }
        val expected = prefs.getString(KEY_EXPECTED_SHA256, null)
        val verified = prefs.getString(KEY_VERIFIED_SHA256, null)
        val ready = expected != null &&
            verified?.equals(expected, ignoreCase = true) == true &&
            canonicalApk(context).exists()
        return mapOf(
            "status" to status,
            "bytes" to bytes,
            "total" to total,
            "ready" to ready,
        )
    }

    /** 校验系统下载的更新包并落盘；接收器与前台轮询共用，幂等可重复调用。 */
    internal fun processCompleted(context: Context, downloadId: Long) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val expected = prefs.getString(KEY_EXPECTED_SHA256, null) ?: return
        if (prefs.getString(KEY_VERIFIED_SHA256, null)?.equals(expected, ignoreCase = true) == true &&
            canonicalApk(context).exists()
        ) {
            return // 已处理过（重复广播）
        }
        val dm = context.getSystemService(Context.DOWNLOAD_SERVICE) as? DownloadManager ?: return
        val sourceUri = try {
            dm.getUriForDownloadedFile(downloadId)
        } catch (_: Exception) {
            null
        }
        if (sourceUri == null) {
            prefs.edit().putString(KEY_LAST_ERROR, "download missing").apply()
            return
        }

        val target = canonicalApk(context)
        val partFile = File(target.parentFile, INTERNAL_PART_NAME)
        try {
            target.parentFile?.mkdirs()
            val digest = MessageDigest.getInstance("SHA-256")
            context.contentResolver.openInputStream(sourceUri)?.use { input ->
                partFile.outputStream().use { output ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                }
            } ?: throw IllegalStateException("无法读取下载内容")

            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (!actual.equals(expected, ignoreCase = true)) {
                partFile.delete()
                prefs.edit().putString(KEY_LAST_ERROR, "sha256 mismatch").apply()
                try {
                    dm.remove(downloadId)
                } catch (_: Exception) {
                }
                return
            }

            if (target.exists()) target.delete()
            if (!partFile.renameTo(target)) {
                partFile.copyTo(target, overwrite = true)
                partFile.delete()
            }
            prefs.edit().putString(KEY_VERIFIED_SHA256, actual).apply()
            try {
                dm.remove(downloadId)
            } catch (_: Exception) {
            }
            if (isNotificationEnabled(context)) {
                showUpdateReadyNotification(context)
            }
        } catch (error: Exception) {
            partFile.delete()
            prefs.edit().putString(KEY_LAST_ERROR, error.message ?: "copy failed").apply()
        }
    }

    private fun isNotificationEnabled(context: Context): Boolean {
        return try {
            context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
                .getBoolean(FLUTTER_KEY_NOTIFICATION, true)
        } catch (_: Exception) {
            true
        }
    }

    internal fun showUpdateReadyNotification(context: Context) {
        val appContext = context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "update_notification",
                "更新通知",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
            appContext.getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
        val installIntent = Intent(appContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("install_update", true)
        }
        val pendingIntent = PendingIntent.getActivity(
            appContext, 0, installIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(appContext, "update_notification")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Notion Lite 更新就绪")
            .setContentText("点击安装新版本")
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        try {
            NotificationManagerCompat.from(appContext).notify(1001, notification)
        } catch (_: SecurityException) {
        }
    }
}
