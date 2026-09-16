# yi-m1-controller-app

An open-source Android controller for the **YI M1** (小蚁微单, model `C59Y1`)
mirrorless camera. It replaces the vendor's abandoned official app.

It pairs with the camera over **Bluetooth Low Energy**, reads the camera's Wi-Fi
credentials from it, joins the camera's own access point at `192.168.0.10`, then
drives it over **HTTP commands** and a **UDP 54321 JPEG live-view stream**, and
syncs photos off the SD card into the phone's system gallery.

This repository contains the application. Nothing else.

> **Status: first public release, `0.2.0+2`.** No APK has been published yet; the
> first one will be attached to a GitHub Release and signed with the maintainer's own
> key (see `RELEASING.md`). The app has been verified on exactly one camera unit by
> one person, on one phone. `CHANGELOG.md` and the sections below separate what has
> evidence from what does not.
>
> The app ships **English and Simplified Chinese**, following the phone's language by
> default, with a picker in Settings. It states its own licences in-app: the info
> button in the app bar (`btn-licences`) opens the licence page, which lists every
> bundled component and says plainly that this is not the manufacturer's app.

---

## Screenshots

<!--
  PROVENANCE — what these four PNGs are, and what they are not.

  They are screenshots of the app, at its native device pixels (1080x2400 and
  2400x1080 @ 420 dpi, Pixel-6-class AVD `yi_m1_test`), captured with
  `adb shell screencap` and NOT downscaled; the <img width> attributes below
  control display size only. Do not upscale or re-encode them to a different
  size — that would make the captions' claim about the preview and the dial
  geometry untrue.

  Build       : a **debug** build of the app source in this repository, run with
                `flutter run -d emulator-5554 --dart-define=MARIONETTE=1
                --dart-define=FAKE_CAMERA=1`. All four carry the app's own
                `dev` build stamp in the app bar, which is how a reader can tell
                they are not a release build. `FAKE_CAMERA` fabricates the
                connection and the camera's answers; the camera protocol is not
                exercised by these images and they are not evidence that any
                command works.
  Camera      : **none.** No M1 was connected or used. There is no real camera
                anywhere in these shots.
  Locale      : `live-view.png` and `dials-landscape.png` are the **English**
                interface; `album-sync.png` and `first-run.png` are
                **简体中文**. The app follows the phone's language by default
                (Settings → Language), so the Chinese shots are what a Chinese
                phone shows with no configuration, and the two together are the
                evidence that both locales are really drawn — not only claimed.
  Preview     : **synthetic, and deliberately so.** The app's own live-view
                receiver, JPEG decode, readout strip and histogram are all real
                and running — but the picture in the preview is a public-domain
                painting, not the camera's output. It is fed to the running app
                as datagrams in the measured live-view format (frame index,
                timestamp, `0x79CE4283`, 2272-byte parameter block, SOI at
                +2284), so what is rendered is the app's real pipeline operating
                on a still life. The camera state in the readout strip is a real
                capture from the maintainer's M1 (its RAW+JPEG, ISO, shutter and
                battery values), replayed for the frame.

                **Nothing here is presented as a photograph of a real scene
                through the app.** The alternative was photographing a desk with
                the maintainer's home in it, which is worse.
  Grid        : `dials-landscape.png` has the composition grid switched on,
                which is why rule-of-thirds lines are visible over the picture.
                The histogram is on in every shot.

  Captions are bilingual on purpose: the camera is a Chinese product (小蚁微单)
  and its users are the reason the app is being localised, while the
  application's code and commit history are English. If you prefer one language,
  delete the other line from each caption — nothing else depends on it.
-->

> **What these four images are — read this before judging the app by them.**
> They are screenshots of this app's own UI, at native device resolution
> (1080x2400 and 2400x1080), from an emulator, with **no camera connected**. The
> connection is stubbed (`FAKE_CAMERA`) and the picture in the preview is a
> public-domain still life fed through the app's real live-view path — so the
> layout, the readout, the dials and the histogram are the app's own rendering,
> while **the photograph is not the camera's**. Two shots are in English and two
> are in 简体中文, because the app follows the phone's language. The full
> provenance — build flags, locales, and the exact JPEG fixture — is in the HTML
> comment above.

<table>
<tr>
<td width="50%">

<img src="docs/screens/live-view.png" width="300"
     alt="Portrait shooting screen: the camera's live preview fills the upper area, with the state readout, the shutter button and the settings panel below it.">

**Live view · 取景页.** Portrait, connected, preview running — the app's own
render. The readout bar carries the camera's own state; the histogram sits
between it and the picture. Shown here in **English**; `album-sync.png` and
`first-run.png` below are the same app in **简体中文**.

**中文**：竖屏取景页，已连接、预览在跑。读数栏显示相机自己的状态，直方图在预览上方。
本图为**英文**界面；下方 `album-sync.png` 与 `first-run.png` 为**简体中文**界面。

</td>
<td width="50%">

<img src="docs/screens/dials-landscape.png" width="700"
     alt="Landscape full screen: the preview fills the display and the mode-aware exposure dial rail runs down both sides.">

**Landscape full screen with the dials · 横屏全屏与拨盘.** S is the mode the
camera reported here, so the right rail is EV plus the parameter S controls
(shutter) and ISO/Mode stay on the left. The composition grid is on, which is why
rule-of-thirds lines are drawn over the picture, and the histogram sits below the
shutter.

**中文**：这里的模式是相机回报的 S 档，因此右侧拨盘为 EV 加 S 档控制的参数（快门），
ISO 与模式固定在左侧。构图网格已打开，所以画面上有三分线；直方图在快门下方。

</td>
</tr>
<tr>
<td>

<img src="docs/screens/album-sync.png" width="300"
     alt="The album page: a grid of thumbnails from the camera's SD card, with selection controls and the sync bar.">

**Album and sync · 相册与同步.** The card's contents, grouped into RAW+JPEG
pairs. Selecting items queues them; **the sync bar is what starts the transfer** —
queueing never starts one.

**中文**：相册把 RAW 与 JPEG 配成一对。勾选只是**入队**，真正开始传输的是同步栏。

</td>
<td>

<img src="docs/screens/first-run.png" width="300"
   alt="The first-run flow: a three-step guide that walks through pairing the phone with the camera over Bluetooth.">

**First run and pairing · 首次使用与配对.** Three steps, skippable and
reopenable from the app bar. Pairing needs a physical **Accept** on the camera
body, and the camera stores only one pairing.

**中文**：三步、可跳过，也能从应用栏重开。配对需要在**相机机身上按 Accept**，
而且相机只保存一个配对。

</td>
</tr>
</table>

---

## What works today

Claims here carry markers: **[V]** means the behaviour was observed and is
recorded, **[H]** means it is judgement or reasoning rather than an observation.

### Verified against a real camera

- **[V]** BLE pairing, reading the Wi-Fi credentials, joining the camera's
  access point, HTTP commands, and remote parameter control (aperture, shutter,
  ISO, white balance).
- **[V]** The shutter really fires. The owner's report was *"the count went down
  and it is in the gallery"* — a platform-level observation, not a green button.
- **[V]** Album protocol details reproduced on hardware: a `204` from a
  `Thumbnail` request means *"this resolution cannot be produced"*, not *"the
  file is absent"*; a RAW (`.DNG`) can only be fetched at `Original` (31.9 MB, a
  real DNG); `DeleteFile` takes a `file_list` **array**, and a wrong request shape
  answers `404` for an existing file and a nonexistent one alike.
- **[V]** Photos sync into the phone's system gallery, and a write is only
  counted as done once `IS_PENDING` is confirmed cleared — the query shows
  `is_pending=0`, not merely a returned URI.
- **[V]** RAW+JPEG pairs are grouped, and selecting one entry queues both.
- **[V]** **The camera has no watchdog.** A capture command sent while the drive
  mode is `Continuous` starts a burst that only a cancel command stops — nothing
  on the camera ends it by itself — and the camera then strands and needs its
  battery pulled. What kills it is *sending any other request during a burst*.
  The app therefore uses press-and-hold to shoot and refuses to shoot in
  `Continuous` at all.

### Verified on a desk

- **[V]** 674 pure-logic assertions across the protocol, transport and sync (450 in
  the transport suite, 224 in the sync one) plus 29 conformance checks, runnable with
  plain `dart` and no Flutter engine:

  ```powershell
  cd app
  dart tool/verify.dart             # everything, in order
  ```

  Or individually: `dart tool/verify_transport.dart`, `dart tool/verify_sync.dart`,
  `dart tool/conformance.dart`.

- **[V]** the widget suite, covering the live view, the album, the viewer, the
  first-run flow, overflow at large system text sizes, and the licence page:

  ```powershell
  cd app
  flutter test
  ```

- **[V]** The whole connection sequence — scan → discover → pair → read
  credentials → join → HTTP → ready — against a **virtual camera** injected into
  the Android emulator's radio, with no change to the app:

  ```powershell
  cd app
  flutter run -d emulator-5554 --dart-define=MARIONETTE=1 --dart-define=FAKE_CAMERA=1
  ```

- **[V]** The release artefact is inspected rather than trusted, and **that check
  ships here** rather than only existing on the machine that built it:

  ```powershell
  dart tool/verify_apk.dart build/app/outputs/flutter-apk/app-release.apk --stamp <stamp>
  ```

  It unpacks the APK and asserts that all eight required permissions are in the
  **packaged** manifest, that no test instrumentation reached the dex or
  `libapp.so`, that the build stamp is inside the shipped `libapp.so`, and that the
  artifact is not signed with the public Android debug key.

### Hardware facts that constrain what the app can do

These are properties of the camera, not of this app, and they are why several
obvious-looking features are absent.

- **[V]** **The live view is a JPEG stream over UDP**, one 800×600 frame per
  datagram, roughly **12–14 Mbit/s** at about 30 frames per second. The client
  deliberately does **no frame dropping** — that is an explicit product decision,
  not an oversight.
- **[V]** **The camera is a single-threaded HTTP server with one Wi-Fi client
  slot and no authentication.** Anything else talking to it contends with the
  preview.
- **[V]** **The camera has no real-time clock.** The app must therefore set the
  camera's clock over BLE after every power-up, or every photo's capture date is
  wrong.
- **[H]** Host Bluetooth passthrough to the Android emulator does not work on
  Windows: libusb cannot take a non-WinUSB device. Consequence: the BLE path can
  only be exercised against a **real phone** or against the emulator's **virtual
  peripheral** — never against your camera through the host radio.

### Built, but not yet exercised on real hardware

- **[V]** `GetMLFileList` always returns `{"code":200,"data":[]}` even with
  photos on the card. The cause is **not** known.
- **[H]** Roughly 15 of the camera's 45 HTTP commands have been exercised.
- **[H]** Only one camera unit and one phone have been used. A different firmware
  version can move things.

### Not verified, and not claimed

- **The dials' appearance.** Every dimension was measured programmatically, so
  the geometry is checked and the *look* is not.
- **Preview stutter under real conditions.** What the stream *feels* like on a
  phone is unmeasured.
- **Pause/resume of the live-view stream.** Never verified on a real camera, and
  using it unverified once wedged the camera. It is off by default
  (`pauseStreamDuringTransfer = false`) and exposed only as an explicit
  experiment (`toggle-pause-stream`).
- **Burst shooting beyond what has been established.** What a burst at full card
  speed actually produces was not measured.
- **USB and HDMI live-view output.** Analysis concluded both are infeasible; the
  complete UVC descriptor in the camera's firmware is dead code with zero
  references. Do not expect this feature.
- **The Chinese localisation and the haptic feedback** described as in progress
  in `CHANGELOG.md`. Neither is in a commit, so neither is in a build.

---

## Hardware and software you need

**Hardware**

- A **YI M1** (`C59Y1`) camera, powered on and charged. The vendor abandoned the
  product line; this project is unaffiliated with it.
- An Android phone with **Bluetooth LE** and Wi-Fi, on **Android 7.0 (API 24)**
  or newer. Release builds target `arm64-v8a`.
- A computer to build on. The project is developed on Windows; the build itself
  is platform-independent apart from the two machine-specific settings below.

**Software**

| | Version used | Notes |
|---|---|---|
| Flutter | `3.47.4` stable | pinned in `app/.metadata` by revision `9584c6713b` |
| Dart | `3.13.3` | comes with Flutter |
| JDK | **21** | the Android build needs a JDK that can `jlink` `core-for-system-modules.jar`; **JDK 25 fails**, and the failure surfaces as a misleading "upgrade your AGP version" hint from Flutter |
| Gradle | `9.3.1` | via `app/android/gradle/wrapper` |
| Android Gradle Plugin | `9.1.0` | `app/android/settings.gradle.kts` |
| Kotlin | `2.4.0` | |
| Android SDK | `compileSdk` 36, `targetSdk` 36, `minSdk` 24, NDK `28.2.13676358` | inherited from the Flutter SDK's defaults, not written down explicitly |

---

## Getting started

### 1. Clone

```bash
git clone https://github.com/xiaobaiwud12/yi-m1-controller-app
cd yi-m1-controller-app
```

There are no submodules. Everything needed to build is in this repository.

> The repository name ends in `-app` on purpose. The reverse-engineering work that
> produced this code — the firmware images, the decompiled vendor application, the
> analysis notes that the comments in `app/lib/` cite as `analysis/NN` — lives in a
> **separate, private** repository. It is not published and cannot be made available,
> which is why some comments cite material you will not find here. `tool/verify_release.dart`
> counts those citations and this README says so rather than leaving you to wonder
> whether your clone is incomplete; it is not.

### 2. Nothing machine-specific to change

Earlier versions of this tree asked you to edit two files before the build would
work. Both are fixed:

- **`app/android/gradle.properties` no longer pins one machine's JDK.**
  Gradle ignores `JAVA_HOME` whenever `org.gradle.java.home` is set, so the pinned
  path made a perfectly good JDK invisible and produced nothing but
  `Java home supplied is invalid`. Set it on your machine if you need to — in
  `~/.gradle/gradle.properties` (`%USERPROFILE%\.gradle\gradle.properties`), which
  is not tracked by anything. You need it if your `JAVA_HOME` is **JDK 24 or
  newer**: the Android build derives a JDK image from `core-for-system-modules.jar`
  with `jlink`, and that transform fails on JDK 25 behind a misleading "upgrade
  your AGP version" hint from Flutter. JDK 21 works.
- **The Gradle wrapper is complete here** — `gradlew`, `gradlew.bat` and
  `gradle/wrapper/gradle-wrapper.jar` are all committed, so `./gradlew` works from a
  fresh clone. (Flutter's own template gitignores all three; that is why an earlier
  export of this tree could not run the wrapper at all.)

### 2b. Signing: what a release build needs, and what a local build needs

A **release** APK must be signed with the maintainer's key, read from
`app/android/keystore.properties` (`storeFile`, `storePassword`, `keyAlias`,
`keyPassword`). That file is deliberately **not** in this repository: a key that can
impersonate the app cannot be un-published. Without it, a release build **fails**:

```
Release build refused: no signing key.
Looked for : .../app/android/keystore.properties
```

That failure is the point. Until 2026-09-16 the release build type silently used the
**debug** keystore — a publicly known key with a fixed alias and password, shipped in
every Android SDK — which would have let anybody build an "update" that Android
accepts. `RELEASING.md` has the `keytool` invocation and the whole procedure.

For a local build you do not intend to distribute, ask for the debug key explicitly:

```bash
flutter build apk --release --android-project-arg=allowDebugSigning=true
```

It prints a warning naming what you asked for, and `tool/verify_apk.dart` refuses the
resulting artifact unless you pass `--allow-debug-signing`.

### 3. Fetch packages

```powershell
cd app
flutter pub get
dart analyze
```

`dart analyze` is the fastest signal available. It should be silent.

### 3b. Verify — one command

```powershell
cd app
dart tool/verify.dart
```

That is the whole verification story for this repository: the analyzer, the three
pure-Dart logic suites (674 assertions between them, plus 29 conformance checks, and they must keep compiling
*without* Flutter — that is an architectural invariant, not a preference), the widget
tests, the leak scan over this repository, and the self-tests of the two checks that
belong to the release rather than to the app. Add `--with-android` to run the Kotlin
JVM tests too (needs a JDK and the Android SDK).

`dart tool/verify.dart` prints, at the end of every run, the list of things it cannot
check — the camera, the firmware notes that are not published, and the Android build.
That list is part of the output on purpose.

### 4. Build

```powershell
cd app
flutter build apk --release --target-platform android-arm64
```

The APK lands in `app/build/app/outputs/flutter-apk/app-release.apk`. The build
stamps itself with the short commit hash plus `-dirty` when the tree is dirty,
renders that in the app bar, and fails if the stamp is not inside the shipped
`libapp.so`.

Then check the artifact itself — this needs no Android SDK, and it is the only check
whose subject is what a user would install:

```powershell
dart tool/verify_apk.dart build/app/outputs/flutter-apk/app-release.apk --stamp <the stamp>
```

It reads the **packaged** manifest (the eight required permissions — one of them,
`CHANGE_NETWORK_STATE`, was missing from shipped APKs for three rounds while the
manifest *source* looked complete), searches `classes*.dex` and `lib/**/*.so` for the
test-instrumentation markers, looks for the build stamp in `libapp.so`, and refuses an
APK signed with the debug certificate.

Two compile-time seams exist purely so that screens which only exist *after* a
connection can be reached without a camera:

- `--dart-define=FAKE_CAMERA=1` — a stub camera that answers the commands the UI
  actually reads. It prints `FAKE_CAMERA_VERIFICATION_ONLY: simulating a
  connected camera` at startup. **It is not evidence that any command works.**
- `--dart-define=DIRECT_CAMERA=1` — skip BLE and talk HTTP to a camera at a
  fixed address.
- `--dart-define=MARIONETTE=1` — enables the widget-tree inspection channel used
  to drive the app remotely during development.

**None of the three may be defined in a release build.** The build asserts their
marker strings are absent from the artefact; if you build a release with one of
them and the build succeeds, that is a bug worth reporting.

### 5. Run it

```powershell
# On a phone that is already paired with the camera, over USB:
cd app
flutter run --release

# On an emulator, with a fake camera so the post-connection UI is reachable:
flutter run -d emulator-5554 --dart-define=MARIONETTE=1 --dart-define=FAKE_CAMERA=1
```

---

## Development

### What you can verify here, and what you cannot

`dart tool/verify.dart` (above) runs everything that can run without hardware.
**Read its last paragraph before you trust a green run**: the camera-facing
conclusions in `app/docs/PROTOCOL.md` were established against a real YI M1, and
nothing in this repository can re-derive them.

Anything that involves the camera — pairing, joining its access point, the
protocol, the live-view stream, and whether a photo actually appears in the
system gallery — **cannot be verified without the hardware**. No emulator
substitutes for it.

### The one rule

**Every new capability needs a check that can actually fail.** "The code is
written" is not done. A bug fix should arrive with the check that would have
caught it, and that check stays. See `CONTRIBUTING.md`.

### Layout

| Path | What it is |
|---|---|
| `app/lib/protocol/` | Wire formats, the 45-command table, parameter pools, coordinate mapping, layout maths. **No Flutter.** |
| `app/lib/transport/` | BLE, HTTP, live view, album, Wi-Fi join, capture interlock. **No Flutter.** |
| `app/lib/sync/` | Transfer queue, sync ledger, pause contract. **No Flutter.** |
| `app/lib/platform/` | The implementations that do need Flutter: MediaStore, file sinks. |
| `app/lib/state/` | `AppState`, the single source of truth. |
| `app/lib/ui/` | Pages and widgets. Interactive controls carry `ValueKey<String>` names (`btn-*`, `toggle-*`, `banner-*`) so they can be located remotely. |
| `app/lib/l10n/` | Translation sources (`app_en.arb`, `app_zh.arb`) and the generated `AppLocalizations`. |
| `app/tool/verify*.dart` | 674 pure-VM assertions, plus `verify.dart` (the entry point), `verify_release.dart` (the leak scan) and `verify_apk.dart` (the artifact check). All runnable with plain `dart`, no Flutter engine. |
| `app/test/` | Widget tests, overflow and text-scale tests, fakes. |
| `app/android/` | Kotlin: `MediaStorePublish`, `WifiJoinDiagnosis`, `MediaKind`, plus JVM unit tests. |
| `app/testdata/liveview/` | 40 real UDP datagrams captured from the camera. `tool/verify_transport.dart` reads them and the framing checks cannot run without them. |
| `app/docs/PROTOCOL.md` | The wire-protocol reference the client is written against, with a confidence marker on every entry. |

The three Flutter-free layers are a hard constraint, not a style preference:
keeping `protocol`, `transport` and `sync` free of `package:flutter` is what
makes 674 assertions runnable in a plain Dart VM in seconds.

---

## Safety notes

The camera is a **single-threaded HTTP server with one Wi-Fi client slot** and no
authentication. Three rules exist because breaking them cost real hardware time.
They are enforced in code, not merely documented:

1. **Queueing a download does not start a transfer.** The sync bar starts it.
2. **An already-synced photo is never fetched from the camera again.** The viewer
   reads the phone's own copy; an explicit request is required to fetch.
3. **Pause/resume of the live-view stream is off by default** because it was
   never verified on real hardware.

Also: the camera's access point accepts **one client at a time**. A phone and a
PC cannot both be on it, and the second one's failure looks like a wrong
password.

---

## Contributing, security, licence

- `CONTRIBUTING.md` — what the project will and will not accept.
- `SECURITY.md` — how to report a vulnerability, and why the camera's own
  protocol is out of scope.
- `CHANGELOG.md` — every notable change.
- `LICENSE` — **Apache License 2.0**. `NOTICE` lists the third-party components
  this app is built from and the notices their licences require.

This project is an independent third-party controller. It is not affiliated
with, endorsed by or supported by the manufacturer of the YI M1. "YI", "Xiaoyi"
and "YI M1" are their owners' trademarks and are used here only to say what the
software is for. No vendor artwork, logo or asset is bundled — the launcher icon
is the stock Flutter template icon.
