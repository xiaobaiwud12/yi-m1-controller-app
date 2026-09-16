/// Camera connection state machine: BLE pairing, Wi-Fi credentials, HTTP, and
/// the live-view stream.
///
/// ## Why the pairing values are persisted
///
/// The camera stores **exactly one pairing at a time**.  Pairing is driven by a
/// `refId` — a random identifier in `0..99998` generated fresh for each pairing
/// attempt — and the camera answers with a `token`.  The session payload is then
/// `"<protocol>,<refId>,<crc32(\"1\" + refId + token)>"`.
///
/// Verified on hardware: re-using a stored `(refId, token)` opens a session
/// **without touching the camera**, so reconnection never needs the user to press
/// "allow" again.  Losing either value forces a fresh pairing and silently kicks
/// the official app off the camera, so both are stored.
///
/// ## Verified end-to-end
///
/// The whole sequence below has been exercised against real hardware:
/// firmware info read, pairing, session, Wi-Fi on, credential read, HTTP reachable
/// at `192.168.0.10`, live view at ~30 fps.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../protocol/wire_format.dart';
import 'http_transport.dart';
import 'liveview.dart';
import 'wifi_join_contract.dart';

/// Where the session lives.  A concrete implementation is supplied by the app so
/// this file stays free of plugin dependencies and testable in the plain VM.
abstract class PairingStore {
  Future<Map<String, String>> load();
  Future<void> save(Map<String, String> values);
}

/// A no-op store, for tests and for a first run.
class MemoryPairingStore implements PairingStore {
  Map<String, String> _v;
  MemoryPairingStore([Map<String, String>? initial]) : _v = initial ?? {};

  @override
  Future<Map<String, String>> load() async => Map.of(_v);

  @override
  Future<void> save(Map<String, String> values) async => _v = Map.of(values);
}

/// Persisted per-camera state.
class PairingRecord {
  final String? refId;
  final String? token;
  final int protocolVersion;
  final String? ssid;
  final String? passkey;
  final String? deviceAddress;

  const PairingRecord({
    this.refId,
    this.token,
    this.protocolVersion = 1,
    this.ssid,
    this.passkey,
    this.deviceAddress,
  });

  bool get canReuseSession =>
      refId != null && refId!.isNotEmpty && token != null && token!.isNotEmpty;

  /// Whether there is a stored `(refId, token)` pair to authenticate a BLE write
  /// with — the gate the radio switch-off turns on.
  ///
  /// A name of its own rather than [canReuseSession] at the call site: the same
  /// fact, but "there is a pairing to use" is what the gate means, and the camera
  /// holds exactly one pairing, which a newer client silently replaces.
  bool get hasPairing => canReuseSession;

  bool get hasWifiCredentials =>
      ssid != null && ssid!.isNotEmpty && passkey != null && passkey!.isNotEmpty;

  factory PairingRecord.fromMap(Map<String, String> m) => PairingRecord(
        refId: m['refId'],
        token: m['token'],
        protocolVersion: int.tryParse(m['protocol'] ?? '') ?? 1,
        ssid: m['ssid'],
        passkey: m['passkey'],
        deviceAddress: m['deviceAddress'],
      );

  Map<String, String> toMap() => {
        if (refId != null) 'refId': refId!,
        if (token != null) 'token': token!,
        'protocol': '$protocolVersion',
        if (ssid != null) 'ssid': ssid!,
        if (passkey != null) 'passkey': passkey!,
        if (deviceAddress != null) 'deviceAddress': deviceAddress!,
      };

  PairingRecord copyWith({
    String? refId,
    String? token,
    int? protocolVersion,
    String? ssid,
    String? passkey,
    String? deviceAddress,
  }) =>
      PairingRecord(
        refId: refId ?? this.refId,
        token: token ?? this.token,
        protocolVersion: protocolVersion ?? this.protocolVersion,
        ssid: ssid ?? this.ssid,
        passkey: passkey ?? this.passkey,
        deviceAddress: deviceAddress ?? this.deviceAddress,
      );

  /// The same record with the session identity dropped, everything else kept.
  ///
  /// `copyWith` cannot express "forget this field" — passing `null` means "keep" —
  /// and a *half*-forgotten pair is worse than none: a `refId` with a token that no
  /// longer matches it makes [canReuseSession] true, so every later attempt takes
  /// the reuse branch and fails, and pairing is never tried again.
  PairingRecord get withoutSession => PairingRecord(
        protocolVersion: protocolVersion,
        ssid: ssid,
        passkey: passkey,
        deviceAddress: deviceAddress,
      );
}

/// What the connection manager is doing right now.  The UI renders this
/// directly, so every state carries enough detail to explain itself.
enum LinkStage {
  idle,
  scanning,
  connecting,
  readingIdentity,
  pairing,
  awaitingUserConfirm,
  startingSession,
  enablingWifi,
  readingCredentials,
  waitingForWifi,
  ready,
  failed,

  /// The link was up and has been lost.
  ///
  /// Distinct from [failed]: a failure happened while establishing, a loss
  /// happened after.  The UI's job differs — one offers a retry of the whole
  /// sequence, the other offers to reconnect and warns that the camera may have
  /// been switched off.
  lost,
}

/// Every message code this file can attach to a [LinkStatus].
///
/// ## Why codes rather than prose in the UI
///
/// `AGENTS.md` §4.1 keeps this file free of `package:flutter`, so it cannot call
/// `AppLocalizations`. The alternative — moving these sentences up into the UI —
/// would move them away from the code that *decides* them: `linkCameraNotAnswering`
/// names the host, the SSID and the passkey, and it is written where those three
/// values are in hand, not where a sentence is drawn.
///
/// So the sentence stays here as the **fallback** (and as what
/// `LinkStatus.toString()` prints in a log or a failed assertion), and a code plus
/// its parameters travel alongside it. The UI resolves the code through
/// `lib/l10n/message_text.dart` and falls back to the English when it does not know
/// the code. The information is never degraded: the parameters are the same values
/// the sentence interpolates, and a code the UI has not been taught still renders a
/// complete, correct English sentence rather than nothing.
///
/// [kLinkCodes] is what makes the pairing checkable: `test/l10n_message_codes_test.dart`
/// asserts it equals the set of codes the resolver handles.
abstract final class LinkCodes {
  static const scanning = 'linkScanning';
  static const notFound = 'linkNotFound';
  static const connecting = 'linkConnecting';
  static const readingIdentity = 'linkReadingIdentity';
  static const unreadableIdentity = 'linkUnreadableIdentity';
  static const found = 'linkFound';
  static const reusingPairing = 'linkReusingPairing';
  static const savedPairingRejected = 'linkSavedPairingRejected';
  static const pressAllow = 'linkPressAllow';
  static const pairingNotConfirmed = 'linkPairingNotConfirmed';
  static const openingSession = 'linkOpeningSession';
  static const enablingWifi = 'linkEnablingWifi';
  static const readingCredentials = 'linkReadingCredentials';
  static const pairingForgotten = 'linkPairingForgotten';
  static const noCredentials = 'linkNoCredentials';
  static const askingAndroidToJoin = 'linkAskingAndroidToJoin';
  static const joined = 'linkJoined';
  static const joinedUnbound = 'linkJoinedUnbound';
  static const savedNetworkInstead = 'linkSavedNetworkInstead';
  static const joinDismissed = 'linkJoinDismissed';
  static const joinTimedOut = 'linkJoinTimedOut';
  static const joinUnsupported = 'linkJoinUnsupported';
  static const joinManual = 'linkJoinManual';
  static const waitingForCamera = 'linkWaitingForCamera';
  static const cameraNotAnswering = 'linkCameraNotAnswering';
  static const connected = 'linkConnected';
  static const previewRunning = 'linkPreviewRunning';
  static const previewStopped = 'linkPreviewStopped';
  static const disconnected = 'linkDisconnected';
  static const idle = 'linkIdle';

  /// The link was up and has gone away.
  ///
  /// The sentence is composed by the *caller* (`AppState._emitLost`) because only the
  /// app layer knows what it was in the middle of when the camera stopped answering —
  /// hence [CameraConnection.reportLost]'s `code` parameter rather than a code chosen
  /// here.
  static const lostContact = 'linkLostContact';

  /// Disconnect left the camera's access point on, with the reason as its own code.
  ///
  /// ## Why a clean disconnect needs no code of its own
  ///
  /// [disconnected] already means it, and [LinkCodes] is compared against the
  /// resolver key by key (`test/l10n_message_codes_test.dart`): a second constant
  /// for the same ARB key would be a code nobody can render differently. The clean
  /// outcome is still reported — as [DisconnectOutcome], and as this cluster's
  /// absence.
  ///
  /// ## Why four codes rather than one with a `{reason}` placeholder
  ///
  /// Measured, not assumed. The one-code-with-a-parameter version was written
  /// first and rendered, and on a Chinese phone it produced:
  ///
  /// ```
  /// 已断开，但相机的 Wi-Fi 还开着 —— the camera holds no pairing for this phone。
  /// ```
  ///
  /// The placeholder had been filled with the transport's **English** clause, so
  /// the half of the sentence that carries the actual diagnosis was in the wrong
  /// language — the same defect as `not connected` on a Chinese phone, which is
  /// why the code mechanism exists at all. A parameter whose value is a sentence
  /// cannot be translated, so the reason is part of the *key* instead, and each
  /// reason gets a whole sentence a translator can write.
  ///
  /// ## And why the *unclean* outcome must be said out loud
  ///
  /// The whole round this comes from is "the button did not do what it said".
  /// Leaving the radio on is a real, visible cost to the user (the camera's AP
  /// admits one client, so nothing else can connect) and it is not always the
  /// app's choice: the BLE route needs a pairing the camera still holds, and the
  /// camera keeps exactly one. So the app says which of those happened instead of
  /// reporting a clean disconnect it did not achieve.
  static const disconnectedNoPairing = 'linkDisconnectedNoPairing';

  /// Same, when the camera was asked and did not take the write.
  static const disconnectedRadioRefused = 'linkDisconnectedRadioRefused';

  /// Same, when the Bluetooth link carrying the command was already gone.
  static const disconnectedNoBle = 'linkDisconnectedNoBle';

  /// Every code above, for the check that compares this file against the resolver
  /// in `lib/l10n/message_text.dart`. A code with no resolver case renders the
  /// English fallback — correct, and invisible — so it is asserted instead.
  static const Set<String> all = {
    scanning,
    notFound,
    connecting,
    readingIdentity,
    unreadableIdentity,
    found,
    reusingPairing,
    savedPairingRejected,
    pressAllow,
    pairingNotConfirmed,
    openingSession,
    enablingWifi,
    readingCredentials,
    pairingForgotten,
    noCredentials,
    askingAndroidToJoin,
    joined,
    joinedUnbound,
    savedNetworkInstead,
    joinDismissed,
    joinTimedOut,
    joinUnsupported,
    joinManual,
    waitingForCamera,
    cameraNotAnswering,
    connected,
    previewRunning,
    previewStopped,
    disconnected,
    disconnectedNoPairing,
    disconnectedRadioRefused,
    disconnectedNoBle,
    lostContact,
    idle,
  };
}

/// Why the camera's radio was, or was not, switched off on the way out.
///
/// A value rather than prose so the caller can decide how loudly to say it — and
/// so a check can assert the *decision* rather than a sentence.
enum RadioSwitchOutcome {
  /// `WIFI_TOGGLE = "OFF"` was written and the transport accepted it.
  switchedOff,

  /// The camera holds no pairing this app can use, so the BLE write had nothing
  /// to authenticate with. **The pairing is what gates this**, not the app's
  /// willingness: the session payload is `crc32("1" + refId + token)` and the
  /// camera stores exactly one pairing, which a newer client silently replaces.
  noPairing,

  /// A pairing existed; the write did not reach the camera or was refused.
  writeFailed,

  /// The link was already gone, so there was no channel to carry the write.
  ///
  /// Worth its own case: on this camera that is the *normal* state while its
  /// network stack is wedged, and it is exactly the state the reference client
  /// recovered from over BLE — so it is a fact to report, not an error.
  noBleLink,
}

/// What a discrete [CameraConnection.disconnect] did.
///
/// Returned rather than logged because two of its three facts are user-visible:
/// the association release is the defect this round is about, and the radio
/// outcome is the reason the camera may still be advertising.
class DisconnectOutcome {
  final AssociationRelease association;

  /// Why the radio ended up as it did, or **null** when nothing asked it to change.
  ///
  /// Null is a real case and not a default: [CameraConnection.dispose] tears the
  /// link down without touching the camera's radio, because a BLE write during
  /// plugin teardown is a race rather than an action. Reporting that as "left on"
  /// would be the same class of lie this round is about.
  final RadioSwitchOutcome? radio;

  const DisconnectOutcome(this.association, this.radio);

  /// Whether the phone is off the camera's network, as far as the platform said.
  bool get leftNetwork => association.released;

  /// Whether the camera's radio was switched off over BLE.
  bool get radioOff => radio == RadioSwitchOutcome.switchedOff;

  /// The English sentence the user reads, with the reason spelled out.
  ///
  /// The same string is the ARB's `linkDisconnectedNoPairing` &c. — the anti-drift
  /// check in `test/l10n_message_codes_test.dart` compares the two word for word,
  /// so a reword has to happen in both places deliberately. It is also the first
  /// sentence to be written the other way round (four codes, one parameterised
  /// sentence) and to be **measured** rendering English in the middle of a Chinese
  /// one; see [LinkCodes.disconnectedNoPairing].
  String get message => switch (radio) {
        null || RadioSwitchOutcome.switchedOff => 'disconnected',
        RadioSwitchOutcome.noPairing =>
          'Disconnected, but the camera\'s Wi-Fi is still on — the camera no '
              'longer holds this phone\'s pairing, so the app has no authenticated '
              'channel to switch it with. Press the camera\'s power switch, or '
              'reconnect and disconnect again, to stop it advertising.',
        RadioSwitchOutcome.writeFailed =>
          'Disconnected, but the camera\'s Wi-Fi is still on — the camera did not '
              'acknowledge the switch-off command. Press the camera\'s power '
              'switch, or reconnect and disconnect again, to stop it advertising.',
        RadioSwitchOutcome.noBleLink =>
          'Disconnected, but the camera\'s Wi-Fi is still on — the Bluetooth link '
              'to the camera was already gone, so the switch-off command had no '
              'way to reach it. Press the camera\'s power switch, or reconnect and '
              'disconnect again, to stop it advertising.',
      };

  /// The status code for the sentence the user reads.
  ///
  /// Only the unclean outcome gets a code of its own; a disconnect that did what
  /// it promised is [LinkCodes.disconnected]. Each unclean code names its own
  /// *reason*, so a translation is a whole sentence rather than a template with an
  /// English clause dropped into it.
  String get code => switch (radio) {
        null || RadioSwitchOutcome.switchedOff => LinkCodes.disconnected,
        RadioSwitchOutcome.noPairing => LinkCodes.disconnectedNoPairing,
        RadioSwitchOutcome.writeFailed => LinkCodes.disconnectedRadioRefused,
        RadioSwitchOutcome.noBleLink => LinkCodes.disconnectedNoBle,
      };

  @override
  String toString() =>
      'DisconnectOutcome($association, radio: ${radio?.name ?? 'not attempted'})';
}

/// Immutable snapshot of the connection.
class LinkStatus {
  final LinkStage stage;

  /// The sentence, in English — what a log, a failed assertion and the pre-localization
  /// UI all print. See [LinkCodes] for why the English is still here.
  final String message;

  /// Which sentence [message] is, or null when this status was built without one
  /// (the `reportLost` path forwards a message a caller composed).
  final String? messageCode;

  /// The values [message] interpolates, so a translation can place them itself
  /// rather than reusing English word order.
  final Map<String, Object?> messageParams;

  final CameraIdentity? identity;
  final bool wifiUp;
  final bool previewRunning;
  final int previewFps;

  const LinkStatus({
    required this.stage,
    required this.message,
    this.messageCode,
    this.messageParams = const {},
    this.identity,
    this.wifiUp = false,
    this.previewRunning = false,
    this.previewFps = 0,
  });

  bool get isReady => stage == LinkStage.ready;
  bool get isBusy =>
      stage != LinkStage.idle &&
      stage != LinkStage.ready &&
      stage != LinkStage.failed &&
      stage != LinkStage.lost;

  /// True when the link was up and has dropped.
  bool get isLost => stage == LinkStage.lost;

  @override
  String toString() => 'LinkStatus($stage: $message)';
}

/// A BLE transport, abstracted so the state machine can be tested offline.
///
/// The real implementation wraps `flutter_blue_plus`; tests supply a scripted
/// one.  The camera's BLE surface is tiny — six writes and three reads — so this
/// interface stays small on purpose.
abstract class BleTransport {
  /// Scan for the camera and return its platform device id, or null.
  Future<String?> findCamera();

  Future<void> connect(String deviceId);
  Future<void> disconnect();
  bool get isConnected;

  Future<List<int>> readFirmwareInfo();
  Future<List<int>> readMisc();
  Future<List<int>> readWifiCredentials();

  /// Write a command to a characteristic.
  ///
  /// The *write type* is not a parameter here on purpose: whether the camera
  /// accepts an acknowledged or unacknowledged write is a property of the
  /// characteristic, differs between platforms, and the transport is the only
  /// layer that can see it. Callers name the logical characteristic and let the
  /// transport negotiate.
  Future<void> write(Uint8List data, String characteristic);

  /// Subscribe to the pairing-result characteristic.  Must be called **before**
  /// the pairing write, as the official app does.
  Future<void> subscribePairing(void Function(List<int>) onData);

  /// Human-readable diagnostics, newest last. Empty for transports that keep no
  /// log.
  List<String> get log => const [];
}

/// Characteristic short names, so the interface stays readable.
class BleChar {
  static const pairing = 'pair';
  static const session = 'session';
  static const wifi = 'wifi';
  static const timeSync = 'time';
  static const mode = 'mode';
}

/// Drives the whole connect sequence and owns the resulting transports.
class CameraConnection {
  static const String defaultHost = CameraHttpClient.defaultHost;

  final BleTransport ble;
  final PairingStore store;
  final String host;

  /// Timeout for control commands.
  ///
  /// Generous on purpose.  The camera serves everything from one tiny HTTP
  /// server over its own 802.11n access point, and while the live-view stream is
  /// running that link is already busy — a 5-second timeout produces spurious
  /// failures on a camera that is merely slow.  Verified: a full-resolution photo is
  /// ~9 MB, and the stream is **not** cheap — measured at ~52-57 KB per datagram at
  /// ~30/s, about **12-14 Mbit/s** (`analysis/50` §3).  An earlier version of this
  /// comment said 4.2 Mbit/s, from a 40-frame sample of a plain scene; the two are
  /// comparable rather than the stream being negligible, which is the case that makes
  /// the generous timeout necessary.
  final Duration commandTimeout;

  /// Timeout for album transfers, which move megabytes rather than bytes.
  final Duration transferTimeout;

  /// Joins the camera's Wi-Fi on the user's behalf where the platform allows it.
  ///`n  /// Injected so this file needs no Flutter dependency and can be exercised
  /// offline; the platform implementation lives in `wifi_joiner.dart`.
  final WifiJoinDelegate wifiJoin;

  final CameraLiveView liveView;
  CameraHttpClient? _http;
  PairingRecord _record = const PairingRecord();

  final _status = StreamController<LinkStatus>.broadcast();

  /// The status before anything has happened — the one the shooting page draws on
  /// launch, before anybody has pressed Connect.
  ///
  /// **The code is not decoration.** This is a `const` value rather than an [_emit]
  /// call, so it is the one status that does not pass through the helper that carries
  /// codes — and it is on screen for the whole first screenful of the app. It shipped
  /// without one, and the maintainer found `not connected` in lowercase English on a
  /// Chinese phone while the app bar's own chip, which goes through a different path,
  /// correctly read 未连接. `linkIdle` was already in the ARB and already in
  /// [LinkCodes]; nothing was reaching for it.
  LinkStatus _current = const LinkStatus(
      stage: LinkStage.idle,
      message: 'not connected',
      messageCode: LinkCodes.idle);

  /// Status updates, for the UI.
  Stream<LinkStatus> get status => _status.stream;
  LinkStatus get current => _current;

  /// The HTTP client, once [connect] has reached [LinkStage.ready].
  CameraHttpClient get http {
    final c = _http;
    if (c == null) {
      throw StateError('HTTP is not available until the connection is ready');
    }
    return c;
  }

  bool get isReady => _current.isReady;

  /// Whether the camera may still be reachable, so a probe is worth making.
  ///
  /// Distinct from [isReady], and the distinction is load-bearing: a **lost** link
  /// is not a ready one, but it is not a hopeless one either — the camera may have
  /// finished rebooting, or the phone may have rejoined its access point. Every
  /// caller that used `isReady` as "may I probe?" therefore refused to probe the one
  /// state probing exists to recover from. Combined with [clearLost]'s own guard
  /// that made a loss **permanent**: the only call that could clear it required the
  /// status it had already left.
  bool get canProbe => isReady || _current.stage == LinkStage.lost;

  PairingRecord get record => _record;

  CameraConnection({
    required this.ble,
    required this.store,
    CameraLiveView? liveView,
    this.host = defaultHost,
    this.commandTimeout = const Duration(seconds: 20),
    this.transferTimeout = const Duration(seconds: 90),
    WifiJoinDelegate? wifiJoin,
    // Test-only. Deliberately not annotated `@visibleForTesting`: that would pull
    // `package:meta` into this file, and the whole `transport` / `sync` /
    // `protocol` chain is kept free of outside packages so `tool/verify_*.dart`
    // can drive it in the plain Dart VM.
    CameraHttpClient? testHttp,
    CameraIdentity? testIdentity,
    // Test-only, and the same documented seam as the two above.  A preview can
    // only be running if a UDP socket was bound, and a real socket completion
    // never arrives inside a widget test's fake clock — so a test that wants the
    // "already previewing" state cannot reach it by pressing anything, and one
    // that tries hangs instead of failing.  Defaults to false, so nothing about
    // production behaviour changes.
    bool testPreviewRunning = false,
  })  : wifiJoin = wifiJoin ?? NoopWifiJoinDelegate(),
        liveView = liveView ?? CameraLiveView() {
    // Put the connection straight into its ready state, skipping BLE and Wi-Fi.
    //
    // ## Why this seam exists
    //
    // Every screen the user has actually complained about — the two side bands,
    // the shutter bar, the camera readout, the paused-preview banner — only exists
    // while `isReady`, and reaching that state needs a paired camera. An Android
    // emulator **has no Bluetooth adapter**, so the very first step of the real
    // sequence cannot run there, and a widget test has no radio at all. The result
    // was that the most-reported screens were the least tested: the landscape band
    // layout was verified by reading the layout maths, and the banner's close
    // button was verified by reading the widget.
    //
    // Injecting the client and the identity is enough to render all of it, and it
    // keeps the fabrication here — in one documented constructor argument — rather
    // than spread through the page as `if (test)` branches.
    if (testHttp != null) {
      _http = testHttp;
      _current = LinkStatus(
        stage: LinkStage.ready,
        message: testPreviewRunning ? 'preview running' : 'connected',
        messageCode: testPreviewRunning
            ? LinkCodes.previewRunning
            : LinkCodes.connected,
        identity: testIdentity,
        wifiUp: true,
        previewRunning: testPreviewRunning,
      );
    }
  }

  void _emit(LinkStage stage, String message,
      {String? code,
      Map<String, Object?> params = const {},
      CameraIdentity? identity,
      bool? wifiUp,
      bool? previewRunning,
      int? fps}) {
    _current = LinkStatus(
      stage: stage,
      message: message,
      messageCode: code,
      messageParams: params,
      identity: identity ?? _current.identity,
      wifiUp: wifiUp ?? _current.wifiUp,
      previewRunning: previewRunning ?? _current.previewRunning,
      previewFps: fps ?? _current.previewFps,
    );
    if (!_status.isClosed) _status.add(_current);
  }

  /// Run the whole sequence.
  ///
  /// [onPairingRequested] is called when the camera needs a human to press
  /// "allow" — the UI should surface that prominently, because the request times
  /// out in a few seconds.
  Future<bool> connect({
    void Function()? onPairingRequested,
    Duration pairWait = const Duration(seconds: 25),
  }) async {
    try {
      _record = PairingRecord.fromMap(await store.load());

      // --- find and attach
      _emit(LinkStage.scanning, 'looking for the camera...',
          code: LinkCodes.scanning);
      final id = await ble.findCamera();
      if (id == null) {
        _emit(LinkStage.failed,
            'camera not found. Is it powered on, and not already held by the '
            'official app?',
            code: LinkCodes.notFound);
        return false;
      }
      _emit(LinkStage.connecting, 'connecting...', code: LinkCodes.connecting);
      await ble.connect(id);

      // --- identity (also serves as the readiness test: a bare BLE connect can
      // report success and drop moments later, and reading is what proves the
      // link actually works)
      _emit(LinkStage.readingIdentity, 'reading camera identity...',
          code: LinkCodes.readingIdentity);
      final raw = await ble.readFirmwareInfo();
      final identity = parseFirmwareInfo(raw);
      if (identity == null) {
        _emit(LinkStage.failed, 'camera answered with an unreadable identity',
            code: LinkCodes.unreadableIdentity);
        return false;
      }
      final proto = identity.protocolVersion == 0 ? 1 : identity.protocolVersion;
      _record = _record.copyWith(protocolVersion: proto, deviceAddress: id);
      _emit(LinkStage.readingIdentity,
          'found ${identity.firmwareVersion.trim()} (${identity.regionMarker})',
          code: LinkCodes.found,
          params: {
            'firmware': identity.firmwareVersion.trim(),
            'region': identity.regionMarker,
          },
          identity: identity);

      // --- subscribe BEFORE the pairing write, as the official app does
      String? token;
      final tokenCompleter = Completer<String?>();
      await ble.subscribePairing((data) {
        if (!tokenCompleter.isCompleted) {
          tokenCompleter.complete(parsePairingResult(data));
        }
      });

      var refId = _record.refId;
      var reused = false;

      // --- try the stored session first; this never disturbs the camera
      if (_record.canReuseSession) {
        _emit(LinkStage.startingSession,
            'reusing the saved pairing (refId ${_record.refId})...',
            code: LinkCodes.reusingPairing,
            params: {'refId': '${_record.refId}'});
        try {
          await ble.write(
            utf8.encode(buildSessionRequest(
              protocolVersion: proto,
              key: int.parse(_record.refId!),
              token: _record.token!,
            )),
            BleChar.session,
          );
          reused = true;
        } on Object catch (e) {
          _emit(LinkStage.startingSession,
              'saved pairing did not take ($e); pairing fresh',
              code: LinkCodes.savedPairingRejected,
              params: {'detail': '$e'});
          reused = false;
        }
      }

      // --- otherwise pair, which needs a human
      if (!reused) {
        refId = '${generatePairingKey()}';
        _emit(LinkStage.awaitingUserConfirm,
            'PRESS ALLOW ON THE CAMERA now (refId $refId)',
            code: LinkCodes.pressAllow,
            params: {'refId': refId});
        onPairingRequested?.call();

        await ble.write(
          utf8.encode(buildPairingRequest(
            protocolVersion: proto,
            key: int.parse(refId),
          )),
          BleChar.pairing,
        );

        token = await tokenCompleter.future.timeout(pairWait,
            onTimeout: () => null);
        if (token == null) {
          _emit(LinkStage.failed,
              'the camera did not confirm the pairing. It must be accepted on '
              'the camera screen within a few seconds.',
              code: LinkCodes.pairingNotConfirmed);
          return false;
        }

        _emit(LinkStage.startingSession, 'opening the session...',
            code: LinkCodes.openingSession);
        await ble.write(
          utf8.encode(buildSessionRequest(
            protocolVersion: proto,
            key: int.parse(refId),
            token: token,
          )),
          BleChar.session,
        );
      }

      // The token that belongs to `refId` wins, and on the fresh-pair path that is
      // the one just issued.  An earlier revision preferred the *stored* token
      // whenever one existed, which paired a newly generated `refId` with the old
      // token: the checksum then never matches again, so the stored record stays
      // reusable but can never open a session, and the app reuses it forever.
      _record = _record.copyWith(
          refId: refId, token: token ?? _record.token, protocolVersion: proto);
      await store.save(_record.toMap());

      // --- ALWAYS switch the camera's access point on.
      //
      // The camera does not persist its Wi-Fi state across a power cycle, and the
      // app cannot tell a freshly-woken camera from one that is already
      // broadcasting.  An earlier revision only sent `ON` when no credentials had
      // been stored yet, which broke exactly the common case: the camera is
      // switched off and back on, the app still holds the credentials from last
      // time, so it skipped the `ON`, found no network to join, and looked like
      // reconnecting did nothing at all.
      //
      // `ON` is idempotent, so sending it unconditionally is both correct and the
      // only version that works.
      _emit(LinkStage.enablingWifi, 'switching the camera Wi-Fi on...',
          code: LinkCodes.enablingWifi);
      await ble.write(utf8.encode('ON'), BleChar.wifi);

      // Read the credentials on every connect rather than trusting the stored pair.
      //
      // **Corrected 2026-09-16, by the maintainer's observation:** this comment used to
      // say the passkey is regenerated on every power cycle. **It is not.** The passkey
      // changes when the camera is **re-paired** — and only then — which the maintainer
      // established directly: a power cycle left the stored credentials working, while
      // pairing from another device rotated them.
      //
      // That distinction matters for diagnosis rather than for this code. A stored
      // passkey that no longer works does **not** mean "the camera was switched off"; it
      // means **something else took the pairing**, which is the one thing the camera
      // allows at a time (`AGENTS.md` §5). Tonight I read a stale Windows WLAN profile as
      // a flaky access point for hours because I believed this comment.
      //
      // The behaviour below is right either way — re-reading is harmless and
      // self-correcting, and it is what makes a re-pair heal without the user retyping
      // anything — so only the reason changes.
      _emit(LinkStage.readingCredentials, 'reading Wi-Fi credentials...',
          code: LinkCodes.readingCredentials);
      final ({String ssid, String passkey})? creds = await _readCredentials();
      if (creds == null) {
        if (reused) {
          // The stored pair was written and the camera never opened a session on
          // it — a BLE write is fire-and-forget, so this is the only evidence
          // there is.  Forgetting the pair costs one press of ALLOW on the camera
          // next time; keeping it costs the app entirely: `canReuseSession` stays
          // true, every later attempt takes this same branch, and no retry can
          // ever reach the pairing code again.  `_readCredentials` already retried
          // for ~12 s, so a transient BLE hiccup is not the explanation.
          _record = _record.withoutSession;
          await store.save(_record.toMap());
          _emit(LinkStage.failed,
              'the camera refused the saved pairing, so it has been forgotten; '
              'press Connect again to pair from scratch (the camera will ask for '
              'confirmation).',
              code: LinkCodes.pairingForgotten);
          return false;
        }
        _emit(LinkStage.failed,
            'the camera did not hand over Wi-Fi credentials. The session may not '
            'have been accepted.',
            code: LinkCodes.noCredentials);
        return false;
      }
      _record = _record.copyWith(ssid: creds.ssid, passkey: creds.passkey);
      await store.save(_record.toMap());

      // --- from here the OS must be joined to the camera's AP.  The app asks the
      //     system to do it so the user does not have to find the SSID and retype
      //     an 8-digit passkey.
      //
      //     (This used to end "...that changes on every power cycle" — see the note
      //     above; it changes on re-pairing, not on a power cycle. The reason to join
      //     for the user is unchanged.)
      //
      // Permission preflight lives inside the join delegate: joining a network
      // is the delegate's job and the permission is a precondition of it.
      // Keeping it there also keeps this file free of Flutter, which is what
      // lets tool/verify_sync.dart drive it in the plain Dart VM.
      // The passkey is printed rather than described.  An earlier build told the
      // user it was "on the camera screen", which is simply false — the camera
      // has never displayed it — so the one piece of information needed for the
      // manual fallback was exactly the piece that was missing.
      final cred = '${creds.ssid} / ${creds.passkey}';

      _emit(LinkStage.waitingForWifi, 'asking Android to join "${creds.ssid}"...',
          code: LinkCodes.askingAndroidToJoin, params: {'ssid': creds.ssid});
      final join = await wifiJoin.joinWithFallback(creds.ssid,
          passphrase: creds.passkey);
      // Retained for the diagnostics panel: this is the measurement that makes a
      // screenshot sufficient to identify a refused join.
      _lastPermissions = join.permissions;

      // Say something true.  The outcomes are genuinely different situations and
      // collapsing them into one "go to Settings" message is what made an earlier
      // build look broken when the join had actually worked.
      //
      // The timeout budget is also decided here rather than being fixed, because
      // waiting 75 seconds for a camera we were never joined to is pure waste —
      // and it is what the user experiences as "it just sat there".
      Duration waitBudget = const Duration(seconds: 75);

      switch (join.outcome) {
        case WifiJoinOutcome.granted:
          // Bind the process to the camera's network, or the following requests
          // leave over cellular and never reach 192.168.0.10 — the AP is
          // requested without NET_CAPABILITY_INTERNET on purpose, so the system
          // does not route to it by default.
          final bound = await wifiJoin.bind();
          _emit(
              LinkStage.waitingForWifi,
              bound
                  ? 'joined "${creds.ssid}" — waiting for the camera to answer...'
                  : 'joined "${creds.ssid}" — waiting for the camera...',
              code: bound ? LinkCodes.joined : LinkCodes.joinedUnbound,
              params: {'ssid': creds.ssid});

        case WifiJoinOutcome.suggested:
          // The platform registered the network as a suggestion instead of
          // joining it outright.  It may associate on its own once the user
          // accepts the notification, so this is a "keep waiting", not a failure
          // — and the binding is attempted on every poll tick, because the
          // association can land at any point.
          _emit(
              LinkStage.waitingForWifi,
              'Android saved "${creds.ssid}" as a network instead of joining it. '
              'If a notification appears, allow it — otherwise open Wi-Fi and pick '
              'it. The passkey is already filled in ($cred). Waiting...',
              code: LinkCodes.savedNetworkInstead,
              params: {'ssid': creds.ssid});

        case WifiJoinOutcome.dismissed:
          // The user may have granted the permission we just asked for and then
          // declined the network prompt, in which case "Retry join" is one tap
          // away. A short wait still lets a manual join through system Settings
          // succeed without the user having to press anything.
          waitBudget = const Duration(seconds: 15);
          _emit(
              LinkStage.waitingForWifi,
              'the join prompt was dismissed. Tap "Retry join" to bring it back, '
              'or connect to "${creds.ssid}" yourself with the passkey '
              '$cred.',
              code: LinkCodes.joinDismissed,
              params: {'ssid': creds.ssid, 'credential': cred});

        case WifiJoinOutcome.timeout:
          waitBudget = const Duration(seconds: 15);
          _emit(LinkStage.waitingForWifi,
              'Android did not finish joining "${creds.ssid}" in time.',
              code: LinkCodes.joinTimedOut, params: {'ssid': creds.ssid});

        case WifiJoinOutcome.unsupported:
          // A settings surface was opened, so give the user time to use it.  The
          // app knows the passkey, so there is nothing to read off the camera —
          // the camera has never displayed it.
          waitBudget = const Duration(seconds: 45);
          _emit(
              LinkStage.waitingForWifi,
              'this phone will not let the app join "${creds.ssid}" by itself, so '
              'the Wi-Fi screen was opened. Choose "${creds.ssid}" there — the '
              'passkey is $cred (the camera does not show it).',
              code: LinkCodes.joinUnsupported,
              params: {'ssid': creds.ssid, 'credential': cred});

        case WifiJoinOutcome.permissionDenied:
        case WifiJoinOutcome.failed:
          // Nothing was joined, so waiting is pure loss.  The diagnosis is
          // carried in `join.explanation`, built from what the platform actually
          // said plus the app's own measurement — never from the Android version.
          waitBudget = const Duration(seconds: 5);
          _emit(
              LinkStage.waitingForWifi,
              '${join.explanation} '
              'You can also connect to "${creds.ssid}" by hand with the passkey '
              '$cred. [${join.permissions.summary}]',
              code: LinkCodes.joinManual,
              params: {
                'detail': join.explanation,
                'ssid': creds.ssid,
                'credential': cred,
                // The measured permission summary is an identifier list, not prose:
                // it is passed through and placed verbatim by every translation.
                'permissions': join.permissions.summary,
              });
      }

      _http = CameraHttpClient(host: host, timeout: commandTimeout);
      final reachable = await _waitForHttp(
        budget: waitBudget,
        onTick: (remaining) async {
          // A suggested network is never handed to us by a callback: Android
          // associates on its own schedule, and until the process is bound to it
          // every request here leaves over cellular and times out.  So the
          // binding is re-attempted on each tick — the association can land at
          // any moment, and without this the "keep waiting" branch would wait the
          // full budget for a camera that is already reachable.
          if (join.outcome == WifiJoinOutcome.suggested) {
            await wifiJoin.refreshBinding();
          }
          // Keep the user informed rather than showing a frozen "joining...".
          _emit(LinkStage.waitingForWifi,
              'waiting for the camera to answer (${remaining.inSeconds}s left)...',
              code: LinkCodes.waitingForCamera,
              params: {'seconds': remaining.inSeconds});
        },
      );
      if (!reachable) {
        _emit(LinkStage.failed,
            'the camera is not answering on $host. Check that the phone is on '
            '"${_record.ssid}" — its passkey is ${_record.passkey} — then retry.',
            code: LinkCodes.cameraNotAnswering,
            params: {
              'host': host,
              'ssid': _record.ssid ?? '',
              'passkey': _record.passkey ?? '',
            });
        return false;
      }

      _emit(LinkStage.ready, 'connected',
          code: LinkCodes.connected, wifiUp: true);
      return true;
    } on Object catch (e) {
      // Deliberately *not* coded: `e` is an arbitrary exception whose text comes
      // from the platform, and inventing a translation for a message this app did
      // not write would be a worse lie than showing the original.
      _emit(LinkStage.failed, '$e');
      return false;
    }
  }

  /// Report that an established link has dropped.
  ///
  /// Called by the app layer when a command fails or a liveness probe misses, so
  /// the UI can stop claiming to be connected.  Without this the app keeps
  /// showing a preview that has stopped updating and a shutter that does
  /// nothing, which is exactly the confusing state a user reports as "it just
  /// freezes".
  ///
  /// [message] is the caller's own sentence — only the app layer knows what it was in
  /// the middle of — so [code] is how it stays translatable: the caller names the
  /// sentence, and the UI resolves the name through `lib/l10n/message_text.dart` with
  /// the English as the fallback. Without it this is a status the UI can only draw in
  /// English, which is what it did.
  void reportLost(String message,
      {String? code, Map<String, Object?> params = const {}}) {
    if (_current.stage == LinkStage.lost) return;
    // The camera is gone, so the pin has to go too or the app keeps no internet.
    unawaited(wifiJoin.unbind());
    _emit(LinkStage.lost, message,
        code: code, params: params, previewRunning: false, wifiUp: false);
  }

  /// Report that the link is answering again.
  ///
  /// Restores the process-wide network pin, because [reportLost] released it: on
  /// Android the camera's AP is only reachable while the process is bound to it,
  /// so a link declared "answering again" without the pin is a claim the very next
  /// request disproves.  (Rebinding is safe to repeat — the native side retained
  /// the granted network across the unbind, so this raises no dialog.)
  Future<void> clearLost() async {
    if (_current.stage != LinkStage.lost) return;
    final bound = await wifiJoin.bind();
    if (!bound || _current.stage != LinkStage.lost) return;
    _emit(LinkStage.ready, 'connected', code: LinkCodes.connected, wifiUp: true);
  }

  /// Tell the OS to join the camera's access point, and pin traffic to it.
  ///
  /// The credentials are known by this point, so making the user find the SSID in
  /// Settings and retype an 8-digit passkey is busywork the platform can do. On
  /// Android this raises the system's own one-tap consent dialog; on older
  /// releases it reports [WifiJoinOutcome.unsupported] so the UI can say something
  /// true.
  ///
  /// Returns the outcome.  A `granted` result does **not** mean the camera is
  /// reachable — the caller still waits for HTTP.
  Future<WifiJoinResult> requestWifiJoin(String ssid, String? passkey) =>
      wifiJoin.requestJoin(ssid, passphrase: passkey);

  /// Re-pin the process to the camera's network after returning to the
  /// foreground.
  ///
  /// [WifiJoinDelegate.unbind] is called when the app is backgrounded, because a
  /// process-wide binding means **no internet for the whole app** — a user who
  /// switches away and finds the phone offline would reasonably conclude the
  /// phone is broken. That leaves the binding off on return, so it has to be
  /// restored, or the app comes back to the foreground unable to reach a camera it
  /// is still connected to.
  ///
  /// The native side retains the granted network across an unbind, so this is a
  /// re-pin rather than a fresh join — no dialog.
  Future<bool> rebindCameraNetwork() async {
    // Never bind on the strength of a link that is not up: the camera's AP may be
    // gone, and pinning the process to a dead network is worse than doing nothing.
    if (!_current.wifiUp) return false;
    if (wifiJoin.isBound) return true;
    return wifiJoin.bind();
  }

  /// Release the process-wide network pin without disconnecting.
  ///
  /// Called when the app leaves the foreground. The pin is what makes the camera
  /// reachable, but it also means **no internet for this app**, so holding it
  /// while the user is elsewhere is both pointless and rude. [rebindCameraNetwork]
  /// restores it on return; the granted network is retained natively, so this is
  /// a re-pin and not a fresh join.
  Future<void> releaseCameraNetwork() async {
    if (_current.wifiUp) await wifiJoin.unbind();
  }

  /// Re-ask the system to join, for the "Retry join" affordance.
  ///
  /// Worth having separately: dismissing a consent dialog is a completely normal
  /// thing for a user to do, and the alternative to a retry is making them start
  /// the whole connect sequence again.
  ///
  /// This goes through the **full ladder**, not just the specifier: a user who
  /// taps "Retry join" after being refused wants the app to try everything, and
  /// the rung that failed once will fail identically.
  Future<WifiJoinResult> retryWifiJoin() async {
    final ssid = _record.ssid;
    if (ssid == null || ssid.isEmpty) {
      return const WifiJoinResult(WifiJoinOutcome.failed, 'no SSID known yet');
    }
    final r = await wifiJoin.joinWithFallback(ssid, passphrase: _record.passkey);
    _lastPermissions = r.permissions;
    if (r.outcome == WifiJoinOutcome.granted) await wifiJoin.bind();
    return r;
  }

  /// The platform's permission state as of the last join attempt.
  ///
  /// Retained so the UI can show it without another round trip, and so a
  /// screenshot of the diagnostics panel is enough to identify why a join was
  /// refused.
  WifiPermissionReport get lastPermissions => _lastPermissions;
  WifiPermissionReport _lastPermissions = const WifiPermissionReport();

  /// The camera's access point name, as last read from the camera.
  ///
  /// Exposed because the **passkey is not shown on the camera** — this app is the
  /// only place the user can read it, and without it the manual fallback (pick the
  /// network in system Wi-Fi) is impossible.
  String? get knownSsid => _record.ssid;

  /// The camera's current Wi-Fi passkey, read over Bluetooth.
  ///
  /// Changes on every camera power cycle, so it is re-read on each connect rather
  /// than cached for long.
  String? get knownPasskey => _record.passkey;

  /// Open the place where the refused permission can actually be changed.
  ///
  /// There is one destination for either fix: Android's own app-permission screen
  /// carries both the location and the nearby-devices switches on the releases
  /// that have them. The location master switch lives elsewhere, which is why
  /// [WifiJoinReason.locationServicesOff] gets its own wording rather than this
  /// button alone.
  ///
  /// Delegated rather than done here on purpose: this file must stay free of
  /// `package:flutter`, which is what lets `tool/verify_sync.dart` drive the whole
  /// connection state machine in the plain Dart VM.
  Future<bool> openPermissionSettings() => wifiJoin.openPermissionSettings();

  /// Open the system's Wi-Fi surface, for the manual fallback.
  ///
  /// The compact panel on API 29+; the full settings screen otherwise. Returns
  /// whether the compact panel was the one opened.
  Future<bool> openWifiPanel() => wifiJoin.openJoinSurface();

  /// Re-read the platform's Wi-Fi permission state, measured now.
  ///
  /// [lastPermissions] is the report attached to the last join attempt; this is a
  /// fresh read, for the diagnostics panel — after the user has changed a switch,
  /// the stale report would say the opposite of the truth.
  Future<WifiPermissionReport> readPermissionReport() =>
      wifiJoin.readPermissionReport();

  /// Keep waiting for the camera after an initial miss.
  ///
  /// The camera's AP takes 10–20 seconds to come up and its HTTP server a little
  /// longer, so the first attempt legitimately fails.  Exposed so the UI can
  /// offer "keep trying" without forcing a full re-pair.
  Future<bool> waitForCameraAgain({Duration budget = const Duration(seconds: 60)}) async {
    if (_http == null) return false;
    final ok = await _waitForHttp(
      budget: budget,
      onTick: (remaining) => _emit(LinkStage.waitingForWifi,
          'waiting for the camera to answer (${remaining.inSeconds}s left)...'),
    );
    if (ok) {
      // Re-pin before claiming to be connected. Without this the link is declared
      // ready while the process is still unbound from the camera's network, and on
      // Android an app-scoped specifier network is **not routed by default** — so
      // the app reports success and then every request leaves over cellular. That
      // is precisely the state `clearLost` exists to avoid, and this method used to
      // be the one path that reached "ready" without it.
      await wifiJoin.bind();
      _emit(LinkStage.ready, 'connected', code: LinkCodes.connected, wifiUp: true);
    }
    return ok;
  }

  /// Read the AP credentials, retrying while the radio comes up.
  ///
  /// The characteristic is briefly unreadable immediately after `Wi-Fi ON` —
  /// verified on hardware, where the first read commonly returns nothing and the
  /// second succeeds.
  Future<({String ssid, String passkey})?> _readCredentials() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final creds = parseWifiCredentials(await ble.readWifiCredentials());
        if (creds != null) return creds;
      } on Object {
        // keep trying
      }
    }
    return null;
  }

  /// Poll until the camera's HTTP server answers.
  ///
  /// ## Why this has an explicit budget and a short per-attempt timeout
  ///
  /// The previous version looped 40 times with a one-second pause, which sounds
  /// like 40 seconds but was not: each attempt inherited the 20-second *command*
  /// timeout, so an unreachable camera produced a loop that could run for
  /// minutes with no feedback at all.  A user watching that has no way to tell a
  /// slow join from a hang.
  ///
  /// So: a 2-second connect timeout per attempt, a wall-clock budget for the
  /// whole wait, and a progress message each second so the UI can say how long it
  /// is still prepared to wait.
  Future<bool> _waitForHttp({
    Duration budget = const Duration(seconds: 75),
    // `FutureOr` rather than `void` because one caller uses the tick to retry the
    // network binding: the association a suggestion produces arrives with no
    // callback, so the poll is the only place to notice it — and it must finish
    // before the probe runs, or the probe goes out over the wrong network.
    FutureOr<void> Function(Duration remaining)? onTick,
  }) async {
    final stopAt = DateTime.now().add(budget);
    // A short-lived client: the command client's timeout is tuned for commands on
    // a working link, not for probing a network that may not exist yet.
    final probe = CameraHttpClient(host: host, timeout: const Duration(seconds: 2));
    try {
      while (DateTime.now().isBefore(stopAt)) {
        final remaining = stopAt.difference(DateTime.now());
        try {
          await onTick?.call(remaining.isNegative ? Duration.zero : remaining);
        } on Object {
          // A tick must never be able to end the wait.
        }
        try {
          final r = await probe.status();
          if (r.ok) return true;
        } on Object {
          // not up yet
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return false;
    } finally {
      probe.close();
    }
  }

  /// Push the phone's clock to the camera.
  ///
  /// The camera has no RTC, so without this every photo is stamped with a wrong
  /// capture date. Cheap, zero-risk, and it must be repeated after each power-on.
  Future<bool> syncTime() async {
    if (!isReady) return false;
    try {
      await ble.write(
          utf8.encode(buildTimeSyncPayload(DateTime.now())), BleChar.timeSync);
      return true;
    } on Object {
      return false;
    }
  }

  /// Start the preview stream.
  ///
  /// Binds the UDP socket **before** telling the camera to start, because frames
  /// begin the instant the mode is entered.
  Future<bool>? _startingPreview;

  Future<bool> startPreview() {
    final inFlight = _startingPreview;
    if (inFlight != null) return inFlight;
    final run = _startPreviewOnce();
    _startingPreview = run;
    run.then<void>(
      (_) {
        if (identical(_startingPreview, run)) _startingPreview = null;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_startingPreview, run)) _startingPreview = null;
      },
    );
    return run;
  }

  Future<bool> _startPreviewOnce() async {
    if (!isReady || current.previewRunning) return current.previewRunning;
    var socketStarted = false;
    try {
      await liveView.start();
      socketStarted = true;
      final r = await http.startRemoteControl();
      if (!r.ok) {
        try {
          await liveView.stop();
        } catch (_) {
          // Cleanup is best effort; preserve the camera command's refusal.
        }
        return false;
      }
      _emit(LinkStage.ready, 'preview running',
          code: LinkCodes.previewRunning, previewRunning: true);
      return true;
    } on Object {
      if (socketStarted) {
        try {
          await liveView.stop();
        } catch (_) {
          // Preserve the original RCStartRemoteCtl/transport exception.
        }
      }
      rethrow;
    }
  }

  /// Stop the preview stream.
  ///
  /// Note: after this the camera is **out of remote mode**, and RC commands such
  /// as `RCDoShooting` will be refused with `{"code":1000,...}` until it is
  /// re-entered.
  Future<void> stopPreview() async {
    if (!isReady) return;
    try {
      await http.stopRemoteControl();
    } on Object {
      // best effort
    }
    await liveView.stop();
    _emit(LinkStage.ready, 'preview stopped',
          code: LinkCodes.previewStopped, previewRunning: false);
  }

  /// Tear the link down so the next [connect] starts clean.
  ///
  /// Deliberately **not** closing [_status]: an earlier revision did, which made
  /// the object single-use — the second connect emitted its progress into a
  /// closed stream, so the UI saw nothing at all and reconnecting appeared to do
  /// nothing.  The stream is a channel for status, not part of the connection, so
  /// it lives as long as the object does.
  ///
  /// ## The two things this used to leave undone
  ///
  /// * **The phone stayed on the access point.** [WifiJoinDelegate.unbind] drops
  ///   the process-wide pin; it does not release the `NetworkRequest` that brought
  ///   an app-scoped network up, and it cannot touch an association the user made
  ///   by hand. Measured on the maintainer's phone after pressing Disconnect:
  ///   `Wifi is connected to "YI_M1_XXXXXX"`, `IP: 192.168.0.3`. That is no
  ///   internet for the user *and* the camera's one client slot held, which is why
  ///   a second device cannot join until the phone is told to leave.
  /// * **The camera's radio stayed on**, costing the battery the app bar's own
  ///   comment claimed to be saving. Nothing in this method ever asked it to stop.
  ///
  /// ## Why the radio goes off over BLE and not over HTTP
  ///
  /// `PROTOCOL.md` §3.4 carries the correction: the Wi-Fi is switched by the BLE
  /// characteristic `41106da5-…` (`WIFI_TOGGLE`), and the same write that opens it
  /// (`"ON"`, `client.py:392`) closes it (`"OFF"`). That route is measured working
  /// even when the camera's network stack has wedged and the peer is **not** on
  /// its access point — i.e. exactly the state this method runs in. HTTP's
  /// `CloseAP` would be the alternative, and it is not used: it exists only over
  /// HTTP, it is in `kDangerousCommands`, and it needs the very link this method
  /// is in the middle of tearing down.
  ///
  /// ## Ordering, and why BLE goes last
  ///
  /// The BLE link is what carries the toggle, so it cannot be torn down before the
  /// write. **It is torn down after it, in this same call.** Leaving it connected
  /// would mean the camera keeps advertising and the phone keeps a second radio
  /// link to a camera the user has just asked to be rid of — the same "rude to the
  /// hardware" the app bar comment objects to, one layer down — and it would let a
  /// later write resurrect the access point the user just switched off. The cost
  /// of reconnecting is bounded and already exercised: [connect] opens BLE first
  /// on every attempt, with no user confirmation while the stored pairing holds.
  Future<DisconnectOutcome> disconnect() => _tearDown(switchRadioOff: true);

  Future<DisconnectOutcome> _tearDown({required bool switchRadioOff}) async {
    DisconnectOutcome? outcome;
    try {
      // 1. Leave the network. Not `unbind` alone — see the doc comment.
      final association = await wifiJoin.releaseAssociation();
      // 2. The pin, which the release above also drops. Kept as its own call
      //    because it is idempotent and because the release path may be a
      //    no-op on a platform that cannot measure the association.
      await wifiJoin.unbind();
      // 3. `stop`, not `dispose`: disposing closes the frame controller, which
      //    makes the receiver single-use and breaks the second connect.
      await liveView.stop();
      // 4. Keep-alive sockets to a camera that is about to vanish make the next
      //    connect look half-established.
      _http?.close();
      _http = null;
      // 5. The radio, over the BLE link that is still up. See `_switchRadioOff`.
      //    `null` when the caller is app teardown and asked for no radio action.
      final RadioSwitchOutcome? radio =
          switchRadioOff ? await _switchRadioOff() : null;
      outcome = DisconnectOutcome(association, radio);
    } finally {
      try {
        await ble.disconnect();
      } on Object {
        // best effort
      }
      // `wifiUp: false` is not decoration: this method released the process-wide
      // network pin a few lines up, and `_emit` keeps the previous value for every
      // field it is not given — so omitting it leaves the status claiming the
      // camera's Wi-Fi is up while nothing is pinned to it.
      //
      // The code is the outcome's own, so the one case that is **not** a clean
      // disconnect — the camera's access point left running — cannot be reported
      // as one. `analysis/46` §8b's lost-link path is a separate method
      // (`reportLost`) and keeps its own sentence.
      final settled = outcome ?? _offlineOutcome;
      // The sentence and the code both come from the outcome, so the two cannot
      // disagree — which is the failure the old `'disconnected'` literal was: a
      // status that said the link went down and nothing about what stayed up.
      //
      // No `params`: each reason is its own code now, precisely so that nothing
      // has to be interpolated into a translated sentence. See
      // [LinkCodes.disconnectedNoPairing] for the measurement that forced it.
      _emit(
        LinkStage.idle,
        settled.message,
        code: settled.code,
        previewRunning: false,
        wifiUp: false,
      );
    }
    // Non-null here by construction: the only way past the `try` without an
    // assignment to `outcome` is an exception, and that leaves through the
    // `finally` rather than reaching this line. Stated rather than defended with a
    // second fallback, because a fallback that cannot run is a claim nobody checks.
    return outcome;
  }

  /// Used when the teardown itself threw, so the status still tells the truth.
  ///
  /// A disconnect that fails halfway has *not* switched anything off, and saying
  /// so is the whole point of this round; the alternative is an empty status or a
  /// clean one, and both are lies.
  static const DisconnectOutcome _offlineOutcome = DisconnectOutcome(
      AssociationRelease(false, 'the teardown did not finish',
          stillAssociated: true),
      RadioSwitchOutcome.writeFailed);

  /// The `"OFF"` write, gated on there being a pairing to authenticate it with.
  ///
  /// ## The gate the task turns on
  ///
  /// The camera holds **one** pairing and a newer client silently replaces it, so
  /// the BLE route to the radio exists only while this app's stored
  /// `(refId, token)` is the pair the camera is holding. Without it the session
  /// payload cannot be correct — the camera's own checksum check is
  /// `crc32("1" + key + token)` — and the write would be refused with the
  /// firmware's generic `0x80`. So the attempt is gated, and the caller is told
  /// **which** of the two situations it was, in the UI, because "nothing happened"
  /// is the failure this whole round is about.
  ///
  /// ## Why the link is not re-established here
  ///
  /// A disconnect during which the BLE link is already down is the wedged-camera
  /// case, and `client.py ble-wifi` recovers it by scanning and reconnecting. That
  /// is deliberately **not** done here: this method runs on a user's tap, and
  /// silently spending a scan plus a connect (seconds, with a radio the user just
  /// asked to be quiet) to switch off a radio they can also switch off with the
  /// camera's own power button is not a trade this app should make unasked. The
  /// reason is reported instead. Reconnecting *is* what [connect] does, and it
  /// does it with the stored pairing and no user confirmation.
  Future<RadioSwitchOutcome> _switchRadioOff() async {
    if (!_record.hasPairing) return RadioSwitchOutcome.noPairing;
    if (!ble.isConnected) return RadioSwitchOutcome.noBleLink;
    try {
      await ble
          .write(utf8.encode('OFF'), BleChar.wifi)
          .timeout(const Duration(seconds: 5));
      return RadioSwitchOutcome.switchedOff;
    } on Object {
      // A refused or lost write. The camera answers application errors on some
      // paths and nothing at all on others, and neither is distinguishable here —
      // so this is reported as "we do not know that it worked" rather than as a
      // switch that failed.
      return RadioSwitchOutcome.writeFailed;
    }
  }

  /// Release everything, including the status and frame streams.
  ///
  /// Only for app shutdown: after this the object is finished.
  ///
  /// The network is released here, but the camera's radio is **not** switched off:
  /// teardown runs while the plugin registrations are coming apart, so a BLE write
  /// from inside it is a race rather than an action — and there is no user waiting
  /// for an outcome to report. The native side releases its own request in
  /// `onDestroy` either way, which is what matters for the phone not being left on
  /// an unusable network.
  Future<void> dispose() async {
    await _tearDown(switchRadioOff: false);
    await liveView.dispose();
    if (!_status.isClosed) await _status.close();
  }
}
