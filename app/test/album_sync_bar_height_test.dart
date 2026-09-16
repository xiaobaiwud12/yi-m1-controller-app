import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';

/// How many shots one `GetFileList` page holds — browsing a page queues the page.
const int _pageSize = 60;

/// The album keeps a **usable grid** while the sync bar is describing a large queue —
/// in English as well as Chinese, in portrait and in landscape.
///
/// ## The defect this exists for
///
/// The sync bar's summary row is
/// `Row(children: [Expanded(Text(…)), actionButton])`. `Expanded` bounds the text's
/// **width**; nothing bounded its **height**, and the action button beside it is
/// measured at its intrinsic width and cannot shrink. When the two do not fit, the text
/// is squeezed into whatever is left and — with no `maxLines` — grows one line per
/// character. Measured on the maintainer's phone shape (411x727) with a 60-shot queue:
///
/// ```
/// en   summary 468.0dp tall x  14.8dp wide   bar 656dp of a 671dp body   grid  15dp
/// zh   summary  54.0dp tall x 184.0dp wide   bar 181dp of a 671dp body   grid 490dp
/// ```
///
/// 14.8dp is one character per line: the English action label
/// (`Start sync (60 photos)`, 22 characters) leaves the row almost nothing, and the
/// sentence pays for it in height. The bar then takes the body, and the grid is left
/// **15dp** — not a row of tiles.
///
/// ## Why the checks that already existed could not see it
///
/// `album_last_page_test.dart` and `album_thumbnail_cache_test.dart` both pin
/// `manualOnly`: browsing queues nothing, the summary is the four-word "Nothing queued"
/// and there is no action button in the row. That workaround is written down in the
/// fixture itself ("a harness where the grid is 15dp tall cannot measure anything about
/// tiles") — and it is the shape this project keeps paying for: a fixture arranged so
/// the failure cannot appear. **Nothing here asks the page to run in any mode other than
/// the one the product launches in** (`kDefaultSyncModeId`, an automatic mode —
/// `AGENTS.md` §4.6: a queued shot is not a transferring one, and browsing is what
/// queues the card in those modes).
///
/// ## What is asserted, and why these are measurements
///
/// * **the grid's rect** ≥ half the body, and ≥ one rendered tile row. Both come from
///   `getRect` on the laid-out tree; neither recomputes the layout's arithmetic.
/// * **the summary line's rect** ≤ two and a half lines of the bar's own text, where
///   "a line" is measured from the one-line `Sync` label in the same bar rather than
///   written down as a font constant. This is the *mechanism*: the row must be bounded
///   by something that does not depend on how long the sentence is.
///
/// ## Which cases can fail, and which are guards
///
/// Measured on the tree **before** the fix:
///
/// | case | grid | verdict |
/// |---|---|---|
/// | en portrait  | 15dp of 671 (2%) | **fails — the reported defect** |
/// | zh portrait  | 490dp of 671 (73%) | passes; the guard that a fix for English may not buy its room out of Chinese |
/// | en landscape | 355dp of 355 (100%) | passes; landscape puts the bar in a scrolling side column, so the grid was never starved there |
/// | zh landscape | 355dp of 355 (100%) | passes; same |
///
/// The landscape half is **not** a defect detector and is not claimed as one: it is here
/// because the promise is "both orientations", and a promise measured in one orientation
/// is not the promise. What it does detect is a regression that puts the bar back above
/// the grid in landscape.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_sync_bar_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS
    }
  });

  /// The card that was measured on hardware: 130 shots over three pages (60/60/10), so
  /// the grid is full, the first page alone queues 60 shots, and the firmware's short
  /// page still ends the listing.
  List<Object> ringCard() {
    const count = 130;
    String name(int n) => 'P915${n.toString().padLeft(4, '0')}.JPG';
    return [
      for (var i = 0; i < count; i++)
        {
          'path': '/DCIM/100YICAM/${name(i + 1)}',
          'date': '${1789400000 + i}',
          'filetype': 'picture',
          'protectStatus': false,
        },
    ];
  }

  /// The app as it launches: **the default sync mode**, which is an automatic one.
  ///
  /// `OnboardingPrefs` is left at its default on purpose — `setSyncMode` is never called,
  /// here or in the harness — because a fixture that names a mode is a fixture that can
  /// name the wrong one.
  AppState appWith(List<Object> listing) => AppState(
        ble: FakeBleTransport(),
        sink: NullAssetSink(),
        // Cheap and decodable: this check is about the boxes, not about pictures.
        testAlbumDownload: (file, resolution) async => onePixelPng,
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
            // Paged like the firmware: `range_start`/`range_end` are 1-based and a short
            // page ends the album (`CameraAlbum.pageSize == 60`).
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

  /// Pump real time until the album has a listing and the automatic mode has queued it.
  ///
  /// `runAsync` is not optional: the page awaits the durable ledger, which is real file
  /// I/O, and a widget test's fake-async zone never completes it — without it the page
  /// sits on its spinner and every assertion below would be about a screen with no tiles
  /// (`analysis/44` §7). Polling with an early exit rather than a fixed frame count, so a
  /// fast machine is not made to wait and a slow one is not read as a defect
  /// (`AGENTS.md` §5).
  Future<void> pumpUntilListed(WidgetTester tester, AppState app, Size size,
      Locale locale, {double textScale = 1.0}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      // The app's own text scale is whatever the phone says it is; this is how
      // `live_view_text_scale_test.dart` injects it, for the same reason.
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        child: AlbumPage(app: app),
      ),
    ));
    for (var i = 0; i < 300; i++) {
      if (find.byType(GridView).evaluate().isNotEmpty &&
          app.sync.items.length >= _pageSize) {
        break;
      }
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
    // One more turn, so the frame drawn after the queue appeared is the one measured.
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// The tiles, keyed per shot (`analysis/70` §18).
  Finder tiles() => find.byWidgetPredicate((w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('album-tile-'));

  Finder summary() => find.byKey(const ValueKey<String>('sync-bar-summary'));

  /// Everything this check promises, measured on the tree the page just laid out.
  void expectTheGridIsUsable(
      WidgetTester tester, Size size, AppLocalizations strings, String label) {
    // ------------------------------------------------------------ preconditions
    //
    // Each of these is a way this check could quietly measure nothing.
    expect(find.byType(GridView), findsOneWidget,
        reason: 'no grid in $label: the page is on its spinner, its empty state or a '
            'failure message, and none of those is what a user browses');
    expect(summary(), findsOneWidget,
        reason: 'the summary line is not on screen in $label, so the row that starves '
            'the grid is not being measured');
    expect(tiles(), findsWidgets);

    // --------------------------------------------------------------- the promise
    //
    // "Usable" is measured, not described: the grid must hold more than half the page's
    // height, and it must be able to draw one whole row of tiles. The second is what the
    // defect produced — 15dp cannot show a row of 161dp tiles.
    final body = size.height - tester.getSize(find.byType(AppBar)).height;
    final gridRect = tester.getRect(find.byType(GridView));
    final tileRow = tester.getSize(tiles().first).height;

    expect(gridRect.height, greaterThan(body * 0.5),
        reason: 'the grid is ${gridRect.height.toStringAsFixed(1)}dp of a '
            '${body.toStringAsFixed(0)}dp body in $label: the sync bar is taking the '
            'height the photos need, and it may not take more than half of the page');
    expect(gridRect.height, greaterThanOrEqualTo(tileRow),
        reason: 'the grid is ${gridRect.height.toStringAsFixed(1)}dp and one row of its '
            'tiles is ${tileRow.toStringAsFixed(1)}dp in $label, so the user cannot see '
            'a single whole photo');

    // ------------------------------------------------------------- the mechanism
    //
    // The row must be bounded by something that does not depend on the sentence's
    // length. "A line" is measured from the bar's own one-line `Sync` label, so this
    // compares two boxes in the same tree rather than a font constant guessed at here;
    // because both boxes scale with the text, the assertion survives a larger font.
    final labelLine = tester.getSize(find.text(strings.syncLabel)).height;
    final summaryRect = tester.getRect(summary());
    expect(summaryRect.height, lessThanOrEqualTo(labelLine * 2.5),
        reason: 'the summary line is ${summaryRect.height.toStringAsFixed(1)}dp tall and '
            '${summaryRect.width.toStringAsFixed(1)}dp wide in $label, while one line of '
            'this bar is ${labelLine.toStringAsFixed(1)}dp: the row has grown past its '
            'cap. It is the row\'s height — not the sentence — that takes the grid, and '
            'when nothing bounds it, it takes the whole page.');
  }

  for (final (locale, strings, tag) in [
    (const Locale('en'), englishStrings, 'English'),
    (const Locale('zh'), chineseStrings, 'Chinese'),
  ]) {
    for (final (orientation, size) in [
      ('portrait 411x727', const Size(411, 727)),
      ('landscape 914x411', const Size(914, 411)),
    ]) {
      testWidgets(
          'the grid keeps a usable height under a 60-shot queue in $tag, $orientation',
          (tester) async {
        final app = appWith(ringCard());
        addTearDown(app.dispose);
        await pumpUntilListed(tester, app, size, locale);
        expect(tester.takeException(), isNull);

        // The fixture must really be in the mode the product launches in. Fixing a
        // failure here by pinning `manualOnly` in the fixture is the workaround that hid
        // this defect from the two checks that already covered this page.
        expect(app.sync.items.length, greaterThanOrEqualTo(_pageSize),
            reason: 'only ${app.sync.items.length} shot(s) are queued in $tag '
                '$orientation: the page is not running in an automatic mode, so the '
                'summary row this check is about is not the row the product draws');
        expect(tester.widget<GridView>(find.byType(GridView)).childrenDelegate
            .estimatedChildCount, greaterThanOrEqualTo(_pageSize),
            reason: 'the first page of the card did not arrive, so there is nothing to '
                'browse');

        expectTheGridIsUsable(tester, size, strings, '$tag $orientation');
      });
    }
  }

  testWidgets(
      'the same promise holds when the user\'s own font size makes every sentence '
      'longer', (tester) async {
    // ## Why this case, and why it is Chinese
    //
    // The bound is supposed to be about **content length**, not about English, and the
    // cheapest way to lengthen every sentence on this screen without touching a word is
    // the phone's own font setting. Measured on the tree before the fix, Chinese portrait
    // at 1.6x: grid 298dp of 671 (44%) — starved, with no framework error to explain it,
    // because the summary row was 203dp of the bar's 373dp. After: 443dp (66%).
    //
    // Chinese and not English, because at 1.6x the **English** bar has a different,
    // pre-existing failure that this check does not cover and must not hide: the action
    // button is 22 characters wide and no longer fits the row at all (it overflows by
    // 156px at 1.6x, and its own width — not the summary's height — is what is left).
    // That is a separate defect with a separate decision to make; asserting this one
    // through it would make the failure message point at the wrong thing.
    final app = appWith(ringCard());
    addTearDown(app.dispose);
    const size = Size(411, 727);
    await pumpUntilListed(tester, app, size, const Locale('zh'), textScale: 1.6);
    expect(tester.takeException(), isNull);
    expect(app.sync.items.length, greaterThanOrEqualTo(_pageSize));
    expectTheGridIsUsable(tester, size, chineseStrings, 'Chinese portrait at 1.6x');
  });
}
