/// End-to-end HTTP verification against a real camera.
///
/// Run with the plain Dart VM - no Flutter, no device build:
///
///     dart run tool/verify_http.dart
///     dart run tool/verify_http.dart --host 192.168.0.10 --live
///
/// `--live` additionally takes a photo and records a short video, which is what
/// proves the capabilities the official app never exposed.  Without it the tool
/// is read-only except for entering remote-control mode.
///
/// ## What a `PASS` means here
///
/// Every `PASS` printed below is the passing branch of a condition that was
/// actually evaluated: [check] takes the condition, and [pass] takes the camera's
/// own response.  This file used to have an `ok(name, detail)` that incremented
/// the pass counter unconditionally, so a camera answering **HTTP 200 with
/// `{"code":500}`** was reported as `PASS RCVideoFormatSet 4K_30 {"code":500}` —
/// and the transport throws only on a non-200 *HTTP status*, so nothing else
/// objected.  In the tool whose entire purpose is finding out which of ten video
/// formats this firmware accepts, that is the difference between an answer and a
/// green line.
///
/// A **404** is reported as `REFUSED`, not as a pass: it is this firmware's
/// status for bad or missing parameters ([CameraHttpException.isBadParameters]),
/// so it is the *answer* to "does it take 4K_24" but it is not evidence that
/// anything worked.  The exit code is non-zero when something failed, and the
/// summary counts the four outcomes separately.
library;

import 'dart:io';

import '../lib/protocol/http_commands.dart';
import '../lib/transport/http_transport.dart';

int _pass = 0;
int _fail = 0;
int _skip = 0;
int _refused = 0;

/// Count a pass only when [condition] held.
///
/// The condition is a parameter rather than something the caller is trusted to
/// have checked, so there is no way to print `PASS` from this file without one.
void check(String name, bool condition, String detail) {
  if (condition) {
    _pass++;
    print('  PASS  $name${detail.isEmpty ? '' : '   ($detail)'}');
  } else {
    bad(name, detail);
  }
}

/// Count a pass whose evidence is a camera response.
///
/// [CameraResponse.ok] is the body's `code`, **not** the HTTP status — the
/// transport only throws on a non-200 *HTTP* status, so a 200 body of
/// `{"code":500}` arrives here looking like an ordinary response.  It is a
/// failure: the camera answered and refused.
void pass(String name, CameraResponse r) {
  check(
      name,
      r.ok,
      r.ok
          ? r.raw.trim()
          : 'the camera answered HTTP 200 with code=${r.code}: refused, '
              'raw=${r.raw.trim()}');
}

void bad(String name, String detail) {
  _fail++;
  print('  FAIL  $name\n          $detail');
}

/// The camera answered, and said no.
///
/// A 404 on this camera is its status for bad or missing parameters (see
/// `CameraHttpException.isBadParameters`), so it means the request was rejected
/// — the value is not accepted, or the endpoint is absent.  That is a result
/// worth printing and worth not counting: it is not evidence that anything
/// worked, and it is not a defect either, so counting it as a failure would put
/// a red line next to a healthy camera.
void refused(String name, String detail) {
  _refused++;
  print('  REFUSED  $name   ($detail)');
}

void skip(String name, String why) {
  _skip++;
  print('  SKIP  $name   ($why)');
}

Future<void> main(List<String> args) async {
  final host = _argValue(args, '--host') ?? CameraHttpClient.defaultHost;
  final live = args.contains('--live');

  print('YI M1 HTTP verification against $host');
  print(live ? 'mode: LIVE (will take a photo and record a video)\n'
             : 'mode: read-only (pass --live to exercise shooting)\n');

  final camera = CameraHttpClient(host: host);
  try {
    // ---------------------------------------------------------------- status
    print('[status]');
    CameraResponse status;
    try {
      status = await camera.status();
    } on CameraHttpException catch (e) {
      bad('GetCameraStatus', '$e');
      print('\nCannot reach the camera. Join its Wi-Fi first '
          '(see docs/HARDWARE-VERIFICATION.md).');
      _summary();
      return;
    }
    if (!status.ok) {
      bad('GetCameraStatus', 'code=${status.code} raw=${status.raw}');
    } else {
      pass('GetCameraStatus', status);
      final data = status.data;
      if (data is Map) {
        final battery = data['batteryLevel'];
        final shots = data['SurplusPhotoCnts'];
        check('batteryLevel reported', battery != null,
            battery?.toString() ?? 'absent from the status body');
        check('SurplusPhotoCnts reported', shots != null,
            shots?.toString() ?? 'absent from the status body');
        // The firmware carries this misspelling for the resolution key; it must
        // never be "corrected" in our requests.
        final lensVer = data['lenVer'];
        if (lensVer == '0.0' || lensVer == '') {
          skip('lens info', 'no lens attached or lens not communicating');
        }
      } else {
        // Was silent: a 200 with no JSON object reported nothing at all, and the
        // fields read out of `data` below are what the status screen shows.
        bad('GetCameraStatus body',
            'no JSON object under "data": ${status.raw.trim()}');
      }
    }

    // ------------------------------------------------------- command coverage
    print('\n[command table]');
    // Offline checks. Nothing here is evidence about the camera, so each one is
    // the condition it asserts rather than the number it prints.
    check('dispatch table loaded', kHttpCommands.isNotEmpty,
        '${kHttpCommands.length} commands');
    check('VideoRecordingStart is in the dispatch table',
        isKnownCommand('VideoRecordingStart'), '');
    for (final c in kDangerousCommands) {
      if (!isKnownCommand(c)) bad('dangerous command $c not in table', 'inconsistent');
    }
    // Non-empty is the assertion: with an empty set the loop above passes
    // vacuously, and the line used to read `PASS dangerous commands flagged (0)`.
    check('dangerous commands flagged', kDangerousCommands.isNotEmpty,
        '${kDangerousCommands.length} in kDangerousCommands');
    // The set is enforced at the transport, not here: `send` refuses every member
    // unless the caller presents an approval (`tool/verify_transport.dart` walks the
    // set and checks that, offline). What belongs on this line is only that the
    // predicate the transport asks agrees with the set the table was checked against
    // — a set and its own accessor disagreeing is the same class of gap as the set
    // having no accessor at all, which is what this round fixed.
    for (final c in kDangerousCommands) {
      if (!isDangerousCommand(c)) {
        bad('dangerous command $c not reported as dangerous',
            'isDangerousCommand disagrees with kDangerousCommands');
      }
    }
    if (isDangerousCommand('GetCameraStatus')) {
      bad('GetCameraStatus reported as dangerous', 'the predicate is too broad');
    }

    // -------------------------------------------------------- remote control
    print('\n[remote control]');
    final rc = await camera.startRemoteControl();
    pass('RCStartRemoteCtl', rc);

    // The tested firmware 404s these two even though they are in the table.
    //
    // A 404 here is reported as REFUSED rather than as a pass. `PASS GetFileList
    // -> 404 (endpoint absent on this firmware)` was counted in the pass total and
    // in the exit code while the camera had just rejected the request, and per
    // `CameraHttpException.isBadParameters` a 404 from this firmware means *we*
    // built the request wrong or the endpoint is absent — neither of which is a
    // verified capability.
    for (final cmd in ['GetFileList', 'GetFileInfo', 'GetMLFileList']) {
      try {
        final r = await camera.send(cmd);
        pass(cmd, r);
      } on CameraHttpException catch (e) {
        if (e.statusCode == 404) {
          refused(cmd,
              '404 - the firmware rejected the request; not a verified capability');
        } else {
          bad(cmd, '$e');
        }
      }
    }

    // -------------------------------------------------------------- settings
    print('\n[settings that the official app does not expose]');
    // Probe the documented format pool.  A 404 here is informative rather than
    // fatal: it means the camera's parser rejected the value, so the pool we
    // transcribed is not the whole story for this firmware.
    const videoFormats = [
      '4K_30', '4K_24', '4K_30_LOW', '2K_30', '2880_24',
      'FHD_60', 'FHD_30', '720P_60', '720P_120', 'VGA_240',
    ];
    for (final f in videoFormats) {
      try {
        final r = await camera.setVideoFormat(f);
        pass('RCVideoFormatSet $f', r);
      } on CameraHttpException catch (e) {
        // 404 moved from FAIL to REFUSED. It is the same status the file-list
        // commands above get, and treating one as a pass and the other as a
        // failure meant the same event was scored two ways; "this firmware does
        // not take 720P_120" is this tool's answer, not a defect it found.
        if (e.statusCode == 404) {
          refused('RCVideoFormatSet $f',
              '404 - value not accepted by this firmware');
        } else {
          bad('RCVideoFormatSet $f', '$e');
        }
      }
    }
    for (final f in ['RAW', 'RAWJ-L', 'JPG-L']) {
      try {
        final r = await camera.setFileFormat(f);
        pass('RCFileFormatSet $f', r);
      } on CameraHttpException catch (e) {
        if (e.statusCode == 404) {
          refused('RCFileFormatSet $f',
              '404 - value not accepted by this firmware');
        } else {
          bad('RCFileFormatSet $f', '$e');
        }
      }
    }

    // ------------------------------------------------------------------ live
    print('\n[live capture]');
    if (!live) {
      skip('photo capture', 'pass --live');
      skip('video recording', 'pass --live');
    } else {
      final shot = await camera.shoot();
      pass('RCDoShooting', shot);
      await Future<void>.delayed(const Duration(seconds: 4));

      final v1 = await camera.videoStart();
      pass('VideoRecordingStart', v1);
      await Future<void>.delayed(const Duration(seconds: 4));
      final v2 = await camera.videoStop();
      pass('VideoRecordingStop', v2);

      print('\n  >>> CHECK THE SD CARD for a new photo and a new video file.');
      print('  >>> The camera returning code 200 is necessary but not sufficient.');
    }

    final finalStatus = await camera.status();
    // Was `if (finalStatus.ok) ok(...)`: anything else produced no line at all, so
    // the last check in the file could pass by not running.
    pass('status after tests', finalStatus);
  } finally {
    camera.close();
  }

  _summary();
}

void _summary() {
  print('\n$_pass passed, $_fail failed, $_skip skipped, '
      '$_refused refused by the camera');
  // `passed` alone is not the verdict and never was: REFUSED lines are results,
  // not passes, which is why they are printed with their own count rather than
  // folded into either total. `task.ps1`'s layer summary reads the "N passed,
  // M failed" prefix of this line, so it stays first.
  if (_fail > 0) exitCode = 1;
}

String? _argValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
}
