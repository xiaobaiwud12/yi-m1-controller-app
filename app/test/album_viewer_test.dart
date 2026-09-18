import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/sync/asset_group.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The photo viewer must not drive the camera for a photo it already has.
///
/// ## Why this file exists
///
/// Reported from a device: opening a photo in the album **froze the camera and
/// it rebooted**. The viewer used to fetch `MidThumb` and then `Original` over
/// HTTP on every open, even for a shot that had already been synced. That puts
/// `GetFile` into the camera's single-threaded server while it is streaming live
/// view — the exact contention the album design is supposed to avoid.
///
/// A synced photo is on the phone, so it has to be read from the phone. These
/// tests assert the *command log*, not the pixels: "did the viewer ask the
/// camera for anything?" is the question whose wrong answer wedges hardware.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_viewer_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  AssetGroup shot() => AssetGroup(AlbumFile(
        path: '/DCIM/101YICAM/YI000001.JPG',
        fileType: 'picture',
        captureTime: DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      ));

  /// Give the app a real album whose downloads are recorded.
  ///
  /// Load-bearing: with `app.album == null` the *old* viewer also sent nothing,
  /// because it bailed out with "not connected". A check that passes against the
  /// defective version proves nothing, so the album has to exist and its
  /// `download` calls have to be observable.
  void attachAlbum(dynamic app, List<String> downloads) {
    app.album = CameraAlbum(
      CameraHttpClient(overrideSend: (command, params) async {
        return const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok');
      }),
      overrideDownload: (file, resolution) async {
        downloads.add('${file.fileName}:${resolution.wire}');
        return onePixelPng;
      },
    );
  }

  /// Whether the viewer has stopped working: no spinner anywhere on it.
  ///
  /// Deliberately not "an image is on screen": two of these checks pass bytes that cannot
  /// decode (the ledger cases), and their subject is the message rather than a picture.
  bool settled(WidgetTester tester) =>
      find.byType(CircularProgressIndicator).evaluate().isEmpty;

  Future<void> pumpViewer(WidgetTester tester,
      {required dynamic app, required AssetGroup group}) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AssetViewerPage(app: app, groups: [group]),
    ));
    // ## Why this is real time and not `pump(Duration(milliseconds: 50))`
    //
    // It was the latter, and it was enough while opening a photo fetched nothing. Now the
    // viewer loads a preview on open, and whether the fetch has **settled** decides what is
    // on screen: during it the status band says the photo is loading, after it the band
    // offers the full size. A fixed fake-clock pump lands somewhere inside that, so an
    // assertion about which control is present would be a race dressed as a check.
    // `runAsync` steps outside the fake-async zone, where the platform channel and the
    // image decode — and the album's `overrideDownload` — actually complete.
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 2));
      if (settled(tester)) break;
    }
  }


  testWidgets('an injected connection reaches the album at all', (tester) async {
    // The verification harness found this the hard way: `connectedTestAppState()`
    // puts the link into `ready` inside the `CameraConnection` constructor, which is
    // *before* `AppState` subscribes to the status stream — and a broadcast stream
    // delivers only what happens after subscription. So the ready branch never ran,
    // `album` stayed null, and the app contradicted itself on screen: the header and
    // shutter said "connected" while the album tab said "Not connected. Connect to
    // the camera first."
    //
    // Asserted through the public surface rather than by poking at internals, so a
    // future connection path that reaches `ready` early is covered too.
    final app = connectedTestAppState();
    addTearDown(app.dispose);

    expect(app.link.isReady, isTrue, reason: 'precondition: the seam is ready');
    expect(app.album, isNotNull,
        reason: 'a ready link must give the album somewhere to come from, or the '
            'album tab claims the app is disconnected');
  });

  testWidgets('opening a synced photo sends nothing to the camera',
      (tester) async {
    // The regression this test exists for. If the viewer reaches for the camera
    // here, the user's camera can be wedged by a tap on a photo that is already
    // on their phone.
    final commands = <String>[];
    final downloads = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);

    final group = shot();
    final reads = <String>[];
    useMediaChannel(bytes: onePixelPng, reads: reads);
    app.ledger.recordLocal(
        group.id, AssetQuality.original, 'content://media/external/images/42');
    attachAlbum(app, downloads);
    commands.clear();

    await pumpViewer(tester, app: app, group: group);

    expect(reads, hasLength(1),
        reason: 'the phone copy was never read, so the viewer had no photo');
    expect(downloads, isEmpty,
        reason: 'the viewer fetched from the camera for a photo already saved');
    expect(commands.where((c) => c == 'GetFile'), isEmpty,
        reason: 'the viewer drove GetFile for a photo already saved');
    expect(find.textContaining(en.viewerLocalCopy), findsOneWidget);
  });

  testWidgets('opening an unsynced photo loads one preview, and no more',
      (tester) async {
    // ## What this test used to say, and why it changed
    //
    // It used to assert `downloads` is **empty** — "the viewer reached the camera without
    // being asked to" — and that was correct for `analysis/39`'s rule. The maintainer then
    // asked for the preview to load when a photo opens, so the rule was narrowed to the
    // half that was always load-bearing (`AGENTS.md` §4.6, `analysis/81` §2.1): **a shot
    // with a ledger entry is never fetched**, and a shot without one may load **one**
    // preview.
    //
    // So the camera *is* reached here, deliberately — and the assertions that matter are
    // that it is reached **exactly once**, at the measured `MidThumb` rendition, and that
    // the full-size file still needs the explicit button. Those numbers are here rather
    // than only in `album_viewer_layout_test.dart` because this file is the command log
    // of record for the viewer, and "one request" is a fact about the camera.
    final commands = <String>[];
    final downloads = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);
    useMediaChannel(bytes: null);
    attachAlbum(app, downloads);

    await pumpViewer(tester, app: app, group: shot());

    // Exactly one request, and it is the cheap rendition. `Original` for this camera is
    // 5,565,238 B against `MidThumb`'s 196,495 B (`analysis/61` §1), and a tap on a photo
    // is not the user asking for five megabytes.
    expect(downloads, ['YI000001.JPG:MidThumb'],
        reason: 'opening a large photo must load exactly one preview — not none, and '
            'not the full-size original. Got $downloads');
    // **Not asserted through `commands`.** `GetFile` is the one command whose response
    // *is* the file, so it does not go through `CameraHttpClient.send` and never reaches
    // `onCommand` — a count of it there is always zero, which is a check that cannot
    // fail. The `downloads` list above is the seam that sees it, and it sees the
    // rendition too. (`analysis/81` §1.7 is this same shape three more times.)
    expect(find.textContaining(en.qualityPreview), findsOneWidget,
        reason: 'the viewer must say the copy on screen is a preview, not the real file');
  });

  testWidgets('a ledger entry whose bytes are gone says so instead of refetching',
      (tester) async {
    // Deleting from the system gallery leaves the ledger claiming the shot is
    // saved. Silently re-downloading would hide the deletion and put the viewer
    // back on the camera path this change removes.
    final commands = <String>[];
    final downloads = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);

    final group = shot();
    useMediaChannel(bytes: null);
    app.ledger.recordLocal(
        group.id, AssetQuality.original, 'content://media/external/images/99');
    attachAlbum(app, downloads);
    commands.clear();

    await pumpViewer(tester, app: app, group: group);

    expect(downloads, isEmpty);
    expect(commands.where((c) => c == 'GetFile'), isEmpty);
    expect(find.textContaining(en.albumSavedCopyGone), findsOneWidget);
  });
}
