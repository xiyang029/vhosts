package com.xiyang.vhosts

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val appChannelName = "vhosts/app"
    private val dnsChannelName = "vhosts/dns"
    private val dnsEventChannelName = "vhosts/dns/events"
    private val installerChannelName = "vhosts/installer"
    private val toastChannelName = "vhosts/toast"
    private var pendingVpnPermissionResult: MethodChannel.Result? = null
    private var dnsEventSink: EventChannel.EventSink? = null
    private val dnsExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val vpnStatusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            dnsEventSink?.success(intent?.getStringExtra(DnsVpnService.EXTRA_STATUS))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerReceiver(
            vpnStatusReceiver,
            IntentFilter(DnsVpnService.ACTION_STATUS),
            RECEIVER_NOT_EXPORTED,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "loadAppState" -> result.success(loadAppState())
                    "getAppVersion" -> result.success(
                        packageManager.getPackageInfo(packageName, 0).versionName.orEmpty(),
                    )
                    "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "saveAppState" -> {
                        saveAppState(call.argument<String>("stateJson").orEmpty())
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, dnsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestVpnPermission" -> requestVpnPermission(result)
                    "startVpn" -> {
                        val profile = call.argument<String>("profileJson").orEmpty()
                        val rules = call.argument<String>("hostRulesJson").orEmpty()
                        val serviceIntent = Intent(this, DnsVpnService::class.java)
                            .setAction(DnsVpnService.ACTION_START)
                            .putExtra(DnsVpnService.EXTRA_PROFILE, profile)
                            .putExtra(DnsVpnService.EXTRA_RULES, rules)
                        startForegroundService(serviceIntent)
                        result.success(true)
                    }
                    "stopVpn" -> {
                        startService(Intent(this, DnsVpnService::class.java).setAction(DnsVpnService.ACTION_STOP))
                        result.success(true)
                    }
                    "testDns" -> testDns(call.argument<String>("profileJson").orEmpty(), result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, dnsEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    dnsEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    dnsEventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
                    "getDownloadDirectory" -> result.success(cacheDir.absolutePath)
                    "openInstallPermissionSettings" -> {
                        openInstallPermissionSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, toastChannelName)
            .setMethodCallHandler { call, result ->
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

    private fun requestVpnPermission(result: MethodChannel.Result) {
        if (pendingVpnPermissionResult != null) {
            result.error("busy", "VPN permission request already in progress", null)
            return
        }
        val prepareIntent = android.net.VpnService.prepare(this)
        if (prepareIntent == null) {
            result.success(true)
            return
        }
        pendingVpnPermissionResult = result
        startActivityForResult(prepareIntent, VPN_PERMISSION_REQUEST_CODE)
    }

    private fun testDns(profileJson: String, result: MethodChannel.Result) {
        dnsExecutor.execute {
            try {
                val profile = DnsProfileConfig.fromJson(JSONObject(profileJson))
                val network = underlyingNetwork()
                val testResult = DnsTransport(profile = profile, network = network).test()
                mainHandler.post { result.success(testResult.toMap()) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.success(
                        mapOf(
                            "success" to false,
                            "latencyMs" to null,
                            "detail" to (error.message ?: "DNS 配置无效"),
                        ),
                    )
                }
            }
        }
    }

    private fun underlyingNetwork(): android.net.Network? {
        val connectivity = getSystemService(android.net.ConnectivityManager::class.java)
        val candidate = connectivity.allNetworks.firstOrNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network)
            capabilities?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true &&
                capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN).not()
        }
        return candidate ?: connectivity.activeNetwork
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            pendingVpnPermissionResult?.success(resultCode == RESULT_OK)
            pendingVpnPermissionResult = null
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(vpnStatusReceiver)
        } catch (_: Exception) {
        }
        dnsExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun canRequestPackageInstalls(): Boolean = packageManager.canRequestPackageInstalls()

    private fun openInstallPermissionSettings() {
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) },
        )
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
        private const val VPN_PERMISSION_REQUEST_CODE = 7101
        private const val APP_PREFERENCES_NAME = "vhosts_dns_state"
        private const val KEY_APP_STATE_JSON = "state_json"
    }
}
