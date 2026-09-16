# Security policy

## Supported versions

**No version of this application has been released.** There is no published APK
and no release artefact, and the `[Unreleased]` section of `CHANGELOG.md` is the
only thing that exists.

Security reports are still welcome and will be taken seriously. Just be aware
that "fixed in version X" cannot be said yet, because there is no version X.

## Reporting a vulnerability

Use **GitHub's private vulnerability reporting** on this repository:
*Security* → *Report a vulnerability*. That opens a private advisory visible only
to the maintainer.

There is deliberately no email address for this project. The commit identity is a
GitHub noreply address, and the maintainer's real address is kept out of the
history on purpose. If private reporting is unavailable to you for some reason,
open a normal issue that says only *"I have a security report and need a private
channel"* — with no details — and wait.

**Do not open a public issue containing an exploit, a working proof of concept, or
credentials.**

This is a single-maintainer project worked on in spare time. Expect a first
response measured in days rather than hours, and no service-level commitment.
That is an honest statement of capacity, not a lack of interest.

---

## What is in scope

This project is unusual in that it is a **client for a device that has no
security model at all**. Being precise about which half of that is ours is the
most useful thing this file can do.

**In scope — defects in this application's own code:**

- The BLE pairing flow, handling of the camera's Wi-Fi credentials, the Wi-Fi
  join, the capture interlock, the sync engine and its ledger, and MediaStore
  publishing — anything that writes to the user's gallery.
- Storage of the persisted pairing record: the camera's SSID, passkey, pairing
  token and reference id. It is written to app-private storage, and anything that
  makes it readable by another app, or that leaks it into a log, a crash report, a
  screenshot path or an exported file, is a real finding.
- The release process: a way to get test instrumentation (`MARIONETTE`,
  `FAKE_CAMERA`, `DIRECT_CAMERA`) or a missing permission into a release APK, or
  a way to make the build's artefact assertions pass without actually holding.
  All three seams are compile-time switches and the build asserts their marker
  strings are absent from the shipped artefact; a way around that is a finding.
- The `tools/` scripts that talk to the camera, where they parse input from
  somewhere untrusted — a hostile Wi-Fi access point, a hostile BLE peripheral.
- Anything in this repository that discloses a third party's data.

**Known and accepted — please do not report these as vulnerabilities:**

- **The camera's protocol is plaintext and unauthenticated, by design of the
  hardware.** The pairing key space is 0–99998; the session check is CRC32, which
  is an integrity check and **not** authentication; the HTTP control interface
  takes a single unauthenticated GET parameter; there is no CSRF protection and no
  pairing beyond a physical button press. This is a property of the camera, not a
  defect in this app, and it is why the app treats the camera's access point as a
  trusted network. `app/docs/PROTOCOL.md` §2.3 states it in full; the app's UI
  does not describe the pairing as "secure".
- **The camera's access point accepts one client at a time** and has no internet
  passthrough. While a transfer runs, the phone is offline. That is the hardware,
  and it is why the sync design is resumable.
- **The app asks for location and nearby-Wi-Fi permissions.** On Android below
  API 33, joining a Wi-Fi network with `WifiNetworkSpecifier` requires location
  permission even though this app never derives a location. The permissions are
  declared with `neverForLocation` where the platform allows it, and the reasoning
  is written out in `app/android/app/src/main/AndroidManifest.xml`. This is a
  platform requirement, not over-asking.
- **The app can command destructive camera operations** — deleting files,
  closing the camera's access point, starting a firmware update. Having the
  capability is not a vulnerability; a way to reach it without the user asking
  is.
- **The camera has no real-time clock and no watchdog.** Two consequences are
  visible in the app: it must set the camera's clock after every power-up, and it
  refuses to shoot in the camera's `Continuous` drive mode. Both are responses to
  the hardware, not bugs.

---

## What a report should contain

- Which part of the project: the app (BLE, Wi-Fi join, sync, gallery), the build
  and release process, or a specific script.
- What you did, what you expected, what happened.
- Whether a camera was involved, and its firmware version if so — the project has
  been tested against one unit, and behaviour may differ elsewhere.
- A minimal reproduction if you have one.

Please do not attach credentials, logs containing other people's device
addresses, or the contents of anyone's photo library.

## Credit

Reporters are credited in the advisory and in `CHANGELOG.md` unless they ask not
to be.
