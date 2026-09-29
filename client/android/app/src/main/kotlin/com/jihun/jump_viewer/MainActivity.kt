package com.jihun.jump_viewer

import android.content.pm.ActivityInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Screen rotation for the viewer only. Flutter's SystemChrome maps "any orientation" to
        // the USER variants, which obey the phone's rotation lock; the viewer's 자동/가로 should
        // follow the sensor inside this app even when the phone is locked to portrait.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jump/orientation")
            .setMethodCallHandler { call, result ->
                requestedOrientation = when (call.arguments as? String) {
                    "auto" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR
                    "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                    "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED // back to the phone's setting
                }
                result.success(null)
            }
    }
}
