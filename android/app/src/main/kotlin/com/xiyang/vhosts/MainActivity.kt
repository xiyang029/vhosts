package com.xiyang.vhosts

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.net.VpnService
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "vhosts/vpn"
    private val stateEventsChannelName = "vhosts/vpn_state_events"
    private val installerChannelName = "vhosts/installer"
    private val downloadNotificationChannelId = "app_update_download"
    private val notificationPermissionRequestCode = 1002
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var notificationPermissionRequested = false
    private var vpnStateEventSink: EventChannel.EventSink? = null
    private var vpnStateReceiver: BroadcastReceiver? = null
    private lateinit var vpnPermissionLauncher: ActivityResultLauncher<Intent>

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        vpnPermissionLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { activityResult ->
            val granted = activityResult.resultCode == Activity.RESULT_OK
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureDownloadNotificationChannel()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasVpnPermission" -> {
                    result.success(VpnService.prepare(this) == null)
                }
                "saveVpnConfiguration" -> {
                    VhostsVpnService.saveConfiguration(
                        this,
                        call.argument<String>("configurationJson").orEmpty(),
                    )
                    result.success(true)
                }
                "loadAppState" -> {
                    result.success(loadAppState())
                }
                "saveAppState" -> {
                    saveAppState(call.argument<String>("stateJson").orEmpty())
                    result.success(true)
                }
                "requestVpnPermission" -> {
                    requestVpnPermission(result)
                }
                "startVpn" -> {
                    val configurationJson = call.argument<String>("configurationJson")
                    if (configurationJson.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    VhostsVpnService.saveConfiguration(this, configurationJson)
                    result.success(startVpn(configurationJson))
                }
                "stopVpn" -> {
                    result.success(stopVpn())
                }
                "testDnsProfile" -> {
                    val profileJson = call.argument<String>("profileJson")
                    val allowIpv6 = call.argument<Boolean>("allowIpv6") ?: true
                    if (profileJson.isNullOrBlank()) {
                        result.success(
                            mapOf(
                                "healthStatus" to "offline",
                                "healthDetail" to "缺少 DNS 配置，无法执行探测",
                                "latencyMs" to null,
                            ),
                        )
                        return@setMethodCallHandler
                    }

                    thread(name = "dns-health-check", isDaemon = true) {
                        val payload = runDnsHealthCheck(this, profileJson, allowIpv6)
                        runOnUiThread {
                            result.success(payload)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, stateEventsChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    vpnStateEventSink = events
                    registerVpnStateReceiver()
                    emitVpnState()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterVpnStateReceiver()
                    vpnStateEventSink = null
                }
            },
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestPackageInstalls" -> {
                    result.success(canRequestPackageInstalls())
                }
                "openInstallPermissionSettings" -> {
                    openInstallPermissionSettings()
                    result.success(null)
                }
                "showDownloadNotification" -> {
                    try {
                        showDownloadNotification(
                            id = call.argument<Int>("id") ?: 1001,
                            title = call.argument<String>("title") ?: "应用更新",
                            content = call.argument<String>("content") ?: "",
                            progress = call.argument<Int>("progress"),
                            completed = call.argument<Boolean>("completed") ?: false,
                            failed = call.argument<Boolean>("failed") ?: false,
                        )
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("show_notification_failed", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        emitVpnState()
    }

    override fun onDestroy() {
        unregisterVpnStateReceiver()
        super.onDestroy()
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }

        if (pendingPermissionResult != null) {
            result.error("busy", "VPN permission request already in progress", null)
            return
        }

        pendingPermissionResult = result
        vpnPermissionLauncher.launch(intent)
    }

    private fun startVpn(configurationJson: String): Boolean {
        if (VpnService.prepare(this) != null) {
            emitVpnState(
                mapOf(
                    "authorized" to false,
                    "running" to false,
                ),
            )
            return false
        }

        return dispatchVpnAction(
            action = VhostsVpnService.ACTION_START,
            configurationJson = configurationJson,
            useForegroundService = true,
        )
    }

    private fun stopVpn(): Boolean {
        return dispatchVpnAction(VhostsVpnService.ACTION_STOP)
    }

    private fun dispatchVpnAction(
        action: String,
        configurationJson: String? = null,
        useForegroundService: Boolean = false,
    ): Boolean {
        val intent = Intent(this, VhostsVpnService::class.java).apply {
            this.action = action
            configurationJson?.let {
                putExtra(VhostsVpnService.EXTRA_CONFIGURATION_JSON, it)
            }
        }

        return try {
            if (useForegroundService) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun currentVpnStatePayload(): Map<String, Boolean> {
        val authorized = VpnService.prepare(this) == null
        return mapOf(
            "authorized" to authorized,
            "running" to (authorized && VhostsVpnService.isRunning(this)),
        )
    }

    private fun registerVpnStateReceiver() {
        if (vpnStateReceiver != null) {
            return
        }

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == VhostsVpnService.ACTION_VPN_STATE_CHANGED) {
                    emitVpnState(VhostsVpnService.statePayloadFromIntent(intent))
                }
            }
        }
        vpnStateReceiver = receiver

        val filter = IntentFilter(VhostsVpnService.ACTION_VPN_STATE_CHANGED)
        registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
    }

    private fun unregisterVpnStateReceiver() {
        val receiver = vpnStateReceiver ?: return
        try {
            unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        vpnStateReceiver = null
    }

    private fun emitVpnState(payload: Map<String, Boolean>? = null) {
        vpnStateEventSink?.success(payload ?: currentVpnStatePayload())
    }

    private fun canRequestPackageInstalls(): Boolean {
        return packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun ensureDownloadNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(downloadNotificationChannelId) != null) {
            return
        }

        val channel = NotificationChannel(
            downloadNotificationChannelId,
            "应用更新下载",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "显示应用更新包下载进度"
        }
        manager.createNotificationChannel(channel)
    }

    private fun showDownloadNotification(
        id: Int,
        title: String,
        content: String,
        progress: Int?,
        completed: Boolean,
        failed: Boolean,
    ) {
        if (!canPostNotifications()) {
            return
        }

        val statusIcon = if (completed) {
            android.R.drawable.stat_sys_download_done
        } else {
            android.R.drawable.stat_sys_download
        }
        val notification = Notification.Builder(this, downloadNotificationChannelId)
            .setSmallIcon(statusIcon)
            .setContentTitle(title)
            .setContentText(content)
            .setOnlyAlertOnce(true)
            .setOngoing(!completed && !failed)
            .setAutoCancel(completed || failed)
            .apply {
                if (progress != null) {
                    setProgress(100, progress.coerceIn(0, 100), false)
                } else if (!completed && !failed) {
                    setProgress(0, 0, true)
                }
            }
            .build()

        getSystemService(NotificationManager::class.java).notify(id, notification)
    }

    private fun canPostNotifications(): Boolean {
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted && !notificationPermissionRequested) {
            notificationPermissionRequested = true
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequestCode,
            )
        }
        return granted
    }

    private fun loadAppState(): String? {
        return getSharedPreferences(APP_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .getString(KEY_APP_STATE_JSON, null)
            ?.takeIf { it.isNotBlank() }
    }

    private fun saveAppState(stateJson: String) {
        getSharedPreferences(APP_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_APP_STATE_JSON, stateJson)
            .apply()
    }

    companion object {
        private const val APP_PREFERENCES_NAME = "vhosts_app"
        private const val KEY_APP_STATE_JSON = "app_state_json"
    }
}
