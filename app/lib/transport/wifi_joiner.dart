import 'dart:io';

import 'package:flutter/services.dart';

import 'permission_gate.dart';
import 'wifi_join_contract.dart';

/// The Android implementation of [WifiJoinDelegate].
///
/// The native half is `MainActivity.kt`.  It uses `WifiNetworkSpecifier` on
/// API 29+ — the only route that lets an app join a specific network without the
/// user hunting through Settings, and one that raises the system's own consent
/// dialog.  Older releases have no programmatic join, so the settings screen is
/// opened and the outcome is reported as [WifiJoinOutcome.unsupported] so the
/// caller can say something accurate.
///
/// ## The binding, and why it is not optional
///
/// The joined network is app-scoped and was requested **without**
/// `NET_CAPABILITY_INTERNET` — correct, because the camera's AP has no internet
/// and must not take over the phone's default route.  But that also means the
/// system will not route to it by default, so with mobile data up, a request to
/// `192.168.0.10` goes out over cellular and fails even though the Wi-Fi
/// associated.
///
/// [bind] pins this process to the camera's network; [unbind] restores normal
/// routing.  The unbind is not a nicety — skip it and the app has no internet for
/// its whole lifetime.
class PlatformWifiJoinDelegate implements WifiJoinDelegate {
  static const MethodChannel _channel =
      MethodChannel('com.cem1.yi_m1_controller/wifi');

  bool _bound = false;

  /// The network the platform last granted, remembered so a later attempt on the
  /// *same* SSID can skip the consent dialog.
  ///
  /// Android raises its "connect to this network?" prompt per request, so a
  /// dropped link means the user is asked again. Where the platform already holds
  /// a granted network for this SSID, reusing it is the difference between
  /// reconnecting and re-interrogating.
  String? _grantedSsid;

  @override
  bool get isBound => _bound;

  @override
  Future<WifiJoinResult> requestJoin(String ssid, {String? passphrase}) async {
    if (!Platform.isAndroid) {
      return const WifiJoinResult(WifiJoinOutcome.unsupported, 'not Android');
    }

    // Check permissions *before* asking the platform to join.
    //
    // The check exists to *report*, not to gate: two earlier versions refused to
    // even try when their version-based guess said a permission was missing, and
    // when the guess was wrong the user was told to grant a permission they
    // already held and no join was attempted at all. Trying anyway costs one
    // prompt worth of latency and turns an opaque refusal into a real result.
    final perms = await PermissionGate.request();

    try {
      final raw = await _channel.invokeMethod<Object?>('joinCameraAp', {
        'ssid': ssid,
        if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
      });
      final result = _parse(raw, perms);
      if (result.outcome == WifiJoinOutcome.granted) _grantedSsid = ssid;
      return result;
    } on PlatformException catch (e) {
      return _failureFromPlatformException(e, perms);
    } on MissingPluginException {
      // The channel is absent, which means the native side did not register it —
      // worth distinguishing from an ordinary failure, because it is a build
      // problem rather than a user problem.
      return const WifiJoinResult(
          WifiJoinOutcome.failed, 'native Wi-Fi channel is not available');
    }
  }

  /// Turn the native answer into a result, keeping the measured permission state.
  ///
  /// The native side answers a **map** (`status`, `reason`, `detail`,
  /// `permissions`). A plain string is still accepted so an older native build
  /// cannot make this crash, and a bool is accepted because the first native
  /// version answered one.
  WifiJoinResult _parse(Object? raw, WifiPermissions perms) {
    if (raw is Map) {
      final status = raw['status'] as String?;
      final reason = WifiJoinReason.parse(raw['reason'] as String?);
      final detail = raw['detail'] as String?;
      final report = WifiPermissionReport.fromMap(
          raw['permissions'] is Map ? (raw['permissions'] as Map).cast<Object?, Object?>() : null);
      return WifiJoinResult(
        _statusFromToken(status),
        detail,
        // The native classifier wins, but if it saw a permission problem the app
        // can name from its own measurement and the native side could not, say
        // so — the switch being off is the case the platform never mentions.
        reason == WifiJoinReason.unknown && report.locationServicesBlocking == true
            ? WifiJoinReason.locationServicesOff
            : reason,
        report,
      );
    }
    // Legacy: a bare token, or a bool from the very first native version.
    final token = raw?.toString();
    return WifiJoinResult(
      _statusFromToken(token),
      token == null ? perms.summary : '$token | ${perms.summary}',
      WifiJoinReason.unknown,
      WifiPermissionReport(
        fineLocation: perms.locationGranted,
        nearbyWifiDevices: perms.nearbyWifiGranted,
      ),
    );
  }

  static WifiJoinOutcome _statusFromToken(String? token) => switch (token) {
        'granted' => WifiJoinOutcome.granted,
        'suggested' => WifiJoinOutcome.suggested,
        'dismissed' => WifiJoinOutcome.dismissed,
        'timeout' => WifiJoinOutcome.timeout,
        'unsupported' => WifiJoinOutcome.unsupported,
        'permissionDenied' => WifiJoinOutcome.permissionDenied,
        'failed' => WifiJoinOutcome.failed,
        'true' => WifiJoinOutcome.granted,
        'false' => WifiJoinOutcome.dismissed,
        null => WifiJoinOutcome.failed,
        _ when token.toLowerCase().contains('permission') =>
          WifiJoinOutcome.permissionDenied,
        _ => WifiJoinOutcome.failed,
      };

  WifiJoinResult _failureFromPlatformException(
      PlatformException e, WifiPermissions perms) {
    final message = '${e.message}';
    final permission = message.toLowerCase().contains('permission');
    return WifiJoinResult(
      permission ? WifiJoinOutcome.permissionDenied : WifiJoinOutcome.failed,
      '${e.code}: ${e.message}',
      WifiJoinReason.unknown,
      WifiPermissionReport(
        fineLocation: perms.locationGranted,
        nearbyWifiDevices: perms.nearbyWifiGranted,
      ),
    );
  }

  // ------------------------------------------------------- fallback ladder

  /// The full ladder, for when plain [requestJoin] was refused.
  /// ## Why a ladder rather than one API
  ///
  /// There is no single call that is guaranteed to work across Android 10–16 and
  /// every OEM skin, and the failure modes differ: `WifiNetworkSpecifier` is the
  /// only route that joins silently but is refused outright on some devices,
  /// while `WifiNetworkSuggestion` goes through a different platform path that is
  /// often still permitted and needs the user to accept one notification. The
  /// system Wi-Fi panel is the floor: it is a first-party surface and always
  /// works, but it makes the user do the work.
  ///
  /// Because the app knows the passkey, **none of the rungs require the user to
  /// type it** — the passkey genuinely is not shown on the camera, so a design
  /// that asked the user to read it off the camera would simply be broken.
  ///
  /// Returns the first result that has a chance of working. The caller polls the
  /// camera afterwards either way, so a rung that silently did nothing costs time
  /// but never a false success.
  @override
  Future<WifiJoinResult> joinWithFallback(String ssid, {String? passphrase}) async {
    if (!Platform.isAndroid) {
      return const WifiJoinResult(WifiJoinOutcome.unsupported, 'not Android');
    }

    final first = await requestJoin(ssid, passphrase: passphrase);
    if (first.shouldPoll) {
      _grantedSsid = ssid;
      return first;
    }

    // A dismissed prompt is the user's own decision, and a user who dismissed it
    // once does not want it replaced by a notification they did not ask for.
    // Retrying is their call.
    if (first.outcome == WifiJoinOutcome.dismissed ||
        first.outcome == WifiJoinOutcome.timeout) {
      return first;
    }
    // Pre-API-29: `requestJoin` already opened the settings screen.
    if (first.outcome == WifiJoinOutcome.unsupported) return first;

    // Rung 2 — the system's own "add network" sheet, pre-filled with the passkey.
    //
    // Preferred over `WifiNetworkSuggestion` because it is strictly better on
    // every axis that matters here: the platform treats the saved network as if
    // the user had typed it in Settings (so it persists and is usable by the
    // system, not just this app), there is **no per-app approval gate**, and
    // declining it cannot strip this app's Wi-Fi permissions. The user still does
    // not type the passkey, because the app supplies it.
    if (await addNetworkViaSystem(ssid, passphrase: passphrase)) {
      _grantedSsid = ssid;
      return WifiJoinResult(
        WifiJoinOutcome.suggested,
        'the system\'s "add network" sheet was opened with the passkey already '
            'filled in — confirm it there.',
        first.reason,
        first.permissions,
      );
    }

    // Rung 3 — register a suggestion.
    final suggested = await suggest(ssid, passphrase: passphrase);
    if (suggested.outcome == WifiJoinOutcome.suggested) {
      // Remember the SSID even though nothing is bound yet: the association
      // arrives later and unannounced, and [refreshBinding] needs to know which
      // network to look for.
      _grantedSsid = ssid;
      return suggested;
    }

    // Bottom rung. Opening a surface the user did not ask for is only justified
    // once everything automatic has actually been tried.
    final opened = await openJoinSurface();
    return WifiJoinResult(
      WifiJoinOutcome.unsupported,
      'the app cannot join "$ssid" on this phone; the system Wi-Fi '
      '${opened ? "panel was opened" : "settings screen was opened"} '
      'instead. Pick the network there — the passkey is already filled in.',
      first.reason,
      // The suggestion rung is the more recent measurement, so it wins when it
      // produced one; `first` is the fallback.
      suggested.permissions.sdkInt == null
          ? first.permissions
          : suggested.permissions,
    );
  }

  /// Open the system's "add Wi-Fi network" sheet with the passkey pre-filled.
  ///
  /// API 30+. Answers whether the sheet was actually opened — some OEM builds
  /// ship without the activity, and that must fall through to the settings screen
  /// rather than silently doing nothing.
  Future<bool> addNetworkViaSystem(String ssid, {String? passphrase}) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('addNetworkViaSystem', {
            'ssid': ssid,
            if (passphrase != null && passphrase.isNotEmpty)
              'passphrase': passphrase,
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Register the camera's network as a system suggestion.
  ///
  /// A suggestion **persists** on the device, which is a real trade-off: useful,
  /// because the phone then reconnects by itself in later sessions, and a hazard,
  /// because a phone with a live suggestion for an absent camera will attach to a
  /// dead network. [forget] withdraws it.
  Future<WifiJoinResult> suggest(String ssid, {String? passphrase}) async {
    if (!Platform.isAndroid) {
      return const WifiJoinResult(WifiJoinOutcome.unsupported, 'not Android');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('suggestCameraAp', {
        'ssid': ssid,
        if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
      });
      if (raw is! Map) {
        return const WifiJoinResult(WifiJoinOutcome.failed, 'no answer');
      }
      final ok = raw['ok'] == true;
      final report = WifiPermissionReport.fromMap(raw['permissions'] is Map
          ? (raw['permissions'] as Map).cast<Object?, Object?>()
          : null);
      final reason = WifiJoinReason.parse(raw['reason'] as String?);
      if (ok) {
        return WifiJoinResult(
          WifiJoinOutcome.suggested,
          '${raw["reason"]}${raw["detail"] == null ? "" : ": ${raw["detail"]}"}',
          reason,
          report,
        );
      }
      return WifiJoinResult(
        WifiJoinOutcome.failed,
        'suggestion refused (${raw["reason"]}'
        '${raw["detail"] == null ? "" : ": ${raw["detail"]}"})',
        reason,
        report,
      );
    } on PlatformException catch (e) {
      return WifiJoinResult(WifiJoinOutcome.failed, '${e.code}: ${e.message}');
    } on MissingPluginException {
      return const WifiJoinResult(
          WifiJoinOutcome.failed, 'native Wi-Fi channel is not available');
    }
  }

  /// Withdraw a previously added suggestion for [ssid].
  ///
  /// Must be called when the user forgets the camera, or the phone keeps
  /// auto-joining an access point that is not there.
  Future<bool> forget(String ssid) async {
    if (!Platform.isAndroid) return false;
    try {
      final raw = await _channel
          .invokeMethod<Object?>('forgetCameraAp', {'ssid': ssid});
      return raw is Map && raw['ok'] == true;
    } on Object {
      return false;
    }
  }

  /// Read the platform's permission state without prompting.
  ///
  /// Prefers the native channel, which reports the **location master switch** and
  /// the API level alongside the permissions. That extra field is not decoration:
  /// a granted location permission with the switch off is the state the platform
  /// misreports as "permission missing", and it is the one diagnosis this app got
  /// wrong in the field. `permission_handler` cannot see it, so it is only the
  /// fallback.
  Future<WifiPermissionReport> report() async {
    if (!Platform.isAndroid) return const WifiPermissionReport();
    try {
      final raw = await _channel.invokeMethod<Object?>('permissionReport');
      final map = raw is Map ? raw.cast<Object?, Object?>() : null;
      final report = WifiPermissionReport.fromMap(map);
      if (report.sdkInt != null) return report;
    } on Object {
      // Fall through: a channel failure must not make the diagnostics panel
      // empty, because an empty panel reads as "nothing is wrong".
    }
    final perms = await PermissionGate.status();
    return WifiPermissionReport(
      fineLocation: perms.locationGranted,
      nearbyWifiDevices: perms.nearbyWifiGranted,
    );
  }

  /// Open the system's Wi-Fi surface: the quick panel where available, the full
  /// settings screen otherwise. Returns whether the compact panel was used.
  @override
  Future<bool> openJoinSurface() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openWifiPanel') ?? false;
    } on Object {
      return openSettings();
    }
  }

  /// Ask the platform whether the camera's AP is up now, and bind if it is.
  ///
  /// The suggestion path gives no callback, so this is the only way to notice
  /// that Android associated.  It is deliberately cheap and safe to call on a
  /// timer: it does nothing at all until the desired SSID is actually the
  /// connected one, and binding twice is idempotent.
  @override
  Future<bool> refreshBinding() async {
    if (!Platform.isAndroid) return false;
    if (_bound) return true;
    final ssid = _grantedSsid;
    if (ssid == null) return false;
    try {
      final ok = await _channel
          .invokeMethod<bool>('adoptNetworkForSsid', {'ssid': ssid}) ??
          false;
      if (ok) _bound = true;
      return ok;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> openSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openWifiSettings') ?? false;
    } on Object {
      return false;
    }
  }

  /// Open this app's own permission screen.
  ///
  /// Not the Wi-Fi screen: after a refusal the user needs the switch that was
  /// refused, and burying it one level further away is how the previous version
  /// wasted the user's time.
  @override
  Future<bool> openPermissionSettings() => PermissionGate.openSettings();

  /// A fresh permission read, for the diagnostics panel.
  @override
  Future<WifiPermissionReport> readPermissionReport() => report();

  @override
  Future<bool> bind() async {
    if (!Platform.isAndroid) return false;
    try {
      _bound = await _channel.invokeMethod<bool>('bindNetwork') ?? false;
      return _bound;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> unbind() async {
    if (!Platform.isAndroid) return;
    if (!_bound) return;
    try {
      await _channel.invokeMethod<void>('unbindNetwork');
    } on Object {
      // Best effort: the process is going away anyway.
    } finally {
      _bound = false;
    }
  }

  /// Give up the association, not only the pin.
  ///
  /// ## The measured defect this answers
  ///
  /// The maintainer pressed Disconnect and the phone was still on `YI_M1_XXXXXX`
  /// with `192.168.0.3` afterwards. [unbind] had already run: it is not wrong, it
  /// is **incomplete**. `bindProcessToNetwork(null)` changes routing; it does not
  /// withdraw the `NetworkRequest` that brought the network up, and a
  /// `WifiNetworkSpecifier` network lives exactly as long as a request for it
  /// does. The native half of this used to release the request only in
  /// `onDestroy`, i.e. never during an ordinary disconnect.
  ///
  /// ## One call, two cases — deliberately not distinguished here
  ///
  /// * the app asked for the network (specifier, or the suggestion rung) — the
  ///   native side releases its request and, if the association is still there,
  ///   asks the platform to disconnect as well;
  /// * the user joined by hand through Settings or the system sheet — there is no
  ///   app request to release, so `WifiManager.disconnect()` is the only thing
  ///   that ends it. This is the case a fix that only handled the first would
  ///   have missed, and it is the case the app cannot see from this side.
  ///
  /// So both are attempted unconditionally, and the answer says what happened.
  @override
  Future<AssociationRelease> releaseAssociation() async {
    if (!Platform.isAndroid) return AssociationRelease.notApplicable;
    try {
      final raw = await _channel.invokeMethod<Object?>('releaseAssociation');
      if (raw is! Map) return AssociationRelease.refused;
      final released = raw['released'] == true;
      final still = raw['stillAssociated'] == true;
      return AssociationRelease(
        released,
        '${raw['reason'] ?? 'no reason given'}'
        '${raw['detail'] == null ? '' : ': ${raw['detail']}'}',
        stillAssociated: still,
      );
    } on MissingPluginException {
      // A native build without the entry point. Answering "not applicable"
      // rather than "refused" matters: nothing is known to be wrong with the
      // phone, so the caller must not tell the user it is still on the network.
      return AssociationRelease.notApplicable;
    } on Object catch (e) {
      return AssociationRelease(false, 'the release call threw: $e',
          stillAssociated: true);
    }
  }
}
