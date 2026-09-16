/// The phone's haptic feedback, and the four places this app is allowed to use it.
///
/// ## Why this file exists at all, and why it has no wrapper class
///
/// `HapticFeedback` is three lines of `package:flutter/services.dart` and needs no
/// permission on Android, so a class wrapping it would be a layer over nothing. What
/// is worth writing down is **where** it is called and **what it costs to call it in
/// the wrong place**, because the dial offers two hooks that look like competitors and
/// are not.
///
/// The widget-level reasoning lives where the calls are made
/// (`ui/widgets/exposure_dial.dart`, `ui/pages/live_view_page.dart`,
/// `ui/pages/album_page.dart`); this file is the shared vocabulary — which
/// `HapticFeedbackType` each gesture means, and the platform facts behind that choice.
///
/// ## The four things that tick, and the one that deliberately does not
///
/// | gesture | call | the platform's own name |
/// |---|---|---|
/// | the finger crossing one dial detent | [detentTick] | `CLOCK_TICK` |
/// | the value leaving the app for the camera | [commandSent] | `CONTEXT_CLICK` |
/// | the shutter's press | [shutterPress] | `VIRTUAL_KEY` |
/// | the shutter's release | [shutterRelease] | `KEYBOARD_TAP` |
/// | a photo tile selected / deselected | [detentTick] | `CLOCK_TICK` |
///
/// **Not** on: preview start/stop, the settings panel, the histogram and grid toggles,
/// mode changes, page navigation, sync progress. The user's instruction was *"anything
/// else is optional; do not sprinkle it around"*, and a phone that buzzes for
/// navigation is a phone whose buzz stops meaning anything.
///
/// ## Why the dial has two calls and they are not rivals
///
/// A turning dial reports two different things, and the first version of this feature
/// only had the second:
///
/// * **the finger passed a detent** — continuously, for as long as the drag lasts. That
///   is what makes a detented control feel detented, and it is [detentTick], the
///   lightest tick the platform has.
/// * **the value actually left for the camera** — once, when the coalescer releases it.
///   That is [commandSent], and it is heavier because it is a different statement: not
///   "the control moved" but "the camera was told".
///
/// The reported defect was the shape of having only one: *"there is no per-detent tick,
/// it only ticks when I let go — and the sensation while turning should be separated
/// from the sensation when the value settles."* Both halves were true at once, because
/// `DialCoalescer` **holds every value while the finger is down**: with the tick only on
/// the send side, a whole drag was silent and then clicked once on release. The fix is
/// the second hook, not the removal of the first.
///
/// ## Why `CONTEXT_CLICK` for the send, given the shutter refuses it
///
/// [shutterRelease] deliberately avoids `heavyImpact`: on API 23+ it is
/// `CONTEXT_CLICK`, the family Android uses for a long-press pop, and "holding" is
/// exactly the shutter's **press** half — two calls the platform may render as one
/// sensation is the failure that pair is avoiding.
///
/// The dial has no such conflict. `analysis/60` §10.15.5 enumerated every input path in
/// `exposure_dial.dart` — vertical drag, tap-half, two arrow buttons — and there is
/// **no long press anywhere on a dial**, so nothing a dial does can be confused with a
/// context click. What the dial needs is a pair that is tellable apart *by strength*,
/// and `CLOCK_TICK` against `CONTEXT_CLICK` is the platform's own light/heavy pair of
/// clicks. The four constants in use are therefore four different ones:
/// `selectionClick` / `heavyImpact` / `lightImpact` / `mediumImpact`, which
/// `test/haptic_feedback_test.dart` asserts as a set rather than trusting this comment.
///
/// ## What is `[V]` and what is `[H]`
///
/// `[V]` — that a `flutter/platform` method call is made, how many, and with which
/// argument; `test/haptic_feedback_test.dart` counts them off the method channel, by
/// kind, for real gestures.
///
/// `[H]` — whether a given phone renders `CLOCK_TICK` and `CONTEXT_CLICK` as different
/// sensations, how strong either is, and whether the phone's haptic engine is on.
/// **None of that is verifiable here** and none of it is claimed. On Android these are
/// `View.performHapticFeedback`, which is exactly the mechanism a system keyboard and
/// the system's own widgets use — so this app requires no `VIBRATE` permission, respects
/// the system's haptic setting, and inherits whatever quality that mechanism has.
///
/// ## The shutter's ticks are not "one per command", and that is deliberate
///
/// The dial's [commandSent] is defined as *"the command left"*. The shutter's are not, and
/// cannot be: in a **bursting** drive mode the press sends `RCDoShooting` and the release
/// sends `RCCancelShooting`; in `Single` the press is **refused client-side**
/// (`CaptureGuard.startBurst` — one frame per request, so there is nothing to hold) while
/// the release still sends its cancel. Defined as "one per command" the press would
/// therefore tick in some drive modes and not others, and the user's own requirement is
/// the opposite: *the user needs to know the press registered*. So the shutter ticks on
/// the two **pointer** events, which are the same in every drive mode, and what they
/// confirm is that the app received the gesture — not what the camera did with it.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// One dial detent crossed, or one album tile toggled: the selection moved.
///
/// Android `HapticFeedbackConstants.CLOCK_TICK`, iOS `UISelectionFeedbackGenerator`.
///
/// **One call per detent the finger crosses**, which is why it is hooked in
/// `_ExposureDialState._step` — the funnel every input path reaches — and not on the
/// send side. On the send side it would be one call per *gesture*, which is the
/// reported defect: a drag that crosses six detents would be silent for its whole
/// length and click once when the finger came up.
///
/// The count is checked against the readout's own travel in
/// `test/haptic_feedback_test.dart`, so "one per detent" is measured rather than
/// asserted, and nothing debounces it: a fast drag is a drum roll, not silence.
void detentTick() {
  // Fire and forget, and `unawaited` rather than a bare call so that "we are not
  // waiting for this" is written down: the platform answers with a bare
  // acknowledgement, nothing in the app can act on it, and awaiting it inside a gesture
  // callback would put a channel round trip in front of the next frame.
  unawaited(HapticFeedback.selectionClick());
}

/// The value left the app for the camera: a heavier click than [detentTick].
///
/// Android `HapticFeedbackConstants.CONTEXT_CLICK`, iOS `UIImpactFeedbackStyleHeavy`.
///
/// **One call per command that is actually sent**, so it is hooked on the gate
/// coalescer's `send` side in `ExposureDialQueue` — after `onSet`, never before it — and
/// the count is asserted equal to the number of commands the camera received. It must
/// not be moved to `_step` (that fires per detent, upstream of two pacers) and it must
/// not fire for a value `discardPending()` threw away.
///
/// The order is part of the contract: a value the page or the app refuses must not have
/// been confirmed first.
void commandSent() {
  unawaited(HapticFeedback.heavyImpact());
}

/// The shutter going down: a key was pressed.
///
/// Android `VIRTUAL_KEY`, iOS `UIImpactFeedbackStyleLight`.
void shutterPress() {
  unawaited(HapticFeedback.lightImpact());
}

/// The shutter coming up: the capture — or the burst — has been stopped.
///
/// A **different** call from [shutterPress] on purpose: the release is the half whose
/// failure strands the camera, so it must be possible to tell it from the press
/// without looking. Android `KEYBOARD_TAP`, iOS `UIImpactFeedbackStyleMedium`.
void shutterRelease() {
  unawaited(HapticFeedback.mediumImpact());
}
