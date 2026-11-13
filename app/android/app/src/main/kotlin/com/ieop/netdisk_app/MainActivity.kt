package com.ieop.netdisk_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 传输进度通知。
 *
 * 没有用 flutter_local_notifications：那个插件要求 compileSdk 37 与 core library
 * desugaring（还带一个 Android 12L 的已知崩溃），而这里只需要「一条可更新的进度通知」。
 * 自己写几十行原生代码反而更稳，而且下一步的 Foreground Service 要复用同一个通知渠道。
 *
 * 只维护**一条**通知（固定 id）：5 个并发任务各发一条会刷屏，汇总成一条更清楚。
 */
class MainActivity : FlutterActivity() {
    private val channelId = "netdisk_transfer"
    private val notificationId = 1001
    private val permissionRequestCode = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        ensureChannel()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "netdisk/notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensurePermission" -> {
                    if (!hasPermission()) requestPermission()
                    result.success(null)
                }

                "show" -> {
                    val title = call.argument<String>("title") ?: "文件传输"
                    val text = call.argument<String>("text") ?: ""
                    // -1 表示不确定进度（滚动条）
                    val progress = call.argument<Int>("progress") ?: -1
                    val ongoing = call.argument<Boolean>("ongoing") ?: true
                    showNotification(title, text, progress, ongoing)
                    result.success(null)
                }

                "cancel" -> {
                    NotificationManagerCompat.from(this).cancel(notificationId)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(channelId) != null) return

        val channel = NotificationChannel(
            channelId,
            "文件传输",
            // LOW：进度通知不该响铃或弹横幅，安静地待在通知栏即可。
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "上传与下载进度"
            setShowBadge(false)
        }
        mgr.createNotificationChannel(channel)
    }

    private fun showNotification(
        title: String,
        text: String,
        progress: Int,
        ongoing: Boolean,
    ) {
        if (!hasPermission()) {
            requestPermission()
            return
        }

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pending)
            .setOngoing(ongoing)
            // 高频更新时不要反复响铃/震动
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)

        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        } else if (ongoing) {
            builder.setProgress(0, 0, true)
        }

        try {
            NotificationManagerCompat.from(this).notify(notificationId, builder.build())
        } catch (_: SecurityException) {
            // 用户在系统设置里撤销了通知权限，忽略即可。
        }
    }

    private fun hasPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    private fun requestPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                permissionRequestCode,
            )
        }
    }
}
