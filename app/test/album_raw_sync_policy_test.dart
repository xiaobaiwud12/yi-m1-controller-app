import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_group.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';

/// **Which files a tap actually queues**, asserted on the page's own call sites.
///
/// ## The defect these exist for
///
/// `transport/album.dart` documents the RAW decision in full: a RAW+JPEG shot is
/// ~32 MB against the JPEG's ~4.9 MB, the phone is on the camera's own access point
/// while it transfers, and *"silently starting to do that is the kind of change that
/// arrives as a data bill. So the capability ships **off**."*
///
/// **Nothing implemented that.** `SyncPlan` — the class that sentence belongs to —
/// was constructed in `tool/verify_transport.dart` and in a test that asserted its own
/// default, and **nowhere in `lib/`**. Every user-facing queue path on this page
/// enqueued `AssetGroup.assets`, which for a `rawJpeg` entry is `[primary, raw!]`. So
/// the documentation said "off" and the queue said "on", and the only check was one
/// that read the same source as the code (`analysis/79`, finding #2).
///
/// ## Why these assert here rather than on `SyncPlan`
///
/// A check on `SyncPlan(skipRaw: …)` re-derives the policy from the source it is
/// checking. `analysis/79`'s header names that shape — *"the check and the code reason
/// twice from the same source of truth, so the two are wrong together"* — and this
/// finding is one of the five that produced it. So each check below drives a real
/// control on the page (a selection, the mode selector, the viewer's save button, the
/// RAW switch) and reads **what ended up in the engine's queue**. `SyncPlan`'s own
/// default is not asserted anywhere in this file; the queue is.
///
/// ## The decision these encode
///
/// RAW transfer **stays off by default** — the documentation was right about the
/// product and wrong only about the implementation — and the opt-in is a real,
/// remembered control (`toggle-sync-raw` in the sync bar, `UiPrefs.includeRaw`), whose
/// label states the cost before it is paid. The third group below is the other half:
/// a shot that carries a RAW says so, and says whether that RAW is still outstanding,
/// which is what `AssetGroup.rawPending` was written for and had no caller for.
///
/// ## What is deliberately *not* asserted
///
/// A shot whose only rendition is a RAW is queued either way. A bare `.DNG` entry is a
/// shutter press with no JPEG to fetch instead, and dropping it would strand that shot
/// where the user could neither see why nor fix it. The switch decides whether a
/// `.DNG` **rides along with its JPEG**, which is the case the 574 MB argument is
/// about.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_rawpolicy_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS
    }
  });

  /// The shape the real 3.1-cn firmware sends for a RAW+JPEG shot (`analysis/50`):
  /// **one** entry per shutter press, `.JPG` path, `filetype: 'rawJpeg'` — the RAW is
  /// derived, not listed, and it is the ~32 MB half.
  const jpeg = '/DCIM/100YICAM/P9140002.JPG';
  const raw = '/DCIM/100YICAM/P9140002.DNG';
  const shotSeconds = 1789391479;

  List<Object> listing() => const [
        {
          'path': jpeg,
          'date': '$shotSeconds',
          'filetype': 'rawJpeg',
          'protectStatus': false,
        },
      ];

  /// The app as it launches: the **default** sync mode (an automatic one), so browsing
  /// this listing queues the shot — that is the state the product is in when the user
  /// taps anything.
  ///
  /// Naming `manualOnly` here would be the workaround that hid the sync-bar height
  /// defect from two earlier checks (`album_sync_bar_height_test.dart` says so in its
  /// own header), and it would hide this one too: in manual mode browsing queues
  /// nothing, so "the tap added the RAW" would have nothing to be measured against.
  ///
  /// [rememberedRaw] puts the opt-in in the **preference file**, the way a relaunch
  /// finds it, rather than flipping the switch afterwards: the automatic modes queue a
  /// card by the act of paging through it, and that path has to honour the switch too
  /// or the switch would be a lie in the one mode the product launches in.
  AppState appWith(List<Object> files, {bool rememberedRaw = false}) {
    final stored = UiPrefs(store: MemorySyncStore());
    stored.setIncludeRaw(rememberedRaw);
    return AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testAlbumDownload: (file, resolution) async => onePixelPng,
      testOnboardingPrefs: OnboardingPrefs(store: MemoryPrefsStore()),
      testUiPrefs: UiPrefs(store: MemorySyncStore(stored.encode())),
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
          // Paged like the firmware: 1-based, 60 a page, and a short page ends the
          // album.
          final start = int.tryParse('${params['range_start']}') ?? 1;
          final end = int.tryParse('${params['range_end']}') ?? start;
          final from = (start - 1).clamp(0, files.length);
          final to = end.clamp(0, files.length);
          final page = from >= to ? const <Object>[] : files.sublist(from, to);
          return CameraResponse(
            code: 200,
            data: page,
            raw: '{"code":200,"data":[...${page.length} of ${files.length}]}',
          );
        }
        return const CameraResponse(
            code: 200, data: 'ok', raw: '{"code":200,"data":"ok"}');
      }),
    );
  }

  /// Pump real time until the album has listed its page and the automatic mode has
  /// queued it.
  ///
  /// `runAsync` is not optional: the page awaits the durable ledger, which is real
  /// file I/O, and a widget test's fake-async zone never completes it — without it the
  /// page sits on its spinner and every assertion below would be about a page with no
  /// tiles (`AGENTS.md` §8).
  Future<void> pumpListed(WidgetTester tester, AppState app) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(localizedApp(AlbumPage(app: app)));
    for (var i = 0; i < 300; i++) {
      if (find.byType(GridView).evaluate().isNotEmpty &&
          app.sync.items.isNotEmpty) {
        break;
      }
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// The paths in the engine's queue, in order — the whole list, so a check fails for
  /// *any* unexpected file rather than only for the one it was written about.
  List<String> queued(AppState app) =>
      [for (final i in app.sync.items) i.file.path];

  Finder tile() => find.byKey(
      const ValueKey<String>('album-tile-$jpeg|$shotSeconds'));

  /// Every check below depends on this: the JPEG is queued and the RAW is not.
  ///
  /// The reason is the whole finding, so it is written out where it fails: 32 MB per
  /// shot against the 9 MB the user's mental model has, over the camera's own access
  /// point, with the phone offline for the duration.
  void expectOnlyTheJpeg(AppState app, String what) {
    expect(queued(app), [jpeg],
        reason: 'after $what the queue holds ${queued(app)}. The documentation this '
            'repo ships says RAW transfer is off by default ("the capability ships '
            'off"), and a tap that queues ${raw.split('/').last} anyway is committing '
            'the user to ~32 MB where they expected ~5 MB — over the camera\'s own '
            'access point, which has no internet passthrough, so the phone is offline '
            'while it runs. Turning it on has to be a choice, not a side effect.');
  }

  group('a tap queues the JPEG it names, not the RAW beside it', () {
    testWidgets('precondition: browsing the listing queues the shot', (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);
      expect(tester.takeException(), isNull);
      expect(tile(), findsOneWidget,
          reason: 'the one listed shot has no tile, so nothing below can be measured');
      expectOnlyTheJpeg(app, 'browsing one rawJpeg entry');
    });

    testWidgets('the selection: Select, tap the shot, Sync', (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      await tester.tap(find.byKey(const ValueKey<String>('btn-album-select')));
      await tester.pump();
      await tester.tap(tile());
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('btn-album-sync-selected')),
          findsOneWidget,
          reason: 'the shot is not selected, so the tap below would do nothing');

      await tester.tap(
          find.byKey(const ValueKey<String>('btn-album-sync-selected')));
      await tester.pump();

      expectOnlyTheJpeg(app, 'selecting the shot and tapping Sync');
    });

    testWidgets('the mode selector: switching to "full size only"', (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      // Fixed pumps and not `pumpAndSettle`: this page keeps a live
      // `LinearProgressIndicator` while anything is queued, so "settle" never
      // arrives.
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

      expectOnlyTheJpeg(app, 'changing the sync mode (which re-derives the list)');
    });

    testWidgets('the viewer: opening the shot and tapping save-to-phone',
        (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      await tester.tap(tile());
      // Long enough for the route transition to finish: a tap taken mid-slide
      // derives an offset outside the window and **silently misses**, which is the
      // "green because it measured nothing" failure this file exists to avoid.
      // `pumpAndSettle` is not available here — the album page underneath keeps a
      // live `LinearProgressIndicator` while anything is queued, so it never settles.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
      }

      final save = find.byKey(const ValueKey<String>('btn-viewer-save-to-phone'));
      expect(save, findsOneWidget,
          reason: 'the viewer did not open, so the tap below would hit the grid');
      await tester.tap(save);
      await tester.pump();
      // Proof the tap landed: without it a miss leaves the queue exactly as the
      // assertion below wants to find it, and the check would pass by doing nothing.
      expect(find.text(en.viewerQueued), findsOneWidget,
          reason: 'the save-to-phone tap did not reach the button');

      expectOnlyTheJpeg(app, 'tapping save-to-phone in the viewer');
    });
  });

  group('the opt-in is reachable, and says what it costs', () {
    testWidgets('the switch is on the sync bar, off, and names its cost',
        (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      final sw = find.byKey(const ValueKey<String>('toggle-sync-raw'));
      expect(sw, findsOneWidget,
          reason: 'the documented policy is only honest if a user can act on it — '
              '"what a user who wants the RAW does" has to have an answer on screen');
      expect(tester.widget<SwitchListTile>(sw).value, isFalse,
          reason: 'the capability ships off, which is what transport/album.dart says');
      expect(find.text(en.syncRawTitle), findsOneWidget);
      expect(en.syncRawTitle, contains('32 MB'),
          reason: 'the cost is in the label rather than only in the note under it, '
              'because the note is dropped on a short screen (landscape) — and this is '
              'the control that must never spend 32 MB a shot without saying so');
    });

    testWidgets('turning it on queues the RAW of the shots already listed',
        (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);
      expectOnlyTheJpeg(app, 'browsing with the opt-in off');

      await tester.tap(find.byKey(const ValueKey<String>('toggle-sync-raw')));
      await tester.pump();

      expect(app.includeRaw, isTrue, reason: 'the switch must write the preference');
      expect(queued(app), [jpeg, raw],
          reason: 'a user who browsed the card, turned the RAW on and pressed start '
              'must not get nothing for it — the switch is the thing that decides what '
              'a sync spends, and a queue built under the old answer would silently '
              'mean something other than what the switch says');
      // Queued is not transferring (§4.6): the snackbar says both, because one tap
      // here can add hundreds of megabytes.
      expect(find.text(en.syncRawQueued(1)), findsOneWidget,
          reason: 'the note that says what was added, and that nothing transfers yet');
    });

    testWidgets('turning it off stops new work and does not cancel the queue',
        (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      await tester.tap(find.byKey(const ValueKey<String>('toggle-sync-raw')));
      await tester.pump();
      expect(queued(app), [jpeg, raw]);

      await tester.tap(find.byKey(const ValueKey<String>('toggle-sync-raw')));
      await tester.pump();
      expect(app.includeRaw, isFalse);
      expect(queued(app), [jpeg, raw],
          reason: 'a selector must not be destructive: what is queued is visible and '
              'cancellable row by row behind List (N), and cancelling it from a switch '
              'is the action SyncEngine.reinterpret argues the mode dropdown must not '
              'take either');
    });

    testWidgets('with the opt-in remembered, paging the card queues the RAW too',
        (tester) async {
      // The relaunch case, and the one the automatic modes live in: browsing is what
      // queues a card, so the switch has to reach *this* path or it would do nothing
      // in the mode the product launches in. The RAW is not in the listing at all
      // (`analysis/50`: the firmware sends one `rawJpeg` entry per shutter press), so
      // this can only pass by the grouping handing the derived sibling to the plan.
      final app = appWith(listing(), rememberedRaw: true);
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      expect(app.includeRaw, isTrue,
          reason: 'precondition: the stored preference said yes');
      expect(queued(app), [jpeg, raw],
          reason: 'the opt-in is remembered, so a browsed page must carry the RAW');
    });

    testWidgets('and it is still off for a fresh install', (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);
      expect(app.includeRaw, isFalse);
      expectOnlyTheJpeg(app, 'a first run with nothing stored');
    });

    testWidgets('with it on, the model says the shots want their RAW',
        (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      // The switch reaches a fresh queue action too, not only the retroactive one:
      // this is the assertion that the *policy* is live rather than one `if` in a tap
      // handler.
      await tester.tap(find.byKey(const ValueKey<String>('toggle-sync-raw')));
      await tester.pump();

      final group = groupAssets([
        AlbumFile.fromJson(const {
          'path': jpeg,
          'date': '$shotSeconds',
          'filetype': 'rawJpeg',
        }),
      ]).single;
      expect(group.isPair, isTrue, reason: 'precondition: the shot owns a RAW');
      expect(plannedQueue([group], app.queuePlan).map((f) => f.path), [jpeg, raw]);
    });
  });

  group('a shot says whether its RAW has landed', () {
    Finder pending() => find.byKey(
        const ValueKey<String>('album-raw-pending-$jpeg|$shotSeconds'));

    testWidgets('no badge while the RAW is not being fetched', (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      // The state the product launches in. "RAW pending" here would claim work that
      // nothing in the app is ever going to do, on every pair tile, forever.
      expect(find.text(en.albumRawJpgBadge), findsOneWidget,
          reason: 'the tile must still say the shot carries a RAW');
      expect(pending(), findsNothing);
    });

    testWidgets('the badge appears while the RAW is outstanding, and goes when it '
        'lands', (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      await tester.tap(find.byKey(const ValueKey<String>('toggle-sync-raw')));
      await tester.pump();
      expect(pending(), findsOneWidget,
          reason: 'the switch promises a ~32 MB file per shot; the tile has to say '
              'which shots have not delivered it yet, which is what '
              'AssetGroup.rawPending was written for and had no caller for');
      expect(find.text(en.albumRawPending), findsOneWidget);

      // The RAW lands. This is the ledger's own record of it, written the way the
      // sync engine writes it — and the rebuild comes the way it does in production:
      // the engine reports the change, `AppState` notifies, the page rebuilds. A bare
      // `pump()` here would leave the tile as it was and "the badge went away" would
      // be a statement about the harness rather than about the app.
      app.ledger.record(
          assetIdOf(AlbumFile.fromJson(const {
            'path': raw,
            'date': '$shotSeconds',
            'filetype': 'raw',
          })),
          AssetQuality.original);
      app.sync.onChanged?.call();
      await tester.pump();

      expect(pending(), findsNothing,
          reason: 'the RAW is on the phone: a badge still saying "pending" is the '
              'other half of the same defect — before this, a shot whose RAW had '
              'landed and one still waiting looked identical');
      expect(find.text(en.albumRawJpgBadge), findsOneWidget,
          reason: 'the shot still owns a RAW; what changed is that it has arrived');
    });

    testWidgets('the badge survives the switch being turned off mid-transfer',
        (tester) async {
      final app = appWith(listing());
      addTearDown(app.dispose);
      await pumpListed(tester, app);

      await tester.tap(find.byKey(const ValueKey<String>('toggle-sync-raw')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('toggle-sync-raw')));
      await tester.pump();

      expect(app.includeRaw, isFalse);
      expect(pending(), findsOneWidget,
          reason: 'turning the switch off does not cancel a RAW already queued, so '
              'that RAW is still on its way and the tile must keep saying so — a '
              'badge driven by the switch alone would stop tracking work in flight');
    });
  });
}
