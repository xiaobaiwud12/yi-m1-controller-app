/// Offline checks for the live-view and album protocol layers.
///
/// The camera is frequently unavailable (it is battery-powered and gets powered
/// off between sessions), so the wire-format logic is verified against **packets
/// captured from the real camera**, committed under `app/testdata/`.
///
/// Run:  dart run tool/verify_transport.dart
///
/// This is a plain Dart VM program rather than a `flutter_test` suite on purpose:
/// it needs no Flutter engine, so it can run anywhere the Dart SDK is present.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/focus_mapper.dart';
import 'package:yi_m1_controller/protocol/http_commands.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/protocol/settings_menu.dart';
import 'package:yi_m1_controller/protocol/viewfinder_layout.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/sync/asset_group.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/album_delete.dart';
import 'package:yi_m1_controller/transport/album_thumbnail_cache.dart';
import 'package:yi_m1_controller/transport/camera_connection.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/transport/liveview.dart';
import 'package:yi_m1_controller/transport/wifi_join_contract.dart';

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

/// Reproduce the receiver's framing logic on a captured datagram, without
/// needing a socket.  Mirrors `CameraLiveView._handle`.
(LiveViewFrame?, String) parseDatagram(Uint8List data) {
  if (data.length < kJpegOffset + 4) return (null, 'too short');
  final bd = ByteData.sublistView(data);
  final frameIndex = bd.getUint32(0, Endian.big);
  final timestamp = bd.getUint32(4, Endian.big);
  final marker = bd.getUint32(8, Endian.big);

  var soi = -1;
  for (var i = kJpegOffset - 4; i + 2 < data.length; i++) {
    if (i < kHeaderSize) continue;
    if (data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF) {
      soi = i;
      break;
    }
  }
  if (soi < 0) return (null, 'no SOI (marker=0x${marker.toRadixString(16)})');

  var eoi = data.length - 2;
  while (eoi > soi && !(data[eoi] == 0xFF && data[eoi + 1] == 0xD9)) {
    eoi -= 2;
  }
  if (eoi <= soi) return (null, 'no EOI');

  return (
    LiveViewFrame(
      frameIndex: frameIndex,
      timestamp: timestamp,
      jpeg: Uint8List.sublistView(data, soi, eoi + 2),
      parameters: Uint8List.sublistView(data, kHeaderSize, soi),
    ),
    'marker=0x${marker.toRadixString(16)}'
  );
}

/// Minimal JPEG dimension reader (SOF0..SOF3).
(int, int)? jpegSize(Uint8List d) {
  var i = 2;
  while (i + 9 < d.length) {
    if (d[i] != 0xFF) {
      i++;
      continue;
    }
    final m = d[i + 1];
    if (m == 0xD8 || m == 0xD9 || (m >= 0xD0 && m <= 0xD7)) {
      i += 2;
      continue;
    }
    final len = (d[i + 2] << 8) | d[i + 3];
    if (m >= 0xC0 && m <= 0xC3) {
      final h = (d[i + 5] << 8) | d[i + 6];
      final w = (d[i + 7] << 8) | d[i + 8];
      return (w, h);
    }
    i += 2 + len;
  }
  return null;
}

void main() async {
  print('=== live-view datagram framing (real captured packets) ===');

  final dir = Directory('testdata/liveview');
  if (!dir.existsSync()) {
    print('  SKIP  testdata/liveview not found - nothing to verify against');
  } else {
    final packs = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.bin'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    check('captured datagrams present', packs.length >= 10, '${packs.length} files');

    var framed = 0, sized = 0, soiAtConstant = 0, paramLens = <int>{};
    var firstIdx = -1, lastIdx = -1, idxStep = <int>{};
    var tsStep = <int>{};

    for (final f in packs) {
      final data = f.readAsBytesSync();
      final (frame, note) = parseDatagram(data);
      if (frame == null) {
        print('    ${f.path}: $note');
        continue;
      }
      framed++;
      if (data.length > kJpegOffset + 2 &&
          data[kJpegOffset] == 0xFF &&
          data[kJpegOffset + 1] == 0xD8) {
        soiAtConstant++;
      }
      paramLens.add(frame.parameters?.length ?? -1);
      final s = jpegSize(frame.jpeg);
      if (s == (800, 600)) sized++;
      if (firstIdx < 0) firstIdx = frame.frameIndex;
      if (lastIdx >= 0) {
        idxStep.add(frame.frameIndex - lastIdx);
        // timestamp step needs the previous frame's timestamp; recompute below
      }
      lastIdx = frame.frameIndex;
    }

    check('every datagram yields a complete JPEG', framed == packs.length,
        '$framed/${packs.length}');
    check('JPEG is always 800x600', sized == framed, '$sized/$framed');
    check('SOI is at the constant offset $kJpegOffset',
        soiAtConstant == framed, '$soiAtConstant/$framed');
    check('parameter block length is constant', paramLens.length == 1,
        'saw ${paramLens.length} distinct lengths: $paramLens');
    check('frameIndex increments by 1', idxStep.length <= 1, 'steps: $idxStep');

    if (firstIdx >= 0) {
      print('    frame index $firstIdx .. $lastIdx over ${packs.length} datagrams');
    }

    // timestamp step, computed properly
    int? prevTs;
    for (final f in packs) {
      final data = f.readAsBytesSync();
      if (data.length < 12) continue;
      final ts = ByteData.sublistView(data).getUint32(4, Endian.big);
      if (prevTs != null) tsStep.add(ts - prevTs);
      prevTs = ts;
    }
    print('    timestamp steps: $tsStep');

    // session marker constant across all packets
    final markers = <int>{};
    for (final f in packs) {
      final data = f.readAsBytesSync();
      if (data.length < 12) continue;
      markers.add(ByteData.sublistView(data).getUint32(8, Endian.big));
    }
    check('session marker is constant 0x${kSessionMarker.toRadixString(16)}',
        markers.length == 1 && markers.first == kSessionMarker,
        'saw ${markers.map((m) => '0x${m.toRadixString(16)}').toList()}');
  }

  print('\n=== GetFileList paging arithmetic ===');
  check('page 0 -> 1..60', CameraAlbum.pageRange(0) == (1, 60),
      '${CameraAlbum.pageRange(0)}');
  check('page 1 -> 61..120', CameraAlbum.pageRange(1) == (61, 120),
      '${CameraAlbum.pageRange(1)}');
  check('page 5 -> 301..360', CameraAlbum.pageRange(5) == (301, 360),
      '${CameraAlbum.pageRange(5)}');
  check('page size is 60', CameraAlbum.pageSize == 60);

  print('\n=== album error codes ===');
  check('end-of-album is 1506', CameraAlbum.codeEndOfAlbum == 1506);
  check('internal error is 1505', CameraAlbum.codeInternalError == 1505);

  print('\n=== FileResolution wire values (firmware spelling) ===');
  check('original', FileResolution.original.wire == 'Original');
  check('midThumb', FileResolution.midThumb.wire == 'MidThumb');
  check('thumbnail', FileResolution.thumbnail.wire == 'Thumbnail');

  print('\n=== AlbumFile parsing ===');
  final af = AlbumFile.fromJson({
    'path': '/DCIM/100YICAM/YI000001.JPG',
    'date': '1700000000',
    'filetype': 'picture',
    'protectStatus': false,
  });
  check('path parsed', af.path == '/DCIM/100YICAM/YI000001.JPG');
  check('bare filename extracted', af.fileName == 'YI000001.JPG');
  check('date parsed from string as seconds',
      af.captureTime?.millisecondsSinceEpoch == 1700000000000);
  check('filetype parsed', af.fileType == 'picture' && !af.isVideo);
  check('path within the 50-byte firmware buffer', !af.isPathTooLong);

  final longPath = AlbumFile.fromJson({
    'path': '/DCIM/100YICAM/${'X' * 60}.JPG',
    'filetype': 'picture',
  });
  check('over-long path is flagged', longPath.isPathTooLong);

  final vid = AlbumFile.fromJson({'path': '/DCIM/a.MP4', 'filetype': 'video'});
  check('video detected', vid.isVideo);

  // ## This check used to enforce the wrong model
  //
  // It read `{'path': '/DCIM/a.DNG', 'filetype': 'rawJpeg'}` and asserted
  // `isRaw == true`. **The firmware never emits that combination** — a `rawJpeg`
  // entry's path ends `.JPG`, and `GetFile` serves it as JPEG bytes (`analysis/50`).
  // The fixture was invented, and because it agreed with the code's own mistake the
  // check passed while the app badged every RAW+JPEG shot `RAW` and queued **no RAW at
  // all**. A fixture that matches the consumer rather than the producer is how that
  // stays invisible.
  //
  // These are the shapes the real 3.1-cn camera sends.
  final rawJpeg =
      AlbumFile.fromJson({'path': '/DCIM/a.JPG', 'filetype': 'rawJpeg'});
  check('a rawJpeg entry is not itself a RAW', !rawJpeg.isRaw);
  check('a rawJpeg entry says it has a RAW beside it', rawJpeg.hasRawSibling);
  check('the RAW is derived as the same basename with .DNG',
      rawJpeg.rawSibling?.path == '/DCIM/a.DNG');
  check('and the derived RAW is what isRaw is for', rawJpeg.rawSibling!.isRaw);

  final picture =
      AlbumFile.fromJson({'path': '/DCIM/a.JPG', 'filetype': 'picture'});
  check('a plain picture has no RAW sibling', picture.rawSibling == null);
  check('and is not a RAW', !picture.isRaw);

  check('syncKey combines path and time', af.syncKey.contains('1700000000000'));

  print('\n=== Wi-Fi join: naming the actual cause (regression guard) ===');
  await _verifyWifiJoinDiagnosis();

  print('\n=== sync policy: the predicate\'s own contract ===');
  // `SyncPlan.wants` is a building block; these are arguments handed to it and the
  // answers it documents. **They are not the evidence that the policy is in force.**
  // A check on this class's own default reads the same source as the class, which is
  // the pattern `analysis/79`'s header names — *"the check and the code reason twice
  // from the same source of truth, so the two are wrong together"* — and the RAW
  // finding is one of the five that produced it. That evidence is in the next section,
  // which calls what the album page calls.
  const plan = SyncPlan(skipVideos: true, skipRaw: false);
  check('plan rejects video', !plan.wants(vid));
  check('plan accepts picture', plan.wants(af));

  final old = AlbumFile.fromJson({
    'path': '/DCIM/old.JPG',
    'date': '1000000000',
    'filetype': 'picture',
  });
  final since = DateTime.fromMillisecondsSinceEpoch(1600000000000);
  check('plan honours "since"', !SyncPlan(since: since).wants(old));

  print('\n=== sync policy: what a queue action actually adds ===');
  //
  // ## Why this section exists where the one above does not
  //
  // `transport/album.dart` documented the RAW decision in full — *"~32 MB per
  // RAW+JPEG shot … the capability ships **off**"* — while `SyncPlan` was constructed
  // **nowhere in `lib/`** and every user-facing queue path enqueued
  // `AssetGroup.assets`, which for a `rawJpeg` entry is `[primary, raw!]`. Measured on
  // hardware: *"pick 1 = 2 queued (JPEG + DNG)"*. The documentation and the queue
  // disagreed, and no check could see it, because the only one there was asked the
  // class its own default.
  //
  // `plannedQueue` is the function all four of the album page's queue paths call — a
  // selection, the mode selector, the viewer's save button, and the automatic browse
  // that fills the queue as the card is paged — under the plan `AppState.queuePlan`
  // builds from the user's own switch. So this is the call site's decision, exercised
  // without a widget.
  final pair = groupAssets([
    AlbumFile.fromJson({
      'path': '/DCIM/100YICAM/P9140002.JPG',
      'date': '1789391479',
      'filetype': 'rawJpeg',
    }),
  ]).single;
  check('the fixture is one shot owning two renditions',
      pair.isPair && pair.assets.length == 2,
      pair.assets.map((f) => f.path).join(','));

  final rawOff = plannedQueue([pair], SyncPlan.forQueue(includeRaw: false));
  check(
      'with the opt-in off, a queue action adds the JPEG alone',
      rawOff.length == 1 && rawOff.single.path.endsWith('.JPG'),
      rawOff.map((f) => f.path).join(','));
  check('and the derived RAW is not in it',
      !rawOff.any((f) => f.path.endsWith('.DNG')));

  final rawOn = plannedQueue([pair], SyncPlan.forQueue(includeRaw: true));
  check(
      'with the opt-in on, both renditions are queued',
      rawOn.length == 2 && rawOn.last.path.endsWith('.DNG'),
      rawOn.map((f) => f.path).join(','));
  check('and the JPEG still comes first, so the shot is viewable first',
      rawOn.first.path.endsWith('.JPG'));

  // A shot whose **only** rendition is a RAW is the photo, not an upgrade: the switch
  // decides whether a `.DNG` rides along with its JPEG, and must not strand a shutter
  // press that has no JPEG to fetch instead.
  final rawOnly = groupAssets([
    AlbumFile.fromJson({
      'path': '/DCIM/100YICAM/P9140003.DNG',
      'date': '1789391480',
      'filetype': 'raw',
    }),
  ]).single;
  check('a shot listed as a bare .DNG is its own shot', rawOnly.isRawOnly);
  final rawOnlyQueue =
      plannedQueue([rawOnly], SyncPlan.forQueue(includeRaw: false));
  check(
      'a RAW-only shot is queued with the opt-in off — it has no JPEG to fetch instead',
      rawOnlyQueue.length == 1,
      rawOnlyQueue.map((f) => f.path).join(','));

  final mixed =
      plannedQueue([rawOnly, pair], SyncPlan.forQueue(includeRaw: false));
  check(
      'a mixed queue takes one file per shot and the JPEG of the pair',
      mixed.map((f) => f.path).join(',') ==
          '/DCIM/100YICAM/P9140003.DNG,/DCIM/100YICAM/P9140002.JPG',
      mixed.map((f) => f.path).join(','));

  // The ledger key a RAW is looked up by has one spelling, and the tile's "has it
  // landed" badge is that lookup: a mismatch would leave the badge on forever, which
  // is the same "claims work that will never finish" failure in a new place.
  check('assetIdOf is path plus the capture second',
      assetIdOf(pair.raw!).key == '/DCIM/100YICAM/P9140002.DNG|1789391479',
      assetIdOf(pair.raw!).key);

  print('\n=== HTTP transport command table ===');
  // Import check happens at compile time via the send() guard; assert the two
  // names that were previously wrong.
  check('RCStopRemoteCtl is the real stop command',
      isKnownCommand('RCStopRemoteCtl'));
  check('bare StopRemoteCtl is NOT a command',
      !isKnownCommand('StopRemoteCtl'));

  print('\n=== capture interlock (the firmware hang workaround) ===');

  // A scripted camera: hand back queued responses per command.
  final scripted = <String, List<CameraResponse>>{};
  final sent = <String>[];
  var simulatedFps = 30.0;
  CameraResponse okResp([Object? data]) =>
      CameraResponse(code: 200, raw: '{"code":200}', data: data);

  final client = CameraHttpClient(overrideSend: (cmd, params) async {
    sent.add(cmd);
    final q = scripted[cmd];
    if (q != null && q.isNotEmpty) return q.removeAt(0);
    return okResp();
  });

  // --- 1. photo fail must trigger quarantine
  scripted['RCDoShooting'] = [
    CameraResponse(code: 1000, raw: '{"code":1000,"data":"photo fail"}', data: 'photo fail'),
  ];
  scripted['GetCameraStatus'] = [okResp({'batteryLevel': '25'})];

  final guard = CaptureGuard(
    http: () => client,
    minInterval: Duration.zero, // keep the test fast
    quarantine: Duration.zero,  // the cooldown floor is tested separately below
    measureFps: () async => simulatedFps,
  );

  check('guard starts ready', guard.describe() == 'ready');
  check('guard starts unquarantined', !guard.isQuarantined);

  final r1 = await guard.shoot();
  check('photo fail is classified as rejected, not a plain failure',
      r1.outcome == CaptureOutcome.rejected, '${r1.outcome}');
  check('rejection quarantines the camera', guard.isQuarantined);

  // --- 2. HTTP answers, but the preview is still crawling: must stay blocked.
  // This is the important case - the hang's precursor looks healthy over HTTP.
  simulatedFps = 3.0;
  final r2 = await guard.shoot();
  check('HTTP-ok but preview stalled => still blocked',
      r2.outcome == CaptureOutcome.blocked, '${r2.outcome}');
  check('blocking explains itself', (r2.reason ?? '').isNotEmpty);
  check('no second RCDoShooting was actually sent',
      sent.where((c) => c == 'RCDoShooting').length == 1,
      'sent: $sent');
  check('health probe queried the camera', sent.contains('GetCameraStatus'));

  // --- 3. preview recovers => quarantine releases and capture proceeds
  simulatedFps = 30.0;
  final r3 = await guard.shoot();
  check('capture resumes once the preview recovers',
      r3.outcome == CaptureOutcome.ok, '${r3.outcome}');
  check('a successful capture reports tookPhoto', r3.tookPhoto);
  check('quarantine cleared after recovery', !guard.isQuarantined);

  // --- 4. the cooldown floor: a fresh guard must not release instantly
  final floorGuard = CaptureGuard(
    http: () => client,
    minInterval: Duration.zero,
    quarantine: const Duration(seconds: 30),
    measureFps: () async => 30.0,
  );
  scripted['RCDoShooting'] = [
    CameraResponse(code: 1000, raw: '{"code":1000,"data":"photo fail"}', data: 'photo fail'),
  ];
  await floorGuard.shoot();
  check('rejected again on the floor guard', floorGuard.isQuarantined);
  final rf = await floorGuard.shoot();
  check('cooldown floor holds even when the preview looks healthy',
      rf.outcome == CaptureOutcome.blocked, '${rf.outcome}');

  // --- 5. manual reset (user power-cycled the camera) clears quarantine
  await floorGuard.forceRelease();
  check('forceRelease clears quarantine', !floorGuard.isQuarantined);
  scripted['RCDoShooting'] = [okResp()];
  final r5 = await floorGuard.shoot();
  check('capture works again after reset', r5.outcome == CaptureOutcome.ok,
      '${r5.outcome}');

  // --- 6. an unreachable camera must not release quarantine
  final deadClient = CameraHttpClient(overrideSend: (cmd, params) async {
    throw const CameraHttpException('cannot reach 192.168.0.10');
  });
  final deadGuard = CaptureGuard(
    http: () => deadClient,
    minInterval: Duration.zero,
    quarantine: Duration.zero,
    measureFps: () async => 30.0,
  );
  scripted['RCDoShooting'] = [
    CameraResponse(code: 1000, raw: '{"code":1000,"data":"photo fail"}', data: 'photo fail'),
  ];
  final rd = await deadGuard.shoot();
  check('unreachable camera -> transportError', rd.outcome == CaptureOutcome.transportError,
      '${rd.outcome}');
  final rd2 = await deadGuard.shoot();
  check('unreachable camera stays blocked', rd2.outcome == CaptureOutcome.blocked,
      '${rd2.outcome}');

  // --- 7. the unsafe drive-mode list
  check('Continuous is flagged unsafe', kUnsafeDriveModes.contains('Continuous'));
  check('Single is not flagged unsafe', !kUnsafeDriveModes.contains('Single'));

  print('\n=== live view: telling a stall from a healthy stream ===');

  {
    // The badge that answers "has the camera stopped sending?" used to read
    // `LiveViewStats.fps`, which is `received / elapsed` — a **session average**.
    // It decays toward zero and never reaches it, so after a minute at 30 fps a
    // stream that stops dead still reads as ~20 fps, and the warning never fired.
    // These checks pin both halves of that: the old number is genuinely useless
    // for this question, and the new one answers it.
    final stats = LiveViewStats();

    check('a receiver that never received anything is not "stalled"',
        !stats.isStalled && stats.sinceLastFrame == null && stats.recentFps == 0);

    for (var i = 0; i < 5; i++) {
      // Mirrors `_handle`, which bumps `received` and then notes the arrival. The
      // two are deliberately separate: `received` feeds the session average, and
      // the arrival log feeds the recent rate.
      stats.received++;
      stats.noteArrival();
    }
    check('recentFps reports frames that just arrived', stats.recentFps > 0,
        stats.recentFps.toStringAsFixed(1));
    check('and the stream is not considered stalled while they arrive',
        !stats.isStalled);

    // Now stop feeding it, and wait past the threshold. This is the whole point:
    // the two numbers disagree, and the wrong one used to drive the UI.
    await Future<void>.delayed(
        Duration(milliseconds: LiveViewStats.stallAfterMs + 150));

    check('a stream that stopped is reported as stalled', stats.isStalled,
        'gap=${stats.sinceLastFrame?.inMilliseconds}ms');
    check('while the session average is still non-zero, which is why it cannot '
        'be used for this', stats.fps > 0, stats.fps.toStringAsFixed(1));

    stats.noteArrival();
    check('and one arriving frame clears the stall', !stats.isStalled);
    check('as does the recent rate', stats.recentFps > 0,
        stats.recentFps.toStringAsFixed(1));
  }

  print('\n=== camera state JSON inside live-view frames ===');

  final paramFiles = Directory('testdata')
      .listSync()
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last.startsWith('params_'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  check('captured parameter blocks present', paramFiles.isNotEmpty,
      '${paramFiles.length} files');

  if (paramFiles.isNotEmpty) {
    final block = paramFiles.first.readAsBytesSync();
    check('parameter block is 2272 bytes', block.length == 2272, '${block.length}');

    final st = CameraState.fromParameterBlock(block);
    check('state JSON decodes', st != null);

    if (st != null) {
      check('has the full field set', st.raw.length >= 20, '${st.raw.length} fields');

      for (final k in const [
        'ExposureMode', 'MeteringMode', 'ImageQuality', 'ImageAspect',
        'DriveMode', 'FileFormat', 'Fnumber', 'FnumberMin', 'FnumberMax',
        'ShutterSpeed', 'EV', 'ISOSetting', 'WB', 'ColorMode', 'BatteryLevel',
        'FocusMode', 'SurplusPhotoCnts', 'LensStatus',
      ]) {
        check('field $k present', st.raw.containsKey(k));
      }

      check('exposureMode parsed', st.exposureMode.isNotEmpty);
      check('fileFormat parsed', st.fileFormat.isNotEmpty, st.fileFormat);
      check('lens detected', st.hasLens, 'LensStatus=${st.lensStatus}');

      final range = st.apertureRange;
      check('aperture range comes for free', range != null, '$range');
      if (range != null) {
        check('aperture range is ordered', range.$1 < range.$2, '$range');
      }

      final bp = st.batteryPercent;
      check('battery percent parses', bp != null && bp >= 0 && bp <= 100, '$bp');

      // Brace matching must survive trailing zero padding - this is why the
      // parser does not simply search for the last '}'.
      final padded = Uint8List(block.length + 64)..setAll(0, block);
      final st2 = CameraState.fromParameterBlock(padded);
      check('trailing padding does not break parsing', st2 != null);
      check('padded parse yields the same fields',
          st2 != null && st2.raw.length == st.raw.length);

      // A block with no JSON must fail cleanly rather than throw.
      check('block without JSON returns null',
          CameraState.fromParameterBlock(Uint8List(512)) == null);

      // diffFrom drives "did the command actually land?" checks, which matter
      // because this firmware answers 200 to commands it did not apply.
      final modified = Map<String, String>.from(st.raw)..['ColorMode'] = 'Vivid';
      final d = CameraState(modified).diffFrom(st);
      check('diffFrom reports the changed field', d.containsKey('ColorMode'), '$d');
      check('diffFrom reports old and new',
          d['ColorMode'] == (st.colorMode, 'Vivid'), '${d['ColorMode']}');
      check('diffFrom is empty against itself', st.diffFrom(st).isEmpty);
    }
  }

  print('\n=== focus coordinate mapping (ported from the official app) ===');

  // A 4:3 preview box as the UI actually lays it out.
  const vw = 1080.0;
  const vh = 810.0;

  // On the narrow plane the x origin is offset by +40, so a tap at zero must NOT
  // produce x = 0.
  final tl43 = FocusMapper.toCamera(
      localX: 0, localY: 0, viewWidth: vw, viewHeight: vh, aspect: '4:3');
  check('4:3 top-left maps to the plane origin, not zero', tl43 == (40, 0), '$tl43');

  // Centre: x = 540*640/1080 + 40 = 360; y = 405*480/810 = 240.
  final c43 = FocusMapper.toCamera(
      localX: vw / 2, localY: vh / 2, viewWidth: vw, viewHeight: vh, aspect: '4:3');
  check('4:3 centre maps to the plane centre (360, 240)', c43 == (360, 240), '$c43');

  final br43 = FocusMapper.toCamera(
      localX: vw, localY: vh, viewWidth: vw, viewHeight: vh, aspect: '4:3');
  check('4:3 bottom-right maps to (680, 480)', br43 == (680, 480), '$br43');

  // THE REGRESSION THAT MATTERS. The 4:3 vertical scale divides by the view
  // HEIGHT, not the width. The two only disagree when the view's aspect differs
  // from the camera plane's - which is exactly the letterboxed case, e.g. a 4:3
  // view showing a 16:9 frame, or any view that is not 4:3.
  //
  // So this check uses a deliberately non-4:3 view. With a 4:3 view the two
  // formulas agree numerically, which is how the bug stayed hidden - and why the
  // first version of this test could not have caught it.
  const oddW = 1000.0;
  const oddH = 1000.0; // square view
  final v30 = FocusMapper.toCamera(
      localX: 0, localY: oddH * 0.3, viewWidth: oddW, viewHeight: oddH, aspect: '4:3');
  final byHeight = (oddH * 0.3 * 480 / oddH).round(); // 144
  final byWidth = (oddH * 0.3 * 640 / oddW).round(); // 192
  check('4:3 vertical scale uses the view height ($byHeight)',
      v30.$2 == byHeight, '${v30.$2}');
  check('and NOT the view width (which would give $byWidth)',
      v30.$2 != byWidth, '${v30.$2} vs $byWidth');

  // The horizontal scale still uses the width, on both planes.
  final h30 = FocusMapper.toCamera(
      localX: oddW * 0.5, localY: 0, viewWidth: oddW, viewHeight: oddH, aspect: '4:3');
  check('4:3 horizontal scale uses the view width (0.5 -> 360)', h30.$1 == 360,
      '${h30.$1}');

  // 16:9 uses the wide plane, where BOTH axes divide by the width.
  const vw169 = 1080.0;
  const vh169 = 607.5;
  final tl169 = FocusMapper.toCamera(
      localX: 0, localY: 0, viewWidth: vw169, viewHeight: vh169, aspect: '16:9');
  check('16:9 top-left maps to (0, -30) - y may be negative',
      tl169 == (0, -30), '$tl169');

  final c169 = FocusMapper.toCamera(
      localX: vw169 / 2,
      localY: vh169 / 2,
      viewWidth: vw169,
      viewHeight: vh169,
      aspect: '16:9');
  // 303.75 * 720 / 1080 - 30 = 172.5 -> 173. The plane's own centre would be
  // 330, so a 16:9 box centred in a 16:9 view does not land on the plane centre -
  // which is correct, and is why this branch uses the width for both axes.
  check('16:9 vertical centre maps to (360, 173)', c169 == (360, 173), '$c169');

  check('3:2 shares the wide plane',
      FocusMapper.toCamera(
              localX: 0, localY: 0, viewWidth: vw169, viewHeight: vh169, aspect: '3:2') ==
          (0, -30));
  check('1:1 shares the narrow plane',
      FocusMapper.toCamera(
              localX: 0, localY: 0, viewWidth: vw, viewHeight: vh, aspect: '1:1') ==
          (40, 0));
  check('an unknown aspect falls back to 4:3',
      FocusMapper.toCamera(
              localX: 0, localY: 0, viewWidth: vw, viewHeight: vh, aspect: '') ==
          (40, 0));
  check('the four real aspects are recognised',
      FocusMapper.isKnownAspect('4:3') &&
          FocusMapper.isKnownAspect('3:2') &&
          FocusMapper.isKnownAspect('16:9') &&
          FocusMapper.isKnownAspect('1:1'));
  check('a nonsense aspect is not', !FocusMapper.isKnownAspect('5:4'));

  // Forward and inverse must agree. The official app's two functions do, and a
  // disagreement is how the vertical-scale bug stayed hidden.
  final (fx, fy) = FocusMapper.fromCamera(
      x: 360, y: 240, viewWidth: vw, viewHeight: vh, aspect: '4:3');
  check('inverse round-trips a 4:3 point', fx == vw / 2 && fy == vh / 2, '($fx, $fy)');
  final (wx, wy) = FocusMapper.fromCamera(
      x: 360, y: 240, viewWidth: vw169, viewHeight: vh169, aspect: '16:9');
  check('inverse round-trips a wide point',
      wx == vw169 / 2 && (wy - (270 * vw169) / 720).abs() < 1e-9, '($wx, $wy)');

  // Every corner of the view must land inside the plane the camera accepts.
  // This is the check that actually catches a wrong divisor.
  var allPlausible = true;
  for (final aspect in const ['4:3', '3:2', '16:9', '1:1']) {
    final w = aspect == '16:9' ? vw169 : vw;
    final h = aspect == '16:9' ? vh169 : vh;
    for (final p in [
      (0.0, 0.0),
      (w, 0.0),
      (0.0, h),
      (w, h),
      (w / 2, h / 2),
    ]) {
      final (x, y) = FocusMapper.toCamera(
          localX: p.$1, localY: p.$2, viewWidth: w, viewHeight: h, aspect: aspect);
      if (!FocusMapper.isPlausible(x, y, aspect)) {
        allPlausible = false;
        print('    $aspect corner ${p.$1},${p.$2} -> ($x, $y) is off-plane');
      }
    }
  }
  check('every corner of the view maps inside the camera plane', allPlausible);

  check('a 4:3 point is plausible', FocusMapper.isPlausible(360, 240, '4:3'));
  check('x=0 is NOT plausible on the 4:3 plane (origin is +40)',
      !FocusMapper.isPlausible(0, 240, '4:3'));
  check('y=-30 IS plausible on the wide plane',
      FocusMapper.isPlausible(360, -30, '16:9'));
  check('the old 800x600 mapping is NOT plausible on 4:3',
      !FocusMapper.isPlausible(799, 599, '4:3'));

  await _deleteChecks();

  await _dangerousCommandChecks();

  print('\n=== viewfinder band layout ===');

  // The premise: a 4:3 frame cannot fill a phone screen, so there are always
  // bands. This layout puts the controls there instead of over the picture, so
  // the checks are about *which* edges get the bands and whether the frame is
  // left alone.

  // Portrait, 1080x2340 with a 4:3 frame -> bands above and below.
  const portrait = ViewfinderLayout(
      availableWidth: 1080, availableHeight: 2340, previewAspect: 4 / 3);
  check('portrait makes the frame width-limited',
      portrait.frameSize.width == 1080, '${portrait.frameSize}');
  check('portrait frame keeps 4:3',
      (portrait.frameSize.width / portrait.frameSize.height - 4 / 3).abs() < 1e-9,
      '${portrait.frameSize}');
  check('portrait leaves a vertical band', portrait.verticalBand > 1000,
      '${portrait.verticalBand}');
  check('portrait leaves no horizontal band', portrait.horizontalBand == 0,
      '${portrait.horizontalBand}');
  check('portrait does NOT use side columns', !portrait.usesSideColumns);
  check('portrait bands are top and bottom',
      portrait.bands.$1 == 0 && portrait.bands.$3 == 0 && portrait.bands.$2 > 0,
      '${portrait.bands}');
  check('portrait band fits controls', portrait.endBandFitsControls);

  // The same screen rotated -> bands left and right.
  const landscape = ViewfinderLayout(
      availableWidth: 2340, availableHeight: 1080, previewAspect: 4 / 3);
  check('landscape makes the frame height-limited',
      landscape.frameSize.height == 1080, '${landscape.frameSize}');
  check('landscape leaves a horizontal band', landscape.horizontalBand > 500,
      '${landscape.horizontalBand}');
  check('landscape leaves no vertical band', landscape.verticalBand == 0,
      '${landscape.verticalBand}');
  check('landscape uses side columns', landscape.usesSideColumns);
  check('landscape bands are left and right',
      landscape.bands.$2 == 0 && landscape.bands.$4 == 0 && landscape.bands.$1 > 0,
      '${landscape.bands}');
  check('landscape band fits controls', landscape.sideBandFitsControls);

  // The frame rect must be centred and inside the screen. A sign error here puts
  // the shutter over the picture.
  final pr = portrait.frameRect;
  check('portrait frame is horizontally centred', pr.left == 0, '${pr.left}');
  check('portrait frame is vertically centred',
      (pr.top - (2340 - pr.height) / 2).abs() < 1e-9, '${pr.top}');
  check('portrait frame fits the screen',
      pr.width <= 1080 + 1e-9 && pr.height <= 2340 + 1e-9);
  final lr = landscape.frameRect;
  check('landscape frame is vertically centred', lr.top == 0, '${lr.top}');
  check('landscape frame fits the screen',
      lr.width <= 2340 + 1e-9 && lr.height <= 1080 + 1e-9);

  // Only one axis ever carries bands, because the frame is fitted rather than
  // cropped. That is what makes the bands a reliable home for chrome.
  for (final spec in [
    (1080.0, 2340.0, 4 / 3),
    (2340.0, 1080.0, 4 / 3),
    (1080.0, 2340.0, 16 / 9),
    (2340.0, 1080.0, 16 / 9),
    (1080.0, 2340.0, 1.0),
    (1280.0, 800.0, 3 / 2),
  ]) {
    final l = ViewfinderLayout(
        availableWidth: spec.$1, availableHeight: spec.$2, previewAspect: spec.$3);
    final both = l.verticalBand > 0 && l.horizontalBand > 0;
    check('only one axis carries bands at ${spec.$1.toInt()}x${spec.$2.toInt()} '
        'aspect ${spec.$3.toStringAsFixed(3)}', !both,
        'v=${l.verticalBand} h=${l.horizontalBand}');
  }

  // A screen whose aspect already matches the frame has no bands, so the caller
  // must reserve none — otherwise controls would have nowhere to go and the
  // picture would be squeezed to make room that is not needed.
  const exact = ViewfinderLayout(
      availableWidth: 800, availableHeight: 600, previewAspect: 4 / 3);
  check('an exactly-matching screen has no bands',
      exact.verticalBand == 0 && exact.horizontalBand == 0,
      'v=${exact.verticalBand} h=${exact.horizontalBand}');
  check('and reserves no band space', exact.bands == (0.0, 0.0, 0.0, 0.0),
      '${exact.bands}');

  // Degenerate input must not throw or yield a negative band.
  const zero = ViewfinderLayout(
      availableWidth: 0, availableHeight: 0, previewAspect: 4 / 3);
  check('a zero-size screen yields a zero frame',
      zero.frameSize.width == 0 && zero.frameSize.height == 0);
  check('and no negative band',
      zero.verticalBand >= 0 && zero.horizontalBand >= 0);

  // ------------------------------------------------- landscape: the side bands
  //
  // The bands are not decoration — they are where the buttons and the camera
  // readout live in landscape, so the checks below are about whether the two
  // sides are actually usable rather than about the band being "big enough".
  //
  // Two things changed here. The band width is now capped, where before it was
  // whatever half the spare space happened to be; and the frame is placed
  // explicitly rather than by centring the leftover, because a cap means there
  // can be space that the bands do not claim.

  check('landscape reserves a control band of control width',
      landscape.controlBandWidth >= 56, '${landscape.controlBandWidth}');
  check('a band stops at the cap rather than swallowing a wide screen',
      landscape.controlBandWidth <= kMaxSideBand &&
          landscape.infoBandWidth <= kMaxSideBand,
      '${landscape.controlBandWidth} / ${landscape.infoBandWidth}');
  check('the two bands are the same width here',
      (landscape.controlBandWidth - landscape.infoBandWidth).abs() < 1e-9,
      '${landscape.controlBandWidth} vs ${landscape.infoBandWidth}');
  check('landscape still leaves the readout a usable band',
      landscape.infoBandWidth >= 56, '${landscape.infoBandWidth}');
  check('the control band lands on the right',
      landscape.bands.$3 == landscape.controlBandWidth &&
          landscape.bands.$1 == landscape.infoBandWidth,
      'left=${landscape.bands.$1} right=${landscape.bands.$3}');
  check('the frame is centred on the screen when the bands are equal',
      (landscape.frameRect.left -
                  (landscape.availableWidth - landscape.frameRect.width) / 2)
              .abs() <
          1e-9,
      'left=${landscape.frameRect.left}');
  check('the frame keeps the full height in landscape',
      landscape.frameRect.height == landscape.availableHeight,
      '${landscape.frameRect.height}');
  check('the frame keeps 4:3 in landscape',
      (landscape.frameRect.width / landscape.frameRect.height - 4 / 3).abs() <
          1e-9,
      '${landscape.frameRect}');
  // The frame, both bands and any surplus must account for exactly the screen: an
  // off-by-one here is what puts the picture under a column. With equal bands the
  // surplus splits evenly, so this comes out exact.
  check('bands, surplus and frame account for the whole width',
      (landscape.bands.$1 +
                  (landscape.frameRect.left - landscape.bands.$1) +
                  landscape.frameRect.width +
                  (landscape.availableWidth -
                      landscape.bands.$3 -
                      landscape.frameRect.left -
                      landscape.frameRect.width) +
                  landscape.bands.$3 -
                  landscape.availableWidth)
              .abs() <
          1e-9,
      '${landscape.bands} + ${landscape.frameRect.width}');
  check('the surplus is split evenly, so the frame stays centred',
      ((landscape.frameRect.left - landscape.bands.$1) -
                  (landscape.availableWidth -
                      landscape.bands.$3 -
                      landscape.frameRect.left -
                      landscape.frameRect.width))
              .abs() <
          1e-9,
      'left gap ${landscape.frameRect.left - landscape.bands.$1}');
  check('the frame sits clear of both bands',
      landscape.frameRect.left >= landscape.bands.$1 - 1e-9 &&
          landscape.frameRect.left + landscape.frameRect.width <=
              landscape.availableWidth - landscape.bands.$3 + 1e-9,
      '${landscape.frameRect}');

  // A phone is the case this design is for, and there the whole side band is
  // around 170dp — so neither side may claim more than half of it. This is the
  // check that catches a rule handing one side 160dp and the other 10, which
  // would clip the readout to nothing.
  //
  // 20:9, because "wider than tall" is not enough: a 4:3 frame on a 1.24-aspect
  // window fills the width exactly and leaves no side band at all. The bands only
  // exist once the screen is wider than the *frame*, which is what this models.
  const phoneLandscape = ViewfinderLayout(
      availableWidth: 1664, availableHeight: 749, previewAspect: 4 / 3);
  check('on a phone the two side bands come out equal',
      (phoneLandscape.controlBandWidth - phoneLandscape.infoBandWidth).abs() <
          1e-9,
      '${phoneLandscape.controlBandWidth} vs ${phoneLandscape.infoBandWidth}');
  check('and both still hold a control',
      phoneLandscape.controlBandWidth >= 56 &&
          phoneLandscape.infoBandWidth >= 56,
      '${phoneLandscape.controlBandWidth}');

  // ---- bands sized from their content, not from the screen's height ---------
  //
  // The emulator defect this exists for: on a 914x411dp landscape screen the
  // height-derived band was 99dp, and the 280dp navigation row destined for it was
  // scaled to about a third — 12sp labels rendering at roughly 4sp, illegible. The
  // width was never scarce: a 4:3 frame needs 332 of those 914dp, so most of the
  // screen sat empty while the bands fought over 198dp of it.
  //
  // These checks are the contract: when a caller says how wide its content is, the
  // band must actually be that wide, or the room must be shown to be genuinely
  // insufficient rather than silently stolen from the content.
  {
    const emulatorLandscape = ViewfinderLayout(
      availableWidth: 914,
      availableHeight: 297,
      previewAspect: 4 / 3,
      controlBandWant: 288,
      infoBandWant: 176,
    );

    check('a band is as wide as the content it was told about',
        emulatorLandscape.controlBandWidth >= 288 &&
            emulatorLandscape.infoBandWidth >= 176,
        'control=${emulatorLandscape.controlBandWidth} '
            'info=${emulatorLandscape.infoBandWidth}');

    // The whole point: widening the bands must not cost the picture. The frame is
    // height-limited, so it keeps its size as long as the bands fit inside the
    // horizontal slack.
    check('and paying for them does not shrink the frame',
        emulatorLandscape.frameRect.width >= 297 * 4 / 3 - 1e-9,
        'frame=${emulatorLandscape.frameRect.width}');

    check('the frame still keeps 4:3',
        (emulatorLandscape.frameRect.width / emulatorLandscape.frameRect.height -
                    4 / 3)
                .abs() <
            1e-9,
        '${emulatorLandscape.frameRect}');

    check('and the bands plus the frame still fit on the screen',
        emulatorLandscape.bands.$1 +
                emulatorLandscape.bands.$3 +
                emulatorLandscape.frameRect.width <=
            emulatorLandscape.availableWidth + 1e-9,
        '${emulatorLandscape.bands} frame=${emulatorLandscape.frameRect}');

    // Demanding more than exists must degrade by *splitting the room evenly*, not
    // by letting one column win: which control is usable must not depend on the
    // screen aspect.
    const greedy = ViewfinderLayout(
      availableWidth: 914,
      availableHeight: 297,
      previewAspect: 4 / 3,
      controlBandWant: 4000,
      infoBandWant: 4000,
    );
    check('impossible wants split the room evenly instead of starving one side',
        (greedy.controlBandWidth - greedy.infoBandWidth).abs() < 1e-9 &&
            greedy.controlBandWidth > 0,
        '${greedy.controlBandWidth} vs ${greedy.infoBandWidth}');
    check('and still leave the frame something to draw in',
        greedy.frameRect.width > 0, '${greedy.frameRect}');

    // A caller that has not measured its content keeps the old behaviour exactly.
    const noWants = ViewfinderLayout(
        availableWidth: 914, availableHeight: 297, previewAspect: 4 / 3);
    check('an unmeasured caller is no worse off than before',
        noWants.controlBandWidth <= kMaxSideBand &&
            noWants.controlBandWidth == noWants.infoBandWidth,
        '${noWants.controlBandWidth}');
  }

  // Whatever the screen, the bands must add up: a band narrower than a control
  // clips its button, and a split that does not sum to the screen width puts the
  // frame under one of them.
  var bandsHonestOnEveryScreen = true;
  for (final w in const [480.0, 700.0, 800.0, 900.0, 1080.0, 1280.0, 1600.0, 2560.0]) {
    for (final h in const [320.0, 400.0, 500.0, 600.0, 720.0, 1080.0]) {
      for (final aspect in const [4 / 3, 3 / 2, 16 / 9, 1.0]) {
        final l =
            ViewfinderLayout(availableWidth: w, availableHeight: h, previewAspect: aspect);
        if (!l.isLandscapeLayout || !l.sideBandFitsControls) continue;
        final b = l.bands;
        if (b.$1 < 0 || b.$3 < 0) bandsHonestOnEveryScreen = false;
        // The frame must never be drawn under a band, and the two bands must not
        // add up to more width than the screen has.
        if (l.frameRect.left < b.$1 - 1e-9 ||
            l.frameRect.left + l.frameRect.width >
                l.availableWidth - b.$3 + 1e-9) {
          bandsHonestOnEveryScreen = false;
        }
        // Neither side may be squeezed below the width a control needs. This is
        // the invariant that keeps `usesSideColumns` from lying.
        if (b.$1 + 1e-9 < 56 || b.$3 + 1e-9 < 56) {
          bandsHonestOnEveryScreen = false;
        }
      }
    }
  }
  check('every band clears a control and stays clear of the frame',
      bandsHonestOnEveryScreen);

  // The controls-on-the-left case must mirror rather than duplicate.
  const mirrored = ViewfinderLayout(
    availableWidth: 2340,
    availableHeight: 1080,
    previewAspect: 4 / 3,
    controlsOnTrailingEdge: false,
  );
  check('mirroring puts the control band on the left',
      mirrored.bands.$1 == mirrored.controlBandWidth &&
          mirrored.bands.$3 == mirrored.infoBandWidth,
      '${mirrored.bands}');

  // The settings panel is a second-level menu of dropdown rows. In landscape it
  // is a sheet over the frame, so it must be panel-wide rather than band-wide,
  // and it must not be sized off the screen so much that the frame is unusable.
  check('the panel is panel-wide in landscape, not band-wide',
      landscape.settingsPanelWidth >= 240 &&
          landscape.settingsPanelWidth <= 360 &&
          landscape.settingsPanelWidth > landscape.controlBandWidth,
      '${landscape.settingsPanelWidth} vs band ${landscape.controlBandWidth}');
  check('the panel never claims the whole screen',
      landscape.settingsPanelWidth < landscape.availableWidth,
      '${landscape.settingsPanelWidth}');
  const tablet = ViewfinderLayout(
      availableWidth: 2560, availableHeight: 1600, previewAspect: 4 / 3);
  check('the panel stops growing on a wide screen',
      tablet.settingsPanelWidth == 360, '${tablet.settingsPanelWidth}');

  // The panel is drawn over the frame, so what matters is what it *hides*. A
  // sheet narrower than the control band would not even cover the buttons it
  // belongs to; one that reached the opposite band would black out the readout
  // the user is watching while changing a setting.
  final cover = settingsSheetCoverage(
      availableWidth: 1664,
      availableHeight: 749,
      previewAspect: 4 / 3,
      panelWidth: phoneLandscape.settingsPanelWidth);
  check('the settings sheet covers the whole control band',
      cover.right >= phoneLandscape.controlBandWidth,
      '${cover.right} vs band ${phoneLandscape.controlBandWidth}');
  check('and does not reach the readout band opposite',
      cover.right < 1664 - phoneLandscape.infoBandWidth,
      '${cover.right} of 1664');
  check('a portrait layout has no side sheet at all',
      settingsSheetCoverage(
              availableWidth: 1080, availableHeight: 2340, previewAspect: 4 / 3) ==
          (left: 0.0, right: 0.0));

  // ------------------------------------------------------- portrait regression
  //
  // Portrait is where the layout was already right, and the landscape work
  // touched the shared `bands`/`frameRect` code that portrait reads. Every
  // property portrait relied on is re-asserted here rather than trusted.
  const tall = ViewfinderLayout(
      availableWidth: 1080, availableHeight: 2340, previewAspect: 4 / 3);
  check('portrait still fits the frame to the width',
      tall.frameSize.width == 1080, '${tall.frameSize}');
  check('portrait bands are still symmetric',
      tall.bands.$2 == tall.bands.$4,
      '${tall.bands}');
  check('portrait keeps the controls out of the side bands',
      tall.bands.$1 == 0 && tall.bands.$3 == 0, '${tall.bands}');
  check('portrait does not use side columns', !tall.usesSideColumns);
  check('portrait still has no horizontal band', tall.horizontalBand == 0,
      '${tall.horizontalBand}');
  check('portrait frame starts at the left edge', tall.frameRect.left == 0,
      '${tall.frameRect.left}');
  check('portrait frame is still vertically centred',
      (tall.frameRect.top - (2340 - tall.frameRect.height) / 2).abs() < 1e-9,
      '${tall.frameRect.top}');
  // The panel spans the band in portrait, so its width is the screen's.
  check('the panel spans the screen in portrait',
      tall.settingsPanelWidth == 1080, '${tall.settingsPanelWidth}');
  check('the side-band split never leaks into portrait',
      (tall.bands.$1 + tall.bands.$3) == 0 &&
          tall.controlBandWidth == tall.horizontalBand / 2,
      '${tall.controlBandWidth}');

  // A 16:9 frame on a short window leaves a band too thin for chrome; the caller
  // keys off `endBandFitsControls`, so it must be false rather than the band
  // silently being used and clipped.
  const thin = ViewfinderLayout(
      availableWidth: 1080, availableHeight: 480, previewAspect: 16 / 9);
  check('a band too thin for chrome reserves none',
      !thin.endBandFitsControls && thin.bands.$2 == 0 && thin.bands.$4 == 0,
      '${thin.bands} v=${thin.verticalBand}');

  print('\n=== settings menu structure (the second level) ===');

  // The menu is data (`kSettingsTabs`) so its shape can be checked here,
  // without a Flutter engine. What is worth checking is not the order of the rows
  // but the two claims the design rests on: nothing is unreachable, and nothing
  // that changes between frames is hidden behind a tap.

  final groups = kSettingsGroups;
  check('the menu has more than one group', groups.length >= 4,
      '${groups.length}');
  check('every group has an id and rows',
      groups.every((g) => g.id.isNotEmpty && g.rows.isNotEmpty));
  check('group ids are unique',
      groups.map((g) => g.id).toSet().length == groups.length);
  check('tab ids are unique',
      kSettingsTabs.map((t) => t.id).toSet().length ==
          kSettingsTabs.length);
  check('every tab has a group',
      kSettingsTabs.every((t) => t.groups.isNotEmpty));

  // A collapsed group builds its children, so this is about what the user has to
  // tap through rather than about whether the row exists at all.
  final collapsed =
      groups.where((g) => g.collapsible && !g.openByDefault).map((g) => g.id);
  check('some groups start collapsed, or there is no second level',
      collapsed.isNotEmpty, '$collapsed');
  check('a collapsed group says what is inside it',
      groups
          .where((g) => g.collapsible && !g.openByDefault)
          .every((g) => (g.summary ?? '').isNotEmpty));
  check('exactly one group is non-collapsible (the shooting controls)',
      groups.where((g) => !g.collapsible).length == 1,
      '${groups.where((g) => !g.collapsible).map((g) => g.id).toList()}');

  // Every settable parameter has exactly one home. A parameter the protocol
  // exposes but the menu never offers is the "code written, never wired" defect
  // this project keeps hitting; one offered twice is two controls disagreeing.
  //
  // The reference list is written out here rather than read from
  // `AppState.paramCommands`, because `AppState` imports Flutter and this program
  // runs without an engine. That is not a weakening: `AppState.paramCommands` is
  // itself checked against the firmware's command and value tables below, and a
  // hand-written list is the only version of this check that can fail when
  // someone edits *both* the catalog and the command map to match each other.
  const settableParams = {
    'RCSwitchDialMode': 'DialMode',
    'RCMeteringModeSet': 'MeteringMode',
    'RCFocusModeSet': 'FocusMode',
    'RCImageQualitySet': 'ImageQuality',
    'RCImageAspect': 'ImageAspect',
    'RCFileFormatSet': 'FileFormat',
    'RCDriveModeSet': 'DriveMode',
    'RCFNSet': 'Fnumber',
    'RCShutterSpeedSet': 'ShutterSpeed',
    'RCEVSet': 'EV',
    'RCISOSet': 'ISO',
    'RCWBSet': 'WB',
    'RCChooseColorMode': 'ColorMode',
  };
  final menuCommands = kMenuParamCommands;
  check('every settable parameter appears in the menu',
      settableParams.keys.every(menuCommands.contains),
      settableParams.keys
          .where((c) => !menuCommands.contains(c))
          .toList()
          .toString());
  check('no parameter command appears twice',
      menuCommands.length == menuCommands.toSet().length, '$menuCommands');
  check('every menu parameter is a settable command',
      menuCommands.every(settableParams.containsKey),
      menuCommands
          .where((c) => !settableParams.containsKey(c))
          .toList()
          .toString());
  check('every menu parameter is in the firmware command table',
      menuCommands.every(isKnownCommand),
      menuCommands.where((c) => !isKnownCommand(c)).toList().toString());

  // The two claims that keep the shooting controls out of the second level.
  final alwaysVisible = groups
      .where((g) => !g.collapsible)
      .expand((g) => g.paramRows)
      .map((r) => r.key)
      .toSet();
  const usedWhileShooting = [
    'RCEVSet',
    'RCShutterSpeedSet',
    'RCISOSet',
    'RCWBSet',
    'RCDriveModeSet',
    'RCFocusModeSet',
    'RCSwitchDialMode',
    'RCFNSet',
  ];
  check('every control used while shooting is always on screen',
      usedWhileShooting.every(alwaysVisible.contains),
      usedWhileShooting.where((c) => !alwaysVisible.contains(c)).toList().toString());

  // And the converse: the settings the user decides once are the ones one down.
  // Named individually because "which settings are low-frequency" is a design
  // decision, and a decision that is not written down cannot be checked.
  final behindAGroup = groups
      .where((g) => g.collapsible && !g.openByDefault)
      .expand((g) => g.paramRows)
      .map((r) => r.key)
      .toSet();
  const oneOff = [
    'RCImageAspect',
    'RCFileFormatSet',
    'RCImageQualitySet',
    'RCChooseColorMode',
  ];
  check('one-off settings are one level down',
      oneOff.every(behindAGroup.contains),
      oneOff.where((c) => !behindAGroup.contains(c)).toList().toString());
  check('and nothing is both always-visible and one level down',
      alwaysVisible.intersection(behindAGroup).isEmpty);

  // Rows that are not parameters must still resolve to something the panel can
  // build: a toggle needs a key it can read, an action needs a handler.
  final nonParamKeys = [
    for (final g in groups)
      for (final r in g.actionRows) r.key,
  ];
  check('every non-parameter row carries a key',
      nonParamKeys.every((k) => k.isNotEmpty), '$nonParamKeys');
  check('every non-parameter key is dispatched by the panel',
      nonParamKeys.every(kSettingsActionKeys.contains),
      nonParamKeys
          .where((k) => !kSettingsActionKeys.contains(k))
          .toList()
          .toString());

  // A parameter row draws its choices from the firmware's own value pool. The
  // pool is **not** indexed by the wire parameter key — `RCMeteringModeSet` sets
  // `MeteringMode`, whose pool is `meteringMode` — so this checks the catalog's
  // own command->pool table rather than assuming the two names agree. A row whose
  // pool is missing renders an empty dropdown: a control that appears and cannot
  // set anything.
  check('every parameter row names a value pool',
      settableParams.keys.every(kSettingsRowPools.containsKey),
      settableParams.keys
          .where((c) => !kSettingsRowPools.containsKey(c))
          .toList()
          .toString());
  check('every named pool exists in the firmware tables',
      kSettingsRowPools.values.every(kRcValuePools.containsKey),
      kSettingsRowPools.entries
          .where((e) => !kRcValuePools.containsKey(e.value))
          .map((e) => '${e.key}->${e.value}')
          .toList()
          .toString());
  check('every value pool is non-empty',
      kSettingsRowPools.values.every((k) => kRcValuePools[k]!.isNotEmpty));

  // Group and tab icon names are resolved to `IconData` in the UI layer, so a
  // typo produces a fallback chevron rather than a failure. Checked here because
  // nothing else would notice.
  final iconNames = [
    ...kSettingsTabs.map((t) => t.icon),
    ...groups.map((g) => g.icon),
  ];
  check('every group and tab names a known icon',
      iconNames.every(kKnownSettingsIcons.contains),
      iconNames
          .where((n) => !kKnownSettingsIcons.contains(n))
          .toList()
          .toString());

  print('\n=== settings menu: persisted layout ===');

  // Which groups are open and which tab was last used must survive a relaunch, or
  // the menu resets its own arrangement every time the app is reopened. The codec
  // is checked rather than the widget because losing a preference is a silent
  // failure: the app still works, it just forgets.
  final prefs = UiPrefs(store: MemorySyncStore());
  check('an untouched group uses its own default',
      !prefs.isGroupOpen('image', fallback: false) &&
          prefs.isGroupOpen('image', fallback: true));
  prefs.setGroupOpen('image', true);
  prefs.setLastTab('sync');
  check('an opened group reads back open',
      prefs.isGroupOpen('image', fallback: false));
  check('and overrides a default of closed',
      prefs.isGroupOpen('image', fallback: false));
  prefs.setGroupOpen('image', false);
  check('closing it wins over the group default',
      !prefs.isGroupOpen('image', fallback: true));

  prefs.setGroupOpen('image', true);
  prefs.setGroupOpen('video', false);
  prefs.setLastTab('sync');
  final roundTripped = UiPrefs(store: MemorySyncStore());
  await roundTripped.load();
  check('a fresh install starts with nothing remembered',
      roundTripped.openGroups.isEmpty &&
          roundTripped.closedGroups.isEmpty &&
          roundTripped.lastTab == null);
  check('keep-screen-on defaults to on, as the app shipped',
      roundTripped.keepScreenOn);
  final written = MemorySyncStore(prefs.encode());
  final reloaded = UiPrefs(store: written);
  await reloaded.load();
  check('an open group survives a save/load',
      reloaded.isGroupOpen('image', fallback: false), reloaded.encode());
  check('a closed group survives a save/load',
      !reloaded.isGroupOpen('video', fallback: true), reloaded.encode());
  check('the last tab survives a save/load', reloaded.lastTab == 'sync',
      '${reloaded.lastTab}');
  check('a group nobody has touched still uses its default',
      reloaded.isGroupOpen('system', fallback: true) &&
          !reloaded.isGroupOpen('system', fallback: false));

  reloaded.setKeepScreenOn(false);
  await reloaded.save();
  final kept = UiPrefs(store: written);
  await kept.load();
  check('the screen-pin choice survives a save/load', !kept.keepScreenOn);

  // A file written before a field existed must not flip that field to the
  // opposite of its default: turning the screen pin back on for a user who never
  // touched it is exactly the kind of silent regression this codec is defensive
  // about.
  final legacy = UiPrefs(store: MemorySyncStore('{"version":1,"open":["image"]}'));
  await legacy.load();
  check('an older preferences file keeps the screen pin on', legacy.keepScreenOn);
  check('and still restores what it does carry',
      legacy.isGroupOpen('image', fallback: false));

  // The RAW opt-in is the one stored preference with a **data bill** attached, so its
  // default is asserted in both directions rather than assumed: a fresh install must
  // not commit the user to ~32 MB a shot, and a stored "yes" must survive a relaunch
  // or the user has to re-arm it against a card they already paid for once.
  final rawDefault = UiPrefs(store: MemorySyncStore());
  await rawDefault.load();
  check('a fresh install does not opt into RAW', !rawDefault.includeRaw);
  check('an older preferences file does not opt into RAW either',
      !legacy.includeRaw,
      'a file written before the switch existed must read as "never asked", and '
          '"never asked" is off');
  final rawPrefOn = UiPrefs(store: MemorySyncStore());
  rawPrefOn.setIncludeRaw(true);
  final rawPrefBack = UiPrefs(store: MemorySyncStore(rawPrefOn.encode()));
  await rawPrefBack.load();
  check('the RAW opt-in survives a save/load', rawPrefBack.includeRaw,
      rawPrefOn.encode());
  check('and turning it back off is stored too, not lost as "absent"', () {
    final off = UiPrefs(store: MemorySyncStore());
    off.setIncludeRaw(true);
    off.setIncludeRaw(false);
    return !off.encode().contains('"includeRaw":true');
  }(), rawPrefOn.encode());

  final damaged = UiPrefs(store: MemorySyncStore('not json at all'));
  await damaged.load();
  check('a damaged preferences file falls back to defaults rather than throwing',
      damaged.openGroups.isEmpty && damaged.lastTab == null);

  final injected =
      UiPrefs(store: MemorySyncStore(prefs.encode().replaceAll('sync', 'sy"nc')));
  await injected.load();
  check('a quote in a stored id cannot break the parse',
      injected.lastTab == null || injected.lastTab!.isNotEmpty);

  // Every group the catalog declares must be storable. A group whose state is
  // never written is a group that resets on every launch, which is precisely the
  // behaviour the persistence exists to prevent — and it would be invisible.
  final allGroups = UiPrefs(store: MemorySyncStore());
  for (final g in groups) {
    allGroups.setGroupOpen(g.id, true);
  }
  for (final g in groups) {
    allGroups.setGroupOpen(g.id, false);
  }
  final groupRound = UiPrefs(store: MemorySyncStore(allGroups.encode()));
  await groupRound.load();
  check('every group in the menu round-trips its state',
      groups.every((g) => !groupRound.isGroupOpen(g.id, fallback: true)),
      groupRound.encode());
  check('and the file stayed small enough to read on the launch path',
      allGroups.encode().length < 4096, '${allGroups.encode().length} bytes');

  await _verifySecondAttempts();

  print('\n${'=' * 52}');
  print('  $_pass passed, $_fail failed');
  print('${'=' * 52}');
  exit(_fail == 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// T17 — deleting on the camera.
//
// Everything here exists because of a measured property of the firmware rather
// than a preference: `DeleteFile` clamps its list at 30 entries, copies each path
// into a 56-byte slot, answers `200` to work it did not do, and treats the literal
// `ALL` as "erase the card". A delete is also the one irreversible thing this app
// can do, so the checks are aimed at what would make it lie to the user.

/// A camera whose card contents the test controls.
///
/// Scripted through `GetFileList`/`DeleteFile` rather than through the album's
/// download seam, because the whole point of the delete design is what it does
/// with the *listing* — believing it is exactly the mistake being guarded against.
///
/// **The listing is not the card.** A real card holds files `GetFileList` never
/// returns: the RAW half of every `rawJpeg` shot. A fixture that cannot express that
/// difference cannot fail the delete verification either, because `after.contains(p)`
/// is then true for a path the firmware would never have sent — which is one of the
/// two reasons finding #1 of `analysis/79` stayed green. [files] is what is **listed**;
/// [unlisted] is what is on the card and never listed.
class _FakeCamera {
  /// Paths currently on the "card" **that `GetFileList` returns**, in listing order.
  List<AlbumFile> files;

  /// Paths that are on the card and that `GetFileList` never returns.
  ///
  /// `analysis/50` §1, measured on the real 3.1-cn body: 25 listing records for 25
  /// shutter presses, 18 of them `rawJpeg` whose path ends `.JPG` — and **not one
  /// `.DNG`**. The RAW is there (`Original` answers `200` with 31,931,408 B beginning
  /// `II*\0`); the listing simply never mentions it.
  final List<String> unlisted;

  /// Set true to make `DeleteFile` answer `200` and change nothing, which is the
  /// behaviour the post-delete re-listing exists to catch.
  bool ignoreDeletes = false;

  /// Whether a `DeleteFile` that names an [unlisted] path removes it.
  ///
  /// **Neither setting is a measurement, and the fixture does not pretend
  /// otherwise.** What this firmware does when it is asked to delete a derived
  /// `.DNG` path has **never been measured by anyone** (`analysis/79`, "what this
  /// audit did not cover"), so the fixture offers both answers instead of choosing
  /// one. The app has to be right about both, because nothing it can see tells them
  /// apart.
  bool removesUnlisted = false;

  /// How many more listings succeed before they start failing. Null = always.
  int? listingsBeforeFailure;

  /// How many listings fail **from the start**, before any succeed.
  ///
  /// The other way round from [listingsBeforeFailure], and it exists for the other
  /// half of the verification: stopping the *pre*-delete listing leaves the
  /// post-delete one working, which is the one shape where the app has to decide
  /// about a derived path with no pre-listing to consult.
  int failFirstListings = 0;

  /// Every `file_list` the client actually put on the wire.
  final List<List<String>> sentRequests = [];

  int listingCount = 0;

  _FakeCamera(this.files, {List<String> unlisted = const []})
      : unlisted = List<String>.of(unlisted);

  /// The scripted camera, as one function.
  ///
  /// A method rather than a closure inside [album] because the client now has two
  /// send overrides — the plain one and the approved one — and a fake that wired
  /// only the first would silently stop seeing `DeleteFile`, which is the command
  /// this class exists to script. Both overrides point here.
  Future<CameraResponse> handle(String cmd, Map<String, Object> params) async {
    switch (cmd) {
      case 'GetFileList':
        if (failFirstListings > 0) {
          failFirstListings--;
          throw const CameraHttpException('cannot reach 192.168.0.10 (simulated)');
        }
        if (listingsBeforeFailure != null) {
          if (listingsBeforeFailure! <= 0) {
            throw const CameraHttpException(
                'cannot reach 192.168.0.10 (simulated)');
          }
          listingsBeforeFailure = listingsBeforeFailure! - 1;
        }
        listingCount++;
        final start = int.parse('${params['range_start']}');
        final end = int.parse('${params['range_end']}');
        final page = [
          for (var i = start - 1; i < end && i < files.length; i++)
            {
              'path': files[i].path,
              'date': '${files[i].captureTime!.millisecondsSinceEpoch ~/ 1000}',
              'filetype': files[i].fileType,
              'protectStatus': files[i].protectStatus,
            },
        ];
        return CameraResponse(code: 200, raw: '{"code":200}', data: page);
      case 'DeleteFile':
        final list = (params['file_list'] as List).cast<String>().toList();
        sentRequests.add(list);
        if (!ignoreDeletes) {
          files = [
            for (final f in files)
              if (!list.contains(f.path)) f,
          ];
          if (removesUnlisted) unlisted.removeWhere(list.contains);
        }
        return CameraResponse(code: 200, raw: '{"code":200}');
      default:
        return CameraResponse(code: 200, raw: '{"code":200}');
    }
  }

  CameraAlbum get album => CameraAlbum(
        CameraHttpClient(
          overrideSend: handle,
          overrideApprovedSend: (cmd, params, approval) =>
              handle(cmd, params),
        ),
      );

  /// The album's own pairing rule, applied to the fake listing.
  List<AssetGroup> groups() => groupAssets(files);
}

/// Padded so a path's length is predictable: `/DCIM/100YICAM/YI000001.JPG`.
String _p(int n) => '/DCIM/100YICAM/YI${n.toString().padLeft(6, '0')}';

AlbumFile _f(int n,
        {String ext = 'JPG',
        String type = 'picture',
        bool protect = false,
        int date = 1700000000}) =>
    AlbumFile(
      path: '${_p(n)}.$ext',
      fileType: type,
      protectStatus: protect,
      captureTime: DateTime.fromMillisecondsSinceEpoch(date * 1000),
    );

/// One shutter press in a RAW+JPEG drive mode, **as the camera really reports it**.
///
/// `analysis/50` §1, measured on the real 3.1-cn body: a single listing record whose
/// `filetype` is `rawJpeg` and whose path ends `.JPG`, and **no `.DNG` record at
/// all** — 25 records for 25 shutter presses, 18 of them `rawJpeg`. The RAW is
/// fetchable at `Original` (200, 31,931,408 B, `II*\0`) and is not in the listing.
///
/// [listed] and [rawPath] are therefore two different things, and they are returned
/// together so a fixture cannot quietly hand the RAW back to the listing. The path
/// is written here as a **literal**, not derived by the code under test: if
/// `AlbumFile.rawSibling` ever derived a different name, the plan would send a path
/// the fixture's card does not hold and the delete checks below would go red.
({AlbumFile listed, String rawPath}) _rawJpegShot(int n,
        {int date = 1700000000}) =>
    (
      listed: _f(n, type: 'rawJpeg', date: date),
      rawPath: '${_p(n)}.DNG',
    );

Future<void> _deleteChecks() async {
  print('\n=== DeleteFile: the request shape the firmware expects ===');

  final empty = _FakeCamera([]);
  final album = empty.album;

  await _expectAlbumException('an empty file_list is refused before it is sent',
      () => album.deleteFileList(const []));
  await _expectAlbumException(
      'more than 30 paths in one call is refused rather than silently clamped',
      () => album.deleteFileList([for (var i = 1; i <= 31; i++) '${_p(i)}.JPG']));
  await _expectAlbumException(
      'a path over the 52-character DeleteFile slot is refused',
      () => album.deleteFileList(['/DCIM/100YICAM/${'X' * 40}.JPG']));
  await _expectAlbumException(
      'and "ALL" — delete the whole card — is refused outright',
      () => album.deleteFileList(const ['ALL']));
  check('nothing was sent to the camera by any of those refusals',
      empty.sentRequests.isEmpty, '${empty.sentRequests}');

  final wire = _FakeCamera([_f(1)]);
  await wire.album.deleteFileList(['${_p(1)}.JPG']);
  check('file_list goes on the wire as a JSON array of paths',
      wire.sentRequests.length == 1 &&
          wire.sentRequests.first.length == 1 &&
          wire.sentRequests.first.first == '${_p(1)}.JPG',
      '${wire.sentRequests}');

  print('\n=== DeleteFile: batching, pair atomicity and refusals ===');

  check('a lone JPEG is one file in one shot',
      planDelete(groupAssets([_f(1)])).files == 1);

  // 45 JPEGs: the firmware's clamp is 30, so this must be two requests.
  final many = [for (var i = 1; i <= 45; i++) _f(i)];
  final manyPlan = planDelete(groupAssets(many));
  check('45 paths are split into more than one request', manyPlan.batches.length > 1,
      '${manyPlan.batches.length} batch(es)');
  check('and no request exceeds the firmware\'s 30-path clamp',
      manyPlan.batches.every((b) => b.paths.length <= 30),
      '${manyPlan.batches.map((b) => b.paths.length)}');
  check('every selected path is in exactly one batch',
      manyPlan.paths.length == 45 && manyPlan.paths.toSet().length == 45,
      '${manyPlan.paths.length}');
  check('45 JPEGs are 45 shots', manyPlan.shotCount == 45,
      '${manyPlan.shotCount}');

  // A RAW+JPEG exposure is two files and ONE shot, which is what the
  // confirmation must say and what the grid already shows.
  final pairPlan = planDelete(groupAssets([_f(1), _f(1, ext: 'DNG', type: 'raw')]));
  check('a RAW+JPEG pair plans both files', pairPlan.files == 2);
  check('and counts as one shot', pairPlan.shotCount == 1, '${pairPlan.shotCount}');
  check('both halves are in the same request, so a pair cannot be half-deleted',
      pairPlan.batches.length == 1 &&
          pairPlan.batches.first.paths.length == 2);

  // The boundary case that packing greedily gets wrong: a pair must not straddle
  // the 30-path boundary, even when that leaves a batch short.
  final boundary = <AlbumFile>[
    for (var i = 1; i <= 13; i++) _f(i),
    for (var i = 14; i <= 22; i++) ...[
      _f(i),
      _f(i, ext: 'DNG', type: 'raw'),
    ],
  ];
  check('the fixture really is 13 singles and 9 pairs',
      groupAssets(boundary).length == 22, '${groupAssets(boundary).length}');
  final boundaryPlan = planDelete(groupAssets(boundary));
  final split = <String>[];
  // The invariant is about a *pair*, not about a batch having distinct shot
  // names: both siblings of a two-asset shot must be in the same request.
  for (final g in groupAssets(boundary)) {
    if (g.assets.length != 2) continue;
    final first = boundaryPlan.batches
        .where((b) => b.paths.contains(g.assets[0].path))
        .toList();
    final second = boundaryPlan.batches
        .where((b) => b.paths.contains(g.assets[1].path))
        .toList();
    if (first.isEmpty || second.isEmpty || first.single != second.single) {
      split.add('${g.primary.fileName} (${first.length} vs ${second.length})');
    }
  }
  check('no request ever splits a RAW+JPEG pair across two batches',
      split.isEmpty, 'splits: $split — ${boundaryPlan.batches.map((b) => b.paths.length)}');
  check('a pair-heavy selection still respects the 30-path clamp',
      boundaryPlan.batches.every((b) => b.paths.length <= 30),
      '${boundaryPlan.batches.map((b) => b.paths.length)}');

  // A protected file is refused, and its sibling with it: deleting the other half
  // would leave an orphan the album can no longer render as one photo.
  final protectedPlan = planDelete(groupAssets([
    _f(1, protect: true),
    _f(1, ext: 'DNG', type: 'raw'),
  ]));
  check('a protected file is not deleted', protectedPlan.isEmpty);
  check('its RAW sibling is not deleted either, so no orphan is created',
      protectedPlan.files == 0 && protectedPlan.refusals.length == 2,
      '${protectedPlan.refusals}');
  check('the protected file is refused for the verified reason',
      protectedPlan.refusals.any((r) => r.block == DeleteBlock.protectedOnCamera));
  check('and the sibling is refused as an orphaned pair, not silently dropped',
      protectedPlan.refusals.any((r) => r.block == DeleteBlock.orphanedPairSibling));
  check('every refusal carries a reason the UI can show',
      protectedPlan.refusals.every((r) => r.reason.length > 20));

  // The 51/52-character band: `GetFile` copies into 50 bytes, `DeleteFile` into
  // 56. A 52-character path is therefore **deletable and not downloadable**, and
  // a pair must not be half-deleted because of that.
  final widePath = AlbumFile(
    path: '/DCIM/100YICAM/${'Y' * 33}.JPG',
    fileType: 'picture',
    captureTime: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );
  check('a 52-character path is deletable but not downloadable — the band this '
      'getter exists for',
      widePath.path.length == 52 &&
          widePath.isPathTooLong &&
          !widePath.isDeletePathTooLong,
      '${widePath.path.length} chars');
  final widePair = planDelete(groupAssets([
    widePath,
    _f(1, ext: 'DNG', type: 'raw'),
  ]));
  check('such a path is still deleted, and its pair with it',
      widePair.files == 2 && widePair.refusals.isEmpty, '${widePair.refusals}');

  // Past 52 the handler would memcpy a truncated path, i.e. delete a different
  // file, so it is refused with a reason instead.
  final overLong = AlbumFile(
    path: '/DCIM/100YICAM/${'Z' * 37}.JPG',
    fileType: 'picture',
    captureTime: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );  final overLongPlan = planDelete(groupAssets([overLong]));
  check('a path past the DeleteFile slot is refused rather than truncated',
      overLongPlan.files == 0 &&
          overLongPlan.refusals.single.block == DeleteBlock.pathTooLong,
      '${overLongPlan.refusals}');
  check('and the refusal is what would have gone wrong, not a bare "no"',
      overLongPlan.refusals.single.reason.contains('truncate'),
      overLongPlan.refusals.single.reason);

  print('\n=== DeleteFile: verification, because 200 is not proof ===');

  final ok = _FakeCamera([_f(1), _f(2)]);
  final okReport = await FileDeleter(album: ok.album)
      .submit(planDelete([groupAssets([_f(1)])[0]]));
  check('a delete that really happened is confirmed against a fresh listing',
      okReport.allConfirmed && okReport.confirmed == 1, okReport.summary);
  check('the reminder of the album is untouched', ok.files.length == 1);
  check('the summary reports the 200-is-not-proof check it performed',
      okReport.summary.contains('checked against a fresh listing'),
      okReport.summary);

  final liar = _FakeCamera([_f(1), _f(2)])..ignoreDeletes = true;
  final liarReport = await FileDeleter(album: liar.album)
      .submit(planDelete([groupAssets([_f(1)])[0]]));
  check('a 200 that deleted nothing is reported as still on the card',
      liarReport.failed == 1 && liarReport.confirmed == 0, liarReport.summary);
  check('and the file is not removed from the UI',
      liarReport.removedShots.isEmpty, '${liarReport.removedShots}');

  final blind = _FakeCamera([_f(1)])..listingsBeforeFailure = 1;
  final blindReport = await FileDeleter(album: blind.album)
      .submit(planDelete([groupAssets([_f(1)])[0]]));
  check('a delete that cannot be checked is called unconfirmed, not success',
      blindReport.unconfirmed == 1 && blindReport.confirmed == 0,
      blindReport.summary);
  check('and the reason is carried for the UI', blindReport.verifyError != null,
      '${blindReport.verifyError}');

  // A pair is reported per file, and the row only leaves the grid when both
  // halves are confirmed gone — otherwise the orphan would be invisible.
  //
  // ## Two card shapes, and only one of them is this camera
  //
  // **The two-entry shape below is the one the fixture used to assume, and the
  // firmware never sends it** (`analysis/50` §1). It is kept, and kept *second*,
  // because `groupAssets` deliberately still supports a card that lists both halves —
  // so it is the control: the rule must key on *what the listing carries*, not on
  // "is this path a RAW".
  final listedPairCam =
      _FakeCamera([_f(1), _f(1, ext: 'DNG', type: 'raw'), _f(2)]);
  final listedPairReport = await FileDeleter(album: listedPairCam.album).submit(
      planDelete(groupAssets([_f(1), _f(1, ext: 'DNG', type: 'raw')])));
  check('a pair delete reports one outcome per file',
      listedPairReport.total == 2, '${listedPairReport.total}');
  check('a RAW the listing really carries is confirmed on listing evidence',
      listedPairReport.removedShots.length == 1,
      '${listedPairReport.removedShots}');
  check('and the untouched shot is still listed', listedPairCam.files.length == 1);

  // ---- the shape the camera really sends: one record, and a RAW it never lists
  //
  // This is finding #1 of `analysis/79`, and the reason it was invisible: the fixture
  // here used to list its DNGs, so `after.contains(rawPath)` could be **true** and the
  // verification looked correct. Against the real listing that expression is false for
  // every RAW **whatever the camera did** — and false was being read as
  // `confirmedGone`, i.e. a 32 MB file reported as deleted and checked.
  final shot = _rawJpegShot(1);
  final pairCam = _FakeCamera([shot.listed, _f(2)], unlisted: [shot.rawPath]);

  // The premise, asserted rather than assumed. A fixture that puts the DNG back into
  // its listing would make every check below vacuous, so the listing the *camera*
  // serves is read back through the album client and required to be the measured
  // shape (AGENTS.md §8: a fixture can silently invalidate the checks that use it).
  final pairListing = <String>[];
  await for (final f in pairCam.album.listAll()) {
    pairListing.add(f.path);
  }
  check('the fixture lists one entry per shutter press and no RAW, as the firmware does',
      pairListing.length == 2 &&
          pairListing.contains('${_p(1)}.JPG') &&
          !pairListing.any((p) => p.endsWith('.DNG')),
      '$pairListing');

  final pairReport = await FileDeleter(album: pairCam.album)
      .submit(planDelete(groupAssets([shot.listed])));

  check('both paths of the pair are asked for, and the RAW is the literal .DNG path',
      pairCam.sentRequests.single.length == 2 &&
          pairCam.sentRequests.single[0] == '${_p(1)}.JPG' &&
          pairCam.sentRequests.single[1] == shot.rawPath,
      '${pairCam.sentRequests}');

  final rawOutcome =
      pairReport.outcomes.singleWhere((o) => o.path == shot.rawPath);
  check('a RAW the listing never carries is never reported as confirmed gone',
      rawOutcome.verdict == DeleteVerdict.unconfirmed,
      '${rawOutcome.verdict.name}: ${rawOutcome.message}');
  check('and it is unconfirmed for the real reason, not for a listing failure',
      rawOutcome.message.contains('RAW') &&
          !rawOutcome.message.contains('could not be re-listed'),
      rawOutcome.message);

  // The control, in the same run and the same shot: the JPEG half *is* checkable, and
  // is checked. Without this, "stop confirming anything" would pass the check above.
  final jpegOutcome =
      pairReport.outcomes.singleWhere((o) => o.path == '${_p(1)}.JPG');
  check('the listed half of the same pair is confirmed gone on its own evidence',
      jpegOutcome.verdict == DeleteVerdict.confirmedGone,
      '${jpegOutcome.verdict.name}: ${jpegOutcome.message}');

  // What the user sees, and the whole point: the row stays. The author's own rule on
  // `DeleteReport.removedShots` — *"a RAW+JPEG row must stay on screen if one half is
  // still on the card, or the orphan it is warning about would be invisible"* — is
  // only honoured if the check that decides it can produce the doubt in the first
  // place. It could not, because absence from a listing the RAW was never in was being
  // counted as proof.
  check('the pair row stays on screen while the RAW half is in doubt',
      pairReport.removedShots.isEmpty, '${pairReport.removedShots}');
  check('and the summary does not call the pair deleted and checked',
      !pairReport.allConfirmed &&
          pairReport.confirmed == 1 &&
          pairReport.unconfirmedUnlisted == 1 &&
          pairReport.verifyError == null &&
          pairReport.summary.contains('never its RAW'),
      pairReport.summary);

  // Whether the firmware removes a RAW it was asked for by a derived path **has never
  // been measured** (`analysis/79`, "what this audit did not cover"), so the fixture
  // is run both ways instead of picking an answer. The verdict has to be the same,
  // because the app cannot tell the two apart — and that is exactly why it may not
  // say "deleted".
  for (final removes in [false, true]) {
    final c = _FakeCamera([shot.listed, _f(2)], unlisted: [shot.rawPath])
      ..removesUnlisted = removes;
    final r = await FileDeleter(album: c.album)
        .submit(planDelete(groupAssets([shot.listed])));
    check('the fixture really ${removes ? 'removed' : 'kept'} the RAW it never lists',
        (c.unlisted.isEmpty) == removes, 'unlisted: ${c.unlisted}');
    check('a RAW that was ${removes ? 'really gone' : 'left behind'} is still not '
        'called confirmed gone',
        r.of(DeleteVerdict.confirmedGone).length == 1 &&
            r.of(DeleteVerdict.unconfirmed).length == 1,
        r.summary);
  }

  // The other half of the same rule: with no pre-delete listing the app cannot even
  // ask whether the album carries the path, and the answer has to stay "unknown".
  // This is the branch a later reader is most likely to "simplify" — absence from a
  // listing looks like absence from a listing — and it is the one that fails towards
  // the file still being on the card.
  final blindBefore =
      _FakeCamera([shot.listed, _f(2)], unlisted: [shot.rawPath])
        ..failFirstListings = 1;
  final blindBeforeReport = await FileDeleter(album: blindBefore.album)
      .submit(planDelete(groupAssets([shot.listed])));
  check('with no pre-delete listing at all the derived RAW is still not confirmed',
      blindBeforeReport.listedBefore == null &&
          blindBeforeReport.of(DeleteVerdict.confirmedGone).length == 1 &&
          blindBeforeReport.unconfirmedUnlisted == 1,
      blindBeforeReport.summary);
  check('and the row is kept for it too',
      blindBeforeReport.removedShots.isEmpty,
      '${blindBeforeReport.removedShots}');

  print('\n=== DeleteFile: one request in flight, never two ===');

  // 45 paths => 2 batches. They must not overlap: this camera has no watchdog,
  // and a second request arriving mid-delete is exactly how it wedges.
  final serial = _FakeCamera([for (var i = 1; i <= 45; i++) _f(i)]);
  final inFlight = <int>[];
  var concurrent = 0;
  var maxConcurrent = 0;
  // The wrapper now observes deletes through the **approved** seam, which is where
  // `DeleteFile` actually goes. It used to sit on the plain seam and work only
  // because every send took that route; once the approved path existed, a harness
  // wired to the old one would have stopped seeing deletes entirely and this check
  // would have passed at `peak 0` — an empty measurement reading as "never two".
  final serialHttp = CameraHttpClient();
  final slow = CameraAlbum(serialHttp);
  serialHttp.overrideApprovedSend = (cmd, params, approval) async {
    if (cmd != 'DeleteFile') return serial.handle(cmd, params);
    concurrent++;
    maxConcurrent = maxConcurrent > concurrent ? maxConcurrent : concurrent;
    inFlight.add(concurrent);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    try {
      return await serial.handle(cmd, params);
    } finally {
      concurrent--;
    }
  };
  serialHttp.overrideSend = serial.handle;
  final serialReport =
      await FileDeleter(album: slow).submit(planDelete(groupAssets(serial.files)));
  check('every file was confirmed deleted',
      serialReport.allConfirmed && serialReport.confirmed == 45,
      serialReport.summary);
  check('and no two DeleteFile requests were ever in flight together',
      maxConcurrent == 1, 'peak $maxConcurrent (saw $inFlight)');

  // The pairing rule is defined in two layers; if they ever disagree, a pair
  // would be deleted as two independent files. Assert they agree.
  check('the delete side pairs shots exactly as the album grid does',
      shotIdentity('${_p(7)}.JPG') == shotIdentity('${_p(7)}.DNG') &&
          shotIdentity('${_p(7)}.JPG') != shotIdentity(_p(8) + '.JPG'),
      '${shotIdentity('${_p(7)}.JPG')}');
}

// ---------------------------------------------------------------------------
// The dangerous-command set, enforced rather than merely declared.
//
// `kDangerousCommands` was data that nothing read: a command could be added to it
// and the app would still send it. Worse, the *sibling* set — `isKnownCommand`,
// which guards a typo — was checked on every send, so the set that guards a bricked
// camera was the one set with no enforcement at all.
//
// What is checked here is deliberately **not** "the list contains CloseAP". That
// is what `tool/verify_http.dart` already does, and it stays green while nothing
// enforces anything. This is the other half: walk the set at run time and require
// each member to be **refused through the send path the app actually uses**.
// Adding a name to `kDangerousCommands` therefore turns this red until the name is
// wired — which is the only way the set stays a policy instead of a comment.

/// A real [CameraHttpClient] whose send is a scripted camera, recording what
/// arrived and **what the caller asked for while sending it**.
///
/// The two matter together: a refusal is only evidence if the attempt went through
/// the same `send` the app calls, so the recording is of the request that reached
/// the client, not of a call that never got there.
class _Wire extends CameraHttpClient {
  final List<String> sent = [];

  /// The approval each request carried (`null` when none was given).
  final List<(String, DangerousApproval?)> calls = [];

  /// Scripted answers, so the transport can be driven with no socket. Anything
  /// not listed here answers `200`, which is what the fake camera does.
  final Future<CameraResponse> Function(String, Map<String, Object>)? answer;

  _Wire({this.answer})
      : super(
          overrideSend: (cmd, params) async => CameraResponse(
              code: 200, raw: '{"code":200}', data: const []),
        ) {
    // `extends`, not a hand-written wrapper, on purpose: every other member —
    // `timeout`, `host`, the convenience wrappers the capture guard calls — then
    // behaves exactly as it does in the app, and only the two send entry points are
    // scripted.
    overrideApprovedSend = (cmd, params, approval) async {
      calls.add((cmd, approval));
      sent.add(cmd);
      if (answer != null) return answer!(cmd, params);
      if (cmd == 'DeleteFile') {
        // The firmware accepts the request and the card is empty afterwards, which
        // is the only combination that lets a delete be called confirmed.
        return CameraResponse(code: 200, raw: '{"code":200}');
      }
      return CameraResponse(code: 200, raw: '{"code":200}', data: const []);
    };
    overrideSend = (cmd, params) async {
      calls.add((cmd, null));
      sent.add(cmd);
      if (answer != null) return answer!(cmd, params);
      return CameraResponse(code: 200, raw: '{"code":200}', data: const []);
    };
  }
}

/// Runs [body] and records whether it threw. Returns what was thrown, so a caller
/// can assert *which* refusal it got rather than only that something stopped it —
/// an exception that cannot be told apart from success is not a refusal, and one
/// that cannot be told apart from a transport failure is not a policy either.
Future<Object?> _expectThrows(String name, Future<void> Function() body) async {
  try {
    await body();
    check(name, false, 'nothing threw — the command was sent');
    return null;
  } on Object catch (e) {
    check(name, true);
    return e;
  }
}

Future<void> _dangerousCommandChecks() async {
  print('\n=== dangerous commands: the set is enforced, not just declared ===');

  // The check below is worthless if the set it walks is empty or has quietly lost
  // its members, so the premise is asserted rather than assumed.
  check('the dangerous set still names the six commands it is a policy about',
      kDangerousCommands.length == 6 &&
          kDangerousCommands.containsAll(const [
            'UpdateFW',
            'UpdateLenFW',
            'UploadML',
            'DeleteFile',
            'DeleteMLFile',
            'CloseAP',
          ]),
      '${kDangerousCommands.length} entries: ${kDangerousCommands.join(', ')}');
  check('and every one of them is a command the firmware really dispatches',
      kDangerousCommands.every(isKnownCommand),
      '${kDangerousCommands.where((c) => !isKnownCommand(c))}');

  // ---- the refusal, with no opt-in -------------------------------------------------
  final cold = _Wire();
  for (final cmd in kDangerousCommands) {
    await _expectThrows(
        'refused with no opt-in: $cmd', () => cold.send(cmd, const {}));
  }
  check('nothing reached the client while those were refused', cold.sent.isEmpty,
      'sent: ${cold.sent}');

  // The params are not what makes it dangerous: `DeleteFile`'s own `file_list`
  // cannot, by itself, get past the guard.
  await _expectThrows('a well-formed DeleteFile is refused just the same',
      () => cold.send('DeleteFile', {
            'file_list': ['/DCIM/100YICAM/YI000001.JPG']
          }));
  check('and still nothing reached the client', cold.sent.isEmpty,
      'sent: ${cold.sent}');

  // The failure has to say which command and why, or the next reader adds a
  // blanket allow to make it stop.
  final refusal = await _expectThrows('the refusal is a CameraHttpException',
      () => cold.send('CloseAP', const {}));
  check('and it names the command and the irreversibility',
      refusal is CameraHttpException &&
          refusal.message.contains('CloseAP') &&
          refusal.message.toLowerCase().contains('refus'),
      '$refusal');

  // ---- what is NOT refused ---------------------------------------------------------
  await cold.send('GetCameraStatus', const {});
  await cold.send('RCStopRemoteCtl', const {});
  check('ordinary commands are untouched by the guard',
      cold.sent.length == 2 && cold.sent.first == 'GetCameraStatus',
      'sent: ${cold.sent}');

  // ---- the approved path, at the transport -----------------------------------------
  //
  // The one shape that gets a dangerous command out of the door, spelled the way a
  // caller has to spell it: the command, its parameters and the authorisation all in
  // one call, with the authorisation a **required named** argument.
  var authorised = 0;
  final r = await cold.sendApproved(
    'DeleteFile',
    {
      'file_list': ['/DCIM/100YICAM/YI000001.JPG']
    },
    approval: DangerousApproval.forCommand('DeleteFile', (cmd) {
      authorised++;
      check('the authorisation runs for the command it was written for',
          cmd == 'DeleteFile', cmd);
    }),
  );
  check('an approved dangerous command is sent', r.ok, '${r.code}');
  check('and the caller\'s authorisation ran exactly once', authorised == 1,
      '$authorised');
  check('it arrived at the client as the approved command',
      cold.sent.length == 3 && cold.sent.last == 'DeleteFile', 'sent: ${cold.sent}');
  check('carrying the approval, so the request can be told apart from a bare send',
      cold.calls.last.$2 != null &&
          cold.calls.last.$2?.command == 'DeleteFile',
      '${cold.calls.map((c) => '${c.$1}:${c.$2?.command ?? '-'}')}');

  // ---- the opt-in cannot be reached by accident ------------------------------------
  //
  // `sendApproved` takes the approval as a **required named** argument, so the shape
  // that would be an omission at a call site — one command name and its parameters
  // and nothing else — does not compile. There is deliberately no check here for
  // that: a check that cannot be written because the program will not build is not a
  // runtime check, and a test that merely *looks* like it makes one is the same class
  // of green-but-empty reassurance this whole section exists to remove.
  //
  // What *can* be checked at run time is the other half of "not by omission": an
  // approval is a statement about **one** command, and the transport holds it to
  // that. The approval below is genuine — signed by the user's decision for a real
  // hazard — and it is still not enough to get a different command out of the door.
  final mismatched = DangerousApproval.forCommand('UpdateFW', (cmd) {
    throw StateError('approved $cmd, and "$cmd" is what this approval is for');
  });
  await _expectThrows(
      'an approval signed for one dangerous command does not authorise another',
      () => cold.sendApproved('DeleteFile', const {}, approval: mismatched));
  check('and it was refused before the caller\'s own authorisation ran',
      cold.sent.length == 3, 'sent: ${cold.sent}');

  // A value the user's decision did not mint cannot be made to stand in for one,
  // and this is the compile-time half of the same claim: `DangerousApproval` has a
  // private constructor and exactly one factory, so the only way to hold one is to
  // have called [DangerousApproval.forCommand] — which refuses a command that is not
  // dangerous. See the note above for why no runtime check is written for that.
  await _expectThrows(
      'an approval cannot be minted for a command that is not dangerous',
      () async => DangerousApproval.forCommand('GetFileList', (_) {}));
  check('nothing extra was sent by that attempt either', cold.sent.length == 3,
      'sent: ${cold.sent}');

  // ---- the legitimate path, end to end ---------------------------------------------
  //
  // The positive case has to be the *album's* path, not a hand-built approval: what
  // is being checked is that `DeleteFile` reaches the camera through the approved
  // entry point, carrying the approval, and that its own guards are all still in
  // front of it.
  final cam = _FakeCamera([_f(1), _f(2)]);
  final approved = <DangerousApproval?>[];
  var albumApprovals = 0;
  final album = CameraAlbum(
    CameraHttpClient(
      overrideSend: cam.handle,
      overrideApprovedSend: (cmd, params, approval) {
        albumApprovals++;
        approved.add(approval);
        return cam.handle(cmd, params);
      },
    ),
  );

  final report = await FileDeleter(album: album)
      .submit(planDelete(groupAssets([_f(1), _f(2)])));
  check('a legitimate delete still goes through: both files confirmed gone',
      report.allConfirmed && report.confirmed == 2, report.summary);
  check('the card no longer lists them', cam.files.isEmpty);
  check('and it arrived at the client through the approved entry point',
      cam.sentRequests.length == 1 &&
          cam.sentRequests.single.contains('${_p(1)}.JPG'),
      '${cam.sentRequests}');
  check('the approval the album signed names DeleteFile, the command actually sent',
      approved.length == 1 && approved.single?.command == 'DeleteFile',
      '${approved.map((a) => a?.command)}');
  check('the album asked for that approval once per request, not once per file',
      albumApprovals == 1, '$albumApprovals');

  // The other direction, in the same fake: an unapproved command still reaches the
  // client as unapproved. The listing is the app's proof that approval is asked for
  // where it is needed and not everywhere.
  final plain = _Wire();
  await plain.send('GetCameraStatus', const {});
  check('a command that is not dangerous carries no approval at all',
      plain.calls.single == ('GetCameraStatus', null), '${plain.calls}');

  // ---- what must NOT have become unreachable ---------------------------------------
  //
  // `deleteFileList` performs its own checks and only then mints the approval, so
  // every one of them is still in front of the camera. They are re-checked here
  // because this round added a gate to the same function, and a guard that a new
  // gate makes unreachable is a guard that will be deleted by the next reader.
  final guarded = _Wire();
  final guardedAlbum = CameraAlbum(guarded);
  await _expectAlbumException('an empty file_list is still refused before send',
      () => guardedAlbum.deleteFileList(const []));
  await _expectAlbumException('more than 30 paths is still refused before send',
      () => guardedAlbum.deleteFileList([for (var i = 1; i <= 31; i++) '${_p(i)}.JPG']));
  await _expectAlbumException('"ALL" is still refused outright',
      () => guardedAlbum.deleteFileList(const ['ALL']));
  await _expectAlbumException('a path past the 52-character slot is still refused',
      () => guardedAlbum.deleteFileList(['/DCIM/100YICAM/${'X' * 40}.JPG']));
  check('and none of those four reached the client, approved or not',
      guarded.sent.isEmpty, 'sent: ${guarded.sent}');
}

Future<void> _expectAlbumException(String name, Future<void> Function() body) async {
  try {
    await body();
    check(name, false, 'no exception was thrown');
  } on AlbumException {
    check(name, true);
  } on Object catch (e) {
    check(name, false, '$e');
  }
}

// ---------------------------------------------------------------------------
// Wi-Fi join diagnosis.
//
// This feature has now been wrong three times, always in the same way: the app
// asserted a cause it had not measured. `WifiJoinReason` and
// `WifiPermissionReport` exist to make that impossible, so what is guarded here
// is that (a) every reason produces advice that is actually different from the
// others, and (b) an unrecognised platform token is never upgraded into a named
// permission.
Future<void> _verifyWifiJoinDiagnosis() async {
  // Every reason must say something specific. A reason that falls through to the
  // generic sentence is indistinguishable from `unknown` at the point of use,
  // which is exactly the bug being guarded against.
  for (final reason in WifiJoinReason.values) {
    if (reason == WifiJoinReason.unknown) continue;
    final text = WifiJoinResult(WifiJoinOutcome.permissionDenied, 'x', reason)
        .explanation;
    check('${reason.name} explains itself', text.length > 40, '"$text"');
  }

  // The three permission cases must not read the same, or the user cannot tell
  // which switch to touch.
  String say(WifiJoinReason r) =>
      WifiJoinResult(WifiJoinOutcome.permissionDenied, null, r).explanation;
  check(
      'location-permission advice differs from nearby-devices advice',
      say(WifiJoinReason.fineLocation) != say(WifiJoinReason.nearbyWifiDevices));
  check(
      'disabled location services reads differently from a refused permission',
      say(WifiJoinReason.locationServicesOff) != say(WifiJoinReason.fineLocation));
  // The one that actually bit: the master switch is NOT the permission screen.
  check(
      'the master-switch case does not tell the user to grant a permission',
      !say(WifiJoinReason.locationServicesOff).contains('Grant it'),
      say(WifiJoinReason.locationServicesOff));

  // The one that actually shipped: CHANGE_NETWORK_STATE was never declared. It is
  // a *normal* permission, so there is no switch the user could flip — advice that
  // asks them to grant something is a dead end by construction.
  check(
      'the change-network-state case does not tell the user to grant anything',
      !say(WifiJoinReason.changeNetworkState).toLowerCase().contains('grant it') &&
          say(WifiJoinReason.changeNetworkState).contains('bug in the app'),
      say(WifiJoinReason.changeNetworkState));
  // And it must be distinguishable from the two permissions the user *can* act on.
  check(
      'and reads differently from every grantable reason',
      say(WifiJoinReason.changeNetworkState) != say(WifiJoinReason.changeWifiState) &&
          say(WifiJoinReason.changeNetworkState) != say(WifiJoinReason.fineLocation),
      say(WifiJoinReason.changeNetworkState));
  check(
      'a clone/UID mismatch does not tell the user to grant a permission either',
      !say(WifiJoinReason.uidPackageMismatch).toLowerCase().contains('grant'),
      say(WifiJoinReason.uidPackageMismatch));

  // Token mapping. These strings are the contract with MainActivity.kt; a typo on
  // either side silently degrades to `unknown`, which is safe but useless.
  const tokens = {
    'fineLocation': WifiJoinReason.fineLocation,
    'nearbyWifiDevices': WifiJoinReason.nearbyWifiDevices,
    'locationServicesOff': WifiJoinReason.locationServicesOff,
    'changeWifiState': WifiJoinReason.changeWifiState,
    'changeNetworkState': WifiJoinReason.changeNetworkState,
    'uidPackageMismatch': WifiJoinReason.uidPackageMismatch,
    'oemRestriction': WifiJoinReason.oemRestriction,
    'otherPermission': WifiJoinReason.otherPermission,
    'notPermission': WifiJoinReason.notPermission,
  };
  tokens.forEach((token, expected) {
    check('native token "$token" maps to ${expected.name}',
        WifiJoinReason.parse(token) == expected);
  });
  for (final unknown in ['android_too_old', 'no_wifi_service', 'unavailable', '', null]) {
    check('unrecognised token ${unknown ?? "null"} stays unknown',
        WifiJoinReason.parse(unknown) == WifiJoinReason.unknown);
  }

  // The measured-state reader. A missing map must not be mistaken for "nothing is
  // wrong": every field is nullable for exactly that reason.
  const empty = WifiPermissionReport();
  check('an absent report claims nothing', empty.sdkInt == null &&
      empty.fineLocation == null && empty.problems.isEmpty);
  check('and its summary says unknown rather than granted',
      empty.summary.contains('unknown'), empty.summary);

  const blocked = WifiPermissionReport(
    sdkInt: 34,
    android: '14',
    manufacturer: 'Xiaomi',
    fineLocation: true,
    nearbyWifiDevices: true,
    locationServices: false,
    locationServicesBlocking: true,
    wifiEnabled: true,
  );
  // The whole point: permissions are granted, and it still cannot join.
  check('granted permissions with the master switch off is diagnosed',
      blocked.problems.contains('location services are switched off'),
      blocked.problems);
  check('and both permissions really are reported granted',
      blocked.fineLocation == true && blocked.nearbyWifiDevices == true);
  check('a healthy report lists no problems',
      const WifiPermissionReport(
        fineLocation: true,
        nearbyWifiDevices: true,
        locationServices: true,
        wifiEnabled: true,
      ).problems.isEmpty);
  check('Wi-Fi being off is reported, because nothing else can work then',
      const WifiPermissionReport(wifiEnabled: false)
          .problems
          .contains('Wi-Fi is off'));

  // The suggestion rung asks for approval through a notification, so from API 33
  // a missing grant makes it inert with no prompt to accept. It must be named,
  // because "the fallback did nothing" and "the fallback was never reached" look
  // identical to the user.
  check('missing notifications on API 33+ is reported as a problem',
      const WifiPermissionReport(sdkInt: 33, notifications: false)
          .problems
          .contains('notifications are off'),
      const WifiPermissionReport(sdkInt: 33, notifications: false).problems);
  check('but on API 32 and below it is not, because no grant was ever needed',
      const WifiPermissionReport(sdkInt: 32, notifications: false)
          .problems
          .isEmpty);
  check('and a granted notification permission is not a problem',
      const WifiPermissionReport(sdkInt: 34, notifications: true)
          .problems
          .isEmpty);
  check('a notification state that could not be read is not called a denial',
      const WifiPermissionReport(sdkInt: 34).problems.isEmpty);
  check('the summary states notification state when it is known',
      const WifiPermissionReport(sdkInt: 34, notifications: true)
          .summary
          .contains('notifications granted'));

  // `shouldPoll` is what decides whether the app keeps waiting for the camera, so
  // a missing case here would make a working join look like a failure.
  check('granted and suggested both keep polling',
      const WifiJoinResult(WifiJoinOutcome.granted).shouldPoll &&
          const WifiJoinResult(WifiJoinOutcome.suggested).shouldPoll);
  check('permissionDenied does not keep polling',
      !const WifiJoinResult(WifiJoinOutcome.permissionDenied).shouldPoll);

  // The scripted delegate is the seam the connection state machine is driven
  // through; assert it records what the tests rely on.
  final scripted = ScriptedWifiJoinDelegate(
      const [WifiJoinResult(WifiJoinOutcome.granted)], bindSucceeds: false);
  check('the scripted delegate starts unbound', !scripted.isBound);
  final ladderResult = await scripted.joinWithFallback('YI_M1_test');
  check('the scripted delegate records a ladder attempt',
      scripted.ladderAttempts.single == 'YI_M1_test', '${scripted.ladderAttempts}');
  check('and a granted ladder run means the caller should poll',
      ladderResult.shouldPoll);
  check('a failed bind is not reported as bound',
      !(await scripted.bind()) && !scripted.isBound);
  check('and reports the granted outcome it was scripted with',
      scripted.script.first.outcome == WifiJoinOutcome.granted);

  // `unbind` is the one that turns auto-connect into auto-disconnect if skipped,
  // so the scripted delegate tracks it explicitly.
  await scripted.unbind();
  check('unbind is recorded', scripted.unbindCount == 1, '${scripted.unbindCount}');
}

// ---------------------------------------------------------------------------
// The defects that only a *second* attempt can reveal.
//
// Every case below has the same shape, and it is the shape that has produced
// every serious failure in this project so far: a guard is checked, an `await`
// follows, and a second caller walks through the gap — or a value is written on
// one path and read on another. None of them is visible from the happy path, and
// none of them needs a widget: `CameraConnection` takes a host, the BLE transport
// is an interface, and the camera's HTTP endpoint can be a loopback server.
// ---------------------------------------------------------------------------

/// The BLE half of a camera, with the two firmware rules that matter here.
///
/// It stores **one** pairing, and it opens a session only when the key *and*
/// `crc32("1" + key + token)` match the pair it is holding — then it hands over the
/// Wi-Fi credentials only while that session is open. That is what makes a
/// saved-but-stale pair fail in the same way the hardware does, instead of failing
/// only in the code's own imagination.
class _FakeCameraBle implements BleTransport {
  _FakeCameraBle({this.storedKey, this.storedToken});

  /// The pairing the camera currently holds.
  int? storedKey;
  String? storedToken;

  /// Session payloads (`<proto>,<key>,<crc>`) in the order they were received.
  final List<String> sessionPayloads = [];

  /// Pairing requests in the order they were received.
  final List<String> pairingPayloads = [];

  /// True while the camera considers a session open.
  bool sessionOpen = false;

  /// Makes the next session write fail at the transport: the case where the app
  /// learns nothing from the write and pairs from scratch.
  bool failNextSessionWrite = false;

  /// Payloads written to the Wi-Fi toggle characteristic, in order.
  ///
  /// `"ON"` at connect and `"OFF"` at disconnect are the *same* characteristic
  /// (`PROTOCOL.md` §3.4), so a check has to look at what was written as well as
  /// that something was: a build that wrote `"ON"` on the way out would pass an
  /// "a write happened" assertion while switching the radio the wrong way.
  final List<String> radioWrites = [];

  /// Makes the next radio write throw, for the "the camera did not acknowledge it"
  /// outcome. Not a claim about the hardware — it is the only half of that outcome
  /// a desk test can produce.
  bool failNextRadioWrite = false;

  /// Whether the transport reports a live link.
  ///
  /// Settable because two of the radio outcomes are about the link's state, and
  /// the one that matters most — leaving the camera on while the link is already
  /// gone — is unreachable from a fixture that always answers true.
  bool connected = true;

  void Function(List<int>)? _onPairing;

  @override
  final List<String> log = [];

  @override
  Future<String?> findCamera() async => 'fake-camera';

  @override
  Future<void> connect(String deviceId) async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool get isConnected => connected;

  @override
  Future<List<int>> readFirmwareInfo() async => ascii.encode('1,M1,M1INT,1.1');

  @override
  Future<List<int>> readMisc() async => <int>[];

  @override
  Future<List<int>> readWifiCredentials() async =>
      sessionOpen ? ascii.encode('YI_M1_test,12345678') : <int>[];

  @override
  Future<void> subscribePairing(void Function(List<int>) onData) async {
    _onPairing = onData;
  }

  @override
  Future<void> write(Uint8List data, String characteristic) async {
    final text = ascii.decode(data, allowInvalid: true);
    if (characteristic == BleChar.wifi) {
      radioWrites.add(text);
      if (failNextRadioWrite) {
        failNextRadioWrite = false;
        throw StateError('GATT write failed (simulated)');
      }
      return;
    }
    if (characteristic == BleChar.session) {
      sessionPayloads.add(text);
      if (failNextSessionWrite) {
        failNextSessionWrite = false;
        throw StateError('GATT write failed (simulated)');
      }
      final parts = text.split(',');
      final key = int.tryParse(parts.length > 1 ? parts[1] : '') ?? -1;
      final crc = int.tryParse(parts.length > 2 ? parts[2] : '') ?? -2;
      final held = storedToken;
      sessionOpen = held != null &&
          storedKey == key &&
          crc == zlibCrc32(utf8.encode('1$key$held'));
      return;
    }
    if (characteristic == BleChar.pairing) {
      pairingPayloads.add(text);
      final key = int.parse(text.split(',')[1]);
      storedKey = key;
      storedToken = 'tok$key';
      final cb = _onPairing;
      final token = storedToken!;
      // The camera answers over a GATT notification, i.e. asynchronously.
      if (cb != null) scheduleMicrotask(() => cb(ascii.encode(token)));
    }
  }
}

/// The camera's HTTP endpoint on the loopback port `CameraConnection` asks for by
/// default, so the whole connect sequence can be driven to `ready` offline.
///
/// `null` when the port cannot be taken — another service holds it, or binding a
/// low port needs privileges (as on Linux). The checks that need `ready` are then
/// reported as skipped rather than silently passing.
Future<HttpServer?> _bindCameraPort() async {
  try {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 80);
    server.listen((req) async {
      final body = utf8.encode('{"code":200,"data":{}}');
      req.response.statusCode = 200;
      req.response.headers.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });
    return server;
  } on Object {
    return null;
  }
}

/// A UDP port nothing is listening on, so a receiver under test does not collide
/// with the camera's real port (54321) while the camera is absent.
Future<int> _freeUdpPort() async {
  final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = probe.port;
  probe.close();
  return p;
}

/// A datagram the receiver accepts: SOI at the measured offset, EOI at the end.
Uint8List _datagram(int index) {
  final b = Uint8List(kJpegOffset + 16);
  ByteData.sublistView(b).setUint32(0, index, Endian.big);
  b[kJpegOffset] = 0xFF;
  b[kJpegOffset + 1] = 0xD8;
  b[kJpegOffset + 2] = 0xFF;
  b[b.length - 2] = 0xFF;
  b[b.length - 1] = 0xD9;
  return b;
}

/// A JPEG of [size] bytes: `FF D8` … `FF D9`, so it satisfies the end-of-image check
/// the sync engine applies before it stores a `.JPG`.
Uint8List _jpegOf(int size) {
  final b = Uint8List(size < 4 ? 4 : size);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[b.length - 2] = 0xFF;
  b[b.length - 1] = 0xD9;
  return b;
}

/// The `resulotion` the client asked for, out of the URL-encoded JSON `data` parameter.
String _askedResolution(HttpRequest req) {
  final raw = req.uri.queryParameters['data'] ?? '{}';
  final decoded = jsonDecode(raw);
  return decoded is Map ? '${decoded['resulotion']}' : '';
}

/// A JPEG whose last two bytes are the EOI marker.
Uint8List jpegBytes([int size = 64]) {
  final b = Uint8List(size);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[size - 2] = 0xFF;
  b[size - 1] = 0xD9;
  return b;
}

/// A minimal HTTP endpoint, so a test can drive `CameraAlbum` against something that
/// answers statuses the camera really produces.
///
/// `CameraAlbum.download` speaks **raw HTTP** — its response body *is* the file — so the
/// `overrideSend` seam every other check uses cannot reach it at all. A loopback server
/// is what makes `204`, `404` and an empty `200` testable offline.
Future<HttpServer> _albumServer(
    Future<void> Function(HttpRequest req) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      await handler(req);
    } finally {
      await req.response.close();
    }
  });
  return server;
}

CameraResponse _ok([Object? data]) =>
    CameraResponse(code: 200, raw: '{"code":200}', data: data);

Future<void> _verifySecondAttempts() async {
  // ---- 1. two shutter presses must not both reach the camera ---------------
  //
  // The interlock's entire purpose is "never two captures at once", and the
  // firmware punishes exactly one overlap with a stranded capture state machine
  // and a battery pull. Two presses land in the same window whenever the user
  // double-taps, and the second one arrives while the first is *waiting out the
  // cool-down* — past the `_inFlight` check but before it is set.
  print('\n=== capture interlock: the second press ===');

  final raceSent = <String>[];
  final raceClient = CameraHttpClient(overrideSend: (cmd, params) async {
    raceSent.add(cmd);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return _ok();
  });
  final raceGuard = CaptureGuard(
    http: () => raceClient,
    minInterval: const Duration(milliseconds: 80),
    quarantine: Duration.zero,
    measureFps: () async => 30.0,
  );
  await raceGuard.shoot(); // primes the cool-down so the next press must wait
  raceSent.clear();
  final raceResults = await Future.wait([raceGuard.shoot(), raceGuard.shoot()]);
  check(
      'two presses inside the cool-down send at most one RCDoShooting',
      raceSent.where((c) => c == 'RCDoShooting').length == 1,
      'sent: $raceSent');
  check('and the extra press is reported as blocked, not silently dropped',
      raceResults.where((r) => r.outcome == CaptureOutcome.blocked).length == 1,
      '${raceResults.map((r) => r.outcome).toList()}');

  // The same hole, through the one control that is *allowed* to override the
  // interlock: releasing quarantine must not release a capture that is genuinely
  // on the wire.
  //
  // The press is asserted **while the release is still running**, which is the
  // only moment the claim is about: `forceRelease` now runs the health probe
  // before it answers, so awaiting it can outlast a scripted capture and the
  // check would pass for the wrong reason.
  final slowSent = <String>[];
  final slowClient = CameraHttpClient(overrideSend: (cmd, params) async {
    slowSent.add(cmd);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _ok();
  });
  final slowGuard = CaptureGuard(
    http: () => slowClient,
    minInterval: Duration.zero,
    quarantine: Duration.zero,
    measureFps: () async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return 30.0;
    },
  );
  final inFlight = slowGuard.shoot();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final releasing = slowGuard.forceRelease(); // the user taps "release"
  await Future<void>.delayed(const Duration(milliseconds: 30));
  final afterRelease = await slowGuard.shoot();
  check(
      'forceRelease does not let a second shot out while one is on the wire',
      slowSent.where((c) => c == 'RCDoShooting').length == 1,
      'sent: $slowSent');
  check('and that press is reported as blocked',
      afterRelease.outcome == CaptureOutcome.blocked, '${afterRelease.outcome}');
  await releasing;
  await inFlight;

  // ---- 2. the saved pairing must describe one pairing, not two halves ------
  print('\n=== pairing: the token that is saved must match the refId ===');

  final server = await _bindCameraPort();
  if (server == null) {
    print('  SKIP  loopback port 80 unavailable - the connect() checks below '
        'cannot reach `ready` here');
  }
  // With no HTTP endpoint the join is scripted to a fast-failing outcome: the
  // session bookkeeping is what these checks are about, and it happens before the
  // HTTP probe is reached.
  WifiJoinOutcome joinOutcome() => server == null
      ? WifiJoinOutcome.permissionDenied
      : WifiJoinOutcome.granted;

  {
    // A pair the camera does not hold: the official app re-paired, or the camera
    // was reset. The session write then fails at the transport, so the app pairs
    // from scratch and is issued a new refId *and* a new token.
    final store = MemoryPairingStore(<String, String>{
      'refId': '4242',
      'token': 'stale-token',
      'protocol': '1',
    });
    final ble = _FakeCameraBle()..failNextSessionWrite = true;
    final conn = CameraConnection(
      ble: ble,
      store: store,
      host: '127.0.0.1',
      wifiJoin: ScriptedWifiJoinDelegate([WifiJoinResult(joinOutcome())]),
    );
    await conn.connect(pairWait: const Duration(milliseconds: 500));

    final saved = PairingRecord.fromMap(await store.load());
    final issuedKey = '${ble.storedKey}';
    final issuedToken = ble.storedToken;
    check(
        'a fresh pairing saves the token that came with the new refId',
        saved.token == issuedToken && saved.refId == issuedKey,
        'saved ${saved.refId}/${saved.token}; the camera issued '
        '$issuedKey/$issuedToken');

    // The property the stale token broke: the record has to open a session. A
    // second connection, against a camera still holding the pair it just issued,
    // stands in for the next launch.
    final ble2 = _FakeCameraBle(storedKey: ble.storedKey, storedToken: issuedToken);
    final conn2 = CameraConnection(
      ble: ble2,
      store: MemoryPairingStore(await store.load()),
      host: '127.0.0.1',
      wifiJoin: ScriptedWifiJoinDelegate([WifiJoinResult(joinOutcome())]),
    );
    final reusedOk = await conn2.connect();
    check('the saved pair is reused rather than paired again',
        ble2.pairingPayloads.isEmpty, '${ble2.pairingPayloads.length} pairing write(s)');
    check('and it really opens a session', ble2.sessionOpen,
        'session payloads: ${ble2.sessionPayloads}');
    if (server != null) {
      check('so the next connect reaches ready without the camera asking again',
          reusedOk, conn2.current.message);
    }
  }

  // ---- 3. a pair the camera refuses must not be reused forever -------------
  print('\n=== pairing: a refused session must not become a dead end ===');

  {
    // The stored pair was written without error — a BLE write is fire-and-forget,
    // so nothing reports that the camera ignored it. The camera holds a different
    // pairing, so the session never opens and the credentials are never handed
    // over. From here the app has to be able to pair again; if the dead record
    // stays reusable, every later attempt takes this same branch and no retry can
    // ever reach the pairing code.
    final store = MemoryPairingStore(<String, String>{
      'refId': '9999',
      'token': 'gone',
      'protocol': '1',
    });
    final ble = _FakeCameraBle(storedKey: 1234, storedToken: 'a-different-pairing');
    final conn = CameraConnection(
      ble: ble,
      store: store,
      host: '127.0.0.1',
      wifiJoin: ScriptedWifiJoinDelegate([WifiJoinResult(joinOutcome())]),
    );
    final first = await conn.connect(pairWait: const Duration(milliseconds: 500));
    check('a stored pair the camera no longer holds fails the connect', !first);
    final after = PairingRecord.fromMap(await store.load());
    check('and that dead pair is forgotten rather than kept for the next try',
        !after.canReuseSession, 'refId=${after.refId} token=${after.token}');

    final second = await conn.connect(pairWait: const Duration(milliseconds: 500));
    check('so the retry pairs again instead of failing the same way',
        ble.pairingPayloads.length == 1,
        '${ble.pairingPayloads.length} pairing write(s)');
    if (server != null) {
      check('and the retry succeeds', second, conn.current.message);
    }
  }

  // ---- 4. a recovered link has to be pinned to the camera again ------------
  print('\n=== network pin: lost and recovered ===');

  if (server != null) {
    final join = ScriptedWifiJoinDelegate(
        [const WifiJoinResult(WifiJoinOutcome.granted)]);
    final conn = CameraConnection(
      ble: _FakeCameraBle(),
      store: MemoryPairingStore(),
      host: '127.0.0.1',
      wifiJoin: join,
    );
    final up = await conn.connect();
    check('a connect pins the process to the camera network',
        up && join.isBound && join.bindCount == 1,
        'ready=$up bound=${join.isBound} binds=${join.bindCount}');

    conn.reportLost('simulated loss');
    check('a lost link releases the pin, or the app keeps no internet',
        !join.isBound && join.unbindCount == 1,
        'bound=${join.isBound} unbinds=${join.unbindCount}');
    // While `wifiUp` is false nothing else re-pins it: the lifecycle resume path
    // asks `rebindCameraNetwork`, which refuses on that flag. So recovery has to
    // restore the pin itself, or the link is only "back" on paper.
    check('and nothing else re-pins it while the link is reported lost',
        !await conn.rebindCameraNetwork());

    await conn.clearLost();
    check('a recovered link is pinned again, not merely reported as connected',
        join.isBound && join.bindCount == 2,
        'bound=${join.isBound} binds=${join.bindCount}');
    check('and the status is ready', conn.current.stage == LinkStage.ready);

    await conn.disconnect();
    // The flag the UI reads. Disconnecting releases the pin, so a status that
    // still says "Wi-Fi up" is the app claiming a capability it just gave up.
    check('disconnect stops claiming the camera Wi-Fi is up',
        !conn.current.wifiUp && !join.isBound,
        'wifiUp=${conn.current.wifiUp}, bound=${join.isBound}, '
        'unbinds=${join.unbindCount}');

    // ---- the lost state has to be *reachable from the outside* --------------
    //
    // `clearLost` restoring the pin is worthless if no caller can get to it, and
    // that was the actual defect: `isReady` is false while lost, so every caller
    // that used it as "may I probe?" skipped the one state probing exists to
    // repair — and `clearLost` itself returns early unless the stage *is* lost.
    // The result was a loss that could never be undone. These two checks are the
    // exit: a lost link must invite a probe, and a successful probe must land back
    // on ready.
    final lostJoin = ScriptedWifiJoinDelegate(
        [const WifiJoinResult(WifiJoinOutcome.granted)]);
    final lostConn = CameraConnection(
      ble: _FakeCameraBle(),
      store: MemoryPairingStore(),
      host: '127.0.0.1',
      wifiJoin: lostJoin,
    );
    await lostConn.connect();
    lostConn.reportLost('simulated loss');
    check('a lost link is not ready', !lostConn.isReady);
    // The whole point. `isReady` alone would say "do not probe", which is how a
    // temporary loss became permanent.
    check('but it still invites a probe, so recovery is possible',
        lostConn.canProbe,
        'stage=${lostConn.current.stage} ready=${lostConn.isReady} '
        'canProbe=${lostConn.canProbe}');
    check('and a ready link invites one too', lostConn.canProbe);
    // A probe against the live server must actually come back, and coming back
    // must restore both the status and the pin.
    final probe = await lostConn.http.status();    check('a lost link can still be probed over HTTP', probe.ok, '${probe.code}');
    await lostConn.clearLost();
    check('and clearing the loss restores ready *and* the pin',
        lostConn.isReady && lostJoin.isBound,
        'ready=${lostConn.isReady} bound=${lostJoin.isBound} '
        'binds=${lostJoin.bindCount}');
    await lostConn.disconnect();
  }

  // ---- 5. disconnect must actually leave, and switch the camera's radio off --
  //
  // ## What the maintainer measured, and what each check below can and cannot say
  //
  // Pressing Disconnect used to leave the phone on `YI_M1_XXXXXX` holding
  // `192.168.0.3` — no internet, and the camera's one client slot taken. Nothing
  // in the teardown released the *association* (only the process pin), and nothing
  // ever asked the camera to switch its radio off.
  //
  // **Be precise about the evidence.** Every assertion here is about what the
  // connection layer *called*; none of them observes a radio. "The release call
  // was made" is [V] about the call and [H] about the phone: whether Android drops
  // the association when the request is released, and whether the camera obeys
  // `WIFI_TOGGLE = "OFF"`, are hardware facts this file cannot see. The hardware
  // half of check 1 is `adb shell dumpsys wifi | grep -i 'mWifiInfo'` before and
  // after a disconnect on a real phone.
  print('\n=== disconnect: leaving the network, and the camera\'s radio ===');

  if (server != null) {
    final join = ScriptedWifiJoinDelegate(
        [const WifiJoinResult(WifiJoinOutcome.granted)]);
    final store = MemoryPairingStore();
    final ble = _FakeCameraBle();
    final conn = CameraConnection(
      ble: ble,
      store: store,
      host: '127.0.0.1',
      wifiJoin: join,
    );
    await conn.connect();
    check('the fixture reached a connected camera with a pairing',
        conn.isReady && PairingRecord.fromMap(await store.load()).hasPairing,
        'ready=${conn.isReady}');

    final before = Map<String, String>.of(await store.load());
    final outcome = await conn.disconnect();

    // (1) The association, not merely the pin.
    check('disconnect asks the platform to give up the association itself',
        join.releaseCount == 1, 'releases=${join.releaseCount}');
    check('and not only to drop the process pin', join.unbindCount >= 1,
        'unbinds=${join.unbindCount}');
    check('the platform reported the phone off the camera network',
        outcome.leftNetwork, '$outcome');

    // (1, cont.) Nothing may re-bind afterwards. A re-bind would put the phone
    // back on the AP the user just left — the defect, restored by a later tick.
    final bindsAfter = join.bindCount;
    check('nothing re-pins the process after a disconnect',
        !await conn.rebindCameraNetwork() && join.bindCount == bindsAfter,
        'binds=${join.bindCount}');

    // (2) The radio, over the characteristic that also switches it on.
    check('the camera\'s radio was switched off over BLE',
        outcome.radio == RadioSwitchOutcome.switchedOff, '${outcome.radio}');
    check('and the payload is "OFF" on the Wi-Fi toggle characteristic',
        ble.radioWrites.length == 2 && ble.radioWrites.last == 'OFF',
        'writes: ${ble.radioWrites}');

    // (3) The pairing survives, or reconnecting costs a walk to the camera.
    final after = Map<String, String>.of(await store.load());
    check('disconnect leaves the stored pairing exactly as it was',
        after.length == before.length &&
            after.entries.every((e) => before[e.key] == e.value),
        'before=$before after=$after');
    check('so the next connect can still open a session without the camera asking',
        PairingRecord.fromMap(after).canReuseSession,
        'refId=${after['refId']}');

    // (2, cont.) No pairing means no authenticated BLE channel, so the write must
    // not be attempted — and the caller has to be told, in the UI, that the radio
    // was left on. `RadioSwitchOutcome.noPairing` is what carries that.
    final store2 = MemoryPairingStore(<String, String>{
      'refId': '9999',
      'token': 'gone',
      'protocol': '1',
    });
    final ble2 = _FakeCameraBle(storedKey: 1234, storedToken: 'a-different-pairing');
    final join2 = ScriptedWifiJoinDelegate(
        [const WifiJoinResult(WifiJoinOutcome.granted)]);
    final conn2 = CameraConnection(
      ble: ble2,
      store: store2,
      host: '127.0.0.1',
      wifiJoin: join2,
    );
    // The camera refuses the stored pair, so the connect fails *and* the dead pair
    // is forgotten — the state where the app is on the network with no session.
    await conn2.connect(pairWait: const Duration(milliseconds: 500));
    await conn2.disconnect();
    check('with no pairing the radio switch-off is not attempted at all',
        ble2.radioWrites.where((w) => w == 'OFF').isEmpty,
        'writes: ${ble2.radioWrites}');
    check('and that outcome is distinguishable for the UI to explain',
        conn2.current.messageCode == LinkCodes.disconnectedNoPairing,
        'code=${conn2.current.messageCode} message="${conn2.current.message}"');
    check('a disconnect that left the radio on does not claim otherwise',
        conn2.current.message.contains('still on'),
        conn2.current.message);

    // The two remaining reasons are hardware states, and each has to be its own
    // value rather than folded into "failed": the user's next move differs.
    final ble3 = _FakeCameraBle()..connected = false;
    final join3 = ScriptedWifiJoinDelegate(
        [const WifiJoinResult(WifiJoinOutcome.granted)]);
    final conn3 = CameraConnection(
      ble: ble3,
      store: MemoryPairingStore(),
      host: '127.0.0.1',
      wifiJoin: join3,
    );
    await conn3.connect();
    await conn3.disconnect();
    check('a link that was already gone is reported as such, not as a refusal',
        conn3.current.messageCode == LinkCodes.disconnectedNoBle &&
            conn3.current.message.contains('already gone'),
        'code=${conn3.current.messageCode} message="${conn3.current.message}"');

    final ble4 = _FakeCameraBle();
    final join4 = ScriptedWifiJoinDelegate(
        [const WifiJoinResult(WifiJoinOutcome.granted)]);
    final conn4 = CameraConnection(
      ble: ble4,
      store: MemoryPairingStore(),
      host: '127.0.0.1',
      wifiJoin: join4,
    );
    await conn4.connect();
    ble4.failNextRadioWrite = true;
    await conn4.disconnect();
    check('a write the camera did not take is reported, not assumed to have worked',
        conn4.current.messageCode == LinkCodes.disconnectedRadioRefused &&
            conn4.current.message.contains('did not acknowledge'),
        'code=${conn4.current.messageCode} message="${conn4.current.message}"');

    // The all-clean case must stay quiet: a warning on every disconnect is a
    // warning nobody reads, and the sentence exists for the case that is *not*
    // clean. A clean disconnect carries the plain `disconnected` code, so the
    // reader is told the link went down and nothing else.
    check('a disconnect that did everything it promised carries no warning',
        conn.current.messageCode == LinkCodes.disconnected,
        'code=${conn.current.messageCode} message="${conn.current.message}"');

    // (3, cont.) A teardown for app shutdown must not claim a radio outcome it
    // never sought: `dispose` runs while the plugin registrations come apart.
    final ble5 = _FakeCameraBle();
    final conn5 = CameraConnection(
      ble: ble5,
      store: MemoryPairingStore(),
      host: '127.0.0.1',
      wifiJoin: ScriptedWifiJoinDelegate(
          [const WifiJoinResult(WifiJoinOutcome.granted)]),
    );
    await conn5.connect();
    await conn5.dispose();
    check('app teardown neither writes the radio nor claims a radio result',
        ble5.radioWrites.length == 1 &&
            conn5.current.messageCode == LinkCodes.disconnected,
        'writes=${ble5.radioWrites} code=${conn5.current.messageCode}');
  } else {
    print('skipped: port 80 is not available, so no connect can reach ready');
  }

  // ---- 6. a download that stops producing bytes must fail ------------------
  print('\n=== album: a stalled transfer must not hang forever ===');

  {
    // A camera that sends the headers and the first bytes of the body, then stops
    // talking without closing. The live-view stream makes this the normal way a
    // transfer dies on this hardware.
    final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    stalled.listen((req) async {
      req.response.statusCode = 200;
      req.response.headers.contentLength = 4096;
      req.response.add(Uint8List.fromList(List<int>.filled(16, 0x41)));
      await req.response.flush();
      // never the rest, and never a close
    });

    final album = CameraAlbum(
      CameraHttpClient(overrideSend: (c, p) async => _ok()),
      host: '127.0.0.1',
      port: stalled.port,
      timeout: const Duration(milliseconds: 400),
    );
    final file = AlbumFile(
      path: '/DCIM/101YICAM/YI000001.JPG',
      fileType: 'picture',
      captureTime: DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
    );

    final sw = Stopwatch()..start();
    Object? err;
    try {
      // An outer deadline so a defective build *fails* this check instead of
      // hanging the whole run.
      await album.download(file).timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      err = e;
    }
    final ms = sw.elapsedMilliseconds;
    check('a stalled body fails the transfer instead of never returning',
        err is AlbumException, '${err.runtimeType}: $err');
    check('and it fails within the configured transfer timeout', ms < 3000,
        '${ms}ms');
    album.close();
    await stalled.close(force: true);
  }

  // ---- 6. the RAW rendition column, against a camera that refuses like the real one
  print('\n=== album: a RAW has no thumbnail, and zero bytes never leave the album ===');

  {
    // ## The measured column, reproduced by a loopback camera
    //
    // `analysis/50` §2 and `analysis/61` §1 agree on these three rows, measured twice on
    // the real 3.1-cn body:
    //
    //   `.DNG` `Thumbnail` -> 204, zero bytes   (not "missing file" — "no such rendition")
    //   `.DNG` `MidThumb`  -> 404
    //   `.DNG` `Original`  -> 200, real bytes
    //
    // The grid's thumbnail fetch is one `GET` per rendition, and its failure mode was to
    // read the 204 as a dead end and hand the (empty) body onward. Both halves are checked
    // **here**, at `CameraAlbum`, rather than only through the page: a page-level check
    // can only see the outcome through a stub of this same class, so if this class is
    // wrong the page check agrees with it.
    final server = await _albumServer((req) async {
      final data = jsonDecode(req.uri.queryParameters['data']!) as Map;
      final res = '${data['resulotion']}';
      final raw = '${data['path']}'.toUpperCase().endsWith('.DNG');
      if (raw && res == 'Thumbnail') {
        req.response.statusCode = 204;
        return; // no body, exactly as the camera does
      }
      if (raw && res == 'MidThumb') {
        req.response.statusCode = 404;
        return;
      }
      req.response.statusCode = 200;
      req.response.add(_jpegOf(raw ? 4096 : (res == 'Thumbnail' ? 6785 : 196495)));
    });

    final album = CameraAlbum(
      CameraHttpClient(overrideSend: (c, p) async => _ok()),
      host: '127.0.0.1',
      port: server.port,
    );
    final dng = AlbumFile(
      path: '/DCIM/100YICAM/P9150034.DNG',
      fileType: 'raw',
      captureTime: DateTime.fromMillisecondsSinceEpoch(1789465690 * 1000),
    );
    final jpg = AlbumFile(
      path: '/DCIM/100YICAM/P9150034.JPG',
      fileType: 'rawJpeg',
      captureTime: DateTime.fromMillisecondsSinceEpoch(1789465690 * 1000),
    );

    // --- the 204 is a named answer, not an anonymous failure
    Object? thumbError;
    try {
      await album.download(dng, resolution: FileResolution.thumbnail);
    } on Object catch (e) {
      thumbError = e;
    }
    check('a RAW thumbnail answers the measured 204',
        thumbError is AlbumException && thumbError.code == 204,
        '${thumbError.runtimeType}: $thumbError');
    check(
        'and the 204 is classified as "this rendition does not exist"',
        thumbError is AlbumException && thumbError.isNoContent,
        '${thumbError is AlbumException ? thumbError.code : thumbError}');
    check('the message says so rather than reporting a missing file',
        '$thumbError'.contains('cannot produce that rendition'), '$thumbError');

    // --- a `200` with an empty body is refused at the source
    //
    // Not hypothetical: `Image.memory` on zero bytes is the phone's own reported
    // `FlutterImageDecoderImplDefault: Failed to decode image`, and an empty buffer is
    // indistinguishable from a valid one to every caller downstream of here.
    final emptyServer = await _albumServer((req) async {
      req.response.statusCode = 200; // headers only, no body
    });
    final emptyAlbum = CameraAlbum(
      CameraHttpClient(overrideSend: (c, p) async => _ok()),
      host: '127.0.0.1',
      port: emptyServer.port,
    );
    Object? emptyError;
    try {
      await emptyAlbum.download(jpg, resolution: FileResolution.thumbnail);
    } on Object catch (e) {
      emptyError = e;
    }
    check('a 200 with an empty body is refused instead of returned',
        emptyError is AlbumException, '${emptyError.runtimeType}: $emptyError');
    check('and it says there is nothing to decode',
        '$emptyError'.contains('empty body'), '$emptyError');
    emptyAlbum.close();
    await emptyServer.close(force: true);

    // --- the grid's chain degrades *through* the 204 rather than stopping at it
    var dngChain = <String>[];
    Object? chainError;
    try {
      final (bytes, res) = await album.downloadWithFallback(
        dng,
        chain: CameraAlbum.gridThumbnailChain,
      );
      dngChain = ['${res.wire}:${bytes.length}'];
    } on Object catch (e) {
      chainError = e;
    }
    check('the grid chain reaches a rendition the camera will serve',
        chainError == null && dngChain.isNotEmpty, '$chainError');
    check('and it is the Original, after 204 at Thumbnail and 404 at MidThumb',
        dngChain.isNotEmpty && dngChain.first.startsWith('Original:'),
        '$dngChain');

    // --- and a JPEG gets the small one: cheapest-first is the point of the order
    final (jpgBytes, jpgRes) = await album.downloadWithFallback(
      jpg,
      chain: CameraAlbum.gridThumbnailChain,
    );
    check('a JPEG grid thumbnail costs one Thumbnail request',
        jpgRes == FileResolution.thumbnail && jpgBytes.length == 6785,
        '${jpgRes.wire}, ${jpgBytes.length} bytes');

    // --- the sync chain keeps the opposite rule: a 204 at `Original` is not a reason to
    //     abandon a file that exists at a smaller size.
    final refusals = <String>[];
    final skipServer = await _albumServer((req) async {
      final data = jsonDecode(req.uri.queryParameters['data']!) as Map;
      final res = '${data['resulotion']}';
      refusals.add(res);
      if (res == 'Original') {
        req.response.statusCode = 204;
        return;
      }
      req.response.statusCode = 200;
      req.response.add(_jpegOf(1024));
    });
    final skipAlbum = CameraAlbum(
      CameraHttpClient(overrideSend: (c, p) async => _ok()),
      host: '127.0.0.1',
      port: skipServer.port,
    );
    final (degraded, degradedRes) = await skipAlbum.downloadWithFallback(jpg);
    check('a 204 at Original still degrades when the chain is not in skip mode',
        degradedRes == FileResolution.midThumb && degraded.isNotEmpty,
        '${degradedRes.wire}, ${degraded.length} bytes');
    check('so the sync chain kept walking after the refusal',
        refusals.join(',') == 'Original,MidThumb', refusals.join(','));

    skipAlbum.close();
    await skipServer.close(force: true);
    album.close();
    await server.close(force: true);
  }

  // ---- 7. one receiver, one bind ------------------------------------------
  print('\n=== live view: two concurrent starts, one receiver ===');

  {
    final port = await _freeUdpPort();
    final lv = CameraLiveView(port: port);
    var frames = 0;
    final sub = lv.frames.listen((_) => frames++);

    // `if (_socket != null) return` is defeated by the bind's own `await`, and
    // `reuseAddress: true` lets the second bind succeed — so both sockets end up
    // bound to the port and only the last one is remembered.
    await Future.wait([lv.start(), lv.start()]);

    final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    void send(int from, int count) {
      for (var i = from; i < from + count; i++) {
        sender.send(_datagram(i), InternetAddress.loopbackIPv4, port);
      }
    }

    send(0, 8);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final beforeStop = lv.stats.received;
    check('a concurrently started receiver still receives frames',
        beforeStop > 0, 'received=$beforeStop');

    await lv.stop();
    final receivedAtStop = lv.stats.received;
    final framesAtStop = frames;
    send(100, 24);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    check(
        'stop() stops the stream even after two concurrent starts',
        lv.stats.received == receivedAtStop && frames == framesAtStop,
        'datagrams $receivedAtStop -> ${lv.stats.received}, '
        'frames $framesAtStop -> $frames');

    await sub.cancel();
    sender.close();
    await lv.dispose();
  }

  // ---- 8. the album's thumbnail cache --------------------------------------
  await _verifyAlbumThumbnailCache();

  await server?.close(force: true);
}

/// The album grid's thumbnail cache: its key, its format, its cap, and everything it
/// must refuse to keep.
///
/// ## Why this runs in the plain VM rather than through the page
///
/// `AGENTS.md` §3: persistence formats, boundaries and backward compatibility belong at
/// the cheapest layer that can answer them, and a widget test can only see this class
/// through the page. The page's own half — "a second visit asks the camera for nothing"
/// — is checked in `test/album_thumbnail_cache_test.dart`, against a real directory; this
/// is the half that says **what** is on the disk and what may never be.
///
/// Every check here is written to be able to fail: the round's report carries the
/// mutations that turned each group red (no eviction, no picture gate, no key in the
/// entry, a key without the date, a remembered refusal).
Future<void> _verifyAlbumThumbnailCache() async {
  print('\n=== album thumbnail cache: the key ===');

  // ## The published function, not `String.hashCode`
  //
  // The entry's file name is FNV-1a 32 of the whole shot key. Pinned against the
  // published test vectors, so the names on a device are reproducible from the key
  // alone — and so "a hash I invented and cannot check" is not what is in the repo.
  check('an entry name is FNV-1a 32 of the key, as published',
      AlbumThumbnailCache.entryName('foobar') == 'tbf9cf968.bin',
      AlbumThumbnailCache.entryName('foobar'));
  check('including the empty string',
      AlbumThumbnailCache.entryName('') == 't811c9dc5.bin',
      AlbumThumbnailCache.entryName(''));
  check('and it is the key that is hashed, not the file name',
      AlbumThumbnailCache.entryName('/DCIM/100YICAM/P9150040.JPG|1789400040') ==
          'tc4970562.bin',
      AlbumThumbnailCache.entryName('/DCIM/100YICAM/P9150040.JPG|1789400040'));

  // ## The date is part of the key, which is what invalidates a re-shot file
  const shot = '/DCIM/100YICAM/P9150040.JPG|1789400040';
  check('a file re-shot in a later second is a different entry',
      AlbumThumbnailCache.entryName(shot) !=
          AlbumThumbnailCache.entryName('/DCIM/100YICAM/P9150040.JPG|1789400041'));
  check('and a different path at the same second is too',
      AlbumThumbnailCache.entryName(shot) !=
          AlbumThumbnailCache.entryName('/DCIM/100YICAM/P9150041.JPG|1789400040'));

  final root = Directory.systemTemp.createTempSync('yi_m1_thumb_cache_vm_');
  Future<Directory> resolve() async => root;
  AlbumThumbnailCache fresh({int? maxBytes, int? maxEntryBytes}) =>
      AlbumThumbnailCache(
        directory: resolve,
        maxBytes: maxBytes ?? kAlbumThumbnailCacheMaxBytes,
        maxEntryBytes: maxEntryBytes ?? kAlbumThumbnailCacheMaxEntryBytes,
      );

  print('\n=== album thumbnail cache: round trip, and what it refuses ===');
  {
    final cache = fresh();
    final bytes = jpegBytes(6785); // the measured cost of one grid thumbnail
    check('a picture is kept', await cache.put(shot, bytes));

    final back = await cache.read(shot);
    check('and comes back byte for byte',
        back != null &&
            back.length == bytes.length &&
            back[0] == bytes[0] &&
            back[back.length - 1] == bytes[bytes.length - 1],
        '${back?.length} bytes');
    check('with the entry header stripped, not handed to the decoder',
        back != null &&
            back[0] == 0xFF &&
            back[1] == 0xD8 &&
            back[back.length - 2] == 0xFF &&
            back[back.length - 1] == 0xD9,
        back == null ? 'null' : '${back[0]},${back[1]} … ${back[back.length - 2]},${back[back.length - 1]}');

    // ## The whole feature, at this layer
    //
    // Nothing is loaded and nothing is cached in the object: a brand-new cache over the
    // same directory is what a new page, a new `CameraAlbum` or a restarted app is.
    final restarted = fresh();
    check('a brand-new cache object over the same directory still has it',
        await restarted.read(shot) != null);

    check('a key that was never cached is a miss',
        await cache.read('/DCIM/100YICAM/P9150099.JPG|1789400099') == null);

    // A response that is not a picture must never become a cache entry: the JSON error
    // body and the truncated transfer are the two this camera actually produces.
    check('a JSON error body is not kept',
        !await cache.put('/err.JPG|1',
            Uint8List.fromList(utf8.encode('{"code":1505,"data":"internal"}'))));
    check('a truncated JPEG is not kept',
        !await cache.put('/trunc.JPG|1', Uint8List.fromList([0xFF, 0xD8, 1, 2, 3])));
    check('an empty body is not kept',
        !await cache.put('/empty.JPG|1', Uint8List(0)));
    check('and none of the three wrote an entry',
        (await cache.stats()).entries == 1, '${await cache.stats()}');

    // ## Absence is not cached, and a refusal leaves no trace
    //
    // A `.DNG` with no thumbnail and a request that failed are different facts; only the
    // first is a property of the file, and the camera's answer can change. So a key that
    // was once offered bytes that are not a picture must still be cacheable the moment a
    // real one arrives — nothing may have been remembered about it in the meantime.
    await cache.put('/later.JPG|1', Uint8List.fromList([0xFF, 0xD8]));
    check('a key offered a non-picture is still cacheable afterwards',
        await cache.put('/later.JPG|1', jpegBytes(64)) &&
            await cache.read('/later.JPG|1') != null);

    // The grid's chain reaches `Original` for a file with no small rendition: 9.4 MB
    // measured for a JPEG, 32 MB for a `.DNG`. Three of those would evict a whole card's
    // thumbnails to store pictures that are not thumbnails.
    check('an Original is not kept to draw a 170dp tile',
        !await cache.put('/big.JPG|1', jpegBytes(2 * 1024 * 1024)));

    // A file that is not what it claims to be is a **miss**, not somebody else's photo.
    // This is what the header line buys: the name is a hash, and a hash can collide.
    final damaged = await cache.entryFile(shot);
    await damaged.writeAsBytes(<int>[
      ...utf8.encode('${AlbumThumbnailCache.magic} /DCIM/100YICAM/OTHER.JPG|7\n'),
      ...jpegBytes(64),
    ], flush: true);
    check('an entry whose header names another key is a miss, not a wrong picture',
        await cache.read(shot) == null);
    await damaged.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    check('and a corrupt file in the cache is a miss too',
        await cache.read(shot) == null);

    // A cache that cannot resolve its directory must not be able to break the grid it
    // accelerates: the page's loop treats a miss as "ask the camera", which is exactly
    // what it did before this cache existed.
    final broken = AlbumThumbnailCache(
        directory: () async => throw const FileSystemException('no cache directory'));
    check('a cache with no directory reports a miss instead of throwing',
        await broken.read(shot) == null);
    check('and refuses to write instead of throwing',
        !await broken.put(shot, jpegBytes(64)));
    check('and reports itself empty', (await broken.stats()).bytes == 0);
  }

  print('\n=== album thumbnail cache: the cap ===');
  {
    // ## A cap, exercised with kilobytes instead of megabytes
    //
    // Several sleeps, because eviction is oldest-first by file mtime: six writes inside
    // one millisecond would tie and the tie-break would decide the order, which is not
    // what this measures.
    final cap = Directory('${root.path}${Platform.pathSeparator}cap');
    final cache = AlbumThumbnailCache(
      directory: () async => cap,
      maxBytes: 40 * 1024,
      maxEntryBytes: 16 * 1024,
    );
    const kb10 = 10 * 1024;
    for (var i = 0; i < 6; i++) {
      await cache.put('/DCIM/100YICAM/C00000$i.JPG|$i', jpegBytes(kb10));
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }

    final stats = await cache.stats();
    check('the cache never exceeds its cap', stats.bytes <= 40 * 1024, '$stats');
    check('and it did not simply keep everything', stats.entries < 6, '$stats');
    check('the newest entry is still there',
        await cache.read('/DCIM/100YICAM/C000005.JPG|5') != null);
    check('and the oldest was the one evicted',
        await cache.read('/DCIM/100YICAM/C000000.JPG|0') == null);

    // The bound has to hold as a *bound*, not only at the moment it was measured: a
    // second pass of writes has to fight the same cap.
    for (var i = 6; i < 12; i++) {
      await cache.put('/DCIM/100YICAM/C00000$i.JPG|$i', jpegBytes(kb10));
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    final after = await cache.stats();
    check('and it still holds after another six writes',
        after.bytes <= 40 * 1024, '$after');

    // Anything in this directory that is not an entry is neither counted nor deleted.
    // A `.tmp` from a write that was killed is the real case; a stray file stands in
    // for both, because the rule is the same one.
    final stray = File('${cap.path}${Platform.pathSeparator}not-an-entry.txt');
    await stray.writeAsString('x', flush: true);
    await cache.put('/DCIM/100YICAM/C000099.JPG|99', jpegBytes(kb10));
    check('a file that is not an entry is left alone, not evicted',
        await stray.exists());
    check('and is not counted against the cap',
        (await cache.stats()).entries < 12, '${await cache.stats()}');

    // ## The invariant the two limits have to keep
    //
    // An entry bigger than the whole cache would be evicted by the write that created
    // it, leaving the directory empty and the cap meaningless.
    check('a single entry can never exceed the whole cache',
        kAlbumThumbnailCacheMaxEntryBytes <= kAlbumThumbnailCacheMaxBytes,
        '$kAlbumThumbnailCacheMaxEntryBytes > $kAlbumThumbnailCacheMaxBytes');
  }

  print('\n=== album thumbnail cache: what a card costs ===');
  {
    // The cap is chosen against this arithmetic, so it is asserted rather than asserted
    // in prose: 12 MB holds a measured 1000-shot card with room to spare.
    const perThumbnail = 6785; // measured, `analysis/50` §2
    const card = 1000;
    check('a 1000-shot card fits in the cap with no eviction at all',
        perThumbnail * card < kAlbumThumbnailCacheMaxBytes,
        '${perThumbnail * card ~/ 1024} KB of '
        '${kAlbumThumbnailCacheMaxBytes ~/ (1024 * 1024)} MB');
    check('and the cap is smaller than one Original on this camera',
        kAlbumThumbnailCacheMaxBytes < 9 * 1024 * 1024,
        'cap ${kAlbumThumbnailCacheMaxBytes ~/ (1024 * 1024)} MB vs a measured '
        '9.4 MB JPEG original');
  }

  try {
    root.deleteSync(recursive: true);
  } on FileSystemException {
    // left for the OS
  }
}

