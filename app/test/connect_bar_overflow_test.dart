import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';

/// The connect bar — the first screen of the app — must fit its own row.
///
/// ## The defect this file is about
///
/// `_ConnectBar` draws its controls in one `Row`: a "connect camera" button, then
/// the BLE and Wi-Fi diagnostics buttons. A `Row` lays its children out at their
/// own widths and clips whatever does not fit — the button was the widest thing
/// in the bar and its label had no bound at all, so the bar overflowed at 411 dp
/// in portrait, in the disconnected state, which is what the app shows on every
/// launch before a camera is connected:
///
/// ```
/// A RenderFlex overflowed by 31 pixels on the right.
/// Row  size=Size(379.0, 48.0)  constraints=BoxConstraints(0.0<=w<=379.0, …)
///   ← … ← _ConnectBar ← Column ← LiveViewPage          (411 dp wide body)
/// ```
///
/// An overflow is a Flutter **error**, and it is *drawn*: the yellow-and-black
/// stripe over the bar and over the button beside it. It is not silent and it is
/// not cosmetic — it also reaches `FlutterError.onError`, which is the same
/// channel that used to replace the app with the startup-error screen.
///
/// 411 dp is the maintainer's phone, which is why they saw it and no desk fixture
/// did. The label's width was the only unbounded term in the row, so there was no
/// width to tune the fix to: the same button measures 305.7 dp at the default
/// text scale, 369.9 at 1.3, 412.7 at 1.5 and 519.7 at 2.0, against the 288 dp of
/// room a 320 dp body leaves — and `320x480` overflowed by 122 px.
///
/// ## Why the sweep, and why by key
///
/// A fix tuned to 411 would be the same defect one size over, so the sweep is
/// every width and text scale the rest of the suite uses, plus the narrow phone
/// `AGENTS.md` §5 records (~386 dp of row at 320 dp), in both orientations and in
/// both shipped languages. The label is Chinese on the maintainer's phone: it is
/// shorter, but not uniformly so, and a check that only ran `en` would not notice
/// a translation that stopped fitting.
///
/// Every assertion is on the controls **by `ValueKey`**, never by text: the bar's
/// wording belongs to the localization round, and a test that finds
/// "Connect to camera" fails the day somebody rewords it — reporting a layout
/// regression that is really a wording change.
///
/// ## What this file cannot say
///
/// That the bar *looks* right. `AGENTS.md` §7.1: rendering was never seen here.
/// A layout that throws nothing and keeps all three controls on screen can still
/// be ugly, and the wrap this file allows is a shape change no assertion here
/// judges. [H]
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_connect_bar_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // The assertions are about layout, not temp files.
    }
  });

  /// The bar itself: the `Column` inside the one `SafeArea` on the page that has
  /// a `Container` around it. The page's own root is a `SafeArea` with no such
  /// parent, so this lands on the bar and only the bar.
  Finder barFinder() => find.ancestor(
        of: find.byType(Column),
        matching: find.ancestor(
          of: find.byType(SafeArea),
          matching: find.byWidgetPredicate((w) => w is Container),
        ),
      );

  Future<void> pumpDisconnected(
    WidgetTester tester,
    Size size,
    double scale,
    Locale locale,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // A disconnected `AppState`: the transport answers nothing, there is no
    // injected identity, so `link.isReady` is false and the bar is on screen.
    final app = testAppState();
    addTearDown(app.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: MediaQuery(
        // `setSurfaceSize` and this `MediaQueryData.size` are both **logical**
        // pixels. Getting that wrong is the documented way an overflow test
        // passes while the device overflows (`AGENTS.md` §8).
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: LiveViewPage(app: app),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Fail if any widget overflowed, naming the widget rather than the symptom.
  void expectNoOverflow(WidgetTester tester, String where) {
    final error = tester.takeException();
    if (error == null) return;
    final detail = error is FlutterError
        ? '${error.diagnostics.first}\n'
            '${error.diagnostics.map((d) => d.toString()).join('\n')}'
        : '$error';
    fail('the connect bar overflowed $where:\n$detail');
  }

  /// Every measurement the bar must satisfy, at one width, scale and language.
  Future<void> expectBarFits(
      WidgetTester tester, Size size, String where) async {
    expectNoOverflow(tester, where);

    final bar = barFinder();
    expect(bar, findsOneWidget,
        reason: 'the bar must exist to be judged — a check that silently '
            'measures nothing is worse than no check');
    final barRect = tester.getRect(bar);

    // The three controls are still the members drawn, all present and inside the
    // bar. Asserting presence is what stops "fixed it by deleting the button"
    // from reading as green.
    for (final key in const <String>[
      'btn-connect',
      'btn-ble-diagnostics',
      'btn-wifi-diagnostics',
    ]) {
      final f = find.byKey(ValueKey<String>(key));
      expect(f, findsOneWidget, reason: '$key must still be drawn $where');
      final r = tester.getRect(f);
      expect(r.left, greaterThanOrEqualTo(barRect.left - 0.01),
          reason: '$key starts outside the bar $where');
      expect(r.right, lessThanOrEqualTo(barRect.right + 0.01),
          reason:
              '$key ends ${(r.right - barRect.right).toStringAsFixed(1)} px '
              'past the bar $where');
      // A control squeezed to nothing is a control the user cannot press, and it
      // would satisfy every "is it inside the bar" assertion above.
      expect(r.width, greaterThanOrEqualTo(48 * 0.99),
          reason: '$key is ${r.width.toStringAsFixed(1)} dp wide $where — '
              'below the 48 dp tap target');
    }

    // The label is allowed two lines and no more. Where it does not fit even
    // wrapped — a 320 dp body at text scale 2.0 wants 519.7 dp of button — it is
    // ellipsized, and an ellipsized `Text` stays inside its own box by
    // definition. This is what proves the *button* was constrained rather than
    // the ink escaping the layout: a label laid out at its full intrinsic width
    // and merely clipped would satisfy every assertion above.
    final label = tester.getRect(find.descendant(
      of: find.byKey(const ValueKey<String>('btn-connect')),
      // The label and only the label: the button's icon is a `RichText` too, and
      // the ellipsis-plus-two-lines pair is what this file asked for.
      matching: find.byWidgetPredicate((w) =>
          w is RichText &&
          w.overflow == TextOverflow.ellipsis &&
          w.maxLines == 2),
    ));
    final button =
        tester.getRect(find.byKey(const ValueKey<String>('btn-connect')));
    expect(label.width, lessThanOrEqualTo(button.width + 0.01),
        reason: 'the connect label is ${label.width.toStringAsFixed(1)} dp wide '
            'inside a ${button.width.toStringAsFixed(1)} dp button $where');
    expect(label.height, greaterThan(0),
        reason: 'the connect label has no height $where');

    // The bar's width is the screen's — it must not have been widened, which is
    // the other way to stop a row overflowing. Its *painted* height is allowed to
    // exceed the screen: that is the bar's content height, and it only happens
    // where the bar is scrollable, which is asserted below.
    expect(barRect.width, closeTo(size.width, 0.01),
        reason: 'the bar is ${barRect.width} dp wide on a ${size.width} dp '
            'screen $where');

    // Where the bar's content is taller than the body — 320x480 at text scale
    // 1.3 in `en` wants 502 dp of bar in a 480 dp screen — the bar must be
    // **scrolled**, not merely clipped: clipped content is unreachable, and the
    // last thing in the bar is the two diagnostics buttons. This is the
    // assertion that the fix is a scroll and not a `ClipRect`.
    final viewport = tester.getRect(find.byType(Scrollable).first);
    expect(viewport.height, lessThanOrEqualTo(size.height + 0.01),
        reason: 'the scroll viewport is ${viewport.height} dp tall on a '
            '${size.height} dp screen $where');
    expect(viewport.right, closeTo(size.width, 0.01),
        reason: 'the bar no longer spans the screen $where');

    final scrollable = Scrollable.of(
        tester.element(find.byKey(const ValueKey<String>('btn-connect'))));
    if (barRect.height > viewport.height + 0.01) {
      expect(scrollable.position.maxScrollExtent,
          closeTo(barRect.height - viewport.height, 1.0),
          reason: 'the bar is ${barRect.height} dp of content in a '
              '${viewport.height} dp viewport $where, so it must scroll by the '
              'difference — and only by it');
      // Reachability, measured rather than asserted in the abstract: scroll the
      // bar to its end and require the last control to be inside the viewport
      // afterwards. "It is in the tree" is not the same claim.
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      final last = find.byKey(const ValueKey<String>('btn-wifi-diagnostics'));
      // Dragged from the bar's own left padding rather than from the control:
      // the control is off screen at this point — that is the whole reason for
      // scrolling — and a drag aimed at it would hit nothing.
      await tester.dragFrom(
        Offset(viewport.left + 8, viewport.bottom - 8),
        Offset(0, -scrollable.position.maxScrollExtent),
      );
      await tester.pumpAndSettle();
      final reached = tester.getRect(last);
      final window = tester.getRect(find.byType(Scrollable).first);
      expect(reached.bottom, lessThanOrEqualTo(window.bottom + 0.01),
          reason: 'scrolling the bar as far as it goes still leaves '
              'btn-wifi-diagnostics off screen $where');
      expect(reached.top, greaterThanOrEqualTo(window.top - 0.01),
          reason: 'btn-wifi-diagnostics is above the viewport $where');
    }
  }

  /// The widths the suite already uses, plus the narrow phone from `AGENTS.md` §5.
  const portrait = <Size>[
    Size(320, 480), // a small phone, the settings panel's own short-screen case
    Size(320, 727),
    Size(360, 640),
    Size(376, 727), // one dp under the ~386 dp the row needed at 320
    Size(411, 727), // the maintainer's phone, the reported overflow
    Size(480, 727),
  ];
  const landscape = <Size>[
    Size(568, 320), // a 320 dp phone rotated
    Size(727, 411), // the maintainer's phone rotated
    Size(914, 297), // the measured landscape body from the overflow test
  ];
  const scales = <double>[1.0, 1.3, 1.5, 2.0]; // as `live_view_text_scale_test`
  const locales = <Locale>[Locale('en'), Locale('zh')];

  for (final locale in locales) {
    for (final scale in scales) {
      for (final size in portrait) {
        testWidgets(
            'connect bar fits ${size.width.toInt()}x${size.height.toInt()} '
            'at text scale $scale in ${locale.languageCode}', (tester) async {
          await pumpDisconnected(tester, size, scale, locale);
          await expectBarFits(
              tester,
              size,
              'at ${size.width.toInt()}x${size.height.toInt()}, text scale '
              '$scale, ${locale.languageCode}');
        });
      }
      for (final size in landscape) {
        testWidgets(
            'connect bar fits landscape ${size.width.toInt()}x'
            '${size.height.toInt()} at text scale $scale in '
            '${locale.languageCode}', (tester) async {
          await pumpDisconnected(tester, size, scale, locale);
          await expectBarFits(
              tester,
              size,
              'in landscape ${size.width.toInt()}x${size.height.toInt()}, '
              'text scale $scale, ${locale.languageCode}');
        });
      }
    }
  }

  for (final locale in locales) {
    testWidgets(
        'the bar keeps its controls on one line when there is room, '
        '${locale.languageCode}', (tester) async {
      // The reported symptom was the *row*, so a fix that stacks everything
      // vertically would satisfy every overflow check above and be a different
      // screen. The controls' **natural** widths are measured on a body wide
      // enough that nothing is compressed: measuring them at 411 dp would
      // measure them already squeezed by the very defect this file is about.
      await pumpDisconnected(tester, const Size(1200, 727), 1.0, locale);
      expectNoOverflow(tester, 'before the one-line check');
      final wanted = <String, double>{
        for (final key in const <String>[
          'btn-connect',
          'btn-ble-diagnostics',
          'btn-wifi-diagnostics',
        ])
          key: tester.getSize(find.byKey(ValueKey<String>(key))).width,
      };

      await pumpDisconnected(tester, const Size(411, 727), 1.0, locale);
      expectNoOverflow(tester, 'before the one-line check at 411 dp');
      final bar = tester.getRect(barFinder());
      final needed = wanted.values.fold<double>(0, (a, w) => a + w) + 16;
      if (needed > bar.width - 32) {
        // The three controls genuinely do not fit on one line here, so which
        // shape the bar takes is the layout's choice. What is not optional was
        // asserted above: it may not overflow, and no control may be squeezed
        // below the tap target or pushed outside the bar.
        return;
      }
      final connect =
          tester.getRect(find.byKey(const ValueKey<String>('btn-connect')));
      final ble = tester
          .getRect(find.byKey(const ValueKey<String>('btn-ble-diagnostics')));
      expect(ble.center.dy, closeTo(connect.center.dy, 1.0),
          reason: '${locale.languageCode}: ${needed.toStringAsFixed(1)} dp of '
              'controls in ${(bar.width - 32).toStringAsFixed(1)} dp of room, '
              'and they are not on one line — the bar was restacked rather '
              'than made to fit');
    });

    testWidgets('at 411 dp the ${locale.languageCode} bar is shaped as '
        'documented', (tester) async {
      // The shape change this fix makes on the maintainer's own screen, pinned
      // so it cannot change silently — `analysis/73` §5 lists it as
      // user-visible. In English at the default text scale the label is wide
      // enough that the Wi-Fi button drops to a second run; in Chinese it is
      // not, and all three stay on one line. If a future fix changes either,
      // that is a change to what the user sees and the report has to say so.
      await pumpDisconnected(tester, const Size(411, 727), 1.0, locale);
      expectNoOverflow(tester, 'before the shape check');
      final connect =
          tester.getRect(find.byKey(const ValueKey<String>('btn-connect')));
      final ble = tester
          .getRect(find.byKey(const ValueKey<String>('btn-ble-diagnostics')));
      final wifi = tester
          .getRect(find.byKey(const ValueKey<String>('btn-wifi-diagnostics')));
      if (locale.languageCode == 'en') {
        expect(wifi.center.dy, greaterThan(connect.center.dy + 1),
            reason: 'the en label is too wide for one line at 411 dp, so the '
                'Wi-Fi button wrapping to a second run is the expected shape — '
                'if it is now on one line, the layout changed and §5 of '
                'analysis/73 is out of date');
      } else {
        expect(wifi.center.dy, closeTo(connect.center.dy, 1.0),
            reason: 'the zh label is short enough for one line at 411 dp; a '
                'second run here is a shape change');
      }
      expect(ble.center.dy, closeTo(connect.center.dy, 1.0),
          reason: '${locale.languageCode}: the BLE button is on the first line '
              'at 411 dp');
    });
  }
}
