/// A detented exposure dial for the camera's three exposure parameters.
///
/// ## What this is for
///
/// Every exposure parameter on this camera is reachable today through the
/// settings panel: open the panel, find the group, tap a row, pick from a modal
/// list. That is three taps and a modal to change the shutter by one stop, while
/// a live view is running and the light is changing. A camera's own body has a
/// dial for exactly this reason.
///
/// This widget is that dial. It shows the parameter, the current value and the
/// steps either side of it, and it is driven by a thumb in a band **without a
/// modal**.
///
/// ## The reason it is not a `ListWheelScrollView`
///
/// A free-scrolling wheel has no detents: the value goes wherever the finger
/// happened to stop, and hitting an exact f-stop becomes a aiming exercise. The
/// camera's parameter lists are *detented lists*, not continua — there is no
/// f/1.9 between f/1.7 and f/2.0 — so the control is a detented wheel: one drag
/// distance is always exactly one step, and the readout can only ever show a
/// value the camera accepts. That also makes the "available values" question
/// answerable: the neighbouring steps are drawn above and below the current one,
/// which is what a marked dial ring does on a real lens.
///
/// ## The reason it does not send a command per detent
///
/// The camera is a **single-threaded HTTP server with no watchdog**, and the
/// preview stream is running the whole time this control is used
/// (`AGENTS.md` §4.6). A 57-step shutter ladder crossed by one thumb, one request
/// per step, is 57 requests against a server that answers one at a time while it
/// is also pushing 800x600 JPEGs. That is how this camera is made to hang.
///
/// So the dial is **optimistic locally and paced remotely**:
///
/// * the readout moves with the finger, immediately, because a control that waits
///   for the camera to answer feels broken;
/// * nothing is sent while a spin is in progress — the in-progress value is not
///   a value the user chose, it is a value they are passing through;
/// * at most **one command per parameter per [kDialPacingWindow]** is delivered.
///   Interaction inside that window replaces the pending value instead of adding
///   to a queue, so a flurry of flicks becomes one request carrying the value the
///   user stopped on.
///
/// This is the same policy the official app implements in its own client:
/// `C3701b.java:586` cancels an in-flight request when a newer request for the
/// same parameter arrives, and `C3701b.java:594` drops a queued duplicate for the
/// same parameter. It is coalescing, not throttling-by-dropping: the *last* value
/// always wins, so the camera ends up holding what the user is looking at.
///
/// **Nothing here skips a preview frame.** The pacing changes when a command is
/// sent, never how a frame is drawn; the client-side frame-skipping that used to
/// exist is banned by the user (`analysis/41` §3.6) and is not reintroduced here.
///
/// ## What it deliberately does not know
///
/// It takes a list of legal values and a callback. It does not know the command
/// table, the wire keys, HTTP, or `AppState`; the caller resolves the camera's
/// value pool and sends the command. That keeps `lib/protocol/` free of
/// `package:flutter` (`AGENTS.md` §4.1) and keeps this file testable on its own.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../haptics.dart';

/// How long one dial stays quiet after sending a command.
///
/// The camera answers one request at a time and is streaming while it does, so
/// the ceiling that matters is *requests in flight per second*, not latency. At
/// 350 ms a determined user spinning continuously produces at most ~3 requests a
/// second — the same order as the live-view state poll the app already runs —
/// instead of one per detent, which on the 57-step shutter ladder would be dozens
/// a second.
///
/// It is deliberately not longer. The command is what makes the *camera* change,
/// and the readout in the camera's own status JSON is the only confirmation that
/// it did; a longer window delays that confirmation past the point where the
/// control feels connected to the camera.
const Duration kDialPacingWindow = Duration(milliseconds: 350);

/// The height a dial is designed at.
///
/// **61 dp, and it is measured from the content rather than chosen from a budget.**
/// The column is a 12 dp heading, a 2 dp gap, three fixed ladder lines of 12, 18 and
/// 12, another 2 dp gap, and a 3 dp position rail: `12 + 2 + 42 + 2 + 3 = 61`.
///
/// ## Why the number changed from 56, and what 56 was costing
///
/// `analysis/51` recorded 56 as the design height because 56 was what the height
/// budget allowed for three dials; the widget's own doc then claimed a dial "given
/// exactly this height draws at scale 1.0". That was never true. Measured on the
/// rendered tree, a 56 dp cell makes the `FittedBox` report **160.7 x 56.0** for a
/// design row of **175 x 61** — i.e. the whole dial was drawn at **0.918**, its 15 sp
/// value painted at 13.8 sp, and the "111 dp readout column" was really 101.9. Every
/// number in the design document was 8% optimistic, which is exactly the class of
/// error `analysis/55` found in the readout strings.
///
/// A dial given exactly this height draws at scale 1.0. Given less it is scaled down
/// as one piece by a `FittedBox`; given more it stays at this size and the band's own
/// centring places it.
const double kDialHeight = 61;

/// The height one dial gets inside the **full-screen control column's stack**.
///
/// 48 dp, and it is the answer to a measured height budget rather than a preference.
/// Two dials of [kDialHeight] plus the 4 dp between them and the 8 dp `_SideColumn`
/// puts around a child come to **132 dp**, and the column also holds the toggle row
/// (56), the shutter bar (77 with the preview running, **194** with the camera's
/// longest explanation under it) and the navigation row (42.8). Measured totals on a
/// 914x411 dp full-screen body: 421.1 dp with 61 dp dials against a 411 dp band —
/// i.e. the column would scroll, which is the mechanism `analysis/54` §4.4 records as
/// having re-broken the shutter size, and it would push the navigation row under the
/// fold. At 48 dp the same worst case is **391.4 dp**.
///
/// 48 is also Material's minimum tap target, so this is as small as the dial may be
/// drawn and still be a control rather than an ornament. It costs legibility — the
/// 61 dp row is scaled to 0.79, so the value is painted at 11.8 sp rather than 15 —
/// and that trade is recorded in `analysis/60` rather than hidden here.
const double kStackedDialHeight = 48;

/// The design width of the dial that goes in the **readout** column.
///
/// **70 dp**, which is arithmetic: that column is [kMinReadoutBand] = 78 dp wide in
/// full screen and `_BandFitted` takes 4 dp a side, so 70 is the width a dial must be
/// designed at to be drawn at scale 1.0 there.
///
/// A 70 dp dial has no room for the two 32 dp arrow buttons — they would leave 6 dp
/// for the value — so this variant is stepperless and is driven by a vertical drag or
/// a tap on the upper/lower half of the value. `_drag` already converts screen travel
/// to detents, so the feel of one step is identical to the wide dial's.
///
/// The alternative was measured and rejected: a [kDialWidth] = 175 dp dial in that
/// band is scaled to **0.42**, which is the defect `analysis/54` exists for, and
/// asking the band to be wider takes the width out of the control column, which
/// `fullscreen_band_split_test.dart` fails on below 288 dp.
const double kCompactDialWidth = 70;

/// The design width of the [ExposureDial] family.
///
/// **175 dp**, which is what the dial's own content measures: two 32 dp arrow
/// buttons plus the **111 dp** readout column that the longest label in any pool
/// needs — `f/1.7` and `1/4000` both land at 103 dp at the sizes the ladder draws
/// them, and the heading `快门 Shutter` needs 111. Measured with a `TextPainter`,
/// not chosen.
///
/// 175 fits the band it goes in, which measures **183 dp**, with 8 dp to spare. It
/// is worth being explicit that this is a fit and not a widening: on the reference
/// device the live-view page asks for 288 + 176 dp of band but only 366 dp of
/// horizontal slack exists, so `ViewfinderLayout` splits it 183 / 183 — and a dial
/// designed at 288 would be scaled to 0.6, which is how the 68 dp shutter came to
/// be drawn at 34.4 dp (`analysis/45`). Nothing here asks the page for more room.
const double kDialWidth = 175;

/// Size of the two one-step arrow buttons, and of the text they flank.
///
/// **32 dp**, and both numbers here were measured rather than chosen. The first
/// version asked for 22 dp and got a 40x40 button anyway: Material 3's
/// `IconButton` wraps its child in its own `ConstrainedBox` enforcing
/// `kMinInteractiveDimension`, and a `constraints:` argument to `IconButton` is
/// applied *inside* that box — so the layout budgeted 22 dp, the button occupied
/// 40, and the row overflowed its design width by 25 dp. Caught by the test, not
/// by eye.
///
/// At 32 dp the band's arithmetic is comfortable and the button is a real target:
/// 167 dp of dial, two 32 dp buttons, and 103 dp left for the readout — which is
/// what `1/4000` needs at the size the ladder draws it.
const double _stepperWidth = 32;

const double _headingSize = 12;

/// The height of one text line in the ladder, in the design's own units.
///
/// Explicit rather than left to the text engine. The row's lines are 10 dp, 15 dp
/// and 10 dp at `height: 1.15`; letting each pick up its own leading made the cell
/// taller than the sum of its parts, which is what the last overflow (2 dp) was.
const double _lineSmall = 12;
const double _lineValue = 18;

/// How wide the vertical position rail beside the readout is, at the design size.
///
/// **3 dp**, and it is paid for out of the readout column rather than added to the
/// dial's design width: [kDialWidth] is 175 because 111 dp of it is what `快门 Shutter`
/// and `1/4000` measure, and widening the dial instead would take 8 dp from a control
/// column that `fullscreen_band_split_test.dart` already holds at 288 dp. A rail is a
/// position indicator, not a target, so three dp at the design size — *sliding with the
/// dial*: the full-screen layout hands the compact dials a 1.3x cell, and the rail is
/// drawn at 1.3x with them.
const double kRailWidth = 3;

/// The tallest a dial may be drawn, as a multiple of its own **width**.
///
/// The dial's content is a row — rail, ladder, and (on the wide variant) two arrow
/// buttons — so it has a natural aspect ratio, and a cell taller than that ratio can
/// only be answered by drawing the same content larger. Past roughly this multiple the
/// row's *width* is the binding constraint and a `FittedBox` would start scaling it back
/// down again, which is the "control squeezed by the band" defect `analysis/45` records.
/// 0.6 is what the pieces measure: a 175 dp dial's natural height is 61, and 61/175 is
/// 0.35 — the ceiling is deliberately well above that, because the full-screen layout
/// hands a one-dial mode (P/Auto/C) a slot of 139 dp and a 175 dp-wide dial has to be
/// able to grow into it rather than leave two thirds of the slot as black band.
const double kDialAspectCeiling = 0.6;

/// Which of the three exposure parameters a dial drives.
///
/// ## Why the labels here are English, and where the Chinese went
///
/// This enum is `const`, so it cannot call `AppLocalizations`, and its `label` is
/// therefore the **fallback** — the string an untaught dial would draw. The displayed
/// heading comes from [dialHeading], which resolves the ARB in the reader's language.
///
/// The Chinese used to be written here (`'光圈'`, `'感光度'` …) because the reference
/// device is a Chinese-market body (`3.1-cn / M1CN`) and the app had exactly one UI
/// language. It now has two, and a Chinese literal compiled into a widget is a string
/// that shows up in an English UI — which is what
/// `test/l10n_hardcoded_strings_test.dart` flags. The words themselves are unchanged:
/// `l.dialAperture` is 光圈 and `l.dialIso` is 感光度, in `lib/l10n/app_zh.arb`.
///
/// The English caption stays beside the label in the heading because "光圈" alone does
/// not say *which* of the three you are about to change if you have just picked the
/// phone up — and in a language where the label already is that word, the heading drops
/// the repeated caption instead of printing it twice.
enum ExposureParam {
  /// `RCFNSet` / `Fnumber`. "FN" is the camera's own name for the aperture ring.
  ///
  /// No `prefix`: [apertureLabel] already writes the `f/`, and the first version
  /// of this file had both — the dial rendered `f/f/1.7`. Caught by asserting on
  /// the rendered text rather than on the formatter alone.
  aperture('dial-aperture', 'Aperture', 'Aperture'),

  /// `RCShutterSpeedSet` / `ShutterSpeed`.
  shutter('dial-shutter', 'Shutter', 'Shutter'),

  /// `RCISOSet` / `ISO`.
  iso('dial-iso', 'ISO', 'ISO');

  const ExposureParam(this.keyName, this.label, this.caption);

  /// The `ValueKey` this dial answers to, as `dial-<name>`.
  ///
  /// Named here rather than at the call site so the key and the widget cannot
  /// drift apart, and so a check can assert the key exists without restating the
  /// string (`AGENTS.md` §5: a control without a key cannot be clicked reliably,
  /// and therefore cannot be verified).
  final String keyName;

  /// The primary label, sized for a thumb's glance.
  final String label;

  /// The secondary label, for the case where the primary one is unfamiliar.
  final String caption;

  /// This parameter's dial identity.
  DialIdentity get identity =>
      DialIdentity(keyName, label, caption, (w) => labelFor(w, this));
}

/// What a dial calls itself, and how it writes the camera's values for a person.
///
/// ## Why this is not just [ExposureParam]
///
/// The dial was written for the three exposure parameters, and its whole *behaviour*
/// — the ladder, the detents, the pacing, the optimistic readout — has nothing to do
/// with which parameter it is: it takes a list of legal values and reports settled
/// ones. The identity is the only parameter-specific part, so it is separated here and
/// the same widget can drive the **shooting-mode ladder** (`RCSwitchDialMode`), which
/// is what the unified full-screen layout needs: ISO and the mode share the left
/// column in every exposure mode, and the right column varies (see `analysis/60`).
///
/// The alternative — a fourth [ExposureParam] — was rejected because `ExposureParam`
/// is a closed list of *exposure* parameters whose members each carry a command and a
/// pool, and the mode is neither; `ExposureDialStrip` also iterates `values` as "the
/// three exposure dials", so a fourth member would silently change what that widget
/// means.
class DialIdentity {
  /// The `ValueKey` this dial answers to, as `dial-<name>`.
  final String keyName;

  /// The primary label, sized for a thumb's glance.
  final String label;

  /// The secondary label, for the case where the primary one is unfamiliar.
  final String caption;

  /// How one of this pool's wire values is written for a person.
  ///
  /// Must be display-only: the wire value is what goes back to the camera, and a
  /// label sent instead is a protocol change (`analysis/07`).
  final String Function(String wire) labelOf;

  const DialIdentity(this.keyName, this.label, this.caption, this.labelOf);
}

/// The dial's heading, in the reader's language.
///
/// ## Why this is keyed on `keyName`, and why the enum keeps its own strings
///
/// [ExposureParam] and the two `DialIdentity` constants are `const`, so they cannot
/// call `AppLocalizations` — and their own `label` / `caption` fields are the design's
/// **fallback**, not a second source of truth. The pairing is the one `analysis/60`
/// settled — 感光度 ISO, 模式 Mode, 曝光补偿 EV, 光圈 Aperture, 快门 Shutter — and this
/// function does not change the Chinese half of it: `l.dialIso` is 感光度, exactly as
/// the enum writes it.
///
/// `keyName` is the stable id the `ValueKey`s are already built from (`dial-iso`,
/// `dial-ev`, …), so keying on it is the same decision as `LinkCodes` in the transport
/// layer: an id that already had to be unique and stable *is* the message code, and a
/// dial this function has not been taught keeps its own label rather than going blank.
String dialHeading(AppLocalizations l, DialIdentity id) => switch (id.keyName) {
      'dial-aperture' => l.dialAperture,
      'dial-shutter' => l.dialShutter,
      'dial-iso' => l.dialIso,
      'dial-ev' => l.dialEv,
      'dial-mode' => l.dialMode,
      _ => id.label,
    };

/// How an exposure-compensation wire value is written for a person.
///
/// The camera's ladder spells the sign only when it is negative (`-0.7`, `0.0`,
/// `1.3`), and a bare `0.0` between `-0.3` and `0.3` does not say which side of
/// neutral it is on. Camera bodies write the positive side with an explicit `+`, so
/// this is display only — the wire value is what goes back, and [wireForLabel]'s
/// contract is unaffected because nothing here is persisted.
String evLabel(String wire) =>
    wire.isEmpty || wire.startsWith('-') || wire.startsWith('+') ? wire : '+$wire';

/// The exposure-compensation dial: `RCEVSet`, over `kEvValues`.
///
/// The label is the English fallback; the heading in the reader's language comes from
/// [dialHeading] (`l.dialEv` is 曝光补偿). See [ExposureParam] for why the const no
/// longer holds the Chinese.
const DialIdentity kEvDialIdentity =
    DialIdentity('dial-ev', 'EV', 'EV', evLabel);

/// The shooting-mode dial: `RCSwitchDialMode`, over `kExposureModes`.
///
/// Its labels are the camera's own — `Auto`, `P`, `A`, `S`, `M`, `C` are what a
/// photographer reads on the body's own mode dial, and writing them out
/// ("Aperture priority") would be a re-spelling of a value that goes back to the
/// camera unchanged.
const DialIdentity kModeDialIdentity =
    DialIdentity('dial-mode', 'Mode', 'Mode', _modeLabel);

String _modeLabel(String wire) => wire;

/// The parameter a dial labels itself with, as a `ValueKey`.
ValueKey<String> dialKey(ExposureParam param) => ValueKey<String>(param.keyName);

/// How an f-number wire value is written for a person.
///
/// The camera sends `"1.7"`; a photographer reads `f/1.7`. The wire value is what
/// goes back to the camera, so this is display only.
String apertureLabel(String wire) => 'f/$wire';

/// How a shutter-speed wire value is written for a person.
///
/// The camera's ladder spells whole seconds with a trailing `s` (`"1s"`, `"2s"`)
/// and fractions with one too (`"1/125s"`). Camera bodies write the first as `1"`
/// and the second without the suffix, and that is not only convention: `1/4000s`
/// is the longest string in any of the three pools at 84 dp, while `1/4000` is
/// 70 dp, and the band this dial lives in is 183 dp wide.
///
/// `TIME` and `BULB` pass through untouched — they are not durations and have no
/// conventional shorthand.
String shutterLabel(String wire) {
  if (wire.endsWith('s') && wire.length > 1) {
    final body = wire.substring(0, wire.length - 1);
    return body.contains('/') ? body : '$body"';
  }
  return wire;
}

/// How an ISO wire value is written for a person.
///
/// Nothing to do — `Auto` and the numbers are already what a camera shows — but
/// it exists so the three labels are reached the same way and a caller cannot mix
/// up "the label" with "the value".
String isoLabel(String wire) => wire;

/// The label [wire] is rendered as, for a given pool.
String labelFor(String wire, ExposureParam param) => switch (param) {
      ExposureParam.aperture => apertureLabel(wire),
      ExposureParam.shutter => shutterLabel(wire),
      ExposureParam.iso => isoLabel(wire),
    };

/// The wire value a label came from, or null when [label] is not in [pool].
///
/// The inverse of [labelFor], and the reason it is worth having: a caller that
/// wants to persist or send "what the dial is showing" must get a wire value
/// back, not a label. `analysis/07` records what sending a re-spelled parameter
/// costs — the firmware's own `resulotion` is the precedent.
String? wireForLabel(String label, List<String> pool, [ExposureParam? param]) {
  for (final v in pool) {
    final l = param == null ? v : labelFor(v, param);
    if (l == label) return v;
  }
  return null;
}

/// The pacing state a dial needs, kept out of the widget tree.
///
/// ## Why this is a separate object
///
/// "How often may we talk to the camera" is a property of the *link*, not of a
/// widget. Three dials share one radio and one single-threaded server, so the
/// decision has to be observable and testable without pumping a frame — which is
/// what lets the rate limit be asserted as a count instead of argued about in a
/// comment.
///
/// The contract is one sentence: **at most one command per [window], and the last
/// value offered always wins.** Offering a value never queues a second one; it
/// replaces the pending one. There is no unbounded list anywhere in this class,
/// deliberately — a queue is how a slow consumer turns a burst into a backlog.
class DialCoalescer {
  /// Delivers a settled value.
  ///
  /// **If it returns a `Future`, that future must complete when the camera has
  /// answered** — not when the value was handed to a transport. The coalescer
  /// holds the next value until then, because the camera is single-threaded and
  /// two commands in flight is the condition `analysis/41` §4.4 records as a
  /// precondition of the known hang. Returning nothing is accepted: the pacing
  /// window alone is then the only bound, which is the weaker but still safe
  /// contract, and it is what `AppState.setParam` gives (its future resolves when
  /// the command is queued, not when the camera replies).
  final Future<void>? Function(String value) send;

  /// How long the dial stays quiet after a send. Defaults to
  /// [kDialPacingWindow]; a test passes something short.
  final Duration window;

  Timer? _timer;

  /// A spin is in progress: values are arriving but none of them is settled yet.
  bool _spinning = false;

  /// The newest value offered that has not been sent.
  String? _pending;

  /// A send has happened inside the current window.
  bool _cooling = false;

  /// A send is outstanding right now.
  ///
  /// The camera is single-threaded, so "how many commands are in flight" is the
  /// number that matters, and this is the only thing that bounds it. Without it
  /// the window alone bounds the *rate* while still letting an old request and a
  /// new one overlap — which is precisely the "two commands in flight" condition
  /// `analysis/41` §4.4 records as a precondition of the known hang.
  ///
  /// The gate is opened when the send's future completes. `Future.then` on the
  /// send alone is not enough when the caller can see the camera answer:
  /// `AppState.setParam` resolves as soon as the command is queued, so a slower
  /// request would already be overlapped by the next one.
  bool _inFlight = false;

  DialCoalescer({required this.send, this.window = kDialPacingWindow});

  /// The value waiting to be delivered, if any. For tests and diagnostics.
  String? get pending => _pending;

  /// Whether a value has been offered and not yet delivered.
  bool get hasPending => _pending != null;

  /// Offer a value. Returns immediately; nothing is delivered from here.
  void offer(String value) {
    _pending = value;
    _schedule();
  }

  /// The user's finger went down on a dial.
  ///
  /// While a spin is held, nothing is delivered even if the window expires: the
  /// values arriving are the ones being dragged *through*, and the camera should
  /// not hear about a value the user never stopped on. This is the difference
  /// between a dial and a slider.
  ///
  /// The window is deliberately **not** cancelled here. An earlier version did,
  /// on the theory that a value left over from the previous gesture should not
  /// fire mid-spin — but that also threw away every value offered while a window
  /// happened to be open, so a burst of taps ended with the screen showing one
  /// value and the camera holding another. Pacing may delay a command; it may
  /// never lose one.
  void hold() {
    _spinning = true;
  }

  /// The user's finger came up. The last value offered is the settled one.
  void release() {
    _spinning = false;
    if (_pending != null) _schedule();
  }

  void _schedule() {
    if (_spinning || _cooling || _inFlight) return;
    _fire();
  }

  void _fire() {
    final value = _pending;
    if (value == null) return;
    _pending = null;
    _cooling = true;
    _timer?.cancel();
    _timer = Timer(window, () {
      _cooling = false;
      // **This is not an optimisation, it is the correctness condition.** A value
      // that arrived while the window was closed still has to reach the camera:
      // without this line the dial shows 1/500, the camera is set to 1/125, and
      // nothing will ever reconcile the two. The window limits how *often* a
      // command is sent, never whether the last one is sent.
      _schedule();
    });
    // Not awaited: the pacing is what keeps the camera alive, and blocking on a
    // slow request would defeat it. A failure surfaces through the caller's own
    // error state (`AppState.lastError`), which is where the UI reads it.
    Future<void>? outstanding;
    try {
      outstanding = send(value);
    } catch (_) {
      // A throwing caller must not leave the dial wedged; the pacing window is
      // already the bound in that case.
      return;
    }
    if (outstanding == null) return;
    _inFlight = true;
    // `whenComplete` rather than `then`: a rejected request is still an *answered*
    // request, and holding the next value back for one the camera has already
    // refused would stall the dial for no gain.
    unawaited(outstanding.whenComplete(() {
      _inFlight = false;
      _schedule();
    }));
  }

  /// Drop anything pending without sending it — the link went away, so a value
  /// cannot be delivered and must not be retried later behind the user's back.
  ///
  /// The window is closed too. Leaving it open would make the *next* session's
  /// first offer wait out a cooldown that belonged to a radio that no longer
  /// exists.
  void discardPending() {
    _pending = null;
    _spinning = false;
    _timer?.cancel();
    _timer = null;
    _cooling = false;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _spinning = false;
  }
}

/// The three exposure dials, paced by **one** client-side queue.
///
/// ## Why one queue and not three
///
/// A dial each would each keep their own promise not to talk faster than
/// [kDialPacingWindow], and the camera would still see three independent streams
/// of requests from one radio. The camera is a single-threaded HTTP server whose
/// preview encoder is easily starved (`AGENTS.md` §4.6), so the thing that has to
/// be bounded is the **link**, not the control. Every command this strip produces
/// therefore goes through one queue: one request in flight at a time, at most one
/// started per window, and if the user turns two dials in quick succession the
/// first one is already on its way and the second waits its turn rather than
/// racing it.
///
/// The pacing is the same policy the official app implements in its own client —
/// `C3701b.java:586` cancels an in-flight request for a parameter when a newer one
/// arrives, and `:594` drops a queued duplicate — applied one level up, where the
/// unit is the link rather than the parameter.
///
/// ## What the caller supplies
///
/// Three value ladders, three current values, and one callback per parameter. The
/// strip knows nothing about the command table: `codes` names the wire values so
/// the caller can tell which dial a value came from, and the callback receives
/// that same code back.
///
/// ```dart
/// ExposureDialStrip(
///   values: {
///     ExposureParam.aperture: kFNumbers,
///     ExposureParam.shutter: kShutterSpeeds,
///     ExposureParam.iso: kIsoValues,
///   },
///   current: {
///     ExposureParam.aperture: state.fnumber,
///     ExposureParam.shutter: state.shutterSpeed,
///     ExposureParam.iso: state.iso,
///   },
///   codes: const {
///     ExposureParam.aperture: 'RCFNSet',
///     ExposureParam.shutter: 'RCShutterSpeedSet',
///     ExposureParam.iso: 'RCISOSet',
///   },
///   onSet: (command, value) => app.setParam(command, value),
/// )
/// ```
class ExposureDialStrip extends StatefulWidget {
  /// The legal values for each parameter, in the camera's own order.
  final Map<ExposureParam, List<String>> values;

  /// The value the camera is currently set to, per parameter.
  final Map<ExposureParam, String?> current;

  /// The command name each parameter writes to, per parameter.
  final Map<ExposureParam, String> codes;

  /// Deliver a settled value: `(command, wireValue)`.
  final void Function(String command, String value) onSet;

  /// Whether each parameter is settable in the current exposure mode. Missing
  /// means settable — see [ExposureDial.enabled].
  final Map<ExposureParam, bool> enabled;

  /// Why a parameter is not settable, per parameter, shown on its dial.
  final Map<ExposureParam, String> disabledReason;

  /// How long the strip stays quiet between commands.
  final Duration window;

  /// How tall each dial may be. Three at [kDialHeight] plus the gaps is 187 dp.
  final double dialHeight;

  const ExposureDialStrip({
    super.key,
    required this.values,
    required this.current,
    required this.codes,
    required this.onSet,
    this.enabled = const {},
    this.disabledReason = const {},
    this.window = kDialPacingWindow,
    this.dialHeight = kDialHeight,
  });

  @override
  State<ExposureDialStrip> createState() => _ExposureDialStripState();
}

/// The one pacing queue behind a strip, and the parent of every dial's own.
///
/// Exported because the rule it enforces is the one this whole widget family
/// exists for, and it is worth checking on its own rather than only through a
/// rendered tree.
///
/// ## Where the haptic ticks are, and which count each one is allowed to make
///
/// A dial reports **two** events and they live on two different tiers. Getting either
/// one onto the wrong tier is the mistake this family invites, so both are written down
/// here with the count each one is accountable for:
///
/// ```
///   160 dp drag  ->  6 detents   ->  _step()               -> 6 light ticks  (detentTick)
///                ->  the dial's own coalescer sends ONCE
///                ->  the gate's send runs ONCE  ->  onSet(...)  -> 1 heavier tick (commandSent)
/// ```
///
/// * **`commandSent()` on this gate** — the count is *one per command that leaves the
///   app*, and it is on this tier because the gate is the boundary: it is the last point
///   in the widget family where the value is still ours, and `onSet` is called exactly
///   once per send. Hooking any of the two pacer tiers above it gives a count that no
///   longer means "the camera was told".
/// * **`detentTick()` in `_ExposureDialState._step`** — the count is *one per detent the
///   finger crossed*, and `_step` is the only place that knows. It is deliberately
///   **not** one per command: a control that only confirms a value after the coalescer
///   releases it is silent for the whole drag, because `DialCoalescer` holds everything
///   while the finger is down (the reported defect, `analysis/66`'s counterpart).
///
/// Hooking **one** tier and expecting both counts, or hooking both tiers with the *same*
/// call, is what fails: the send tick on `_step` fires per detent for values the camera
/// never received, and one shared call makes "the control moved" and "the camera was
/// told" the same sensation. `test/haptic_feedback_test.dart` counts them separately and
/// per `HapticFeedbackType`.
class ExposureDialQueue {
  /// The single in-flight gate: one command to the camera at a time.
  final DialCoalescer gate;

  /// One coalescer per dial, so a spam of steps on the ISO dial cannot push the
  /// last shutter value out of the queue.
  ///
  /// Keyed by the dial's `ValueKey` name (`dial-iso`, `dial-mode`, …) rather than by
  /// [ExposureParam], because the dials are no longer all exposure parameters — the
  /// shooting mode is one of them, and it lives in the same column as the ISO dial.
  /// Creating the coalescer on first use is what keeps that open: a queue shared by
  /// two columns of the page cannot know its dials from an enum.
  final Map<String, DialCoalescer> _dials = {};

  /// The window each dial's own coalescer uses.
  final Duration window;

  /// How long the gate closes after a command. See the class comment.
  ///
  /// Short — far shorter than a thumb can travel between two dials — because the
  /// gate is not what paces the camera; the per-dial window is. It exists so that
  /// changes arriving in the *same* frame, from one user action, land as one
  /// command instead of a burst. The first version used `Duration.zero` and four
  /// taps produced four requests: with no barrier at all, `_fire`'s timer runs on
  /// the next microtask and the cooldown never bites.
  static const Duration gateWindow = Duration(milliseconds: 1);

  ExposureDialQueue({
    required void Function(String dial, String value) onSet,
    this.window = kDialPacingWindow,
  }) : gate = DialCoalescer(
          window: gateWindow,
          send: (v) {
            final parts = v.split('\u0000');
            onSet(parts[0], parts[1]);
            // **After** the send, and that order is the only one that is correct: the
            // tick is the phone confirming that the command left, so a value the page or
            // the app refuses must not have ticked first. `onSet` is called once per
            // gate send, so the tick is too — one per command, by construction.
            //
            // This is the **heavier** of the dial's two ticks. The lighter one is the
            // per-detent tick in [_ExposureDialState._step], and the two answer different
            // questions: "the control moved" against "the camera was told". See
            // `ui/haptics.dart` for why both exist rather than one.
            commandSent();
            return null;
          },
        );

  DialCoalescer _dial(String id) => _dials.putIfAbsent(
        id,
        () => DialCoalescer(
          window: window,
          // A dial never writes to the camera directly: it hands its settled value
          // to the gate, which decides when the link is free.
          send: (v) {
            gate.offer('$id\u0000$v');
            return null;
          },
        ),
      );

  /// The function one dial's `onSpin` should call, by its `ValueKey` name.
  void Function(String value) spin(String dial) => _dial(dial).offer;

  /// The `hold`/`release` pair one dial should drive during a drag.
  void hold(String dial) => _dial(dial).hold();
  void release(String dial) => _dial(dial).release();

  /// The link went away: drop everything rather than delivering it later.
  void discardPending() {
    for (final d in _dials.values) {
      d.discardPending();
    }
    gate.discardPending();
  }

  void dispose() {
    for (final d in _dials.values) {
      d.dispose();
    }
    _dials.clear();
    gate.dispose();
  }
}

class _ExposureDialStripState extends State<ExposureDialStrip> {
  late ExposureDialQueue _queue;

  @override
  void initState() {
    super.initState();
    _queue = _newQueue();
  }

  ExposureDialQueue _newQueue() => ExposureDialQueue(
        window: widget.window,
        onSet: (dial, value) {
          // The parameter's own value from the map the caller supplied. The
          // `!` is deliberate: a dial that exists without a command code is a
          // wiring mistake and must fail loudly rather than silently doing
          // nothing when the user turns it.
          widget.onSet(widget.codes[ExposureParam.values.byName(dial)]!, value);
        },
      );

  @override
  void didUpdateWidget(covariant ExposureDialStrip old) {
    super.didUpdateWidget(old);
    if (old.window != widget.window) {
      _queue.dispose();
      _queue = _newQueue();
    }
  }

  @override
  void dispose() {
    _queue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in ExposureParam.values) ...[
            SizedBox(
              height: widget.dialHeight,
              child: ExposureDial(
                param: p,
                values: widget.values[p] ?? const [],
                value: widget.current[p],
                enabled: widget.enabled[p] ?? true,
                disabledReason: widget.disabledReason[p],
                window: widget.window,
                onSpin: _queue.spin(p.name),
              ),
            ),
            if (p != ExposureParam.values.last) const SizedBox(height: 4),
          ],
        ],
      );
}
///
/// Stateless from the caller's point of view: it takes the value list, the
/// current value and a callback, and it reports **settled** values through that
/// callback at most once per [kDialPacingWindow].
class ExposureDial extends StatefulWidget {
  /// Which exposure parameter this is, when it is one of the three.
  ///
  /// Optional: a dial whose ladder is not an exposure parameter — today the shooting
  /// mode — supplies an [identity] instead. One of the two must be given, and the
  /// assertion below is what makes that a compile-time-shaped mistake rather than a
  /// dial that renders an empty label.
  final ExposureParam? param;

  /// What this dial calls itself, for a ladder that is not one of the three exposure
  /// parameters. Null means "use [param]'s own identity".
  final DialIdentity? identity;

  /// Every value the camera will accept, in the camera's own order, **including
  /// its own spellings** (`"1/125s"`, `"1.7"`, `"Auto"`).
  ///
  /// The order is the camera's, not sorted here: the shutter ladder runs slow to
  /// fast and the ISO ladder low to high, and re-sorting them would put `BULB`
  /// and `Auto` in arbitrary places.
  final List<String> values;

  /// The value the camera is currently set to, as a wire string. -1 renders the
  /// dial with no selection rather than guessing one.
  final String? value;

  /// Deliver a settled value. Called at most once per [kDialPacingWindow], and
  /// never while a spin is in progress.
  ///
  /// The parameter type is a plain `void Function(String)`, not a
  /// `Future`-returning one, so that nothing here can accidentally await a
  /// request and so that a caller cannot pass an async function expecting its
  /// intermediate results to matter.
  final void Function(String value) onSpin;

  /// False when the camera owns this parameter in the current exposure mode.
  ///
  /// `AppState.isParamEffective` is the authority. A control that looks live and
  /// changes nothing is worse than a disabled one, so a disabled dial says so on
  /// its face rather than accepting a spin and dropping it — and it says **why**,
  /// through [disabledReason].
  final bool enabled;

  /// Why this dial is disabled, shown in place of its secondary label.
  ///
  /// Every vendor that gates exposure by mode shows the reason (Panasonic prints
  /// *"Camera operation is in progress."* and refuses the phone's controls; Canon
  /// publishes the per-mode table as documentation). A dead control with no
  /// explanation is indistinguishable from a broken one. Pass something like
  /// `'S 模式下相机自己决定光圈'`. When this is null and the dial is disabled it
  /// shows `不可调`.
  final String? disabledReason;

  /// How long the dial stays quiet between commands.
  final Duration window;

  /// The width the content is designed at. [kDialWidth] for the wide dial of the
  /// control column, [kCompactDialWidth] for the narrow one in the readout column.
  final double designWidth;

  /// Whether the two one-step arrow buttons are drawn.
  ///
  /// False for the compact dial, where two 32 dp buttons would leave 6 dp of a 70 dp
  /// design width for the value. The drag and the tap-the-half gestures are the same
  /// in both variants, so only the discoverability differs — and that is recorded as
  /// a cost in `analysis/60` rather than papered over.
  final bool steppers;

  const ExposureDial({
    super.key,
    this.param,
    this.identity,
    required this.values,
    required this.value,
    required this.onSpin,
    this.enabled = true,
    this.disabledReason,
    this.window = kDialPacingWindow,
    this.designWidth = kDialWidth,
    this.steppers = true,
  }) : assert(param != null || identity != null,
            'a dial needs an identity: pass param: or identity:');

  @override
  State<ExposureDial> createState() => _ExposureDialState();
}

class _ExposureDialState extends State<ExposureDial> {
  late DialCoalescer _coalescer;

  /// What this dial is called, from whichever of [ExposureDial.param] /
  /// [ExposureDial.identity] the caller supplied.
  DialIdentity get _id => widget.identity ?? widget.param!.identity;

  /// What the readout shows. Usually [ExposureDial.value], but ahead of it while
  /// a spin is in progress — the dial is optimistic, the camera catches up.
  int _shown = -1;

  /// The last value reported through [ExposureDial.onSpin]. When the parent
  /// echoes it back, it is the optimistic index that is right, not the parent's
  /// stale one.
  String? _reported;

  @override
  void initState() {
    super.initState();
    _coalescer = DialCoalescer(
        send: (v) {
          widget.onSpin(v);
          // `AppState.setParam` resolves when the command is queued, not when the
          // camera answers, so there is no honest future to hand back here. The
          // pacing window is therefore the only bound the widget can enforce on
          // its own — which is the load-bearing one; see `kDialPacingWindow`.
          return null;
        },
        window: widget.window);
    _shown = _indexOf(widget.value);
  }

  @override
  void didUpdateWidget(covariant ExposureDial old) {
    super.didUpdateWidget(old);
    if (old.window != widget.window) {
      _coalescer.dispose();
      _coalescer = DialCoalescer(
          send: (v) {
            widget.onSpin(v);
            return null;
          },
          window: widget.window);
    }
    // The camera is the authority on what it is set to, so a new value from
    // above wins — unless it is simply the echo of what this dial just sent, in
    // which case the index the user spun to is the correct one to keep showing.
    if (widget.value != old.value) {
      if (widget.value != _reported || _indexOf(widget.value) < 0) {
        _reported = null;
        _shown = _indexOf(widget.value);
      }
    }
    // A parameter that stops being settable mid-spin must not deliver the value
    // the user was on when it went read-only.
    if (old.enabled && !widget.enabled) _coalescer.discardPending();
  }

  @override
  void dispose() {
    _coalescer.dispose();
    super.dispose();
  }

  int _indexOf(String? v) =>
      v == null ? -1 : widget.values.indexOf(v);

  /// Vertical travel, in logical pixels, that equals one detent.
  ///
  /// Fixed, and that is a decision: the first version scaled it with the list
  /// length (18 dp for short ladders, 14 dp for long ones), which made the *same
  /// finger movement* mean different things depending on which parameter you were
  /// on. A dial is muscle memory; it should not need re-learning three times.
  ///
  /// 12 dp against a ~48 dp tall readout means a full-height drag crosses four
  /// detents and a short 16 dp flick moves exactly one, which is what makes the
  /// tap-to-step gesture below worth having.
  ///
  /// These are **screen** logical pixels, not the dial's design units — see
  /// [_drag], which converts before dividing.
  static const double stepHeight = 12;

  /// Leftover vertical travel, in logical pixels.
  ///
  /// Drag events arrive in small slices, and rounding each slice on its own
  /// **discards** everything below half a detent. A slow finger produces many
  /// 3 dp slices, each of which rounds to zero — so a slow drag would move the
  /// value not at all and then jump. Carrying the remainder means every pixel of
  /// travel eventually counts, and a slow drag is smooth.
  double _carry = 0;

  bool get _canSpin =>
      widget.enabled && widget.values.length > 1 && _shown >= 0;

  void _step(int delta) {
    if (!_canSpin) return;
    final next = (_shown + delta).clamp(0, widget.values.length - 1);
    if (next == _shown) return;
    // ## The per-detent tick, and why it is here rather than on the send side
    //
    // This is the only place that knows a detent was crossed, and the tick is **one call
    // per detent**, not one per `_step`: a fast flick arrives as a single `_step(4)`, and
    // a dial that ticked once for it would feel like it had three dead positions.
    // Nothing here is debounced, deliberately — a fast drag is a drum roll, and a
    // throttled tick is indistinguishable from a dial that stopped responding.
    //
    // A dial makes **two** ticks and they are not competitors. This one says *the
    // control moved*; `ExposureDialQueue`'s gate ticks `commandSent()` when the value
    // actually leaves for the camera, which is a different statement and a heavier
    // sensation. The first version of this feature had only the second, and because
    // `DialCoalescer` holds every value while the finger is down, a whole drag was
    // silent and clicked once on release — the reported "只有松手才咔". The fix was to
    // add this hook, not to move that one. See `ui/haptics.dart`.
    //
    // It is below the `_canSpin` and `next == _shown` guards on purpose: a disabled dial
    // (`'不可调'`) is not a control and a value already at the end of its ladder did not
    // cross anything, so neither may tick.
    final crossed = (next - _shown).abs();
    setState(() => _shown = next);
    for (var i = 0; i < crossed; i++) {
      detentTick();
    }
    _reported = widget.values[next];
    _coalescer.offer(_reported!);
  }

  /// The scale the dial is **painted** at, read back from the render tree.
  ///
  /// ## Why the `LayoutBuilder` inside the `FittedBox` cannot answer this
  ///
  /// The dial's content is built at its design size and scaled as one piece by a
  /// `FittedBox` ([kDialWidth] x the design box into the cell). A `FittedBox` lays
  /// its child out with **unbounded constraints** — it scales painting and hit
  /// testing, not constraints — so every `LayoutBuilder` inside it sees the *design*
  /// space. The ratio this used to compute,
  /// `box.maxWidth / designWidth`, is therefore a ratio of two design numbers
  /// (`111 / 175` = 0.634 for the wide dial, `70 / 70` = 1.0 for the compact one,
  /// right only by coincidence) and **not** the scale in force. Measured on the
  /// reference body: the wide dial's real scale is **0.803** in a 49 dp cell and
  /// **0.787** in a 48 dp one, so the wide dial cost **15.2 screen dp per detent**
  /// where [stepHeight] says 12, and the EV dial in P/Auto/C — whose cell it fills,
  /// scale 1.0 — cost **18.9**, i.e. 4 dp more than the compact dial beside it in
  /// the same column for the same gesture.
  ///
  /// A gesture's `delta` is the screen delta transformed into the coordinate space
  /// of the render object that receives it (`PointerEvent.localDelta`), which
  /// includes every ancestor scale, so the factor that converts it back to screen
  /// dp is the transform from **here** to the root. That is the same thing
  /// `WidgetTester.getRect` measures, and it is a measurement rather than a second
  /// prediction of what the `FittedBox` will do — the hand-computed scale was tried
  /// (`build`'s comment records the 2 dp overflow) and so was predicting nothing at
  /// all.
  ///
  /// Falls back to 1.0 only for a render object that is not laid out (never attached,
  /// or inside a `FittedBox` with no room, whose transform is zero): a dial like that
  /// cannot be under a finger anyway.
  double _paintedScale(BuildContext surface) {
    final ro = surface.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return 1.0;
    final m = ro.getTransformTo(null);
    // **Not** `Matrix4.getMaxScaleOnAxis`: that takes the largest of the three axis
    // scales and the z axis is identity, so it answers 1.0 for every scale-*down*.
    // (Measured: it reported 1.0 for a dial the same run painted at 0.787.) One local
    // dp in x and in y is mapped to the root instead — exactly what `getRect` does to
    // a rect — and the larger of the two is the factor from local dp to screen dp.
    final origin = MatrixUtils.transformPoint(m, Offset.zero);
    final unitX = MatrixUtils.transformPoint(m, const Offset(1, 0)) - origin;
    final unitY = MatrixUtils.transformPoint(m, const Offset(0, 1)) - origin;
    final s = math.max(unitX.distance, unitY.distance);
    return s.isFinite && s > 0 ? s : 1.0;
  }

  void _drag(DragUpdateDetails d, BuildContext surface) {
    if (!_canSpin) return;
    // ## Two coordinate spaces, and getting them the wrong way round
    //
    // A drag arrives in the dial's **local** space. The dial is designed at
    // [kDialWidth] and is scaled down as a unit when the band is narrower, so a
    // finger that crosses 40 dp of screen crosses `40 / scale` local dp. Detents
    // are a property of the *finger* — "one flick is one stop" has to feel the
    // same whether the band is 183 dp or 200 — so the travel is converted back to
    // screen units before it is divided by [stepHeight].
    //
    // This was wrong twice. First the drag was divided by the design step height
    // with no conversion at all, which made a scaled dial less sensitive than a
    // full-size one. Then the conversion existed but used the **design** ratio above
    // rather than the painted scale, so every wide dial was 1.27x too coarse and the
    // dials disagreed with each other. A third time the fixture agreed with it:
    // `haptic_feedback_test` counts the detents the readout crossed, which is a
    // measured quantity, but the handover's "13 detents in a 160 dp drag" was read
    // off the arithmetic rather than the screen.
    //
    // ## The sign, and the algebra that pins it
    //
    // Positive `dy` is **down**, and this stays `-d.delta.dy`. That looks like the old
    // behaviour and it is — but it is now paired with a **reversed drawn order**
    // ([ladderAbove] draws the larger value *below*), and the pair is what changes the
    // feel. Work it through, because the sign is the trap in this change:
    //
    //     drag UP    dy < 0  ->  carry > 0  ->  index +  ->  readout **rises**
    //                                                       (index + is drawn BELOW, so
    //                                                        it scrolls UP into the readout)
    //     drag DOWN  dy > 0  ->  carry < 0  ->  index -  ->  readout **falls**
    //
    // The value still rises on an upward push — the property the user has confirmed twice
    // — and the marking that was underneath arrives in the readout, i.e. the text travels
    // **with** the finger. Flipping *this* sign as well would send the camera the opposite
    // value, which is the half-fix trap [ladderAbove] warns about; a first attempt at this
    // change did exactly that and `exposure_dial_test.dart` caught it as
    // `Expected: a value greater than <400>  Actual: <200>`.
    //
    // The local-to-screen conversion above is unchanged and still needed: a scaled dial
    // must move one detent per 12 dp of **finger**, not per 12 dp of design. What
    // changed is that the factor is now the **painted** scale rather than a ratio of
    // two design numbers — see [_paintedScale].
    final scale = _paintedScale(surface);
    _carry += -d.delta.dy * scale / stepHeight;
    final steps = _carry.truncate();
    if (steps == 0) return;
    _carry -= steps;
    _step(steps);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      // ## Why the dial is sized from its *height* and not by a `FittedBox`
      //
      // A dial lives in a band whose height the *page* decides, and that height
      // changes with the window: 411 dp in full-screen landscape, 297 dp with the
      // system bars in, and less again once the shutter bar's status line wraps.
      // The first two versions of this widget picked fixed pixel heights and
      // overflowed the column by 9 dp and then 5 dp — a `Column` overflow is an
      // **error** in Flutter, not a cosmetic warning, and both were caught by the
      // test file rather than by eye.
      //
      // The third version wrapped the cell in a `FittedBox`, which removed the
      // overflow but silently broke the *gesture*: a drag arrives in the child's
      // coordinate space, so under a 0.75 scale a 42 dp drag was read as 31.5 dp
      // and produced two steps instead of three.
      //
      // The fourth version computed a scale from the cell's height and applied it
      // by hand — and still overflowed, by 2 dp, because the arithmetic was
      // against *design* line heights rather than against what the text engine
      // actually lays out. Two guesses, two overflows, and neither is visible
      // without running it.
      //
      // So the fit is no longer arithmetic at all. The content is built at its
      // design size and the whole row is scaled as one piece by a `FittedBox`,
      // which is exact because it measures what is really there. The gesture
      // arithmetic then reads the **applied** scale back out of the layout (below)
      // instead of predicting it, so drawing and sensitivity cannot disagree.
      //
      // Text scale is deliberately **not** honoured. Every other control in the
      // app scales with the system font size; this one has a fixed budget of
      // pixels, so a larger system font would be scaled back down here anyway —
      // all honouring it would achieve is making the *other* lines inconsistent
      // with the value they exist to explain. The dial stays proportional and
      // legible instead, which is what `analysis/45` §7 is actually about: a
      // control that is unreadable because it was squeezed is the defect.
      return MediaQuery.withNoTextScaling(
        child: LayoutBuilder(builder: (context, cell) {
          // ## The cell's height, and what the dial does with it
          //
          // Until this round the dial was **designed at [kDialHeight] and never
          // stretched**: a taller cell centred it and left the spare room as black band
          // above and below. That was right while the cell was the page's leftover — a
          // 64 dp cell scaled the row 1.12x off a number the page happened to have, which
          // changed how far a finger had to move per detent, and `_drag`'s comment below
          // records what that cost.
          //
          // The user's third report changes the premise. The dials are no longer sized
          // from the column's leftover: the shutter is **pinned** and the dials above it
          // are given their own slot, whose whole purpose is to be filled — *"the dials
          // above and below and the histogram should scale adaptively to fill the blank
          // space, to make them easier to touch and to use the space."* So a taller cell
          // is now a request, and the dial answers it by growing: the whole 61-unit design
          // is scaled by one factor, so the heading, the three ladder lines and the rail
          // the user has to aim at all grow together.
          //
          // The gesture is unaffected, and that is not luck: `_drag` converts screen
          // travel to detents through the scale it **reads back** from the laid-out tree
          // (below), so a dial drawn 1.6x larger still moves one step per 12 dp of finger.
          final cellHeight =
              cell.maxHeight.isFinite ? cell.maxHeight : kDialHeight;

          // The reader's language, read here rather than passed in: this widget is
          // built from a `LayoutBuilder`, so the `context` in scope already has the
          // `Localizations` above it, and threading an `AppLocalizations` through the
          // dial's two dozen constructor parameters to reach three strings would be a
          // bigger change than the strings are worth.
          final l = l10nOf(context);

          return Container(
            key: ValueKey<String>(_id.keyName),
            width: cell.maxWidth,
            height: cellHeight,
            color: const Color(0xFF101010),
            alignment: Alignment.center,
            child: SizedBox(
              height: cellHeight,
              child: FittedBox(
                // `contain`, not `scaleDown`: a dial given a 97 dp slot draws at 97 dp.
                // `scaleDown` would clamp it back to 61 and leave the slot's remaining
                // third as black band, which is the waste the user is asking to remove.
                // The width still binds — the ladder's `FittedBox` inside scales the
                // text if the row cannot hold it — and the ceiling that keeps a very
                // narrow, very tall column from drawing type wider than its band is
                // [kDialAspectCeiling], applied below.
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: widget.designWidth,
                  child: SizedBox(
                    height: _designBoxHeight(
                      cellHeight,
                      widget.designWidth,
                      kDialHeight,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          // What is left of the design width once the arrow buttons
                          // (if this variant has them) are paid for.
                          width: widget.steppers
                              ? widget.designWidth - 2 * _stepperWidth
                              : widget.designWidth,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // A `Builder` rather than a `LayoutBuilder`: every
                              // constraint readable in here is the *design* space the
                              // `FittedBox` above lays this subtree out in, so there is
                              // nothing to measure from it. What this provides is a
                              // `BuildContext` **inside** the `FittedBox`, which is what
                              // [_paintedScale] needs at gesture time.
                              Builder(builder: (context) {
                                // The drag surface is the full readout cell. The gesture
                                // it carries reads the scale from the render tree at
                                // gesture time ([_paintedScale]) rather than from any
                                // constraint in here: a `FittedBox` lays its child out
                                // with unbounded constraints, so what a `LayoutBuilder`
                                // here would report is the *design* width the `SizedBox`
                                // below states — which is what the old
                                // `box.maxWidth / designWidth` read, and it is not the
                                // scale in force.
                                return SizedBox(
                                  // ## The drag surface is the full readout cell
                                  //
                                  // Measured, and it cost five tests to notice: the ladder
                                  // window is a `Row` with `MainAxisSize.min`, so its width
                                  // is its **content's** — 70.9 dp of a 111 dp cell, with
                                  // the numbers occupying only the right-hand 64.3 of it.
                                  // A drag at the dial's own centre — which is what a thumb
                                  // reaches for, and what `exposure_dial_test.dart` grabs —
                                  // therefore landed on the dial's background instead of on
                                  // the control, and did nothing.
                                  //
                                  // The old shape hid this: the rail was the last row of a
                                  // `Column` inside the `GestureDetector`, so the detector
                                  // was as wide as the cell whether or not anything was
                                  // drawn there. Pinning the width states that property
                                  // instead of inheriting it from the layout, which is what
                                  // makes it survive the next rearrangement.
                                  width: widget.designWidth -
                                      (widget.steppers ? 2 * _stepperWidth : 0),
                                  child: _LadderWindow(
                                    keyName: _id.keyName,
                                    labelOf: _id.labelOf,
                                    values: widget.values,
                                    index: _shown,
                                    enabled: _canSpin,
                                    onHold: _coalescer.hold,
                                    onRelease: _coalescer.release,
                                    onDelta: (d) => _drag(d, context),
                                    onTapStep: _step,
                                    railWidth: kRailWidth,
                                    headingWidth: widget.designWidth -
                                        (widget.steppers
                                            ? 2 * _stepperWidth
                                            : 0) -
                                        kRailWidth * 2.2,
                                    heading: _Heading(
                                      label: dialHeading(l, _id),
                                      caption: _id.caption,
                                      // Only while it is actually dead: a reason shown on
                                      // a live dial is a lie about the camera's state.
                                      disabledReason: _canSpin
                                          ? null
                                          : (widget.disabledReason ??
                                              l.dialDisabledByMode),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                        if (widget.steppers) ...[
                          _StepperButton(
                            keyName: '${_id.keyName}-decrement',
                            icon: Icons.keyboard_arrow_down,
                            tooltip: l.dialDecrease(dialHeading(l, _id)),
                            onPressed:
                                _canSpin && _shown > 0 ? () => _step(-1) : null,
                          ),
                          _StepperButton(
                            keyName: '${_id.keyName}-increment',
                            icon: Icons.keyboard_arrow_up,
                            tooltip: l.dialIncrease(dialHeading(l, _id)),
                            onPressed:
                                _canSpin && _shown < widget.values.length - 1
                                    ? () => _step(1)
                                    : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      );
    });
  }
}

/// The design box a dial's content is laid out in, for a cell of [cellHeight].
///
/// ## The one rule: the content keeps the dial's own aspect ratio, and the cell fills
///
/// A dial's content is a **row** — rail, ladder, and on the wide variant two arrow
/// buttons — so its natural shape is wide and short. A cell can be wide and short (the
/// full-screen stacked dials, 175 x 48), or nearly square (the one-dial modes, where the
/// slot is all the dial region has), or narrow and tall (the compact dials in a 78 dp
/// readout column).
///
/// The content is therefore laid out at `(designWidth, designWidth * kDialAspectCeiling)`
/// — the dial's **own** aspect ratio — and the `FittedBox` above scales that one box into
/// the cell. Two consequences, both deliberate:
///
/// * the whole dial scales by **one factor**, so the heading, the value line and the rail
///   keep their proportions at every size, and `_drag`'s read-back of the applied scale
///   stays the single source of truth for the gesture;
/// * the drawing never exceeds the cell, so a tall narrow column cannot make the type run
///   out of the side of its band. That is what [kDialAspectCeiling] is for, and it is why
///   this is a function rather than `cellHeight` passed straight through.
///
/// A floor of [kDialHeight] keeps a dial handed a very short cell at its design size and
/// lets the `FittedBox` scale it down as one piece, which is the behaviour every
/// overflow guard in this file was written against.
double _designBoxHeight(double cellHeight, double designWidth, double floor) {
  final byAspect = designWidth * kDialAspectCeiling;
  final wanted = cellHeight < byAspect ? cellHeight : byAspect;
  return wanted < floor ? floor : wanted;
}

/// The parameter's name, in the camera world's shorthand and in plain language.
///
/// Both, because "光圈" alone does not say which of the three parameters you are
/// about to change if you have just picked the phone up, and three dials of
/// numbers in a column look alike.
class _Heading extends StatelessWidget {
  final String label;
  final String caption;

  /// Why the dial is dead, when it is. Shown in place of [caption].
  ///
  /// ## Why the reason replaces the caption rather than a whole line being added
  ///
  /// A dead control and a broken control look identical, so the reason has to be
  /// on screen — every vendor that gates exposure by mode says so out loud
  /// (Panasonic prints *"Camera operation is in progress."* and refuses the
  /// phone's controls; Canon publishes the per-mode table as documentation).
  ///
  /// It goes where the English caption was because that is the same footprint: the
  /// dial's height budget is a fixed 411 dp shared with the shutter bar and the
  /// navigation row, and a four-line dial does not fit. The caption is the right
  /// thing to spend, too — a user who cannot change the value does not need its
  /// language lesson.
  final String? disabledReason;

  const _Heading({
    required this.label,
    required this.caption,
    this.disabledReason,
  });

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        // The heading is the one line that can be too wide for its column on a
        // band narrower than the design width — "感光度 ISO" needs 54 dp and a
        // 150 dp band leaves 29. Scaling is right here where truncation would not
        // be: a half-drawn parameter name is worse than a small one.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(label,
                  maxLines: 1,
                  style: TextStyle(
                      color: Colors.white, fontSize: _headingSize, height: 1.0)),
              // The caption is the *other* half of a bilingual heading — 感光度 ISO,
              // 光圈 Aperture — and it exists because the primary label alone does not
              // say which of three parameters you are about to change if you have just
              // picked the phone up. In a language where the label already *is* that
              // word (`Aperture`, `ISO`, `EV`, `Mode`) the caption is the same string,
              // and drawing it twice is not a hint, it is a stutter. So it is dropped
              // when it repeats the label — **but a disabled reason is never dropped**:
              // it is the thing that tells the user why the control is dead, and it
              // borrows the caption's footprint rather than adding a line.
              //
              // The heading is inside a `FittedBox`, so this only ever makes the row
              // narrower — it cannot push the dial's fixed 61 dp height budget.
              if (disabledReason != null || caption != label) ...[
                SizedBox(width: _headingSize * 0.25),
                Text(disabledReason ?? caption,
                    maxLines: 1,
                    style: TextStyle(
                        color: disabledReason == null
                            ? Colors.white54
                            : Colors.orangeAccent,
                        fontSize: _headingSize * 0.66,
                        height: 1.0)),
              ],
            ],
          ),
        ),
      );
}

/// The value a dial draws **above** its readout, or null at the top of the drawn window.
///
/// ## The rotation law: a physical detented dial moves its markings with your thumb
///
/// The user's words, and they settle a question this file had answered wrongly for a
/// round: **"让文字跟着手指走，符合物理带刻度拨盘逻辑"** — *make the text follow the
/// finger; that is what a physical detented dial does.*
///
/// Push the surface of a real marked dial upward and:
///
/// * the surface **and its markings** move up;
/// * the marking that was **below** the index line arrives **in** the index line;
/// * so the readout shows what used to be underneath it.
///
/// Three facts, and together they fix both the drawing **and** the value: with the
/// markings ordered **larger below**, pushing up brings a **larger** marking into the
/// readout, and the surface has travelled **with** the finger. That is this function —
/// larger below — and `_drag`'s index direction, which stays `-d.delta.dy` (see the
/// algebra there). It is **one** change to the drawing order, not two to the mapping:
/// a first attempt also flipped the drag sign and sent the camera the opposite value.
///
/// ## What the value mapping is, and is not
///
/// `values` is untouched. It stays the camera's own order, ascending in the number
/// ([ExposureDial.values]), and `index` still indexes it: **index + 1 is still a larger
/// number on every pool.** What changed is only *where on the screen* a given index is
/// drawn. Dragging up still increases the value — the property the user has confirmed
/// twice — and that is asserted as `RCISOSet=800` for an upward drag from 400, in the
/// same check as the drawing.
///
/// (The previous revision drew `index + 1` *above*, which put the larger value on top and
/// made the text scroll **down** under an upward finger. Measured then: value 400 -> 800
/// while `400` moved y 284.0 -> 301.5 — the content travelled opposite the finger, which
/// is the defect the user had been describing in the only words they had for it.)
String? ladderAbove(List<String> values, int index) =>
    index > 0 && index < values.length ? values[index - 1] : null;

/// The value a dial draws **below** its readout, or null at the bottom of the drawn window.
///
/// The other half of the law in [ladderAbove]: **the larger value is drawn below**, which
/// is what lets an upward push raise the readout while the markings travel upward with it.
String? ladderBelow(List<String> values, int index) =>
    index >= 0 && index + 1 < values.length ? values[index + 1] : null;

/// The readout, the steps either side of it, and the drag surface.
class _LadderWindow extends StatelessWidget {
  /// The dial's `ValueKey` name, so the degenerate-ladder marker can be keyed to the
  /// dial it belongs to (`dial-iso-empty`).
  final String keyName;

  /// How one of this ladder's wire values reads, from the dial's [DialIdentity].
  final String Function(String wire) labelOf;

  final List<String> values;
  final int index;
  final bool enabled;
  final VoidCallback onHold;
  final VoidCallback onRelease;
  final void Function(DragUpdateDetails) onDelta;
  final void Function(int) onTapStep;

  /// How wide the vertical position rail beside the readout is.
  ///
  /// Fixed in the dial's **own design units**, so the whole dial scales as one piece:
  /// the rail is 3 of the design's 61 dp of height, and a dial drawn 1.6x larger draws a
  /// 4.8 dp rail. That is the point of the rail existing at all — the design cell's 3 dp
  /// is thinner than a thumb, and growing with the cell is what makes the position
  /// readable on the dials the full-screen layout actually seats.
  final double railWidth;

  /// The dial's name, drawn above the readout — **inside** the drag surface.
  ///
  /// It is built by the dial and passed in rather than placed by the dial around this
  /// widget, because the gesture surface has to include it: see the comment in `build`.
  final Widget heading;

  /// The width the heading is given.
  ///
  /// The cell's width less the rail and the gap beside it. Explicit because `_Heading`
  /// ends in an `Align`, which takes its child's width rather than the available one, and
  /// an unbounded child in a `MainAxisSize.min` row is an overflow — measured at 29 px on
  /// a disabled dial, whose caption is the longest string this widget draws.
  final double headingWidth;

  const _LadderWindow({
    required this.keyName,
    required this.labelOf,
    required this.values,
    required this.index,
    required this.enabled,
    required this.onHold,
    required this.onRelease,
    required this.onDelta,
    required this.onTapStep,
    required this.railWidth,
    required this.heading,
    required this.headingWidth,
  });

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty || index < 0) {
      // Degenerate, and it must look deliberate rather than broken: this is what
      // a parameter the camera reports no range for looks like.
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '—',
          key: ValueKey<String>('$keyName-empty'),
          style: const TextStyle(
              color: Colors.white38, fontSize: 15, height: 1.0),
        ),
      );
    }

    final above = ladderAbove(values, index);
    final below = ladderBelow(values, index);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: enabled ? (_) => onHold() : null,
      onVerticalDragUpdate: enabled ? onDelta : null,
      onVerticalDragEnd: enabled ? (_) => onRelease() : null,
      onVerticalDragCancel: enabled ? onRelease : null,
      // A tap on the upper/lower half is the same one-step move the arrow buttons
      // make. It is what makes the control work before the user has discovered
      // that it also drags — and on the compact variant, where there are no arrow
      // buttons at all, it is the only one-step gesture there is.
      //
      // ## Why the upper half is `-1`, and why that is the **new** way round
      //
      // The promise a tap makes is: **tapping the marking you can see selects it.** The
      // upper half of this box is where [ladderAbove] draws `values[index - 1]`, so the
      // upper half must step the index **down** by one — hence `? -1 : 1`.
      //
      // It was `? 1 : -1` until the drawn order was reversed, and it was then the one input
      // path that had *not* followed the reversal: tapping the upper half moved the index
      // up, i.e. selected the marking drawn **underneath** it. Measured before the fix,
      // ISO 400: tapping the upper half took the readout to **800** (the value drawn
      // *below*) and tapping the lower half took it to **200** (the value drawn *above*) —
      // the exact opposite of the promise. After: upper -> 200, lower -> 800.
      //
      // `exposure_dial_test.dart`'s tap check stayed **green** throughout, which is the
      // lesson worth keeping: it asserted the *value direction* (`v003` for the upper
      // half), which the reversal did not change, so it could not see that the zone had
      // been left behind. It now asserts the zone against the drawn order.
      onTapUp: enabled
          ? (d) {
              final box = context.findRenderObject();
              if (box is! RenderBox || !box.hasSize || box.size.height <= 0) {
                return;
              }
              onTapStep(d.localPosition.dy < box.size.height / 2 ? -1 : 1);
            }
          : null,
      // ## What is inside the surface, and why it is everything here
      //
      // The rail is a **sibling** of the readout, not a gap in it: putting it outside this
      // detector split the surface in two, and the dial's own centre — which is what a
      // thumb reaches for and what `exposure_dial_test.dart` drags — landed on the 3.6 dp
      // of daylight between the rail and the numbers. Measured: five drag tests stopped
      // being delivered, all of them at the centre.
      //
      // The arrow buttons stay outside, and they are the only thing that does: a tap on an
      // arrow must be a step of exactly one, not a spin.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ## The indicator is **vertical**, and it is beside the ladder
          //
          // It used to be a horizontal 3 dp strip under the readout, reporting the right
          // fact — where in the ladder you are — on the **wrong axis**: the control is
          // operated by dragging up and down, and the thing that says "you are here" was
          // drawn left to right. That is the user's first report (*"the dial is dragged up
          // and down, but the progress bar is a horizontal strip?"*), and the disagreement
          // is real rather than cosmetic: a horizontal rail also reads as a *level*, so its
          // left end looked like "less" while the ladder beside it puts less at the
          // **bottom**.
          //
          // Its height is the ladder's own three lines and nothing else, so the marker at
          // the top of the rail is level with the top line of the readout window and the
          // marker at the bottom is level with the bottom one. That is what makes the rail
          // an indicator of *this* ladder rather than a decorative progress bar.
          SizedBox(
            height: _lineSmall * 2 + _lineValue,
            child: _LadderRail(
              count: values.length,
              index: index,
              enabled: enabled,
              width: railWidth,
            ),
          ),
          SizedBox(width: railWidth * 1.2),
          SizedBox(
            width: headingWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The heading is given the cell's **remaining** width explicitly. It ends
                // in an `Align`, which does not claim width on its own, and inside a
                // `MainAxisSize.min` row that is what an unbounded child overflows:
                // measured, a disabled dial — whose caption is the long
                // `S 模式下相机自己决定光圈` — threw
                // `A RenderFlex overflowed by 29 pixels on the right` from this very row.
                // The `FittedBox` inside `_Heading` scales the line down, and this is what
                // gives it a bound to scale *against*.
                heading,
                const SizedBox(height: 2),
                _ValueLine(
                  text: above == null ? '' : labelOf(above),
                  colour: Colors.white24,
                  size: 10,
                  lineHeight: _lineSmall,
                ),
                _ValueLine(
                  text: labelOf(values[index]),
                  colour: enabled ? Colors.white : Colors.white38,
                  size: 15,
                  lineHeight: _lineValue,
                  weight: FontWeight.w600,
                ),
                _ValueLine(
                  text: below == null ? '' : labelOf(below),
                  colour: Colors.white24,
                  size: 10,
                  lineHeight: _lineSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of the ladder, shrunk rather than clipped when it is too wide.
///
/// `FittedBox(scaleDown)` and not a smaller font, for two reasons. The longest
/// string in the shutter pool is `1/4000` at 103 dp and the readout column is
/// 111 dp, so it fits — but only just, and the *same* line has to hold `ISO 12800`
/// and `f/1.7`. Scaling the drawn text means any pool can be dropped in without
/// re-measuring the layout. And it keeps the text **inside the box** at every
/// system font size, because a `RenderFlex` overflow is an error in Flutter, not a
/// cosmetic warning (that is how the two overflows this widget had were found).
///
/// The line height is fixed rather than derived from font metrics: the cell's
/// height is a budget, and a text engine free to add its own leading is what made
/// the cell 2 dp taller than the sum of its parts.
class _ValueLine extends StatelessWidget {
  final String text;
  final Color colour;
  final double size;
  final double lineHeight;
  final FontWeight weight;

  const _ValueLine({
    required this.text,
    required this.colour,
    required this.size,
    required this.lineHeight,
    this.weight = FontWeight.w400,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return SizedBox(height: lineHeight);
    }
    return SizedBox(
      height: lineHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            maxLines: 1,
            // Tabular figures: without them the readout's width changes as the
            // value scrolls and the whole column jitters under the thumb.
            style: TextStyle(
              color: colour,
              fontSize: size,
              fontWeight: weight,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// The position-in-the-ladder strip **beside** the readout.
///
/// One tick per value, with the current one marked. It answers "how much room is
/// left above me" without a number, which is the question a dial with 57 detents
/// raises and a bare readout cannot answer. The ticks are drawn small on purpose:
/// they are information, not a target.
///
/// ## Why it is vertical, and why it is on the left
///
/// It used to be a horizontal 3 dp strip **under** the readout, and the user's first
/// report is exactly that: *"the dial is dragged up and down, but the progress bar is a
/// horizontal strip?"* A control operated by a vertical drag has to report its position
/// on the vertical axis — otherwise the indicator says "you are 40% along" in a
/// direction the hand never moves in, and a horizontal rail in particular reads as a
/// **level**: its left end looks like "less" while the ladder above it puts less at the
/// **bottom**.
///
/// It sits on the **left** because the ladder's own numbers start there: the readout
/// column is flush left, so a rail on that edge lines up with the digits the eye is
/// already following.
///
/// ## The direction is the whole point
///
/// Tick `i` is placed so that a **higher index is higher on the screen** — the same
/// order [ladderAbove] gives the text lines. An "empty" tick (above the current value)
/// is dimmer than a passed one (below it), which is what makes the thumb's travel
/// readable at a glance rather than merely indicated.
class _LadderRail extends StatelessWidget {
  final int count;
  final int index;
  final bool enabled;

  /// How wide the rail is. See [_LadderWindow.railWidth].
  final double width;

  const _LadderRail({
    required this.count,
    required this.index,
    required this.enabled,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    // One tick is not a position, and a rail for a one-entry ladder would claim there
    // is somewhere to go. The dial draws nothing there instead. `2` rather than `< 2`
    // on `count` because a `Column` of one `Expanded` is a full-height bar, which
    // reads as "you are here and there is nothing else" — true, but it is a control
    // that cannot move and the readout already says so.
    if (count < 2) return SizedBox(width: width);

    return Padding(
      key: const ValueKey<String>('dial-rail'),
      // The rail is inset from the readout by 1 dp of its own width at each end, so
      // the first and last ticks are not flush against the value lines beside them.
      padding: EdgeInsets.symmetric(vertical: width * 0.25),
      child: SizedBox(
        width: width,
        // ## Why the gap is measured rather than fixed
        //
        // The ticks are one `Expanded` per ladder entry, and each used to carry a fixed
        // `margin` of `width * 0.25` top and bottom — 1.5 dp of the ~35 dp the rail has
        // in total. **That is fine until the ladder is long.** Past roughly 23 entries a
        // tick's own share is shorter than the margin it is asked to carry, so every tick
        // is drawn at zero height and **the whole rail disappears**.
        //
        // Measured on the maintainer's phone, and it is exactly what they saw: in M the
        // aperture ladder is 14 entries and its rail was there, while shutter (57) and ISO
        // (~30) had none — so the one dial that still showed a rail was the one that
        // happened to be short enough. They asked why only the aperture had one, and
        // whether "remaining room" even means anything for aperture: it does not, and that
        // was the clue — a coincidence was being read as a design.
        //
        // A `LayoutBuilder` because the rail is the only thing that knows how much height
        // it was actually given, and the gap has to be a fraction of a tick's share of it.
        // The cap keeps the original look on short ladders, where there is room to spare.
        child: LayoutBuilder(
          builder: (context, rail) {
            final share =
                rail.maxHeight.isFinite && count > 0 ? rail.maxHeight / count : 0.0;
            final gap = math.min(width * 0.25, share * 0.35);
            return Column(
              children: [
                // ## The rail is the ladder, drawn the same way round as the ladder
                //
                // The ticks are built in **drawn order, bottom-up**: the last child of this
                // `Column` is at the bottom of the screen and carries **index 0**. That is
                // the same arrangement [ladderAbove]/[ladderBelow] gives the text — larger
                // value *below* — so the rail and the numbers beside it agree, and pushing
                // the markings up past the marker walks the marker **up** the rail with
                // them.
                //
                // (It was top-down when the text was larger-above. The pair had to move
                // together; a rail that kept the old direction would have been a second,
                // quieter inversion — which is exactly the shape of the bug this round
                // fixes.)
                for (var i = count - 1; i >= 0; i--)
                  Expanded(
                    child: Container(
                      margin: EdgeInsets.symmetric(vertical: gap),
                      decoration: BoxDecoration(
                        color: !enabled
                            ? Colors.white10
                            // Above the marker is a **lower** index now, so `i < index` is
                            // the part of the ladder the user has already passed through on
                            // the way up, and `i > index` is what is still below the thumb.
                            // The marker is the value in the readout either way.
                            : i == index
                                ? Colors.white
                                : i > index
                                    ? Colors.white12
                                    : Colors.white38,
                        borderRadius: BorderRadius.circular(width * 0.3),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A one-step arrow button with a stable key.
class _StepperButton extends StatelessWidget {
  final String keyName;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _StepperButton({
    required this.keyName,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        // Explicit size rather than `IconButton`'s own `constraints:` — see
        // [_stepperWidth]. This box is what the layout budgets for, so it is the
        // box the button is measured in.
        width: _stepperWidth,
        height: _stepperWidth,
        child: IconButton(
          key: ValueKey<String>(keyName),
          tooltip: tooltip,
          icon: Icon(icon),
          iconSize: 20,
          padding: EdgeInsets.zero,
          color: Colors.white,
          disabledColor: Colors.white24,
          onPressed: onPressed,
        ),
      );
}
