<!--
  Sized for a single-maintainer project: if a section does not apply, write
  "n/a" and move on rather than leaving it blank. The maintainer is also the
  reviewer, so this is a record for the next session more than a gate.
-->

## What this changes

<!-- One paragraph. Say what a user would notice, not what the diff did. -->

## What you ran, and what it said

Tick what you actually ran. The reason this list exists: the whole suite below
costs seconds, and skipping it has cost this project hardware rounds.

- [ ] `dart analyze` — always
- [ ] `dart tool/verify_transport.dart`, `verify_sync.dart`, `conformance.dart` — `lib/protocol/**`, `lib/transport/**`, `lib/sync/**`
- [ ] `flutter test` — `lib/ui/**`, `lib/state/**`, `lib/platform/**`
- [ ] Android Lint — platform code, manifest, `android/**`
- [ ] Kotlin JVM unit tests — `android/app/src/test/**`
- [ ] `flutter build apk --release` — only if this touches the platform contract
      or the shipped artefact; it is heavy, so say why you ran it
- [ ] Not run — <!-- say which, and why -->

Result: <!-- all green / FAILED: <what> / not run, and why -->

## The check that proves it

<!--
  Every new capability needs a check that can actually fail. Name it, and say
  what it would catch. If this change has no check, say so explicitly and say
  why — that is a legitimate answer, but it needs to be written down.
-->

- Check added or extended:
- What it would catch that nothing caught before:
- If a bug fix: the check was written **before** the fix — <!-- yes / no -->

## User-visible changes (required for a build)

Landscape full-screen mode once shipped, verified, and went unnoticed because the
delivery note did not mention it. List every entry and say how to reach it.

| Change | Where to find it | `ValueKey` |
|---|---|---|
|  |  |  |

- [ ] Internal only, no user-visible change — <!-- say so in one line above -->

## Constraints

- [ ] `lib/sync/`, `lib/transport/` and `lib/protocol/` still contain no
      `package:flutter`
- [ ] Any new interactive control has a `ValueKey<String>`
- [ ] No existing assertion was weakened or deleted to make this pass
- [ ] The build's artefact assertions are untouched
- [ ] No CI configuration was added — that was evaluated and rejected
- [ ] This does not introduce pause/resume of the live-view stream as a default,
      nor drive the camera while the preview is streaming
- [ ] No credentials, pairing tokens, third-party device addresses or
      photo-library contents are included in the diff or in any log committed
      with it
- [ ] No asset copied from the vendor's official application

## Documentation

- [ ] `CHANGELOG.md` `[Unreleased]` entry added, saying what a user would notice
- [ ] If this adds a dependency, its entry is added to `NOTICE` in the same pull
      request

## Licence

- [ ] I have the right to submit this under **Apache-2.0**, it is my own work or
      compatibly licensed, and it is not copied from the vendor's official
      application.
