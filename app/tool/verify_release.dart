// Scan a *release* tree for the things that must never be in it.
//
// ## What this is for
//
// The public repository is `yi-m1-controller-app`, and it is produced by
// `tools/release/export_app_release.ps1` from a private development repository that
// keeps the camera's Wi-Fi credentials, a pairing token, a BLE census of about
// 45-55 *other people's* devices, the vendor firmware and the reverse-engineering
// notes. None of that can be un-published, so the rule is "it was never there".
//
// The export script already makes that claim, and it makes it against **its own
// idea** of what it copied. This program is the second, independent reading: it walks
// the tree that actually exists on disk and looks for the shapes. That is the same
// split the export's own rules file describes between `exclude`/`redactions` and
// `deny` - a mistake in selection or redaction has to be *caught*, not trusted.
//
// ## It is also the release repository's leak check, forever
//
// This file ships inside the release tree (`app/tool/verify_release.dart`), because
// the moment that repository exists, the interesting question stops being "was the
// export clean" and becomes "is it still clean". A contributor opening a pull request
// that adds a captured log, a test fixture with a real address or a signing key gets a
// red `verify` rather than a review comment somebody has to remember to write.
//
// Nothing here is a *value*. Every rule is a shape - an SSID-shaped token, an
// eight-digit number next to the word "passkey", a MAC address, a machine path, a
// vendor extension - so this file is safe to publish, which is the whole point of
// doing it this way rather than shipping the export's deny list (which necessarily
// contains the test unit's SSID, passkey, token and MAC).
//
// ## Usage
//
//     cd app
//     dart tool/verify_release.dart                 # scans the repository root (..)
//     dart tool/verify_release.dart --root <dir>    # scans something else
//     dart tool/verify_release.dart --strict        # dangling `analysis/` citations fail
//     dart tool/verify_release.dart --self-test     # negative control: prove the rules bite
//
// Exit codes: 0 = clean · 1 = at least one FAIL · 2 = could not run.
//
// `--self-test` builds a temporary tree containing every hazard on purpose and
// asserts each rule fires; a rule that silently stops matching turns the self-test
// red. That is the check that this check works, and it is wired into the development
// repository's `verify` as the `release` layer.

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Rules. Data, so that the report can say which rule produced which line.
// ---------------------------------------------------------------------------

/// Directory names that never belong in the app-only release.
const List<String> kForbiddenSegments = <String>[
  'analysis',
  'aosp-research',
  'firmware',
  'unpacked',
  'lvprobe',
  'capture_test',
  're',
  'tools',
  '__pycache__',
  '.dart_tool',
  '.gradle',
];

/// File names or extensions that never belong, with the reason.
const Map<String, String> kForbiddenFilePatterns = <String, String>{
  'AGENTS.md': 'the development workflow contract',
  'release-denylist.json': 'the export rules: they name the real credentials',
  'keystore.properties': 'signing key material',
  'key.properties': 'signing key material',
  '.release-export-ok': 'the export script\'s own marker; must be deleted before commit',
};

const List<String> kForbiddenExtensions = <String>[
  '.jks', '.keystore', '.p12', '.pem', '.key', '.pk8',
  '.apk', '.aab', '.dex', '.so', '.img', '.image', '.acv', '.java',
  '.zip', '.jar', '.pdf', '.py', '.pyc', '.ps1', '.sh', '.bat', '.cmd',
  '.log', '.pcap', '.btsnoop', '.mp4', '.dng', '.snoop',
];

/// The few binaries that are allowed despite their extension, each pinned by hash.
///
/// `gradle-wrapper.jar`, `gradlew` and `gradlew.bat` are Gradle's own launcher
/// (Apache-2.0). They are committed so that `./gradlew` works in a fresh clone —
/// Flutter's template gitignores all three, which is why the first export had no
/// working wrapper at all. Pinning the hash means the exception cannot quietly become
/// a place where *a* jar hides: it has to be this one, byte for byte, and these are
/// the same files Flutter injects from
/// `$FLUTTER_ROOT/bin/cache/artifacts/gradle_wrapper`.
const Map<String, String> kPinnedBinaries = <String, String>{
  'app/android/gradle/wrapper/gradle-wrapper.jar':
      '16caeaf66d57a0d1d2087fef6a97efa62de8da69afa5b908f40db35afc4342da',
  'app/android/gradlew':
      'ec56c02543666d92d9ac5ae7fcc48f88ce4de0deb8b7f9b39928ca46f68c1b2b',
  'app/android/gradlew.bat':
      'c13c6e91b9a517783976de213d46398c661ea9e17651376d7301e839eaedcc62',
};

/// Names that are credentials or capture logs whatever their extension.
const List<String> kCredentialFilenameGlobs = <String>[
  'session*.txt', 'pair*.txt', 'bond*.txt', 'ble_diag*.txt',
  'map_state*.txt', 'hci*.txt', '*snoop*', '*.btsnoop', '*.pcap',
];

/// Content rules. `fail: true` stops the check; the rest are shapes that have
/// legitimate code-shaped occurrences and are reported for a human to read.
///
/// [exempt] names files that may mention the rule's shape *because describing or
/// detecting it is their job* — the runbook, the .gitignore policy, the Gradle block
/// that reads the key, and this scanner. The exemption is by exact path and each one
/// has to be justified here; it is not a directory-wide escape hatch.
class ContentRule {
  final String id;
  final RegExp pattern;
  final bool fail;
  final String why;
  final Set<String> exempt;
  ContentRule(this.id, this.pattern, this.fail, this.why,
      {this.exempt = const <String>{}});
}

/// The maintainer's account and development-repository names, assembled rather than
/// written out: this file must be able to search for them without containing them, or
/// the scan reports itself.
final String _accountPattern = '${'Guan' 'cheng'}|${'xiaoyi' 'fwmod'}';

final List<ContentRule> kContentRules = <ContentRule>[
  ContentRule('known-camera-ssid-shape', RegExp(r'YI_M1_[0-9a-f]{6}'), true,
      'the test unit\'s SSID shape: six lowercase hex digits after the prefix'),
  ContentRule(
      'signing-key-material',
      RegExp(r'storePassword|keyPassword|keyAlias'
          r'|-----BEGIN [A-Z ]*PRIVATE KEY-----'),
      true,
      'signing key material cannot be un-published',
      exempt: const <String>{
        'README.md', // it has to tell a contributor that a release build needs a key
        'README.zh-CN.md', // the same paragraph, translated: it names the four fields
        'RELEASING.md', // the runbook: it has to name the fields
        'app/android/.gitignore', // the policy that keeps keys out
        'app/android/app/build.gradle.kts', // the code that reads the key
        'app/tool/verify_release.dart', // this rule, and its self-test
        'app/tool/verify_apk.dart', // the debug-signature marker
      }),
  ContentRule('machine-user-path', RegExp(_accountPattern), true,
      'a path naming the maintainer\'s account or the development repository',
      exempt: const <String>{'app/tool/verify_release.dart'}),
  ContentRule('other-peoples-device-names',
      RegExp(r'\b(?:LAPTOP|DESKTOP)-[A-Za-z0-9]{4,}'), true,
      'a hostname from the BLE census is somebody else\'s device',
      exempt: const <String>{'app/tool/verify_release.dart'}),
  ContentRule('known-passkey-length-near-credential-word',
      RegExp(r'\b(ssid|passkey|passphrase|credentials?|pairing[_ ]?token)\b'
          r'[^\n]{0,60}\b\d{8}\b'
          r'|\b\d{8}\b[^\n]{0,60}\b(ssid|passkey|passphrase|credentials?|pairing[_ ]?token)\b',
          caseSensitive: false),
      false, 'an eight-digit number beside a credential word'),
  ContentRule('ssid-shaped-token', RegExp(r'YI_M1_[A-Za-z0-9]{4,}'), false,
      'an SSID-shaped token; the placeholder and the fixtures are expected here'),
  ContentRule('ssid-assignment',
      RegExp(r'''\bssid\b\s*[:=]\s*["']?[A-Za-z0-9_.-]{4,32}''',
          caseSensitive: false),
      false, 'a field or literal named ssid'),
  ContentRule('mac-address', RegExp(r'\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b'),
      false, 'a MAC-shaped address; the fixtures use obvious placeholders',
      exempt: const <String>{'app/tool/verify_release.dart'}),
  ContentRule('absolute-windows-path', RegExp(r'\b[A-Za-z]:\\'), false,
      'one machine\'s filesystem layout; repository content should be relative'),
];

/// Anything bigger than this is not app source.
const int kMaxFileBytes = 4 * 1024 * 1024;

/// A guard against a vendor blob arriving inside something legitimate.
const int kMaxTreeBytes = 25 * 1024 * 1024;

/// Files without which the tree is not the application. A missing entry here is the
/// failure mode an allow-list exists to produce: silence replaced by a red check.
const List<String> kRequiredFiles = <String>[
  'LICENSE',
  'NOTICE',
  'README.md',
  // The Chinese README is a published document, not a convenience: the camera is a
  // Chinese product and the maintainer's first language is Chinese, so a tree that
  // dropped it would still pass every other check here. It was missing from this list
  // (and from the exporter's root allow list) until 0.2.1, which is why the export
  // refused the tree the first time it was added to `tools/release/metadata/`.
  'README.zh-CN.md',
  'CHANGELOG.md',
  'CONTRIBUTING.md',
  'SECURITY.md',
  'RELEASING.md',
  '.editorconfig',
  '.gitignore',
  'app/pubspec.yaml',
  'app/pubspec.lock',
  'app/analysis_options.yaml',
  'app/l10n.yaml',
  'app/lib/main.dart',
  'app/lib/app.dart',
  'app/lib/l10n/app_en.arb',
  'app/lib/l10n/app_zh.arb',
  // Generated, and committed anyway: `lib/l10n/l10n.dart` imports it, so a fresh
  // clone cannot analyze or build without it. See the repository's `.gitignore`.
  'app/lib/l10n/gen/app_localizations.dart',
  'app/lib/protocol/http_commands.dart',
  'app/lib/protocol/viewfinder_layout.dart',
  'app/lib/ui/licences.dart',
  'app/docs/PROTOCOL.md',
  'app/README.md',
  'app/android/app/build.gradle.kts',
  'app/android/gradle.properties',
  'app/android/gradle/wrapper/gradle-wrapper.properties',
  'app/android/gradle/wrapper/gradle-wrapper.jar',
  'app/android/gradlew',
  'app/android/gradlew.bat',
  'app/android/app/src/main/AndroidManifest.xml',
  'app/test/fakes.dart',
  'app/test/l10n_arb_test.dart',
  'app/test/licences_page_test.dart',
  'app/tool/verify.dart',
  'app/tool/verify_release.dart',
  'app/tool/verify_apk.dart',
  'app/tool/conformance.dart',
  'app/tool/verify_transport.dart',
  'app/tool/verify_sync.dart',
  'app/testdata/liveview/pack_000.bin',
  'app/testdata/liveview/pack_039.bin',
];

/// Paths whose *absence* is also a check. The release tree must not have grown these
/// back, and naming them here means an export that starts copying them again is
/// caught by the shipped check rather than only by the export's own rules.
const List<String> kForbiddenPaths = <String>[
  'analysis',
  'firmware',
  'unpacked',
  'aosp-research',
  'AGENTS.md',
  'build',
  'app/re',
  'app/tools',
  'app/build',
  'app/lvprobe',
  'app/liveview',
  'app/capture_test',
  'app/docs/HARDWARE-VERIFICATION.md',
  'app/docs/VERIFICATION-RESULTS.md',
  'app/docs/APP-PLAN.md',
];

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

class Finding {
  final String check;
  final String severity; // FAIL | WARN | INFO
  final String detail;
  const Finding(this.check, this.severity, this.detail);
}

class ScanResult {
  final List<Finding> findings = <Finding>[];
  final List<String> stats = <String>[];
  final List<String> notes = <String>[];
  int files = 0;
  int bytes = 0;
  /// `tracked` = the file list came from git, which is the authoritative answer to
  /// "what would be published". `filesystem` = there is no git repository here yet.
  String mode = 'filesystem';
  int skippedGenerated = 0;

  void add(String check, String severity, String detail) =>
      findings.add(Finding(check, severity, detail));

  List<Finding> get fails =>
      findings.where((f) => f.severity == 'FAIL').toList();
}

/// Directories and files that are build output rather than repository content.
///
/// Only used in the filesystem fallback. In tracked mode nothing is skipped: the
/// question is what git would publish, and git already knows.
const List<String> kGeneratedPaths = <String>[
  '.dart_tool',
  'build',
  '.gradle',
  '.idea',
  '.flutter-plugins-dependencies',
  'l10n_untranslated.json',
  'app/.dart_tool',
  'app/build',
  'app/.flutter-plugins-dependencies',
  'app/l10n_untranslated.json',
  'app/android/.gradle',
  'app/android/local.properties',
  'app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
];

/// The files git would publish under [rootPath], or null if this is not a work tree.
///
/// This is the difference between "the repository is clean" and "this directory
/// happens to look clean": `flutter pub get` and `flutter test` write `.dart_tool/`
/// and `app/build/` full of absolute paths and multi-megabyte caches, and a scan that
/// read those would report a working checkout as a leak while a scan that ignored
/// them by pattern could miss a committed one. Asking git removes both problems.
List<String>? gitTrackedFiles(String rootPath) {
  try {
    final r = Process.runSync(
      'git',
      <String>['-C', rootPath, 'ls-files', '-z'],
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    if (r.exitCode != 0) return null;
    final out = r.stdout;
    if (out is! List<int>) return null;
    final text = utf8.decode(out, allowMalformed: true);
    final paths =
        text.split('\u0000').where((p) => p.isNotEmpty).toList();
    return paths.isEmpty ? null : paths;
  } on ProcessException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// The scan
// ---------------------------------------------------------------------------

ScanResult scanTree(String rootPath) {
  final r = ScanResult();
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    throw StateError('no such directory: $rootPath');
  }

  final files = <File>[];
  final tracked = gitTrackedFiles(rootPath);
  if (tracked != null) {
    r.mode = 'tracked';
    for (final rel in tracked) {
      final f = File(_join(rootPath, rel));
      if (f.existsSync()) files.add(f);
    }
  } else {
    r.mode = 'filesystem';
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = _rel(rootPath, e.path);
      // `.git` is not content. It only exists if somebody has already initialised the
      // repository in place, which is a legitimate state for this check to run in.
      if (rel == '.git' || rel.startsWith('.git/')) continue;
      if (kGeneratedPaths.any((g) => rel == g || rel.startsWith('$g/'))) {
        r.skippedGenerated++;
        continue;
      }
      files.add(e);
    }
    r.add(
        'scan-mode',
        'WARN',
        'not a git work tree, so build output was skipped by pattern '
        '(${r.skippedGenerated} file(s) under ${kGeneratedPaths.join(", ")}) and '
        'this scan cannot tell a committed file from a stray one. Run `git add -A` '
        'first for the authoritative answer: the published repository is the commit, '
        'not the directory.');
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  r.files = files.length;
  r.stats.add('scan mode      : ${r.mode}'
      '${r.mode == 'filesystem' ? ' (${r.skippedGenerated} generated file(s) skipped)' : ' — git lists exactly what would be published'}');

  // --- 1. paths ------------------------------------------------------------
  var pathHits = 0;
  for (final f in files) {
    final rel = _rel(rootPath, f.path);
    final segments = rel.split('/');
    for (var i = 0; i < segments.length - 1; i++) {
      if (kForbiddenSegments.contains(segments[i])) {
        r.add('forbidden-path', 'FAIL',
            '$rel (directory segment \'${segments[i]}\')');
        pathHits++;
      }
    }
    final name = segments.last;
    final ext = _ext(name);
    if (kForbiddenFilePatterns.containsKey(name)) {
      r.add('forbidden-path', 'FAIL',
          '$rel (${kForbiddenFilePatterns[name]})');
      pathHits++;
    }
    if (kForbiddenExtensions.contains(ext) && !kPinnedBinaries.containsKey(rel)) {
      r.add('forbidden-path', 'FAIL',
          '$rel (a $ext file has no business in an app-only release)');
      pathHits++;
    }
  }
  r.stats.add('paths          : ${files.length} files scanned for '
      '${kForbiddenSegments.length} forbidden directory names, '
      '${kForbiddenFilePatterns.length} forbidden file names and '
      '${kForbiddenExtensions.length} forbidden extensions -> $pathHits hit(s)');

  // --- 2. credential file names -------------------------------------------
  var nameHits = 0;
  for (final f in files) {
    final rel = _rel(rootPath, f.path);
    final name = rel.split('/').last;
    for (final glob in kCredentialFilenameGlobs) {
      if (_globMatch(glob, name)) {
        r.add('credential-filename', 'FAIL', '$rel (matches $glob)');
        nameHits++;
      }
    }
  }
  r.stats.add('credential names: ${kCredentialFilenameGlobs.length} patterns '
      'checked across ${files.length} files -> $nameHits hit(s)');

  // --- 3. sizes, the pinned wrapper hash, and the total ---------------------
  var sizeHits = 0;
  var total = 0;
  final sized = <MapEntry<String, int>>[];
  for (final f in files) {
    final rel = _rel(rootPath, f.path);
    final len = f.lengthSync();
    total += len;
    sized.add(MapEntry(rel, len));
    if (len > kMaxFileBytes) {
      r.add('oversize-file', 'FAIL',
          '$rel is ${_mb(len)} MB (limit ${_mb(kMaxFileBytes)} MB)');
      sizeHits++;
    }
    if (kPinnedBinaries.containsKey(rel)) {
      final sha = _sha256OfFile(f);
      final expected = kPinnedBinaries[rel]!;
      if (sha != expected) {
        r.add('pinned-binary-hash', 'FAIL',
            '$rel is $sha, not the pinned $expected');
        sizeHits++;
      } else {
        r.notes.add('$rel matches its pinned sha256');
      }
    }
  }
  r.bytes = total;
  sized.sort((a, b) => b.value.compareTo(a.value));
  final largest = sized.take(5).map((e) => '${e.key} (${_mb(e.value)} MB)');
  r.stats.add('size           : ${_mb(total)} MB total; largest five: '
      '${largest.join(', ')}');
  if (total > kMaxTreeBytes) {
    r.add('tree-size', 'FAIL',
        'the tree is ${_mb(total)} MB, above the ${_mb(kMaxTreeBytes)} MB guard');
    sizeHits++;
  }
  r.stats.add('size guard     : limit ${_mb(kMaxFileBytes)} MB per file, '
      '${_mb(kMaxTreeBytes)} MB per tree -> $sizeHits hit(s)');

  // --- 4. content ----------------------------------------------------------
  final texts = <String, String>{};
  var contentFails = 0;
  for (final rule in kContentRules) {
    var count = 0;
    final examples = <String>[];
    for (final f in files) {
      final rel = _rel(rootPath, f.path);
      if (rule.exempt.contains(rel)) continue;
      final text = texts.putIfAbsent(rel, () => _readSearchable(f));
      if (text.isEmpty) continue;
      final matches = rule.pattern.allMatches(text);
      if (matches.isEmpty) continue;
      count += matches.length;
      if (examples.length < 4) {
        final at = matches.first.start;
        final line = '\n'.allMatches(text.substring(0, at)).length + 1;
        examples.add('$rel line $line');
      }
    }
    if (count > 0) {
      r.add('content', rule.fail ? 'FAIL' : 'WARN',
          '${rule.id}: $count occurrence(s) - ${examples.join('; ')}'
          '${count > examples.length ? ' …' : ''}');
      if (rule.fail) contentFails += count;
    }
    r.stats.add('content        : ${rule.id.padRight(42)} '
        '$count occurrence(s)');
  }

  // --- 5. required files ---------------------------------------------------
  var missing = 0;
  for (final rel in kRequiredFiles) {
    if (!File(_join(rootPath, rel)).existsSync()) {
      r.add('missing-required-file', 'FAIL', '$rel is not in the tree');
      missing++;
    }
  }
  r.stats.add('required files : ${kRequiredFiles.length} checked -> '
      '$missing missing');

  var present = 0;
  for (final rel in kForbiddenPaths) {
    // "Present" means "in the repository", not "on this disk". In tracked mode that
    // is literally the question git answers, and it matters: `flutter test` creates
    // `app/build/` in any working checkout, so a filesystem test would report a
    // clean repository as dirty the moment somebody ran the tests — which is how the
    // first version of this check managed to fail its own release verify.
    final bool isPresent;
    if (tracked != null) {
      isPresent = tracked.contains(rel) ||
          tracked.any((t) => t.startsWith('$rel/'));
    } else {
      if (kGeneratedPaths.any((g) => rel == g || rel.startsWith('$g/'))) continue;
      final p = _join(rootPath, rel);
      isPresent = File(p).existsSync() || Directory(p).existsSync();
    }
    if (isPresent) {
      r.add('forbidden-path-present', 'FAIL', '$rel is present');
      present++;
    }
  }
  r.stats.add('forbidden paths: ${kForbiddenPaths.length} checked -> '
      '$present present');

  // --- 6. version coherence ------------------------------------------------
  final pubspec = File(_join(rootPath, 'app/pubspec.yaml'));
  if (pubspec.existsSync()) {
    final version = _pubspecVersion(pubspec.readAsStringSync());
    if (version == null) {
      r.add('version', 'FAIL', 'app/pubspec.yaml has no parsable version:');
    } else {
      final name = version.split('+').first;
      final changelog = File(_join(rootPath, 'CHANGELOG.md'));
      final changelogText =
          changelog.existsSync() ? changelog.readAsStringSync() : '';
      if (version == '0.1.0+1') {
        r.add('version', 'FAIL',
            'pubspec still says 0.1.0+1, the version this project had before the '
            'first release; the tag/pubspec/artifact identity check in '
            'analysis/63 §2 is unsatisfiable at that number');
      }
      if (!changelogText.contains(name)) {
        r.add('version', 'FAIL',
            'CHANGELOG.md never mentions $name, the version pubspec.yaml declares');
      }
      r.stats.add('version        : pubspec $version; CHANGELOG mentions '
          '${changelogText.contains(name) ? 'it' : 'NOT it'}');
    }
  }

  // --- 7. the release build must not be debug-signed by default ------------
  final gradle = File(_join(rootPath, 'app/android/app/build.gradle.kts'));
  if (gradle.existsSync()) {
    final text = gradle.readAsStringSync();
    if (text.contains('TODO: Add your own signing config')) {
      r.add('release-signing', 'FAIL',
          'app/android/app/build.gradle.kts still carries the Flutter template\'s '
          '"TODO: Add your own signing config" — the release signing question has '
          'not been answered in this tree');
    }
    if (!text.contains('Release build refused')) {
      r.add('release-signing', 'FAIL',
          'app/android/app/build.gradle.kts has no loud failure for a missing '
          'release key, so a release build can be debug-signed while reporting '
          'success (analysis/63 §6)');
    }
  }

  // --- 8. .gitignore traps -------------------------------------------------
  // The tree is going to be committed with `git add -A`, so a .gitignore that
  // excludes a file the tree needs turns a green export into a repository that
  // cannot be cloned and built.
  final ignores = <String, List<String>>{};
  for (final f in files) {
    final rel = _rel(rootPath, f.path);
    if (rel.split('/').last != '.gitignore') continue;
    final dir = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
    ignores[dir] = f
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
  }
  var ignoreHits = 0;
  for (final needed in kPinnedBinaries.keys) {
    final dir = needed.substring(0, needed.lastIndexOf('/'));
    final base = needed.split('/').last;
    for (final entry in ignores.entries) {
      // A .gitignore only applies to its own directory and below.
      if (dir != entry.key && !dir.startsWith('${entry.key}/')) continue;
      for (final pattern in entry.value) {
        if (pattern.startsWith('!')) continue;
        if (_ignoreMatches(pattern, base, dir, entry.key)) {
          r.add('gitignore-trap', 'FAIL',
              '${entry.key.isEmpty ? '.' : entry.key}/.gitignore has '
              '"$pattern", which excludes $needed — `git add -A` would leave it '
              'behind and the repository would not build');
          ignoreHits++;
        }
      }
    }
  }
  // The inverse: whatever the development repository does, the release repository
  // must keep ignoring signing material.
  for (final entry in ignores.entries) {
    for (final pattern in entry.value) {
      if (pattern == '!keystore.properties' || pattern == '!keystore/*.jks') {
        r.add('gitignore-trap', 'FAIL',
            '${entry.key.isEmpty ? '.' : entry.key}/.gitignore has "$pattern": '
            'this repository must never track a signing key');
        ignoreHits++;
      }
    }
  }
  r.stats.add('gitignore traps: ${ignores.length} .gitignore file(s) checked '
      'against the build entry points -> $ignoreHits hit(s)');

  // --- 9. citations to material that is not published ----------------------
  var refs = 0;
  final refFiles = <String>[];
  for (final f in files) {
    final rel = _rel(rootPath, f.path);
    if (!rel.startsWith('app/')) continue;
    final text = texts.putIfAbsent(rel, () => _readSearchable(f));
    final n = RegExp('analysis/').allMatches(text).length;
    if (n > 0) {
      refs += n;
      refFiles.add('$rel ($n)');
    }
  }
  r.stats.add('design refs    : $refs citation(s) to \'analysis/\' inside app/');
  r.notes.add('$refs citation(s) to analysis/ in app/ comments; README.md explains that '
      'the notes are not published (${refFiles.take(6).join(', ')}'
      '${refFiles.length > 6 ? ' …' : ''})');

  // Keep the reference count visible to callers for --strict.
  r.add('analysis-reference', refs > 0 ? 'INFO' : 'INFO',
      '$refs citation(s) to material that is not published');

  return r;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _rel(String root, String path) {
  var p = path.replaceAll('\\', '/');
  var r = root.replaceAll('\\', '/');
  if (r.endsWith('/')) r = r.substring(0, r.length - 1);
  if (p.startsWith('$r/')) p = p.substring(r.length + 1);
  return p;
}

String _join(String root, String rel) =>
    '$root${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i <= 0 ? '' : name.substring(i).toLowerCase();
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(2);

/// Reads a file as searchable text.
///
/// Text files are decoded directly. Anything else — a `.png`, a `.bin`, a jar — has
/// its printable ASCII runs extracted, so a credential embedded in a binary is still
/// visible to these rules. That matters: the interesting leak is not always a `.txt`.
String _readSearchable(File f) {
  final bytes = f.readAsBytesSync();
  final ext = _ext(f.path.split(Platform.pathSeparator).last);
  const textExts = <String>{
    '.dart', '.kt', '.kts', '.gradle', '.xml', '.md', '.json', '.yaml', '.yml',
    '.txt', '.properties', '.arb', '.html', '.css', '.js', '.toml', '.lock',
    '.gitignore', '.editorconfig', '.metadata', '.pro', '.sh', '.bat', '.csv',
  };
  final looksText = textExts.contains(ext) ||
      f.path.split(Platform.pathSeparator).last.startsWith('.') ||
      !bytes.contains(0);
  if (looksText) {
    return utf8.decode(bytes, allowMalformed: true);
  }
  final sb = StringBuffer();
  final run = StringBuffer();
  for (final b in bytes) {
    if (b >= 32 && b < 127) {
      run.writeCharCode(b);
    } else {
      if (run.length >= 5) sb.writeln(run.toString());
      run.clear();
    }
  }
  if (run.length >= 5) sb.writeln(run.toString());
  return sb.toString();
}

String _sha256OfFile(File f) {
  // A tiny SHA-256 so this file has no dependencies. It is the same construction the
  // rest of the project uses in Dart-only tools.
  return _sha256Hex(f.readAsBytesSync());
}

/// Minimal glob matching for the patterns this file uses: `*`, `?`, and `**`.
bool _globMatch(String glob, String name) {
  final re = RegExp('^${glob.split('*').map(RegExp.escape).join('.*')}\$');
  return re.hasMatch(name);
}

/// Does [pattern] from a `.gitignore` in [ignoreDir] exclude [base] in [dir]?
///
/// Deliberately narrow: it understands the forms that appear in this project
/// (`name`, `/name`, `**/name`, `dir/name`) and treats anything else as
/// non-matching, because a false positive here would be a red check about a file
/// that is in fact committed.
bool _ignoreMatches(String pattern, String base, String dir, String ignoreDir) {
  if (pattern.contains('*')) {
    final stripped = pattern.startsWith('**/') ? pattern.substring(3) : pattern;
    if (_globMatch(stripped, base)) return true;
    if (_globMatch(pattern, base)) return true;
    return false;
  }
  final p = pattern.startsWith('/') ? pattern.substring(1) : pattern;
  if (p == base) return true;
  // A pattern with a slash is relative to the .gitignore's own directory.
  final relFromIgnore = dir == ignoreDir
      ? base
      : '${dir.substring(ignoreDir.isEmpty ? 0 : ignoreDir.length + 1)}/$base';
  return p == relFromIgnore && p.contains('/');
}

String? _pubspecVersion(String pubspec) {
  for (final line in pubspec.split('\n')) {
    final t = line.trim();
    if (t.startsWith('version:')) {
      return t.substring('version:'.length).trim().replaceAll('"', '');
    }
  }
  return null;
}

// --- SHA-256 (no dependencies) ---------------------------------------------

const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

String _sha256Hex(List<int> message) {
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final ml = message.length * 8;
  final withPad = <int>[...message, 0x80];
  while (withPad.length % 64 != 56) {
    withPad.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    withPad.add((ml >> (8 * i)) & 0xff);
  }
  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < withPad.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] = (withPad[j] << 24) |
          (withPad[j + 1] << 16) |
          (withPad[j + 2] << 8) |
          withPad[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final sb = StringBuffer();
  for (final x in h) {
    sb.write(x.toRadixString(16).padLeft(8, '0'));
  }
  return sb.toString();
}

int _rotr(int x, int n) =>
    ((x >> n) | (x << (32 - n))) & 0xffffffff;

// ---------------------------------------------------------------------------
// Self-test: the negative control
// ---------------------------------------------------------------------------

/// Builds a tree full of hazards and asserts that each rule fires.
///
/// Without this, every rule above could stop matching — a regex typo, a renamed
/// directory, a walk that finds nothing — and the scan would report a clean tree
/// forever. `AGENTS.md` §8 calls that "a green check that checks nothing", and the
/// project has already paid for that lesson twice (an all-transparent golden image,
/// and a firmware layer that passed in 0.2s having run nothing).
int runSelfTest() {
  final tmp = Directory.systemTemp.createTempSync('yim1-relselftest-');
  try {
    void write(String rel, String content) {
      final f = File(_join(tmp.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    // A tree with nothing in it, which also proves the rules are not simply
    // "everything fails". The only findings allowed here are the required-file ones:
    // an empty tree genuinely is missing the application.
    final clean = Directory(_join(tmp.path, 'clean'))..createSync(recursive: true);
    final cleanFile = File(_join(clean.path, 'app/lib/main.dart'));
    cleanFile.parent.createSync(recursive: true);
    cleanFile.writeAsStringSync('void main() {}\n');
    final cleanResult = scanTree(clean.path);
    final unexpected = cleanResult.fails
        .where((f) => f.check != 'missing-required-file')
        .toList();
    if (unexpected.isNotEmpty) {
      stderr.writeln('SELF-TEST FAILED: a tree with no hazards in it was reported '
          'as dirty:');
      for (final f in unexpected.take(5)) {
        stderr.writeln('  ${f.check}: ${f.detail}');
      }
      return 1;
    }

    // Deliberately not the real values: the point is the *shape*. Using the real ones
    // would bake a credential into a file that ships.
    //
    // The planted strings are assembled from fragments for the same reason a scanner
    // must not contain what it looks for: written whole, they would be found in *this*
    // file by the very rules they are meant to exercise, and the export would fail on
    // its own self-test.
    const dash = '-';
    final hazards = <String, String>{
      'app/lib/leak_ssid.dart': '// the test unit broadcasts YI_M1_${'0a1b2c'}\n',
      'app/lib/leak_key.dart': 'store${'Password'}=hunter2\n',
      'app/lib/leak_path.dart': 'const p = "C:\\Users\\${'Guan' 'cheng'}\\work";\n',
      'app/lib/leak_host.dart': '// seen: LAPTOP$dash${'A1B2C3D4'} nearby\n',
      'app/lib/leak_mac.dart': '// addr: ${'11:22:33:44:55'}:66\n',
      'app/lib/leak_eight.dart': '// passkey ${'12345678'} was accepted\n',
      'app/lib/leak_pem.dart': '-----BEGIN PRIVATE ${'KEY'}-----\n',
      'analysis/63-release-readiness.md': 'notes\n',
      'firmware/patched/firmware.bin': 'not really firmware\n',
      'app/android/keystore.properties': 'storeFile=x\n',
      'app/android/keystore/key.jks': 'binary-ish\n',
      // Not under `build/`: in the filesystem fallback that directory is treated as
      // generated output, so a hazard planted there would be skipped and the
      // self-test would report a rule that never fired — which is exactly what it is
      // for, but the wrong reason to see it.
      'capture_logs/session.txt': 'ssid=YI_M1_${'0a1b2c'} passkey\n',
      'app/AGENTS.md': 'workflow\n',
      'app/lib/huge_payload.dart': 'x' * (5 * 1024 * 1024),
      'vendor/firmware.image': 'image\n',
      // The tree is committed with `git add -A`, so a .gitignore that excludes the
      // files the tree needs is its own class of defect — and the negation is the
      // exact line the development repository carries and the release repository
      // must not.
      'app/android/.gitignore': 'gradlew\ngradle-wrapper.jar\n!keystore.properties\n',
      'app/pubspec.yaml': 'name: x\nversion: 0.1.0+1\n',
      'CHANGELOG.md': '# changelog\n',
      'app/android/app/build.gradle.kts':
          '// TODO: Add your own signing config for the release build.\n',
    };
    final dirty = Directory(_join(tmp.path, 'dirty'));
    hazards.forEach((rel, content) => write('dirty/$rel', content));

    final dirtyResult = scanTree(dirty.path);
    final fired = <String>{};
    for (final f in dirtyResult.findings) {
      if (f.severity == 'FAIL' || f.severity == 'WARN') fired.add(f.check);
    }
    // Each of these has to have produced *something*, and the FAIL-class rules have to
    // have produced a FAIL rather than a WARN.
    const expectedFailChecks = <String>[
      'forbidden-path',
      'credential-filename',
      'oversize-file',
      'content',
      'forbidden-path-present',
      'gitignore-trap',
      'version',
      'release-signing',
    ];
    const expectedFailRules = <String>[
      'known-camera-ssid-shape',
      'signing-key-material',
      'machine-user-path',
      'other-peoples-device-names',
    ];
    final failDetails = dirtyResult.fails.map((f) => '${f.check}|${f.detail}').join('\n');
    final problems = <String>[];
    for (final c in expectedFailChecks) {
      if (!fired.contains(c)) problems.add('check "$c" never fired');
    }
    for (final r in expectedFailRules) {
      if (!failDetails.contains(r)) problems.add('rule "$r" did not FAIL');
    }
    if (!failDetails.contains('keystore.properties')) {
      problems.add('the keystore properties file was not reported');
    }
    if (!failDetails.contains('.jks')) {
      problems.add('a .jks file was not reported');
    }
    for (final rule in <String>['machine-user-path', 'known-camera-ssid-shape']) {
      if (!failDetails.contains(rule)) {
        problems.add('rule "$rule" was not reported as a FAIL');
      }
    }

    stdout.writeln('   self-test: clean tree -> ${cleanResult.fails.length} FAIL, '
        'hazard tree -> ${dirtyResult.fails.length} FAIL, '
        '${dirtyResult.findings.length} finding(s) total');
    stdout.writeln('   self-test: ${hazards.length} hazards planted, '
        '${fired.length} distinct checks fired');
    if (problems.isNotEmpty) {
      stderr.writeln('SELF-TEST FAILED: the scan did not notice what it was built '
          'to notice:');
      for (final p in problems) {
        stderr.writeln('  $p');
      }
      return 1;
    }
    stdout.writeln('   self-test: PASS - every planted hazard was reported');
    return 0;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temp directory is not a failure of the check.
    }
  }
}

String _selfTestVersionMarker() => 'self-test';

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

void main(List<String> argv) {
  var root = Directory.current.path;
  if (File('${Directory.current.path}${Platform.pathSeparator}pubspec.yaml')
      .existsSync()) {
    // Run from `app/`: the repository root is one level up.
    root = Directory.current.parent.path;
  }
  var strict = false;
  var selfTest = false;

  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--root':
        root = argv[++i];
      case '--strict':
        strict = true;
      case '--self-test':
        selfTest = true;
      case '--help' || '-h':
        stdout.writeln('usage: dart tool/verify_release.dart '
            '[--root <dir>] [--strict] [--self-test]');
        exit(0);
      default:
        stderr.writeln('unknown argument: ${argv[i]}');
        exit(2);
    }
  }

  stdout.writeln('release tree scan');
  stdout.writeln('   tree: ${Directory(root).absolute.path}');

  if (selfTest) {
    exit(runSelfTest());
  }

  final ScanResult result;
  try {
    result = scanTree(root);
  } on StateError catch (e) {
    stderr.writeln('scan could not run: $e');
    exit(2);
  }

  stdout.writeln('   files: ${result.files}   size: ${_mb(result.bytes)} MB');
  for (final s in result.stats) {
    stdout.writeln('   $s');
  }

  if (strict) {
    final refs = result.findings
        .where((f) => f.check == 'analysis-reference')
        .toList();
    result.findings.removeWhere((f) => f.check == 'analysis-reference');
    for (final f in refs) {
      result.add(f.check, 'FAIL', '${f.detail} (--strict)');
    }
  }

  final fails = result.fails;
  final warns = result.findings.where((f) => f.severity == 'WARN').toList();
  final infos = result.findings.where((f) => f.severity == 'INFO').toList();

  stdout.writeln('');
  stdout.writeln('   findings: ${fails.length} FAIL, ${warns.length} warning, '
      '${infos.length} informational');
  for (final f in fails) {
    stdout.writeln('   [FAIL] ${f.check}: ${f.detail}');
  }
  for (final f in warns) {
    stdout.writeln('   [warn] ${f.check}: ${f.detail}');
  }
  for (final f in infos) {
    stdout.writeln('   [info] ${f.check}: ${f.detail}');
  }
  for (final n in result.notes) {
    stdout.writeln('   note: $n');
  }

  stdout.writeln('');
  if (fails.isEmpty) {
    stdout.writeln('RELEASE TREE CLEAN - nothing the rules look for is present.');
    exit(0);
  }
  stdout.writeln('RELEASE TREE DIRTY - ${fails.length} finding(s). Do not publish.');
  exit(1);
}
