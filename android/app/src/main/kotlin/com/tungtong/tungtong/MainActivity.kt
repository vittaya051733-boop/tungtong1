package com.tungtong.tungtong

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val channelName = "tungtong/notifications"
	private val requestCodePostNotifications = 1001
	private var pendingPermissionResult: MethodChannel.Result? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"requestPermission" -> {
						requestNotificationPermission(result)
					}
					else -> result.notImplemented()
				}
			}
	}

	private fun requestNotificationPermission(result: MethodChannel.Result) {
		if (Build.VERSION.SDK_INT < 33) {
			result.success(true)
			return
		}

		val alreadyGranted = ContextCompat.checkSelfPermission(
			this,
			Manifest.permission.POST_NOTIFICATIONS
		) == PackageManager.PERMISSION_GRANTED

		if (alreadyGranted) {
			result.success(true)
			return
		}

		// Avoid multiple concurrent permission requests.
		if (pendingPermissionResult != null) {
			result.success(false)
			return
		}

		pendingPermissionResult = result
		ActivityCompat.requestPermissions(
			this,
			arrayOf(Manifest.permission.POST_NOTIFICATIONS),
			requestCodePostNotifications
		)
	}

	override fun onRequestPermissionsResult(
		requestCode: Int,
		permissions: Array<out String>,
		grantResults: IntArray
	) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults)
		if (requestCode != requestCodePostNotifications) return
		val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
		pendingPermissionResult?.success(granted)
		pendingPermissionResult = null
	}
}
