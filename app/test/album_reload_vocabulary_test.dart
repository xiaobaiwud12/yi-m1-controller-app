import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// Three listing operations, three names.
///
/// ## What was wrong
///
/// The user reported that the toolbar button and the prompt shown just after
/// connecting "conflict a little". They did, and not because of the wording alone:
/// three different operations all read as "fetch the listing again".
///
/// | control | what it really did |
/// |---|---|
/// | toolbar refresh, tooltip *"Reload from the first page"* | threw away the listing, the thumbnails, the paging position and the delete report |
/// | empty state, *"Reload"* | called `_loadPage` |
/// | read-failure state, *"Retry"* | also called `_loadPage` |
///
/// ## What these checks are about
///
/// Not spelling: **which operation a control performs**, established by counting
/// `GetFileList` requests. A toolbar refresh that quietly stopped re-listing, or an
/// empty-state button that quietly became a full reset, would still "look right" in a
/// screenshot and would still pass a check that counted buttons.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_vocab_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS to reclaim
    }
  });

  /// An app whose every command is recorded, and which can be made to fail the
  /// listing on demand.
  AppState appWith({required List<String> commands, bool listingFails = false}) =>
      AppState(
        ble: FakeBleTransport(),
        sink: NullAssetSink(),
        testIdentity: const CameraIdentity(
          protocolVersion: 1,
          firmwareVersion: '3.1-cn ',
          regionMarker: 'M1CN',
        ),
        testHttp: CameraHttpClient(overrideSend: (command, params) async {
          commands.add(command);
          if (command == 'GetFileList') {
            if (listingFails) {
              return const CameraResponse(
                code: 1000,
                data: 'busy',
                raw: '{"code":1000,"data":"busy"}',
              );
            }
            // An empty but successful listing: this is the "No photos found" state,
            // which is where one of the two ambiguous buttons lives.
            return const CameraResponse(code: 200, data: [], raw: '{"code":200}');
          }
          return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
        }),
      );

  /// See `sync_list_control_test.dart` for why `runAsync` is required.
  Future<void> pumpAlbum(WidgetTester tester, AppState app) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AlbumPage(app: app),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('no button in the page is labelled just "Reload"', (tester) async {
    final commands = <String>[];
    final app = appWith(commands: commands);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    // The exact word that used to sit on the empty-state button and in the toolbar's
    // tooltip, meaning two different things. Taken from the ARB rather than re-typed:
    // it is the bare name of the toolbar operation, which is the first word of that
    // operation's own tooltip.
    final bareReload = en.albumReloadTooltip.split(' ').first;
    expect(find.widgetWithText(FilledButton, bareReload), findsNothing);
    expect(find.byType(IconButton), findsWidgets);

    // Distinct labels, each describing its own operation.
    expect(find.text(en.albumLookAgain), findsOneWidget);
  });

  testWidgets('the toolbar refresh re-lists the card from the first page',
      (tester) async {
    final commands = <String>[];
    final app = appWith(commands: commands);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    final initial = commands.where((c) => c == 'GetFileList').length;
    expect(initial, greaterThanOrEqualTo(1),
        reason: 'precondition: opening the album lists the card');

    final refresh = find.byKey(const ValueKey<String>('btn-album-reload'));
    expect(refresh, findsOneWidget);

    // The tooltip is the only place a user can read what the icon does, so it has to
    // distinguish this from the other two.
    expect(tester.widget<IconButton>(refresh).tooltip, en.albumReloadTooltip);

    await tester.tap(refresh);
    await tester.pump();

    // A full reset is what this control does, and the honest consequence is that the
    // page then has nothing — so it must **ask again** rather than sitting on a cleared
    // grid that looks like a card with no photos on it. Before this, the reset cleared
    // the listing and stopped; the user was left looking at an empty album.
    expect(commands.where((c) => c == 'GetFileList').length, initial + 1,
        reason: 'reloading everything must actually re-list');
    await tester.pump(const Duration(milliseconds: 20));
    expect(app.lastError, isNull,
        reason: 'the reset must not leave a stale failure behind');
  });

  testWidgets('the empty state offers its own wording and re-asks',
      (tester) async {
    final commands = <String>[];
    final app = appWith(commands: commands);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    expect(find.text(en.albumEmptyTitle), findsOneWidget,
        reason: 'precondition: the injected listing is empty');
    // The bare word is the first word of the retry label — derived from the ARB, not
    // re-typed here.
    expect(find.text(en.albumRetryListing.split(' ').first), findsNothing);
    expect(find.text(en.albumLookAgain), findsOneWidget);

    final before = commands.where((c) => c == 'GetFileList').length;
    await tester.tap(find.byKey(const ValueKey<String>('btn-album-look-again')));
    await tester.pump(const Duration(milliseconds: 20));
    expect(commands.where((c) => c == 'GetFileList').length, before + 1,
        reason: 'the empty state must ask the card again');
  });

  testWidgets('a failed listing gets a named control and a key of its own',
      (tester) async {
    final commands = <String>[];
    final app = appWith(commands: commands, listingFails: true);
    addTearDown(app.dispose);
    await pumpAlbum(tester, app);

    expect(find.text(en.albumReadFailedTitle), findsOneWidget,
        reason: 'precondition: the injected listing fails');
    expect(find.text(en.albumRetryListing.split(' ').first), findsNothing,
        reason: 'bare "Retry" collided with the empty state and the toolbar');
    expect(find.text(en.albumRetryListing), findsOneWidget);

    // Keyed, so it can be tapped by a machine rather than by coordinate: a control
    // with no key cannot be verified, which is how this page's reload vocabulary
    // drifted in the first place.
    final retry = find.byKey(const ValueKey<String>('btn-album-retry-listing'));
    expect(retry, findsOneWidget);

    final before = commands.where((c) => c == 'GetFileList').length;
    await tester.tap(retry);
    await tester.pump(const Duration(milliseconds: 20));
    expect(commands.where((c) => c == 'GetFileList').length, before + 1);
  });
}
