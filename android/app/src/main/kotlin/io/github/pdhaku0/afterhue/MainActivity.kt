package io.github.pdhaku0.afterhue

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val mediaLocationRequest = 51241
    private var locationChannel: MethodChannel? = null
    private val locationResults = mutableListOf<MethodChannel.Result>()

    private fun canReadPhotoLocation(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        locationChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "afterhue/photo_location").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "granted" -> result.success(canReadPhotoLocation())
                    "request" -> {
                        if (canReadPhotoLocation()) {
                            result.success(true)
                        } else {
                            locationResults.add(result)
                            if (locationResults.size == 1 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                // Photo EXIF only. ACCESS_FINE/COARSE_LOCATION is not needed.
                                requestPermissions(arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION), mediaLocationRequest)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode == mediaLocationRequest) {
            val allowed = canReadPhotoLocation()
            val pending = locationResults.toList()
            locationResults.clear()
            pending.forEach { it.success(allowed) }
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        locationChannel?.setMethodCallHandler(null)
        locationChannel = null
        val pending = locationResults.toList()
        locationResults.clear()
        pending.forEach { it.success(false) }
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
