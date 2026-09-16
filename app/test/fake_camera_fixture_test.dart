import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';

/// The verification harness must not lie about what it is showing.
///
/// `fakeVerificationImage()` feeds the album grid and the viewer when the app is
/// run with `--dart-define=FAKE_CAMERA=1`. If those bytes are not a real JPEG then
/// `Image.memory` throws `Exception: Invalid image data`, both screens draw their
/// `errorBuilder` placeholder instead, and a visual pass would report "the grid is
/// broken" — or worse, look plausible while verifying nothing.
///
/// So the harness's own fixture gets a check. It is the one part of this repo whose
/// failure mode is *silently making other verification meaningless*.
void main() {
  testWidgets('the fake camera image really decodes', (tester) async {
    final bytes = fakeVerificationImage();
    expect(bytes.isNotEmpty, isTrue);

    // The format markers, and specifically **JPEG**: the album names these files
    // `.JPG`, and the sync engine refuses to store a `.JPG` that does not end with
    // the end-of-image marker. A PNG fixture therefore made every transfer fail with
    // "truncated image (missing end-of-image marker) — retrying", which reads as a
    // bug in the transfer path and is really the harness being wrong.
    //
    // The previous version of this test checked only that the bytes *decoded*, which a
    // PNG satisfies — so it passed while the sync path it feeds was failing. Checking
    // the format the consumer validates is the point.
    expect(bytes.take(2).toList(), [0xFF, 0xD8], reason: 'no JPEG SOI marker');
    expect(bytes.skip(bytes.length - 2).toList(), [0xFF, 0xD9],
        reason: 'no JPEG EOI marker — the sync engine rejects this as truncated');

    // `runAsync` is required and is the whole reason this test is written the way
    // it is: a widget test runs in a fake-async zone where the engine's real image
    // decoder never completes, so `pump` would report "no frame" for a perfectly
    // good JPEG. The first version of this check did exactly that and produced a
    // false failure.
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
      expect(frame.image.height, greaterThan(0));
      frame.image.dispose();
      codec.dispose();
    });

    expect(tester.takeException(), isNull,
        reason: 'the fixture threw while decoding');
  });

  testWidgets('the fake album page exercises the cases the UI distinguishes',
      (tester) async {
    // A page of identical JPEGs would render, look fine, and verify none of the
    // pairing or badging logic — so the fixture's *content* is asserted too.
    final page = fakeAlbumPage();
    final types = page.map((e) => (e as Map)['filetype']).toList();

    expect(types.where((t) => t == 'picture').length, greaterThanOrEqualTo(2));
    expect(types, contains('raw'), reason: 'no RAW-only shot: the RAW badge is '
        'never exercised');
    expect(types, contains('video'), reason: 'no video: the VIDEO badge is never '
        'exercised');

    // A RAW+JPEG pair is one shot in two entries sharing a stem and a timestamp;
    // without one, the single-row-per-shutter-press rule is untested by eye.
    final paths = page.map((e) => (e as Map)['path'] as String).toList();
    final paired = paths.where((p) => p.endsWith('YI000002.JPG')).isNotEmpty &&
        paths.where((p) => p.endsWith('YI000002.DNG')).isNotEmpty;
    expect(paired, isTrue, reason: 'no RAW+JPEG pair in the fixture');

    // `date` must be a *string* of seconds: the real firmware sends it that way and
    // `AlbumFile.fromJson` parses a string, so a fixture using an int would take a
    // path production never takes.
    for (final entry in page) {
      expect((entry as Map)['date'], isA<String>(),
          reason: 'the firmware sends the date as a string');
    }

    // Short page = the firmware's own end-of-album signal, so the grid must not
    // page forever looking for a 60-entry page that will never come.
    expect(page.length, lessThan(60),
        reason: 'a full page would make the album ask for page 2 forever');
  });
}
