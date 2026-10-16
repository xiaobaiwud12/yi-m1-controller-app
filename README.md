[English](README.md) | [简体中文](README.zh-CN.md)

# yi-m1-controller-app

An open-source Android controller for the YI M1 (`C59Y1`) mirrorless camera. It pairs over Bluetooth Low Energy (BLE), joins the camera's Wi-Fi network, sends HTTP controls, receives JPEG live view over UDP, and copies selected camera files to the phone.

This is an independent project, not affiliated with or endorsed by the camera manufacturer.

## Release status

The current source version is **`0.2.3+5`**. See [GitHub Releases](https://github.com/xiaobaiwud12/yi-m1-controller-app/releases) for published versions and APK downloads. `app/pubspec.yaml` is the single source of the app version, and `CHANGELOG.md` records release changes. This maintenance fixes fullscreen rotation, focus placement across aspect ratios, and unwanted original-file requests after preview failures.

The maintainer confirmed that the original delivered app works. The camera is now unusable, so the current source has not been verified with a real camera. Offline and emulator checks cannot establish real-camera behavior.

## Features and operating limits

- Pair with a YI M1 over BLE and obtain its Wi-Fi settings.
- Connect to the camera's access point and send supported HTTP controls.
- Display the camera's JPEG live-view stream.
- Browse camera-card media and select files to transfer to the phone.

The camera handles HTTP requests serially. Media selection adds work to a queue; the user starts transfer from the sync controls. Connection readiness does not start downloads. RAW and JPEG files captured as a pair are grouped, and selecting the pair queues both. A `204` response to a thumbnail request means that resolution is unavailable, not that the file is missing; RAW files require an original-size request.

The shutter uses press-and-hold, and capture is unavailable while the camera reports Continuous drive mode. Pause/resume of the live-view stream is an explicit experiment and is off by default.

## Requirements

- YI M1 (`C59Y1`) and an Android phone running Android 7.0 (API 24) or later, with BLE and Wi-Fi.
- Release APKs target **`arm64-v8a`**. Install on a compatible device. Android may ask you to allow installation from the source used to open the APK.
- To build from source, use Flutter/Dart, Android SDK, JDK and Git.

A simulator with fake-camera flags is for UI and integration checks only. It does not connect to a physical camera.

## Checks and APK verification

From the repository's `app/` directory, run the unified offline verification entry point:

```bash
dart tool/verify.dart
```

To inspect a release APK from the same directory:

```bash
dart tool/verify.dart --apk build/app/outputs/flutter-apk/app-release.apk --stamp <commit-stamp>
```

The APK check inspects packaged permissions, rejects test-only instrumentation, checks the embedded build stamp, and rejects the public Android debug signing key.

`MARIONETTE`, `FAKE_CAMERA`, and `DIRECT_CAMERA` are test or experiment flags. They must not be enabled in a formal APK.

## Licensing

This application is licensed under **Apache-2.0**; see `LICENSE`. `NOTICE` lists third-party components and applicable notices, including MIT-licensed generated protocol material. Preserve notices when redistributing the source or bundled components. The in-app licence page lists bundled components.

## Project links

- [Release notes](CHANGELOG.md)
- [Release instructions](RELEASING.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Protocol notes](app/docs/PROTOCOL.md)
- [Issue tracker](https://github.com/xiaobaiwud12/yi-m1-controller-app/issues)
