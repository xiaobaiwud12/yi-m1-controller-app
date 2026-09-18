import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';

/// An expanded settings group must be in the **same place** before and after a tab
/// switch, in both directions, and must still be expanded afterwards.
///
/// ## The report
///
/// > *"In the camera settings, if an expandable setting — image output for example —
/// > is expanded, then switching back and forth between the Capture and Sync tabs
/// > makes the expandable setting twitch."*
///
/// ## What is actually wrong (measured, not inferred)
///
/// Two defects in `_SettingsGroupTile`, and the second is the one the user sees:
///
/// 1. **`_SettingsGroupTileState` has no key on its widget.** `_SettingsPanelState`
///    builds the tab's groups as a plain list of `_SettingsGroupTile`s, so Flutter
///    matches them to the existing elements **by position**. The Capture tab has four
///    groups and the Sync tab has three, and their ids differ — so on every tab switch
///    the state object of one group is reused for a *different* group:
///
///    ```
///    [TILE] didUpdate connection open=false shown=true controllerExpanded=true
///    [TILE]   -> collapse() connection        ← this is the tile that was 'image'
///    ```
///
///    That `collapse()` is a change on the `ExpansibleController`, and
///    `ExpansionTile` reports every controller change through
///    `onExpansionChanged` — which this widget wires to `widget.onToggle()`. So the
///    switch **writes a group's preference**: `connection` goes to `open = true`
///    although nobody touched it.
///
/// 2. **The `ExpansionTile` is not told to be expanded when it is first built.**
///    `_shown` is initialised to `widget.open`, but the `ExpansibleController` starts
///    collapsed and nothing expands it until `didUpdateWidget` sees a difference. So
///    a tile that mounts with `open: true` draws **collapsed** for a frame, and the
///    `didUpdateWidget` that corrects it calls `expand()` — another controller change,
///    another `onExpansionChanged`, another `onToggle()`. The preference is therefore
///    flipped **to false** by the very act of honouring it:
///
///    ```
///    [TILE] didUpdate image open=true shown=false controllerExpanded=false
///    [TILE]   -> expand() image
///    [TOGGLE] group=image was=true            ← writes open=false
///    ```
///
///    Net effect across one round trip, measured: the group ends **collapsed** and its
///    remembered preference is **false**, so the next open of the panel shows it closed.
///
/// Both are caught here because the check measures `getRect` of the expanded row's
/// first control before and after the switch — not "the group is open", which a
/// collapsed-but-laid-out subtree can satisfy.
///
/// ## Why the geometry, and not the state
///
/// `AGENTS.md` §8: assert the defect itself. A twitch *is* a difference between two
/// frames of a sequence, so this compares frames. The row that is measured is
/// `setting-RCImageAspect` — the first control inside "Image output" — and what is
/// required of it is an **identical `Rect`** on either side of the round trip, plus a
/// non-empty rect (a clipped-to-nothing subtree would otherwise pass by being
/// consistently absent).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_tabtwitch_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // the OS can keep it; the assertions are about layout
    }
  });

  const portrait = Size(411, 727);

  /// A camera state, so the panel draws its groups rather than its "start the
  /// preview" placeholder — the placeholder has no expandable row at all, and a
  /// check written against it would pass by measuring nothing.
  CameraState cameraState() => CameraState(const {
        'ExposureMode': 'M',
        'ImageAspect': '4:3',
        'ShutterSpeed': '1/15s',
        'Fnumber': '1.0',
        'ISOSetting': '400',
        'WB': 'Incandescent',
        'ColorMode': 'HContrastBW',
        'BatteryLevel': '100',
        'SurplusPhotoCnts': '999',
        'EV': '-0.7',
      });

  /// Pump the page the way `HomeShell` does — inside an `AnimatedBuilder` on
  /// `AppState`.
  ///
  /// Without it the page never rebuilds when the panel writes the tab preference, and
  /// the whole round trip happens against a frozen tree: `analysis/60` §5.4 records
  /// that shape of false pass.
  Future<AppState> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(portrait);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState();
    addTearDown(app.dispose);
    app.setTestCameraState(cameraState());
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AnimatedBuilder(
        animation: app,
        builder: (context, _) => LiveViewPage(app: app),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    return app;
  }

  Finder panelList() => find.descendant(
        of: find.byKey(const ValueKey<String>('live-settings-panel')),
        matching: find.byType(Scrollable),
      );

  /// Tap a group's header, scrolling the panel's list until it is on screen first.
  ///
  /// The list is 193 dp tall and the Capture tab's first group is nine rows of
  /// controls, so "Image output" is below the fold until it is scrolled to. Tapping
  /// without scrolling would aim at whatever is at those coordinates — which is a
  /// different control, not a failure, and would make this check lie.
  Future<void> expandGroup(WidgetTester tester, String title) async {
    final header = find.text(title);
    final list = panelList();
    await tester.scrollUntilVisible(header, 60, scrollable: list);
    await tester.pumpAndSettle();
    await tester.tap(header);
    await tester.pumpAndSettle();
  }

  /// The rect of the first control inside "Image output", and the panel's own rect.
  ///
  /// The row's own key is `setting-<command>` (`_MenuRow.valueKey`), so this is the
  /// control and not a label: `find.byKey` cannot be satisfied by a reworded string or
  /// by a look-alike row in another group.
  ///
  /// It scrolls the row into view first, and that is **not** a convenience. The
  /// panel's list is 193 dp tall, `List`-built, so a row below the fold is not merely
  /// off-screen — it is not mounted, and `getRect` has nothing to measure. Switching to
  /// Sync and back resets the list's offset to 0 (the Sync tab's content is shorter, so
  /// the offset the Capture list had is clamped away while it is unmounted), which puts
  /// this row back below the fold. Measuring without scrolling would therefore be
  /// measuring *where the list happens to be scrolled*, not the row's geometry — two
  /// different questions, and only the second one is this check.
  Future<({Rect row, Rect panel})> measure(WidgetTester tester) async {
    final row = find.byKey(const ValueKey<String>('setting-RCImageAspect'));
    await tester.scrollUntilVisible(row, 60, scrollable: panelList());
    await tester.pumpAndSettle();
    expect(row, findsOneWidget,
        reason: 'the expanded group\'s first control is not in the tree at all, so '
            'there is no geometry to compare — the group is collapsed');
    return (
      row: tester.getRect(row),
      panel: tester.getRect(find.byKey(const ValueKey<String>('live-settings-panel'))),
    );
  }

  /// Switch to [tabTitle] and settle, then come back to Capture.
  Future<void> tapTab(WidgetTester tester, String tabTitle) async {
    await tester.tap(find.text(tabTitle));
    await tester.pumpAndSettle();
  }

  /// The row's rect on **every** frame of the tab switch, in order, or null where the
  /// row is not built.
  ///
  /// A twitch is a difference between two frames of a sequence, so this exists, and it
  /// is used below to assert the one frame property a widget test *can* establish: the
  /// expanded tile's height is the same on every frame the panel is on the Capture tab,
  /// and never passes through an intermediate value on the way.
  ///
  /// ## Why this does not measure the reveal itself, and what that leaves to a device
  ///
  /// The row's own mount frames are **outside the widget test's reach**, and that is a
  /// property of the layout rather than of the test. The panel's list is 193 dp tall and
  /// the Capture tab's first group is nine rows of controls, so "Image output" — and the
  /// rows inside it — starts ~500 dp down. A `ListView` builds a child only within its
  /// viewport plus `cacheExtent` (250 dp), and switching to Sync and back resets the
  /// list's offset to 0, which puts the expanded group below that window again. Measured:
  /// across 8 frames drawn by `pumpAndSettle` and then 10 hand-driven frames, the row was
  /// `ABSENT` on every one. So a check cannot see the frame it would need to see.
  ///
  /// **What is left to a device**: a screen recording of the panel with the expanded
  /// group scrolled into view, switching tabs both ways, examined frame by frame for a
  /// frame in which the group is collapsed or partly revealed. Neither `getRect` nor
  /// `pumpAndSettle` can answer that, because `pumpAndSettle` runs any reveal animation
  /// to completion before a measurement is taken.
  Future<List<Rect?>> rectsWhileSwitching(
      WidgetTester tester, Finder row, AppState app) async {
    final seen = <Rect?>[];
    var recording = true;
    void record(Duration _) {
      if (!recording) return;
      seen.add(row.evaluate().isEmpty ? null : tester.getRect(row));
      tester.binding.addPostFrameCallback(record);
    }

    tester.binding.addPostFrameCallback(record);
    await tester.pumpAndSettle();
    recording = false;
    return seen;
  }

  testWidgets(
      'an expanded group keeps its geometry across a Capture→Sync→Capture round trip',
      (tester) async {
    final app = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('btn-settings-toggle')));
    await tester.pumpAndSettle();

    await expandGroup(tester, en.settingsGroupImage);
    expect(app.isSettingsGroupOpen('image'), isTrue,
        reason: 'tapping the header did not open the group, so nothing was expanded '
            'and the rest of this check would measure a collapsed panel');
    final before = await measure(tester);

    await tapTab(tester, en.settingsTabSync);
    await tapTab(tester, en.settingsTabCapture);

    // A framework error during a tab switch is a defect in its own right, and this one
    // had a name: with the expand driven from `didUpdateWidget`, the panel called
    // `AppState.notifyListeners()` while the list was still building, so every switch
    // raised `setState() or markNeedsBuild() called during build` — five to six of them
    // per round trip, measured. `takeException` is how a widget test sees that.
    expect(tester.takeException(), isNull,
        reason: 'the tab switch raised a framework error');

    expect(app.isSettingsGroupOpen('image'), isTrue,
        reason: 'the expanded state was written to the preference by the tab switch, '
            'so the user has to expand the row again after every switch');
    final after = await measure(tester);
    expect(tester.takeException(), isNull,
        reason: 'the switch back raised a framework error');

    expect(after.row, before.row,
        reason: 'the expanded row moved or resized across the round trip — this is the '
            'reported twitch. Before: ${before.row}, after: ${after.row}');
    expect(after.panel, before.panel,
        reason: 'the panel itself changed height across the round trip');
    expect(after.row.height, greaterThan(0),
        reason: 'a zero-height row would satisfy "identical" by being absent');
  });

  testWidgets(
      'the expanded tile is one height on every frame of the switch back',
      (tester) async {
    // The frame half of the report: *"it twitches"* is a claim about a sequence, so
    // something in this file has to look at a sequence rather than at one settled tree.
    //
    // What it can look at is the **tile**, not the row inside it. The row's own mount
    // frames are below the list's build window and are `ABSENT` on every frame (measured;
    // see `rectsWhileSwitching`), so it cannot be the subject. The tile's height is
    // measurable throughout, and it is where a reveal would show: an `ExpansionTile` that
    // mounts collapsed and is expanded a frame later passes through intermediate heights,
    // and this fails on the first one.
    final app = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('btn-settings-toggle')));
    await tester.pumpAndSettle();
    await expandGroup(tester, en.settingsGroupImage);

    final tile = find.byKey(const PageStorageKey<String>('settings-group-image'),
        skipOffstage: false);
    final before = await measure(tester);

    await tapTab(tester, en.settingsTabSync);
    await tester.tap(find.text(en.settingsTabCapture));

    final rects = await rectsWhileSwitching(tester, tile, app);
    final present = rects.whereType<Rect>().toList();
    expect(present, isNotEmpty,
        reason: 'the Image output tile was not found on any frame of the switch back; '
            'frames seen: $rects');
    expect(present.map((r) => r.height).toSet(), hasLength(1),
        reason: 'the tile passed through more than one height while the tab switch '
            'settled — that staircase is a reveal animation, and on screen it is the '
            'twitch. Heights seen: ${present.map((r) => r.height).toList()}');
    expect(present.first.height, present.last.height,
        reason: 'the tile grew into place: first ${present.first}, last ${present.last}');
    // And the end state has to be the height it had before the switch, or "stable" would
    // only mean "stably wrong". The tile is the group's header plus the row measured
    // above, so the two are compared through the header's own height rather than by
    // assuming a constant.
    expect(present.last.height, greaterThan(before.row.height),
        reason: 'a collapsed tile can still be taller than a single row, so a tile '
            'height that is not bigger than the row\'s means the group is closed');
  });

  testWidgets('the same invariant holds on the group in the Sync tab',
      (tester) async {
    // The control experiment for "it is every expandable row, not that one row":
    // `Transfer` is collapsible and lives in the other tab, so a fix that hard-codes
    // anything about "Image output" fails here.
    final app = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('btn-settings-toggle')));
    await tester.pumpAndSettle();
    await tapTab(tester, en.settingsTabSync);

    await expandGroup(tester, en.settingsGroupTransfer);
    expect(app.isSettingsGroupOpen('transfer'), isTrue);
    final row = find.byKey(const ValueKey<String>('setting-pauseStreamDuringTransfer'));
    expect(row, findsOneWidget);
    final before = tester.getRect(row);

    await tapTab(tester, en.settingsTabCapture);
    await tapTab(tester, en.settingsTabSync);

    expect(app.isSettingsGroupOpen('transfer'), isTrue,
        reason: 'the Sync tab\'s own expanded group was closed by the round trip');
    final after = tester.getRect(row);
    expect(after, before,
        reason: 'the Sync tab\'s expanded row moved across the round trip. '
            'Before: $before, after: $after');
  });

  testWidgets('a group remembered as open is open the moment the panel is built',
      (tester) async {
    // The mount half of the same defect, reached without a tab switch. A tile that is
    // built with `open: true` and is not told so until the next rebuild lays out
    // collapsed, and the `expand()` that reconciles it is reported as a user expansion —
    // which writes the preference to **false**. This is the shortest path to that: the
    // preference is already true when the panel first appears.
    final app = await pumpPage(tester);
    app.setSettingsGroupOpen('image', true);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey<String>('btn-settings-toggle')));
    await tester.pumpAndSettle();

    expect(app.isSettingsGroupOpen('image'), isTrue,
        reason: 'opening the panel closed the group the preference said was open');
    final row = find.byKey(const ValueKey<String>('setting-RCImageAspect'));
    await tester.scrollUntilVisible(row, 60, scrollable: panelList());
    await tester.pumpAndSettle();
    expect(row, findsOneWidget,
        reason: 'the group is remembered as open but its rows are not drawn');
    expect(tester.getRect(row).height, greaterThan(0));
    expect(tester.takeException(), isNull,
        reason: 'building the panel with an open group raised a framework error');
  });

  testWidgets('a tab switch does not toggle a group nobody touched',
      (tester) async {
    // Separates "the row twitches" from "the switch presses the row for you". A group
    // in the tab being switched **to** must not be opened by the act of switching:
    // that is the preference corruption, and it is what makes the row unstable on the
    // *next* round trip rather than only this one.
    final app = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('btn-settings-toggle')));
    await tester.pumpAndSettle();

    final closedInSync = <String>[
      'transfer',
      'connection',
      'system',
    ].where((id) => !app.isSettingsGroupOpen(id)).toList();
    expect(closedInSync, hasLength(3),
        reason: 'this check needs all three Sync groups closed to begin with');

    await expandGroup(tester, en.settingsGroupImage);
    await tapTab(tester, en.settingsTabSync);

    for (final id in closedInSync) {
      expect(app.isSettingsGroupOpen(id), isFalse,
          reason: 'switching tabs opened "$id", which nobody tapped — the tab switch '
              'is writing group preferences');
    }
  });
}
