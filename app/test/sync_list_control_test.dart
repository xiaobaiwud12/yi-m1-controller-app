import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/sync_engine.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The sync list can be **seen**, and entries can be **removed**.
///
/// ## Why these checks exist
///
/// The reported defect was that the sync bar offered Pause, Resume, Start and a mode
/// selector and nothing else: no way to see what was queued, no way to drop one shot,
/// no way to empty the list. On a link where a full-size photo is ~5 MB and a RAW is
/// ~32 MB, a queue can hold hundreds of megabytes that the user agreed to by tapping
/// a mode and then browsing — with a single summary line ("Start sync (312 photos)")
/// as the only statement about it.
///
/// ## Why the assertions are about the engine, not about the wording
///
/// A control that *looks* like it cancels is the failure mode worth catching. So the
/// checks read `queue.length` and `pendingCount` after the tap, and they also assert
/// that **no command reached the camera** — cancelling a transfer is not permission to
/// start one (`AGENTS.md` §4.6), and a list view that refreshed itself with a
/// `GetFileList` would be a second request competing with the preview.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_synclist_');
    useTempStorage(tmp.path);
    // The grid's thumbnails come from the fake camera fixture, which is a JPEG
    // because that is what the consumer checks. `ui_smoke_test.dart` explains why.
    useMediaChannel(bytes: jpegFixture, reads: []);
  });

  tearDown(() {
    // Tolerant on purpose: queueing writes the real ledger and queue files, and a
    // handle can still be open when the test ends.
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS to reclaim
    }
  });

  AlbumFile shot(String name, {int date = 1700000000}) => AlbumFile(
        path: '/DCIM/101YICAM/$name.JPG',
        fileType: 'picture',
        captureTime: DateTime.fromMillisecondsSinceEpoch(date * 1000),
      );

  /// The album page, with real file I/O allowed to finish — **polled, not budgeted**.
  ///
  /// `runAsync` is not optional here: the page awaits the durable ledger before its
  /// first listing, that ledger is read from **real files**, and in a widget test's
  /// fake-async zone the read never completes — the page then sits on its spinner and
  /// every assertion below would fail looking like a missing control
  /// (`analysis/41` §7 item 9).
  ///
  /// ## Why this waits for a state instead of eight rounds of 40 ms
  ///
  /// It used to run a fixed `for (i = 0; i < 8; i++)` loop, and **that budget was what
  /// the checks below rested on**. Measured, with the loop cut to four rounds or fewer
  /// the page has not asked the camera for a listing at all — `GetFileList` never
  /// reaches the injected client — and `app.sync.pendingCount` is 2 instead of 5: the
  /// two shots this test queued itself, with none of the three the listing adds.
  /// Reading the ledger and the queue is real file I/O gated inside `runAsync`, so on a
  /// loaded machine eight rounds of 40 ms is a coin flip. That is this file's recorded
  /// flake: *"expecting a five-item queue and finding two"* (`AGENTS.md` §8); the
  /// fixture was not wrong about the queue, it was wrong about how long the launch path
  /// takes.
  ///
  /// So it now waits for the **state the assertions need** and exits the moment it
  /// arrives — `AGENTS.md` §5's rule (poll, exit early, never sleep a fixed time).
  /// [commands] is the recorder the caller already hands `connectedTestAppState`; it is
  /// a wait predicate from an independent source (the protocol spy), never an
  /// assertion, so the counts below stay statements about the queue rather than about
  /// the fixture.
  ///
  /// Measured on the round the request appears, the queue has already been updated
  /// (2 → 5 in the same iteration), but the loop keeps polling until both halves hold
  /// rather than trusting that ordering under load. Running out of rounds is a failure
  /// with its own name, not a longer wait: a listing that never lands would otherwise
  /// be reported as a wrong count, which reads like a queue bug.
  Future<void> pumpAlbum(
    WidgetTester tester,
    AppState app, {
    required List<String> commands,
  }) async {
    final queuedByTheTest = app.sync.pendingCount;
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AlbumPage(app: app),
    ));
    var settled = false;
    for (var i = 0; i < 100; i++) {
      settled = commands.contains('GetFileList') &&
          app.sync.pendingCount > queuedByTheTest;
      if (settled) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(settled, isTrue,
        reason: 'the card was never listed, so nothing below is measured against the '
            'state it describes: the page asks only after `AppState._load()` has read '
            'the ledger and the queue from disk, and that is real file I/O, which '
            'progresses only inside `runAsync`. '
            'listed=${commands.contains('GetFileList')} '
            'pending=${app.sync.pendingCount} (was $queuedByTheTest before the pump)');
  }

  testWidgets('the media fixtures really are the formats their consumers expect',
      (tester) async {
    // A fixture that is the wrong format does not fail loudly: it makes **other** checks
    // quietly stop meaning anything. So the fixtures' own formats are asserted here
    // rather than assumed.
    expect(looksLikePng(onePixelPng), isTrue,
        reason: 'the thumbnail fixture must still be a PNG');
    expect(looksLikeJpeg(jpegFixture), isTrue,
        reason: 'the sync fixture must still be a JPEG — the engine checks for EOI');
    expect(jpegFixture.length, greaterThan(4));
  });

  testWidgets('the queue can be listed, and one entry removed', (tester) async {
    final commands = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);
    // The injected camera answers `GetFileList` with three photos, and the page queues
    // them because the default mode is automatic — so the queue is those three plus
    // the two named below. Stating that here is the point: a check that assumed two
    // would be reading a number it had not accounted for.
    app.sync.enqueueSelected([shot('YI000501'), shot('YI000502', date: 1700000100)]);
    await pumpAlbum(tester, app, commands: commands);

    // Preconditions, asserted rather than assumed: an empty queue would make every
    // check below pass by having nothing to remove.
    expect(app.sync.pendingCount, 5,
        reason: '3 listed shots plus the 2 queued here');
    expect(find.byKey(const ValueKey<String>('btn-sync-list')), findsOneWidget,
        reason: 'there must be a labelled way into the list');
    expect(find.text(en.syncListCount(5)), findsOneWidget);

    // Closed by default: the list shares a column with the switch and the selector,
    // and in landscape that column's height comes out of the photo grid.
    expect(find.text(en.syncStillToFetch(5)), findsNothing,
        reason: 'the list must not be expanded until it is asked for');

    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-list')));
    await tester.pump();

    expect(find.text(en.syncStillToFetch(5)), findsOneWidget);
    expect(find.text('YI000501.JPG'), findsOneWidget);
    expect(find.text(en.syncHideList), findsOneWidget);

    // The row's cancel control, keyed per shot so a three-hundred-row queue can be
    // addressed rather than only its first match.
    final removeOne = find.byKey(
        const ValueKey<String>('btn-sync-list-remove-/DCIM/101YICAM/YI000501.JPG|1700000000'));
    expect(removeOne, findsOneWidget,
        reason: 'each row needs its own addressable control');

    await tester.tap(removeOne);
    await tester.pump();

    expect(app.sync.pendingCount, 4, reason: 'the tap must really dequeue the shot');
    expect(find.text('YI000501.JPG'), findsNothing);
    expect(find.text('YI000502.JPG'), findsOneWidget,
        reason: 'only the row that was tapped may go');
    // The button reads "Hide list" while the list is open, so the count that has to be
    // checked is the list's own header — the visible consequence of the tap.
    expect(find.text(en.syncStillToFetch(4)), findsOneWidget);
    expect(find.text(en.syncHideList), findsOneWidget);

    // It is not merely gone from the engine: the durable record goes too, or a
    // relaunch would restore work the user just cancelled.
    expect(app.queue.length, 4, reason: 'the durable queue kept the shot');
    expect(
        app.queue.pending.any((r) => r.path.endsWith('YI000501.JPG')), isFalse,
        reason: 'the cancelled shot is still in the durable queue');

    // Reading the list, and cancelling an entry, must not talk to the camera.
    for (final forbidden in const [
      'GetFile',
      'DeleteFile',
      'PauseMovieStream',
      'ResumeMovieStream',
    ]) {
      expect(commands.where((c) => c == forbidden), isEmpty,
          reason: '$forbidden must never be sent by cancelling or listing');
    }
  });

  testWidgets('clearing the list empties it and leaves the camera alone',
      (tester) async {
    final commands = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);
    app.sync.enqueueSelected([
      shot('YI000511'),
      shot('YI000512', date: 1700000100),
      shot('YI000513', date: 1700000200),
    ]);
    await pumpAlbum(tester, app, commands: commands);

    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-list')));
    await tester.pump();
    // 3 from the injected listing plus the 3 above.
    expect(find.text(en.syncStillToFetch(6)), findsOneWidget);

    final clear = find.byKey(const ValueKey<String>('btn-sync-list-clear'));
    expect(clear, findsOneWidget);
    await tester.tap(clear);
    await tester.pump();

    expect(app.sync.pendingCount, 0, reason: 'clear must empty the job list');
    expect(app.sync.items, isEmpty);
    expect(app.queue.isEmpty, isTrue, reason: 'the durable queue must empty too');
    expect(find.text(en.syncNothingLeftToFetch), findsOneWidget);

    expect(commands.where((c) => c == 'DeleteFile'), isEmpty,
        reason: 'clearing the sync list deletes nothing on the camera');
    expect(commands.where((c) => c == 'GetFile'), isEmpty);
  });

  testWidgets('the list starts closed and survives progress ticks', (tester) async {
    final commands = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app, commands: commands);
    // The injected listing queues three photos in the default automatic mode.
    expect(app.sync.pendingCount, 3, reason: 'precondition: the listing is queued');

    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-list')));
    await tester.pump();
    expect(find.text(en.syncStillToFetch(3)), findsOneWidget);

    // The engine calls `onChanged` on every stage change, and the page rebuilds from
    // it. A list that snapped shut on the next progress tick would be a control the
    // user cannot use during the one moment it matters most.
    app.sync.items.first.stage = SyncStage.downloadingOriginal;
    app.sync.items.first.bytesReceived = 4096;
    app.sync.onChanged?.call();
    await tester.pump();

    expect(find.text(en.syncStillToFetch(3)), findsOneWidget,
        reason: 'the list must not collapse when the engine reports progress');

    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-list')));
    await tester.pump();
    expect(find.text(en.syncStillToFetch(3)), findsNothing);
  });

  testWidgets('the mode dropdown re-derives the list, not just future work',
      (tester) async {
    // The reported defect, driven through the real control: the mode is what decides
    // whether a preview is fetched before the full size, and switching between the two
    // automatic modes used to leave the list untouched — so it silently meant
    // something other than what the selector above it said. Only *leaving manual* was
    // handled.
    final commands = <String>[];
    final app = connectedTestAppState(onCommand: commands.add);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app, commands: commands);

    expect(app.sync.pendingCount, 3,
        reason: 'precondition: the listed photos are queued for a preview pass');
    expect(find.text(en.syncListCount(3)), findsOneWidget);

    // Open the list first: the assertion below is about what it *says*, and a closed
    // list says nothing at all.
    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-list')));
    await tester.pump();
    expect(find.text(en.syncStillToFetch(3)), findsOneWidget);

    // What the user does: open the dropdown on the sync bar. It is a `DropdownButton`
    // rather than a `PopupMenuButton`, so it opens a menu route instead of a route of
    // its own.
    //
    // Fixed pumps and not `pumpAndSettle`: this page keeps a live
    // `LinearProgressIndicator` for as long as anything is queued, so there is always
    // an animation running and "settle" never arrives.
    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-mode')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text(en.syncModeAutoOriginalOnly), findsOneWidget,
        reason: 'the menu did not open, so this check would prove nothing');

    await tester.tap(find.text(en.syncModeAutoOriginalOnly).last);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(app.sync.mode, SyncMode.autoOriginalOnly,
        reason: 'the selector must actually change the mode');

    // Nothing has been fetched yet, so no shot here has a preview on the phone, and
    // "full size only" still has to fetch a first rendition for each of them. The list
    // is therefore **not** emptied by this switch — what it must not do is stay a list
    // of pending *previews*. That distinction is the whole point: the mode describes
    // renditions, and `SyncEngine.reinterpret` is where that is settled (`tool/
    // verify_sync.dart` covers the previewed case, which cannot be produced here without
    // running a sync against a real sink).
    expect(find.text(en.syncStillToFetch(3)), findsOneWidget,
        reason: 'a shot with nothing on the phone is still work in either mode');

    // And the switch must not have sent anything to the camera: re-deriving the list is
    // clockwork, not protocol.
    expect(commands.where((c) => c == 'GetFile'), isEmpty);
    expect(commands.where((c) => c == 'DeleteFile'), isEmpty);
  });
}
