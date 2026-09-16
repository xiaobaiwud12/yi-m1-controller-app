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
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';

/// The **end of a paged listing**: every tile the user scrolls to must end up with a
/// thumbnail, the last page included.
///
/// ## What this is for
///
/// Reported from the phone after the round that fixed the 81-of-99 blank tiles
/// (`analysis/70` §9): **the oldest few still never load**. "Oldest" is now the *last*
/// tiles of the grid, because that same round sorted the album newest-first — and the
/// listing is **paged**, so the last tiles arrive from the last `GetFileList` page.
///
/// `album_thumbnails_test.dart` already proves that a tile past the eighteenth gets its
/// thumbnail when it scrolls into view. It cannot see this defect, and the reason is
/// worth writing down: it scrolls on a **2400dp** window, and the defect is invisible
/// on one — the precondition below carries the measurement. The short version is that the grid's
/// scroll handler reads the viewport's **main-axis** extent where it needs the
/// **cross-axis** one, so the window of tiles it asks for is scaled by the grid's
/// height instead of its width. On a tall window that error makes it ask for *more*
/// than it needs and everything looks fine; on a phone it asks for *less*, and the
/// tiles past the end of the last full window are never asked for at all.
///
/// ## What is asserted
///
/// Not "the code called a function": **which tiles are on screen at the bottom of the
/// card, and whether they have a picture**. Every mounted tile is named individually,
/// so a failure says which shots are missing rather than that something is wrong.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_last_page_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS
    }
  });

  /// Every request the album made, in order — the evidence for *what was never asked
  /// for*, which is the whole defect.
  final asked = <String>[];

  setUp(asked.clear);

  /// A card long enough to need **several pages**, shaped like the one that was
  /// measured: `analysis/61` §8 found 99 files listed from `P9150040` and wrapping to
  /// `P9150039`, i.e. a ring rather than a sequence.
  ///
  /// 130 rather than 99 so the listing is **three** pages (60, 60, 10) and the last one
  /// is short — which is what the firmware uses as its end-of-album signal, and what
  /// makes "the last page" a specific, small group of tiles rather than most of the
  /// card. Its ten entries sort to the **last ten tiles of the grid**, which is where
  /// the maintainer sees the missing thumbnails.
  List<Object> ringCard() {
    const count = 130;
    const start = 40;
    String name(int n) => 'P915${n.toString().padLeft(4, '0')}.JPG';
    int shot(int i) => (start - 1 + i) % count + 1; // 40, 41, … 130, 1, 2, … 39
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

  /// The last tile the grid draws: the oldest entry of the last page.
  ///
  /// The page sorts each `GetFileList` page newest-first and appends it, so within one
  /// page the oldest entry ends up last — and the last page is the last group of tiles.
  String lastTilePath(List<Object> card) {
    final lastPage = card.sublist(120);
    final oldest = lastPage.reduce((a, b) =>
        int.parse('${(a as Map)['date']}') <= int.parse('${(b as Map)['date']}')
            ? a
            : b);
    return '${(oldest as Map)['path']}';
  }

  AppState appWith(
    Future<Uint8List> Function(AlbumFile, FileResolution) download, {
    required List<Object> listing,
  }) {
    return AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testPreviewRunning: true,
      testAlbumDownload: (file, resolution) {
        asked.add('${file.path}@${resolution.wire}');
        return download(file, resolution);
      },
      // **Manual mode on purpose.** In an auto mode browsing the card queues every
      // listed shot (`sync.enqueueBrowsed`), and the sync bar then draws that queue.
      // That used to squeeze the grid to a couple of rows — measured: an unbounded
      // summary row took **656dp of a 671dp body in English, leaving the grid 15dp** —
      // which is a real defect and is now **fixed** (`album_sync_bar_height_test.dart`
      // is the check that runs in the automatic mode and measures the grid's rect).
      // This fixture still picks manual mode for a different reason: its subject is the
      // thumbnail window at the end of a paged listing, and a bar that does not move
      // keeps those numbers stable.
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
          // Paged like the firmware: `range_start`/`range_end` are **1-based**, a page
          // shorter than 60 is the end-of-album signal. A fake that returned the whole
          // card at once would make the paging path and the end-of-list behaviour
          // untestable — which is exactly where this defect lives.
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
  }

  /// Pump real time until the album has stopped working.
  ///
  /// A fixed number of frames was the wrong answer here: the fetch is one serial loop
  /// over however many tiles the scroll brought into view, and on a 130-tile card that
  /// number is not a constant. Polling with an early exit keeps the check from passing
  /// or failing on how long the harness happened to wait (`AGENTS.md` §5, "等待要短，
  /// 且要能提前结束").
  ///
  /// ## Why "no new requests" is not enough on its own (since `analysis/77`)
  ///
  /// Requests going quiet says nothing about **local** work, and each tile now costs a
  /// cache read and, on a miss, a cache write — real file I/O. Between two requests a
  /// write can easily be in flight, so a request-only quiet window declares the page
  /// finished while the loop is still mid-tile. The condition therefore also requires
  /// what the user can see: every mounted tile has stopped spinning. The mounted-tile
  /// floor matters too — before the first listing arrives there are no tiles at all, and
  /// "nothing is spinning" would be true of an empty screen.
  Future<void> settleUntilQuiet(WidgetTester tester,
      {int maxFrames = 2000, int quietFrames = 4}) async {
    final tiles = find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('album-tile-'));
    var last = -1;
    var quiet = 0;
    for (var i = 0; i < maxFrames; i++) {
      final mounted = tester.widgetList(tiles).length;
      final spinning = tester
          .widgetList(find.descendant(
              of: tiles, matching: find.byType(CircularProgressIndicator)))
          .length;
      if (mounted > 0 && spinning == 0 && asked.length == last) {
        quiet++;
        if (quiet >= quietFrames) return;
      } else {
        quiet = 0;
        last = asked.length;
      }
      // One **event-loop turn**, not a sleep — see `album_thumbnails_test.dart`'s
      // `settleTiles`: the real loop has to deliver the file-I/O completions, and a
      // non-zero delay also waits for the platform timer tick. Measured on this machine:
      // these two files took ~40 s with a 1 ms turn and ~20 s with a zero-duration one.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
  }

  /// Pump the album on the maintainer's phone, and until its fetches go quiet.
  ///
  /// `runAsync` is not optional: the page awaits the durable ledger, which is real file
  /// I/O, and a widget test's fake-async zone never completes it (`analysis/44` §7).
  Future<void> pumpAlbum(WidgetTester tester, AppState app) async {
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AlbumPage(app: app),
    ));
    await settleUntilQuiet(tester);
    expect(app.album, isNotNull,
        reason: 'the injected link is not ready, so the page cannot list anything');
  }

  Finder tile(String path) => find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('album-tile-$path|'),
      description: 'the album tile for $path');

  int imagesInTile(WidgetTester tester, String path) => tester
      .widgetList(find.descendant(of: tile(path), matching: find.byType(Image)))
      .length;

  /// Every mounted tile and what it is drawing, as `path -> state`.
  ///
  /// Keyed by path rather than counted, because "three tiles have no picture" is not a
  /// report anybody can act on; "`P9150030.JPG` is still spinning" is.
  Map<String, String> tileStates(WidgetTester tester) {
    final out = <String, String>{};
    for (final e in find
        .byWidgetPredicate((w) => w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('album-tile-'))
        .evaluate()) {
      final key = (e.widget.key! as ValueKey<String>).value;
      final path = key.substring('album-tile-'.length).split('|').first;
      final found = find.byKey(ValueKey<String>(key));
      final img = tester
          .widgetList(find.descendant(of: found, matching: find.byType(Image)))
          .length;
      final spin = tester
          .widgetList(find.descendant(
              of: found, matching: find.byType(CircularProgressIndicator)))
          .length;
      final refused = tester
          .widgetList(find.descendant(
              of: found,
              matching: find.byIcon(Icons.image_not_supported_outlined)))
          .length;
      out[path] =
          img > 0 ? 'has a picture' : (spin > 0 ? 'spinning' : (refused > 0 ? 'refused' : 'blank'));
    }
    return out;
  }

  /// Every tile on screen must have a picture — asserted **after** the fetches have
  /// gone quiet, so "still loading" is not an excuse.
  void expectEveryTileOnScreenHasAPicture(WidgetTester tester, String when) {
    final offenders = [
      for (final e in tileStates(tester).entries)
        if (e.value != 'has a picture') '${e.key} is ${e.value}',
    ];
    expect(offenders, isEmpty,
        reason: 'tiles on screen $when have no thumbnail. Asked for so far: '
            '${asked.length} request(s); never asked: '
            '${tileStates(tester).keys.where((p) => !asked.any((a) => a.startsWith('$p@'))).toList()}');
  }

  testWidgets(
      'every tile that comes into view on a paged card ends up with a thumbnail, '
      'the last page included', (tester) async {
    final card = ringCard();
    final app = appWith(fakeCameraThumbnail, listing: card);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    // ## Preconditions, asserted rather than assumed
    //
    // 1. The listing has to be longer than the leading window the page fetches on
    //    load, or "scrolled into view" is not a different region from "on screen at
    //    startup" and this check measures nothing.
    final grid = tester.widget<GridView>(find.byType(GridView));
    final tiles = grid.childrenDelegate.estimatedChildCount ?? 0;
    expect(tiles, greaterThan(24),
        reason: 'only $tiles tile(s) are listed, so nothing here is off screen');

    // 2. The grid has to be a phone's grid and **not a tall one**. This is not a
    //    style preference: the page's scroll handler scales its window by the
    //    viewport's main-axis extent where it needs the cross-axis one, and the sign
    //    of that error depends on the grid's shape. Measured both ways on this
    //    fixture — at 490dp tall the page asks for tiles 102..121 of 130 while the
    //    screen is showing 123..129, and at 1688dp tall the same error makes it ask
    //    for 0..190 and every tile is fetched. So a tall window turns this check
    //    **green against the defect**, which is worse than not having it
    //    (`AGENTS.md` §8). The band is asserted so that a future layout change that
    //    pushes the grid out of it fails loudly instead of passing quietly.
    final gridBox = tester.getSize(find.byType(GridView));
    expect(gridBox.height, greaterThan(150),
        reason: 'the grid is ${gridBox.height}dp tall — nothing is off screen');
    expect(gridBox.height, lessThan(540),
        reason: 'a ${gridBox.height}dp grid makes the misscaled window overshoot '
            'instead of trail, so this check cannot see the defect it exists for; '
            'if the grid legitimately grew this tall, re-measure the fixture');

    final scrollable = find.descendant(
        of: find.byType(GridView), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'the grid cannot scroll, so no tile is out of view');

    // Everything on the first screen is fetched — that is what the previous round
    // fixed, and a regression there is a different failure this check would otherwise
    // report as "the last page".
    expectEveryTileOnScreenHasAPicture(tester, 'on load');

    final lastTile = lastTilePath(card);
    expect(asked.where((a) => a.startsWith('$lastTile@')), isEmpty,
        reason: 'precondition: the last tile of the card was already fetched, so '
            'scrolling to it cannot show anything');

    // ## Scroll to the end of the card, the way a user does
    //
    // Repeated drags with the fetches settled in between, and to the **true** bottom
    // including the pages that arrive while scrolling: the trigger to load the next
    // page is "within 600dp of the end", so the last page's entries appear partway
    // through and the grid keeps growing under the drag.
    var rounds = 0;
    for (; rounds < 40; rounds++) {
      final at = tester.state<ScrollableState>(scrollable).position;
      if (at.pixels >= at.maxScrollExtent - 0.5) break;
      await tester.drag(find.byType(GridView), const Offset(0, -700));
      await tester.pump();
      await settleUntilQuiet(tester, maxFrames: 12, quietFrames: 3);
    }
    await settleUntilQuiet(tester);
    expect(rounds, lessThan(40), reason: 'the grid never reached its end');

    final at = tester.state<ScrollableState>(scrollable).position;
    expect(at.pixels, greaterThan(at.maxScrollExtent - 1),
        reason: 'the check did not actually reach the bottom of the card, so the '
            'last page is not on screen and nothing below is measured');

    // The listing really did take several pages, and the last of them really did
    // arrive: without this the check could pass by never asking for the last page.
    expect(
        tester
            .widget<GridView>(find.byType(GridView))
            .childrenDelegate
            .estimatedChildCount,
        card.length,
        reason: 'the grid is not holding the whole card, so the last page never '
            'arrived and nothing below is measured');
    expect(tile(lastTile), findsOneWidget,
        reason: 'the last entry of the last page is not even drawn');

    // ## The assertion, 1: everything the user is looking at
    //
    // This is the reported symptom. On a phone the bottom of the card shows the last
    // page's tiles, and they spin forever.
    expectEveryTileOnScreenHasAPicture(tester, 'at the bottom of the card');
    expect(imagesInTile(tester, lastTile), 1,
        reason: 'the last shot on the card has no thumbnail: the grid never asked '
            'the camera for $lastTile. Asked for: ${asked.length} rendition(s)');

    // ## The assertion, 2: everything on the way back up
    //
    // A tile that came into view during the drag and was never asked for would be
    // missed by the check above — it is off screen by then. Scrolling back through the
    // whole card visits every tile again and requires each of them to be settled.
    for (var r = 0; r < 40; r++) {
      await settleUntilQuiet(tester, maxFrames: 12, quietFrames: 3);
      final p = tester.state<ScrollableState>(scrollable).position;
      if (p.pixels <= 0.5) break;
      expectEveryTileOnScreenHasAPicture(tester, 'at ${p.pixels.round()}dp on the '
          'way back up');
      await tester.drag(find.byType(GridView), const Offset(0, 700));
      await tester.pump();
    }
    await settleUntilQuiet(tester);
    expectEveryTileOnScreenHasAPicture(tester, 'back at the top');
  });
}
