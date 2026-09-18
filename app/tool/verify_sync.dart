/// Offline checks for the sync engine, RAW pairing and the sync ledger.
///
/// These are the parts of the album feature most likely to be subtly wrong —
/// deduplication across a clock change, preview-then-upgrade ordering, never
/// silently downgrading, and treating a vanished camera as a pause — and none of
/// them need a camera to exercise.  Run:
///
///     dart run tool/verify_sync.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yi_m1_controller/sync/asset_group.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/exif_wall_clock.dart';
import 'package:yi_m1_controller/sync/stream_pause_contract.dart';
import 'package:yi_m1_controller/sync/sync_engine.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/sync/transfer_queue.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/camera_connection.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('  PASS  $name');
  } else {
    _fail++;
    print('  FAIL  $name${detail == null ? '' : '  -- $detail'}');
  }
}

// ---------------------------------------------------------------------------

AlbumFile jpg(String name, {int date = 1700000000, String dir = '101YICAM'}) =>
    AlbumFile(
      path: '/DCIM/$dir/$name.JPG',
      fileType: 'picture',
      captureTime: DateTime.fromMillisecondsSinceEpoch(date * 1000),
    );

AlbumFile raw(String name, {int date = 1700000000, String dir = '101YICAM'}) =>
    AlbumFile(
      path: '/DCIM/$dir/$name.DNG',
      fileType: 'raw',
      captureTime: DateTime.fromMillisecondsSinceEpoch(date * 1000),
    );

/// A JPEG whose last two bytes are the EOI marker.
Uint8List jpegBytes([int size = 64]) {
  final b = Uint8List(size);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[size - 2] = 0xFF;
  b[size - 1] = 0xD9;
  return b;
}

/// A JPEG that was truncated in transit — the corruption this camera is most
/// likely to produce.
Uint8List truncatedJpeg([int size = 64]) {
  final b = Uint8List(size);
  b[0] = 0xFF;
  b[1] = 0xD8;
  return b;
}

// ---------------------------------------------------------------- EXIF fixture

/// The `YYYY:MM:DD HH:MM:SS` fields inside a buffer, found by scanning for the
/// shape rather than by walking the TIFF structure.
///
/// Deliberately **not** a parser shared with the code under test: a check that
/// finds the fields the same way the writer finds them agrees with the writer even
/// when both are wrong (`analysis/79`, four independent auditors). This is also
/// exactly how a superficially-written EXIF reader — a gallery, `strings`, a
/// desktop viewer — locates a date, so it is the consumer's own view of the file.
final RegExp _dateStamp = RegExp(r'\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}');

List<({int at, String text})> dateStamps(Uint8List b) => [
      for (final m in _dateStamp.allMatches(latin1.decode(b)))
        (at: m.start, text: m.group(0)!),
    ];

/// The instant a consumer derives from a naive EXIF date string.
///
/// **EXIF has no timezone field.** `DateTimeOriginal` and friends are the camera's
/// *local wall clock*, and every reader — Android's `ExifInterface`,
/// MediaProvider's `DATE_TAKEN` derivation, a desktop viewer — interprets them in
/// the zone of whoever is looking. So this is written as an independent
/// implementation of the reader's rule, not by calling the writer under test.
DateTime instantFromExifStamp(String s) {
  final p = s.split(RegExp(r'[: ]'));
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]),
      int.parse(p[3]), int.parse(p[4]), int.parse(p[5]));
}

/// `YYYY:MM:DD HH:MM:SS` for a `DateTime`, as an EXIF date field spells it.
String wallClock(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}:${two(t.month)}:${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// The wall clock the **camera** writes, as the fixture's model of the body.
///
/// The body has one clock and no timezone at all: the firmware image contains the
/// single string `GMT` and no offset table (`analysis/_frag-clock.md` §D.5), and
/// the RTC is set from the app's BLE time-sync, which sends Unix epoch seconds
/// (`wire_format.dart`, verified against the official app). A clock with no zone
/// formats a naive date field as GMT — i.e. as the **UTC wall clock**.
///
/// Measured, not invented: `app/capture_test/probe_original.jpg`, an `Original`
/// fetched from the 3.1-cn body, carries three date fields and all three read
/// `2026:09:14 00:49:06`.
String gmtStamp(int epochSeconds) => wallClock(
    DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true));

/// A JPEG shaped like the ones the real M1 writes, with [exifDate] in all three
/// date fields.
///
/// The structure is the measured one (`probe_original.jpg`, decoded tag by tag):
/// little-endian TIFF, IFD0 at TIFF+8, `0x0132` in IFD0, `0x8769` pointing at an
/// ExifIFD holding `0x9003` and `0x9004`, and each of the three fields an ASCII
/// value of **count 20** — nineteen characters, a NUL, and one pad byte, stored
/// out of line. `DateTimeOriginal` really is present on this body; an earlier note
/// in `analysis/44` that the M1 JPEG has no such tag is wrong for the file that is
/// in the tree.
///
/// The fixture checks its own shape and throws rather than letting a malformed
/// fixture quietly weaken every check that reads it (`AGENTS.md` §8: a fixture's
/// failure mode is to make other verifications meaningless). It earned that on the
/// first run of the new code: the date-shape validator refused all three fields
/// because it expected colons at two positions that do not have them, and only a
/// fixture with the real `YYYY:MM:DD HH:MM:SS` layout could show that.
Uint8List m1Jpeg({
  required String exifDate,
  int bodyBytes = 64,
  bool littleEndian = true,
  int? decoyValueOffset,
}) {
  final tiff = measuredTiff(
    exifDate: exifDate,
    littleEndian: littleEndian,
    decoyValueOffset: decoyValueOffset,
  );
  final out = BytesBuilder();
  out.add([0xFF, 0xD8]); // SOI
  final app1Len = 2 + 6 + tiff.length;
  out.add([0xFF, 0xE1, (app1Len >> 8) & 0xFF, app1Len & 0xFF]);
  out.add(ascii.encode('Exif\u0000\u0000'));
  out.add(tiff);
  out.add(Uint8List(bodyBytes)); // entropy-coded data stand-in
  out.add([0xFF, 0xD9]); // EOI — the engine's integrity check wants this
  return out.toBytes();
}

/// The measured IFD structure on its own, as a bare TIFF — which is what the
/// camera's `.DNG` files are.
///
/// [decoyValueOffset] moves the `0x0132` entry's value offset without moving the
/// data, which is how a malformed (or hostile) file points a date field at bytes
/// that are not a date field at all.
Uint8List measuredTiff({
  required String exifDate,
  bool littleEndian = true,
  int? decoyValueOffset,
}) {
  if (exifDate.length != 19) {
    throw ArgumentError.value(exifDate, 'exifDate', 'must be 19 characters');
  }
  const ifd0At = 8;
  const ifd0Bytes = 2 + 2 * 12 + 4;
  const exifIfdAt = ifd0At + ifd0Bytes;
  const exifIfdBytes = 2 + 2 * 12 + 4;
  const dateAt = exifIfdAt + exifIfdBytes;
  const tiffBytes = dateAt + 3 * 20;

  final tiff = Uint8List(tiffBytes);
  void u16(int o, int v) {
    if (littleEndian) {
      tiff[o] = v & 0xFF;
      tiff[o + 1] = (v >> 8) & 0xFF;
    } else {
      tiff[o] = (v >> 8) & 0xFF;
      tiff[o + 1] = v & 0xFF;
    }
  }

  void u32(int o, int v) {
    if (littleEndian) {
      u16(o, v & 0xFFFF);
      u16(o + 2, (v >> 16) & 0xFFFF);
    } else {
      u16(o, (v >> 16) & 0xFFFF);
      u16(o + 2, v & 0xFFFF);
    }
  }

  tiff[0] = littleEndian ? 0x49 : 0x4D;
  tiff[1] = littleEndian ? 0x49 : 0x4D;
  u16(2, 42);
  u32(4, ifd0At);

  u16(ifd0At, 2);
  var e = ifd0At + 2;
  u16(e, 0x0132); // DateTime
  u16(e + 2, 2); // ASCII
  u32(e + 4, 20);
  u32(e + 8, decoyValueOffset ?? dateAt);
  e += 12;
  u16(e, 0x8769); // ExifIFD pointer
  u16(e + 2, 4); // LONG
  u32(e + 4, 1);
  u32(e + 8, exifIfdAt);
  e += 12;
  u32(e, 0); // no IFD1

  u16(exifIfdAt, 2);
  e = exifIfdAt + 2;
  u16(e, 0x9003); // DateTimeOriginal
  u16(e + 2, 2);
  u32(e + 4, 20);
  u32(e + 8, dateAt + 20);
  e += 12;
  u16(e, 0x9004); // DateTimeDigitized
  u16(e + 2, 2);
  u32(e + 4, 20);
  u32(e + 8, dateAt + 40);
  e += 12;
  u32(e, 0);

  final stamp = ascii.encode(exifDate);
  for (final at in [dateAt, dateAt + 20, dateAt + 40]) {
    tiff.setRange(at, at + stamp.length, stamp);
  }
  return tiff;
}

/// A JPEG whose APP1 header claims EXIF and then points past the end of the file.
///
/// The transform that normalises the date runs on **every** published byte, so its
/// behaviour on a file it cannot parse is as important as its behaviour on the M1's
/// own shape: it must return the input untouched rather than throw — a thrown
/// exception here would fail a transfer of a perfectly good photo — and it must not
/// write at an offset taken from a field it never validated.
Uint8List lyingExifJpeg() {
  final b = <int>[0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x14];
  b.addAll(ascii.encode('Exif\u0000\u0000'));
  b.addAll([0x49, 0x49, 0x2A, 0x00]); // little-endian TIFF
  b.addAll([0xFF, 0xFF, 0xFF, 0x7F]); // IFD0 at 0x7FFFFFFF: far outside
  b.addAll(List<int>.filled(32, 0x5A));
  b.addAll([0xFF, 0xD9]);
  return Uint8List.fromList(b);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A sink that keeps what it was handed, so a check can read the bytes the way
/// the gallery's indexer will.
class RecordingSink implements AssetSink {
  final List<
      ({
        String fileName,
        AssetQuality quality,
        DateTime? capturedAt,
        Uint8List bytes,
      })> writes = [];

  /// The bytes stored for one file and rendition, or null when it was not stored.
  Uint8List? bytesFor(String fileName, AssetQuality quality) {
    for (final w in writes) {
      if (w.fileName == fileName && w.quality == quality) return w.bytes;
    }
    return null;
  }

  @override
  Future<String> store({
    required String assetKey,
    required String fileName,
    required Uint8List bytes,
    required AssetQuality quality,
    DateTime? capturedAt,
  }) async {
    writes.add((
      fileName: fileName,
      quality: quality,
      capturedAt: capturedAt,
      bytes: bytes,
    ));
    return 'record://$assetKey/${quality.name}';
  }

  @override
  Future<void> replace(String localId, Uint8List bytes) async {}
}

/// A CameraAlbum wired to a scripted download, so the engine can run offline.
CameraAlbum fakeAlbum({
  required Future<Uint8List> Function(AlbumFile, FileResolution) onDownload,
}) =>
    CameraAlbum(
      CameraHttpClient(
        overrideSend: (cmd, p) async =>
            CameraResponse(code: 200, raw: '{"code":200}', data: const []),
      ),
      overrideDownload: onDownload,
    );

// ---------------------------------------------------------------------------

/// A scripted stand-in for the camera's stream, so the pause can be checked
/// without hardware.
///
/// The failure modes that matter here are the ones a happy-path test cannot see:
/// a stream that is never resumed, one that is resumed while somebody else still
/// needs it paused, and one left paused because the pause command itself was
/// refused.  So the fake is deliberately as awkward as the real thing — it can
/// refuse to pause, it can throw, and it keeps exact counts of both commands.
class FailingAssetSink implements AssetSink {
  @override
  Future<String> store({
    required String assetKey,
    required String fileName,
    required Uint8List bytes,
    required AssetQuality quality,
    DateTime? capturedAt,
  }) async {
    throw StateError('MediaStore did not publish $fileName');
  }

  @override
  Future<void> replace(String localId, Uint8List bytes) async {}
}

class FakeStreamPause implements StreamPauseController {
  /// Whether the stream is currently paused.  This is the observation every
  /// check below is really making.
  bool paused = false;

  /// False simulates the untested firmware refusing `PauseMovieStream`; true (the
  /// default) simulates it being accepted.
  bool pauseOk;

  /// When set, `pause()` throws instead of returning — the transport failing
  /// rather than the camera refusing.
  bool throwOnPause;

  /// When set, `resume()` throws.  The engine must still not leave its own
  /// accounting stuck, because that would strand every later run.
  bool throwOnResume;

  int pauseCalls = 0;
  int resumeCalls = 0;

  FakeStreamPause({
    this.pauseOk = true,
    this.throwOnPause = false,
    this.throwOnResume = false,
  });

  @override
  Future<bool> pause() async {
    pauseCalls++;
    if (throwOnPause) throw StateError('transport died during pause');
    if (!pauseOk) return false;
    paused = true;
    return true;
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    if (throwOnResume) throw StateError('transport died during resume');
    paused = false;
    return true;
  }
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== RAW+JPEG pairing ===');

  final paired = groupAssets([
    jpg('YI000001'),
    raw('YI000001'),
    jpg('YI000002'),
  ]);
  // Looked up by name rather than by index, because `groupAssets` now returns
  // **newest first** and every shot in this fixture shares one timestamp — so the
  // filename tie-break puts `YI000002` ahead of the pair, and `paired.first` is no
  // longer the pair. A check that reads position here would be measuring the
  // fixture, not the pairing.
  AssetGroup groupNamed(List<AssetGroup> groups, String name) =>
      groups.firstWhere((g) => g.primary.fileName == name,
          orElse: () => throw StateError('no group for $name in $groups'));

  final pair = groupNamed(paired, 'YI000001.JPG');
  check('a RAW+JPEG shot becomes one group', paired.length == 2,
      '${paired.length} groups');
  check('the JPEG is the primary, so it is what the user sees first',
      pair.primary.fileName == 'YI000001.JPG');
  check('the RAW is attached to the same group',
      pair.raw?.fileName == 'YI000001.DNG');
  check('the group reports a pair', pair.isPair);
  check('an unpaired shot stays a single asset',
      !groupNamed(paired, 'YI000002.JPG').isPair);
  check('the badge names the pairing', pair.badge == 'RAW+JPG');
  check('a plain photo has no badge',
      groupNamed(paired, 'YI000002.JPG').badge.isEmpty);
  check('one shutter press is not counted twice',
      paired.fold<int>(0, (n, g) => n + g.assets.length) == 3);
  check('grouping returns the listing newest first, not in listing order',
      paired.first.primary.fileName == 'YI000002.JPG',
      paired.map((g) => g.primary.fileName).join(','));

  // Order of arrival must not matter: the listing has been seen either way.
  final reversed = groupAssets([raw('YI000003'), jpg('YI000003')]);
  check('pairing works when the RAW arrives first',
      reversed.length == 1 && reversed.first.primary.fileName == 'YI000003.JPG',
      '$reversed');

  // The same basename in two folders must NOT pair: the test card really does
  // have both 100YICAM and 101YICAM.
  final twoDirs = groupAssets([
    jpg('YI000001', dir: '100YICAM'),
    raw('YI000001', dir: '101YICAM'),
  ]);
  check('the same basename in different folders does not pair',
      twoDirs.length == 2, '${twoDirs.length} groups');

  // Same name, same folder, different second -> different shots (a card format
  // reusing the numbering).
  final reused = groupAssets([
    jpg('YI000001', date: 1700000000),
    raw('YI000001', date: 1800000000),
  ]);
  check('the same name at a different time does not pair', reused.length == 2,
      '${reused.length} groups');

  final rawOnly = AssetGroup(raw('YI000009'));
  check('a RAW-only shot is labelled', rawOnly.badge == 'RAW' && rawOnly.isRawOnly);

  // ------------------------------------------------- the album's order
  //
  // Reported from hardware: "app内相册的照片没有排序" — the photos in the app's
  // album are not sorted. The listing the camera returns is a **ring**, measured
  // with 99 files (`analysis/61` §8): first entry `P9150040.JPG`, last entry
  // `P9150039.JPG`, so it wraps and is neither capture order nor filename order.
  // The page appended it verbatim, so the grid was an arbitrary rotation of the
  // card — and the maintainer nearly deleted the wrong photo by trusting it.
  print('\n=== album order: the listing is a ring, the album is not ===');

  /// One entry in the shape the real firmware sends: a `.JPG` path, `rawJpeg`.
  AlbumFile ring(String name, {String? date}) => AlbumFile(
        path: '/DCIM/100YICAM/$name',
        fileType: name.toUpperCase().endsWith('.DNG') ? 'raw' : 'rawJpeg',
        captureTime: date == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(int.parse(date) * 1000),
      );

  // The measured ring, to scale: 99 files, shot `P9150001` first and `P9150099`
  // last, returned **starting at `P9150040` and wrapping**. Capture order and
  // listed order therefore disagree by 60 positions, which is the whole point —
  // a fixture that happens to be in capture order cannot fail this check.
  final ringOrder = <AlbumFile>[
    for (var n = 40; n <= 99; n++)
      ring('P9150${n.toString().padLeft(3, '0')}.JPG', date: '${1789400000 + n}'),
    for (var n = 1; n <= 39; n++)
      ring('P9150${n.toString().padLeft(3, '0')}.JPG', date: '${1789400000 + n}'),
  ];
  check('the fixture really is the camera\'s ring, not a sorted list',
      ringOrder.length == 99 &&
          ringOrder.first.path.endsWith('P9150040.JPG') &&
          ringOrder.last.path.endsWith('P9150039.JPG'),
      '${ringOrder.length} entries, ${ringOrder.first.path} .. ${ringOrder.last.path}');

  final ordered = groupAssets(ringOrder);
  check('grouping does not lose or invent shots from the ring',
      ordered.length == 99, '${ordered.length}');

  var outOfOrder = 0;
  for (var i = 1; i < ordered.length; i++) {
    final prev = ordered[i - 1].captureTime!;
    final here = ordered[i].captureTime!;
    if (here.isAfter(prev)) outOfOrder++;
  }
  check('the album is in capture order, newest first', outOfOrder == 0,
      '$outOfOrder inversion(s); first=${ordered.first.primary.fileName} '
      'last=${ordered.last.primary.fileName}');
  check('the newest shot on the card is the first tile',
      ordered.first.primary.fileName == 'P9150099.JPG',
      ordered.first.primary.fileName);
  check('and the oldest is the last',
      ordered.last.primary.fileName == 'P9150001.JPG',
      ordered.last.primary.fileName);

  // The tie-break, and why it has to exist: `date` is whole **seconds**, so a
  // burst is several frames inside one second. Without a stable second key those
  // frames are tied, and a tied sort returns them in input order — i.e. the ring
  // order, which is the one thing that changes between listings. The burst would
  // then shuffle on every reload.
  final burst = groupAssets([
    for (final n in [60, 57, 59, 58])
      ring('P91500$n.JPG', date: '1789401000'),
  ]);
  check('frames inside one second keep the camera\'s numbering',
      burst.map((g) => g.primary.fileName).join(',') ==
          'P9150060.JPG,P9150059.JPG,P9150058.JPG,P9150057.JPG',
      burst.map((g) => g.primary.fileName).join(','));
  check('the burst is ordered by filename descending, not by arrival',
      compareGroupsNewestFirst(burst[0], burst[1]) < 0 &&
          compareGroupsNewestFirst(burst[1], burst[2]) < 0 &&
          compareGroupsNewestFirst(burst[2], burst[3]) < 0);

  // The numbering rolls over to four digits, and the string compare has to agree
  // with the camera's counting there — it does only because the firmware pads.
  final rollover = groupAssets([
    ring('P9150099.JPG', date: '1789402000'),
    ring('P9150100.JPG', date: '1789402000'),
  ]);
  check('the tie-break holds across the 99 -> 100 roll-over',
      rollover.first.primary.fileName == 'P9150100.JPG',
      rollover.map((g) => g.primary.fileName).join(','));

  // A listing with no usable date: the tile already falls back to drawing the
  // filename, so the order must not invent a capture instant either. The
  // temptation is to sort on the `0` that `AssetGroup.id` substitutes, which
  // would file every undated shot under 1970 — worse as a *claim* than as a
  // position, because it looks deliberate.
  final undated = groupAssets([
    ring('P9150005.JPG', date: '1789400005'),
    ring('P9150110.JPG'),
    ring('P9150001.JPG', date: '1789400001'),
  ]);
  check('a shot with no capture time is kept, not dropped',
      undated.length == 3, '${undated.length}');
  check('it sorts after every shot that has a date',
      undated.last.primary.fileName == 'P9150110.JPG',
      undated.map((g) => g.primary.fileName).join(','));
  check('and the dated ones are still newest first',
      undated.first.primary.fileName == 'P9150005.JPG' &&
          undated[1].primary.fileName == 'P9150001.JPG',
      undated.map((g) => g.primary.fileName).join(','));

  // Re-grouping the same listing must give the same answer twice. This is the
  // property the tie-break exists for, stated as the user sees it: reload the
  // album and the photos do not move.
  final again = groupAssets(ringOrder.reversed.toList());
  check('a second listing of the same card produces the same order',
      again.map((g) => g.primary.path).join('|') ==
          ordered.map((g) => g.primary.path).join('|'),
      'the order changed between two listings of identical content');

  // `groupAssets` must not have reordered the caller's list in place: the page
  // feeds the same page to the sync engine right after grouping it.
  final untouched = <AlbumFile>[ring('P9150009.JPG', date: '1789400009')];
  groupAssets(untouched);
  check('grouping copies rather than sorting the caller\'s list in place',
      untouched.length == 1);

  // ---------------------------------------------------------------- ledger

  print('\n=== sync ledger and deduplication ===');

  final ledger = SyncLedger();
  final idA = AssetId(path: '/DCIM/101YICAM/YI000001.JPG', dateSeconds: 1700000000);

  check('an unknown asset is not synced', !ledger.has(idA));
  ledger.record(idA, AssetQuality.preview);
  check('a preview is recorded', ledger.qualityOf(idA) == AssetQuality.preview);
  check('a preview does not count as the original',
      !ledger.has(idA, atLeast: AssetQuality.original));
  check('a preview counts as at least a preview',
      ledger.has(idA, atLeast: AssetQuality.preview));

  ledger.record(idA, AssetQuality.original);
  check('the original is recorded',
      ledger.qualityOf(idA) == AssetQuality.original);

  // A gallery publication failure must not turn an invisible app-private path
  // into a done item. This is the pure-VM contract behind MediaStore retries.
  final failingEngine = SyncEngine(
    album: () => fakeAlbum(
      onDownload: (file, resolution) async => jpegBytes(1024),
    ),
    ledger: SyncLedger(),
    sink: FailingAssetSink(),
  )..cameraConnected();
  failingEngine.enqueue([jpg('YI000099')]);
  await failingEngine.run();
  check('gallery publication failure does not mark original done',
      failingEngine.items.single.stage != SyncStage.done,
      failingEngine.items.single.error ?? 'no error');

  // The critical anti-regression: a failed upgrade must not lose the record of
  // the preview already on disk, or the next run re-downloads it.
  ledger.record(idA, AssetQuality.preview);
  check('quality never goes backwards',
      ledger.qualityOf(idA) == AssetQuality.original);

  // Identity must include the time, because the M1 reuses filenames after a
  // card format.
  final sameNameLater = AssetId(
      path: '/DCIM/101YICAM/YI000001.JPG', dateSeconds: 1800000000);
  check('the same filename at a later time is a different asset',
      !ledger.has(sameNameLater));

  check('identity key is path plus time', idA.key.contains('1700000000'));

  // ------------------------------------------------- where an asset landed

  print('\n=== sync ledger: the local copy, and reading an older file ===');

  // The sync engine used to discard `sink.store`'s return value, so a photo was
  // on the phone with nothing on the app side able to name it — which is why
  // there was no share or open action at all. These assert the identifier is
  // recorded, survives a round trip, and never regresses.
  final idL = AssetId(path: '/DCIM/101YICAM/YI000777.JPG', dateSeconds: 1700000777);
  final storeL = MemorySyncStore();
  final ledgerL = SyncLedger(store: storeL);
  check('an asset never stored has no local identifier',
      ledgerL.localIdOf(idL) == null);

  ledgerL.recordLocal(idL, AssetQuality.preview, 'content://media/1');
  check('the local identifier is recorded',
      ledgerL.localIdOf(idL) == 'content://media/1');
  check('and the quality comes with it',
      ledgerL.qualityOf(idL) == AssetQuality.preview);

  ledgerL.recordLocal(idL, AssetQuality.original, 'content://media/2');
  check('a better rendition replaces the identifier',
      ledgerL.localIdOf(idL) == 'content://media/2');

  // The regression that matters: a late preview arriving after the original must
  // not repoint the album at a 1440x1080 stand-in.
  ledgerL.recordLocal(idL, AssetQuality.preview, 'content://media/1');
  check('a worse rendition does NOT replace the identifier',
      ledgerL.localIdOf(idL) == 'content://media/2',
      '${ledgerL.localIdOf(idL)}');
  check('and does not lower the quality either',
      ledgerL.qualityOf(idL) == AssetQuality.original);

  await ledgerL.save();
  final reloaded = SyncLedger(store: storeL);
  await reloaded.load();
  check('the identifier survives a save and load',
      reloaded.localIdOf(idL) == 'content://media/2',
      '${reloaded.localIdOf(idL)}');
  check('and so does the quality',
      reloaded.qualityOf(idL) == AssetQuality.original);

  // An upgrading user must not lose the record of what is already on their
  // phone: a v1 file is the flat `"key":"quality"` shape with no local ids.
  final v1 = MemorySyncStore(
      '{"version":1,"assets":{"${idL.key}":"original",'
      '"${idA.key}":"preview"}}');
  final fromV1 = SyncLedger(store: v1);
  await fromV1.load();
  check('a version-1 ledger still reports its qualities',
      fromV1.qualityOf(idL) == AssetQuality.original &&
          fromV1.qualityOf(idA) == AssetQuality.preview,
      '${fromV1.qualityOf(idL)} / ${fromV1.qualityOf(idA)}');
  check('and honestly reports no local identifiers for those assets',
      fromV1.localIdOf(idL) == null);

  // The distinction the share feature turns on: "the ledger says this was synced"
  // and "the file is on this phone" are NOT the same claim. A v1 ledger, or a
  // local delete the user asked for, leaves the first true and the second false —
  // and sharing must follow the second, or the share sheet opens with nothing
  // attached.
  check('a recorded quality alone does not make a shot shareable',
      fromV1.qualityOf(idL) == AssetQuality.original &&
          fromV1.localIdOf(idL) == null);

  // A shot that IS located is shareable.
  check('a located shot is shareable',
      reloaded.localIdOf(idL) != null && reloaded.localIdOf(idL)!.isNotEmpty);

  // Forgetting the local copy must not forget the asset itself, or the next sync
  // would re-download a file the user deliberately removed from the phone.
  ledgerL.forgetLocal(idL);
  check('forgetting the local copy keeps the quality record',
      ledgerL.localIdOf(idL) == null &&
          ledgerL.qualityOf(idL) == AssetQuality.original);

  // A path containing quotes and backslashes is what breaks a hand-rolled
  // encoder, and this ledger has a hand-rolled one.
  final nasty = AssetId(path: '/DCIM/a"b\\c/YI000001.JPG', dateSeconds: 1700000001);
  final storeN = MemorySyncStore();
  final ledgerN = SyncLedger(store: storeN);
  ledgerN.recordLocal(nasty, AssetQuality.original, 'content://media/we"ird\\id');
  await ledgerN.save();
  final reloadedN = SyncLedger(store: storeN);
  await reloadedN.load();
  check('a quoted and backslashed path round-trips',
      reloadedN.localIdOf(nasty) == 'content://media/we"ird\\id',
      '${reloadedN.localIdOf(nasty)}');

  // ------------------------------------------------------- sharing the result

  print('\n=== sharing: the MIME type a receiver is offered ===');

  // A wrong type here is silent — the share sheet opens and the receiver refuses
  // the attachment, or the gallery lists a RAW it cannot decode — so the table is
  // pinned. The native `MediaKind` has the same table and its own test.
  check('a JPEG is offered as image/jpeg',
      mimeTypeForName('YI000123.JPG') == 'image/jpeg');
  check('a RAW is not labelled as a JPEG',
      mimeTypeForName('YI000123.DNG') == 'image/x-adobe-dng');
  check('a video is offered as video/mp4',
      mimeTypeForName('YI000123.MP4') == 'video/mp4');
  check('a query string does not defeat the extension',
      mimeTypeForName('content://media/external/images/media/42.jpg?pending=0') ==
          'image/jpeg');
  check('a content URI with no extension is offered as */*',
      mimeTypeForName('content://media/external/images/media/42') == '*/*');
  check('a directory named .jpg does not make its files JPEGs',
      mimeTypeForName('content://x/foo.jpg/42') == '*/*');
  check('a dotfile is a name, not an extension',
      mimeTypeForName('.jpg') == '*/*');
  check('an unknown type is not guessed',
      mimeTypeForName('YI000123.XYZ') == '*/*');

  // Renditions: a preview is shared when the original has not landed, so it must
  // be recognisable rather than passing itself off as the real file.
  check('a preview is recognisable as a rendition',
      isRenditionName('YI000123.JPG.preview.jpg') &&
          isRenditionName('YI000123.JPG.thumb.jpg'));
  check('an original is not a rendition',
      !isRenditionName('YI000123.JPG'));

  // ---------------------------------------------------------------- engine

  print('\n=== sync engine: preview first, then upgrade ===');

  final requested = <String>[];
  final ledger2 = SyncLedger();
  final sink = NullAssetSink();

  final engine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async {
      requested.add('${f.fileName}:${res.wire}');
      return jpegBytes(res == FileResolution.original ? 4096 : 256);
    }),
    ledger: ledger2,
    sink: sink,
  );
  check('unverified stream pause is disabled by default',
      !engine.pauseStreamDuringTransfer);

  // Before connecting, a run must do nothing at all.
  await engine.run();
  check('a run with no camera present does nothing', requested.isEmpty,
      '$requested');

  engine.cameraConnected();
  engine.enqueue([jpg('YI000010')]);
  await engine.run();

  check('preview is fetched before the original', requested.length == 2,
      '$requested');
  check('the first fetch is MidThumb',
      requested.isNotEmpty && requested.first.endsWith('MidThumb'), '$requested');
  check('the second fetch is Original',
      requested.length > 1 && requested[1].endsWith('Original'), '$requested');
  check('the item finishes at original quality',
      engine.items.first.quality == AssetQuality.original);
  check('the item is done', engine.items.first.stage == SyncStage.done);
  check('the ledger recorded the original',
      ledger2.qualityOf(engine.items.first.id) == AssetQuality.original);

  // Re-running must not re-fetch what is already saved.
  requested.clear();
  engine.clearAll();
  engine.enqueue([jpg('YI000010')]);
  await engine.run();
  check('an already-synced asset is not fetched again', requested.isEmpty,
      '$requested');

  // ------------------------------------------------- original-only mode

  print('\n=== sync engine: full-size-only mode ===');

  final requested3 = <String>[];
  final engine3 = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async {
      requested3.add(res.wire);
      return jpegBytes(4096);
    }),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
  )..mode = SyncMode.autoOriginalOnly
   ..cameraConnected()
   ..enqueue([jpg('YI000020')]);
  await engine3.run();
  check('full-size-only mode makes exactly one request', requested3.length == 1,
      '$requested3');
  check('and it is the original', requested3.first == 'Original', '$requested3');

  // ------------------------------------------------- integrity checking

  print('\n=== sync engine: integrity and failure handling ===');

  var attempts = 0;
  final engine4 = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async {
      attempts++;
      // Always truncated: the transfer must never be accepted.
      return truncatedJpeg();
    }),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000030')]);
  await engine4.run();

  final item4 = engine4.items.first;
  check('a truncated JPEG is rejected', item4.quality != AssetQuality.original);
  check('the item did not reach done', item4.stage != SyncStage.done,
      '${item4.stage}');
  check('the failure is named rather than silent',
      item4.error != null && item4.error!.contains('truncated'), '${item4.error}');
  check('retries are bounded, not infinite', attempts <= 4, '$attempts attempts');

  // ------------------------------------------------- camera loss is a pause

  print('\n=== sync engine: losing the camera pauses rather than fails ===');

  final engine5 = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes()),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000040')]);

  engine5.cameraLost();
  await engine5.run();

  check('a vanished camera pauses the item',
      engine5.items.first.stage == SyncStage.pausedNoCamera,
      '${engine5.items.first.stage}');
  check('a paused item is not a failure',
      engine5.items.first.stage != SyncStage.failed);
  check('the summary explains the pause',
      (engine5.summary.note ?? '').isNotEmpty, '${engine5.summary.note}');
  check('nothing is pending forever: the item is still recoverable',
      !engine5.items.first.stage.isTerminal);

  engine5.cameraConnected();
  await engine5.run();
  check('reconnecting resumes the queue',
      engine5.items.first.stage == SyncStage.done,
      '${engine5.items.first.stage}');

  // ------------------------------------------------- pause by user

  print('\n=== sync engine: user pause ===');

  final engine6 = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes()),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000050')]);
  engine6.pause();
  await engine6.run();
  check('a user pause stops the queue', engine6.items.first.stage != SyncStage.done,
      '${engine6.items.first.stage}');
  engine6.resume();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  check('resuming drains it', engine6.items.first.stage == SyncStage.done,
      '${engine6.items.first.stage}');

  // ------------------------------------------- every stage has an assigner
  //
  // `analysis/79` #9. `SyncStage.pausedLowBattery` was declared, labelled
  // ("Paused, camera battery low"), given a translation key in **both** locales and
  // counted by `isPaused` — and **nothing in `lib/` ever assigned it**. No
  // low-battery threshold existed anywhere. It read as a shipped safety feature and
  // was a comment on an enum.
  //
  // The audit filed it as a product decision (implement it or delete it) and that is
  // the right framing for the *feature*; this check is about the **value**, and it is
  // the half that is not a judgement call. A stage that nothing assigns can never be
  // reached, so its label, its translation and its `isPaused` membership are all
  // unreachable code that reads like behaviour — which is exactly what the localisation
  // checks and the enum's own exhaustive switches are structurally unable to see.
  //
  // The scan is a source read, deliberately. The alternative — driving the engine until
  // every stage appears — is not possible for a stage nothing can set, and each stage
  // that *is* set needs a different scenario (a lost link, a user pause, a stall). A
  // source scan over `lib/sync/` plus `lib/state/` answers the question the finding
  // asks: is there an assignment anywhere?
  {
    final sources = <String>[
      for (final dir in ['lib/sync', 'lib/state', 'lib/transport'])
        for (final f in Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')))
          f.readAsStringSync(),
    ].join('\n');

    final unassigned = <String>[];
    for (final stage in SyncStage.values) {
      // `= SyncStage.x` covers `i.stage = ...`, `stage = ...`, a named argument
      // default and a const initialiser; `: SyncStage.x` covers the map entries the
      // durable queue writes. Both are shapes this codebase actually uses.
      final assigned = RegExp('(=|:)\\s*SyncStage\\.${stage.name}\\b').hasMatch(sources);
      if (!assigned) unassigned.add(stage.name);
    }
    check('every SyncStage value is assigned somewhere, or it cannot be reached',
        unassigned.isEmpty,
        'declared, labelled and translated, but nothing sets: $unassigned');

    // The scan has to be able to see the assignments that exist, or "nothing is
    // unassigned" would be indistinguishable from "the regex matched nothing".
    for (final name in ['pausedNoCamera', 'pausedByUser', 'queued', 'done']) {
      check('the scan finds the assignment of ${name}',
          RegExp('(=|:)\\s*SyncStage\\.$name\\b').hasMatch(sources));
    }
    check('the scan read a real corpus', sources.length > 100000,
        '${sources.length} characters of lib/sync + lib/state + lib/transport');
  }

  // ------------------------------------------------- summary accounting

  print('\n=== sync summary ===');

  final engine7 = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes()),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000060'), jpg('YI000061')]);
  final before = engine7.summary;
  check('pending items are counted', before.pending == 2, '${before.pending}');
  check('the total is the queue length', before.total == 2);
  check('the summary is not complete before running', !before.isComplete);

  await engine7.run();
  final after = engine7.summary;
  check('done items are counted', after.done == 2, '${after.done}');
  check('originals are distinguished from previews', after.originals == 2,
      '${after.originals}');
  check('the summary is complete', after.isComplete);
  check('bytes are accounted', after.bytes > 0, '${after.bytes}');

  // ------------------------------------------------- mode switching

  print('\n=== sync modes ===');
  check('auto preview-then-original is the default',
      engine7.mode == SyncMode.autoPreviewThenOriginal);
  check('there are three selectable modes', SyncMode.values.length == 3);

  // ------------------------------------------- pausing the stream for a sync

  print('\n=== pausing the live-view stream during a bulk transfer ===');

  // The design guide (§5.3) says pause the stream while a bulk transfer runs,
  // because both share one 802.11n link. The interesting properties are not that
  // it pauses, but that it *always* comes back.

  final fakeStream = FakeStreamPause();
  final streamEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: fakeStream,
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000070')]);
  streamEngine.pauseStreamDuringTransfer = true;

  await streamEngine.run();
  check('the stream is paused while the transfer runs', fakeStream.pauseCalls == 1,
      '${fakeStream.pauseCalls} pause call(s)');
  check('the pause is requested exactly once for the whole run, not per file',
      fakeStream.pauseCalls == 1, '${fakeStream.pauseCalls}');
  check('the stream is resumed after a successful run', !fakeStream.paused,
      'stream still paused');
  check('the resume is sent once', fakeStream.resumeCalls == 1,
      '${fakeStream.resumeCalls} resume call(s)');
  check('the run did finish, so this is not passing by doing nothing',
      streamEngine.items.first.stage == SyncStage.done,
      '${streamEngine.items.first.stage}');
  check('the summary stops claiming the stream is paused',
      !streamEngine.summary.streamPausedForTransfer &&
          streamEngine.summary.streamPauseReason == null);

  // ------------------------------------------------- a transfer that throws

  final throwStream = FakeStreamPause();
  final throwEngine = SyncEngine(
    album: () => fakeAlbum(
        onDownload: (f, res) async => throw StateError('the download blew up')),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: throwStream,
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000071')]);
  throwEngine.pauseStreamDuringTransfer = true;

  await throwEngine.run();
  check('a throwing transfer still resumes the stream', !throwStream.paused,
      'stream still paused after a throw');
  check('the throw was seen as a stall, not swallowed',
      throwEngine.items.first.stage != SyncStage.done,
      '${throwEngine.items.first.stage}');

  // ---------------------------------------- the pause command itself fails

  // The most important check of the four: a refused `PauseMovieStream` must not
  // fail the transfer.  This command is structurally verified but has never run
  // on real hardware, so "the camera said no" is an outcome to plan for.
  final refusedStream = FakeStreamPause(pauseOk: false);
  final refusedEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: refusedStream,
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000072')]);
  refusedEngine.pauseStreamDuringTransfer = true;

  await refusedEngine.run();
  check('a refused pause does not fail the transfer',
      refusedEngine.items.first.stage == SyncStage.done,
      '${refusedEngine.items.first.stage}');
  check('the refusal was attempted, so this is not a skipped path',
      refusedStream.pauseCalls == 1, '${refusedStream.pauseCalls}');
  check('the stream is still not left paused', !refusedStream.paused);

  // A pause that throws must not strand the run either.
  final throwingPause = FakeStreamPause(throwOnPause: true);
  final throwingPauseEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: throwingPause,
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000073')]);
  throwingPauseEngine.pauseStreamDuringTransfer = true;

  try {
    await throwingPauseEngine.run();
  } on Object catch (e) {
    // Temporary: an in-flight change to the stream-hold path lets this throw. The
    // queue checks below must still run, so the section is isolated rather than
    // allowed to abort the whole harness.
    check('a throwing pause does not fail the transfer', false, '$e');
  }
  check('a throwing pause does not fail the transfer',
      throwingPauseEngine.items.first.stage == SyncStage.done,
      '${throwingPauseEngine.items.first.stage}');
  check('a throwing pause does not strand the hold',
      !throwingPauseEngine.summary.streamPausedForTransfer);

  // ------------------------------------------------- counted, not a flag

  // Two holders must not resume each other's pause: with a plain boolean, the
  // first one to finish would put the stream back into competition with the
  // second, which is the whole thing this feature exists to prevent.
  //
  // Note what is *not* tested here: two `await`ed `run()` calls. Those are
  // sequential by construction, so they pause and resume twice and that is
  // correct. Overlap happens through the engine's own public hold API, which is
  // how a reconnect restarting a run while the previous one unwinds actually
  // presents itself — one pause, two holders, one resume.
  final holdStream = FakeStreamPause();
  final holdEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: holdStream,
  );
  holdEngine.pauseStreamDuringTransfer = true;

  await holdEngine.beginStreamHold();
  await holdEngine.beginStreamHold();
  check('a second holder does not re-send the pause',
      holdStream.pauseCalls == 1, '${holdStream.pauseCalls} pause call(s)');

  await holdEngine.endStreamHold();
  check('the first of two holders leaves the stream paused', holdStream.paused,
      'the stream was resumed while a transfer still needed it paused');
  check('and sends no resume at all', holdStream.resumeCalls == 0,
      '${holdStream.resumeCalls} resume call(s)');
  check('the summary still reports the pause',
      holdEngine.summary.streamPausedForTransfer &&
          holdEngine.summary.streamPauseReason != null);

  await holdEngine.endStreamHold();
  check('the last holder resumes the stream', !holdStream.paused,
      'stream still paused after the last hold was released');
  check('the resume is sent exactly once', holdStream.resumeCalls == 1,
      '${holdStream.resumeCalls} resume call(s)');

  await holdEngine.endStreamHold();
  check('an unbalanced extra release is harmless and sends no command',
      holdStream.resumeCalls == 1, '${holdStream.resumeCalls} resume call(s)');

  // ------------------------------------------------------------- opt-out

  // A user who wants to watch the preview while syncing must be able to, and
  // then no command at all should reach the camera.
  final optOutStream = FakeStreamPause();
  final optOutEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: optOutStream,
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000074')]);

  check('pausing the stream during a transfer is off by default for safety',
      !optOutEngine.pauseStreamDuringTransfer);

  optOutEngine.pauseStreamDuringTransfer = false;
  await optOutEngine.run();
  check('opting out sends no pause at all', optOutStream.pauseCalls == 0,
      '${optOutStream.pauseCalls} pause call(s)');
  check('opting out sends no resume either — nothing was paused',
      optOutStream.resumeCalls == 0, '${optOutStream.resumeCalls}');
  check('opting out does not stop the transfer',
      optOutEngine.items.first.stage == SyncStage.done,
      '${optOutEngine.items.first.stage}');

  // ------------------------------------------------------------ watchdog

  // A `finally` cannot run if the transfer never completes, and this camera has
  // no watchdog of its own, so the resume has to be armed on a timer as well or
  // a stuck transfer leaves the user with a frozen view indefinitely.
  final watchdogStream = FakeStreamPause();
  final watchdogEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: watchdogStream,
    streamPauseWatchdog: const Duration(milliseconds: 400),
  );
  watchdogEngine.pauseStreamDuringTransfer = true;

  // Deliberately no release: this is the hung-transfer case.
  await watchdogEngine.beginStreamHold();
  check('the hold is represented while it is open',
      watchdogEngine.summary.streamPausedForTransfer);

  await Future<void>.delayed(const Duration(milliseconds: 700));
  check('the watchdog resumes the stream even though nothing released the hold',
      !watchdogStream.paused, 'stream still paused after the watchdog');
  check('the watchdog sends the resume itself', watchdogStream.resumeCalls == 1,
      '${watchdogStream.resumeCalls}');
  check('the watchdog clears the pause state',
      !watchdogEngine.streamPausedForTransfer &&
          watchdogEngine.streamPauseReason == null);

  // Clean up the timer the last hold armed, or the test process would linger.
  await watchdogEngine.endStreamHold();

  // ------------------------------------------------ nothing to transfer

  final idleStream = FakeStreamPause();
  final idleEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
    streamPause: idleStream,
  )..cameraConnected();

  await idleEngine.run();
  check('a run with an empty queue never touches the stream',
      idleStream.pauseCalls == 0 && idleStream.resumeCalls == 0,
      '${idleStream.pauseCalls} pause / ${idleStream.resumeCalls} resume');

  // ------------------------------------------------- engine with no controller

  // The engine has to stay drivable without a camera at all — that is what makes
  // this file possible — so a missing controller is a supported configuration,
  // not an error.
  final noControllerEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
    ledger: SyncLedger(),
    sink: NullAssetSink(),
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000075')]);

  await noControllerEngine.run();
  check('an engine with no stream controller still transfers',
      noControllerEngine.items.first.stage == SyncStage.done,
      '${noControllerEngine.items.first.stage}');

  // ------------------------------------------------- browsed vs manual mode

  print('\n=== sync mode decides what browsing may queue ===');

  {
    // The reported defect: every photo on the card entered the queue whichever
    // mode was selected, so choosing "Manual — only what I pick" changed nothing
    // visible — the queue had already been filled by the act of looking.
    final manualEngine = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(1024)),
      ledger: SyncLedger(),
      sink: NullAssetSink(),
    )..cameraConnected();
    final manualQueue = TransferQueue();
    final manualWithQueue = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(1024)),
      ledger: SyncLedger(),
      sink: NullAssetSink(),
      queue: manualQueue,
    )..cameraConnected();

    manualEngine.mode = SyncMode.manualOnly;
    manualWithQueue.mode = SyncMode.manualOnly;
    final queuedInManual =
        manualEngine.enqueueBrowsed([jpg('YI000080'), jpg('YI000081')]);
    manualWithQueue.enqueueBrowsed([jpg('YI000082')]);

    check('manual mode queues nothing while browsing', queuedInManual == 0,
        '$queuedInManual item(s)');
    check('and nothing reaches the engine either',
        manualEngine.items.isEmpty, '${manualEngine.items.length} item(s)');
    check('and nothing reaches the durable queue',
        manualQueue.isEmpty, '${manualQueue.length} pending');

    // An explicit pick must still work in manual mode: that is the entire point
    // of the mode, so a guard that also blocked it would be useless.
    manualEngine.enqueueSelected([jpg('YI000083')]);
    check('an explicit pick still queues in manual mode',
        manualEngine.items.length == 1, '${manualEngine.items.length} item(s)');

    // The automatic modes must keep queueing, or the fix would have broken the
    // behaviour the other two options promise.
    final autoEngine = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(1024)),
      ledger: SyncLedger(),
      sink: NullAssetSink(),
    )..cameraConnected();
    autoEngine.mode = SyncMode.autoPreviewThenOriginal;
    check('an automatic mode still queues what was browsed',
        autoEngine.enqueueBrowsed([jpg('YI000084')]) == 1,
        '${autoEngine.items.length} item(s)');
  }

  // ------------------------------------------------- durable transfer queue

  print('\n=== durable queue: surviving an app kill ===');

  final queueFiles = <String, String>{};
  final ledgerFiles = <String, String>{};
  final queueStore = _QueueStore(queueFiles);
  final ledgerStore = _QueueStore(ledgerFiles);

  final ledgerQ = SyncLedger(store: ledgerStore);
  await ledgerQ.load();
  final queueA = TransferQueue(store: queueStore);

  final engineA = SyncEngine(
    album: () => fakeAlbum(
        onDownload: (f, res) async =>
            jpegBytes(res == FileResolution.original ? 4096 : 256)),
    ledger: ledgerQ,
    sink: NullAssetSink(),
    queue: queueA,
    onQueueChanged: () => unawaited(queueA.save()),
  )
    ..cameraConnected()
    ..enqueue([jpg('YI000070')]);

  await engineA.run();
  check('a finished transfer leaves the pending queue',
      queueA.isEmpty && engineA.items.first.stage == SyncStage.done,
      '${queueA.length} record(s)');

  // --- the app is killed with work still pending
  final queueB = TransferQueue(store: queueStore);
  engineA
    ..pause()
    ..enqueue([jpg('YI000071')]);
  await queueB.save();

  // --- simulate the kill and relaunch: same bytes, brand-new objects
  final queueC = TransferQueue(store: queueStore);
  await queueC.load();
  check('the pending queue survives a restart', queueC.length == 1,
      '${queueC.length} record(s)');

  final survivor = queueC.pending.first;
  check('the restored record keeps the path',
      survivor.path == '/DCIM/101YICAM/YI000071.JPG', survivor.path);
  check('the restored record keeps the capture second',
      survivor.dateSeconds == 1700000000, '${survivor.dateSeconds}');
  check('the restored record keeps the filetype',
      survivor.fileType == 'picture', survivor.fileType);
  check('the finished asset was never re-queued by the restore',
      !queueC.pending.any((r) => r.path.endsWith('YI000070.JPG')),
      '${queueC.pending}');

  // --- what the restore hands the engine
  final ledgerR = SyncLedger(store: ledgerStore);
  await ledgerR.load();
  final fetchedR = <String>[];
  final engineR = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async {
      fetchedR.add('${f.fileName}:${res.wire}');
      return jpegBytes();
    }),
    ledger: ledgerR,
    sink: NullAssetSink(),
    queue: queueC,
    onQueueChanged: () => unawaited(queueC.save()),
  )..cameraConnected();

  engineR.restore();
  check('the restore hands the pending work back to the engine',
      engineR.items.length == 1 && engineR.items.first.name == 'YI000071.JPG',
      '${engineR.items}');

  await engineR.run();
  check('the restored item transfers without the album being re-listed',
      engineR.items.first.stage == SyncStage.done, '${engineR.items.first}');
  check('the restored item keeps its capture time',
      fetchedR.isNotEmpty &&
          engineR.items.first.file.captureTime != null &&
          engineR.items.first.file.captureTime!.millisecondsSinceEpoch ~/ 1000 ==
              1700000000,
      '${engineR.items.first.file.captureTime}');

  // -------------------------------------------- a finished item is not revived

  final queueD = TransferQueue(store: queueStore);
  await queueD.load();
  final ledgerD = SyncLedger(store: ledgerStore);
  await ledgerD.load();
  final engineD = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes()),
    ledger: ledgerD,
    sink: NullAssetSink(),
    queue: queueD,
  )..cameraConnected();
  engineD.restore();
  check('a completed item is not resurrected by the restore',
      engineD.items.isEmpty, '${engineD.items}');

  // Browsing the same album page again must not re-queue it either.
  engineD.enqueue([jpg('YI000070'), jpg('YI000071')]);
  check('an already-synced file is not re-queued by a later browse',
      engineD.items.isEmpty && queueD.isEmpty,
      '${queueD.length} record(s), ${engineD.items.length} item(s)');

  // ---------------------------------------------- the quality already obtained

  final queueE = TransferQueue(store: queueStore);
  queueE.add(jpg('YI000080'));
  await queueE.save();

  // The preview was delivered and *recorded in the queue*, then the process died
  // before the upgrade. Only the queue can carry that across the kill.
  queueE.mergeQuality('/DCIM/101YICAM/YI000080.JPG', 1700000000,
      AssetQuality.preview);
  await queueE.save();

  final queueF = TransferQueue(store: queueStore);
  await queueF.load();
  check('the quality already obtained survives the restart',
      queueF.pending.first.quality == AssetQuality.preview,
      '${queueF.pending.first.quality}');

  final ledgerF = SyncLedger(store: ledgerStore);
  await ledgerF.load();
  final fetchedF = <String>[];
  final engineF = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async {
      fetchedF.add(res.wire);
      return jpegBytes();
    }),
    ledger: ledgerF,
    sink: NullAssetSink(),
    queue: queueF,
    onQueueChanged: () => unawaited(queueF.save()),
  )..cameraConnected();
  engineF.restore();

  check('the restored item is not back at square one',
      engineF.items.first.quality == AssetQuality.preview,
      '${engineF.items.first.quality}');

  await engineF.run();
  check('the preview already on the phone is not downloaded again',
      !fetchedF.contains('MidThumb'), '$fetchedF');
  check('only the missing rendition is fetched', fetchedF.length == 1,
      '$fetchedF');
  check('the upgrade completes the item',
      engineF.items.first.stage == SyncStage.done, '${engineF.items.first}');

  // ------------------------------------------------- the queue must not break

  const garbage = 'this is not a queue at all';
  const ledgerFile = '{"version":1,"assets":{}}';
  // A torn write: the queue object is closed, but the last record inside it was
  // cut off mid-string. Every record before the tear has to be read back, or a
  // power loss during a write costs the whole session's queue.
  const torn = '{"version":1,"capacity":2000,"queue":{'
      '"/DCIM/101YICAM/YI000090|1700000000":'
      '{"path":"/DCIM/101YICAM/YI000090.JPG","date":1700000000,'
      '"filetype":"picture","quality":"none"},'
      '"/DCIM/101YICAM/YI000092|1700000000":{"path":"/DCIM/1';
  const unclosed = '{"version":1,"capacity":2000,"queue":{'
      '"/DCIM/101YICAM/YI000090|1700000000":{"path":"/DCIM/1';

  var brokeOn = '';
  for (final text in [garbage, ledgerFile, torn, unclosed, '']) {
    final q = TransferQueue(store: _StringStore(text));
    try {
      await q.load();
    } on Object catch (e) {
      brokeOn = 'threw $e on ${text.length} bytes';
    }
  }
  check('an unreadable queue file is not an exception', brokeOn.isEmpty, brokeOn);

  final corruptQueue = TransferQueue(store: _StringStore(unclosed));
  await corruptQueue.load();
  check('a queue file with no usable record loads as empty',
      corruptQueue.isEmpty, '${corruptQueue.length} record(s)');

  final emptyQueue = TransferQueue(store: _StringStore(null));
  await emptyQueue.load();
  check('a missing queue file loads as empty', emptyQueue.isEmpty);

  final tornQueue = TransferQueue(store: _StringStore(torn));
  await tornQueue.load();
  check('a good record survives a tear in a later one',
      tornQueue.length == 1 &&
          tornQueue.droppedOnLoad == 1 &&
          tornQueue.pending.first.path.endsWith('YI000090.JPG'),
      '${tornQueue.length} record(s), ${tornQueue.droppedOnLoad} dropped');

  // The ledger's own file under the queue's name must not be half-read: it holds
  // no records, so the result is an empty queue rather than a corrupt one.
  final wrongQueue = TransferQueue(store: _StringStore(ledgerFile));
  await wrongQueue.load();
  check('another file under this name loads as empty', wrongQueue.isEmpty);

  // ---------------------------------------------- a RAW+JPEG pair is one item

  final pairQueue = TransferQueue(store: _StringStore(null));
  pairQueue.add(jpg('YI000100'));
  pairQueue.add(raw('YI000100'));
  check('a RAW+JPEG pair is one queue record, not two', pairQueue.length == 1,
      '${pairQueue.length} record(s) for 2 files');
  check('the pair keeps the JPEG as the item the user sees first',
      pairQueue.pending.first.path.endsWith('YI000100.JPG'),
      pairQueue.pending.first.path);
  check('the pair keeps the RAW with it',
      pairQueue.pending.first.raw?.path.endsWith('YI000100.DNG') ?? false,
      '${pairQueue.pending.first.raw?.path}');

  // The engine works per file, so a pair is two items there — but re-browsing the
  // page that produced them must not double-queue the shot.
  final pairStore = _QueueStore(<String, String>{});
  final pairLedger = SyncLedger();
  final pairEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async {
      // Only the RAW succeeds, so the JPEG's sibling is left outstanding.
      if (f.path.endsWith('.JPG')) {
        throw const AlbumException('the camera refused the JPEG');
      }
      return jpegBytes(1024);
    }),
    ledger: pairLedger,
    sink: NullAssetSink(),
    queue: TransferQueue(store: pairStore),
    onQueueChanged: () {},
  )..cameraConnected();

  pairEngine.enqueue([jpg('YI000101'), raw('YI000101')], onlyNew: false);
  pairEngine.enqueue([jpg('YI000101'), raw('YI000101')], onlyNew: false);
  check('re-browsing the page does not queue the shot twice',
      pairEngine.items.length == 2, '${pairEngine.items.length} item(s)');

  final pairStore2 = pairStore;
  final pairQueue2 = TransferQueue(store: pairStore2);
  pairQueue2.add(jpg('YI000101'));
  pairQueue2.add(raw('YI000101'));
  await pairQueue2.save();

  final pairBack = TransferQueue(store: pairStore2);
  await pairBack.load();
  check('a pair round-trips as one record',
      pairBack.length == 1 && (pairBack.pending.first.raw != null),
      '${pairBack.length} record(s)');

  // Finishing the JPEG must not take the un-fetched RAW with it. `markDone`
  // retires one asset, and the surviving RAW becomes the record.
  pairBack.markDone('/DCIM/101YICAM/YI000101.JPG', 1700000000);
  check('finishing the JPEG leaves the RAW queued',
      pairBack.length == 1 &&
          pairBack.pending.first.path.endsWith('YI000101.DNG'),
      '${pairBack.length} record(s): ${pairBack.pending}');
  pairBack.markDone('/DCIM/101YICAM/YI000101.DNG', 1700000000);
  check('finishing the RAW empties the record', pairBack.isEmpty,
      '${pairBack.length} record(s)');

  // ------------------------------------------------------------- the size bound

  final bulk = <AlbumFile>[
    for (var i = 0; i < TransferQueue.capacity + 500; i++)
      jpg('YI${(i + 1).toString().padLeft(6, '0')}'),
  ];
  final bulkQueue = TransferQueue(store: _StringStore(null));
  for (final f in bulk) {
    bulkQueue.add(f);
  }
  check('the queue is bounded', bulkQueue.length <= TransferQueue.capacity,
      '${bulkQueue.length} records for ${bulk.length} files');
  check('the bound is what the constant says it is',
      bulkQueue.length == TransferQueue.capacity,
      '${bulkQueue.length} vs ${TransferQueue.capacity}');

  // The bound has to hold inside the *file*, not only in memory, or a 1290-file
  // card still produces a startup cost that grows without limit.
  final bulkStore = _QueueStore(<String, String>{});
  final bulkQueue2 = TransferQueue(store: bulkStore);
  for (final f in bulk) {
    bulkQueue2.add(f);
  }
  await bulkQueue2.save();
  final bulkText = bulkStore.saved['queue'] ?? '';
  final bytesPerRecord =
      bulkText.length / (bulkQueue2.length == 0 ? 1 : bulkQueue2.length);
  check('a full queue file stays small', bulkText.length < 300 * 1024,
      '${bulkText.length} bytes for ${bulkQueue2.length} records '
          '(~${bytesPerRecord.toStringAsFixed(0)} B each)');

  final bulkBack = TransferQueue(store: bulkStore);
  await bulkBack.load();
  check('a full queue round-trips', bulkBack.length == bulkQueue2.length,
      '${bulkBack.length} vs ${bulkQueue2.length}');

  // ------------------------------------------------------------ 1080-photo soak
  // ------------------------------------------------------------ 1080-photo soak

  final soakLedger = SyncLedger();
  final soakQueue = TransferQueue(store: _StringStore(null));
  final soakFetched = <String>[];
  var soakIterations = 0;

  final soakEngine = SyncEngine(
    album: () => fakeAlbum(onDownload: (f, res) async {
      soakFetched.add(res.wire);
      return jpegBytes(res == FileResolution.original ? 4096 : 256);
    }),
    ledger: soakLedger,
    sink: NullAssetSink(),
    queue: soakQueue,
    onQueueChanged: () => unawaited(soakQueue.save()),
  )..cameraConnected();

  for (var page = 0; page < 18; page++) {
    soakEngine.enqueue([
      for (var i = 0; i < 60; i++)
        jpg('YI${(page * 60 + i + 1).toString().padLeft(6, '0')}',
            dir: page.isEven ? '100YICAM' : '101YICAM'),
    ]);
  }
  check('the whole card is queued', soakEngine.summary.total == 1080,
      '${soakEngine.summary.total}');

  while (soakEngine.summary.pending > 0 && soakIterations < 128) {
    await soakEngine.run();
    soakIterations++;
  }

  check('a 1080-file card drains without the queue growing without bound',
      soakEngine.summary.isComplete && soakQueue.isEmpty,
      '${soakEngine.summary}, ${soakQueue.length} record(s) left');
  check('every file was fetched exactly once at full size',
      soakFetched.where((r) => r == 'Original').length == 1080,
      '${soakFetched.where((r) => r == 'Original').length} originals, '
          '${soakFetched.where((r) => r == 'MidThumb').length} previews');

  // ------------------------------------------------- T15: the capture date

  print('\n=== capture date reaches the sink (T15) ===');

  // The bytes are the camera's own file and are never re-encoded, so EXIF is
  // intact by construction. What the phone gets wrong is the file's *timestamp*,
  // and the only place that can be fixed is the sink — so what has to be checked
  // here is that the sink is actually told the capture time rather than left to
  // stamp "now". Exactly this class of bug (a value that exists but never
  // arrives) is why `tools/audit_app_capabilities.py` exists.
  final dateSink = NullAssetSink();
  final captureSecs = 1568000000; // 2019-09-09, i.e. emphatically not today
  final captureEngine = SyncEngine(
    album: () => fakeAlbum(
        onDownload: (f, res) async =>
            jpegBytes(res == FileResolution.original ? 4096 : 256)),
    ledger: SyncLedger(),
    sink: dateSink,
  )
    ..cameraConnected()
    ..enqueue([
      jpg('YI000070', date: captureSecs),
      raw('YI000070', date: captureSecs),
    ]);
  await captureEngine.run();

  check('the sink was given a capture instant for every rendition stored',
      dateSink.capturedAt.length == dateSink.stored,
      '${dateSink.capturedAt.length} of ${dateSink.stored}');
  check('and it is the camera\'s date, not the moment of the transfer',
      dateSink.capturedAt.every((t) =>
          t != null &&
          t.millisecondsSinceEpoch ~/ 1000 == captureSecs),
      '${dateSink.capturedAt}');
  // A RAW+JPEG exposure is **two assets**, and the engine fetches each by its own
  // path: the JPEG gets a preview and an original, the RAW gets an original only.
  // That is **3** stores, not 4.
  //
  // ## Why the RAW has no preview rendition — measured, not a preference
  //
  // The firmware cannot produce one. Against the real camera (`analysis/50` §2):
  // `.DNG` answers **`204` with a zero-byte body at `Thumbnail`** and **`404` at
  // `MidThumb`**; only `Original` answers `200`, with the full ~32 MB DNG. Since a
  // `404` is classified as a stall, a RAW asked for a preview would burn its retries
  // and never progress — so the preview pass skips RAW entirely
  // (`sync_engine.dart`: `wantsPreview = ... && !item.file.isRaw`).
  //
  // This check used to assert 4, on the assumption that both assets got both
  // renditions. It was never true of the hardware; nothing exercised it, because no
  // RAW had ever been enqueued at all.
  //
  // The claim that matters is not the count but that **every** store carries the
  // camera's instant rather than the moment of the transfer.
  check('both assets were transferred, the RAW at full size only',
      dateSink.stored == 3, '${dateSink.stored}');
  check('every rendition was given the camera\'s instant',
      dateSink.capturedAt.length == 3 &&
          dateSink.capturedAt.every((t) =>
              t != null && t.millisecondsSinceEpoch ~/ 1000 == captureSecs),
      '${dateSink.capturedAt}');

  // ------------------------- T15, the half that the earlier round measured wrong

  print('\n=== the date the *gallery* shows, not the column we write ===');

  {
    // ## The reported defect
    //
    // A photo the app displays as **18:40** — correct, and the app is the
    // reference because it renders the camera's `date` field in the phone's own
    // zone — reads **10:40** once it is on the phone. Eight hours, which is the
    // offset of the phone that reported it, in the direction that means *the UTC
    // wall clock was written where a local wall clock belongs*.
    //
    // Both of the app's own date writes are already the true instant:
    // `DATE_ADDED`/`DATE_MODIFIED`/`DATE_TAKEN` are epoch seconds handed to the
    // Kotlin side, and that is why sorting a gallery by date comes out right —
    // which is exactly what the earlier round measured before the claim was
    // withdrawn. **Sorting is not display.** What a gallery *displays* as the
    // capture time, and what MediaProvider re-derives `DATE_TAKEN` from when the
    // pending row is published, is the date **inside the file**, and the file is
    // the camera's own: a naive wall clock with no zone, formatted by a body whose
    // only timezone is `GMT`.
    //
    // So the invariant this checks is the one AGENTS.md §7.1 states for the
    // feature: **the capture time a gallery displays for a synced photo must equal
    // the time the app showed for it on the camera.** It is asserted on the bytes
    // the sink is handed, because that is what the gallery will read, and through
    // the real `SyncEngine`, because a check that re-derived the value from its own
    // fixture would agree with the code by construction (`analysis/79`).
    // The reported pair, to the minute: the shot the app displays as **18:40** at
    // +08:00 is `10:40Z`, and `10:40` is what the file itself says.
    const captureSecs = 1789468800; // 2026-09-15 18:40 at +08:00, i.e. 10:40Z
    final gmt = gmtStamp(captureSecs); // what the body writes: the UTC wall clock
    final captureInstant = DateTime.fromMillisecondsSinceEpoch(captureSecs * 1000);

    // ## Why this check refuses to run quietly at UTC
    //
    // On a phone whose zone *is* UTC, the camera's GMT stamp and the phone's own
    // wall clock are the same string, so nothing here can tell the defect from the
    // fix — and a check that cannot fail is worse than no check (`AGENTS.md` §11,
    // where an always-green screenshot baseline was deleted for exactly this).
    // The emulator this project tested on ran at UTC: `analysis/44` records a tile
    // showing `11/14 22:13` for the capture second `1700000000`, which renders as
    // `2023-11-15 06:13` at +08:00 and as `2023-11-14 22:13` only at UTC. That is
    // why the defect survived a pass that looked at the same numbers.
    final zone = DateTime.fromMillisecondsSinceEpoch(0).timeZoneOffset;
    check(
        'this check can measure a zone shift at all: the host is not at UTC',
        zone != Duration.zero,
        'host offset ${zone.inMinutes} min — at UTC the body\'s GMT stamp and this '
            'machine\'s own wall clock are the same string, so every check below '
            'would pass without measuring anything. Run the suite on a host with a '
            'real offset.');

    // The fixture is the measured shape, and the three fields really do carry the
    // camera's GMT rendering until something rewrites them.
    final m1 = m1Jpeg(exifDate: gmt);
    final m1Stamps = dateStamps(m1);
    check('the fixture has the three date fields the real body writes',
        m1Stamps.length == 3, '${m1Stamps.length}');
    check('and all three hold the camera\'s own GMT rendering',
        m1Stamps.every((s) => s.text == gmt), '${m1Stamps.map((s) => s.text)}');
    check('the camera\'s rendering is NOT the wall clock this phone displays',
        instantFromExifStamp(gmt) != captureInstant,
        '${instantFromExifStamp(gmt)} vs ${captureInstant} — on a UTC host these '
            'would be equal and the check would be vacuous');

    // A JPEG with no EXIF at all (the offline fixtures, and the emulator's
    // synthetic file) and one whose APP1 header is a lie. Neither may be touched,
    // and neither may throw: this transform runs on every published byte.
    final plain = jpegBytes(256);
    final lying = lyingExifJpeg();

    final published = RecordingSink();
    final engine = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async {
        if (f.fileName.startsWith('P0002')) return plain;
        if (f.fileName.startsWith('P0003')) return lying;
        return m1Jpeg(exifDate: gmt);
      }),
      ledger: SyncLedger(),
      sink: published,
    )
      ..cameraConnected()
      ..enqueue([
        jpg('P0001', date: captureSecs),
        jpg('P0002', date: captureSecs),
        jpg('P0003', date: captureSecs),
      ]);
    await engine.run();

    final original = published.bytesFor('P0001.JPG', AssetQuality.original);
    check('the full-size file reached the sink', original != null, null);
    if (original != null) {
      final stamps = dateStamps(original);

      // **The check the defect fails.** Every date field in the published file,
      // read the way a consumer reads it (a naive local wall clock), must be the
      // instant the album tile shows for this shot.
      check(
          'every date inside the published photo is the time the app displayed',
          stamps.isNotEmpty &&
              stamps.every((s) =>
                  instantFromExifStamp(s.text) == captureInstant),
          '${stamps.map((s) => s.text)} — a gallery reads these as local, and the '
              'app shows ${captureInstant.hour}:${captureInstant.minute}');

      // All three, not just the first: which of `DateTime`, `DateTimeOriginal` and
      // `DateTimeDigitized` a given consumer prefers differs by consumer, so a fix
      // that rewrites one of them is a fix that works in one gallery.
      check(
          'the camera\'s own GMT rendering survives only where this phone is GMT',
          stamps.any((s) => s.text == gmt) == (zone == Duration.zero),
          'still GMT after publishing: ${stamps.any((s) => s.text == gmt)}');

      // The file must be the camera's file plus a date, not a re-encode: same
      // length, and no byte outside the three date fields may differ.
      check('the photo is not re-encoded: the length is unchanged',
          original.length == m1.length, '${original.length} vs ${m1.length}');
      final windows = [for (final s in m1Stamps) (s.at, s.at + 19)];
      final outside = [
        for (var i = 0; i < original.length; i++)
          if (original[i] != m1[i] &&
              !windows.any((w) => i >= w.$1 && i < w.$2))
            i,
      ];
      check('and no byte outside the date fields was touched',
          outside.isEmpty, '${outside.length} byte(s): ${outside.take(8)}');

      // Both renditions of one shot land in the same gallery, so they must not
      // disagree with each other about when it was taken.
      final preview = published.bytesFor('P0001.JPG', AssetQuality.preview);
      check(
          'the preview rendition carries the same instant as the original',
          preview != null &&
              dateStamps(preview).isNotEmpty &&
              dateStamps(preview).every((s) =>
                  instantFromExifStamp(s.text) == captureInstant),
          preview == null ? 'no preview stored' : '${dateStamps(preview)}');
    }

    final plainOut = published.bytesFor('P0002.JPG', AssetQuality.original);
    check('a photo with no EXIF is published byte for byte as it arrived',
        plainOut != null && _sameBytes(plainOut, plain), null);
    final lyingOut = published.bytesFor('P0003.JPG', AssetQuality.original);
    check('a lying APP1 header is left alone rather than followed',
        lyingOut != null && _sameBytes(lyingOut, lying), null);
  }

  // ---------------------- the rewrite's refusals, on every published byte

  print('\n=== the date rewrite refuses what it cannot do safely ===');

  {
    // This transform runs on the bytes of **every** photo the app publishes, so the
    // interesting half of its behaviour is what it declines to do. A wrong date is a
    // nuisance; nineteen bytes written into compressed image data is a lost photo.
    const secs = 1789468800;
    final when = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    final expected = wallClock(when);
    final gmt = gmtStamp(secs);

    String stampsOf(Uint8List b) =>
        dateStamps(b).map((s) => s.text).join(', ');

    // A body whose clock was never set writes zeros, not a date. The app is
    // holding the real instant, so a blank field is filled.
    final blank = m1Jpeg(exifDate: '\u0000' * 19);
    final blankOut = stampExifWallClock(blank, when);
    check('a blank date field is filled from the instant the app holds',
        blankOut.fields == 3 && dateStamps(blankOut.bytes).every((s) => s.text == expected),
        '${blankOut.fields} field(s): ${stampsOf(blankOut.bytes)}');

    // A DNG is a bare TIFF with no JPEG container around it, and the camera's RAW
    // half is published to the gallery too.
    for (final le in [true, false]) {
      final dng = measuredTiff(exifDate: gmt, littleEndian: le);
      final out = stampExifWallClock(dng, when);
      check(
          'a bare TIFF (the .DNG) is stamped too, '
          '${le ? 'little' : 'big'}-endian',
          out.fields == 3 && dateStamps(out.bytes).every((s) => s.text == expected),
          '${out.fields} field(s), refused ${out.refused}: ${stampsOf(out.bytes)}');
    }

    // An entry whose value offset points at something that is not a date field.
    // The field must be refused, and the bytes there must not move.
    final decoy = m1Jpeg(exifDate: gmt, decoyValueOffset: 22);
    final decoyOut = stampExifWallClock(decoy, when);
    final base = latin1.decode(decoy).indexOf('Exif\u0000\u0000') + 6;
    check('an entry pointing at bytes that are not a date is refused',
        decoyOut.refused == 1 && decoyOut.fields == 2,
        'refused ${decoyOut.refused}, stamped ${decoyOut.fields}');
    check('and the bytes it pointed at are untouched',
        _sameBytes(
            Uint8List.sublistView(decoyOut.bytes, base + 22, base + 22 + 19),
            Uint8List.sublistView(decoy, base + 22, base + 22 + 19)),
        null);

    // A camera that does not know the time reports 0. Stamping 1970 over a real
    // photo's metadata replaces one wrong date with a worse one.
    final source = m1Jpeg(exifDate: gmt);
    final broken = stampExifWallClock(source, DateTime.fromMillisecondsSinceEpoch(0));
    check('a capture instant before 1990 is refused rather than written',
        !broken.changed && (broken.note ?? '').contains('broken clock'),
        '${broken.note}');
    final undated = stampExifWallClock(source, null);
    check('and so is a file with no capture instant at all',
        !undated.changed && (undated.note ?? '').contains('no capture instant'),
        '${undated.note}');

    // Doing nothing must not copy a 32 MB RAW — the identity is the assertion, and
    // it has to compare against the *input*: comparing the result with itself is a
    // check that cannot fail.
    check('a file that needs nothing is handed on, not copied',
        identical(broken.bytes, source) && identical(undated.bytes, source), null);

    // Video goes to the gallery through the same call.
    final mp4 = Uint8List.fromList(
        [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0, 0, 2, 0]);
    final mp4Out = stampExifWallClock(mp4, when);
    check('a video is published unchanged', _sameBytes(mp4Out.bytes, mp4),
        '${mp4Out.note}');
  }

  // ------------- the same rewrite, against the camera's own file in the tree

  print('\n=== the rewrite on a real M1 original, not on a fixture ===');

  {
    // `capture_test/probe_original.jpg` is an `Original` fetched from the 3.1-cn
    // body by `tools/verify_camera.py` and committed. Every other check here runs
    // against a fixture **this project wrote**, which is the weakness
    // `analysis/79` found four times over — a fixture and the code agreeing because
    // they came from the same head. This one runs the real transform over the real
    // body's own bytes: 16 IFD0 entries, a 36-entry ExifIFD, a 13 KB MakerNote and
    // a 690-byte private block, none of which the transform may touch.
    final candidates = [
      'capture_test/probe_original.jpg',
      'app/capture_test/probe_original.jpg',
    ];
    final path = candidates.firstWhere((p) => File(p).existsSync(), orElse: () => '');
    check('the real camera JPEG is in the tree to check against', path.isNotEmpty,
        'looked for ${candidates.join(' or ')} from ${Directory.current.path} — it is '
            'committed, so a missing one means the checkout is incomplete');

    if (path.isNotEmpty) {
      final real = File(path).readAsBytesSync();
      final realStamps = dateStamps(real);
      check('the body writes three date fields into one photo',
          realStamps.length == 3, '${realStamps.map((s) => s.text)}');
      check('and all three carry the same naive wall clock',
          realStamps.length == 3 &&
              realStamps.every((s) => s.text == realStamps.first.text),
          '${realStamps.map((s) => s.text)}');

      // The instant that file's own date field names, read as the body's clock
      // reads it. `[V-]`: no independent wall clock was recorded in the session
      // that fetched it, so this is the file's own render — which is all the
      // transform needs, since it is handed the instant and writes the wall clock.
      const realSecs = 1789346946; // 2026-09-14 00:49:06, as read from the file
      final realWhen = DateTime.fromMillisecondsSinceEpoch(realSecs * 1000);
      final stamped = stampExifWallClock(real, realWhen);
      final after = dateStamps(stamped.bytes);
      check('every date in the published photo becomes the time the app displays',
          stamped.fields == 3 &&
              after.length == 3 &&
              after.every((s) =>
                  instantFromExifStamp(s.text) == realWhen),
          '${stamped.fields} field(s): ${after.map((s) => s.text)}');
      check('the camera\'s own GMT rendering is gone from it',
          !after.any((s) => s.text == realStamps.first.text),
          '${after.map((s) => s.text)}');
      // The file this runs on is the real camera original committed under
      // `testdata/` (4.9 MB, recorded as 4,897,837 B in `analysis/50` §2 and declared
      // in `lib/transport/measured_sizes.dart`). This check used to say "9.4 MB",
      // which is not a size any measurement in this tree contains — the same invented
      // figure as `analysis/79` #19.
      check('the original is still the same length after the EXIF rewrite',
          stamped.bytes.length == real.length,
          '${stamped.bytes.length} vs ${real.length}');

      // The MakerNote, the private block and every byte of image data: untouched.
      final windows = [for (final s in realStamps) (s.at, s.at + 19)];
      var outside = 0;
      var firstOutside = -1;
      for (var i = 0; i < real.length; i++) {
        if (real[i] != stamped.bytes[i] &&
            !windows.any((w) => i >= w.$1 && i < w.$2)) {
          outside++;
          if (firstOutside < 0) firstOutside = i;
        }
      }
      check('and nothing else in it moved — not the MakerNote, not the pixels',
          outside == 0,
          '$outside byte(s) outside the date fields, first at $firstOutside');
    }
  }

  // ------------------------------------------------ cancelling queued work

  print('\n=== sync list: cancelling a queued shot ===');
  {
    // The reported defect: the sync bar offered Pause and Start and nothing else, so
    // there was no way to drop one shot out of a queue that can hold hundreds of
    // megabytes, and no way to see what was in it. These checks are about the
    // *effect* — what the queue holds afterwards — because a control that only looks
    // like it cancels is the failure mode worth catching.
    final q1 = TransferQueue();
    final e1 = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(512)),
      ledger: SyncLedger(),
      sink: NullAssetSink(),
      queue: q1,
    )..cameraConnected();
    e1.enqueueSelected([jpg('YI000100'), jpg('YI000101')]);
    check('two shots are queued to begin with', q1.length == 2, '${q1.length}');

    final target1 =
        e1.items.firstWhere((i) => i.file.path.endsWith('YI000100.JPG'));
    final dropped = e1.removeItem(target1);
    check('removing one shot returns the path it dropped',
        dropped.length == 1 && dropped.first.endsWith('YI000100.JPG'), '$dropped');
    check('the engine no longer lists it', e1.items.length == 1,
        '${e1.items.length}');
    // The durable record goes too. Without that the next launch restores work the
    // user just cancelled, which is a cancellation that silently undoes itself.
    check('and it is gone from the durable queue', q1.length == 1, '${q1.length}');
    check('while the shot that was not touched stays',
        q1.pending.single.path.endsWith('YI000101.JPG'),
        '${q1.pending.single.path}');
    check('pendingCount agrees with what would be fetched',
        e1.pendingCount == 1, '${e1.pendingCount}');

    // A second tap on the same row must not report a second removal. The handle is
    // kept rather than re-read from `items`, because the row the user tapped is the
    // one they had — and re-reading `items.single` would tap the *other* shot, which
    // is what an earlier version of this check did: it removed the survivor and then
    // asserted the survivor was still queued.
    final tapped1 = target1;
    check('removing a shot twice is a no-op',
        e1.removeItem(tapped1).isEmpty, 'a double tap removed something again');
    check('and the untouched shot is still queued', e1.pendingCount == 1,
        '${e1.pendingCount}');
  }

  print('\n=== sync list: clearing the whole list ===');
  {
    final q2 = TransferQueue();
    final e2 = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(512)),
      ledger: SyncLedger(),
      sink: NullAssetSink(),
      queue: q2,
    )..cameraConnected();
    e2.enqueueSelected([jpg('YI000110'), jpg('YI000111'), jpg('YI000112')]);

    final n = e2.clearPending();
    check('clearing reports how many shots left', n == 3, '$n');
    check('the engine list is empty', e2.items.isEmpty, '${e2.items.length}');
    check('the durable queue is empty too', q2.isEmpty, '${q2.length}');
    check('a second clear has nothing to do', e2.clearPending() == 0);

    // Re-queueing must still work — the point is an empty list, not a dead engine.
    e2.enqueueSelected([jpg('YI000113')]);
    check('a cleared list can be refilled', e2.items.length == 1,
        '${e2.items.length}');
  }

  print('\n=== sync list: cancelling one that is already in flight ===');
  {
    // The hard case, and the reason `SyncItem.removed` exists. A `GetFile` on the
    // wire cannot be recalled without `PauseMovieStream`, which has never been
    // accepted by a real YI M1; so the request finishes and its reply is **thrown
    // away**. The check is that nothing lands: not in the gallery, not in the ledger,
    // not back in the queue.
    var landed = Completer<Uint8List>();
    final sink3 = NullAssetSink();
    final ledger3 = SyncLedger();
    final q3 = TransferQueue();
    final e3 = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) => landed.future),
      ledger: ledger3,
      sink: sink3,
      queue: q3,
    )
      ..cameraConnected()
      ..mode = SyncMode.autoOriginalOnly; // one request, so the cancel lands mid-flight
    final shot3 = jpg('YI000120');
    final id3 = AssetId(path: shot3.path, dateSeconds: 1700000000);
    e3.enqueueSelected([shot3]);

    final running = e3.run();
    await Future<void>.delayed(Duration.zero);
    check('the transfer really is in flight before we cancel',
        e3.items.single.stage.isActive, '${e3.items.single.stage}');

    e3.removeItem(e3.items.single);
    landed.complete(jpegBytes(4096));
    await running;

    check('a cancelled transfer publishes nothing to the gallery', sink3.stored == 0,
        '${sink3.stored} store(s): ${sink3.log}');
    check('nothing is recorded as saved on the phone',
        !ledger3.has(id3, atLeast: AssetQuality.preview));
    check('and it does not come back as pending work', q3.isEmpty, '${q3.length}');
    check('the engine list does not still offer it',
        e3.items.isEmpty, '${e3.items.length}');
  }

  // ------------------------------------------- the mode decides the list

  print('\n=== sync mode re-derives the job list ===');
  {
    // The reported defect, stated exactly: the mode is what decides whether a preview
    // is fetched before the full size, so a list built under one mode and carried into
    // another means something other than what the selector says.
    final q4 = TransferQueue();
    final ledger4 = SyncLedger();
    final e4 = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
      ledger: ledger4,
      sink: NullAssetSink(),
      queue: q4,
    )
      ..cameraConnected()
      ..mode = SyncMode.autoPreviewThenOriginal;
    e4.enqueueSelected([jpg('YI000130'), jpg('YI000131')]);

    // Both shots are already previewed but not full size: exactly the state where the
    // two automatic modes disagree about whether there is anything left to do.
    final previewedId = e4.items.first.id;
    for (final i in e4.items) {
      i.quality = AssetQuality.preview;
      ledger4.recordLocal(i.id, AssetQuality.preview, 'null://preview');
    }

    final note = e4.reinterpret(SyncMode.autoOriginalOnly, const []);
    check('switching to full size only says what it did', note != null, '$note');
    check('and the list is empty, because there is nothing left to fetch',
        e4.pendingCount == 0, '${e4.pendingCount}');
    check('the durable queue is empty with it', q4.isEmpty, '${q4.length}');
    // Removing a shot from the job list must not touch what is on the phone: the
    // preview is still in the gallery and the ledger still says so.
    check('the preview that is already on the phone is not forgotten',
        ledger4.qualityOf(previewedId) == AssetQuality.preview,
        '${ledger4.qualityOf(previewedId)}');

    // Back the other way: preview-first means every shot without a preview is queued
    // for one. This is what the OLD code could not do — it only reacted to leaving
    // manual mode, so this switch left the old (now empty) list in place and the
    // selector's promise was never carried out.
    final back = e4.reinterpret(
        SyncMode.autoPreviewThenOriginal, [jpg('YI000130'), jpg('YI000131')]);
    check('switching back re-derives the list', e4.pendingCount == 2,
        '${e4.pendingCount} — the list did not follow the mode');
    check('and re-queues the durable records', q4.length == 2, '${q4.length}');
    check('and says so', (back ?? '').contains('queued'), '$back');

    // Full-size-only must not touch a shot whose preview is not even here yet: the
    // first fetch is still the preview pass in that mode (the item has nothing on the
    // phone at all), and dropping it would lose work rather than describe it.
    final e5 = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async => jpegBytes(4096)),
      ledger: SyncLedger(),
      sink: NullAssetSink(),
    )
      ..cameraConnected()
      ..mode = SyncMode.autoPreviewThenOriginal;
    e5.enqueueSelected([jpg('YI000140')]);
    e5.reinterpret(SyncMode.autoOriginalOnly, const []);
    check('a shot with nothing on the phone is not dropped',
        e5.pendingCount == 1, '${e5.pendingCount}');

    // Manual keeps what is queued: the mode is about *automatic* queueing, and the
    // user's explicit picks are not the mode's business.
    e5.reinterpret(SyncMode.manualOnly, const []);
    check('switching to manual keeps what was already picked',
        e5.pendingCount == 1, '${e5.pendingCount}');
    check('and manual queues nothing new when browsing',
        e5.enqueueBrowsed([jpg('YI000141')]) == 0);

    // Selecting the mode that is already selected changes nothing and says so.
    check('re-selecting the same mode is not a change',
        e5.reinterpret(SyncMode.manualOnly, const []) == null);
  }

  print('\n=== an already-saved shot is resolved without asking the camera ===');
  {
    // The guard that makes re-deriving safe. A mode change puts items back in front of
    // the engine on purpose; for a shot whose original is already here the answer is
    // "nothing", and it has to be reached with **zero requests** — the whole point of
    // the ledger, and the difference between describing a list and re-downloading one.
    final asked = <String>[];
    final ledger6 = SyncLedger();
    final e6 = SyncEngine(
      album: () => fakeAlbum(onDownload: (f, res) async {
        asked.add('${f.fileName}:${res.wire}');
        return jpegBytes(4096);
      }),
      ledger: ledger6,
      sink: NullAssetSink(),
      queue: TransferQueue(),
    )
      ..cameraConnected()
      ..mode = SyncMode.autoPreviewThenOriginal;
    e6.enqueueSelected([jpg('YI000150')]);
    final id6 = e6.items.single.id;
    ledger6.recordLocal(id6, AssetQuality.original, 'content://already/1');

    e6.reinterpret(SyncMode.autoPreviewThenOriginal, const []);
    e6.items.single.quality = AssetQuality.original;
    await e6.run();

    check('nothing was fetched for a shot that is already saved', asked.isEmpty,
        '$asked');
    check('and it is reported as done', e6.items.single.stage == SyncStage.done,
        '${e6.items.single.stage}');
    check('so it leaves the durable queue', e6.summary.pending == 0,
        '${e6.summary.pending}');
  }

  print('\n${'=' * 52}');
  print('  $_pass passed, $_fail failed');
  print('${'=' * 52}');
}

/// An in-memory stand-in for the on-disk queue and ledger files.
///
/// The queue is verified by *restarting* it — a brand-new [TransferQueue] over
/// the same bytes — so the store has to outlive the object that writes it.  That
/// is the whole point of the checks below: a queue that only round-trips through
/// its own memory proves nothing about an app kill.
class _QueueStore implements SyncStore {
  final Map<String, String> saved;
  _QueueStore(this.saved);

  @override
  Future<String?> read() async => saved['queue'];

  @override
  Future<void> write(String contents) async => saved['queue'] = contents;
}

/// A store holding one fixed string, for the corrupt-file checks.
class _StringStore implements SyncStore {
  final String? text;
  _StringStore(this.text);

  @override
  Future<String?> read() async => text;

  @override
  Future<void> write(String contents) async {}
}
