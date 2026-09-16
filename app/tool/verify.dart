// The release repository's one verification command.
//
// ## Why the release repository needs its own
//
// The development repository runs `pwsh tools/task.ps1 verify` — eight layers,
// parallel, about 36 seconds. **None of that machinery is published**: `tools/` is
// development-only, and two of those layers (`audit`, `firmware`) cannot run without
// material the release tree does not contain anyway. So a contributor cloning the
// public repository had *no* verification entry point at all, and the only evidence
// available to them was whatever they chose to type (`analysis/63` §6.1, §12.5).
//
// This is that entry point, rewritten in Dart so it is one command on Windows, macOS
// and Linux rather than one command on Windows. It runs the checks that *can* run
// from a clean checkout, and it says out loud which ones cannot.
//
// ## What it checks
//
//   1. `flutter pub get`            — dependencies resolve
//   2. `dart analyze lib tool test` — the analyzer is clean
//   3. `dart tool/conformance.dart`            — generated tables vs. the protocol
//   4. `dart tool/verify_transport.dart`       — 333 transport assertions, pure VM
//   5. `dart tool/verify_sync.dart`            — 182 sync assertions, pure VM
//   6. `flutter test`               — the widget suite
//   7. `dart tool/verify_release.dart`         — the leak scan over this repository
//   8. `dart tool/verify_apk.dart <apk>`       — only with `--apk`; see below
//
// Steps 3–5 are the project's real logic coverage: they compile and run **without
// Flutter**, which is a hard architectural invariant here (`lib/protocol/`,
// `lib/transport/` and `lib/sync/` must stay drivable from a plain Dart VM). If a
// change drags `package:flutter` into one of them, these steps stop compiling — and
// that is the mechanism, not a comment in a document.
//
// ## What it cannot check, and why that is acceptable
//
//   * **The camera.** The protocol conclusions, the shutter, the album sync and the
//     MediaStore path were established against a real YI M1, and nothing in this
//     repository can re-derive them. They are documented, with confidence markers,
//     in `app/docs/PROTOCOL.md`.
//   * **The firmware work.** The patched firmware, the reverse-engineering tooling
//     and the notes that motivate several code decisions are not published. Comments
//     citing `analysis/NN` are citations to unpublished material, and README.md says
//     so rather than pretending otherwise. The leak scan counts them.
//   * **The Android build assertions.** `flutter build apk` needs the Android SDK,
//     ~20 minutes and a signing key, so it is not part of this command. Run it, then
//     point step 8 at the result: `dart tool/verify.dart --apk build/app/outputs/flutter-apk/app-release.apk`.
//     That step re-checks the eight required permissions in the *packaged* manifest,
//     the absence of test instrumentation and the build stamp, and refuses a
//     debug-signed artifact.
//
// ## Usage
//
//     cd app
//     dart tool/verify.dart
//     dart tool/verify.dart --no-pub          # dependencies already fetched
//     dart tool/verify.dart --apk <path> --stamp <stamp>
//
// Exit code 0 only if every step that ran passed.

import 'dart:io';

/// One step: a command, a description of what it proves, and whether it ran.
class Step {
  final String name;
  final String command;
  final List<String> args;
  final String proves;
  final String? dir;
  Step(this.name, this.command, this.args, this.proves, {this.dir});
}

Future<int> _run(Step step) async {
  stdout.writeln('');
  stdout.writeln('== ${step.name} — ${step.proves}');
  stdout.writeln('   \$ ${step.command} ${step.args.join(' ')}');
  final sw = Stopwatch()..start();
  // `runInShell` is not optional on Windows: `flutter` and `dart` are `.bat` files
  // there, and a process started without a shell cannot execute one. This is the same
  // trap `tools/task.ps1` documents for `gradlew.bat`, where the layer reported
  // success in 0.0 seconds having launched nothing at all.
  final p = await Process.start(
    step.command,
    step.args,
    workingDirectory: step.dir ?? Directory.current.path,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  final code = await p.exitCode;
  sw.stop();
  stdout.writeln('   -> exit $code in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
  return code;
}

Future<void> main(List<String> argv) async {
  var pubGet = true;
  var withAndroid = false;
  String? apk;
  String? stamp;
  var allowDebugSigning = false;

  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--no-pub':
        pubGet = false;
      case '--with-android':
        withAndroid = true;
      case '--apk':
        apk = argv[++i];
      case '--stamp':
        stamp = argv[++i];
      case '--allow-debug-signing':
        allowDebugSigning = true;
      case '--help' || '-h':
        stdout.writeln('usage: dart tool/verify.dart [--no-pub] [--with-android] '
            '[--apk <path>] [--stamp <stamp>] [--allow-debug-signing]');
        exit(0);
      default:
        stderr.writeln('unknown argument: ${argv[i]}');
        exit(2);
    }
  }

  // Run from `app/`. Accepting the repository root as well would mean guessing where
  // the pubspec is, and guessing wrong produces confusing failures rather than a
  // clear one.
  if (!File('pubspec.yaml').existsSync()) {
    stderr.writeln('run this from the `app/` directory (no pubspec.yaml here): '
        'cd app && dart tool/verify.dart');
    exit(2);
  }

  final steps = <Step>[
    if (pubGet)
      Step('pub get', 'flutter', <String>['pub', 'get'],
          'the dependency set resolves'),
    Step('analyze', 'dart', <String>['analyze', 'lib', 'tool', 'test'],
        'types, imports and lints are clean'),
    Step('conformance', 'dart', <String>['tool/conformance.dart'],
        'the generated command and parameter tables still match the protocol'),
    Step('transport', 'dart', <String>['tool/verify_transport.dart'],
        'the transport layer runs on a plain Dart VM (no Flutter import crept in)'),
    Step('sync', 'dart', <String>['tool/verify_sync.dart'],
        'the sync engine and its ledger run on a plain Dart VM'),
    Step('widget', 'flutter', <String>['test'],
        'every screen builds and the widget regressions hold'),
    if (withAndroid)
      // The Kotlin side's pure-logic JVM tests (`WifiJoinDiagnosis`, the MIME table,
      // the camera-AP SSID matcher). Off by default because it needs a JDK and the
      // Android SDK, which `dart` and `flutter` alone do not.
      Step(
          'kotlin',
          Platform.isWindows ? 'gradlew.bat' : './gradlew',
          <String>['--offline', ':app:testDebugUnitTest', '--console=plain'],
          'the Android-side pure logic still passes its JVM tests',
          dir: 'android'),
    Step('release-tree', 'dart',
        <String>['tool/verify_release.dart', '--root', '..'],
        'no credential, vendor binary, signing key or machine path is in this repository'),
    if (apk != null)
      Step(
          'apk',
          'dart',
          <String>[
            'tool/verify_apk.dart',
            apk,
            if (stamp != null) ...<String>['--stamp', stamp],
            if (allowDebugSigning) '--allow-debug-signing',
          ],
          'the built artifact carries the required permissions, no test '
              'instrumentation and a real signature'),
    Step('self-test: release scan', 'dart',
        <String>['tool/verify_release.dart', '--self-test'],
        'the leak scan still notices the hazards it was written for'),
    Step('self-test: apk check', 'dart',
        <String>['tool/verify_apk.dart', '--self-test'],
        'the artifact check still notices a missing permission, an instrument '
            'marker, an absent stamp and a debug signature'),
  ];

  stdout.writeln('yi-m1-controller-app verification');
  stdout.writeln('   ${steps.length} steps, sequential; logs are this terminal');

  var failed = <String>[];
  for (final s in steps) {
    final code = await _run(s);
    if (code != 0) failed.add(s.name);
  }

  stdout.writeln('');
  stdout.writeln('== summary');
  for (final s in steps) {
    stdout.writeln('   ${failed.contains(s.name) ? 'FAIL' : 'ok  '}  ${s.name}');
  }

  stdout.writeln('');
  stdout.writeln('Not checked here, on purpose:');
  stdout.writeln('  * the camera itself — BLE pairing, the HTTP command set, the live'
      ' view stream, the album sync and the MediaStore path were verified against a'
      ' real YI M1 and cannot be re-derived from source');
  stdout.writeln('  * the firmware patch and the reverse-engineering notes — not'
      ' published; `analysis/NN` citations in comments point at them and are not'
      ' followable from here');
  stdout.writeln('  * the Android build — run `flutter build apk --release` (needs the'
      ' Android SDK and a signing key) and then `dart tool/verify.dart --apk <apk>`');

  if (failed.isEmpty) {
    stdout.writeln('');
    stdout.writeln('ALL GREEN');
    exit(0);
  }
  stdout.writeln('');
  stdout.writeln('FAILED: ${failed.join(', ')}');
  exit(1);
}
