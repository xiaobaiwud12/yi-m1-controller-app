# Application source guide

This directory contains the Flutter application for the YI M1 (`C59Y1`). For user-facing behavior, limits and release status, see the [application README](../README.md). For build, signing and publication steps, see the [release guide](../RELEASING.md).

## Verify and build

Run commands from this `app/` directory. The unified offline checks are:

```bash
dart tool/verify.dart
```

For release preparation and artifact checks, follow the [release guide](../RELEASING.md). Signing requirements and certificate handling are documented there.

## Source layout

| Path | Responsibility |
|---|---|
| `lib/app/` | Startup, application assembly and navigation. |
| `lib/features/*/presentation/` | Feature screens and their presentation logic. |
| `lib/platform/` | Flutter and native platform adapters. |
| `lib/protocol/` | Camera protocol formats and command definitions; pure Dart. |
| `lib/transport/` | BLE, HTTP, live-view and camera transport; pure Dart, no Flutter imports. |
| `lib/sync/` | Transfer queue and sync logic; pure Dart, no Flutter imports. |
| `lib/state/app_state.dart` | Compatibility facade; shared synchronization ownership belongs to `SyncSession`. |
| `lib/ui/` | Shared widgets and theme. |
| `lib/l10n/` | English and Simplified Chinese translations. |
| `tool/` | Unified verification entry point and focused offline checks. |
| `test/` | Widget and application tests. |
| `android/` | Kotlin platform code and JVM tests. |
| `testdata/liveview/` | Captured camera datagrams used for offline framing checks. |
| `docs/PROTOCOL.md` | Protocol reference for the client. |

`lib/protocol/`, `lib/transport/` and `lib/sync/` remain independent of Flutter so their checks can compile and run on the Dart VM. Platform integrations belong in `lib/platform/`; `AppState` remains a compatibility facade rather than the owner of shared sync state.

Offline fixtures include captured live-view data and a privacy-safe EXIF layout derived from a camera original with other payloads zeroed. These fixtures support offline checks; they do not establish current real-camera behavior. The camera is currently unusable, so this source has not been retested with a real camera.
