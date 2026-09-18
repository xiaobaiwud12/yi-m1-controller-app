// Assert things about a **built APK**, without an Android SDK installed.
//
// ## Why this exists
//
// `tools/task.ps1 build` in the development repository already unpacks the artifact
// and checks it — the eight required permissions, the absence of test instrumentation
// and the build stamp. Those checks are the best release hygiene this project has
// (`analysis/63` §3.3), and **none of them survive the move to a public repository**,
// because `tools/` is not published. A stranger could build an APK and had nothing at
// all to check it with: the one artifact that actually reaches a user was the one
// thing nobody verified (`analysis/63` §12.4 item 2).
//
// This file closes that, and it has to do it with nothing but Dart and `dart:io`,
// because a contributor should not need Android build-tools to check a build. So it
// reads the `.apk` — which is a zip — itself:
//
//   * deflate is `dart:io`'s own `ZLibDecoder(raw: true)`, and the zip directory is
//     parsed here (about eighty lines, no packages added);
//   * permissions are read out of the **packaged** `AndroidManifest.xml`, not out of
//     the source tree. That distinction is the whole point: `CHANGE_NETWORK_STATE`
//     was missing from the shipped APK for three rounds while the manifest source
//     looked complete (`analysis/63` §4.2);
//   * the instrument markers are searched in `classes*.dex` and `lib/**/*.so`, which
//     is where Dart's AOT snapshot and the Android bytecode actually live;
//   * the signature is inspected for the **debug certificate's subject**. A release
//     build signed with the public debug key is exactly the blocker `analysis/63` §6
//     records, and until now nothing could detect it from the artifact.
//
// ## What it deliberately cannot check
//
// Nothing here validates the APK's structure the way `aapt2` does, and the permission
// check is a *presence* test on the manifest's string pool rather than an XML-
// structure test. It answers "is this string in the shipped manifest" — which is what
// the original check answered too — and not "is it attached to a `uses-permission`
// element". That is a real difference and it is stated rather than papered over: run
// `aapt2 dump xmltree` when you have build-tools, and see the release README.
//
// ## Usage
//
//     cd app
//     dart tool/verify_apk.dart <path-to.apk>
//     dart tool/verify_apk.dart <path-to.apk> --stamp <build stamp> [--allow-debug-signing]
//     dart tool/verify_apk.dart --self-test
//
// Exit codes: 0 = every check passed · 1 = at least one failed · 2 = could not run.
//
// `--self-test` writes a synthetic APK (a stored-only zip, built here) containing one
// missing permission, one instrument marker, no build stamp and a debug certificate
// subject, then asserts that each of those is reported. A check that cannot fail is
// not a check, and this is how this one proves it can.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// What the artifact must satisfy
// ---------------------------------------------------------------------------

/// The eight permissions `tools/task.ps1 build` asserts, verbatim.
///
/// `CHANGE_NETWORK_STATE` is *normal*, not dangerous: it has no runtime dialog, so a
/// missing one is invisible until `requestNetwork()` silently does nothing. That is
/// why the check exists and why it reads the artifact rather than the source.
const List<String> kRequiredPermissions = <String>[
  'android.permission.CHANGE_NETWORK_STATE',
  'android.permission.CHANGE_WIFI_STATE',
  'android.permission.NEARBY_WIFI_DEVICES',
  'android.permission.ACCESS_FINE_LOCATION',
  'android.permission.POST_NOTIFICATIONS',
  'android.permission.BLUETOOTH_SCAN',
  'android.permission.BLUETOOTH_CONNECT',
  'android.permission.INTERNET',
];

/// Strings that must not be in a delivered build.
///
/// `FAKE_CAMERA_VERIFICATION_ONLY` and `DIRECT_CAMERA_VERIFICATION_ONLY` are
/// compile-time seams: with the define absent the compiler tree-shakes them out, and
/// this check is the mechanical proof that it did.
const List<String> kForbiddenMarkers = <String>[
  'MarionetteBinding',
  'marionette',
  'FAKE_CAMERA_VERIFICATION_ONLY',
  'DIRECT_CAMERA_VERIFICATION_ONLY',
];

/// A substring of the debug certificate's subject, as it appears in the DER of
/// `META-INF/*.RSA`.
///
/// The Android debug key is a *publicly known* key — fixed alias, fixed password,
/// shipped in every SDK installation — so an APK signed with it can be replaced by
/// anybody's build and Android will accept the replacement as an update.
const String kDebugCertificateMarker = 'Android Debug';

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

class ApkFinding {
  final String check;
  final String severity;
  final String detail;
  const ApkFinding(this.check, this.severity, this.detail);
}

class ApkResult {
  final List<ApkFinding> findings = <ApkFinding>[];
  final List<String> stats = <String>[];
  int sizeBytes = 0;
  int entryCount = 0;
  void add(String check, String severity, String detail) =>
      findings.add(ApkFinding(check, severity, detail));
  List<ApkFinding> get fails =>
      findings.where((f) => f.severity == 'FAIL').toList();
}

// ---------------------------------------------------------------------------
// A zip reader, and the little of a zip writer the self-test needs
// ---------------------------------------------------------------------------

class ZipEntry {
  final String name;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final Uint8List? _data;
  const ZipEntry(this.name, this.method, this.compressedSize,
      this.uncompressedSize, this.localHeaderOffset, this._data);
}

class MiniZip {
  final Uint8List bytes;
  MiniZip(this.bytes);

  /// Every entry in the archive, read from the central directory.
  List<ZipEntry> entries() {
    final eocd = _findEocd();
    final count = _u16(eocd + 10);
    var p = _u32(eocd + 16);
    final out = <ZipEntry>[];
    for (var i = 0; i < count; i++) {
      if (_u32(p) != 0x02014b50) {
        throw StateError('bad central directory entry at $p');
      }
      final method = _u16(p + 10);
      final compressed = _u32(p + 20);
      final uncompressed = _u32(p + 24);
      final nameLen = _u16(p + 28);
      final extraLen = _u16(p + 30);
      final commentLen = _u16(p + 32);
      final localOffset = _u32(p + 42);
      final name = utf8.decode(bytes.sublist(p + 46, p + 46 + nameLen),
          allowMalformed: true);
      out.add(ZipEntry(name, method, compressed, uncompressed, localOffset, null));
      p += 46 + nameLen + extraLen + commentLen;
    }
    return out;
  }

  /// The bytes of one entry, inflated if needed.
  Uint8List read(ZipEntry entry) {
    final p = entry.localHeaderOffset;
    if (_u32(p) != 0x04034b50) {
      throw StateError('bad local header for ${entry.name}');
    }
    final nameLen = _u16(p + 26);
    final extraLen = _u16(p + 28);
    final start = p + 30 + nameLen + extraLen;
    final raw = Uint8List.sublistView(
        bytes, start, start + entry.compressedSize);
    switch (entry.method) {
      case 0:
        return Uint8List.fromList(raw);
      case 8:
        return Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      default:
        throw StateError('${entry.name}: unsupported compression '
            'method ${entry.method}');
    }
  }

  int _findEocd() {
    for (var i = bytes.length - 22; i >= 0; i--) {
      if (_u32(i) == 0x06054b50) return i;
      if (bytes.length - i > 66000) break;
    }
    throw StateError('not a zip: no end-of-central-directory record');
  }

  int _u16(int at) => bytes[at] | (bytes[at + 1] << 8);
  int _u32(int at) =>
      bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24);
}

/// Builds a zip with stored (uncompressed) entries — enough for the self-test.
Uint8List buildStoredZip(Map<String, List<int>> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  final offsets = <String, int>{};
  entries.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final crc = _crc32(data);
    offsets[name] = out.length;
    final lh = BytesBuilder();
    lh.add(_le32(0x04034b50));
    lh.add(_le16(20)); // version needed
    lh.add(_le16(0)); // flags
    lh.add(_le16(0)); // method: stored
    lh.add(_le16(0)); // time
    lh.add(_le16(0)); // date
    lh.add(_le32(crc));
    lh.add(_le32(data.length));
    lh.add(_le32(data.length));
    lh.add(_le16(nameBytes.length));
    lh.add(_le16(0)); // extra
    lh.add(nameBytes);
    lh.add(data);
    out.add(lh.takeBytes());
  });
  entries.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final crc = _crc32(data);
    central.add(_le32(0x02014b50));
    central.add(_le16(20)); // version made by
    central.add(_le16(20)); // version needed
    central.add(_le16(0));
    central.add(_le16(0));
    central.add(_le16(0));
    central.add(_le16(0));
    central.add(_le32(crc));
    central.add(_le32(data.length));
    central.add(_le32(data.length));
    central.add(_le16(nameBytes.length));
    central.add(_le16(0));
    central.add(_le16(0));
    central.add(_le16(0));
    central.add(_le16(0));
    central.add(_le32(0));
    central.add(_le32(offsets[name]!));
    central.add(nameBytes);
  });
  final centralBytes = central.takeBytes();
  final body = out.takeBytes();
  final eocd = BytesBuilder();
  eocd.add(_le32(0x06054b50));
  eocd.add(_le16(0));
  eocd.add(_le16(0));
  eocd.add(_le16(entries.length));
  eocd.add(_le16(entries.length));
  eocd.add(_le32(centralBytes.length));
  eocd.add(_le32(body.length));
  eocd.add(_le16(0));
  return Uint8List.fromList(
      <int>[...body, ...centralBytes, ...eocd.takeBytes()]);
}

List<int> _le16(int v) => <int>[v & 0xff, (v >> 8) & 0xff];
List<int> _le32(int v) => <int>[
      v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff,
    ];

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (~crc) & 0xffffffff;
}

// ---------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------

/// What a `--stamp` argument means: a stamp to look for, a refusal, or "not asked".
class StampState {
  /// The stamp to look for, or null when there is nothing to look for.
  final String? stamp;

  /// Why the argument is unusable, or null when it is fine or absent.
  final String? reason;

  const StampState(this.stamp, this.reason);
}

/// Decide what to do with the `--stamp` argument.
///
/// Split out of [verifyApk] so the self-test can drive the three cases directly instead
/// of only through a whole synthetic archive — `analysis/79` #12 is about this exact
/// decision, and `'abc'.contains('')` is a property of the *argument*, not of the APK.
StampState checkStamp(String? stamp) {
  if (stamp == null) return const StampState(null, null);
  if (stamp.trim().isEmpty) {
    return const StampState(
        null,
        'the build stamp is empty, so there is nothing to look for: '
        "every artefact contains the empty string, and a check that cannot fail is "
        'worse than no check. `tools/task.ps1` produces this when `git` is '
        'unavailable — a build that cannot name itself must not be reported as '
        'identified');
  }
  return StampState(stamp, null);
}

/// Every check performed on one `.apk`.
ApkResult verifyApk(String path, {String? stamp, bool allowDebugSigning = false}) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('no such file: $path');
  }
  final r = ApkResult();
  final bytes = file.readAsBytesSync();
  r.sizeBytes = bytes.length;

  final zip = MiniZip(bytes);
  final entries = zip.entries();
  r.entryCount = entries.length;
  r.stats.add('archive : ${entries.length} entries, '
      '${(bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB');

  // --- 1. the packaged manifest -------------------------------------------
  final manifest =
      entries.where((e) => e.name == 'AndroidManifest.xml').toList();
  if (manifest.isEmpty) {
    r.add('manifest', 'FAIL', 'AndroidManifest.xml is not in the archive');
  } else {
    final m = zip.read(manifest.first);
    // Android's binary XML keeps its strings in a pool, UTF-8 or UTF-16LE. Both
    // encodings are searched because which one is used is aapt2's choice, not ours.
    final ascii = _printableOf(m);
    final utf16 = _utf16Of(m);
    final missing = <String>[];
    for (final p in kRequiredPermissions) {
      if (!ascii.contains(p) && !utf16.contains(p)) missing.add(p);
    }
    r.stats.add('manifest: ${kRequiredPermissions.length} required permissions '
        'searched; ${kRequiredPermissions.length - missing.length} present');
    for (final p in missing) {
      r.add('missing-permission', 'FAIL',
          '$p is not in the packaged AndroidManifest.xml (the *source* manifest '
          'looking right is what this check exists to distrust)');
    }
  }

  // --- 2. test instrumentation --------------------------------------------
  var markerHits = 0;
  for (final e in entries) {
    final isCode = e.name.endsWith('.dex') || e.name.endsWith('.so');
    if (!isCode) continue;
    final data = _printableOf(zip.read(e));
    for (final marker in kForbiddenMarkers) {
      if (data.contains(marker)) {
        r.add('test-instrument', 'FAIL', '$marker in ${e.name}');
        markerHits++;
      }
    }
  }
  r.stats.add('instrument: ${kForbiddenMarkers.length} markers searched across '
      '${entries.where((e) => e.name.endsWith('.dex') || e.name.endsWith('.so')).length} '
      'dex/so entries -> $markerHits hit(s)');

  // --- 3. the build stamp --------------------------------------------------
  //
  // ## Why an empty stamp is refused rather than skipped
  //
  // `'abc'.contains('')` is **true**, so `--stamp ''` used to walk into the "is it in
  // libapp.so?" branch and pass for every artefact in the world — including one with no
  // identity at all. That is `analysis/79` #12, and it is the section-4 failure shape
  // (`the check reports the state of the world and never asserts anything about it`) one
  // step further on: it asserts something that is always true.
  //
  // `tools/task.ps1` produced exactly that stamp on a machine without `git`:
  // `git rev-parse` writes nothing to stdout, and `"$short$dirty"` is then `''` or
  // `-dirty`. So the empty value is not hypothetical, and the two checks that consume it
  // — this one and the PowerShell scan at the end of `Invoke-Build` — both have to refuse
  // it. A build that cannot name itself is a build whose whole point (answering "is this
  // the APK I just made?") is gone, and `--stamp` was supplied by a caller who believes
  // it checked something.
  final stampState = checkStamp(stamp);
  if (stampState.reason != null) {
    r.add('build-stamp', 'FAIL', stampState.reason!);
  } else if (stampState.stamp != null) {
    final s = stampState.stamp!;
    final libs = entries.where((e) => e.name.endsWith('libapp.so')).toList();
    if (libs.isEmpty) {
      r.add('build-stamp', 'FAIL',
          'no libapp.so in the archive, so the build cannot identify itself');
    } else {
      var found = false;
      for (final e in libs) {
        if (_printableOf(zip.read(e), chunk: true).contains(s)) found = true;
      }
      if (!found) {
        r.add('build-stamp', 'FAIL',
            "'$s' is not in libapp.so — the app would show a stale or absent "
            'build identity, and "is this the build I just made?" would be '
            'unanswerable again');
      } else {
        r.stats.add('stamp   : "$s" found in libapp.so');
      }
    }
  } else {
    r.stats.add('stamp   : not checked (no --stamp given)');
  }

  // --- 4. who signed it ----------------------------------------------------
  //
  // Two signatures can be present and they live in different places. A v1 signature
  // is a `META-INF/*.RSA` **zip entry**; a v2/v3 signature is a blob in the APK
  // Signing Block, which is not an entry at all — it sits between the last local
  // header and the central directory. Searching only the entries therefore reported
  // "debug certificate: no" for an APK that `apksigner` calls debug-signed, which is
  // the worst possible outcome for a check like this one. Both places are searched,
  // and the raw file is searched directly because that covers both.
  final sigFiles = entries
      .where((e) =>
          e.name.startsWith('META-INF/') &&
          (e.name.endsWith('.RSA') || e.name.endsWith('.DSA') || e.name.endsWith('.EC')))
      .toList();
  final hasV2V3 = _containsAscii(bytes, 'APK Sig Block 42');
  final fileAscii = _printableOf(bytes);
  final debugSigned = fileAscii.contains(kDebugCertificateMarker);
  final subjects = RegExp(r'CN=[ -~]{1,40}')
      .allMatches(fileAscii)
      .map((m) => m.group(0)!)
      .toSet()
      .take(4)
      .toList();
  r.stats.add('signing : v1 signature files: ${sigFiles.length}; '
      'v2/v3 signing block: ${hasV2V3 ? 'present' : 'absent'}');
  r.stats.add('signing : certificate subject fragment(s) found: '
      '${subjects.isEmpty ? 'none' : subjects.join(' | ')}');
  if (sigFiles.isEmpty && !hasV2V3) {
    r.add('signature', 'FAIL', 'the APK is not signed at all');
  }
  if (debugSigned) {
    r.add('debug-signature', allowDebugSigning ? 'WARN' : 'FAIL',
        'the archive carries "$kDebugCertificateMarker": this APK is signed with '
        'the public Android debug key, so anybody can build an update Android will '
        'accept${allowDebugSigning ? ' (allowed by --allow-debug-signing)' : ''}');
  }
  r.stats.add('signing : debug certificate: ${debugSigned ? 'YES' : 'no'}');

  return r;
}

/// Printable ASCII runs of [data] — how a search sees a binary.
///
/// [chunk] keeps runs short enough that a multi-megabyte `libapp.so` does not turn
/// into one enormous string; a build stamp is a short token and is never split by
/// this, because the runs are only cut at non-printable bytes.
String _printableOf(Uint8List data, {bool chunk = false}) {
  final sb = StringBuffer();
  final run = StringBuffer();
  const limit = 1 << 20;
  for (var i = 0; i < data.length; i++) {
    final b = data[i];
    if (b >= 32 && b < 127) {
      run.writeCharCode(b);
    } else {
      if (run.length >= 4) sb.write(run);
      if (chunk && sb.length > limit) sb.write('\n');
      run.clear();
    }
  }
  if (run.length >= 4) sb.write(run);
  return sb.toString();
}

String _utf16Of(Uint8List data) {
  final sb = StringBuffer();
  for (var i = 0; i + 1 < data.length; i += 2) {
    final c = data[i] | (data[i + 1] << 8);
    if (c >= 32 && c < 127) {
      sb.writeCharCode(c);
    } else {
      sb.write('\n');
    }
  }
  return sb.toString();
}

bool _containsAscii(Uint8List data, String needle) {
  final n = ascii.encode(needle);
  outer:
  for (var i = 0; i + n.length <= data.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (data[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Self-test
// ---------------------------------------------------------------------------

int runSelfTest() {
  final tmp = Directory.systemTemp.createTempSync('yim1-apkselftest-');
  try {
    // A manifest whose string pool is UTF-8 and holds all but one permission, an AOT
    // library carrying an instrument marker and no stamp, and a v1 signature block
    // holding the debug certificate's subject.
    final missing = kRequiredPermissions.last;
    final manifestText =
        '<manifest>${kRequiredPermissions.where((p) => p != missing).map((p) => '<uses-permission android:name="$p"/>').join()}</manifest>';
    final libapp = <int>[
      ...utf8.encode('some AOT snapshot with FAKE_CAMERA_VERIFICATION_ONLY in it'),
      0,
      ...List<int>.filled(64, 0),
    ];
    final signature = <int>[
      ...utf8.encode('0\x82\x01\x00 CN=$kDebugCertificateMarker,O=Android,C=US'),
      0,
    ];
    final apkBytes = buildStoredZip(<String, List<int>>{
      'AndroidManifest.xml': utf8.encode(manifestText),
      'classes.dex': utf8.encode('dex\n035\x00 some bytecode'),
      'lib/arm64-v8a/libapp.so': libapp,
      'META-INF/CERT.RSA': signature,
    });
    final apk = File('${tmp.path}${Platform.pathSeparator}probe.apk')
      ..writeAsBytesSync(apkBytes);

    final r = verifyApk(apk.path, stamp: 'abc1234');
    final details = r.findings.map((f) => '${f.check}|${f.detail}').join('\n');
    final checks = r.findings.map((f) => f.check).toSet();
    final problems = <String>[];
    if (!checks.contains('missing-permission')) {
      problems.add('the missing permission was not reported');
    }
    if (!details.contains(missing)) {
      problems.add('the report did not name $missing');
    }
    if (!checks.contains('test-instrument')) {
      problems.add('the instrument marker was not reported');
    }
    if (!checks.contains('build-stamp')) {
      problems.add('the absent build stamp was not reported');
    }
    if (!checks.contains('debug-signature')) {
      problems.add('the debug certificate was not reported');
    }

    // The **empty** stamp, which is a different hazard from the absent one and the one
    // `analysis/79` #12 found: `'abc'.contains('')` is true, so an empty `--stamp` used
    // to certify every artefact in the world — including `good.apk`, which carries the
    // stamp `abc1234` and therefore could not have satisfied a real lookup for `''` in
    // any meaningful sense. Asserted twice: on the argument, and end to end on that
    // artefact, so removing `checkStamp` from the call path fails the self-test too.
    for (final empty in <String>['', '   ']) {
      final s = checkStamp(empty);
      if (s.reason == null || s.stamp != null) {
        problems.add('an empty stamp argument was accepted '
            '(${jsonEncode(empty)} -> stamp ${s.stamp}, reason ${s.reason})');
      }
    }
    if (checkStamp('abc1234').stamp != 'abc1234') {
      problems.add('a real stamp argument was refused');
    }
    if (checkStamp(null).stamp != null || checkStamp(null).reason != null) {
      problems.add('an absent stamp argument was treated as a hazard');
    }

    // And the other direction: the same archive with nothing wrong in it, plus the
    // debug signature explicitly allowed, must be clean apart from that warning.
    final goodManifest =
        '<manifest>${kRequiredPermissions.map((p) => '<uses-permission android:name="$p"/>').join()}</manifest>';
    final goodApk = File('${tmp.path}${Platform.pathSeparator}good.apk')
      ..writeAsBytesSync(buildStoredZip(<String, List<int>>{
        'AndroidManifest.xml': utf8.encode(goodManifest),
        'classes.dex': utf8.encode('dex\n035\x00 some bytecode'),
        'lib/arm64-v8a/libapp.so': <int>[
          ...utf8.encode('some AOT snapshot stamped abc1234'),
          ...List<int>.filled(64, 0),
        ],
        'META-INF/CERT.RSA': signature,
      }));
    final good = verifyApk(goodApk.path,
        stamp: 'abc1234', allowDebugSigning: true);
    if (good.fails.isNotEmpty) {
      problems.add('a clean archive was reported dirty: '
          '${good.fails.map((f) => '${f.check}: ${f.detail}').join('; ')}');
    }

    // The end-to-end half of the empty-stamp hazard: `good.apk` carries `abc1234`, so a
    // lookup for `''` must be refused rather than satisfied. Without this, deleting
    // `checkStamp` from [verifyApk]'s call path would leave the argument unit cases above
    // passing while the check went back to certifying everything.
    final emptyStamp =
        verifyApk(goodApk.path, stamp: '', allowDebugSigning: true);
    if (!emptyStamp.fails.any((f) => f.check == 'build-stamp')) {
      problems.add('an empty --stamp certified a stamped artefact instead of being '
          'refused');
    }

    stdout.writeln('   self-test: hazard apk -> ${r.fails.length} FAIL '
        '(${r.findings.length} finding(s)); clean apk -> ${good.fails.length} FAIL');
    if (problems.isNotEmpty) {
      stderr.writeln('SELF-TEST FAILED: the apk check did not notice what it was '
          'built to notice:');
      for (final p in problems) {
        stderr.writeln('  $p');
      }
      return 1;
    }
    stdout.writeln('   self-test: PASS - missing permission, instrument marker, '
        'absent stamp, empty stamp and debug signature were all reported');
    return 0;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Leftover temp files are not a failure of the check.
    }
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

void main(List<String> argv) {
  String? path;
  String? stamp;
  var allowDebugSigning = false;
  var selfTest = false;

  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--stamp':
        stamp = argv[++i];
      case '--allow-debug-signing':
        allowDebugSigning = true;
      case '--self-test':
        selfTest = true;
      case '--help' || '-h':
        stdout.writeln('usage: dart tool/verify_apk.dart <apk> '
            '[--stamp <stamp>] [--allow-debug-signing]');
        stdout.writeln('       dart tool/verify_apk.dart --self-test');
        exit(0);
      default:
        if (argv[i].startsWith('-')) {
          stderr.writeln('unknown argument: ${argv[i]}');
          exit(2);
        }
        path = argv[i];
    }
  }

  stdout.writeln('apk artifact check');
  if (selfTest) {
    exit(runSelfTest());
  }
  if (path == null) {
    stderr.writeln('no apk given. usage: dart tool/verify_apk.dart <apk> '
        '[--stamp <stamp>]');
    exit(2);
  }

  stdout.writeln('   apk : ${File(path).absolute.path}');
  final ApkResult result;
  try {
    result = verifyApk(path, stamp: stamp, allowDebugSigning: allowDebugSigning);
  } on StateError catch (e) {
    stderr.writeln('check could not run: $e');
    exit(2);
  }

  for (final s in result.stats) {
    stdout.writeln('   $s');
  }
  stdout.writeln('');
  final fails = result.fails;
  final warns = result.findings.where((f) => f.severity == 'WARN').toList();
  stdout.writeln('   findings: ${fails.length} FAIL, ${warns.length} warning');
  for (final f in fails) {
    stdout.writeln('   [FAIL] ${f.check}: ${f.detail}');
  }
  for (final f in warns) {
    stdout.writeln('   [warn] ${f.check}: ${f.detail}');
  }
  stdout.writeln('');
  if (fails.isEmpty) {
    stdout.writeln('ARTIFACT OK - the packaged manifest, the instrument markers, '
        'the build stamp and the signature all check out.');
    exit(0);
  }
  stdout.writeln('ARTIFACT REJECTED - ${fails.length} finding(s). Do not distribute.');
  exit(1);
}
