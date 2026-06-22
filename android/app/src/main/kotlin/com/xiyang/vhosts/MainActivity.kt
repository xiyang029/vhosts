package com.xiyang.vhosts

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.net.VpnService
import android.widget.Toast
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "vhosts/vpn"
    private val stateEventsChannelName = "vhosts/vpn_state_events"
    private val installerChannelName = "vhosts/installer"
    private val toastChannelName = "vhosts/toast"
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var vpnStateEventSink: EventChannel.EventSink? = null
    private var vpnStateReceiver: BroadcastReceiver? = null
    private lateinit var vpnPermissionLauncher: ActivityResultLauncher<Intent>
    private lateinit var notificationPermissionLauncher: ActivityResultLauncher<String>

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        vpnPermissionLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { activityResult ->
            val granted = activityResult.resultCode == Activity.RESULT_OK
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
        notificationPermissionLauncher = registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { granted ->
            pendingNotificationPermissionResult?.success(granted)
            pendingNotificationPermissionResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                "requestNotificationPermission" -> {
                    requestNotificationPermission(result)
                }
                "getDownloadDirectory" -> {
                    result.success(cacheDir.absolutePath)
                }
                "openInstallPermissionSettings" -> {
                    openInstallPermissionSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, toastChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "showToast" -> {
                    val message = call.argument<String>("message").orEmpty()
                    val isLong = call.argument<Boolean>("long") ?: false
                    Toast.makeText(
                        this,
                        message,
                        if (isLong) Toast.LENGTH_LONG else Toast.LENGTH_SHORT,
                    ).show()
                    result.success(true)
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

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        if (pendingNotificationPermissionResult != null) {
            result.error("busy", "Notification permission request already in progress", null)
            return
        }

        pendingNotificationPermissionResult = result
        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
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
