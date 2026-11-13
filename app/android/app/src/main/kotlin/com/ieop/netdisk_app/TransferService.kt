package com.ieop.netdisk_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * 传输期间保持进程存活。
 *
 * 为什么必须有它：Android 会在应用退到后台几分钟后回收进程，锁屏时更激进。
 * QUIC 传输一旦被系统掐断，之前断点续传攒下的进度虽然还在，但任务本身已经死了，
 * 用户回到前台只会看到「失败」。
 *
 * 绑定一条前台通知是使用前台服务的必要条件（Android 的硬性规则），
 * 这里直接复用 `netdisk_transfer` 渠道和同一个 notificationId，
 * 所以用户看到的仍然是那一条进度通知，不会多出一条。
 */
class TransferService : Service() {
    companion object {
        const val CHANNEL_ID = "netdisk_transfer"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.ieop.netdisk_app.TRANSFER_START"
        const val ACTION_STOP = "com.ieop.netdisk_app.TRANSFER_STOP"
        const val ACTION_UPDATE = "com.ieop.netdisk_app.TRANSFER_UPDATE"

        /** 由 MainActivity 在调用 startForegroundService 前写入，供 onStartCommand 首帧使用。 */
        @Volatile
        var pendingTitle: String = "文件传输"

        @Volatile
        var pendingText: String = ""

        /** -1 表示不确定进度。 */
        @Volatile
        var pendingProgress: Int = -1
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                ensureChannel()
                // Android 14+ 必须声明前台服务类型，否则抛 MissingForegroundServiceTypeException。
                val notification = buildNotification(
                    pendingTitle,
                    pendingText,
                    pendingProgress,
                    ongoing = true,
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }

            ACTION_UPDATE -> {
                NotificationManagerCompat.from(this).notify(
                    NOTIFICATION_ID,
                    buildNotification(pendingTitle, pendingText, pendingProgress, ongoing = true),
                )
            }

            ACTION_STOP -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
        }
        // 进程被杀后重启没有意义：Flutter 引擎已经没了，没人再驱动传输。
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "文件传输",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "上传与下载进度"
            setShowBadge(false)
        }
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Int,
        ongoing: Boolean,
    ): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pending)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)

        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }
}
