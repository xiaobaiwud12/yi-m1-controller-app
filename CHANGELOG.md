# Changelog

All notable changes to this application are recorded here.

**Nothing in this file had been published before `0.2.0`.** The first release is
`0.2.0+2`, signed with the maintainer's own key and attached to a GitHub Release.
The version is declared in exactly one place — `app/pubspec.yaml` — and
`dart tool/verify_release.dart` fails if this file does not mention the version that
file declares. That coupling is the point: a tag, a pubspec and an installed build have
to be checkable against each other, or "which build is this?" becomes unanswerable
again.

Releases so far: **`0.2.0+2`**, the first public one, and **`0.2.1+3`**.

This file was reconstructed from the project's development history. Where an
entry states something the project paid to learn, it says what the symptom was —
"the button was green and the shutter had never been sent" is worth more to the
next reader than "fixed a wiring defect".

Grouping follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.2.1]

### Added

- **The app has its own launcher icon.** Until this release it shipped Flutter's
  template icon — a stock blue-and-white placeholder that says nothing and is nobody's
  design. The new mark is a lens ring with a white glass at its centre and two
  broadcast waves opening to the upper right: a camera you command over a radio link.
  It is **original work by this project under this project's licence**, drawn from
  three primitives; `NOTICE` §6 records what it is and, just as deliberately, what it
  is not — no vendor logo, wordmark or trade dress was traced or approximated, and
  nothing came from the vendor's decompiled application. It is a real adaptive icon
  rather than one bitmap: the API 26+ foreground and background layers, a
  `<monochrome>` layer so Android 13+ can recolour it to the wallpaper palette, and
  ten legacy PNGs for API 24–25, all derived from one set of geometry constants.
- **`dart tool/verify_icon.dart`** — 115 assertions over the icon, runnable with plain
  `dart`. It decodes the ten PNGs with a real decoder rather than reading their
  headers, asserts they are neither blank nor single-coloured nor duplicates of each
  other, requires the round ones to be genuinely round, and re-derives the safe-zone
  arithmetic by parsing the written vector instead of trusting the generator's own
  numbers. Its first runs found four defects that would otherwise have shipped: every
  legacy PNG a dark rectangle with the mark drawn off-canvas, a ring whose inner
  contour was a four-lobed blob, `android:roundIcon` never declared — so the resource
  shrinker deleted every round variant — and two XML comments containing `--`, which
  XML forbids, breaking the release resource packaging twice.

### Changed

- **The name under the launcher icon follows the phone's language.** `android:label`
  was the literal `M1 Controller`, and it is the one string that survives the app being
  closed: the launcher reads it from the APK's resources, so the in-app translation
  could not reach it and a Chinese phone showed English under the icon however good
  that translation was. It is now a string resource with an English and a Chinese
  value. **Which one is used is decided by the *system* locale**, through
  `PackageManager`, before any Dart code runs — so this follows the phone's language
  setting and *not* the language picked inside the app. That is a platform property
  rather than a defect, and it is stated in the manifest, in the README and in `NOTICE`
  §6 rather than glossed.
- **An expanded settings group now survives switching between the "Shooting" and
  "Sync" tabs**, and a remembered group is drawn expanded on the panel's first frame
  instead of opening with a visible twitch. Before, switching away and back left the
  group **collapsed** — so it had to be opened again — and the switch itself silently
  expanded a *different* group nobody had tapped, the sync tab's connection
  diagnostics, throwing five or six framework errors while it did. One cause: a group's
  `State` object was being handed to another group when the list was rebuilt.
- **A zoomed photo in the album viewer now fills the viewing area** — to the screen
  edges left and right, to the bottom, and up to the app bar. It used to be confined to
  the photo's own intrinsic size, so magnifying a thumbnail-sized picture magnified it
  *inside* a thumbnail-sized box. The zoom limit was never the problem: it has always
  been 6×, and the cause was a `Center` whose size was derived from its child.
- **Opening a photo that is not on the phone loads one preview automatically**,
  instead of showing an empty frame until the fetch button is pressed. It is one
  `MidThumb` — measured at 196,495 B on the real camera, against 5,565,238 B for the
  same photo's full-size original — it is fetched only for the page actually on screen,
  and it takes priority over the album grid's thumbnail requests. The full-size
  original is still an explicit press, and the button now says which of the two it will
  do.
- **The viewer pages left and right** instead of having to be closed and reopened,
  **double-tap zooms to 3×** about the point tapped, and **dragging after zoom pans the
  photo rather than turning the page** — which is what makes the edges of a photo
  reachable at all. The app bar shows where you are (`3 of 12`), and the information
  strip now floats over the photo rather than sitting under it, so the photo's height
  no longer changes with the interface language.
- **The thumbnail cache keeps its 8 MiB cap.** The cap is deliberately over a measured
  1000-shot card rather than under one photograph: what it protects is that
  reconnecting and opening the album does not re-fetch a card's worth of tiles from a
  single-threaded camera. The justification written next to the number is now the
  measured one, and the number that used to argue it — 9.4 MB for one photo, where the
  real figure is 4.9 MB — is gone.

### Fixed

- **One camera file request at a time, for everything.** The album grid's thumbnail
  loop, the sync engine's queue and the viewer each serialise their own requests, and
  each was correct on its own — but the viewer becoming a third caller made two of
  those serial loops into a pair of parallel ones, which is the one thing this camera
  cannot take. A single gate now serialises every file request, gives the photo on
  screen priority, never sends a request whose page has been swiped away, and lets an
  in-flight request finish with its bytes discarded rather than pretending a
  single-threaded server can be interrupted.
- **A preview that never arrives leaves a usable viewer**: the failure is shown, the
  spinner is gone, and the fetch button is back and still works. It does not retry on
  every rebuild, which against this camera would be a request storm.
- **A photo that is already on the phone still asks the camera for nothing** — not
  even a thumbnail. That was the guardrail this round had to keep green, and it is the
  one the automatic preview was allowed to move next to, not through.
- **The invented byte figures are now measured ones.** One figure for the size of a
  full-size JPEG was quoted in nine places across five files and matched neither of the
  two real measurements (4,897,837 B and 5,565,238 B); `MidThumb` was quoted as
  "~186 KB, measured" where its two measurements are 106,375 B and 196,495 B. They are
  now named constants with their provenance, and a check fails on any `N MB` / `N KB`
  figure in the code that is not one of them — a number in a comment cannot be tested,
  and this one had already drifted into a decision.
- **The localisation mechanism gained the direction it was missing.** The checks
  proved that every key existed, had a translation and had matching placeholders; none
  asked whether anything ever *read* the key. That check now exists, and it found three
  keys nothing could reach.
- **Two camera parameters were being read back under a key they were not set with,
  and nothing checked either direction.** Thirteen commands take a value and are then
  re-read to show the camera's state; two of them spell the two keys differently, so a
  typo in either table is a value the camera never receives and the interface never
  notices. Both tables are now single-source and checked from two sides — against
  parameter blocks recorded from the camera, and against the app's own state.
- **The build stamp could be empty, and the check that reads it passed anyway.** The
  artifact check asks whether the shipped `libapp.so` contains the build stamp, and an
  empty string is contained in every string — so on a machine without `git`, where
  there is no commit to name, the one check whose job is "the binary can name itself"
  certified any file at all. The stamp's producer and its reader both refuse an empty
  value now, and the release check carries a self-test that plants that hazard.
- **A sync stage that could never happen was removed rather than implemented.** The
  low-battery pause was declared, labelled "camera battery low", unreachable, and wrong
  three times over: the battery level it would watch is the *camera's* while the phone
  is what runs down, `101` on this camera means *charging* rather than empty, and
  nothing would have resumed the transfer it paused. A check now fails any sync stage
  with no assignment anywhere in the code, which is the shape that let this one stay
  alive.
- **Three published documents contradicted the release they shipped with.** `NOTICE`
  still said the app has no in-app licence screen — `0.2.0` added one — and that the
  launcher icon was Flutter's template icon, which this release replaces; the README
  still said no APK had been published, while `0.2.0`'s was attached to a GitHub
  Release and downloaded. All three are corrected, and the corrections are kept as a
  record rather than overwritten.
- **The README's safety rule was narrowed to match the code.** "An explicit request is
  required to fetch" was true of the full-size original and false of the automatic
  preview, so the rule now reads as the one that always held: a photo already on the
  phone is never fetched from the camera again.

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
