import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// The state of the permissions needed to join the camera's Wi-Fi.
///
/// Reported as a value rather than a nullable string so the caller can tell
/// "granted" from "not granted" **and show the user which one is which**. The
/// first two attempts at this feature failed opaquely precisely because the app
/// could not say what it thought the permission state was.
class WifiPermissions {
  final bool locationGranted;
  final bool nearbyWifiGranted;

  /// Whether the platform may post the notification that the suggestion
  /// fallback depends on.  Not a Wi-Fi permission, but the join cannot complete
  /// without it once that rung is reached.
  final bool notificationsGranted;
  final List<String> problems;

  const WifiPermissions({
    required this.locationGranted,
    required this.nearbyWifiGranted,
    this.notificationsGranted = false,
    this.problems = const [],
  });

  /// Whether a Wi-Fi network request has a chance of succeeding.
  ///
  /// **Either** permission is enough, and that is deliberately permissive:
  /// which one the platform actually consults varies by release and by OEM, and
  /// requiring both would refuse to try on a device where one is permanently
  /// denied for an unrelated reason.
  ///
  /// Note what this does **not** include: `CHANGE_NETWORK_STATE`. That one is a
  /// *normal* permission — declared in the manifest and granted at install, with
  /// no runtime dialog — and its absence is what made every join throw
  /// `SecurityException` while this check reported both permissions as granted.
  /// A runtime check cannot see it and must not pretend to; the manifest audit in
  /// `tools/audit_app_capabilities.py` is what verifies it.
  bool get mayJoin => locationGranted || nearbyWifiGranted;

  String get summary =>
      'location ${locationGranted ? "granted" : "NOT granted"}, '
      'nearby-Wi-Fi ${nearbyWifiGranted ? "granted" : "NOT granted"}, '
      'notifications ${notificationsGranted ? "granted" : "NOT granted"}';

  @override
  String toString() => 'WifiPermissions($summary)';
}

/// Obtains the permissions needed to join the camera's access point.
///
/// ## What went wrong the first two times
///
/// Both earlier versions decided *which* permission to ask for by parsing the
/// Android version out of `Platform.operatingSystemVersion`. That is a guess, and
/// when it guessed low the app asked for the wrong permission — then reported
/// "a required permission is missing" to a user who had already granted it.
///
/// So this does not guess. It requests **both**:
///
/// * a permission that is already granted is a no-op;
/// * a permission that does not exist on the running release is reported as
///   denied, which is harmless because [WifiPermissions.mayJoin] accepts either.
///
/// The result is version-independent, and the app can state exactly what it sees
/// instead of asserting what it expects.
///
/// ## Why the app can report this at all
///
/// `WifiNetworkSpecifier` validates the caller's permission and, when it is
/// missing, throws a `SecurityException` **inside the framework's own callback**.
/// The app never sees that exception — it observes only "unavailable", which is
/// indistinguishable from the user declining. Hence checking up front and
/// surfacing the answer.
class PermissionGate {
  /// Whether the platform is Android at all. Other platforms reach Wi-Fi through
  /// their own means, so there is nothing to gate.
  static bool get isAndroid => Platform.isAndroid;

  /// Ask for everything that might be needed, and report what came back.
  ///
  /// Never throws: a permission plugin that is missing or misbehaving must not
  /// prevent the app from trying the join anyway, because the join is the thing
  /// the user actually wants.
  static Future<WifiPermissions> request() async {
    if (!Platform.isAndroid) {
      return const WifiPermissions(
          locationGranted: true, nearbyWifiGranted: true);
    }

    var location = false;
    var nearby = false;
    var notifications = false;
    final problems = <String>[];

    // All three, unconditionally. See the class comment for why this is not a
    // version check.
    //
    // The third one is not a Wi-Fi permission, and it is here because the Wi-Fi
    // fallback needs it: when `WifiNetworkSpecifier` is refused, the app registers
    // the camera as a **suggestion**, and the platform asks the user for approval
    // through a notification. From API 33 that notification is suppressed without
    // `POST_NOTIFICATIONS`, so the fallback would report success and then do
    // nothing, with no prompt for the user to accept — the same shape of silent
    // inertness as the missing `CHANGE_NETWORK_STATE`.
    //
    // One extra dialog on first connect is the honest price. Asking only when the
    // fallback is reached would be better manners, but that moment is exactly when
    // a suppressed prompt is unrecoverable.
    for (final p in [
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
      Permission.notification,
    ]) {
      try {
        final status = await p.request();
        final granted = status.isGranted;
        switch (p) {
          case Permission.locationWhenInUse:
            location = granted;
          case Permission.nearbyWifiDevices:
            nearby = granted;
          case Permission.notification:
            notifications = granted;
          default:
            break;
        }
        if (!granted) {
          problems.add('${_name(p)}: ${_why(status)}');
        }
      } on Object catch (e) {
        // A plugin failure here is not fatal: the join is still attempted, and a
        // genuine denial will surface as one.
        problems.add('${_name(p)}: could not be checked ($e)');
      }
    }

    return WifiPermissions(
      locationGranted: location,
      nearbyWifiGranted: nearby,
      notificationsGranted: notifications,
      problems: problems,
    );
  }

  /// Read the current state without prompting.
  static Future<WifiPermissions> status() async {
    if (!Platform.isAndroid) {
      return const WifiPermissions(
          locationGranted: true, nearbyWifiGranted: true);
    }
    var location = false;
    var nearby = false;
    var notifications = false;
    try {
      location = (await Permission.locationWhenInUse.status).isGranted;
    } on Object {
      location = false;
    }
    try {
      nearby = (await Permission.nearbyWifiDevices.status).isGranted;
    } on Object {
      nearby = false;
    }
    try {
      notifications = (await Permission.notification.status).isGranted;
    } on Object {
      notifications = false;
    }
    return WifiPermissions(
      locationGranted: location,
      nearbyWifiGranted: nearby,
      notificationsGranted: notifications,
    );
  }

  /// Open this app's page in Android settings, for a permission the user has
  /// permanently refused — the only place it can be changed.
  static Future<bool> openSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await openAppSettings();
    } on Object {
      return false;
    }
  }

  static String _name(Permission p) => switch (p) {
        Permission.nearbyWifiDevices => 'nearby Wi-Fi devices',
        Permission.notification => 'notifications',
        _ => 'location',
      };

  static String _why(PermissionStatus s) {
    if (s.isPermanentlyDenied) return 'permanently denied';
    if (s.isRestricted) return 'restricted by the system';
    if (s.isLimited) return 'limited';
    return 'not granted';
  }
}
