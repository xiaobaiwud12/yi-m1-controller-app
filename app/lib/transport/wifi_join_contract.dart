/// Asking the operating system to join the camera's access point.
///
/// The contract only — the Flutter platform-channel implementation lives in
/// `wifi_joiner.dart` — so the connection state machine can be exercised in the
/// plain Dart VM by `tool/verify_sync.dart`.
///
/// ## Why the app cannot simply join the network itself
///
/// The camera runs its own AP whose 8-digit passkey **changes on every power
/// cycle**, so the user cannot save the network once and forget it. Android can
/// join programmatically, but only with user consent and only through
/// `WifiNetworkSpecifier` (API 29+), which raises a system dialog.
///
/// ## Why a bool was not enough
///
/// An earlier version returned `true`/`false`, which conflates three completely
/// different situations: the user dismissed the prompt, the join timed out, and
/// the platform has no programmatic join at all. The caller could only respond by
/// telling the user to go to Settings by hand — **even when they had just tapped
/// "Connect" and it worked**. [WifiJoinOutcome] exists so the UI can say something
/// true instead.
///
/// ## Why binding matters
///
/// A network joined through `WifiNetworkSpecifier` is scoped to the app and is
/// deliberately requested *without* `NET_CAPABILITY_INTERNET` — the camera's AP
/// has no internet and must not become the phone's default route. The
/// consequence is that **the system will not route to it by default**: with
/// mobile data active, a request to `192.168.0.10` goes out over cellular and
/// fails, even though the Wi-Fi association succeeded.
///
/// So after a successful join the process must be bound to that network, and —
/// this is the part that is easy to forget — **unbound again**, or the whole app
/// loses internet for as long as it runs. See `NetworkBinder`.
library;

/// How a join attempt ended.
enum WifiJoinOutcome {
  /// The radio associated.  This is **not** proof the camera is reachable — the
  /// caller must still poll it over HTTP.
  granted,

  /// The user dismissed the system prompt.
  dismissed,

  /// The system did not answer within the platform's own window.
  timeout,

  /// The app does not hold a permission the platform requires to request a
  /// network.
  ///
  /// Its own case rather than a flavour of [failed], because it is the one
  /// failure the user can fix, and the fix is specific: grant the permission, or
  /// join the network by hand. Discovering this cost a round trip — with the
  /// permission missing, the platform throws a `SecurityException` inside its own
  /// callback, so the app observed only "unavailable" and could say nothing
  /// useful while then waiting out its full timeout.
  permissionDenied,

  /// No programmatic join exists on this platform or release; a settings screen
  /// was opened for the user instead.
  unsupported,

  /// The app could not join, so the camera's network was registered as a system
  /// **suggestion** instead.  Android usually associates on its own once the
  /// user accepts the notification, so the caller should keep polling rather than
  /// give up.
  suggested,

  /// Anything else, with the platform's message carried alongside.
  failed,
}

/// Which specific platform permission the join was refused for.
///
/// Kept as an enum rather than a message because **naming the wrong permission is
/// worse than naming none**: the app has twice sent the user to a switch that was
/// already on. An unrecognised refusal stays [unknown] and the raw platform text
/// is shown instead, so the user sees the truth rather than a confident guess.
enum WifiJoinReason {
  /// The app does not hold `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`.
  fineLocation,

  /// The app does not hold `NEARBY_WIFI_DEVICES`, or the OEM's equivalent.
  nearbyWifiDevices,

  /// Location services are switched off for the whole device.
  ///
  /// The trap that produced the false diagnosis: the permission is granted, the
  /// master switch is off, and the platform reports a permission failure anyway.
  /// The fix is the quick-settings tile, not the permission screen.
  locationServicesOff,

  /// The app does not hold `CHANGE_WIFI_STATE` / `CHANGE_NETWORK_STATE`.
  changeWifiState,

  /// `CHANGE_NETWORK_STATE` is not declared in the manifest.
  ///
  /// **This is the one that actually happened, and it cost three rounds of
  /// testing.** `ConnectivityService.enforceChangePermission()` throws before the
  /// request is dispatched when this permission is absent, and it is a *normal*
  /// permission — declaring it is enough, nothing is granted at runtime. It was
  /// simply never declared, and because `ACCESS_NETWORK_STATE` *was* declared,
  /// the permission list looked complete.
  changeNetworkState,

  /// The calling package does not belong to the calling UID.
  ///
  /// Raised by `AppOpsManager.checkPackage`. MIUI's 双开 / 第二空间 (Dual Apps /
  /// Second Space) clones the app under a different UID, which is the shape this
  /// detects — so the fix is to run outside the clone, and no permission grant
  /// can help.
  uidPackageMismatch,

  /// An OEM (MIUI/HyperOS, EMUI, ColorOS…) refused the request itself.
  oemRestriction,

  /// A permission is named that this app has no specific advice for.
  otherPermission,

  /// The refusal was not about permissions.
  notPermission,

  /// The platform gave no reason at all.
  unknown;

  /// Parse the token the native side sends.
  static WifiJoinReason parse(String? token) => switch (token) {
        'fineLocation' => fineLocation,
        'nearbyWifiDevices' => nearbyWifiDevices,
        'locationServicesOff' => locationServicesOff,
        'changeWifiState' => changeWifiState,
        'changeNetworkState' => changeNetworkState,
        'uidPackageMismatch' => uidPackageMismatch,
        'oemRestriction' => oemRestriction,
        'otherPermission' => otherPermission,
        'notPermission' => notPermission,
        // `android_too_old`, `no_wifi_service`, `unavailable`, `busy` … all mean
        // "the platform did not tell us which permission", which is `unknown`
        // and never a guess.
        _ => unknown,
      };

  /// Whether this reason points at a permission the user can grant.
  bool get isGrantable =>
      this == fineLocation ||
      this == nearbyWifiDevices ||
      this == changeWifiState;
}

/// What the platform reports about its own permissions, measured at the moment
/// of the attempt.
///
/// Every join answer carries one of these. It exists because the app previously
/// had to *guess* whether a permission was held, and guessed wrong — telling the
/// user to grant something they already had. Facts are cheap; guessing is not.
class WifiPermissionReport {
  final int? sdkInt;
  final int? targetSdk;
  final String? android;
  final String? manufacturer;
  final bool? fineLocation;
  final bool? coarseLocation;
  final bool? nearbyWifiDevices;
  final bool? changeWifiState;
  final bool? accessWifiState;

  /// Whether `CHANGE_NETWORK_STATE` is declared.
  ///
  /// A *normal* permission, so this is a build fact rather than something the
  /// user granted — and its absence is the reason every join threw
  /// `SecurityException` for three rounds of testing. Reported as a measured value
  /// so a screenshot of the diagnostics panel identifies it.
  final bool? changeNetworkState;

  /// Whether the platform may post notifications.
  ///
  /// Not a Wi-Fi permission, but the suggestion rung of the fallback ladder asks
  /// for approval *through* a notification, so from API 33 a missing grant makes
  /// that rung silently inert.
  final bool? notifications;

  /// How the system "add network" sheet ended (`saved`, `cancelled`, …).
  final String? addNetworkResult;

  /// Whether the device's location master switch is on.
  final bool? locationServices;

  /// Whether the switch is off **while the permission is granted** — the state
  /// that reads as "permission missing" but is fixed somewhere else entirely.
  final bool? locationServicesBlocking;
  final bool? wifiEnabled;

  const WifiPermissionReport({
    this.sdkInt,
    this.targetSdk,
    this.android,
    this.manufacturer,
    this.fineLocation,
    this.coarseLocation,
    this.nearbyWifiDevices,
    this.changeWifiState,
    this.accessWifiState,
    this.changeNetworkState,
    this.notifications,
    this.addNetworkResult,
    this.locationServices,
    this.locationServicesBlocking,
    this.wifiEnabled,
  });

  static WifiPermissionReport fromMap(Map<Object?, Object?>? map) {
    if (map == null) return const WifiPermissionReport();
    bool? asBool(String k) => map[k] is bool ? map[k] as bool : null;
    int? asInt(String k) => map[k] is int ? map[k] as int : null;
    String? asString(String k) => map[k] is String ? map[k] as String : null;
    return WifiPermissionReport(
      sdkInt: asInt('sdkInt'),
      targetSdk: asInt('targetSdk'),
      android: asString('android'),
      manufacturer: asString('manufacturer'),
      fineLocation: asBool('fineLocation'),
      coarseLocation: asBool('coarseLocation'),
      nearbyWifiDevices: asBool('nearbyWifiDevices'),
      changeWifiState: asBool('changeWifiState'),
      accessWifiState: asBool('accessWifiState'),
      changeNetworkState: asBool('changeNetworkState'),
      notifications: asBool('notifications'),
      addNetworkResult: asString('addNetworkResult'),
      locationServices: asBool('locationServices'),
      locationServicesBlocking: asBool('locationServicesBlocking'),
      wifiEnabled: asBool('wifiEnabled'),
    );
  }

  /// A one-line, screen-readable summary of what the platform actually said.
  ///
  /// Deliberately verbose: this string is the diagnostic, and it is what makes a
  /// user's screenshot sufficient to identify the cause without a logcat.
  String get summary => [
        'Android $android (API $sdkInt, target $targetSdk, $manufacturer)',
        'location perm ${_yn(fineLocation)}',
        if (nearbyWifiDevices != null) 'nearby-Wi-Fi perm ${_yn(nearbyWifiDevices)}',
        'location services ${_yn(locationServices)}',
        'Wi-Fi ${_yn(wifiEnabled)}',
        if (notifications != null) 'notifications ${_yn(notifications)}',
        if (addNetworkResult != null) 'add-network sheet: $addNetworkResult',
      ].join(' · ');

  /// Only the parts that are wrong, for a compact UI line. Empty when nothing is.
  String get problems {
    final out = <String>[];
    if (locationServicesBlocking == true) {
      out.add('location services are switched off');
    }
    if (fineLocation == false && nearbyWifiDevices != true) {
      out.add('no location permission');
    }
    if (wifiEnabled == false) out.add('Wi-Fi is off');
    // Named separately because its consequence is indirect: Wi-Fi can still be
    // joined the normal way, but the suggestion fallback goes quiet, and a silent
    // fallback is indistinguishable from a fallback that was never tried.
    if (notifications == false && sdkInt != null && sdkInt! >= 33) {
      out.add('notifications are off, so the "add network" fallback cannot ask '
          'for approval');
    }
    return out.join(', ');
  }

  static String _yn(bool? v) => switch (v) {
        true => 'granted',
        false => 'NOT granted',
        null => 'unknown',
      };

  @override
  String toString() => 'WifiPermissionReport($summary)';
}

/// Result of a join attempt.
class WifiJoinResult {
  final WifiJoinOutcome outcome;
  final String? detail;

  /// Which permission (if any) the refusal named.
  final WifiJoinReason reason;

  /// The platform's own permission state at the moment of the attempt.
  final WifiPermissionReport permissions;

  const WifiJoinResult(
    this.outcome, [
    this.detail,
    this.reason = WifiJoinReason.unknown,
    this.permissions = const WifiPermissionReport(),
  ]);

  /// Whether the caller should go straight on to polling the camera.
  bool get shouldPoll =>
      outcome == WifiJoinOutcome.granted || outcome == WifiJoinOutcome.suggested;

  /// Whether the user must be asked to join manually.
  bool get needsManualStep =>
      outcome == WifiJoinOutcome.dismissed ||
      outcome == WifiJoinOutcome.permissionDenied ||
      outcome == WifiJoinOutcome.unsupported ||
      outcome == WifiJoinOutcome.failed;

  /// True when the user can resolve this themselves, and how badly they are
  /// needed — the UI shows a different message for a missing permission than for
  /// a declined prompt.
  bool get isUserFixable => outcome == WifiJoinOutcome.permissionDenied;

  /// A sentence naming the actual cause, rather than a guess about it.
  ///
  /// This is the text the user reads, so it is built from [reason] and the
  /// measured [permissions] — never from the Android version.
  String get explanation {
    switch (reason) {
      case WifiJoinReason.fineLocation:
        return 'Android refused: this app does not have the location permission. '
            'Grant it in Android settings, then retry.';
      case WifiJoinReason.nearbyWifiDevices:
        return 'Android refused: this app does not have the "nearby Wi-Fi '
            'devices" permission. Grant it in Android settings, then retry.';
      case WifiJoinReason.locationServicesOff:
        return 'Android refused because **location services are switched off**. '
            'The permission is granted — turn on the location toggle in quick '
            'settings, then retry.';
      case WifiJoinReason.changeWifiState:
        return 'Android refused: this app is missing the Wi-Fi control '
            'permission, which is normally granted at install. Reinstalling the '
            'app restores it.';
      case WifiJoinReason.changeNetworkState:
        // Deliberately does NOT tell the user to grant anything: this permission
        // is normal, not runtime, so there is no switch to flip. Naming a
        // permission the user cannot act on is what made three rounds of testing
        // useless.
        return 'Android refused before trying: the app does not declare the '
            'CHANGE_NETWORK_STATE permission, which Android requires to request '
            'a network. This is a bug in the app, not a setting on this phone — '
            'no permission you grant can fix it. Please report it; joining the '
            'network by hand still works.';
      case WifiJoinReason.uidPackageMismatch:
        return 'Android refused because the app\'s package does not match the '
            'user it is running as — this happens when an app is launched from a '
            'clone such as MIUI Dual Apps or Second Space. Install and open it '
            'normally (not cloned), or join the network by hand.';
      case WifiJoinReason.oemRestriction:
        return 'The phone\'s own security software refused the request, not '
            'Android itself. On MIUI/HyperOS this is usually the per-app '
            '"connect to nearby devices" or "Wi-Fi control" switch in the '
            'Security app. Joining the network by hand always works.';
      case WifiJoinReason.otherPermission:
        return 'Android refused for a permission this app has no specific advice '
            'for. The platform said: ${detail ?? "nothing"}. Joining the network '
            'by hand always works.';
      case WifiJoinReason.notPermission:
        return 'The join failed for a reason unrelated to permissions'
            '${detail == null ? "." : ": $detail"}';
      case WifiJoinReason.unknown:
        break;
    }
    return switch (outcome) {
      WifiJoinOutcome.granted => 'Joined.',
      WifiJoinOutcome.suggested =>
        'Android saved the camera\'s network. Accept the notification if it '
            'appears, and the phone will join it.',
      WifiJoinOutcome.dismissed => 'The join prompt was dismissed or the network '
          'could not be brought up.',
      WifiJoinOutcome.timeout => 'Android did not finish joining in time.',
      WifiJoinOutcome.unsupported =>
        'This Android version cannot join a network for an app, so the Wi-Fi '
            'screen was opened.',
      WifiJoinOutcome.permissionDenied =>
        'Android refused the join for a permission reason it did not name.',
      WifiJoinOutcome.failed =>
        'Could not join the camera\'s network'
            '${detail == null ? "." : ": $detail"}',
    };
  }

  @override
  String toString() =>
      'WifiJoinResult(${outcome.name}${detail == null ? '' : ': $detail'}'
      '${reason == WifiJoinReason.unknown ? '' : ' [${reason.name}]'})';
}

/// What came of asking the platform to give up the camera's association.
///
/// Not a bool, for the reason [WifiJoinOutcome] is not one: the situations are
/// genuinely different and collapsing them loses the only thing the user can act
/// on — *which* of them happened. `notOnNetwork` is a success (nothing to leave);
/// `refused` is the one that means the phone is still on the AP and the camera's
/// single client slot is still taken.
class AssociationRelease {
  final bool released;

  /// A short token naming the mechanism that produced this answer, or why none
  /// could be used. Diagnostic, and deliberately not prose: the sentence the user
  /// reads is built by the caller, which is the layer that knows whether a camera
  /// radio was also involved.
  final String reason;

  /// True when the platform reported that the phone is still associated
  /// afterwards — i.e. this is the failure the whole capability exists to avoid.
  final bool stillAssociated;

  const AssociationRelease(this.released, this.reason,
      {this.stillAssociated = false});

  /// The phone is not on the camera's network, and was not when this ran.
  static const AssociationRelease notOnNetwork =
      AssociationRelease(true, 'not on the camera network');

  /// The app's claim was withdrawn and the platform told us the network is gone.
  static const AssociationRelease requestReleased =
      AssociationRelease(true, 'the app released its network request');

  /// The user joined by hand, so there was no app request to release; the
  /// platform was asked to disconnect instead.
  static const AssociationRelease disconnected =
      AssociationRelease(true, 'disconnected from the camera AP');

  /// Nothing could be done on this platform or release.
  static const AssociationRelease notApplicable =
      AssociationRelease(true, 'no programmatic release on this platform');

  /// The platform was asked and the phone is still on the AP.
  static const AssociationRelease refused =
      AssociationRelease(false, 'the platform refused', stillAssociated: true);

  @override
  String toString() =>
      'AssociationRelease(released: $released, $reason'
      '${stillAssociated ? ', still associated' : ''})';
}

/// Joins the camera's Wi-Fi network, and controls whether the app's traffic is
/// pinned to it.
abstract class WifiJoinDelegate {
  /// Ask the system to join [ssid].
  Future<WifiJoinResult> requestJoin(String ssid, {String? passphrase});

  /// Open the system Wi-Fi screen, for platforms and releases where the app
  /// cannot join on the user's behalf.
  Future<bool> openSettings();

  /// Pin this process's network traffic to the joined AP.
  ///
  /// Required on Android: a `WifiNetworkSpecifier` network is not used by
  /// default.  Must be paired with [unbind] or the app keeps no internet.
  Future<bool> bind();

  /// Release the binding, restoring normal routing.
  ///
  /// Called on disconnect, on link loss, and when the app leaves the foreground.
  /// Skipping it is how "auto-connect" turns into "auto-disconnect".
  ///
  /// **This is not the same thing as leaving the network.** It releases the
  /// process-wide *pin*; whether the phone is still associated is a separate
  /// question, and answering it is [releaseAssociation]'s job. Conflating the two
  /// is a measured defect: the app's Disconnect button dropped the pin, said
  /// "disconnected", and left the phone holding the camera's single client slot.
  Future<void> unbind();

  /// Give up the camera's association itself, not merely the pin.
  ///
  /// ## Why this is a separate capability rather than part of [unbind]
  ///
  /// A `WifiNetworkSpecifier` network exists **because a process asked for it**,
  /// and it keeps existing until that request is released. `bindProcessToNetwork`
  /// / `null` changes routing; it does not withdraw the request. So an app that
  /// only unbinds stays associated — with no internet, holding the one client
  /// slot the camera's AP admits, which is what the maintainer measured on the
  /// phone (still on `YI_M1_XXXXXX`, still holding `192.168.0.3`).
  ///
  /// ## The two ways the phone can be on that network, and why one call covers both
  ///
  /// * **The app asked for it** (`WifiNetworkSpecifier`, or the suggestion rung).
  ///   Releasing the request lets Android tear the network down.
  /// * **The user joined by hand** — the system's "add network" sheet, the Wi-Fi
  ///   panel, or Settings. Here the platform owns the network and no app request
  ///   exists to release; only `WifiManager.disconnect()` ends the association.
  ///
  /// The delegate does not try to tell the cases apart in the Dart layer: it
  /// cannot see them, and a guess would produce the same defect in a new place.
  /// It attempts *both*, and reports what happened, so a phone that stays on the
  /// network is visible rather than silent.
  ///
  /// Whether the phone is off the camera's network when the call was made —
  /// [AssociationRelease.released] when the platform says it is gone, and
  /// [AssociationRelease.notOnNetwork] when it never was (which is a success: the
  /// stateless outcome the caller wanted is already true). Both name their
  /// **reason**, because "the app cannot do this here" and "the app tried and the
  /// phone stayed on" are different facts and only one of them is the user's to
  /// act on.
  Future<AssociationRelease> releaseAssociation();

  /// Whether traffic is currently pinned to the camera.
  bool get isBound;

  // -------------------------------------------------------------------------
  // Capabilities whose default lives in [WifiJoinFallbacks].
  //
  // Declared abstract here rather than with a body because Dart's `implements`
  // ignores method bodies, so a default on this class would have to be restated
  // by every implementer — the opposite of a default. A bare
  // `implements WifiJoinDelegate` therefore still compiles unchanged.
  // -------------------------------------------------------------------------

  /// Join [ssid], falling back through every mechanism the platform has before
  /// asking the user to do it by hand.
  Future<WifiJoinResult> joinWithFallback(String ssid, {String? passphrase});

  /// Re-check whether the process should now be bound, and bind it if so.
  ///
  /// Needed for the suggestion path: Android associates on its own schedule and
  /// hands back no callback, so the only way to notice is to look.  Returns
  /// whether traffic is pinned to the camera afterwards.
  Future<bool> refreshBinding();

  /// Open this app's own entry in Android settings, where a refused permission
  /// can be granted.
  ///
  /// Distinct from [openSettings], which opens the *Wi-Fi* screen: after a
  /// permission refusal, sending the user to Wi-Fi settings leaves them with no
  /// way to fix the actual problem.
  Future<bool> openPermissionSettings();

  /// Open the Wi-Fi surface itself, for the manual fallback.
  ///
  /// Separate from [openPermissionSettings] because the two failures need
  /// different destinations: a refused permission is fixed in the app's
  /// permission screen, while "the platform will not join this network for me" is
  /// fixed by picking the network by hand. Returns whether the compact system
  /// panel was used rather than the full settings screen.
  Future<bool> openJoinSurface();

  /// Read the platform's Wi-Fi permission state **now**.
  ///
  /// Distinct from the report carried on a [WifiJoinResult], which describes the
  /// moment of that attempt: after the user changes a switch, the old report says
  /// the opposite of the truth.
  Future<WifiPermissionReport> readPermissionReport();
}

/// Default behaviour for the two capabilities that a delegate may not be able to
/// improve on.
///
/// A `mixin` rather than concrete methods on [WifiJoinDelegate] because Dart's
/// `implements` does not inherit method bodies: a default on the abstract class
/// would force every implementer to restate it, which is the opposite of a
/// default.
mixin WifiJoinFallbacks implements WifiJoinDelegate {
  /// Joining twice through the same mechanism would show the user the same
  /// consent dialog twice. Laddering is the platform implementation's job
  /// ([PlatformWifiJoinDelegate.joinWithFallback]); this is the honest default.
  @override
  Future<WifiJoinResult> joinWithFallback(String ssid, {String? passphrase}) =>
      requestJoin(ssid, passphrase: passphrase);

  /// Nothing to re-check when the delegate never joins asynchronously.
  @override
  Future<bool> refreshBinding() async => isBound;

  /// Without a platform permission screen, the Wi-Fi screen is the only
  /// destination there is — it at least lets the user join by hand.
  @override
  Future<bool> openPermissionSettings() => openSettings();

  /// No compact panel exists outside the platform implementation.
  @override
  Future<bool> openJoinSurface() => openSettings();

  @override
  Future<WifiPermissionReport> readPermissionReport() async =>
      const WifiPermissionReport();

  /// A delegate that never joined anything has no association to release, and no
  /// way to ask the platform about one — so this answers the honest thing rather
  /// than pretending to a capability it does not have.
  @override
  Future<AssociationRelease> releaseAssociation() async =>
      AssociationRelease.notApplicable;
}

/// A delegate that does nothing, for tests and for platforms with no Wi-Fi
/// control.  Answering [WifiJoinOutcome.unsupported] lets the caller fall back to
/// instructing the user.
class NoopWifiJoinDelegate with WifiJoinFallbacks implements WifiJoinDelegate {
  @override
  Future<WifiJoinResult> requestJoin(String ssid, {String? passphrase}) async =>
      const WifiJoinResult(WifiJoinOutcome.unsupported);

  @override
  Future<bool> openSettings() async => false;

  @override
  Future<bool> bind() async => false;

  @override
  Future<void> unbind() async {}

  @override
  bool get isBound => false;
}

/// A delegate that supports everything [WifiJoinDelegate] declares, for tests
/// that need to drive the connection state machine through the fallback ladder
/// without a device.
///
/// Answers are scripted, so a test can assert what the state machine does with
/// each outcome — which matters because the whole point of the ladder is that
/// different rungs need different user-facing behaviour.
class ScriptedWifiJoinDelegate with WifiJoinFallbacks implements WifiJoinDelegate {
  /// Consumed in order by [requestJoin]. The last entry repeats once exhausted.
  final List<WifiJoinResult> script;

  /// SSIDs passed to [requestJoin], in order.
  final List<String> joinAttempts = [];

  /// SSIDs passed to [joinWithFallback], in order.
  final List<String> ladderAttempts = [];

  int bindCount = 0;
  int unbindCount = 0;
  int refreshCount = 0;
  bool _bound = false;
  bool bindSucceeds;

  ScriptedWifiJoinDelegate(
    this.script, {
    this.bindSucceeds = true,
  });

  int _index = 0;

  @override
  Future<WifiJoinResult> requestJoin(String ssid, {String? passphrase}) async {
    joinAttempts.add(ssid);
    final r = script[_index < script.length ? _index : script.length - 1];
    _index++;
    if (r.outcome == WifiJoinOutcome.granted) _bound = true;
    return r;
  }

  /// Records the ladder call and then answers from the same script, so a test can
  /// exercise the state machine's handling of a given outcome either way.
  @override
  Future<WifiJoinResult> joinWithFallback(String ssid, {String? passphrase}) {
    ladderAttempts.add(ssid);
    return requestJoin(ssid, passphrase: passphrase);
  }

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<bool> openPermissionSettings() async => true;

  @override
  Future<bool> openJoinSurface() async => true;

  /// Whatever the test set, so a scripted run can assert the diagnostics sheet
  /// renders the platform's answer rather than a guess.
  WifiPermissionReport report = const WifiPermissionReport();

  @override
  Future<WifiPermissionReport> readPermissionReport() async => report;

  @override
  Future<bool> bind() async {
    bindCount++;
    _bound = bindSucceeds;
    return _bound;
  }

  @override
  Future<void> unbind() async {
    unbindCount++;
    _bound = false;
  }

  /// Releases recorded, so a check can assert the disconnect path asks for the
  /// association to go rather than only dropping the pin.
  int releaseCount = 0;

  /// What the next [releaseAssociation] answers. Defaults to the success the
  /// caller wants, so a check that is not about the refusal does not have to say
  /// anything; a check that *is* about it sets this.
  AssociationRelease releaseAnswer = AssociationRelease.requestReleased;

  @override
  Future<AssociationRelease> releaseAssociation() async {
    releaseCount++;
    if (releaseAnswer.released) _bound = false;
    return releaseAnswer;
  }

  @override
  Future<bool> refreshBinding() async {
    refreshCount++;
    return _bound;
  }

  @override
  bool get isBound => _bound;
}

/// The camera's access point is always named `YI_M1_<suffix>`.
bool looksLikeCameraAp(String ssid) => ssid.toUpperCase().startsWith('YI_M1_');
