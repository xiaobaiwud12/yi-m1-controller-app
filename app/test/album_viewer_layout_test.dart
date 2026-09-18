import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_group.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';

/// The zoomed photo must fill the screen, and opening one must load a preview
/// through a single serial request path.
///
/// ## Why these are measured and not looked at
///
/// Reported from the phone: *"the album's zoomed viewer cannot fill the screen — it
/// is constrained to the area the un-zoomed photo occupied."* The cause is a
/// **containment** defect rather than a zoom limit, and the way to see it is to
/// measure the rendered rectangle instead of reading the widget that does the
/// scaling:
///
/// * `Center` was the outer wrapper. `Center` sizes itself to its child, and
///   `InteractiveViewer` sizes *its* viewport to whatever it is given — so the
///   viewer's clip rect, its pan boundary and everything drawn inside it were all
///   **the photo's own intrinsic size**. A small photo therefore zooms inside a
///   small box, which is the report. Nothing about `maxScale` was wrong, which is
///   why a check on the zoom *factor* would have passed against the defect;
///   `viewport.width` is the number that moves.
/// * So the assertions below are rectangles: the viewer's own rect against the
///   screen, and the picture's rect against **the album grid's tile slot**
///   (`maxCrossAxisExtent: 170`, `childAspectRatio: 0.8` — 170x212.5 dp), which is
///   the box the report names.
///
/// ## And why the camera side is counted
///
/// Opening a photo now loads a preview by itself, which puts `GetFile` in front of a
/// **single-threaded HTTP server with no watchdog** while the live view streams over
/// the same radio (`AGENTS.md` §4.6). Three rules in this project exist because that
/// went wrong before (`analysis/37`-`39`). Two of them survive this change intact —
/// a synced shot is still never fetched again, and the request path is still serial —
/// and both are asserted here by counting at the client seam, the way `analysis/61`
/// and the transport suite do.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_viewer_layout_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The album grid's tile slot, from `album_page.dart`'s own delegate:
  /// `maxCrossAxisExtent: 170` with `childAspectRatio: 0.8`.
  ///
  /// This is the box the report describes the zoom as being trapped in, so it is the
  /// number the picture has to beat. Written as the delegate's own arithmetic rather
  /// than as a measured constant so a deliberate layout change moves both sides.
  const double kTileExtent = 170;
  const double kTileHeight = 170 / 0.8;

  /// The maintainer's phone, in logical pixels, as the album tests use it.
  const portrait = Size(411, 866);
  const landscape = Size(866, 411);

  // The fixture itself is declared below `main` — see [photo].

  /// Three shots, newest first, so the viewer has somewhere to swipe to.
  ///
  /// The dates are spread on purpose: `AssetId.key` is `path|captureSeconds`, and
  /// entries sharing a second would collide in the ledger.
  List<AssetGroup> card([int count = 3]) => [
        for (var i = 0; i < count; i++)
          AssetGroup(AlbumFile(
            path: '/DCIM/101YICAM/YI00000${i + 1}.JPG',
            fileType: 'picture',
            captureTime:
                DateTime.fromMillisecondsSinceEpoch((1700000000 + i) * 1000),
          )),
      ];

  /// Whether the page is still claiming to work: a spinner is on screen.
  ///
  /// The distinction matters because "no download happened" and "the page is still
  /// waiting" look identical in a request log, and only one of them is a defect.
  bool isWorking(WidgetTester tester) => find
      .descendant(
          of: find.byType(AssetViewerPage),
          matching: find.byType(CircularProgressIndicator))
      .evaluate()
      .isNotEmpty;

  /// The page being served, as a finder.
  ///
  /// **Not `find.byType(InteractiveViewer)` and not `.first`.** A `PageView` keeps its
  /// neighbours built, so there are up to three of everything in the tree, and which one
  /// a bare type finder returns depends on paint order rather than on which photo the user
  /// is looking at. Both mistakes were made while writing this file and both read as
  /// layout defects: a viewport reported 56dp below the bottom of a 411x866 window, and a
  /// 1024-square photo reported as covering the whole screen at rest.
  ///
  /// The index comes from the widget that publishes it (`ViewerPageIndex`), which is the
  /// app's own statement about which photo is on screen.
  Finder servedPage(WidgetTester tester) {
    final index = ViewerPageIndex.of(tester.element(find.byType(PageView)));
    return find.byKey(ValueKey<String>('viewer-page-$index'));
  }

  /// Whether a viewer is laid out — which is only true once a photo is in hand.
  ///
  /// `_ViewerPhoto` builds the `InteractiveViewer` only when it has bytes, so a nonzero
  /// box is the same claim as "the picture is on screen" rather than "the widget is
  /// mounted". The **decoded** image has to be there too: `Image.memory` builds a
  /// `RawImage` before its decode completes, and a check that measured at that moment
  /// would be measuring a placeholder. (Measured: the first check in this file failed
  /// that way — the element existed, `RawImage.image` was still null.)
  bool photoIsDrawn(WidgetTester tester) {
    final f = find.byType(InteractiveViewer);
    if (f.evaluate().isEmpty) return false;
    if (tester.getSize(f.first).width <= 0) return false;
    final raw = find.descendant(
        of: servedPage(tester), matching: find.byType(RawImage));
    if (raw.evaluate().isEmpty) return false;
    return tester.widget<RawImage>(raw.first).image != null;
  }

  /// Whether the page has stopped working, for the checks that expect **no** photo yet.
  ///
  /// ## Why "no spinner on screen" is not enough, and what that cost
  ///
  /// The first version of this predicate was `!isWorking(tester)`, and it is true of a
  /// page that has **not started yet** — before the post-frame callback that begins the
  /// load, there is no viewer and no spinner, so the wait returned immediately. The
  /// geometry checks then saw a page with no photo, found no fetch button either (the
  /// fetch was already on its way), and failed with "the viewer is stuck" against a
  /// viewer that was working perfectly. It is the shape `AGENTS.md` §5 names: a
  /// precondition assumed rather than established.
  ///
  /// So the page has to have **decided**: either a photo is drawn, or the load that was
  /// going to happen has happened and nothing is in flight.
  bool pageIsResting(WidgetTester tester, AppStateFixture app) {
    if (photoIsDrawn(tester)) return true;
    return app.live == 0 && !isWorking(tester);
  }

  /// The viewer on [groups], with the camera stubbed so every request is recorded.
  ///
  /// [download] defaults to answering [photo] for every rendition.
  ///
  /// [wantsPhoto] is the precondition, stated rather than assumed: a check that
  /// measures a rendered rectangle is meaningless unless a photo was rendered, and
  /// "the picture is 0x0" reads like a layout defect rather than like a fixture that
  /// never produced one. Tests whose subject is the *absence* of a photo pass false
  /// and wait for the request log to stop instead.
  Future<void> pumpViewer(
    WidgetTester tester, {
    required AppStateFixture app,
    required List<AssetGroup> groups,
    int initialIndex = 0,
    Size size = portrait,
    Locale? locale,
    bool wantsPhoto = true,
    Future<Uint8List> Function(AlbumFile, FileResolution)? download,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    app.reset();
    app.album = CameraAlbum(
      app.http,
      overrideDownload: (file, resolution) async {
        app.downloads.add('${file.fileName}:${resolution.wire}');
        app.live++;
        if (app.live > app.maxLive) app.maxLive = app.live;
        try {
          return await (download ?? (f, r) async => photo)(file, resolution);
        } finally {
          app.live--;
        }
      },
    );
    await tester.pumpWidget(localizedApp(
      AssetViewerPage(
        app: app.state,
        groups: groups,
        initialIndex: initialIndex,
      ),
      locale: locale,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    ));
    // The photo arrives through a **platform channel** and then a real image decode.
    // Neither completes inside a widget test's fake-async zone, so without `runAsync`
    // the page is measured mid-load and every assertion below is about a spinner
    // (`AGENTS.md` §8, "启动时读盘的页面，widget 测试要用 tester.runAsync").
    await settle(tester,
        () => wantsPhoto ? photoIsDrawn(tester) : pageIsResting(tester, app),
        what: wantsPhoto ? 'the decoded photo to be drawn' : 'the page to come to rest');
  }

  /// Every viewer in the tree, in paint order.
  Finder viewers() => find.byType(InteractiveViewer);

  /// The viewer's clip box — the rectangle the photo can never paint outside of, and
  /// the box the report is about.
  Rect viewport(WidgetTester tester) => tester.getRect(viewers().first);

  /// The picture's **painted** rectangle, in global coordinates.
  ///
  /// ## Why this cannot come from either widget's rect
  ///
  /// Two candidate shortcuts were tried and both are wrong, in the same direction — they
  /// report the *page* rather than the photo, so every assertion about "how big is the
  /// picture" compares the viewport against itself and passes at any zoom:
  ///
  /// * `tester.getRect(find.byType(Image))` is the **layout** box. `Image` fills whatever
  ///   it is given and letterboxes the picture inside itself;
  /// * `tester.getRect(find.byType(RawImage))` is the same box. `RenderImage` sizes
  ///   itself with `constrainSizeAndAttemptToPreserveAspectRatio`, which returns the
  ///   tight constraints unchanged — the `fit` is applied when **painting**, not when
  ///   laying out. (Measured: a 1024x1024 fixture reported as 411x810 at rest, i.e. the
  ///   whole viewport.)
  ///
  /// So the painted box is computed from the two things that actually determine it: the
  /// **decoded image's own size**, and the box the `Image` was laid out in. That is why
  /// the fixture's dimensions matter — this is the number the check is about.
  Rect painted(WidgetTester tester) {
    final rawImage = tester.widget<RawImage>(find
        .descendant(of: servedPage(tester), matching: find.byType(RawImage))
        .first);
    final decoded = rawImage.image;
    expect(decoded, isNotNull,
        reason: 'the photo never decoded, so there is no painted rectangle to measure');
    // The decoded pixels' own size, which is what the fit is applied to. Not the
    // `RawImage`'s render box: that is the viewport, because `RenderImage` sizes itself
    // with `constrainSizeAndAttemptToPreserveAspectRatio` and applies `fit` at **paint**
    // time.
    final source = Size(decoded!.width.toDouble(), decoded.height.toDouble());

    final image = tester.widget<Image>(
        find.descendant(of: servedPage(tester), matching: find.byType(Image)).first);
    final box = tester.getRect(find
        .descendant(of: servedPage(tester), matching: find.byType(RawImage))
        .first);
    final fitted =
        applyBoxFit(image.fit ?? BoxFit.scaleDown, source, box.size).destination;
    final pic = Rect.fromCenter(
        center: box.center, width: fitted.width, height: fitted.height);
    final transform = tester
        .renderObject<RenderBox>(find
            .descendant(of: servedPage(tester), matching: find.byType(RawImage))
            .first)
        .getTransformTo(null);
    return MatrixUtils.transformRect(transform, pic);
  }

  /// The scale currently drawn, read from the controller the viewer itself applies.
  double zoom(WidgetTester tester) {
    final iv = tester.widget<InteractiveViewer>(viewers().first);
    final c = iv.transformationController;
    if (c == null) {
      // A viewer with no controller cannot be zoomed programmatically, which is the
      // defect this file is about — reported as a scale of 1 rather than as a null.
      return 1.0;
    }
    return c.value.getMaxScaleOnAxis();
  }

  /// Two taps in the same place: the viewer's zoom gesture, if it has one.
  Future<void> doubleTap(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
  }

  /// A pinch: two pointers moved apart in steps, so the scale recognizer sees a real
  /// sequence rather than one jump.
  Future<void> pinchOut(WidgetTester tester) async {
    final c = tester.getCenter(viewers().first);
    final a = await tester.startGesture(c - const Offset(24, 0));
    final b = await tester.startGesture(c + const Offset(24, 0));
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-14, 0));
      await b.moveBy(const Offset(14, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
  }

  /// Make sure a photo is on screen before measuring anything about it.
  ///
  /// The geometry below is about what a **drawn** photo does, so it must not also be a
  /// check on how the photo got there. This taps the explicit camera button, which is
  /// the way in that exists on both sides of this round's change; a viewer that already
  /// loaded the preview by itself has nothing to tap and is left alone. That keeps the
  /// failure this file's zoom checks report a *geometry* failure rather than "the
  /// fixture never produced a photo" — the distinction the report asks for.
  Future<void> showPhoto(WidgetTester tester, AppStateFixture app) async {
    // **Tap first, then wait; never the other way round.** Measured: waiting for a
    // settled page before deciding whether to tap races the automatic preview — the
    // fetch is already on its way, so no button is on screen and no photo is drawn yet,
    // and the check reports a stuck viewer against one that is working. Two taps would
    // be a double tap, which zooms, so the button is only pressed when it is there.
    var tapped = false;
    for (var i = 0; i < 400 && !photoIsDrawn(tester); i++) {
      if (!tapped) {
        final button = find.byKey(const ValueKey<String>('btn-viewer-fetch-camera'));
        if (button.evaluate().isNotEmpty) {
          await tester.tap(button);
          tapped = true;
        }
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 2));
    }
    expect(photoIsDrawn(tester), isTrue,
        reason: 'no photo was drawn and there was no way to ask for one — the viewer is '
            'stuck (downloads so far: ${app.downloads})');
  }

  // --------------------------------------------------------------- containment

  for (final (name, size) in <(String, Size)>[
    ('portrait', portrait),
    ('landscape', landscape),
  ]) {
    for (final (langName, locale) in <(String, Locale?)>[
      ('Chinese', const Locale('zh')),
      ('English', const Locale('en')),
    ]) {
      testWidgets('the viewer is the screen, not the photo, in $name $langName',
          (tester) async {
        final app = AppStateFixture();
        addTearDown(app.dispose);
        useMediaChannel(bytes: null, reads: app.reads);

        await pumpViewer(tester, app: app, groups: card(),
            size: size, locale: locale, wantsPhoto: false);
        expect(tester.takeException(), isNull);
        // The photo before this round had to be asked for; the button is the way in
        // that works against both versions of the page, so the geometry below is
        // measured on a drawn photo rather than on a spinner.
        await showPhoto(tester, app);

        final v = viewport(tester);
        expect(v.width, closeTo(size.width, 0.5),
            reason: 'the viewer is ${v.width}dp wide on a ${size.width}dp screen, so '
                'it is sizing itself to the photo rather than to the screen '
                '($langName). Nothing drawn inside it can exceed that box, which is '
                'the "zoom stops at the un-zoomed photo" report.');

        // The whole point: the picture is bigger than the tile slot it was opened
        // from. At the default zoom a photo wider than the slot already is — the
        // defect is that the *viewport* was the slot's size, which the assertion
        // above catches — so this also pins that nothing shrinks it to fit an
        // inner box.
        final p = painted(tester);
        expect(p.width, greaterThan(kTileExtent),
            reason: 'the picture is ${p.width}x${p.height}dp, no bigger than the '
                '${kTileExtent}x$kTileHeight dp grid tile it was opened from');

        // The three bar/panel relationships the report asks about, as geometry.
        // "Fill the screen" here means **the body**: edge to edge horizontally and
        // behind the metadata panel at the bottom, but not under the app bar — see
        // the class note on `AssetViewerPage` for why the bars differ.
        final body = tester.getRect(find.byType(Scaffold));
        expect(v.left, closeTo(body.left, 0.5), reason: 'not flush left');
        expect(v.right, closeTo(body.right, 0.5), reason: 'not flush right');
        expect(v.top,
            greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom - 0.5),
            reason: 'the viewer runs under the app bar, which is opaque — that would '
                'hide the top of every photo for good, with no pan that can reveal it');
        expect(v.bottom, closeTo(body.bottom, 0.5),
            reason: 'the viewer stops short of the bottom of the screen');
      });
    }
  }

  testWidgets('a zoomed photo covers the screen', (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: null, reads: app.reads);

    await pumpViewer(tester, app: app, groups: card(), wantsPhoto: false);
    await showPhoto(tester, app);
    final v = viewport(tester);
    final start = painted(tester);
    // At rest the picture fits the viewport, so at least one side of it is short of
    // the screen — otherwise "it can cover the screen" would be true at 1x and the
    // assertion below would measure nothing.
    expect(start.width < v.width - 1 || start.height < v.height - 1, isTrue,
        reason: 'precondition: the photo already covers $v at rest ($start), so no '
            'zoom is needed and this check proves nothing');

    await doubleTap(tester, v.center);
    expect(zoom(tester), greaterThan(1.0),
        reason: 'a plain DoubleTapGestureRecognizer wins the arena on every phone, so '
            'a double tap must zoom; without one the only way in is a pinch');

    final zoomed = painted(tester);
    expect(zoomed.width, greaterThan(start.width),
        reason: 'the double tap did not change what is drawn ($zoomed)');
    expect(
        zoomed.left <= v.left + 0.5 &&
            zoomed.top <= v.top + 0.5 &&
            zoomed.right >= v.right - 0.5 &&
            zoomed.bottom >= v.bottom - 0.5,
        isTrue,
        reason: 'at ${zoom(tester).toStringAsFixed(2)}x the picture is $zoomed, which '
            'does not cover the $v viewer — the zoom is still bounded by something '
            'smaller than the screen');

    // Back to rest, then the pinch, which must reach the same place.
    await doubleTap(tester, v.center);
    expect(zoom(tester), closeTo(1.0, 0.01),
        reason: 'a second double tap must return to fit — zooming in with no way back '
            'out is the same defect pointing the other way');

    await pinchOut(tester);
    expect(zoom(tester), greaterThan(1.0),
        reason: 'pinch-to-zoom did not move the scale at all');
    expect(painted(tester).width, greaterThan(start.width),
        reason: 'the pinch changed the scale but the drawn picture did not grow '
            '(${painted(tester)})');
  });

  testWidgets('a zoomed photo can be panned, and cannot be flung off screen',
      (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: null, reads: app.reads);

    await pumpViewer(tester, app: app, groups: card(), wantsPhoto: false);
    await showPhoto(tester, app);
    final v = viewport(tester);
    await doubleTap(tester, v.center);

    final before = painted(tester);
    expect(before.width, greaterThan(v.width + 1),
        reason: 'precondition: at this zoom the picture is $before, no wider than the '
            '$v viewer, so there is nothing to pan to');

    await tester.drag(viewers().first, const Offset(-120, 0));
    await tester.pumpAndSettle();
    final after = painted(tester);
    // Measured rather than assumed: `InteractiveViewer` clamps a pan to the boundary, so
    // a 120dp drag moves the picture by however much of that drag was *inside* the
    // boundary. What has to be true is that it moved at all. (The first version of this
    // line demanded 100dp and failed at 99.99 — a check on floating-point rounding
    // rather than on panning.)
    expect(after.left, lessThan(before.left - 1),
        reason: 'dragging left by 120dp moved the picture from ${before.left} to '
            '${after.left} — a zoom that cannot be panned is a zoom that cannot be used');

    // The boundary is the point of `InteractiveViewer`: a picture that can be flung
    // into empty space is a broken viewer, not a generous one.
    await tester.drag(viewers().first, const Offset(-4000, 0));
    await tester.pumpAndSettle();
    final edge = painted(tester);
    expect(edge.right, greaterThanOrEqualTo(v.right - 0.5),
        reason: 'the picture was flung off the right edge: $edge against $v');
    expect(edge.width, greaterThan(v.width + 1),
        reason: 'the picture collapsed to the viewport while being panned');
  });

  testWidgets('zoomed in, a horizontal drag pans instead of turning the page',
      (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: null, reads: app.reads);

    await pumpViewer(tester, app: app, groups: card(), wantsPhoto: false);
    await showPhoto(tester, app);
    expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
        reason: 'precondition: at rest the pages must be swipeable');

    await doubleTap(tester, viewport(tester).center);
    await tester.drag(viewers().first, const Offset(-200, 0));
    await tester.pumpAndSettle();

    expect(find.text('YI000001.JPG'), findsOneWidget,
        reason: 'a horizontal drag while zoomed turned the page, so the photo cannot '
            'be examined — every pan is a navigation');
  });

  // ------------------------------------------------------- auto-preview, counted

  testWidgets('opening a photo already on the phone asks the camera for nothing',
      (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: photo, reads: app.reads);

    final groups = card();
    app.state.ledger.recordLocal(groups.first.id, AssetQuality.original,
        'content://media/external/images/42');

    await pumpViewer(tester, app: app, groups: groups);

    expect(app.reads, hasLength(1), reason: 'the phone copy was never read');
    expect(app.downloads, isEmpty,
        reason: 'the viewer fetched ${app.downloads} for a shot already saved — '
            'AGENTS.md §4.6: a synced photo must never be fetched again');
  });

  testWidgets('opening an unsynced photo loads exactly one preview',
      (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: null, reads: app.reads);

    await pumpViewer(tester, app: app, groups: card(), wantsPhoto: false);
    // **No button tap here.** This check is that the preview arrives because the photo
    // was *opened*, so pressing the explicit fetch button first would make it pass
    // against the old viewer — which had exactly that button and no auto-load.
    await settle(tester, () => find.byType(Image).evaluate().isNotEmpty,
        what: 'the preview to be drawn without being asked for');

    expect(app.downloads, ['YI000001.JPG:MidThumb'],
        reason: 'opening a large photo must load one preview — one request, at the '
            'rendition analysis/61 measured at 196,495 B. Got ${app.downloads}');
    expect(app.live, 0,
        reason: 'a request was still in flight when the page settled');
    expect(app.maxLive, 1,
        reason: 'the harness saw ${app.maxLive} concurrent requests for one photo');
    expect(find.byType(Image), findsOneWidget,
        reason: 'the preview was fetched but never drawn');
  });

  testWidgets('swiping through photos keeps at most one request in flight',
      (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: null, reads: app.reads);

    final groups = card(4);
    // A preview that takes long enough that a second request would overlap it if
    // anything were allowed to start one. Without the delay the serial property would
    // be satisfied by the requests never overlapping in the first place, and the check
    // would pass against a viewer that fired all four at once.
    await pumpViewer(
      tester,
      app: app,
      groups: groups,
      download: (f, r) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return photo;
      },
    );
    expect(app.downloads, hasLength(1),
        reason: 'precondition: only the photo on screen may be asked for, got '
            '${app.downloads}');

    // Swipe through the rest, the way someone flicking through a card does.
    for (var i = 0; i < 3; i++) {
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1200);
      await settle(tester, () => app.downloads.length >= i + 2,
          what: 'the viewer to ask for photo ${i + 2}');
    }
    await settle(tester, () => app.live == 0, what: 'every request to finish');
    await settle(tester, () => find.byType(Image).evaluate().isNotEmpty,
        what: 'the last preview to be drawn');

    expect(app.maxLive, 1,
        reason: 'AGENTS.md §4.6: this camera runs a single-threaded httpd, so two '
            'GetFile requests at once do not go faster and increase the chance of a '
            'stall. Saw ${app.maxLive} at once: ${app.downloads}');
    expect(app.downloads, [
      'YI000001.JPG:MidThumb',
      'YI000002.JPG:MidThumb',
      'YI000003.JPG:MidThumb',
      'YI000004.JPG:MidThumb',
    ], reason: 'each photo on screen asks once, in the order it was reached');
    expect(app.downloads.toSet(), hasLength(app.downloads.length),
        reason: 'a photo was asked for twice: ${app.downloads}');
  });

  testWidgets('a preview that never arrives leaves the viewer usable',
      (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: null, reads: app.reads);

    await pumpViewer(
      tester,
      app: app,
      groups: card(),
      wantsPhoto: false,
      download: (f, r) async =>
          throw const AlbumException('HTTP 404 downloading nothing', 404),
    );

    // analysis/70 records a round that shipped a spinner-forever defect because a
    // throw was swallowed. A failure has to be visible, named and escapable.
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the viewer is still spinning for a request that already failed');
    expect(find.textContaining('404'), findsOneWidget,
        reason: 'the camera refused and the viewer said nothing, so a failure is '
            'indistinguishable from a slow link');
    expect(find.byKey(const ValueKey<String>('btn-viewer-fetch-camera')),
        findsOneWidget,
        reason: 'a failed automatic preview must leave a way to ask again');

    // And asking again must work: the failure must not have latched.
    final before = app.downloads.length;
    await tester.tap(find.byKey(const ValueKey<String>('btn-viewer-fetch-camera')));
    await tester.pumpAndSettle();
    expect(app.downloads.length, greaterThan(before),
        reason: 'the manual button did not retry: ${app.downloads}');
  });

  testWidgets('a ledger entry whose bytes are gone is not re-downloaded',
      (tester) async {
    final app = AppStateFixture();
    addTearDown(app.dispose);
    useMediaChannel(bytes: null, reads: app.reads);

    final groups = card();
    // The ledger says it is saved and the bytes are gone — analysis/39's fourth case.
    app.state.ledger.recordLocal(groups.first.id, AssetQuality.original,
        'content://media/external/images/99');

    await pumpViewer(tester, app: app, groups: groups, wantsPhoto: false);

    expect(app.downloads, isEmpty,
        reason: 'the ledger entry was treated as "not synced" and re-downloaded: '
            '${app.downloads}');
    expect(find.textContaining(en.albumSavedCopyGone), findsOneWidget,
        reason: 'the user was not told their saved copy is gone');
  });
  /// Warm the platform's image decoder up before anything is measured.
  ///
  /// ## Why this exists, and why it is a check rather than a longer timeout
  ///
  /// Measured while writing the checks below: the **first** widget test in this file
  /// could not decode the fixture at all — `RawImage.image` stayed null through two
  /// seconds of pumping, with the bytes in hand and the widget built — while every later
  /// test decoded the identical bytes immediately. It follows the **position in the
  /// file**, not the parameters: the same check passes in portrait and landscape and in
  /// both languages as long as it is not the one that runs first (verified by swapping
  /// the locale loop's order — the failure moved to the new first test).
  ///
  /// So it is the harness's decoder warm-up, not the viewer. Both alternative shapes are
  /// worse: one enormous timeout on every geometry check would hide a genuinely stuck
  /// decoder behind a wait that never fails, and reordering the file to dodge the first
  /// slot leaves the next person who adds a test here with a mystery.
  ///
  /// It asserts something real as well — that a fixture of this size **can** be decoded
  /// here, which is the precondition every measurement below rests on (`AGENTS.md` §8: a
  /// fixture that quietly stops working makes the checks that use it meaningless).
  testWidgets('the fixture decodes, before anything is measured', (tester) async {
    expect(photo.length, greaterThan(1000),
        reason: 'the fixture is suspiciously small — is it still a JPEG?');
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Image.memory(photo)),
    ));
    // Its own predicate, not `photoIsDrawn`: there is no viewer and no served page in
    // this tree, and reusing the viewer's helper here is how this check first failed
    // against a fixture that decodes perfectly well.
    bool decoded() {
      final f = find.byType(RawImage);
      return f.evaluate().isNotEmpty && tester.widget<RawImage>(f.first).image != null;
    }

    await settle(tester, decoded, what: 'the fixture itself to decode');
    final raw = tester.widget<RawImage>(find.byType(RawImage).first);
    expect(raw.image?.width, 1024,
        reason: 'the fixture is not the size the geometry checks below assume');
    expect(raw.image?.height, 768);
  });
}

/// One `AppState` plus the seams these checks count through.
///
/// An object rather than three loose variables because the counters have to travel
/// together into `pumpViewer` and be cleared by it: a check that forgot to reset
/// `downloads` would count the previous pump's requests.
class AppStateFixture {
  AppStateFixture() {
    http = CameraHttpClient(overrideSend: (command, params) async {
      return const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok');
    });
    state = connectedTestAppState(onCommand: commands.add);
  }

  final List<String> commands = [];
  late final CameraHttpClient http;
  late final AppState state;

  /// What the phone was asked to read back, per URI.
  final List<String> reads = [];

  /// Every camera request this page caused, as `file:rendition`.
  final List<String> downloads = [];

  /// Requests in flight right now, and the high-water mark.
  int live = 0;
  int maxLive = 0;

  /// A stub album whose downloads are recorded rather than performed.
  ///
  /// `AppState.album` only exists once the link is ready, and `connectedTestAppState`
  /// reaches ready in its constructor — so the precondition is asserted here rather
  /// than left to fail later as "the viewer asked for nothing".
  set album(CameraAlbum a) {
    if (state.album == null) {
      throw StateError('the injected link never reached ready, so there is no album '
          'to record downloads on and every camera assertion below would be vacuous');
    }
    state.album = a;
  }

  /// Back to nothing observed, so the next pump is measured on its own.
  ///
  /// The downloads list is handed to the album by identity — `pumpViewer` rebuilds the
  /// album around it — so it is emptied in place rather than replaced.
  void reset() {
    downloads.clear();
    live = 0;
    maxLive = 0;
  }

  void dispose() => state.dispose();
}

/// Pump until [done], driving **both** clocks, then pump once more so the result draws.
///
/// ## Why both clocks, because getting this wrong cost two rounds
///
/// Two kinds of asynchrony are in play and they need opposite treatment:
///
/// * the photo arrives through a **platform channel** and then an image decode, and the
///   ledger is **real file I/O** — none of that completes inside a widget test's
///   fake-async zone, so `runAsync` is what steps outside it and lets the event loop turn
///   (`analysis/44` §7). With plain `pump` the page stays on a spinner and every
///   assertion afterwards is about a spinner rather than about the app;
/// * a fixture that deliberately makes a transfer take a while uses
///   `Future.delayed`, which inside the test body is scheduled on the **fake** clock.
///   `runAsync` does not advance it: this file first tried a 30 ms fixture delay and the
///   request stayed in flight for the whole budget, because every `pump` in the loop
///   passed `Duration.zero`. A sweep check whose fixture never finishes cannot show
///   whether two requests overlap.
///
/// So: real time for the channel and the filesystem, a small step of fake time for the
/// timers. The predicate is checked at the top of every turn, so a fixture that finishes
/// immediately costs one turn.
///
/// Exhausting the budget is a failure that names what it was waiting for, rather than a
/// timeout with no explanation.
Future<void> settle(WidgetTester tester, bool Function() done,
    {required String what, int maxTurns = 400}) async {
  for (var i = 0; i < maxTurns; i++) {
    if (done()) {
      await tester.pump(const Duration(milliseconds: 2));
      return;
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 2));
  }
  if (done()) return;
  // One long, uninterrupted real-time turn before giving up.
  //
  // Measured: the platform's image decoder can need a longer single turn than a
  // 5ms-per-iteration loop gives it — the first check in this file hit that and looked
  // exactly like a viewer that never draws, which is the failure this wait exists to
  // report honestly. A single generous turn is a different claim from "wait longer
  // everywhere": the loop above still fails fast when the predicate is impossible.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1000)));
  await tester.pump(const Duration(milliseconds: 2));
  if (done()) return;
  final ex = tester.takeException();
  fail('waited for $what and it never happened'
      '${ex == null ? '' : '; the last exception raised was: $ex'}');
}


/// The photo the viewer's geometry is measured on: a real **JPEG**, 1024x768.
///
/// ## Why it is inlined, and why it is not generated
///
/// The first version of this file generated its fixture — a hand-built PNG container,
/// which is a perfectly good way to get a picture of a chosen size. It decoded in a
/// probe, and then **failed to decode at all when it was the first widget test in the
/// file**: `RawImage.image` stayed null through two seconds of pumping, with the bytes in
/// hand and the widget built, while every later test decoded the identical bytes
/// immediately. Verified to follow the *position* in the file rather than the parameters
/// — swapping the locale loop's order moved the failure to the new first test.
///
/// A real JPEG does not do that, first position included. So the fixture is the format
/// this camera actually serves (`analysis/61` §1: a `MidThumb` is a JPEG), and the check
/// at the top of this file stops being a check on the generator.
///
/// ## Why the size matters
///
/// 1024x768 is **wider than the phone and shorter than it**. On a 411x866 screen the
/// fitted picture covers the width and falls well short of the height, so "a zoom can
/// cover the screen" is false at 1x and has to be earned. A fixture whose ratio matched
/// the screen would be edge to edge before any zoom, and that check could not fail. It is
/// also far bigger than the 170x212.5dp album tile the report names.
///
/// Regenerate with any JPEG encoder; the only property that matters is the pixel size,
/// which the check at the top of this file asserts.
final Uint8List photo = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIf'
  'IiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7'
  'Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAMABAADASIA'
  'AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA'
  'AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3'
  'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm'
  'p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA'
  'AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx'
  'BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK'
  'U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3'
  'uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDhqKKK'
  '7jlCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivP'
  'PSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQP'
  'NCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPS'
  'CiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNC'
  'iiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCi'
  'iigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCii'
  'igD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiii'
  'gDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiig'
  'D2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigD'
  'xiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2'
  'eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxi'
  'iiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2ei'
  'iivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigAooooAKKKKAPGKKKK9A80KKKKAPZ6KKK889'
  'IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80'
  'KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IK'
  'KKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KK'
  'KKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKK'
  'KAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKK'
  'APZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKA'
  'PGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAP'
  'Z6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPG'
  'KKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6'
  'KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKK'
  'KK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KK'
  'K889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK'
  '9A80KKKKACiiigAooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQo'
  'oooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goo'
  'ooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooo'
  'oA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goooo'
  'A8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA'
  '9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8'
  'Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9n'
  'ooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yo'
  'oor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9noo'
  'orzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooo'
  'r0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooor'
  'zz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0'
  'DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooAKKKKACiiigDxiiiivQPNCii'
  'igD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiii'
  'gDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiig'
  'D2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigD'
  'xiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2'
  'eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxi'
  'iiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2ei'
  'iivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiii'
  'ivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiii'
  'vPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiiv'
  'QPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivP'
  'PSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQP'
  'NCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPS'
  'CiiigDxiiiivQPNCiiigAooooAKKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKA'
  'PGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAP'
  'Z6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPG'
  'KKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6'
  'KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKK'
  'KK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KK'
  'K889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK'
  '9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK8'
  '89IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A'
  '80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889'
  'IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80'
  'KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IK'
  'KKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKACiiigAooooA8'
  'Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9n'
  'ooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yo'
  'oor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9noo'
  'orzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooo'
  'r0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooor'
  'zz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0'
  'DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz'
  '0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0Dz'
  'QooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0g'
  'ooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQo'
  'oooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goo'
  'ooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooo'
  'oA9nooorzz0gooooA8Yooor0DzQooooAKKKKACiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2ei'
  'iivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiii'
  'ivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiii'
  'vPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiiv'
  'QPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivP'
  'PSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQP'
  'NCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPS'
  'CiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNC'
  'iiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCi'
  'iigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCii'
  'igD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiii'
  'gDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiig'
  'D2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigA'
  'ooooAKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK'
  '9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK8'
  '89IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A'
  '80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889'
  'IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80'
  'KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IK'
  'KKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KK'
  'KKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKK'
  'KAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKK'
  'APZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKA'
  'PGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAP'
  'Z6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPG'
  'KKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKACiiigAooooA9nooorzz0gooooA8Yooor0'
  'DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz'
  '0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0Dz'
  'QooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0g'
  'ooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQo'
  'oooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goo'
  'ooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooo'
  'oA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goooo'
  'A8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA'
  '9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8'
  'Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9n'
  'ooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yo'
  'oor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9noo'
  'orzz0gooooAKKKKACiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPS'
  'CiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNC'
  'iiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCi'
  'iigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCii'
  'igD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiii'
  'gDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiig'
  'D2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigD'
  'xiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2'
  'eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxi'
  'iiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2ei'
  'iivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiii'
  'ivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiii'
  'vPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigAooooAKKKKAPZ6KKK889IK'
  'KKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KK'
  'KKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKK'
  'KAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKK'
  'APZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKA'
  'PGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAP'
  'Z6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPG'
  'KKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6'
  'KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKK'
  'KK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KK'
  'K889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK'
  '9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK8'
  '89IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A'
  '80KKKKAPZ6KKK889IKKKKACiiigAooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooo'
  'oA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goooo'
  'A8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA'
  '9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8'
  'Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9n'
  'ooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yo'
  'oor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9noo'
  'orzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooo'
  'r0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooor'
  'zz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0'
  'DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz'
  '0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0Dz'
  'QooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooAKKKKACiiig'
  'D2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigD'
  'xiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2'
  'eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxi'
  'iiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2ei'
  'iivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiii'
  'ivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiii'
  'vPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiiv'
  'QPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivP'
  'PSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQP'
  'NCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPS'
  'CiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNC'
  'iiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCi'
  'iigDxiiiivQPNCiiigD2eiiivPPSCiiigAooooAKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPG'
  'KKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6'
  'KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKK'
  'KK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KK'
  'K889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK'
  '9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK8'
  '89IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A'
  '80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889'
  'IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80'
  'KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IK'
  'KKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KK'
  'KKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKK'
  'KAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKK'
  'ACiiigAooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9noo'
  'orzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooo'
  'r0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooor'
  'zz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0'
  'DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz'
  '0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0Dz'
  'QooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0g'
  'ooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQo'
  'oooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goo'
  'ooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooo'
  'oA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goooo'
  'A8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA'
  '9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooAKKKKACiiigDxiiiivQPNCiiigD2eiii'
  'vPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiiv'
  'QPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivP'
  'PSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQP'
  'NCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPS'
  'CiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNC'
  'iiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCi'
  'iigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCii'
  'igD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiii'
  'gDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiig'
  'D2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigD'
  'xiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2'
  'eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxi'
  'iiivQPNCiiigAooooAKKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A'
  '80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889'
  'IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80'
  'KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IK'
  'KKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KK'
  'KKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKK'
  'KAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKK'
  'APZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKA'
  'PGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAP'
  'Z6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPG'
  'KKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6'
  'KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKK'
  'KK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKACiiigAooooA8Yooor0Dz'
  'QooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0g'
  'ooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQo'
  'oooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goo'
  'ooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooo'
  'oA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goooo'
  'A8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA'
  '9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8'
  'Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9n'
  'ooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yo'
  'oor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9noo'
  'orzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooo'
  'r0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooor'
  'zz0gooooA8Yooor0DzQooooAKKKKACiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCi'
  'iigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCii'
  'igD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiii'
  'gDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiig'
  'D2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigD'
  'xiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2'
  'eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxi'
  'iiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2ei'
  'iivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiii'
  'ivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiii'
  'vPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiiv'
  'QPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivP'
  'PSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigAooooAKKK'
  'KAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKK'
  'APZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKA'
  'PGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAP'
  'Z6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPG'
  'KKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6'
  'KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKK'
  'KK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KK'
  'K889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK'
  '9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK8'
  '89IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A'
  '80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889'
  'IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80'
  'KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKACiiigAooooA9nooorzz0gooooA8Yooor0DzQooooA'
  '9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8'
  'Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9n'
  'ooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yo'
  'oor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9noo'
  'orzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooo'
  'r0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooor'
  'zz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0'
  'DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz'
  '0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0Dz'
  'QooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0g'
  'ooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQo'
  'oooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goo'
  'ooAKKKKACiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxi'
  'iiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2ei'
  'iivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiii'
  'ivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiii'
  'vPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiiv'
  'QPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivP'
  'PSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQP'
  'NCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPS'
  'CiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNC'
  'iiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCi'
  'iigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCii'
  'igD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigD2eiiivPPSCiii'
  'gDxiiiivQPNCiiigD2eiiivPPSCiiigDxiiiivQPNCiiigAooooAKKKKAPZ6KKK889IKKKKAPGKK'
  'KK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KK'
  'K889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK'
  '9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK8'
  '89IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A'
  '80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889'
  'IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80'
  'KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IK'
  'KKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KK'
  'KKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKK'
  'KAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKK'
  'APZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKA'
  'PGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAPZ6KKK889IKKKKAPGKKKK9A80KKKKAP'
  'Z6KKK889IKKKKACiiigAooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooor'
  'zz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0'
  'DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz'
  '0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0Dz'
  'QooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0g'
  'ooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQo'
  'oooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goo'
  'ooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooo'
  'oA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0goooo'
  'A8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA'
  '9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8'
  'Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA9n'
  'ooorzz0gooooA8Yooor0DzQooooA9nooorzz0gooooA8Yooor0DzQooooA//2Q=='
);
