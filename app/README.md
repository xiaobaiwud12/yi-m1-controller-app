# yi_m1_controller — the Flutter application

This directory is the application. The repository's front page, `README.md` at
the root, is the documentation: what the app does, what has been verified and
what has not, the hardware and toolchain you need, how to build and run it, and
the safety rules the camera imposes.

Start there rather than here.

## The short version

```powershell
flutter pub get
dart tool/verify.dart        # analyzer, logic suites, widget tests, leak scan
```

Individual pieces, if you want a faster signal:

```powershell
dart analyze                      # the fastest signal; should be silent
flutter test
dart tool/verify_transport.dart   # pure Dart VM, no Flutter engine
dart tool/verify_sync.dart
dart tool/conformance.dart
```

Nothing machine-specific has to be edited before that works — the JDK path and the
missing Gradle wrapper are both fixed. A **release** build needs the maintainer's
signing key and refuses to run without it; for a local build ask for the debug
signature explicitly with `--android-project-arg=allowDebugSigning=true`. The root
`README.md` §2b and `RELEASING.md` explain both.

## Where things are

| Path | What it is |
|---|---|
| `lib/protocol/` | Wire formats, the 45-command table, parameter pools, coordinate mapping, layout maths. **No Flutter.** |
| `lib/transport/` | BLE, HTTP, live view, album, Wi-Fi join, capture interlock. **Four files import Flutter; the pure-VM verifiers avoid them.** |
| `lib/sync/` | Transfer queue, sync ledger, pause contract. **No Flutter.** |
| `lib/platform/` | The implementations that do need Flutter: MediaStore, file sinks. |
| `lib/state/` | `AppState`, the single source of truth. |
| `lib/ui/` | Pages and widgets. Interactive controls carry `ValueKey<String>` names. |
| `lib/l10n/` | Translation sources (`app_en.arb`, `app_zh.arb`). |
| `tool/verify.dart` | The one verification command; it runs everything below and then says what it could not check. |
| `tool/verify_*.dart` | 686 pure-VM assertions, plus the leak scan (`verify_release.dart`), the artifact check (`verify_apk.dart`) and the launcher-icon check (`verify_icon.dart`). |
| `test/` | Widget tests, overflow and text-scale tests, fakes. |
| `android/` | Kotlin platform code and its JVM unit tests. |
| `testdata/liveview/` | 40 real UDP datagrams off the camera. The framing checks cannot run without them. |
| `docs/PROTOCOL.md` | The wire-protocol reference the client is written against. |

Keeping `protocol`, `transport` and `sync` free of `package:flutter` is a hard
constraint, not a style preference — it is what lets 686 assertions run in a
plain Dart VM in seconds. Implementations that need Flutter belong in
`lib/platform/`.
