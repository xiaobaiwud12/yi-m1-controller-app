import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/camera_connection.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';

/// The English strings, synchronously, for a test that asserts on what a user reads.
///
/// ## Why a test must use this instead of a literal
///
/// `find.text('Capture')` passes today and fails the next time somebody rewords the
/// button — and the failure looks like a broken feature rather than a broken test.
/// Looking the string up through the same table the app draws from means a wording
/// change moves both sides at once, so a test only fails when the *behaviour* it
/// describes has changed.
///
/// It also does something a literal cannot: because the getter is typed, a key that
/// no longer exists is a **compile error** rather than a `findsNothing` that reads
/// like a UI regression.
///
/// `AppLocalizationsEn` is generated, and constructing it directly is what makes this
/// synchronous — `AppLocalizations.delegate.load()` returns a `Future`, which would
/// push every caller into an `async` body for no benefit.
final AppLocalizations en = englishStrings;

/// The Simplified Chinese strings, for the tests that assert a locale switch.
final AppLocalizations zh = chineseStrings;

/// Wraps [child] in the `MaterialApp` the app actually builds.
///
/// **Every widget test that pumps a page must go through this.** Since the app was
/// localized, `l10nOf(context)` resolves through `Localizations`, so a bare
/// `MaterialApp` without [AppLocalizations.localizationsDelegates] throws
/// `Null check operator used on a null value` at the first `Text` — and on a page that
/// wraps its body in something that swallows exceptions (`tester.takeException()`),
/// the measurement would silently be taken off an `ErrorWidget` instead. That is the
/// "green but measuring nothing" failure `AGENTS.md` §8 names, so the harness installs
/// the delegates rather than each test remembering to.
///
/// [locale] pins the drawn language. Left null the app follows the test binding's
/// platform locale, which is `en_US` — but a test that asserts Chinese must say so
/// here, because "it happened to pick Chinese" is not a check.
Widget localizedApp(Widget child, {Locale? locale, ThemeData? theme}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: theme,
      home: child,
    );

/// A BLE transport that answers nothing and connects to nothing.
///
/// The pages under test must render their **disconnected** state without a
/// camera — that is the state the app is in every time it is launched — so the
/// transport only has to exist and refuse politely.
class FakeBleTransport implements BleTransport {
  @override
  Future<String?> findCamera() async => null;

  @override
  Future<void> connect(String deviceId) async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool get isConnected => false;

  @override
  Future<List<int>> readFirmwareInfo() async => const [];

  @override
  Future<List<int>> readMisc() async => const [];

  @override
  Future<List<int>> readWifiCredentials() async => const [];

  @override
  Future<void> write(Uint8List data, String characteristic) async {}

  @override
  Future<void> subscribePairing(void Function(List<int>) onData) async {}

  @override
  List<String> get log => const [];
}

/// Replace the `path_provider` channel with a temporary directory.
///
/// Without it every persistence read throws `MissingPluginException` inside a
/// fire-and-forget future, which would make this suite report failures that say
/// nothing about the app.
void useTempStorage(String dir) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => dir);
}

/// An [AppState] wired for a widget test: no camera, no real files, and a sink
/// that keeps nothing.
///
/// The disconnected state — which is what the app launches into, and worth
/// testing on its own.
AppState testAppState() => AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
    );

/// An [AppState] that believes it is talking to the camera.
///
/// ## Why this is needed
///
/// The screens the user has reported bugs in — the two landscape side bands, the
/// shutter bar, the camera readout, the paused-preview banner — are all gated on
/// `link.isReady`, which needs a paired camera. The real sequence starts with BLE,
/// and an Android emulator **has no Bluetooth adapter**, so the connected UI
/// cannot be reached on one; a widget test has no radio at all. Injecting the HTTP
/// client is enough to render all of it, which is what makes the landscape band
/// widths and the banner's actions **measurable** rather than something verified
/// by reading the layout code.
///
/// The HTTP client is a stub: every command answers 200 with no data, and nothing
/// is asserted about protocol behaviour here — these tests are about the tree, not
/// about the camera.
AppState connectedTestAppState({
  CameraIdentity? identity,
  void Function(String command)? onCommand,
  /// The album's `GetFile` seam.
  ///
  /// The album downloads through raw HTTP (its body *is* the file), which no widget
  /// test has a server for — so without this, `_pumpThumbs` fails for every tile and
  /// the grid is a wall of spinners whatever the page does. That is the state the
  /// missing-thumbnail checks exist for, and they cannot be written against a harness
  /// that cannot serve a thumbnail at all.
  ///
  /// Supply [fakeCameraThumbnail] from `lib/app.dart` for the real camera's measured
  /// behaviour (a `.DNG` `Thumbnail` is a `204` with no body), or a spy of your own to
  /// record what was asked for.
  Future<Uint8List> Function(AlbumFile, FileResolution)? albumDownload,
  /// Report the preview as already running.
  ///
  /// Some screens are only reachable in remote mode — the video page shows its caution
  /// dialog only when its gear is usable, and the shutter is only enabled with the
  /// preview up — so a test of those needs the link to claim it is streaming. It is a
  /// claim about state, not a stream: nothing is actually sent or received.
  bool previewRunning = false,
  /// The remembered first-run answers, defaulting to "nothing stored".
  ///
  /// **Always supply one in a widget test.** The production store reads through
  /// `path_provider`, and a widget test has no platform channel for it: the call raises
  /// `MissingPluginException` — which `OnboardingPrefs.load` swallows, as it should —
  /// but only after an **asynchronous gap**. `AppState._load()` awaits it, so that extra
  /// hop delays everything after it, `sync.restore()` and the first `notifyListeners()`,
  /// past a test's pump budget. It surfaced as `sync_list_control_test` expecting a
  /// five-item queue and finding two, with nothing wrong with the queue or the
  /// preference: the album listing simply had not happened yet.
  ///
  /// A memory-backed store removes the hop instead of papering over it, so tests drive
  /// the real launch path with a real answer in it.
  OnboardingPrefs? onboardingPrefs,
}) =>
    AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testPreviewRunning: previewRunning,
      testAlbumDownload: albumDownload,
      testOnboardingPrefs:
          onboardingPrefs ?? OnboardingPrefs(store: MemoryPrefsStore()),
      // Same reasoning as `onboardingPrefs` above: the launch path awaits this store too,
      // and `path_provider` has no channel in a widget test, so the read raises
      // `MissingPluginException` after an asynchronous gap and pushes `_load()` past a
      // test's pump budget. Two such gaps made `sync_list_control_test` fail
      // intermittently — three passes in three runs alone, a failure under a full
      // parallel verify.
      testUiPrefs: UiPrefs(store: MemoryPrefsStore()),
      testIdentity: identity ??
          const CameraIdentity(
            protocolVersion: 1,
            firmwareVersion: '3.1-cn ',
            regionMarker: 'M1CN',
          ),
      testHttp: CameraHttpClient(overrideSend: (command, params) async {
        onCommand?.call(command);
        // `RCGetStatus` is the liveness probe the app uses; answering it with a
        // plausible state keeps the guard happy without inventing behaviour.
        if (command == 'RCGetStatus') {
          return const CameraResponse(
            code: 200,
            data: {'BatteryLevel': '3'},
            raw: '{"code":200,"data":{"BatteryLevel":"3"}}',
          );
        }
        // A listing, so the album renders its **grid** rather than its empty state.
        //
        // Without this the album tests only ever exercised `_Message("No photos
        // found")`, which meant any assertion about the grid silently had nothing to
        // measure — the landscape layout test found out by reporting 0 `GridView`s.
        // Three entries rather than one, because a single tile cannot show whether
        // the grid is laying out or just stretching.
        if (command == 'GetFileList') {
          return const CameraResponse(
            code: 200,
            data: [
              {
                'path': '/DCIM/101YICAM/YI000001.JPG',
                'date': '1700000000',
                'filetype': 'picture',
                'protectStatus': false,
              },
              {
                'path': '/DCIM/101YICAM/YI000002.JPG',
                'date': '1700000100',
                'filetype': 'picture',
                'protectStatus': false,
              },
              {
                'path': '/DCIM/101YICAM/YI000003.DNG',
                'date': '1700000200',
                'filetype': 'raw',
                'protectStatus': false,
              },
            ],
            raw: '{"code":200,"data":[...]}',
          );
        }
        return const CameraResponse(
          code: 200,
          data: 'ok',
          raw: '{"code":200,"data":"ok"}',
        );
      }),
    );

/// A 1x1 PNG, so `Image.memory` decodes in a widget test instead of throwing.
///
/// The content is irrelevant for a *viewer*: those tests assert what the viewer asks
/// the camera for, not what the picture looks like. `looksLikePng` below is the check
/// that it really is a PNG rather than bytes that merely decode.
///
/// **This is not usable as a `.JPG`** for anything the sync engine inspects: the engine
/// integrity-checks a `.JPG` for its end-of-image marker before publishing it, and a PNG
/// can never carry one. `analysis/44` §6 records a whole sync failing that way because a
/// fixture was the wrong format.
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// The marker a PNG must start with — `89 50 4E 47`.
///
/// A fixture's own format has to be asserted, because the failure mode of a wrong
/// fixture is that **other** checks quietly stop meaning anything: a PNG served for a
/// `.JPG` makes a viewer test pass against a file the sync engine would reject.
bool looksLikePng(List<int> bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

/// A real JPEG — `FF D8` … `FF D9` — for anything the sync engine inspects.
///
/// ## Why the fixtures must be the format the consumer checks
///
/// A PNG under a `.JPG` name makes a check pass against a consumer that would reject the
/// real file. That is not hypothetical here: `analysis/44` §6 records a whole sync failing
/// with `truncated image (missing end-of-image marker)` because the fake camera's fixture
/// was a PNG, and the fixture's own test only asserted "it decodes".
///
/// `looksLikeJpeg` is the assertion that this cannot silently stop being a JPEG.
final Uint8List jpegFixture = base64Decode(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
  'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA'
  'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
);

/// The markers a JPEG must have.
bool looksLikeJpeg(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0xFF &&
    bytes[1] == 0xD8 &&
    bytes[bytes.length - 2] == 0xFF &&
    bytes[bytes.length - 1] == 0xD9;

/// Replace the media channel so a stored asset can be read back in a test.
void useMediaChannel({Uint8List? bytes, List<String>? reads}) {
  const channel = MethodChannel('com.cem1.yi_m1_controller/media');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'readMedia') {
      reads?.add((call.arguments as Map)['uri'] as String);
      return bytes;
    }
    if (call.method == 'available') return true;
    return null;
  });
}

/// A [SyncStore] that lives in memory, so a widget test never reaches
/// `path_provider`.
///
/// See the note on [connectedTestAppState]'s `onboardingPrefs` argument: the platform
/// call is not merely unavailable in a widget test, it is *slow to fail*, and the
/// asynchronous gap it leaves is enough to push `AppState._load()` past a test's pump
/// budget. Removing the channel removes the gap.
class MemoryPrefsStore implements SyncStore {
  MemoryPrefsStore([this._contents]);

  String? _contents;

  @override
  Future<String?> read() async => _contents;

  @override
  Future<void> write(String contents) async => _contents = contents;
}
