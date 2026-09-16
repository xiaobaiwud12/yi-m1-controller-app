import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';

/// Opening the album twice must not fetch the same thumbnails twice.
///
/// ## What this is for
///
/// Reported by the maintainer: *every time I connect the camera and open the album the
/// thumbnails reload — is that necessary?* It is not, and the cost is not only the wait:
/// the camera is a **single-threaded HTTP server with no watchdog**, and while the live
/// view is streaming every thumbnail request competes with the preview (`AGENTS.md`
/// §4.6, `analysis/37`–`39`). Browsing the album with the preview running is the worst
/// case, so re-fetching pictures the phone already holds is pressure the feature should
/// be removing rather than adding.
///
/// ## What is asserted, and what is not
///
/// **Which requests reached the camera**, counted at the album's own `GetFile` seam —
/// not "the cache object returned something". A check that only proved the in-memory map
/// works would pass on the code as it was before this change, which is the failure
/// `analysis/75` records. So the checks below were **run against the unfixed tree first**
/// and failed there; the round's report carries the output.
///
/// The second half of the same claim is [the camera being switched off]: a visit that
/// draws the pictures while the camera refuses every request cannot have got them from
/// the camera. That is the difference between "the grid remembered" and "the phone has
/// them", and only the second survives leaving the page.
///
/// ## Why the harness is shaped like this
///
/// * **A real directory** (`useTempStorage`), because the whole feature is that the
///   bytes outlive the page and the app object. A memory-backed store would make the
///   harness unable to fail in the one place that matters.
/// * **`manualOnly` sync mode**, so browsing does not queue every listed shot and the
///   sync bar does not squeeze the grid into a few rows (`album_last_page_test.dart`
///   records the same reasoning). The squeeze was a **real defect** — an unbounded
///   summary row left the grid 15dp of a 671dp body in English — and it is **fixed**;
///   `album_sync_bar_height_test.dart` is the check that runs in the automatic mode and
///   measures the grid. This fixture still picks manual mode because its subject is the
///   cache, not the layout, and a lighter bar keeps its numbers stable.
/// * **Real JPEG bytes** from `fakeVerificationImage()`, the same fixture the fake camera
///   serves: it carries the SOI/EOI markers the cache insists on before it keeps
///   anything.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_thumb_cache_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS
    }
  });

  /// A camera that records what was asked of it, and can be switched off.
  ///
  /// "Off" is half of what the feature promises: a phone that already has the picture
  /// must draw it when the camera has nothing to say.
  final camera = _RecordingCamera();

  setUp(camera.reset);

  /// The card: five shots, one page, short enough to be the firmware's own end-of-album
  /// signal. Phone-sized on purpose — nothing here is about scrolling.
  List<Object> card({int base = 1789400000}) => [
        for (var i = 1; i <= 5; i++)
          {
            'path': '/DCIM/100YICAM/P915000$i.JPG',
            'date': '${base + i}',
            'filetype': 'picture',
            'protectStatus': false,
          },
      ];

  AppState appWith(List<Object> listing) => AppState(
        ble: FakeBleTransport(),
        sink: NullAssetSink(),
        testPreviewRunning: true,
        testAlbumDownload: camera.download,
        testOnboardingPrefs:
            OnboardingPrefs(store: MemoryPrefsStore())..setSyncMode('manualOnly'),
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
            // Paged like the firmware: `range_start`/`range_end` are 1-based and a page
            // shorter than 60 is the end-of-album signal.
            final start = int.tryParse('${params['range_start']}') ?? 1;
            final end = int.tryParse('${params['range_end']}') ?? start;
            final from = (start - 1).clamp(0, listing.length);
            final to = end.clamp(0, listing.length);
            final page =
                from >= to ? const <Object>[] : listing.sublist(from, to);
            return CameraResponse(
              code: 200,
              data: page,
              raw: '{"code":200,"data":[...${page.length} of ${listing.length}]}',
            );
          }
          return const CameraResponse(
              code: 200, data: 'ok', raw: '{"code":200,"data":"ok"}');
        }),
      );

  // ------------------------------------------------------------------- observing

  /// Pump real time until [done], with an early exit.
  ///
  /// `runAsync` is not optional anywhere in this file: the page reads a real ledger, and
  /// the cache reads and writes real files, and a widget test's fake-async zone never
  /// completes either (`analysis/44` §7).
  Future<bool> pumpUntil(WidgetTester tester, bool Function() done,
      {int maxFrames = 250}) async {
    for (var i = 0; i < maxFrames; i++) {
      if (done()) return true;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    return done();
  }

  Iterable<String> tileIds(WidgetTester tester) => tester
      .widgetList(find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('album-tile-')))
      .map((w) => (w.key! as ValueKey<String>).value);

  Finder tileFor(String path) => find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('album-tile-$path|'),
      description: 'the album tile for $path');

  int imagesInTile(WidgetTester tester, String path) => tester
      .widgetList(find.descendant(of: tileFor(path), matching: find.byType(Image)))
      .length;

  int spinnersInTile(WidgetTester tester, String path) => tester
      .widgetList(find.descendant(
          of: tileFor(path), matching: find.byType(CircularProgressIndicator)))
      .length;

  /// How many entries the phone is holding, seen from the file system.
  ///
  /// Deliberately outside the app's own API: the claim under test is "the pictures are
  /// **on the phone**", so the check looks where the phone would. The directory name is
  /// spelled out here rather than imported, so moving the cache is a failing check
  /// rather than a silent one.
  int cacheEntriesOnDisk() {
    final dir = Directory('${tmp.path}${Platform.pathSeparator}album_thumbs');
    if (!dir.existsSync()) return 0;
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.bin'))
        .length;
  }

  // --------------------------------------------------------------------- acting

  /// Open the album and wait until the grid stops claiming to be loading.
  ///
  /// ## Why "no requests reached the camera" cannot be the signal
  ///
  /// On a visit served from the cache the camera is never asked, so a quiet-request
  /// heuristic declares the page finished **before it has read anything** — and a check
  /// built on that reports "the cache did not work" when what actually happened is that
  /// it was never waited for. (This file was written that way first, and that is how it
  /// failed.) What the user can see is the grid: every tile stops spinning, whether it
  /// ended up with a picture or with the "no picture" icon. That is the condition.
  Future<void> visit(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(localizedApp(
      AlbumPage(app: app),
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    ));
    await pumpUntil(tester, () {
      final ids = tileIds(tester).toList();
      if (ids.isEmpty) return false;
      return ids.every((id) => tester
          .widgetList(find.descendant(
              of: find.byKey(ValueKey<String>(id)),
              matching: find.byType(CircularProgressIndicator)))
          .isEmpty);
    });
    expect(app.album, isNotNull,
        reason: 'the injected link is not ready, so the page cannot list anything');
  }

  /// Leave the album, **unmounting the page**.
  ///
  /// Pumping another `AlbumPage` would not do it: the framework reuses the `State` when
  /// the widget's type and key match, so the map being tested would still be there and
  /// nothing would be measured. A different widget type disposes the page, which is what
  /// switching tabs does.
  Future<void> leave(WidgetTester tester) async {
    await tester
        .pumpWidget(localizedApp(const Scaffold(body: SizedBox.shrink())));
    await tester.pump();
  }

  /// Wait until the pictures the first visit painted have landed on the phone.
  ///
  /// ## Why this is measured rather than assumed
  ///
  /// `_pumpThumbs` paints a tile **before** it writes the entry — the `setState` is what
  /// the user sees, and the write follows it — so "the grid is painted" does not mean
  /// "it is on the phone yet". Leaving the album inside that window and coming back
  /// would measure a race rather than the cache. Every check below therefore states its
  /// premise: the first visit's writes have landed.
  Future<bool> waitUntilOnDisk(WidgetTester tester, int atLeast) =>
      pumpUntil(tester, () => cacheEntriesOnDisk() >= atLeast);

  /// Assert the premise, so a failure below is about the cache and not about timing.
  Future<void> expectWritesLanded(
      WidgetTester tester, List<String> paths) async {
    final landed = await waitUntilOnDisk(tester, paths.length);
    expect(landed, isTrue,
        reason: 'the first visit painted ${paths.length} tile(s) but only '
            '${cacheEntriesOnDisk()} entry/entries reached the cache directory, so '
            'nothing below is measuring the cache');
  }

  /// Every tile that had a picture must still have one.
  ///
  /// Named per shot rather than counted: "three tiles have no picture" is not a report
  /// anybody can act on.
  void expectEveryTileHasAPicture(
      WidgetTester tester, Iterable<String> paths, String when) {
    final offenders = [
      for (final p in paths)
        if (imagesInTile(tester, p) != 1)
          '$p is ${spinnersInTile(tester, p) > 0 ? 'spinning' : 'without a picture'}',
    ];
    expect(offenders, isEmpty,
        reason: 'tiles $when have no picture. Asked the camera for: ${camera.asked}');
  }

  // ----------------------------------------------------------------- the checks

  testWidgets('a second visit to the album asks the camera for no thumbnails at all',
      (tester) async {
    final app = appWith(card());
    addTearDown(app.dispose);
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await visit(tester, app);

    // ## Preconditions, asserted rather than assumed
    //
    // The check is "the second visit asks for **no** thumbnails", which is vacuously
    // true if the first visit asked for none either. So what the first visit did is
    // measured first, and the second visit is compared against it.
    expect(camera.asked, isNotEmpty,
        reason: 'the first visit fetched nothing at all, so "the second visit fetched '
            'nothing" would pass for the wrong reason');
    final firstVisit = camera.asked.length;
    final paths = camera.asked.map((a) => a.split('@').first).toSet().toList();
    expect(paths.length, greaterThanOrEqualTo(3),
        reason: 'only ${paths.length} tile(s) were fetched, too few to tell "the cache '
            'served them" from "the grid only drew one tile"');
    expectEveryTileHasAPicture(tester, paths, 'on the first visit');
    await expectWritesLanded(tester, paths);

    await leave(tester);
    await visit(tester, app);

    expect(
        camera.asked.length,
        firstVisit,
        reason: 'opening the album a second time asked the camera for '
            '${camera.asked.sublist(firstVisit)} — the reported "every time I open the '
            'album the thumbnails reload", against a single-threaded camera with no '
            'watchdog that is streaming the preview at the same time');
    expectEveryTileHasAPicture(tester, paths, 'on the second visit');
  });

  testWidgets(
      'the second visit draws the pictures even when the camera refuses to answer',
      (tester) async {
    // ## Why the camera is switched off
    //
    // "The second visit asked for nothing" is not the same claim as "the second visit
    // had the pictures". A grid that asked for nothing and drew nothing satisfies the
    // first and fails the user. Refusing every request on the second visit separates
    // them: the only place these bytes can come from is the phone.
    final app = appWith(card());
    addTearDown(app.dispose);
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await visit(tester, app);
    expect(camera.asked, isNotEmpty,
        reason: 'the first visit fetched nothing, so there is nothing to have kept');
    final paths = camera.asked.map((a) => a.split('@').first).toSet().toList();
    expectEveryTileHasAPicture(tester, paths, 'on the first visit');
    await expectWritesLanded(tester, paths);

    camera.answering = false;
    await leave(tester);
    await visit(tester, app);

    expectEveryTileHasAPicture(
        tester, paths, 'on a second visit with the camera refusing every request');
  });

  testWidgets(
      'the pictures outlive the app object, so a fresh connect does not refetch',
      (tester) async {
    // The maintainer's words are "every time I **connect** the camera and open the
    // album". A cache that only survives leaving the tab does not answer that: a
    // reconnect builds a new `CameraAlbum`, and an app restart builds a new `AppState`
    // as well. So the second visit here is a **new `AppState`** over the same phone —
    // and its camera is silent, so a request would also be a failure.
    final first = appWith(card());
    addTearDown(first.dispose);
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await visit(tester, first);
    expect(camera.asked, isNotEmpty,
        reason: 'nothing was fetched on the first connect');
    final paths = camera.asked.map((a) => a.split('@').first).toSet().toList();
    await expectWritesLanded(tester, paths);
    await leave(tester);

    // A fresh session: same phone, same card, camera not answering.
    camera.reset();
    camera.answering = false;
    final second = appWith(card());
    addTearDown(second.dispose);
    await visit(tester, second);

    expect(camera.asked, isEmpty,
        reason: 'a new session asked the camera for ${camera.asked} — the thumbnails '
            'did not survive the app object that fetched them');
    expectEveryTileHasAPicture(
        tester, paths, 'on a fresh session with no camera answering');
  });

  testWidgets('a failure is not cached: a tile that failed once is asked for again',
      (tester) async {
    // ## The half of the cache that must **not** exist
    //
    // A `.DNG` or a video can genuinely have no thumbnail (`analysis/70` §7), and the
    // tile has to say so rather than spin. But "this file has no thumbnail" and "this
    // request failed" are different facts, and only the first is a property of the
    // file: a transient refusal remembered on disk is a blank tile that no amount of
    // reloading fixes.
    //
    // This check is a **guard against over-reach**, not failing-first evidence: on the
    // tree before the cache existed there was nothing that could be sticky, so it passes
    // there too. The round's report says so rather than counting it as evidence.
    final app = appWith(card());
    addTearDown(app.dispose);
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    camera.answering = false;
    await visit(tester, app);

    expect(camera.asked, isNotEmpty,
        reason: 'the page never tried, so nothing here is about a failure');
    final paths = camera.asked.map((a) => a.split('@').first).toSet().toList();
    expect(find.byIcon(Icons.image_not_supported_outlined), findsWidgets,
        reason: 'the tiles did not report the refusal, so the state under test is not '
            'the one being checked');
    expect(cacheEntriesOnDisk(), 0,
        reason: 'a refused fetch wrote ${cacheEntriesOnDisk()} entry/entries: absence '
            'was cached, which is the "one transient failure becomes a permanently '
            'blank tile" case');

    camera.answering = true;
    final afterFailure = camera.asked.length;
    await leave(tester);
    await visit(tester, app);

    expect(camera.asked.length, greaterThan(afterFailure),
        reason: 'the camera was never asked again for a tile that had failed: a '
            'transient failure was remembered as "this file has no thumbnail"');
    expectEveryTileHasAPicture(
        tester, paths, 'after the camera started answering again');
  });

  testWidgets('the cache is keyed by the shot, so a re-shot card is fetched again',
      (tester) async {
    // ## What invalidates an entry
    //
    // The key is the shot's own identity — `path` plus the capture **second** — which is
    // the same pair the grid's tiles are keyed by. A file re-shot to the same name has a
    // new second, so it is a different shot and the old picture must not be served for
    // it. A cache keyed on the path alone would show the previous photo under the new
    // name, which is the one failure a cache must never have.
    final first = appWith(card());
    addTearDown(first.dispose);
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await visit(tester, first);
    expect(camera.asked, isNotEmpty, reason: 'nothing was fetched on the first visit');
    await expectWritesLanded(
        tester, camera.asked.map((a) => a.split('@').first).toSet().toList());
    await leave(tester);

    camera.reset();
    // The same five names, re-shot: same paths, **new** capture times.
    final second = appWith(card(base: 1789500000));
    addTearDown(second.dispose);
    await visit(tester, second);

    expect(camera.asked, isNotEmpty,
        reason: 'the same five paths with new capture times were served from the cache: '
            'the key does not carry the date, so a re-shot file would show the old '
            'picture');
  });
}

/// A camera that records every `GetFile` and can stop answering.
class _RecordingCamera {
  final List<String> asked = [];

  /// False is "the camera refuses every rendition" — a 500, which is what a transient
  /// failure looks like at the album's seam.
  bool answering = true;

  void reset() {
    asked.clear();
    answering = true;
  }

  Future<Uint8List> download(AlbumFile file, FileResolution resolution) async {
    asked.add('${file.path}@${resolution.wire}');
    if (!answering) {
      throw const AlbumException('HTTP 500 downloading', 500);
    }
    return fakeVerificationImage();
  }
}
