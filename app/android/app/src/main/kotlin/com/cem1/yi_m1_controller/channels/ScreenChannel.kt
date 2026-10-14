package com.cem1.yi_m1_controller.channels

import android.app.Activity
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Screen-only channel. Its window flag remains scoped to the host Activity. */
object ScreenChannel {
    private const val channelName = "com.cem1.yi_m1_controller/screen"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        // FLAG_KEEP_SCREEN_ON is preferred over a WakeLock: it is
                        // scoped to this window, needs no permission, and cannot
                        // leak — the system clears it when the window goes away.
                        activity.runOnUiThread {
                            if (on) {
                                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
