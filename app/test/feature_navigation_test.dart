import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';
import 'package:yi_m1_controller/features/album/presentation/album_page.dart';
import 'package:yi_m1_controller/features/video/presentation/video_page.dart';
import 'package:yi_m1_controller/features/live_view/presentation/live_view_page.dart';

import 'fakes.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Native thumbnail/file I/O is outside the fake clock. Do not wait for an
    // animated spinner with pumpAndSettle: advance native work and stop early.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 2));
      if (!tester.binding.hasScheduledFrame &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        return;
      }
    }
  }

  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('yi_m1_navigation_');
    useTempStorage(temp.path);
    useMediaChannel(bytes: jpegFixture, reads: []);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  testWidgets('shell tabs are reachable by stable keys in both locales',
      (tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });
    final app = await tester.runAsync(() async {
      final state = connectedTestAppState(
        albumDownload: (_, __) async => jpegFixture,
      );
      await state.loadDurableState();
      return state;
    });
    expect(app, isNotNull);
    await tester.pumpWidget(YiM1ControllerApp(
      testHome: HomeShell(testApp: app),
    ));
    await settle(tester);

    for (final locale in ['en', 'zh']) {
      app!.localeTag = locale;
      await settle(tester);
      final capture = find.byKey(const ValueKey('btn-nav-capture'));
      final sync = find.byKey(const ValueKey('btn-nav-sync'));
      expect(capture, findsOneWidget);
      expect(sync, findsOneWidget);
      expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          0);

      await tester.tap(sync);
      await settle(tester);
      expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          1);
      expect(find.byType(AlbumPage), findsOneWidget);
      expect(find.byType(LiveViewPage), findsNothing);

      await tester.tap(capture);
      await settle(tester);
      expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          0);
      expect(find.byType(LiveViewPage), findsOneWidget);
      expect(find.byType(AlbumPage), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the shell handles live-view album and video navigation',
      (tester) async {
    final app = await tester.runAsync(() async {
      final state = connectedTestAppState(
        albumDownload: (_, __) async => jpegFixture,
      );
      await state.loadDurableState();
      return state;
    });
    expect(app, isNotNull);
    await tester.pumpWidget(YiM1ControllerApp(
      testHome: HomeShell(testApp: app),
    ));
    await tester.pump();

    final albumButton = find.byKey(const ValueKey('btn-live-open-album'));
    expect(albumButton, findsOneWidget);
    await tester.ensureVisible(albumButton);
    await tester.tap(albumButton);
    await settle(tester);
    expect(find.byType(AlbumPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(AlbumPage))).pop();
    await settle(tester);

    final videoButton = find.byKey(const ValueKey('btn-live-open-video'));
    expect(videoButton, findsOneWidget);
    await tester.ensureVisible(videoButton);
    await tester.tap(videoButton);
    await settle(tester);
    expect(find.byType(VideoPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
