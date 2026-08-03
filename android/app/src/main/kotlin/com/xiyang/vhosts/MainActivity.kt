package com.xiyang.vhosts

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val appChannelName = "vhosts/app"
    private val installerChannelName = "vhosts/installer"
    private val toastChannelName = "vhosts/toast"
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private lateinit var notificationPermissionLauncher: ActivityResultLauncher<String>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        notificationPermissionLauncher = registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { granted ->
            pendingNotificationPermissionResult?.success(granted)
            pendingNotificationPermissionResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "loadAppState" -> result.success(loadAppState())
                    "saveAppState" -> {
                        saveAppState(call.argument<String>("stateJson").orEmpty())
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
                    "requestNotificationPermission" -> requestNotificationPermission(result)
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

    private fun canRequestPackageInstalls(): Boolean = packageManager.canRequestPackageInstalls()

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
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
        private const val APP_PREFERENCES_NAME = "vhosts_app"
        private const val KEY_APP_STATE_JSON = "app_state_json"
    }
}
