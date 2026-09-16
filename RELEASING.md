# Releasing

Everything a maintainer needs to cut a release, and the decisions behind each step.
Two of those decisions are not reversible later — the signing key and the application
ID — so they are written down here rather than remembered.

`yi-m1-controller-app` is the **release** repository. The reverse-engineering work, the
firmware, the captured credentials and the BLE census live in a separate **private**
repository named `yi-m1-controller`, which is never published. Nothing in this
repository refers to it except to say that it exists: a reader here should never be
sent looking for material they cannot have.

---

## 1. Verify before you build

```bash
cd app
dart tool/verify.dart
```

That runs the analyzer, the pure-Dart logic suites (which must keep compiling without
Flutter — it is an architectural invariant, not a preference), the widget tests, and
the leak scan over this repository. It also runs the self-tests of the leak scan and of
the APK check, because a check that cannot fail is worse than no check.

To check a built artifact as well:

```bash
flutter build apk --release --target-platform android-arm64 --dart-define=BUILD_STAMP=$(git rev-parse --short HEAD)
dart tool/verify.dart --apk build/app/outputs/flutter-apk/app-release.apk --stamp $(git rev-parse --short HEAD)
```

Step 8 re-reads the **packaged** manifest (the required permissions), the dex and
`libapp.so` (test instrumentation must not be there), `libapp.so` again for the build
stamp, and the signature — and it refuses a debug-signed artifact.

---

## 2. The signing key

### Where it lives

**In the private development repository, tracked on purpose:**

| File | What it is |
|---|---|
| `app/android/keystore.properties` | `storeFile`, `storePassword`, `keyAlias`, `keyPassword` |
| `app/android/keystore/yi-m1-release.jks` | the key itself |

That repository is private forever and already contains the camera's Wi-Fi credentials,
a pairing token and a BLE census of other people's devices, so a signing key is not a
new class of thing there. What it *does* buy is the thing that makes a self-held key
safe: **git history is the backup**. A signing key whose only copy is one file on one
disk is how an application becomes impossible to update — Android will not accept an
update signed by a different key, so the failure mode is "all users must uninstall and
reinstall", or "this app is finished".

`app/android/.gitignore` in that repository carries two negation lines
(`!keystore.properties`, `!keystore/*.jks`) so that `git add` will actually track them.
That is the only place they are exceptions.

### Where it must never be

**Here.** Not in this repository, not in its history, not in a release asset, not in a
log pasted into an issue.

- The export drops `app/android/keystore.properties` and `app/android/keystore/**` by
  explicit name, and a file under `app/` that nobody classified stops the export.
- `tools/verify_release.dart`, which runs as part of `dart tool/verify.dart`, fails on a
  file named `keystore.properties`, `key.properties`, `*.jks`, `*.keystore`, `*.p12`,
  `*.pem` or `*.pk8`, and on the *content* shapes `storePassword`, `keyPassword`,
  `keyAlias` and `-----BEGIN … PRIVATE KEY-----`, and on a `.gitignore` line that stops
  ignoring any of them.
- The APK check fails an artifact signed with the public Android debug key
  (`CN=Android Debug`), so a debug-signed build cannot be published by accident.

A key that can impersonate this app cannot be un-published. Forks and caches keep
copies, which is why the answer is "it was never there" rather than "it was removed".

### Generating it

Once, on the maintainer's machine, **inside the private development repository**:

```bash
cd app/android
mkdir -p keystore
keytool -genkeypair -v \
  -keystore keystore/yi-m1-release.jks \
  -storetype PKCS12 \
  -alias yi-m1-release \
  -keyalg RSA -keysize 4096 \
  -validity 10950 \
  -dname "CN=yi-m1-controller-app, O=xiaobaiwud12, C=CN"
```

* `-keysize 4096` — Play requires at least 2048 for an upload key; 4096 costs nothing
  here and the app is sideloaded anyway.
* `-validity 10950` — 30 years. **Expiry is the same failure as loss**: after the
  certificate expires, Android refuses updates signed with it. Google's own guidance is
  "later than 22 October 2033, preferably 25+ years"; take the long number.
* `-alias yi-m1-release` — the alias is part of the identity you type later; keep it.
* `-storetype PKCS12`, not the legacy JKS format: `keytool` defaults to PKCS12 in
  current JDKs and PKCS12 is what modern tooling expects.
* **Write the passwords down somewhere that is not the laptop.** They are in
  `keystore.properties`, which is in git — that is the backup — but a password you
  cannot read is a key you do not have.

Then create `app/android/keystore.properties`:

```properties
storeFile=keystore/yi-m1-release.jks
storePassword=<the store password>
keyAlias=yi-m1-release
keyPassword=<the key password>
```

`storeFile` is **relative to `app/android/`** so that the file works from any checkout.
An absolute path there would be a machine-specific path in a repository — the same
defect this project removed from `gradle.properties`.

Then commit both files **in the development repository** and confirm they are gone from
this one:

```bash
# in the development repository
git add -f app/android/keystore.properties app/android/keystore/yi-m1-release.jks
git status --porcelain

# then, in the export tree before it is committed
dart run tool/verify_release.dart --root ..
```

### How the build reads it

`app/android/app/build.gradle.kts` reads `keystore.properties` (looked up as
`rootProject.file("keystore.properties")`, i.e. `app/android/keystore.properties`) and
uses it for the `release` build type.

**A release build with no key fails.** That is deliberate: until 2026-09-16 the release
build type was `signingConfig = signingConfigs.getByName("debug")` under a Flutter
template `TODO`, which means every "release" APK this project produced was signed with
a *publicly known* key — fixed alias, fixed password, shipped in every Android SDK. Any
user of such a build can be served an update built by anybody. A silent fallback to
that key while reporting success is the defect class this project spent a day fixing,
so the missing key is an error, not a warning.

For a **local, non-distributable** build — which is what a contributor without the key
needs — the debug signature is available explicitly and loudly:

```bash
flutter build apk --release --android-project-arg=allowDebugSigning=true
# or: cd android && ./gradlew assembleRelease -PallowDebugSigning=true
```

It prints `WARNING: release build is DEBUG-SIGNED …` and `verify_apk.dart` refuses the
result unless you also pass `--allow-debug-signing`. Do not publish such an artifact.

### The first public APK must be signed with this key

Users cannot switch signing keys. Android treats a different key as a different
application: the update is rejected, and the only path is uninstall and reinstall —
which loses the app's data.

**Nothing has been published yet, so the window is open and nothing is lost.** The
first APK anybody installs must be signed with the key above.

### Play later

The decision was: own key, sideload through GitHub Releases, no Play Store for now.
That decision is reversible in one direction only, and in the good one: an app
published under a self-held key can still move to Play later **with Play App Signing**,
as long as the upload key (this key, or a new one you enrol with Google) is kept. What
is not recoverable is publishing a *debug-signed* build first, so don't.

If Play is ever on the table, `analysis/63` §7.3 in the private repository has the
policy sweep with URLs, and §4.3 has the release-notes template.

---

## 3. Cutting a release

1. **`app/pubspec.yaml`'s `version:` is the artifact's identity.** Bump it there — it is
   the only place: `versionName` and `versionCode` are derived from it. `CHANGELOG.md`
   must mention the same version, and `tools/verify_release.dart` fails if it does not.
2. **Commit everything first.** A build from a dirty tree cannot be reproduced from any
   commit, and the build stamp says `-dirty` when it happens.
3. **Verify**: `cd app && dart tool/verify.dart`.
4. **Build** with a stamp that names the commit:
   `flutter build apk --release --target-platform android-arm64 --dart-define=BUILD_STAMP=$(git rev-parse --short HEAD)`
5. **Assert the artifact**: `dart tool/verify.dart --apk <apk> --stamp <stamp>`.
   It checks the packaged permissions, the instrument markers, the stamp and the
   signature; for a structural dump as well, if you have build-tools:
   `aapt2 dump xmltree --file AndroidManifest.xml <apk>`.
6. **Record the fingerprints**, because they are what lets a user check what they
   installed:
   ```bash
   apksigner verify --print-certs <apk>
   sha256sum <apk>          # Windows: Get-FileHash <apk> -Algorithm SHA256
   ```
   Compare the certificate's SHA-256 against the one you recorded the first time. It
   must never change; if it does, **do not publish** — you are signing with the wrong
   key.
7. **Tag** `v<versionName>` on the commit the build came from.
8. **GitHub Release** with the APK attached, and release notes containing:
   * `versionName` / `versionCode` / build stamp;
   * the APK's SHA-256 and the signing certificate's SHA-256;
   * the toolchain: Flutter, Dart, JDK, Gradle, AGP, Kotlin, compileSdk/targetSdk/minSdk;
   * **what a user can see that changed**, and how to reach it (which screen, which
     button, what it reads) — a feature nobody can find is a feature that was not
     delivered;
   * **what is still not verified**, copied from README.md rather than re-worded;
   * the corresponding source: this repository at tag `v<versionName>`.
9. **Register the app** for Android developer verification (free Limited Distribution
   account, up to 20 devices). From 2027 an unregistered app needs a 24-hour advanced
   flow or ADB to install, and updates fail. The cost of doing it now is a form; the
   cost of not doing it is users who cannot install the app.

---

## 4. If something goes wrong

| Situation | What to do |
|---|---|
| Key lost, no backup | Nothing can be done for existing users: a new key means a new app identity. This is why it is committed in the private repository. |
| Password lost, keystore intact | The keystore is PKCS12; without the store password it is unusable. Same answer as above, so keep the password with the keystore. |
| Keystore committed here by accident | Treat the key as compromised: generate a new one **before** the first public release, and never publish the repository containing it. If it is already public, the app's identity is public and any published build can be impersonated. |
| Debug-signed APK published | Withdraw it and publish a correctly signed build with a higher `versionCode`. Users must uninstall the debug-signed build — Android will not update across keys. |
| A release is bad | You cannot un-publish, but you can publish a higher `versionCode` immediately. There is no update mechanism inside the app (deliberately: `REQUEST_INSTALL_PACKAGES` may not be used to update your own app), so users find updates by looking at the releases page. |

---

## 5. Play Store: drafts, if the decision ever changes

The maintainer's decision is **no Play Store for now**; GitHub Releases and sideloading
are the distribution channel. This section is a draft so that the work is not started
from nothing, and **every answer below is derived from what the app does, not from a
policy reading**. Anything that could not be established from the code is marked.

### 5.1 Privacy policy

Play requires a privacy policy URL for **every** app, including one that collects
nothing, and it must be publicly reachable, not a PDF, not geofenced, and not editable.
A draft of the text:

> **yi-m1-controller-app — privacy policy**
>
> This app controls a YI M1 camera that you own, over your own local network. It has no
> server, no account, no analytics, no advertising and no third-party SDK that reports
> anything anywhere.
>
> * **Camera Wi-Fi credentials.** During pairing the app reads the camera's own
>   network name and password from the camera over Bluetooth. They are stored on your
>   device only, in the app's private storage, and are sent only to that camera.
> * **Photos and videos.** The app lists files on the camera's memory card and, when
>   you ask it to, downloads the ones you chose into your phone's own gallery
>   (MediaStore) or into the app's private storage. Nothing is uploaded anywhere.
> * **Bluetooth and location.** Bluetooth is used to find and pair with the camera. On
>   Android 11 and older the system requires location permission for Bluetooth
>   scanning; the app never reads or stores your location. (Android 12+ uses the
>   `BLUETOOTH_SCAN` permission, which no longer requires location.)
> * **Photos you never asked for.** The app does not upload, share or analyse your
>   photos. It has no code path that sends anything off your device except commands
>   and file requests to the camera's own address.
> * **Data retention and deletion.** Uninstalling the app deletes everything it stored.
>   There is no account to delete and no server-side data to request.
> * **Contact.** Open an issue at
>   <https://github.com/xiaobaiwud12/yi-m1-controller-app/issues>.
>
> *Not established, and deliberately not claimed:* whether a policy is needed for a
> device-to-device LAN transfer under Google's definitions (their "collect" means
> "transmitting data off the user's device", which this does not do, but no official
> example covers a camera on the same network).

### 5.2 Data safety form

Draft answers, and where each comes from:

| Question | Draft answer | Basis |
|---|---|---|
| Does your app collect or share any of the required user data types? | **No** | No network destination other than the camera's own address; no analytics, ads or crash reporting; the only permissions that touch user data are for the camera link and for writing to your own gallery |
| Is all user data encrypted in transit? | Not applicable (nothing is transmitted off the device) | Plain HTTP is used **to the camera only**, on the camera's own access point; `network_security_config.xml` permits cleartext for `192.168.0.10` and nothing else |
| Do you provide a way for users to request data deletion? | Not applicable — no account | — |
| Data types: photos/videos | Not collected. The app *writes* to your gallery at your request | `MediaStorePublish` (Kotlin) and `MediaStoreSink` (Dart) |
| Data types: location | Not collected | `ACCESS_FINE_LOCATION` is declared for Bluetooth scanning on Android ≤ 11 and is never read by app code |
| Data types: device or other IDs | Not collected | no advertising ID, no device identifier is read |
| Data types: app activity / diagnostics | Not collected | no logging leaves the device; logs are `debugPrint` to logcat only |

**Marked as not established:** the form must be completed even for a "collects nothing"
app, and the definitions' treatment of a same-network device is not covered by any
official example. If Play is pursued, re-read
<https://support.google.com/googleplay/android-developer/answer/10787469> and
<https://support.google.com/googleplay/android-developer/answer/10144311> at that time:
the policy text changes every year.

### 5.3 Other Play obligations, from the private audit

* `ACCESS_FINE_LOCATION` needs a Play Console **declaration form** — from 2027-01-27 for
  all apps. The use here ("connecting to nearby Bluetooth/Wi-Fi devices on Android 11
  or lower") is explicitly listed as acceptable, but the reason has to be written out.
* `.aab` and Play App Signing, and the upload key rules.
* A reviewer cannot test this app: it needs a discontinued camera. Play allows a test
  account/instructions and a demo video for exactly this, and the "limited
  functionality" policy is the one that would otherwise bite.
* Nothing in the app may imply affiliation with the manufacturer. The in-app licence
  page (`btn-licences` in the app bar) already states that it is unofficial, and no
  vendor artwork, font or logo is bundled.

---

## 6. What this repository cannot verify, and why that is accepted

It contains the application and nothing else. Specifically it does **not** contain the
firmware work, the reverse-engineering tools, the analysis notes that most design
comments cite (`analysis/NN`), or the captured credentials.

The trade is deliberate: the alternative was publishing a repository that carries the
camera's Wi-Fi passkey, a pairing token and about 45–55 addresses of *other people's*
Bluetooth devices, none of which can be un-published. So the protocol conclusions, the
shutter behaviour, the album sync and the MediaStore path are documented in
`app/docs/PROTOCOL.md` with confidence markers, and a reader can check the code against
that document — but they cannot re-derive it. `dart tool/verify.dart` says so at the end
of every run rather than leaving it to be discovered.
