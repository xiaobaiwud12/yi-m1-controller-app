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

  Future<void> pumpViewer(WidgetTester tester,
      {required dynamic app, required AssetGroup group}) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AssetViewerPage(app: app, group: group),
    ));
    await tester.pump(const Duration(milliseconds: 50));
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

  testWidgets('opening an unsynced photo still does not touch the camera',
      (tester) async {
    // The camera is a deliberate second step, not a side effect of a tap. The
    // album grid already loads thumbnails for browsing; opening one must not add
    // a full-size request to that traffic.
    final commands = <String>[];
    final downloads = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);
    useMediaChannel(bytes: null);
    attachAlbum(app, downloads);

    await pumpViewer(tester, app: app, group: shot());

    expect(downloads, isEmpty,
        reason: 'the viewer reached the camera without being asked to');
    expect(commands.where((c) => c == 'GetFile'), isEmpty,
        reason: 'the viewer drove GetFile without being asked to');
    expect(find.byKey(const ValueKey<String>('btn-viewer-fetch-camera')),
        findsOneWidget,
        reason: 'there must be a named way to fetch it, or the photo is stuck');
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
