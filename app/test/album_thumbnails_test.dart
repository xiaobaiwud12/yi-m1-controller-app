import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/sync_engine.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';

/// The album grid must end up with a thumbnail for every tile it can have one for,
/// and must **never** hand an image decoder zero bytes.
///
/// ## Where this comes from
///
/// Reported from the phone, with the log to go with it:
///
/// ```
/// E FlutterImageDecoderImplDefault: Failed to decode image
/// E FlutterImageDecoderImplDefault: android.graphics.ImageDecoder$DecodeException: …
/// ```
///
/// and, separately, that the tiles are mostly blank. Both are the grid's thumbnail
/// fetch, and the mechanism is measured rather than guessed (`analysis/50` §2,
/// reproduced in `analysis/61` §1):
///
/// | request | real camera |
/// |---|---|
/// | `.JPG` `Thumbnail` | 200, ~6.8 KB |
/// | **`.DNG` `Thumbnail`** | **204 No Content, zero bytes** |
/// | `.DNG` `MidThumb` | **404** |
/// | `.DNG` `Original` | 200, ~32 MB |
///
/// ## Why the fake camera is shaped like this
///
/// `AGENTS.md` §8 is the rule: *a fixture that does not match what downstream
/// validates can quietly invalidate the whole check.* A fake camera that answers a
/// `.DNG` thumbnail with a JPEG makes the grid look perfect on the desk and blank on
/// the phone — which is precisely how this shipped. So [fakeCameraThumbnail] in
/// `lib/app.dart` refuses what the camera refuses, and these tests drive it.
///
/// ## What is actually asserted
///
/// Not "the code calls the right function": **which entry was asked about**, **which
/// renditions were tried for it**, and what came back. The last one is the defect.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_thumbs_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS
    }
  });

  /// Every request the album made, in order, as `path@resolution`.
  final asked = <String>[];

  /// Every byte buffer that reached an image decoder, with a label saying which
  /// widget handed it over.
  final decoded = <({String where, int length})>[];

  // ## Cleared per test, because these lists *are* the evidence
  //
  // A widget test's page starts fetching thumbnails the moment it is pumped, and both
  // lists live for the whole file. Left alone, the second test's request list contains
  // the first test's requests as well — and an assertion of the form "this tile was
  // asked for exactly three times, in this order" then fails against what is really two
  // tests' worth of evidence. A check that measures the harness instead of the app is
  // worse than no check (`AGENTS.md` §8).
  setUp(() {
    asked.clear();
    decoded.clear();
  });

  /// Wraps a download seam so the requests are visible, and asserts at the point of
  /// handing bytes to a decoder that there are some.
  Future<Uint8List> Function(AlbumFile, FileResolution) spying(
      Future<Uint8List> Function(AlbumFile, FileResolution) inner) {
    return (file, resolution) async {
      asked.add('${file.path}@${resolution.wire}');
      final bytes = await inner(file, resolution);
      if (bytes.isEmpty) {
        // The camera produces this (204 with no body). Recording it here means a
        // future change that lets zero bytes through is reported as *this*, rather
        // than as a decoder exception inside a framework callback.
        decoded.add((where: 'download ${file.path}', length: 0));
      }
      return bytes;
    };
  }

  /// The tile for one camera path.
  ///
  /// The page keys every tile `album-tile-<path|dateSeconds>`, which is what makes an
  /// assertion about *this* tile possible at all — `find.byType(GridView)` and
  /// `find.byType(Image)` cannot tell one tile from another, and the shell keeps other
  /// images mounted besides.
  Finder tile(String path) => find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('album-tile-$path|'),
      description: 'the album tile for $path');

  int imagesInTile(WidgetTester tester, String path) => tester
      .widgetList(find.descendant(of: tile(path), matching: find.byType(Image)))
      .length;

  int spinnersInTile(WidgetTester tester, String path) => tester
      .widgetList(find.descendant(
          of: tile(path), matching: find.byType(CircularProgressIndicator)))
      .length;

  /// The listing the real firmware sends: one entry per shutter press, `.JPG` paths,
  /// `rawJpeg` for a RAW+JPEG shot — plus a **`.DNG`** entry, which the fake camera
  /// fixture deliberately includes because it is the one whose `Thumbnail` the camera
  /// answers with a 204.
  List<Object> listing() => [
        {
          'path': '/DCIM/100YICAM/P9150001.JPG',
          'date': '1789391480',
          'filetype': 'rawJpeg',
          'protectStatus': false,
        },
        {
          'path': '/DCIM/100YICAM/P9150002.JPG',
          'date': '1789391490',
          'filetype': 'picture',
          'protectStatus': false,
        },
        {
          'path': '/DCIM/100YICAM/P9150003.DNG',
          'date': '1789391500',
          'filetype': 'raw',
          'protectStatus': false,
        },
      ];

  /// The card that was measured, **in the camera's own ring order**: 99 files,
  /// starting at `P9150040` and wrapping to `P9150039` (`analysis/61` §8).
  ///
  /// Capture order and listed order therefore disagree by 60 positions, and the *last*
  /// entry is the **oldest** shot. A grid that draws the listing verbatim opens on the
  /// 40th-oldest photo; one that sorts opens on `P9150099`.
  ///
  /// 99 and not 44 on purpose: the grid asks for a bounded leading window and the rest
  /// on scroll, and a fixture short enough to fit inside the grid's cache extent cannot
  /// tell those two paths apart — every assertion about scrolled-to tiles would pass for
  /// the wrong reason.
  List<Object> ringListing() {
    const count = 99;
    const start = 40;
    String name(int n) => 'P9150${n.toString().padLeft(3, '0')}.JPG';
    int shot(int i) => (start - 1 + i) % count + 1; // 40, 41, … 99, 1, 2, … 39
    return [
      for (var i = 0; i < count; i++)
        {
          'path': '/DCIM/100YICAM/${name(shot(i))}',
          'date': '${1789400000 + shot(i)}',
          'filetype': 'picture',
          'protectStatus': false,
        },
    ];
  }

  AppState appWith(
    Future<Uint8List> Function(AlbumFile, FileResolution) download, {
    List<Object>? listingOverride,
  }) {
    return AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testPreviewRunning: true,
      testAlbumDownload: spying(download),
      testOnboardingPrefs: OnboardingPrefs(store: MemoryPrefsStore()),
      testUiPrefs: UiPrefs(store: MemoryPrefsStore()),
      testIdentity: const CameraIdentity(
        protocolVersion: 1,
        firmwareVersion: '3.1-cn ',
        regionMarker: 'M1CN',
      ),
      testHttp: CameraHttpClient(overrideSend: (command, params) async {
        if (command == 'RCGetStatus') {
          return const CameraResponse(
            code: 200,
            data: {'BatteryLevel': '3'},
            raw: '{"code":200,"data":{"BatteryLevel":"3"}}',
          );
        }
        if (command == 'GetFileList') {
          final all = listingOverride ?? listing();
          // ## Paged like the firmware, not returned whole
          //
          // `GetFileList` is **1-based and 60 per page**, and a page *shorter* than 60 is
          // the camera's own end-of-album signal (`CameraAlbum.pageRange`, `listAll`).
          // A fake that ignored `range_start` would hand a 99-entry card over in one
          // response and tell the page the album had ended — so paging, the short-page
          // signal and the grid's scroll-triggered next page would all be untested, and
          // a real card would behave differently from the harness in exactly the place
          // the harness is supposed to be trustworthy.
          final start = int.tryParse('${params['range_start']}') ?? 1;
          final end = int.tryParse('${params['range_end']}') ?? start;
          final from = (start - 1).clamp(0, all.length);
          final to = end.clamp(0, all.length);
          final page = from >= to ? const <Object>[] : all.sublist(from, to);
          return CameraResponse(
            code: 200,
            data: page,
            raw: '{"code":200,"data":[...${page.length} of ${all.length}]}',
          );
        }
        return const CameraResponse(
            code: 200, data: 'ok', raw: '{"code":200,"data":"ok"}');
      }),
    );
  }

  /// Pump real time until no album tile is still claiming to be loading.
  ///
  /// ## Why this is a condition and not a frame budget
  ///
  /// This started as a fixed `for (var i = 0; i < 12; i++)` of real-time frames, and
  /// that was already a guess: the grid fetches **one thumbnail at a time**, so how many
  /// frames it needs is however many tiles the viewport has. Since the disk thumbnail
  /// cache (`analysis/77`) each tile also costs a local cache read and, on a miss, a
  /// cache write — and those are **real file I/O**, which inside a widget test advances
  /// only while `runAsync` is spinning the real event loop, about one step per
  /// iteration. Twelve frames then covered roughly one tile, and the checks below
  /// stopped measuring the grid and started measuring the budget.
  ///
  /// The condition used instead is the one the user can see: every tile stops spinning,
  /// with either a picture or the "no picture" icon. `runAsync` is still required — the
  /// page reads a real ledger before it lists anything, and then reads real files
  /// (`analysis/44` §7).
  Future<void> settleTiles(WidgetTester tester,
      {int maxFrames = 1500, int settledFrames = 3}) async {
    final tiles = find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('album-tile-'));
    var settled = 0;
    for (var i = 0; i < maxFrames; i++) {
      final spinning = find.descendant(
          of: tiles, matching: find.byType(CircularProgressIndicator));
      if (tester.widgetList(tiles).isNotEmpty &&
          tester.widgetList(spinning).isEmpty) {
        // More than one frame of it, because the tree can *look* settled for exactly one
        // frame: right after the reload button is tapped, the previous build is still on
        // screen (tiles, no spinners, nothing in flight) while the new listing has not
        // been asked for yet. Requiring the condition to hold for a few frames is what
        // distinguishes "finished" from "not started".
        if (++settled >= settledFrames) return;
      } else {
        settled = 0;
      }
      // One **event-loop turn**, not a sleep: this loop's job is to let the real event
      // loop deliver file-I/O completions, and every `await` in the grid's serial loop
      // needs one turn of it (the loop's continuations belong to the test's fake-async
      // zone, so they run on the `pump` below). `Duration.zero` and not a millisecond: a
      // non-zero delay also waits for the platform timer tick. Measured on this machine:
      // the two album files took ~40 s with a 1 ms turn and ~20 s with a zero one.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
  }

  /// Pump the album until its thumbnails have settled.
  ///
  /// `runAsync` is not optional here: the page awaits the durable ledger, which is
  /// **real file I/O**, and a widget test's fake-async zone never completes it — the
  /// page then sits on its spinner and the grid is reported missing (`analysis/44`
  /// §7). Several rounds went into diagnosing exactly that.
  Future<void> pumpAlbum(WidgetTester tester, AppState app,
      {Size size = const Size(411, 727)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AlbumPage(app: app),
    ));
    await settleTiles(tester);
    expect(app.album, isNotNull,
        reason: 'the injected link is not ready, so the page cannot list anything');
  }

  testWidgets(
      'the grid asks for the JPEG, gets a thumbnail, and hands the decoder real '
      'bytes', (tester) async {
    final app = appWith(fakeCameraThumbnail);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    // Which entry, and which renditions. The JPEG is the primary of its group, so
    // the first rendition tried for it is `Thumbnail` — the cheap one.
    expect(asked, contains('/DCIM/100YICAM/P9150001.JPG@Thumbnail'),
        reason: 'the grid must ask about the JPEG the group is built from; the '
            'derived .DNG is not in the listing and must not be fetched instead');
    expect(asked.where((a) => a.endsWith('@Thumbnail')).length, 3,
        reason: 'one Thumbnail attempt per tile, not several');
    expect(asked, isNot(contains('/DCIM/100YICAM/P9150001.DNG@Thumbnail')),
        reason: 'the RAW sibling is derived for transfer, not for the grid; asking '
            'for its thumbnail is the request this firmware answers with a 204');

    // The decoder was handed real bytes and nothing else.
    expect(decoded.where((d) => d.length == 0), isEmpty,
        reason: 'zero bytes reached an image decoder, which is the reported '
            '`Failed to decode image`');

    // Counted **per tile, by key**, and not by `find.byType(Image)`: the shell keeps
    // the live-view preview mounted behind the album, so a global image count is
    // three whatever the grid does — the "measuring something other than the thing
    // under test" failure `AGENTS.md` §8 names.
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150001.JPG'), 1,
        reason: 'a JPEG tile did not get a picture after a 200 with real bytes');
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150002.JPG'), 1);
  });
  testWidgets('a .DNG whose Thumbnail is a 204 falls through to another rendition '
      'instead of leaving a spinner', (tester) async {
    final app = appWith(fakeCameraThumbnail);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    // The failure the grid used to have: one `download()` at `Thumbnail`, the throw
    // swallowed, and the tile on a spinner for the life of the page. With the chain
    // the 204 is not the end of the story.
    final dng = asked.where((a) => a.startsWith('/DCIM/100YICAM/P9150003.DNG@'));
    expect(dng, isNotEmpty,
        reason: 'the .DNG tile was never asked about at all, so the fallback '
            'cannot have run');
    expect(dng.first, endsWith('@Thumbnail'),
        reason: 'the cheapest rendition is tried first — a 204 there costs one '
            'empty reply, and the chain only pays for more if it has to');
    expect(dng, contains('/DCIM/100YICAM/P9150003.DNG@MidThumb'),
        reason: 'a 204 at Thumbnail must degrade to the next size rather than '
            'abandon the tile');
    // The full measured column for a RAW, in order: Thumbnail 204, MidThumb 404,
    // Original 200. Nothing here is shortened — this is the same three requests the
    // real camera would be sent, and the reason the chain is ordered cheapest-first
    // is that the first of them is free and usually enough.
    //
    // Asserted as an **exact list**, not "contains": a rebuild during the transfer once
    // made the grid send the whole chain twice, and `contains` cannot see that. This
    // camera serves one request at a time and has no watchdog, so a duplicated chain
    // is the difference between a cosmetic feature and a request storm.
    expect(dng.toList(),
        [
          '/DCIM/100YICAM/P9150003.DNG@Thumbnail',
          '/DCIM/100YICAM/P9150003.DNG@MidThumb',
          '/DCIM/100YICAM/P9150003.DNG@Original',
        ],
        reason: 'the .DNG was asked for more than once, or in the wrong order');
    expect(asked.where((a) => a.endsWith('@Thumbnail')).length, 3,
        reason: 'each tile asks for Thumbnail exactly once, whatever else happens: '
            '$asked');

    // Settled with a picture, and **not** left on a spinner. The `Original` came back
    // with real bytes, so the honest end state is a photo — the point is that the
    // `204` no longer ends the story at "nothing".
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150003.DNG'), 1,
        reason: 'the .DNG tile reached a rendition with real bytes and still shows '
            'nothing');
    expect(spinnersInTile(tester, '/DCIM/100YICAM/P9150003.DNG'), 0,
        reason: 'a tile is still spinning after the fetch chain finished');
    // Every tile is settled, not just that one — the whole point is that the grid
    // stops claiming to be loading.
    expect(
        find.descendant(
            of: find.byWidgetPredicate((w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('album-tile-')),
            matching: find.byType(CircularProgressIndicator)),
        findsNothing);

    expect(decoded.where((d) => d.length == 0), isEmpty,
        reason: 'the 204 body must never reach a decoder');
  });

  testWidgets('a thumbnail is asked for once, not on every rebuild',
      (tester) async {
    final app = appWith(fakeCameraThumbnail);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    final afterFirst = List<String>.of(asked);
    expect(afterFirst, isNotEmpty, reason: 'nothing was fetched at all');

    // Rebuild the page and scroll, which is what an `AnimatedBuilder` on `AppState`
    // does on every sync tick. The camera serves one request at a time with no
    // watchdog (`AGENTS.md` §4.6), so a cosmetic feature re-asking here would be a
    // request storm against it.
    for (var i = 0; i < 5; i++) {
      app.sync.mode = i.isEven
          ? SyncMode.autoOriginalOnly
          : SyncMode.autoPreviewThenOriginal;
      await tester.pump();
    }
    await tester.drag(find.byType(GridView), const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 50));

    expect(asked.length, afterFirst.length,
        reason: 'the grid re-asked for a thumbnail it had already asked for: '
            '${asked.sublist(afterFirst.length)}');
  });

  testWidgets('a transient failure is reported and the tile says so, and a reload '
      'gives it another chance', (tester) async {
    var fail = true;
    final app = appWith((file, resolution) async {
      if (fail) throw const AlbumException('HTTP 500 downloading', 500);
      return fakeVerificationImage();
    });
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    expect(asked, isNotEmpty, reason: 'nothing was attempted');
    expect(asked.first, endsWith('@Thumbnail'));
    // Every rendition failed, so the tile is not left claiming to be loading.
    expect(
        find.byIcon(Icons.image_not_supported_outlined), findsNWidgets(3),
        reason: 'all three tiles failed, so all three must say so');

    // A failure must not be cached into permanence: the reload button clears both
    // the "asked" record and the failed set, so a transient failure does not become
    // a blank tile for the life of the page.
    fail = false;
    asked.clear();
    await tester.tap(find.byKey(const ValueKey<String>('btn-album-reload')));
    await settleTiles(tester);

    expect(asked, isNotEmpty, reason: 'the reload did not re-ask');
    // Every tile recovered: nothing may still be marked unloadable, on the JPEG or on
    // the .DNG. This is the assertion that fails if a failure is remembered forever —
    // which is what turns one transient error into a permanently blank grid.
    expect(
        tester
            .widgetList(find.descendant(
                of: tile('/DCIM/100YICAM/P9150001.JPG'),
                matching: find.byIcon(Icons.image_not_supported_outlined)))
            .length,
        0,
        reason: 'the tile is still marked unloadable after a successful refetch');
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150001.JPG'), 1);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing,
        reason: 'a tile is still marked unloadable after the camera started '
            'answering');
  });

  testWidgets('a tile further down the card gets its thumbnail when it comes into '
      'view', (tester) async {
    // ## The other half of "thumbnails are missing"
    //
    // The fetch used to be `grouped.take(18)` — one pass, over the first eighteen tiles,
    // once per page load. Everything past the eighteenth therefore showed a spinner for
    // the life of the page no matter how long the user waited or how far they scrolled,
    // because nothing ever asked for it. On the card that was measured (99 files) that is
    // 81 of 99 tiles blank.
    final app = appWith(fakeCameraThumbnail, listingOverride: ringListing());
    addTearDown(app.dispose);
    // A **real phone's** surface, not the 800x600 default: on the default the app bar
    // and the sync bar leave the grid a couple of rows, so almost nothing is laid out
    // and the preconditions below fail for reasons that have nothing to do with
    // thumbnails. Tall enough that the leading window and the scrolled-to window are
    // clearly different regions of the card.
    await pumpAlbum(tester, app, size: const Size(411, 2400));

    // Preconditions, asserted rather than assumed: a fixture that fits on one screen
    // cannot show whether off-screen tiles are fetched, and every assertion below would
    // pass against it for the wrong reason.
    final grid = tester.widget<GridView>(find.byType(GridView));
    final tiles = grid.childrenDelegate.estimatedChildCount ?? 0;
    expect(tiles, greaterThan(24),
        reason: 'the first page must already be longer than the leading window this '
            'grid fetches, or nothing here is measured');
    final gridBox = tester.getSize(find.byType(GridView));
    expect(gridBox.height, greaterThan(150),
        reason: 'the grid is ${gridBox.height}dp tall, so nothing is off screen and '
            'this check measures nothing');
    // `ScrollPosition` is reached through the element tree, because `tester.widget`
    // would hand back the `Scrollable` *configuration*, which carries no position.
    final scrollable = find.descendant(
        of: find.byType(GridView), matching: find.byType(Scrollable));
    final position = tester
        .state<ScrollableState>(scrollable)
        .position;
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'the grid cannot scroll, so no tile is out of view');

    final offScreen = '/DCIM/100YICAM/P9150018.JPG'; // the oldest on the first page
    // Deliberately **not asked for** on load: the initial pass covers a bounded leading
    // window, and everything past it waits until it is scrolled into view. That bound is
    // the point — the camera serves one request at a time, so a page load must not queue
    // the whole card.
    expect(asked.where((a) => a.startsWith('$offScreen@')), isEmpty,
        reason: 'precondition: the far end of the page was fetched before it was ever '
            'scrolled to — this check cannot then show anything');
    // The tiles on screen, in order: this is the user-visible half of the sort. The
    // listing arrives as a ring (40, 41, … 99, 1, 2, … 39), so an unsorted grid opens
    // on the 40th-oldest photo; the newest is `P9150099`.
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150099.JPG'), 1,
        reason: 'the newest shot in the listing did not get a thumbnail on the first '
            'screen — the grid is not drawing the listing newest-first');

    // Scroll until it is genuinely on screen — the same thing the user does, and not a
    // fixed offset, because the point of the check is that being *visible* is what
    // triggers the fetch.
    await tester.scrollUntilVisible(tile(offScreen), 400,
        scrollable: find.descendant(
            of: find.byType(GridView), matching: find.byType(Scrollable)));
    await settleTiles(tester);
    expect(tile(offScreen), findsOneWidget,
        reason: 'the tile never came into view, so nothing was measured');

    expect(asked.where((a) => a.startsWith('$offScreen@')), isNotEmpty,
        reason: 'the tile came into view and nothing asked the camera for it');
    expect(spinnersInTile(tester, offScreen), 0,
        reason: 'the tile at the end of the card is still spinning — nothing asked '
            'the camera for it, which is the reported "thumbnails are missing"');
    expect(imagesInTile(tester, offScreen), 1,
        reason: 'a tile that scrolled into view did not get a thumbnail');
  });

  // ------------------------------------------------------------------ videos
  //
  // ## The maintainer's hypothesis, tested rather than assumed
  //
  // "缩略图最旧几张还是不显示 — 我觉得和这些照片一旁的视频有关": *I think it is related
  // to the videos next to those photos.* The card really does carry them — the full
  // listing measured in `analysis/61` reports `{'video', 'rawJpeg', 'picture'}` — and
  // the fetch is **one serial loop**, so the shape of the worry is: a video's
  // thumbnail fails, the loop stops there, and everything after it is blank.
  //
  // The two halves of that are answered separately below, because they have different
  // answers: the loop **does** survive a video (it cannot not — see the first check),
  // and the grid **does** ask a video for its full-size original (it must not — see
  // the second).
  //
  // ## What is *not* measured, and it is the same gap as last time
  //
  // What this firmware answers for a **video's** `Thumbnail` is unknown. `analysis/50`
  // measured `.JPG` (200) and `.DNG` (204 at Thumbnail, 404 at MidThumb, 200 at
  // Original) and nothing at all for a video, and `fakeCameraThumbnail` answers a
  // video's thumbnail with a real JPEG — a *hope*, not a measurement. That is exactly
  // the fixture gap that let the `.DNG` defect ship, so neither check below depends on
  // the answer: one models the worst case (every rendition refused) and the other holds
  // whatever the camera answers at `Thumbnail`.
  Map<String, Object> shotEntry(String name, int seconds, {bool asVideo = false}) =>
      {
        'path': '/DCIM/100YICAM/$name.${asVideo ? 'MP4' : 'JPG'}',
        'date': '$seconds',
        'filetype': asVideo ? 'video' : 'picture',
        'protectStatus': false,
      };

  /// The camera with no still rendition for a video: **every** rung of the chain
  /// refused.
  ///
  /// This is the maintainer's shape, modelled as the worst case rather than as a
  /// measurement — see the section note above. A camera that answers a video's
  /// `Thumbnail` with a real frame never reaches the rungs below it, which is the
  /// other possible answer and is left alone here.
  Future<Uint8List> Function(AlbumFile, FileResolution) refusingVideoStills() =>
      (file, resolution) async {
        if (file.isVideo) {
          throw AlbumException(
              'refused ${file.path} at ${resolution.wire} (worst-case fixture)', 204);
        }
        return fakeVerificationImage();
      };

  testWidgets('a video whose every rendition is refused does not stop the grid '
      'fetching the tiles after it', (tester) async {
    final videoPath = '/DCIM/100YICAM/P9150002.MP4';
    final card = <Object>[
      shotEntry('P9150004', 1789400004),
      shotEntry('P9150003', 1789400003),
      // Third of four, so the tiles after it are the **oldest** — the ones the
      // maintainer reports as missing.
      shotEntry('P9150002', 1789400002, asVideo: true),
      shotEntry('P9150001', 1789400001),
    ];
    final app = appWith(refusingVideoStills(), listingOverride: card);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app, size: const Size(411, 1200));

    // The video was really asked about and really ended with no picture — otherwise
    // this check is measuring a video that never entered the loop.
    expect(asked.where((a) => a.startsWith('$videoPath@')), isNotEmpty,
        reason: 'the video tile was never fetched, so nothing here is measured');
    expect(spinnersInTile(tester, videoPath), 0,
        reason: 'the video tile is still spinning after its chain was refused');
    expect(
        tester
            .widgetList(find.descendant(
                of: tile(videoPath),
                matching: find.byIcon(Icons.image_not_supported_outlined)))
            .length,
        1,
        reason: 'a video with no thumbnail must say so rather than spin');

    // **And the loop went on.** The oldest shot on the card comes after the video, and
    // a serial loop that gave up at the refusal would leave it spinning forever.
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150001.JPG'), 1,
        reason: 'the video took the rest of the list down with it: the tile after it '
            'never got a thumbnail');
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150003.JPG'), 1);
    expect(imagesInTile(tester, '/DCIM/100YICAM/P9150004.JPG'), 1);
  });

  testWidgets('the grid never asks a video for its full-size original',
      (tester) async {
    // ## Why this is the real half of the video hypothesis
    //
    // The grid's chain is `Thumbnail → MidThumb → Original`, and for a `.DNG` that is
    // right: the original is a 32 MB image, which is a lot, but it *is* an image.
    //
    // A video's original is the **video**. `Image.memory` cannot decode an MP4 at all,
    // so the last rung of the chain can only produce a broken-image icon — after
    // downloading the whole file, over the camera's own access point, on a
    // single-threaded server sharing the radio with the live view (`AGENTS.md` §4.6).
    // And because the fetch is **one serial loop**, a video that reaches that rung
    // holds up every tile behind it in the queue: the tiles the user is scrolling
    // towards are exactly the ones that wait. That is a mechanism for "the oldest few
    // never load" which needs no guess about what the camera answers at `Thumbnail`.
    final videoPath = '/DCIM/100YICAM/P9150002.MP4';
    final card = <Object>[
      shotEntry('P9150003', 1789400003),
      shotEntry('P9150002', 1789400002, asVideo: true),
      shotEntry('P9150001', 1789400001),
    ];
    final app = appWith(refusingVideoStills(), listingOverride: card);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app, size: const Size(411, 1200));

    expect(asked, contains('$videoPath@Thumbnail'),
        reason: 'the video was never asked for a thumbnail at all, so this check '
            'measured nothing');
    expect(asked, isNot(contains('$videoPath@Original')),
        reason: 'the grid asked the camera for the video itself to draw a 170dp tile: '
            'an MP4 cannot be decoded into an image, and on this single-threaded '
            'camera that request holds up every tile behind it in the one serial loop');
    expect(asked.where((a) => a.startsWith('$videoPath@')).toList(),
        ['$videoPath@Thumbnail', '$videoPath@MidThumb'],
        reason: 'a video is asked for its still renditions, cheapest first, and '
            'nothing beyond them');
  });
}
