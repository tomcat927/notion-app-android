package com.notion.app

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlin.concurrent.thread

/**
 * 系统下载完成广播（包定向，可唤醒被冻结的进程）：
 * App 在后台/被杀期间下载完成时，负责校验落盘并发安装通知。
 * downloadId 与自排队记录比对，伪造广播直接忽略。
 */
class UpdateDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val downloadId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
        val appContext = context.applicationContext
        if (!UpdateDownloadManager.isTrackedDownload(appContext, downloadId)) return
        val pendingResult = goAsync()
        thread(name = "update-download-complete") {
            try {
                UpdateDownloadManager.processCompleted(appContext, downloadId)
            } catch (_: Exception) {
            } finally {
                pendingResult.finish()
            }
        }
    }
}
