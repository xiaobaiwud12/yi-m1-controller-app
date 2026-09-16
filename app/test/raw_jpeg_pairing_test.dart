import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/sync/asset_group.dart';
import 'package:yi_m1_controller/transport/album.dart';

/// What the firmware actually sends for a RAW+JPEG shot, and what we make of it.
///
/// ## Why these fixtures look the way they do
///
/// Every value here was read off the user's real 3.1-cn camera with `GetFileList`
/// (`analysis/50`). That matters because the previous fixture was **invented**: it listed
/// a `.JPG` and a `.DNG` as two entries with `filetype: 'raw'`, and the grouping logic
/// was then built to pair them. The firmware does not do that. It sends **one** entry per
/// shutter press, whose path ends `.JPG` and whose `filetype` is `rawJpeg`.
///
/// So the old code was waiting for a listing that never arrives, and **not one RAW had
/// ever been queued** — while the tests passed, because the fixture agreed with the code
/// rather than with the camera. A fixture that matches the consumer instead of the
/// producer is how that stays invisible.
AlbumFile _file(String path, String type, {String date = '1789391479'}) =>
    AlbumFile.fromJson({
      'path': path,
      'filetype': type,
      'date': date,
      'protectStatus': false,
    });

void main() {
  group('a rawJpeg entry is a JPEG that owns a RAW', () {
    final jpeg = _file('/DCIM/100YICAM/P9140002.JPG', 'rawJpeg');

    test('isRaw is false — the file itself is a JPEG', () {
      expect(jpeg.isRaw, isFalse,
          reason: 'the camera serves this path as JPEG bytes '
              '(FF D8 FF E1 ... Exif) and answers 200 with 4,897,837 of them. Calling '
              'it a RAW badged every such tile "RAW" and gave the grouping the wrong '
              'primary');
      expect(jpeg.hasRawSibling, isTrue);
    });

    test('the derived sibling is the same basename with .DNG', () {
      final raw = jpeg.rawSibling;
      expect(raw, isNotNull);
      expect(raw!.path, '/DCIM/100YICAM/P9140002.DNG');
      expect(raw.isRaw, isTrue, reason: 'this one really is a RAW');
      expect(raw.hasRawSibling, isFalse);
      expect(raw.captureTime, jpeg.captureTime,
          reason: 'the pair shares one capture time; that is what makes them one shot');
    });

    test('a plain picture has no sibling and no badge', () {
      final pic = _file('/DCIM/100YICAM/P9140005.JPG', 'picture');
      expect(pic.rawSibling, isNull);
      expect(pic.isRaw, isFalse);
      expect(groupAssets([pic]).single.badge, isEmpty);
    });
  });

  group('grouping one shutter press', () {
    test('a rawJpeg entry becomes ONE group carrying both renditions', () {
      final groups = groupAssets([
        _file('/DCIM/100YICAM/P9140002.JPG', 'rawJpeg'),
      ]);
      expect(groups, hasLength(1),
          reason: 'one shutter press is one row; the old code needed a second entry '
              'to pair with and so produced a group with no RAW at all');
      expect(groups.single.isPair, isTrue);
      expect(groups.single.assets, hasLength(2));
      expect(groups.single.primary.path, endsWith('.JPG'));
      expect(groups.single.raw!.path, endsWith('.DNG'));
      // The badge is the user-visible consequence of getting this right.
      expect(groups.single.badge, 'RAW+JPG');
    });

    test('the whole measured card groups 1:1 — 25 entries, 25 shots', () {
      // The real listing: 18 rawJpeg, 5 picture, 2 video, 25 entries in all.
      final files = <AlbumFile>[
        _file('/DCIM/100YICAM/P9140001.MP4', 'video', date: '1789371748'),
        for (var i = 2; i <= 4; i++)
          _file('/DCIM/100YICAM/P914000$i.JPG', 'rawJpeg', date: '178939147$i'),
        for (var i = 5; i <= 9; i++)
          _file('/DCIM/100YICAM/P914000$i.JPG', 'picture', date: '178939544$i'),
        _file('/DCIM/100YICAM/P9150010.MP4', 'video', date: '1789400000'),
        for (var i = 11; i <= 25; i++)
          _file('/DCIM/100YICAM/P91500$i.JPG', 'rawJpeg', date: '17894001$i'),
      ];
      expect(files, hasLength(25));
      final groups = groupAssets(files);
      expect(groups, hasLength(25),
          reason: 'the camera lists 25 files for 25 shutter presses, so grouping must '
              'not invent or lose rows');
      expect(groups.where((g) => g.isPair).length, 18,
          reason: 'the 18 rawJpeg entries each own a RAW');
      expect(groups.where((g) => g.badge == 'RAW+JPG').length, 18);
    });

    test('the two-entry shape still groups, for a firmware that lists both', () {
      final groups = groupAssets([
        _file('/DCIM/101YICAM/YI000002.JPG', 'picture'),
        _file('/DCIM/101YICAM/YI000002.DNG', 'raw'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.isPair, isTrue);
      expect(groups.single.primary.path, endsWith('.JPG'));
    });
  });

  group('RAW is opt-in', () {
    test('SyncPlan skips RAW unless asked', () {
      const plan = SyncPlan();
      expect(plan.skipRaw, isTrue,
          reason: 'the capability is new; defaulting it on would make a first sync '
              'quietly pull ~32 MB per shot, about 574 MB for the card that was '
              'measured, over the radio that also carries the live view');
      expect(plan.wants(_file('/DCIM/100YICAM/P9140002.DNG', 'raw')), isFalse);
      // ...but the JPEG half of the same shot is still wanted, which is the point of
      // skipping rather than filtering the entry out.
      expect(plan.wants(_file('/DCIM/100YICAM/P9140002.JPG', 'rawJpeg')), isTrue);
    });

    test('turning it on admits the RAW and still keeps the JPEG', () {
      const plan = SyncPlan(skipRaw: false);
      expect(plan.wants(_file('/DCIM/100YICAM/P9140002.DNG', 'raw')), isTrue);
      expect(plan.wants(_file('/DCIM/100YICAM/P9140002.JPG', 'rawJpeg')), isTrue);
    });
  });
}
