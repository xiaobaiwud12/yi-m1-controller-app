# Releasing

This guide covers preparing, building, checking and publishing an app release. The public repository contains the app and its public release materials. Keep credentials, signing files and machine-specific paths out of the repository and release notes.

## Release facts

- `app/pubspec.yaml` is the **only source of the app version**; Android version fields derive from it.
- The current source version is `0.2.3+5`. See [GitHub Releases](https://github.com/xiaobaiwud12/yi-m1-controller-app/releases) for published versions and APK downloads.
- Release APKs target `arm64-v8a`.
- The application is licensed **Apache-2.0**. Consult `NOTICE` for third-party licenses and attribution, including MIT-licensed generated protocol material.

## 1. Prepare the source

1. Update `version:` in `app/pubspec.yaml` and add matching notes to `CHANGELOG.md`.
2. Describe user-visible changes and where users can find them. Keep unverified behavior clearly marked; the camera cannot currently be used for real-device testing.
3. Review and commit the source before building. A dirty build cannot be tied to a clean source revision.
4. Confirm release test flags are disabled. `MARIONETTE`, `FAKE_CAMERA` and `DIRECT_CAMERA` are not for formal APKs.

## 2. Keep signing material external

A distributable release must use the maintainer's private release keystore. The keystore and its properties file are external to this public repository. Obtain them through the maintainer's secure process; do not commit them, paste passwords into issues, or include them in release assets.

The Android release configuration reads `storeFile`, `storePassword`, `keyAlias` and `keyPassword`. `storeFile` is relative to `app/android/`. A release build fails if the signing configuration is missing. Debug signing is only for local, non-distributable work and must never be published.

Use the same signing certificate for every update. Back up the keystore and passwords securely. If the key is lost or exposed, stop and resolve the signing identity before distributing an APK.

## 3. Run offline verification

From the repository root, enter `app/` and run:

```bash
cd app
dart tool/verify.dart
```

This unified entry point runs analysis, pure-Dart logic, widget checks and release safeguards. Record which checks actually ran. Fake-camera or emulator runs cannot establish camera functionality.

## 4. Build and inspect the APK

From `app/`, build an arm64 release and embed the source commit in the build stamp:

```bash
flutter build apk --release --target-platform android-arm64 --dart-define=BUILD_STAMP=<commit-sha>
```

Then inspect the APK from `app/`:

```bash
dart tool/verify.dart --apk build/app/outputs/flutter-apk/app-release.apk --stamp <commit-sha>
```

The APK check inspects packaged permissions, scans shipped code for test instrumentation, verifies the embedded stamp, and rejects the public Android debug signing key. A successful build alone does not replace this check.

Record the APK hash and signing certificate fingerprint with the release notes:

```bash
sha256sum build/app/outputs/flutter-apk/app-release.apk
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

On Windows, use `Get-FileHash <apk> -Algorithm SHA256` for the APK hash. Compare the certificate SHA-256 fingerprint with the established release certificate. Stop and investigate any mismatch.

## 5. Export, tag and publish

Prepare the app-only source tree using the established export process. Review the exported file list and run its bundled release-tree check before committing. Keep the export isolated from development notes, firmware, device captures, credentials and signing files.

After the APK passes verification, tag the exact source commit as `v<version-name>` and attach the matching APK to that GitHub Release. Confirm the source tag, version, build stamp, APK hash and certificate fingerprint agree before publishing.

Release notes should include:

- Version name/code, source tag and build stamp.
- APK SHA-256 and signing certificate SHA-256.
- User-visible changes and where to find them in the app.
- Checks performed and their limits, including the lack of real-camera verification.
- Installation requirements and the `arm64-v8a` ABI.

Describe the changes included in the release: fullscreen rotation, aspect-ratio focus placement and preview-only media browsing for `0.2.3+5`. Label emulator or fake-camera results as such and keep verification limits consistent with the public README. The maintainer confirmed the original delivered app works; the camera is currently unusable, so the current source has not been retested with a real camera.

Users install by downloading the APK from the release page and opening it on a compatible arm64 Android device. Android may ask them to permit installation from that download source. Updates must use the same signing certificate; a corrected release must have a higher app version code.

## If a release problem is found

Do not publish an APK with an incorrect version, stamp, hash, permissions, test flags or signing certificate. If a bad release is already public, publish a corrected build with a higher version code and clearly explain any user action required. Android will reject an update signed with a different key.

## Licensing and notices

Keep `LICENSE` and `NOTICE` with the exported source. The project license is Apache-2.0. Preserve notices required by third-party components when redistributing them.
