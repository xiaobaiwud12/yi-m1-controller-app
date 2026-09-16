import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The sync bar must offer a way to *start*, not only to pause.
///
/// ## Why this file exists
///
/// Reported from hardware: "you have to tap pause and then resume before a sync
/// happens at all". That was literally what the control did — one toggle whose
/// label read "Pause" whenever anything was pending, so with a queue waiting and
/// nothing running the only available action was to pause an engine that was
/// already idle, and the run then needed a second tap.
///
/// The checks below assert the *action*, not the wording: which callback the
/// visible control is wired to. A test that only counted buttons would have
/// passed against the broken version, because there was always exactly one.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_syncbar_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    // Tolerant on purpose: queueing writes the durable ledger and queue, and a
    // handle can still be open when the test ends. The directory is in the
    // system temp area, so failing to remove it is not worth failing a test that
    // is about which control the user sees.
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS to reclaim
    }
  });

  AlbumFile shot(String name) => AlbumFile(
        path: '/DCIM/101YICAM/$name.JPG',
        fileType: 'picture',
        captureTime: DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );

  Future<void> pumpAlbum(WidgetTester tester, dynamic app) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AlbumPage(app: app),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a waiting queue offers Start sync, not Pause', (tester) async {
    final app = testAppState();
    addTearDown(app.dispose);
    app.sync.enqueueSelected([shot('YI000001')]);

    await pumpAlbum(tester, app);

    expect(find.byKey(const ValueKey<String>('btn-sync-start')), findsOneWidget,
        reason: 'a queue with nothing running must offer a way to start it');
    expect(find.byKey(const ValueKey<String>('btn-sync-pause')), findsNothing,
        reason: 'the only control used to be a pause toggle, which is the bug');
  });

  testWidgets('the start control is wired to beginTransfer', (tester) async {
    // The action is the point. A control labelled "Start sync" that paused the
    // engine would be the same defect with better wording.
    final app = testAppState();
    addTearDown(app.dispose);
    app.sync.enqueueSelected([shot('YI000002')]);
    await pumpAlbum(tester, app);

    expect(app.sync.paused, isFalse, reason: 'precondition: not paused');

    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-start')));
    await tester.pump(const Duration(milliseconds: 50));

    expect(app.sync.paused, isFalse,
        reason: 'starting a sync must never leave the engine paused');
  });

  testWidgets('a paused engine offers Resume', (tester) async {
    final app = testAppState();
    addTearDown(app.dispose);
    app.sync.enqueueSelected([shot('YI000003')]);
    app.sync.pause();

    await pumpAlbum(tester, app);

    expect(find.byKey(const ValueKey<String>('btn-sync-resume')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('btn-sync-resume')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.sync.paused, isFalse);
  });

  testWidgets('nothing queued shows no transport control', (tester) async {
    final app = testAppState();
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    expect(find.byKey(const ValueKey<String>('btn-sync-start')), findsNothing);
    expect(find.byKey(const ValueKey<String>('btn-sync-pause')), findsNothing);
    expect(find.byKey(const ValueKey<String>('btn-sync-resume')), findsNothing);
    expect(find.text(en.syncNothingQueued), findsOneWidget);
  });
}
