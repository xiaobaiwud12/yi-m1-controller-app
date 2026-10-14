import 'dart:io';

import 'package:flutter/services.dart';

/// Keeping the screen awake while framing a shot.
///
/// A camera controller is used at arm's length with both hands occupied, so the
/// screen timing out mid-composition is a genuine annoyance rather than a
/// theoretical one.
///
/// ## Why this is not `wakelock_plus`
///
/// It would be one line of Dart plus a dependency, but the native side here is
/// three lines and the project already has a platform channel. Adding a package
/// for `FLAG_KEEP_SCREEN_ON` would also pull in a second, independent lifecycle
/// policy to reason about — and the existing channel is already the place where
/// "Android-specific screen behaviour" belongs.
///
/// ## Why the window flag rather than a `WakeLock`
///
/// `FLAG_KEEP_SCREEN_ON` is scoped to this window, needs **no permission**, and
/// cannot leak: the system clears it when the window goes away. A `WakeLock`
/// needs `WAKE_LOCK`, must be released by hand, and keeps burning after a crash.
/// The official app requests `WAKE_LOCK` in its manifest and then never sets any
/// flag — so its screen sleeps anyway. This is the defect not being repeated.
class ScreenControl {
  static const MethodChannel _channel =
      MethodChannel('com.cem1.yi_m1_controller/screen');

  static bool _on = false;
  static bool get isOn => _on;

  /// Ask the platform to keep the screen on, or to stop.
  ///
  /// Safe to call repeatedly; the native side treats it as an idempotent flag.
  /// Returns whether the request was accepted, so a caller can say so rather
  /// than assuming it worked.
  static Future<bool> keepAwake(bool on) async {
    if (!Platform.isAndroid) return false;
    if (_on == on) return true;
    try {
      await _channel.invokeMethod<bool>('setKeepScreenOn', {'on': on});
      _on = on;
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
