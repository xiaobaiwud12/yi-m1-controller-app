# Changelog

All notable changes to this application are recorded here.

**Nothing in this file had been published before `0.2.0`.** The first release is
`0.2.0+2`, signed with the maintainer's own key and attached to a GitHub Release.
The version is declared in exactly one place — `app/pubspec.yaml` — and
`dart tool/verify_release.dart` fails if this file does not mention the version that
file declares. That coupling is the point: a tag, a pubspec and an installed build have
to be checkable against each other, or "which build is this?" becomes unanswerable
again.

This file was reconstructed from the project's development history. Where an
entry states something the project paid to learn, it says what the symptom was —
"the button was green and the shutter had never been sent" is worth more to the
next reader than "fixed a wiring defect".

Grouping follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.2.0] — first public release

### Added

- **An in-app licence page** — `btn-licences` in the app bar, reachable at every
  connection state. It lists every bundled component's licence (Flutter collects them
  into `NOTICES` at build time, so the list is the real one rather than one somebody
  maintained by hand), registers this app's own Apache-2.0 notice, and says plainly
  that this is an unofficial third-party application with no affiliation to the
  camera's manufacturer. The audit that prompted it found **no** `showLicensePage`,
  `LicensePage` or `LicenseRegistry` anywhere in the app while it was shipping
  Apache-2.0, MIT and BSD-3-Clause code.
- **`dart tool/verify.dart`** — one verification command for this repository: the
  analyzer, the three pure-Dart logic suites, the widget tests, the leak scan, and the
  self-tests of the two release checks, followed by the list of what it could **not**
  check. The development repository has `tools/task.ps1 verify`; none of that machinery
  is published, so without this a clone had no verification entry point at all.
- **`dart tool/verify_release.dart`** — a leak scan over the repository: credential
  shapes, signing-key material, vendor binaries, one machine's paths, and a
  `.gitignore` that would keep a needed file out of the commit. It carries a
  `--self-test` that plants every hazard in a temporary tree and fails if the scan
  misses one.
- **`dart tool/verify_apk.dart`** — artifact assertions needing no Android SDK: the
  eight required permissions read out of the **packaged** manifest, the test
  instrumentation markers searched across `classes*.dex` and `lib/**/*.so`, the build
  stamp in `libapp.so`, and a refusal to pass an APK signed with the public Android
  debug key.
- **English + Simplified Chinese**, following the phone's language by default with a
  picker in Settings.
- **Haptic feedback** — one tick per dial detent, and distinguishable feedback for the
  shutter's half-press and release.
- **RAW files sync, not just the JPEG beside them.** The album protocol was
  probed against real hardware: one shutter press produces one entry, a RAW is
  reachable only at the `Original` resolution, and `Thumbnail` answers `204`
  where `204` means "this resolution cannot be produced" rather than "the file is
  missing".
- **Deleting a file from the card works.** An earlier `404` was never about the
  file: the request needs a `file_list` **array**, and given the wrong key an
  existing file and a nonexistent one answer identically. The app now carries the
  correct shape and says in its own error text that a `404` here means the
  request was rejected rather than that the file is gone.
- **First-run and pairing flow.** Three steps, skippable, reopenable from the app
  bar. Two real bugs fell out of building it — the persisted-storage write failed
  on Windows every time, and a `PageView` with `NeverScrollableScrollPhysics`
  never turns the page at all, so the step counter said "2" while the body still
  showed step 1.
- **The sync list is visible and controllable** — `btn-sync-list` shows it,
  `btn-sync-list-remove-*` removes one entry, `btn-sync-list-clear` empties it.
  Switching sync mode always re-derives the list rather than asking the user to
  choose, and "cancel an in-flight transfer" means letting the request finish and
  discarding the reply, never interrupting the camera.
- **Exposure dials on the live-view page**, with three levels of throttling:
  nothing is sent while the finger is down, then the newest value supersedes the
  previous one every 350 ms, and only one request is ever in flight.
- **The dials change with the shooting mode.** In M the rail shows aperture and
  shutter with EV as a hint; in A/S it shows EV plus the parameter that mode
  controls; in P, EV only. The left rail is always ISO and mode, the histogram
  moved below the shutter button, and the full-screen settings panel drops
  entries that are already on the rail.
- **Burst shooting by holding the shutter** — press starts, release stops, and a
  watchdog stops it regardless. It was made stoppable *before* it was made
  startable, and shooting in the camera's `Continuous` mode is refused outright,
  because the app could start a burst it could not stop.
- **Focus is set to `Manual`, not `Auto`.** The camera never reported where it
  actually focused, so the app sends a manual focus point and draws the frame at
  the tapped position. Verified on hardware that the focus plane really moves.
- **A build stamp is rendered in the app bar.** A release APK was once reported
  as missing UI fixes that were in fact present in it; nothing on screen said
  which build was running, so the report could not be settled by looking at the
  app. The build now passes the short commit hash in and fails if the stamp is
  not inside the shipped `libapp.so`.
- **A virtual camera for the emulator's radio**, so that the connection sequence
  — scan, discover, pair, read credentials, join, HTTP, ready — can be exercised
  on a desk. It advertises the camera's own service, exposes its real GATT table,
  auto-accepts the pairing write and validates the session request, with no
  change to the app. It is a fake camera: it proves the app's own BLE logic and
  nothing about a real camera's radio.
- **Two compile-time seams so post-connection screens are reachable without a
  camera** — `--dart-define=FAKE_CAMERA=1` (a stub camera that answers the
  commands the UI actually reads) and `--dart-define=DIRECT_CAMERA=1` (skip BLE
  and talk HTTP to a camera at a fixed address). Both are asserted absent from
  release artefacts.
- **An observer for the preview stream**, so the emulator can be fed while
  somebody watches.

### Changed

- **A release build now fails without a signing key**, instead of silently using the
  debug one. The release build type had been
  `signingConfig = signingConfigs.getByName("debug")` under a Flutter template `TODO`,
  which meant every "release" APK was signed with a **publicly known** key — fixed
  alias, fixed password — so anybody could build an update Android would accept as
  legitimate. The build reads `app/android/keystore.properties` and refuses to
  configure a release without it. A local build can still ask for the debug signature
  explicitly (`--android-project-arg=allowDebugSigning=true`), and both the build log
  and the artifact check say what was asked for.
- **`compileSdk` / `targetSdk` / `minSdk` are written down** (36 / 36 / 24) rather than
  inherited from the Flutter SDK's defaults. The inherited values were these numbers;
  what changes is that a Flutter upgrade can no longer move `targetSdk` — and with it
  the app's runtime behaviour and its store eligibility — without a line of this
  repository changing.
- **`app/android/gradle.properties` no longer pins one machine's JDK path.** Gradle
  ignores `JAVA_HOME` whenever `org.gradle.java.home` is set, so the pinned path was a
  hard build failure for everybody else. If your `JAVA_HOME` is JDK 24 or newer the
  property is still needed — in `~/.gradle/gradle.properties`, not in the repository.
- **The Gradle wrapper is complete**: `gradlew`, `gradlew.bat` and
  `gradle/wrapper/gradle-wrapper.jar` are all committed, so `./gradlew` works from a
  fresh clone. Flutter's template gitignores all three, and `flutter build` hides the
  omission by injecting its own copies.
- **The version is `0.2.0+2`.** The development repository's only tag is
  `v0.2.0-hardware-round1`, a milestone marker pointing at a build that called itself
  `0.1.0`; the build number starts at 2 because it has to be strictly greater than the
  code already installed on the test phone.
- **Downloading queues; it does not start a transfer.** The sync bar starts it.
- **Opening an already-synced photo reads the phone's own copy.** Fetching from
  the camera can only be triggered by an explicit user request, because the
  camera serves one HTTP client and the preview stream contends with everything
  else.
- **`pauseStreamDuringTransfer` defaults to `false`.** Pausing and resuming the
  live-view stream has never been verified on a real camera, and using it
  unverified once wedged the camera. It is exposed only as an explicit
  experiment (`toggle-pause-stream`).
- **A gallery write is only "done" once `IS_PENDING` is confirmed cleared** —
  the update must affect more than zero rows. A call returning a URI is not
  evidence that the gallery can see the file.
- **A synced photo lands under its capture date**, and the landscape album grid
  no longer crashes on a zero-size cell.
- **The readout bar is legible and stops jumping.** The required width was
  re-measured from 192 dp to 156 dp, full screen uses a compact notation, and a
  `FittedBox` that made the row shrink vertically as the value got shorter was
  removed.
- **Landscape album layout reworked** to give the grid back its height, with the
  sync bar's width documented as a workaround rather than as a design.

### Fixed

- **The shutter had never reached the camera at all.** The capture interlock was
  constructed with a client captured by value before the link was ready, so it
  held a dead client for the whole session. Three rounds of investigation looked
  elsewhere; the owner's judgement was right each time.
- **The camera could be driven while it was streaming** — the interlock that was
  supposed to prevent it did not.
- **A power cycle now clears the capture interlock and says so when it is
  needed.**
- **Two live-view controls did nothing at all**, and the small ones were too
  small; the shutter button went from 15.2 dp to 68 dp.
- **The recovery banner no longer tells the reader to press a button that is not
  there.**
- **The top band no longer overflows by 55 px when the histogram is on.**
- **A stale UI state is now covered by a test**, after it was found by driving
  the running app rather than by reading the code.
- **Disconnecting really disconnects.** The disconnect path released the process's
  network binding but never withdrew the `NetworkRequest` that had brought the
  camera's access point up, so the phone stayed on it — occupying the camera's single
  client slot and making the next connection attempt look like a wrong password.
- **Album order is no longer the ring the camera sent it in**, and the oldest
  thumbnails are requested instead of never being asked for.
- **The capture-date log line is kept deliberately**, and the code says why it is
  not leftover debug output.
- **Two documents were steering the next reader wrong** and were corrected
  rather than left to mislead.

### Removed

- **The golden screenshot test.** Its only baseline was an entirely transparent image
  (1080×2136, one distinct colour), so the comparison passed under any rendering — a
  green check that checked nothing. Fixing it would have been worse than deleting it:
  the baseline was a screenshot of the Wi-Fi diagnostics sheet, which displays the
  camera's SSID **and its password**, so a correct baseline would have baked a
  credential into the repository.

---

## [0.2.0-hardware-round1] — 2026-09-15

**Internal milestone marker, not a release.** The version in
`app/pubspec.yaml` was never bumped to match it, so the APK built at this
milestone reports `0.1.0+1` — the Android `versionName` and `versionCode` are
taken from the pubspec. That mismatch is recorded here rather than quietly fixed:
a marker whose name disagrees with the artefact it points at is worth knowing
about.

### Changed

- **`CHANGE_NETWORK_STATE` is declared**, which is the permission whose absence
  made "the app cannot join the camera" true. The manifest *source* looked
  complete; only a dump of the built APK showed it was gone. The build now
  unpacks the shipped APK and asserts all eight required permissions.
- **Gallery delivery is verifiable and platform results are no longer
  discarded** — `IS_PENDING` must be confirmed cleared before a write counts as
  done.
- **The camera is no longer driven while it is streaming.**

### Known issues at this milestone

- It was not confirmed on hardware that a synced photo appears in the system
  gallery with its capture date, nor what preview stutter during capture actually
  feels like.
- The camera's own firmware bug — a burst that nothing on the camera stops — was
  understood but not worked around in the app yet.

---

## [0.1.0] — 2026-09-14

Initial import: the Flutter/Android controller application.

No version of `app/pubspec.yaml` has ever been published, so `0.1.0` labels the
initial import rather than a release.
