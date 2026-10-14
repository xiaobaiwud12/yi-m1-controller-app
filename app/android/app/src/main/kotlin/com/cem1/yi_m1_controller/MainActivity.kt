package com.cem1.yi_m1_controller

import android.content.Intent
import com.cem1.yi_m1_controller.channels.ScreenChannel
import com.cem1.yi_m1_controller.media.MediaStoreChannel
import com.cem1.yi_m1_controller.wifi.WifiCameraChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** Hosts Flutter and forwards system events to the Activity-scoped channels. */
class MainActivity : FlutterActivity() {
    private lateinit var mediaChannel: MediaStoreChannel
    private lateinit var wifiChannel: WifiCameraChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Reuse owners if an engine is attached again to this Activity.
        if (!::wifiChannel.isInitialized) wifiChannel = WifiCameraChannel(this)
        if (!::mediaChannel.isInitialized) mediaChannel = MediaStoreChannel(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ScreenChannel.register(this, messenger)
        mediaChannel.register(messenger)
        wifiChannel.register(messenger)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (::wifiChannel.isInitialized) wifiChannel.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (::mediaChannel.isInitialized) mediaChannel.onPermissionResult(requestCode, grantResults)
    }

    override fun onPause() {
        super.onPause()
        if (::wifiChannel.isInitialized) wifiChannel.pause()
    }

    override fun onDestroy() {
        if (::wifiChannel.isInitialized) wifiChannel.dispose()
        if (::mediaChannel.isInitialized) mediaChannel.dispose()
        super.onDestroy()
    }
}
