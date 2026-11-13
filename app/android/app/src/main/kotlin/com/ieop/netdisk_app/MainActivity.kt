package com.ieop.netdisk_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 传输进度通知 + 前台服务 + 厂商后台策略引导。
 *
 * 没有用 flutter_local_notifications：那个插件要求 compileSdk 37 与 core library
 * desugaring（还带一个 Android 12L 的已知崩溃），而这里只需要「一条可更新的进度通知」
 * 和「一个保活的服务」。自己写原生反而更稳。
 *
 * 通知只维护**一条**（固定 id）：5 个并发任务各发一条会刷屏，汇总成一条更清楚。
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
                    val progress = call.argument<Int>("progress") ?: -1
                    val ongoing = call.argument<Boolean>("ongoing") ?: true
                    showNotification(title, text, progress, ongoing)
                    result.success(null)
                }

                "cancel" -> {
                    NotificationManagerCompat.from(this).cancel(notificationId)
                    result.success(null)
                }

                // ---- 前台服务 ----
                "startService" -> {
                    cachePayload(call)
                    val intent = Intent(this, TransferService::class.java)
                        .setAction(TransferService.ACTION_START)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }

                "updateService" -> {
                    cachePayload(call)
                    startService(
                        Intent(this, TransferService::class.java)
                            .setAction(TransferService.ACTION_UPDATE),
                    )
                    result.success(null)
                }

                "stopService" -> {
                    startService(
                        Intent(this, TransferService::class.java)
                            .setAction(TransferService.ACTION_STOP),
                    )
                    result.success(null)
                }

                // ---- 厂商适配 ----
                "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())

                "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())

                "openAutoStartSettings" -> result.success(openAutoStartSettings())

                "deviceInfo" -> result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "brand" to Build.BRAND,
                        "model" to Build.MODEL,
                        "sdk" to Build.VERSION.SDK_INT,
                        "harmony" to isHarmonyOs(),
                    ),
                )

                else -> result.notImplemented()
            }
        }
    }

    private fun cachePayload(call: MethodCall) {
        TransferService.pendingTitle = call.argument<String>("title") ?: "文件传输"
        TransferService.pendingText = call.argument<String>("text") ?: ""
        TransferService.pendingProgress = call.argument<Int>("progress") ?: -1
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

    // ---------------------------------------------------------------------
    // 厂商后台策略
    // ---------------------------------------------------------------------

    /** 是否已豁免电池优化。未豁免时系统更倾向在后台冻结或回收进程。 */
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(PowerManager::class.java) ?: return false
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * 弹出系统的「忽略电池优化」确认框。
     *
     * 这是通用做法；华为/小米等还有自己的「自启动」「后台活动」开关，
     * 系统对话框管不到，需要 [openAutoStartSettings] 再引导一次。
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName")),
            )
            true
        } catch (_: Exception) {
            openAppSettings()
        }
    }

    /**
     * 跳转到厂商的「自启动 / 后台管理」设置页。
     *
     * 各家的 Activity 名不通用且随时可能被 ROM 改掉，所以列一串候选逐个尝试，
     * 全部失败时退回应用详情页 —— 至少让用户能找到入口。
     */
    private fun openAutoStartSettings(): Boolean {
        val candidates = mutableListOf<ComponentName>()
        when (Build.MANUFACTURER.lowercase()) {
            "huawei" -> {
                candidates += ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                )
                candidates += ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity",
                )
            }

            "honor" -> {
                candidates += ComponentName(
                    "com.hihonor.systemmanager",
                    "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                )
                candidates += ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                )
            }

            "xiaomi", "redmi" -> candidates += ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            )

            "oppo", "realme", "oneplus" -> {
                candidates += ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                )
                candidates += ComponentName(
                    "com.oplus.safecenter",
                    "com.oplus.safecenter.permission.startup.StartupAppListActivity",
                )
            }

            "vivo", "iqoo" -> {
                candidates += ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                )
                candidates += ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                )
            }

            "meizu" -> candidates += ComponentName(
                "com.meizu.safe",
                "com.meizu.safe.permission.SmartBGActivity",
            )

            "samsung" -> candidates += ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.ui.battery.BatteryActivity",
            )
        }

        for (component in candidates) {
            try {
                startActivity(
                    Intent().setComponent(component)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return true
            } catch (_: Exception) {
                // 该 ROM 上没有这个页面，试下一个
            }
        }

        openAppSettings()
        return false
    }

    private fun openAppSettings(): Boolean = try {
        startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"),
            ),
        )
        true
    } catch (_: Exception) {
        false
    }

    /** HarmonyOS 的 Build.MANUFACTURER 仍是 huawei，用系统属性进一步区分。 */
    private fun isHarmonyOs(): Boolean = try {
        val clazz = Class.forName("com.huawei.system.BuildEx")
        val method = clazz.getMethod("getOsBrand")
        method.invoke(clazz)?.toString()?.lowercase()?.contains("harmony") == true
    } catch (_: Throwable) {
        false
    }
}
