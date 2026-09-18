# Contributing

This is a **single-maintainer project**, in the repository
`yi-m1-controller-app`. That is a description, not a gatekeeping policy: patches,
bug reports and hardware results are welcome, and the fastest way to get a change
accepted is to make the check that proves it come with it.

> The name ends in `-app` because the reverse-engineering work that produced this
> code lives in a separate, private repository. Do not go looking for it; the
> comments in `app/lib/` that cite `analysis/NN` refer to notes that are not
> published, and `dart tool/verify.dart` counts them for you rather than letting
> you wonder whether your clone is broken.

---

## The one rule

**Every new capability needs a check that can actually fail.** "The code is
written" is not done. A bug fix should arrive with the check that would have
caught it, and that check stays.

This project has paid for that rule repeatedly. The permission assertion in the
build exists because `CHANGE_NETWORK_STATE` was missing from a shipped APK for
three rounds while the manifest *source* looked complete. The misspelled-name
guard exists because a verification command once reported success while
silently skipping the layer that was misspelled. And an all-transparent golden
baseline once made a screenshot test pass under every possible rendering, which
is worse than having no test at all — it was deleted rather than fixed.

The two release checks carry their own negative controls for the same reason:
`dart tool/verify_release.dart --self-test` plants a passkey shape, a MAC, a
hostname, a keystore and a vendor binary in a temporary tree and fails if the scan
does not report each one; `dart tool/verify_apk.dart --self-test` builds a synthetic
APK with a missing permission, an instrument marker, no build stamp and a debug
certificate, and does the same. `dart tool/verify.dart` runs both.

Assertions should be as close to the defect as possible: count widgets with
`find.byKey` rather than matching text, measure rendered size rather than
recomputing the layout maths, and inspect the built artefact rather than trusting
the source that produced it.

---

## Getting set up

```powershell
cd app
flutter pub get
dart tool/verify.dart             # one command: analyzer, logic suites, widget tests,
                                  # the leak scan, and the checks' own self-tests
```

The individual pieces are still there if you want a faster signal:

```powershell
dart analyze                      # should be silent
dart tool/verify_transport.dart   # pure Dart VM, no Flutter engine
dart tool/verify_sync.dart
dart tool/conformance.dart
flutter test                      # the widget suite
```

Nothing machine-specific has to be edited first — the JDK pin and the missing Gradle
wrapper are both gone. If your `JAVA_HOME` is JDK 24 or newer, set
`org.gradle.java.home` in `~/.gradle/gradle.properties`; `README.md` explains why.

**You do not need the camera to contribute to the protocol, transport, sync or UI
layers.** Those have 686 assertions and a widget suite that run without hardware.
What you cannot verify without hardware is anything involving pairing, joining the
camera's access point, the wire protocol, the live-view stream, or whether a photo
actually appears in the system gallery. Say which side of that line your change is
on, and do not claim a hardware result you did not get.

---

## What a change needs to include

1. **The narrowest check that covers it.** Do not run a full hardware pass for a
   pure-logic change, and do not push a logic question onto hardware — that turns
   the maintainer into a CI system with a turnaround measured in hours. The
   `dart tool/verify_*.dart` scripts and `flutter test` are seconds, not hours.
2. **A short note in your pull request saying what you ran and what it said.**
   "It builds" is not a verification result; if you did not run something, say so
   rather than leaving it implied.
3. **A `CHANGELOG.md` entry** if the change is notable, under `[Unreleased]`. The
   entry must say what a *user* would notice, not what the diff did.
4. **A delivery note, if you are delivering a build.** List every user-visible
   change and say how to reach it: which page, which control, what it says or
   which icon it uses. This came from a real failure — landscape full-screen mode
   was built, verified and handed over, and the owner never found it because the
   note did not mention it. "Internal only, no visible change" is also worth one
   line. For a new control, include its `ValueKey` so the next person can drive
   it.

### Things that will block a pull request

- Weakening or deleting an existing assertion to make a change pass. If a check
  is wrong, say so and fix the check; do not remove it quietly.
- Building a release with `FAKE_CAMERA`, `DIRECT_CAMERA` or `MARIONETTE`
  defined, or bypassing the artefact assertions that are supposed to catch it.
  The build is supposed to refuse; if it does not, that is the bug.
- Breaking the plain-VM invariant: `tool/verify_transport.dart` and
  `tool/verify_sync.dart` must keep compiling and running in a plain Dart VM, without
  Flutter, so the 686 assertions finish in seconds. **That is the rule the tree actually
  enforces**, and it is deliberately narrower than "these layers are Flutter-free":
  `app/lib/protocol/` and `app/lib/sync/` are clean, but four files in `app/lib/transport/`
  do import Flutter (`file_pairing_store.dart`, `flutter_ble_transport.dart`,
  `screen_control.dart`, `wifi_joiner.dart`) — which is exactly why the two verifiers avoid
  them. Implementations that need Flutter belong in `app/lib/platform/`, and
  `app/lib/protocol/viewfinder_layout.dart` is deliberately free of even `dart:ui`.
- Adding an interactive control without a `ValueKey<String>`. A control without a
  key cannot be located reliably — text changes and coordinates drift — which
  makes it unverifiable.
- Silencing an `[NewApi]` Android Lint error with an annotation instead of
  guarding the call. An unguarded API call is an `Error`, not an `Exception`: it
  passes straight through the file's own `catch` and the platform channel's
  `RuntimeException` handling, and the call simply never answers.
- Vendoring, bundling or copying assets out of the vendor's official application.
  None of it is licensed for reuse, and the repository deliberately carries no
  vendor asset at all — including the launcher icon, which is the stock Flutter
  template icon.
- Committing credentials, device identifiers or logs captured in a place where
  other people's devices were visible. A camera's Wi-Fi passkey, its SSID, its
  Bluetooth address and a scan of the surrounding devices are all things that
  must not enter this repository.

---

## Things this project has deliberately rejected

Already evaluated; please do not re-open without new information.

| Rejected | Why |
|---|---|
| **A UI-automation framework with native hooks** | Its value is native interaction, and this project needs only "permission dialogs" and "Wi-Fi join", both of which are tested at the injection layer instead. |
| **Robolectric** | Only a few `MainActivity` branches would benefit, and Android Lint already catches six of them mechanically. |
| **Merging the `verify_*.dart` scripts** | Measured: of the then-507 assertions only 2 were duplicates and the imports barely overlap. The split is correct. |
| **A hand-rolled screenshot diff** | `matchesGoldenFile` is the same feature, built into `flutter_test`. |
| **A CI service** | A single-maintainer project with a good local entry point does not need one. There is deliberately **no** CI configuration in this repository, and adding one is out of scope. |
| **A coordinate-tapping test script** | The app's controls already carry widget keys, which locate them reliably where coordinates do not. |

---

## Practical notes

### Working on the camera protocol

The camera is a **single-threaded HTTP server with one Wi-Fi client slot** and no
authentication. The three rules in `README.md` §"Safety notes" are load-bearing,
not stylistic. `app/docs/PROTOCOL.md` is the reference the client is written
against, and it carries a confidence marker on every entry — **do not add a value
to it by guessing**, because a wrong value makes the camera silently reject a
command rather than return an error.

### Working on the UI

Interactive controls carry `ValueKey<String>` names in the `btn-*`, `toggle-*`
and `banner-*` families. Two things learned the hard way and worth knowing before
you trust a test or a screenshot:

- **A toggle's state is not visible in the widget tree.** Point at it, look at a
  screenshot, and never infer "it is on" from "I tapped it once".
- **A non-interactive element — a histogram, a focus marker — does not appear in
  an element listing.** "Not found in the list" is not evidence that it is
  missing; take a screenshot or measure its rect.

### Scratch files

`app/build/` and `app/.dart_tool/` are gitignored. Do not commit build output,
captured frames or probe dumps.

### Commit messages

Commit subjects here are written as **conclusions**, not as categories. "The
shutter never reached the camera: the interlock held a client from before the
link existed" rather than "fix capture bug". That is deliberate: a subject which
names the actual finding saves the next reader from re-deriving it, and
`CHANGELOG.md` is written from those subjects.

### Machine-specific files

`app/android/gradle.properties` records this maintainer's JDK path and
`app/android/.gitignore` excludes the Gradle wrapper jar. Do not commit your own
paths into the former; if you need a different value locally, keep it out of the
diff.

---

## Licence

Contributions are accepted under **Apache-2.0**, the licence this project already
carries, with no separate contributor licence agreement. By opening a pull
request you confirm you have the right to submit the work under that licence, and
that it is not copied from the vendor's official application or from any source
that forbids it.

`NOTICE` records the third-party components the app is built from and the
notices their licences require. If your change adds a dependency, add its entry
there in the same pull request — attribution is the *only* obligation several of
those licences impose, so it is the one thing that must not be forgotten.
