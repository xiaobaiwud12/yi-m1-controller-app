import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;

import '../../l10n/l10n.dart';
import '../../l10n/message_text.dart';
import '../../l10n/param_labels.dart';
import '../../l10n/settings_menu_l10n.dart';
import '../../protocol/camera_state.dart';
import '../../protocol/focus_mapper.dart';
import '../../protocol/histogram.dart';
import '../../protocol/http_params.dart';
import '../../protocol/settings_menu.dart';
import '../../protocol/viewfinder_layout.dart';
import '../../state/app_state.dart';
import '../../transport/camera_connection.dart';
import '../../transport/screen_control.dart';
import '../haptics.dart';
import '../histogram_sampler.dart';
import '../widgets/exposure_dial.dart';
import '../widgets/histogram_view.dart';
import '../widgets/locale_picker.dart';
import '../../transport/wifi_join_contract.dart';
import 'album_page.dart';
import 'video_page.dart';

/// The live-view screen: preview, live camera state, and the controls the
/// official app never had.
///
/// Design notes that come from the hardware rather than from taste:
///
/// * The stream is **800x600**, so the preview is letterboxed rather than
///   cropped. Pretending otherwise would misrepresent framing.
/// * Camera state is read from the **frames themselves**, not polled, so the
///   overlay is live at ~30 Hz for free.
/// * Tap-to-focus maps to the camera's own 800x600 coordinate space, and is
///   **debounced** — hammering focus is the same request pattern that strands the
///   capture state machine.
/// * The shutter is routed through the interlock, so a refused capture cannot
///   lead straight into another one.
class LiveViewPage extends StatefulWidget {
  final AppState app;
  const LiveViewPage({super.key, required this.app});

  @override
  State<LiveViewPage> createState() => _LiveViewPageState();
}

class _LiveViewPageState extends State<LiveViewPage> {
  /// Display aspect for the preview box, derived from the camera's own
  /// `ImageAspect`.
  ///
  /// This is **not** cosmetic. The focus mapping is correct only when the box's
  /// aspect matches what the camera is actually framing: the 4:3 plane scales x
  /// by the view width and y by the view *height*, so a box with the wrong aspect
  /// puts the frame's content somewhere other than where the box says it is, and
  /// every tap lands off target. It is also simply more honest — showing a 16:9
  /// frame inside a 4:3 letterbox wastes screen and misrepresents the framing.
  double get _aspect {
    switch (widget.app.cameraState?.imageAspect) {
      case '16:9':
        return 16 / 9;
      case '3:2':
        return 3 / 2;
      case '1:1':
        return 1.0;
      default:
        return 4 / 3;
    }
  }

  bool _showGrid = false;
  bool _showSettings = false;

  /// Every exposure dial in **both** columns of the full-screen layout.
  ///
  /// ## Why the page owns one queue and the widgets own none
  ///
  /// The camera is a single-threaded HTTP server with no watchdog
  /// (`AGENTS.md` §4.6), so the thing that has to be bounded is the **link**, not a
  /// control: three dials each promising to be quiet are still three streams of
  /// requests from one radio. The full-screen layout puts two dials in the control
  /// column and two more in the readout column, so a per-widget queue would be four
  /// promises and no bound at all. `ExposureDialQueue` is therefore created here, at
  /// the one place that can see every dial, and each dial is handed
  /// `_dials.spin(<its own ValueKey name>)`.
  ///
  /// The pacing contract itself is unchanged and is the one `analysis/51` measured:
  /// nothing while a finger is down, at most one command per parameter per 350 ms with
  /// the **last** value winning, and one command in flight across the link. The dials
  /// still never write to the camera directly.
  late final ExposureDialQueue _dials = ExposureDialQueue(onSet: _sendDial);

  /// Which `RC…` command each dial's `ValueKey` name drives.
  ///
  /// Keyed by the same string the dial answers to (`dial-iso`), so the key a
  /// Marionette script clicks and the command it provokes cannot drift apart, and the
  /// `!` in [_sendDial] makes an unregistered dial a loud wiring mistake rather than a
  /// control that turns and does nothing.
  static const Map<String, String> _dialCommand = {
    'dial-aperture': kCmdAperture,
    'dial-shutter': kCmdShutter,
    'dial-iso': kCmdIso,
    'dial-ev': kCmdEv,
    'dial-mode': kCmdMode,
  };

  /// Deliver one settled dial value to the camera.
  ///
  /// Not awaited: the dial's own pacing window is what keeps the camera alive, and the
  /// failure path is `AppState.setParam`'s — which refuses the command and records the
  /// reason in `lastNotice`, where the rest of the app reads it.
  void _sendDial(String dial, String value) {
    unawaited(app.setParam(_dialCommand[dial]!, value));
  }

  /// The width the control column needs, in logical pixels.
  ///
  /// ## What sets it
  ///
  /// The **navigation row** is the widest thing in the column. Measured on the
  /// connected-camera fixture it lays out at **385.8 dp** — three labelled
  /// `TextButton.icon`s, and the labels are the ones this app uses. The shutter bar
  /// is designed at `_ShutterBar._shutterRowWidth` = 320 dp and is the narrower of
  /// the two.
  ///
  /// ## Why the number is what it is, and why it is not simply the row width
  ///
  /// This is the band that the shutter bar is measured inside, and `_BandFitted`
  /// subtracts 4 dp of padding a side before its `FittedBox` sees the bar. So the
  /// bar renders at its design width — and the 68 dp shutter is **painted at
  /// 68 dp** rather than scaled — exactly when the band is
  /// `_ShutterBar._shutterRowWidth + 8`. Both are written out here rather than one
  /// being derived from the other, because they are edited in different files of
  /// this one library and the relationship is what matters:
  /// `fullscreen_controls_size_test.dart` fails if this band drops back below the
  /// row's design width, which is the shape the defect took.
  ///
  /// ## The trade this number is on the winning side of
  ///
  /// On a 914x411 dp full-screen body a 4:3 frame wants 548 of the 914 dp width,
  /// leaving 366 dp for **both** side columns, while the two asks here sum to
  /// 395 dp. Until this round `ViewfinderLayout` split the shortfall evenly at 183
  /// each: the shutter row was scaled to 0.547 and a 68 dp shutter was **painted at
  /// 34.4 dp**, below Material's 48 dp floor, in the mode that exists to make
  /// shooting easier. The layout now scales the two wants back **in proportion**
  /// (see its `sideBands`), which lands the control column at **267 dp of the 366**
  /// and makes every rendered control the same size in both layouts:
  ///
  ///     control              normal   full screen   (before this round)
  ///     btn-shutter           55.04       55.04        55.0 -> 34.4
  ///     btn-focus-centre      45.33       45.33        45.3 -> 28.3
  ///     btn-preview-toggle    45.33       45.33        45.3 -> 28.3
  ///     btn-fullscreen        45.33       45.33        45.3 -> 28.3
  ///     btn-settings-toggle   34.84       34.84        34.8 -> 21.8
  ///
  /// A constant rather than a measurement because these are fixed-width widgets by
  /// construction; if one of them stops being fixed, this must follow it.
  ///
  /// ## The measurements behind the table, with the row at its final width
  ///
  /// The row width matters as much as the band (see `_ShutterRowWidth`), so both
  /// numbers were settled together. Final, on 914x297 normal and 914x411 full screen:
  /// the **control** band is 288 in both, and the readout band is the only thing the
  /// two layouts disagree about — 156 normally (the camera's own words, `Incandescent`
  /// at 144.0 dp plus padding) against 78 in full screen (its short forms), because
  /// `ViewfinderLayout` holds the readout at [`kMinReadoutBand`] and hands the rest to
  /// the controls. The picture area is 470 x 297 normally and 548 x 411 in full screen;
  /// the 4:3 frame *inside* it is 396 x 297 in both, because a frame on a 297 dp body
  /// is height-limited — which is why the readout's 78 extra dp come out of black
  /// margin rather than out of the picture.
  static const double _controlBandWidth = 288;

  /// The width the camera-readout column asks for when the camera's own words fit.
  ///
  /// ## Measured from the strings the UI actually draws
  ///
  /// The widest string that reaches this column is `Incandescent`, the white-balance
  /// value: 12 characters at 12 sp, **144.0 dp** against this app's font metrics, plus
  /// the 2+2 dp row padding and `_BandFitted`'s 4+4 = **156 dp**. The next widest are
  /// `HContrastBW` (11 characters, 132.0) and `1/4000s` (7, 84.0); the labels top out
  /// at `Aperture` and `ISO auto`, 8 characters at 9 sp = 72.0.
  ///
  /// **A previous revision recorded 148 dp from `AperturePriority`.** That is an enum
  /// *constant name*, not a string this page can render: `rcExposureMode`'s
  /// `AperturePriority` carries `'A'`. `app/tools/measure_readout_strings.py`
  /// enumerates the camera's vocabulary — 232 constants, 219 display values — and the
  /// longest display value of all is `CenterWeighted`, the **metering mode**, which is
  /// not a row here.
  ///
  /// ## Why this is a want and not the number that gets used
  ///
  /// The band is granted only when the controls are already served:
  /// `ViewfinderLayout.readoutRoom` is the slack the frame leaves, less the 288 dp the
  /// control column asks for. On a 914x297 dp normal-landscape body that slack is
  /// **518** and the room is **230**, so 156 is affordable and the readout is drawn at
  /// full size. On the 914x411 dp full-screen body the slack is 366 and the room is
  /// **78**, so it is not — and asking for it anyway is what would re-open
  /// `analysis/54`'s defect, in proportion rather than in full: 366 × 288/(288+156)
  /// hands the controls 242 dp and paints the shutter at 45.9 dp against 55.0 normally.
  ///
  /// The room is real space that nothing else wants: a 4:3 frame on a 914x297 dp body
  /// is **height**-limited at 396×297, so the readout's 78 dp comes out of black
  /// margin beside the picture, not out of the picture — `readout_legibility_test.dart`
  /// measures the frame box in both layouts and fails if it stops filling the height.
  static const double _readoutFullWidth = 156;

  /// The width the readout column falls back to when the controls need the rest.
  ///
  /// It is [`kMinReadoutBand`] = 78, the width full screen leaves it, and it is a
  /// *content* width as well as a floor: at 78 the band leaves a value 66 dp, and the
  /// short forms this page draws there are at most 7 characters — 84.0 dp — so the
  /// longest row lands at **0.79** of its size (9.4 dp of type), the shutter row at
  /// 0.92 and the rest at 1.0.
  /// See [compactReadoutValue] and [_SideState].
  ///
  /// ## The alternatives, each built and measured
  ///
  ///     readout share   controls get   measured result                       (analysis/54)
  ///      78 dp            288 dp       all controls equal in both layouts    <- chosen
  ///      99 dp            267 dp       shutter 61.4 both, but the settings
  ///                                    toggle 32.2 full screen vs 34.8 normal
  ///     107 dp            259 dp       shutter 59.1 normal vs 54.6 full screen
  ///     148 dp            242 dp       shutter 55.0 normal vs 45.9 full screen
  ///
  /// Every one of those is the reported defect at decreasing sizes: a control that gets
  /// smaller when the user enters the mode that is supposed to make shooting easier.
  /// The settings toggle is the one that refuses to be fixed any other way — it lives
  /// in the navigation row, which is 385.8 dp wide against a 288 dp band, so it is
  /// scaled by the band and shrinks by exactly as much as the band does.
  static const double _readoutCompactWidth = kMinReadoutBand;

  /// Heights of the portrait end rows, measured from what they hold.
  ///
  /// The top row is the icon row plus the one-line state strip; **72** is what that
  /// measures — 48 was the first guess and it overflowed by exactly 20 pixels, caught
  /// by `focus_shutter_ui_test`. The bottom row is the shutter bar plus the navigation
  /// row.
  ///
  /// Both used to be given half the slack around the frame, which on a 411x727 body
  /// meant 209.5dp each: a great deal of empty space above a line of text, and the
  /// reason the settings panel was starved.
  ///
  /// ## What the 72 assumes, and which half of it was not true
  ///
  /// It is a measurement **at the default text scale**, and it means "the icon row plus
  /// **one line**". Both halves of that are now enforced rather than assumed: the strip
  /// cannot wrap (`_StateStrip`), and the page gives the band this number as a
  /// **minimum** rather than a fixed height, so a larger system font makes the band a
  /// few dp taller instead of making the `Column` inside paint outside its box.
  ///
  /// Measured with a worst-case camera state injected, portrait 411x727. Two fonts,
  /// because they differ by ~2x and only one of them is what a phone draws — see
  /// `_StateStrip`:
  ///
  ///     text scale      1.0     1.3     1.5     2.0
  ///     Roboto          72.0    75.0    79.0    88.0     <- the device's font
  ///     flutter_test    72.0    73.0    76.0    82.5     <- what the tests lay out in
  ///
  /// (**129** with the histogram on at 1.0, i.e. this constant plus
  /// `_histogramPanelHeight`.) The growth is the strip's own line — the reader's type
  /// size — plus the icon row above it. Roboto is the column a phone sees, and it needs
  /// 75 rather than 72 once the font is at 1.3, so the fixed 72 was a few dp short at the
  /// common accessibility settings even before wrapping is considered; at the largest
  /// setting the picture gives up 16 dp. The test-font column is lower only because that
  /// font's own line height is smaller — the battery value's line box measures 13 dp at
  /// 1.0 against Roboto's 18 — not because the band behaves differently there.
  static const double _topBandHeight = 72;

  /// What the histogram panel adds to the top band when it is showing.
  ///
  /// ## Why the band height has to know about this
  ///
  /// `_BandFitted` fixes **horizontal** overflow and cannot fix vertical: a `FittedBox`
  /// inside a `Column` is laid out with an unbounded main axis, so it never scales down
  /// along it. Every band child is wrapped in one — and the band still overflowed on
  /// hardware and in the test fixture the moment the histogram was turned on, drawn as
  /// the yellow-and-black stripe.
  ///
  /// So the height is content-derived rather than a constant measured once: `_topBandHeight`
  /// covers the toggle row and the state strip, and this covers the panel.
  ///
  /// ## 57, and it is measured in both of the panel's own states
  ///
  /// The panel is **not one height**, which is what made the first two numbers here
  /// wrong — 46 was estimated from `HistogramView(height: 38)` plus padding, and 55 was
  /// inferred from a device overflow of 9 px. Measured on the laid-out tree (probe over
  /// `test/tmp_probe2_test.dart`, portrait 411x727, `connectedTestAppState`), the panel
  /// reports:
  ///
  ///     state                        panel (getSize)   panel's own Column
  ///     no frame sampled yet              43.0          38 + 1 + 0        (39)
  ///     first frame sampled               57.0          38 + 1 + 14       (53)
  ///
  /// — i.e. `HistogramView` 38, a 1 dp gap, `HistogramReadout`, and 2 dp of padding top
  /// and bottom. `HistogramReadout` returns `SizedBox.shrink()` while
  /// `histogram.samples == 0`, so the panel **grows by 14 dp** the moment the camera's
  /// first frame is sampled; the readout's own line measures 14.0 dp (`10.5 sp` at
  /// `height: 1.3`). This constant has to cover the **taller** state: a band sized for
  /// the pre-frame one overflows a second after the preview starts, which is the same
  /// class of error as measuring a band without its histogram in it at all.
  ///
  /// (The device's 9 px overflow is consistent with the taller state: `72 + 55 = 127`
  /// in a 118 dp band is 9. The 55 there is the panel with a readout at the device's own
  /// font metrics; the test font measures the same line at 14.0.)
  static const double _histogramPanelHeight = 57;

  /// The top band's request, which grows when the band has one more child.
  ///
  /// **Minimum**, not `max`: the band must be exactly this, and a clamp is how a
  /// request gets silently rounded back down. `72 + 57 = 129` is the portrait body's
  /// worst case and it fits inside the 419 dp of vertical band a 411x727 screen leaves
  /// around a 4:3 frame, so nothing is competing for the slack.
  double get _topBandWant =>
      _topBandHeight + (_showHistogram ? _histogramPanelHeight : 0);
  static const double _bottomBandHeight = 172;

  /// The preview area is never squeezed below this, however far the panel is dragged.
  ///
  /// Below roughly this the picture stops being something you can frame with. It is
  /// deliberately less than the frame's natural 4:3 height so that opening the panel
  /// *does* shrink the picture — the picture is already full-width, and a shorter
  /// preview area letterboxes rather than crops, so trading height for settings rows
  /// costs nothing that matters.
  static const double _minPreviewHeight = 200;

  /// The settings panel's height, adjustable by dragging its header.
  ///
  /// Starts at [_minPanelHeight] and grows into the space the end rows do not use.
  /// Before this the panel was a `Flexible` sibling of an `Expanded` preview, so the
  /// two split the free space evenly and the panel got 154dp — about two settings
  /// rows once the header and tab strip took their 78. Reported as "opening Settings
  /// shows only two lines".
  /// The panel height the *user* has asked for.
  ///
  /// Starts as "as much as fits", so opening Settings uses the free space rather than
  /// a guessed constant — which is what was asked for. Once the header is dragged it
  /// holds a real number. [_resolvedPanelHeight] is what that worked out to on the
  /// last build, and is what a drag starts from.
  double _panelHeight = double.infinity;
  double _resolvedPanelHeight = _minPanelHeight;
  static const double _minPanelHeight = 240;

  /// The most the panel may take.
  ///
  /// Bounded so a drag can never squeeze the picture out of existence: 420dp is
  /// roughly eight settings rows, and the preview keeps the rest.
  static const double _maxPanelHeight = 420;

  /// The panel height when the current drag gesture began, so the drag is measured
  /// from a fixed origin instead of accumulating rounding as frames arrive.
  double _panelHeightStart = 0;

  /// Record which settings tab the user is on.
  ///
  /// Read straight from `AppState` on every build rather than cached in a field
  /// here: `AppState` loads its preferences asynchronously, so a field seeded in
  /// `initState` would capture the default before the saved tab had been read
  /// and quietly discard the user's choice for the whole session.
  void _selectSettingsTab(String tab) => widget.app.settingsTab = tab;

  void _toggleSettingsGroup(String groupId) =>
      widget.app.toggleSettingsGroup(groupId);

  /// The histogram costs an extra full decode plus a GPU read-back per sample,
  /// so it is **off by default**: a user who did not ask for it should not pay
  /// for it, and the preview is the thing being looked at.
  bool _showHistogram = false;
  late final HistogramSampler _histogram = HistogramSampler();

  Offset? _focusPoint;
  Timer? _focusDebounce;
  Timer? _focusMarkerTimer;

  /// Whether this page is the one being looked at.
  ///
  /// ## Why the page has to say so at all
  ///
  /// `HomeShell` puts the live view and the album in an `IndexedStack`, which
  /// keeps both alive: the page stays mounted, its state survives, and — before
  /// this — its frame subscription kept running.  Frames nobody could see were
  /// still pulled off the socket and decoded, thirty 800x600 JPEGs a second.
  ///
  /// Measured with the album tab displayed: 46 906 datagrams / 2.47 GB across the
  /// bridge.  (An earlier note here also quoted the app's CPU; that number came
  /// from an emulator with no GPU and a debug build and has been withdrawn — see
  /// `transport/frame_gate.dart`.  The reason for this change is that the work is
  /// wasted by construction, not that a benchmark demanded it.)
  ///
  /// Only this page can know it is off screen, so it reports it; what to *do*
  /// about it lives in `AppState.setLiveViewVisible`, because the frame
  /// subscription and the decode pipeline are not the page's to cancel.
  bool _liveViewVisible = false;

  /// Ask the ambient tree whether this page is actually being shown.
  ///
  /// Both halves matter and neither is sufficient:
  ///
  /// * `Visibility.of` — `IndexedStack` marks every non-selected child hidden and
  ///   rebuilds it when that flips, which is the tab switch;
  /// * `ModalRoute.isCurrentOf` — false once another route covers this one, which
  ///   is what opening the album or the video page *from* the live view does.  A
  ///   covered route is not repainted either.
  ///
  /// Both register a dependency, so `didChangeDependencies` runs when either
  /// changes — which is why this is read here rather than in `build`, where it
  /// would be a state change during build.
  bool _readVisible() {
    final shown = Visibility.of(context);
    final route = ModalRoute.isCurrentOf(context);
    return shown && route != false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = _readVisible();
    if (visible == _liveViewVisible) return;
    _liveViewVisible = visible;
    app.setLiveViewVisible(visible);
  }

  AppState get app => widget.app;

  bool _keepAwakeApplied = false;

  @override
  void dispose() {
    _focusDebounce?.cancel();
    _focusMarkerTimer?.cancel();
    // Never leave the screen pinned on after this screen is gone: a keep-awake
    // that outlives its reason is just a battery drain the user cannot explain.
    unawaited(ScreenControl.keepAwake(false));
    if (_histogramHooked) {
      app.frameNotifier.removeListener(_onFrameForHistogram);
      _histogramHooked = false;
    }
    _histogram.dispose();
    _dials.dispose();
    super.dispose();
  }

  /// Keep the screen on while a preview is actually running.
  ///
  /// A camera controller is held at arm's length with both hands occupied, so a
  /// screen that times out mid-composition is a real annoyance. The official app
  /// has this defect in a subtle form: it requests `WAKE_LOCK` in its manifest and
  /// then never sets any flag, so its screen sleeps anyway.
  ///
  /// Called from `build`, which is safe because [ScreenControl.keepAwake] is
  /// idempotent and returns early when the state has not changed. Tying it to the
  /// preview rather than to the page means it is released when the preview stops,
  /// which is the moment the user is no longer looking through the camera.
  /// Start or stop histogram sampling with the user's toggle.
  ///
  /// Started here rather than in `initState` because the sampler's whole cost is
  /// the decode, and there is no reason to pay it for a panel nobody opened.
  /// The histogram must see frames, and the only cheap place to catch them is the
  /// frame notifier itself — going through `build` would sample the decoded widget
  /// tree rather than the arriving JPEG.
  void _onFrameForHistogram() {
    final f = app.frameNotifier.value;
    if (f != null) _histogram.offer(f);
  }

  bool _histogramHooked = false;

  void _syncHistogram() {
    final want = _showHistogram && app.link.previewRunning;
    if (want && !_histogramHooked) {
      app.frameNotifier.addListener(_onFrameForHistogram);
      _histogramHooked = true;
    } else if (!want && _histogramHooked) {
      app.frameNotifier.removeListener(_onFrameForHistogram);
      _histogramHooked = false;
    }
    if (want) {
      _histogram.start();
    } else {
      _histogram.stop();
    }
  }

  void _syncKeepAwake() {
    // The user's own preference is now part of the condition, which is why this
    // no longer tracks `previewRunning` alone: a user who turned the pin off must
    // get it released on the next build, not only when the preview stops.
    final want = app.keepScreenOn && app.link.previewRunning;
    if (want == _keepAwakeApplied) return;
    _keepAwakeApplied = want;
    unawaited(ScreenControl.keepAwake(want));
  }

  /// Convert a tap in the preview box to the camera's focus coordinate space and
  /// send it.  The marker is drawn **where the user tapped** and does not move.
  ///
  /// The conversion is the official app's own algorithm (see [FocusMapper]); the
  /// camera's focus plane is **not** the preview's 800x600 pixel space, and using
  /// that space is what made earlier focus points land in the wrong place.
  ///
  /// ## Why the marker does not move any more
  ///
  /// An earlier version drew the marker at the tap, let the command's reply move
  /// it, and rendered "the camera did not name a usable point" as a second,
  /// outlined marker at the plane centre — on the theory that `RCDoFocus` answers
  /// with where the AF system settled.
  ///
  /// That theory is falsified by measurement.  Against the real camera, `Manual`
  /// echoes the request verbatim and `Auto` answers `(360, 240)` for **every**
  /// request — including after the AF point has been moved elsewhere with
  /// `Manual`.  The app sends `Mode='Auto'`, so the reply is a constant: the
  /// marker moved to the centre of the frame on every tap, no matter where the
  /// user tapped.  Two emulator screenshots of taps in opposite corners
  /// (`analysis/emulator/151_focus_topleft.png`, `152_focus_bottomright.png`)
  /// show one marker position, which is the defect stated as a picture.
  ///
  /// So the marker stays on the tap, which is the one thing that is certainly
  /// true: that is where the command was sent.  Nothing here claims the camera
  /// accepted it, focused there, or focused anywhere — the reply carries no such
  /// information, and inventing a position from it is what went wrong.
  void _handleTap(Offset local, Size box) {
    final aspect = app.cameraState?.imageAspect ?? '4:3';

    if (kDebugMode && !FocusMapper.isKnownAspect(aspect)) {
      debugPrint('focus: unrecognised aspect "$aspect"; treating it as 4:3');
    }

    final (cx, cy) = FocusMapper.toCamera(
      localX: local.dx,
      localY: local.dy,
      // Both dimensions: on the 4:3 plane the camera scales x by the view width
      // and y by the view *height*. Passing the width for both silently squashes
      // every focus point vertically.
      viewWidth: box.width,
      viewHeight: box.height,
      aspect: aspect,
    );

    if (kDebugMode && !FocusMapper.isPlausible(cx, cy, aspect)) {
      debugPrint('focus: ($cx, $cy) is outside the $aspect plane — the mapping '
          'or the aspect is wrong');
    }

    _showFocusMarker(local);

    // Debounce: the camera is still settling from the previous request, and
    // rapid-fire focus is the same request pattern that strands the capture
    // state machine.
    _focusDebounce?.cancel();
    _focusDebounce = Timer(const Duration(milliseconds: 350), () async {
      if (kDebugMode) debugPrint('focus: tap -> camera ($cx, $cy) in $aspect');
      await app.focusAt(cx, cy);
      // The reply is deliberately not read.  It is not a focus position; see the
      // table in `focus_mapper.dart`.  The marker was already drawn above and has
      // nothing to learn from the answer.
    });
  }

  void _showFocusMarker(Offset at) {
    setState(() => _focusPoint = at);
    _focusMarkerTimer?.cancel();
    _focusMarkerTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncKeepAwake();
    _syncHistogram();
    final st = app.cameraState;

    // The whole screen, not just the middle, is laid out here.
    //
    // A 4:3 frame cannot fill a phone screen, so there are always black bands —
    // above and below in portrait, left and right in landscape. The usual
    // approach is to ignore them and float translucent controls *over* the
    // picture, which covers the thing the user is composing. The bands are
    // exactly control-shaped, so they get used instead.
    //
    // `SafeArea` is not cosmetic here. The bands are computed from the *available*
    // box and the chrome is pinned to its edges, so without the insets the bottom
    // navigation row is laid out underneath the system status bar in portrait and
    // underneath the gesture bar in landscape — which is exactly what a device
    // screenshot showed. Insetting the whole layout once is simpler and safer than
    // insetting the four edges separately and getting one of them wrong.
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, screen) {
          // The readout's want is **conditional on what the controls leave**, so it is
          // asked of the geometry first.
          //
          // `readoutRoom` is arithmetic on the screen and the preview aspect only —
          // the frame's size never depends on the bands — so constructing a layout to
          // ask the question and then constructing the one that is used is not
          // circular. See `ViewfinderLayout.readoutRoom`, and the two constants above
          // for why the choice is between two *contents* (the camera's own words, or
          // their short forms) rather than one number.
          final geometry = ViewfinderLayout(
            availableWidth: screen.maxWidth,
            availableHeight: screen.maxHeight,
            previewAspect: _aspect,
            controlBandWant: _controlBandWidth,
          );
          final readoutWant = geometry.readoutRoom >= _readoutFullWidth
              ? _readoutFullWidth
              : _readoutCompactWidth;

          final layout = ViewfinderLayout(
            availableWidth: screen.maxWidth,
            availableHeight: screen.maxHeight,
            previewAspect: _aspect,
            // Measured widths of what actually goes in each column, so the bands
            // are sized by their content instead of by the screen's height.
            //
            // This is the landscape fix. `availableHeight/3` gave a 99 dp column on
            // a 914x411 dp screen, and `_BandFitted` then scaled the 280 dp
            // navigation row into it — 12 sp labels landing at about 4 sp, which the
            // emulator showed as an illegible speck. The width was always there: a
            // 4:3 frame needs 332 of those 914 dp, so 582 dp sat unused.
            controlBandWant: _controlBandWidth,
            // The readout's own words when there is room for them, its short forms
            // when there is not. On the reference body that is 156 in the normal
            // landscape layout and 78 in full screen — and the control column is 288
            // in both, which is what `fullscreen_controls_size_test` pins.
            infoBandWant: readoutWant,
            // The same treatment for the portrait end rows. They used to split the
            // slack evenly, 209.5dp above and below on a 411x727 body, to hold a
            // one-line state strip and a shutter bar. Sizing them to their content
            // frees what the user pointed at: the empty space around the frame, which
            // is where the settings panel needs to go.
            topBandWant: _topBandWant,
            bottomBandWant: _bottomBandHeight,
          );
          final bands = layout.bands;
          final sideColumns = layout.usesSideColumns;

          // Which vocabulary the readout column is drawing — decided from the band it
          // actually got rather than from the want, so a body where the layout had to
          // trim the want also gets the short forms.
          final compactReadout = layout.infoBandWidth < _readoutFullWidth;

          // How much room the settings panel may use.
          //
          // **Not** `layout.endBandSlack`: that is the space the end rows did not
          // claim, which leaves the picture its full height and therefore gives the
          // panel only ~175dp — about two rows again, which is the complaint. The panel
          // is allowed to take from the preview down to [_minPreviewHeight], because
          // the picture is already full-width and shortening the preview area
          // letterboxes rather than crops.
          final chrome = bands.$2 + bands.$4;
          final panelRoom = screen.maxHeight - chrome - _minPreviewHeight;
          final panelHeight = _panelHeight.clamp(
            panelRoom < _minPanelHeight ? panelRoom : _minPanelHeight,
            panelRoom < _minPanelHeight ? _minPanelHeight : panelRoom,
          );
          // Remembered so a drag starts from what is actually on screen: `_panelHeight`
          // may be the "as much as fits" sentinel, which is no use as a drag origin.
          _resolvedPanelHeight = panelHeight;

          final preview = _previewArea(st);
          final shutter = _ShutterBar(
            app: app,
            wide: screen.maxWidth > screen.maxHeight,
            // The slot the slotted column will put it in, when there is one. Null in the
            // content-sized layouts (portrait, and full screen without the dials), where
            // the bar sizes itself and `_SideColumn` scrolls what does not fit — which is
            // the behaviour every layout except landscape full screen has always had.
            maxHeight: app.fullScreen &&
                    st != null &&
                    fullScreenColumnFits(screen.maxHeight)
                ? fullScreenColumnSlots(screen.maxHeight).shutter -
                    2 * kColumnChildPadding
                : null,
          );
          final nav = _BottomNav(
            settingsOpen: _showSettings,
            onToggleSettings: () => setState(() => _showSettings = !_showSettings),
          app: app,
          onOpenAlbum: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => AlbumPage(app: app)),
          ),
          // Remote recording lives on its own page rather than in the settings
          // list: it is the one capability the official app lacks entirely, so it
          // should not be buried among the parameters the official app does have.
          onOpenVideo: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => VideoPage(app: app)),
          ),
        );

        final showChrome = app.link.isReady || app.link.isLost;

        if (!showChrome) {
          return Column(children: [
            Expanded(child: preview),
            // `Flexible`, not a plain child, and the bar scrolls inside it.
            //
            // The bar is drawn on the **first screen of the app** — every launch,
            // before any camera exists — so it has to survive a narrow body and a
            // large system font at once, and both of those make it taller: the
            // status sentence wraps, and with 320 dp of width and `en` at 1.3 the
            // connect button's own label takes two lines and the icon buttons drop
            // to a second run. Measured on a 320x480 body at 1.3: the bar wants
            // **502 dp** of a 480 dp screen, and because `Expanded` is greedy the
            // preview was already at zero height when it overflowed by 22.
            //
            // So the bar claims what it needs and no more (`FlexFit.loose`), and
            // what does not fit **scrolls** rather than throwing. Nothing the user
            // has to press is lost: a scroll is reachable; a clipped row is not.
            Flexible(
              fit: FlexFit.loose,
              child: Align(
                // Pinned to the bottom, and the `Align` is not decoration: a flex
                // share is a share of the *slack*, so both of these children are
                // offered half the screen whatever they contain. `FlexFit.loose`
                // then lets the bar take only its own height — and without the
                // `Align` the bar would be centred in the half it was offered,
                // measured 79.5 dp above the bottom edge instead of on it.
                alignment: Alignment.bottomCenter,
                child: SingleChildScrollView(
                  child: _ConnectBar(app: app),
                ),
              ),
            ),
          ]);
        }

        if (sideColumns) {
          // Landscape, or any wide screen: the bands are on the left and right, so
          // the camera state goes down one side and everything the user presses
          // goes down the other. The frame keeps the full height and is flanked
          // rather than covered, which is the whole point of the band model — a
          // 4:3 preview on a 16:9 or 20:9 screen leaves just enough room for a
          // column of controls, and those columns are not over the picture.
          //
          // Every child of a band is wrapped in `_BandFitted`, because a band's
          // width comes from the screen's aspect rather than from a breakpoint: a
          // 20:9 phone leaves about 160dp a side, while the same build on a
          // tablet's window leaves less, and chrome built for a 360dp panel would
          // simply be clipped there.  It degrades gracefully; it is **not** the
          // sizing mechanism.  A band narrower than its content's design width is a
          // layout bug that `fullscreen_controls_size_test.dart` fails on, not a
          // tight fit to be absorbed here — see `analysis/54`.
          //
          // ## Why the columns are fixed-width, and the flex attempt that failed
          //
          // `SizedBox(width: bands.$1)` reserves exactly what the layout maths
          // decided, and `frameRect` then centres the picture in what is left. That
          // is the geometry the checks in `tool/verify_transport.dart` pin, and it
          // is what keeps the picture at ~2/3 of a 20:9 screen.
          //
          // I replaced it with `Expanded(flex: ...)` on the theory that it would
          // reclaim space a half-empty column was wasting. It does the opposite:
          // `flex` divides only the space left after each child's **minimum**
          // intrinsic width, and a column of labelled buttons has a wide minimum
          // (an icon plus "Album" plus padding). The measured result was the
          // picture getting **one third** of the width instead of two thirds —
          // `test/ui_smoke_test.dart` caught it as
          // "landscape picture is only 712.0 of 2136.0 wide", which is why that
          // assertion exists.
          // ## The exposure dials exist here and nowhere else
          //
          // The user's requirement A: the dials go into **landscape full screen**
          // only, "rather than the other non-full-screen states where space is really
          // small", and the parameters they cover are then dropped from the settings
          // panel so the same control does not exist twice.
          //
          // The measurements behind "only here" are in `analysis/60`: the control
          // column is 288 dp wide and 411 dp tall in full screen, which is exactly
          // enough for the toggle row, two dials, the shutter bar, the readout strip
          // and the navigation row. In the **normal** landscape layout the same column
          // is 288 x 297, and in portrait the chrome is two short rows — neither has
          // the height, and a dial that gets scaled below its design size is the defect
          // `analysis/45` records.
          //
          // `st != null` is part of the condition rather than an afterthought: a dial
          // shows the **camera's** value, this project does not push a client-side
          // cache at the camera (`analysis/51` §1.3, the Sony Imaging Edge complaint),
          // and with no state JSON there is no value to show and no mode to plan from.
          // It is also what keeps this feature out of the way of `_ConnectBar` and of
          // the first moments after connecting.
          final dialMode = st?.exposureMode ?? '';
          final dialsVisible = app.fullScreen && st != null;
          final dialsAbove = dialsVisible
              ? fullScreenDialsAboveShutter(dialMode, AppState.isParamEffective)
              : const <String>[];
          // The camera's explanation of a blocked shutter and the read-only extras
          // share one slot below the shutter, and the explanation wins it: measured,
          // the column cannot hold both (the longest message is 194 dp of shutter bar
          // on its own), and when that message is up the extras have nothing live to
          // show anyway — the histogram samples frames, and the persistent blocked
          // states are exactly the ones with no frames.
          final showExtras = app.shutterBlockedReason == null;
          final histogramOnRight = _showHistogram && dialsVisible;

          return Row(
            children: [
              // The left band is the **readout**: the camera's own numbers and
              // nothing pressable, apart from the histogram it shares the column
              // with.
              //
              // It used to lead with `_TopBar` — the identity chip, the drawn /
              // received fps chips and the grid and histogram toggles. That moved to
              // the control band for the reason recorded there, and it had to: the
              // row measures 264.5 dp with the preview running while this band is
              // **78 dp** wherever the controls are contending for the slack (156
              // where they are not), and a row with two 48 dp toggle buttons scaled to
              // 0.29 has no usable tap targets in it. The readout below it is text and
              // survives being scaled; those two buttons do not.
              SizedBox(
                width: bands.$1,
                child: _SideColumn(
                  alignment: Alignment.topCenter,
                  children: [
                    // Back on the **left**, where it started.
                    //
                    // It was moved to the right band to fill the dead space above the
                    // shutter, and that was the wrong trade: the right band is where the
                    // controls live, and putting the readout there crowded them —
                    // "if everything is on the right it squeezes the space". The left
                    // band's job is information, and it has room for it.
                    //
                    // That is still true, and it is why the readout stayed when
                    // `_TopBar` left: a column of label-over-value pairs is exactly
                    // what a band this shape is for.
                    //
                    // `compact` is what makes it survive the narrow band: the camera
                    // writes `Incandescent` and `HContrastBW`, which want 144 and 132
                    // dp at 12 sp, and this column has 66 dp of text room in full
                    // screen. See [compactReadoutValue].
                    if (st != null)
                      _SideState(state: st, compact: compactReadout),
                    // ISO and the shooting mode, in **every** exposure mode: the left
                    // column is the fixed half of the dial layout, and only the right
                    // column's contents vary. That is the user's requirement B, and it
                    // is what makes the operating logic the same in M, A, S and P.
                    //
                    // The dials are the **compact** variant because this band is
                    // `kMinReadoutBand` = 78 dp wide and `_BandFitted` leaves 70 of it:
                    // a 175 dp dial here would be drawn at 0.42, which is the defect
                    // `analysis/54` exists for. `kCompactDialWidth` is that 70 dp.
                    if (dialsVisible)
                      _BandFitted(
                        child: _dialStack(
                          kFullScreenDialsLeftColumn,
                          st,
                          l10nOf(context),
                          height: kDialHeight,
                          designWidth: kCompactDialWidth,
                          steppers: false,
                        ),
                      ),
                    // The histogram stays in this column wherever the dials are not
                    // — i.e. in the normal landscape layout, and in full screen before
                    // the first frame arrives. In full screen it moves below the
                    // shutter, which is the user's requirement B: "the histogram used
                    // to be on the left and is too small — put it below the shutter
                    // control on the right". Measured, it is drawn at 0.56 of its size
                    // on the left (a 132 dp panel in a 78 dp band) and at 1.0 in the
                    // 288 dp control column.
                    if (_showHistogram && !histogramOnRight)
                      _BandFitted(child: _HistogramPanel(sampler: _histogram)),
                  ],
                ),
              ),
              Expanded(child: preview),
              SizedBox(
                width: bands.$3,
                // ## The column has two shapes, and which one is a requirement
                //
                // With the dials off this is the column `analysis/54` settled: content
                // sized, centred as one group. With them on it is the **slotted** column
                // of `fullScreenColumnSlots`, where the shutter is placed from the band
                // alone and the dials and the read-only extras scale into what is left.
                //
                // The reason is the user's third report: *"the shutter position should
                // not move."* A content-sized column cannot promise that — adding a dial
                // in M, or turning the histogram on, changes the group's height and the
                // centring moves the shutter with it. `test/mode_aware_dials_test.dart`
                // measures `getRect(btn-shutter)` across M/A/S/P and both histogram
                // states and requires all eight to be the same rectangle.
                //
                // `fullScreenColumnFits` is not an optimisation: the full-screen layout is
                // reachable on a 297 dp landscape body the full-screen button cannot
                // actually be pressed from, and the slot arithmetic collapses the column
                // there (measured: a 62.9 dp band and a shutter drawn at 0.3). Below that
                // height the old content-sized column is the better failure.
                child: !dialsVisible ||
                        !fullScreenColumnFits(screen.maxHeight)
                    ? _SideColumn(
                        // Centred, so the shutter sits nearer the middle of the screen
                        // rather than at the very bottom with all the slack above it —
                        // which was the "too much white space above the shutter" report.
                        alignment: Alignment.center,
                        children: [
                          _sideColumnTop(app, nav),
                          _BandFitted(child: shutter),
                          if (showExtras && histogramOnRight)
                            _BandFitted(
                                child: _HistogramPanel(sampler: _histogram)),
                          _BandFitted(child: nav),
                        ],
                      )
                    : _fullScreenControlColumn(
                        bandHeight: screen.maxHeight,
                        app: app,
                        state: st,
                        mode: dialMode,
                        dialsAbove: dialsAbove,
                        shutter: shutter,
                        nav: nav,
                        showExtras: showExtras,
                        histogramOnRight: histogramOnRight,
                      ),
              ),
              // The second level opens over the frame rather than replacing a
              // side column. A dropdown row needs roughly 240dp and a band is
              // sized for a button; widening the band to fit the panel would
              // shrink the 4:3 frame until it is too small to focus with, which
              // is a worse trade than covering the picture only while the user
              // is not composing.
              if (_showSettings)
                _SettingsPanel(
                  app: app,
                  state: app.cameraState,
                  tab: app.settingsTab,
                  onSelectTab: _selectSettingsTab,
                  onToggleGroup: _toggleSettingsGroup,
                  onOpenVideo: nav.onOpenVideo,
                  onOpenAlbum: nav.onOpenAlbum,
                  onClose: () => setState(() => _showSettings = false),
                  onOpenBleLog: () => _showBleLog(context, app),
                  onOpenWifiDiagnostics: () =>
                      _showWifiDiagnostics(context, app),
                  // Requirement A, second half: the parameters the dials cover are
                  // **removed from this panel** while the dials are on screen, so the
                  // same setting does not exist in two places. Empty when the dials are
                  // not shown, which is every layout except landscape full screen.
                  dialedCommands: dialsVisible
                      ? fullScreenDialCommands(dialMode, AppState.isParamEffective)
                      : const <String>{},
                  width: layout.settingsPanelWidth,
                ),
            ],
          );
        }

        // Portrait: the bands are above and below, so the frame sits between an
        // information band on top and a control band underneath. The preview
        // column is sized to what the frame actually needs, minus whatever the
        // bands take, so nothing ever overlaps the picture.
        // The panel is a direct child of the Column rather than of the band, so
        // its height follows its own content and only the list scrolls — a
        // fixed-height band containing a second scrollable is how a nested
        // scroll ends up fighting the outer one.
        final settingsPanel = _showSettings
            ? _SettingsPanel(
                app: app,
                state: app.cameraState,
                tab: app.settingsTab,
                onSelectTab: _selectSettingsTab,
                onToggleGroup: _toggleSettingsGroup,
                onOpenVideo: nav.onOpenVideo,
                onOpenAlbum: nav.onOpenAlbum,
                onClose: () => setState(() => _showSettings = false),
                onOpenBleLog: () => _showBleLog(context, app),
                onOpenWifiDiagnostics: () => _showWifiDiagnostics(context, app),
                // Only in portrait: there the panel shares the column with the
                // preview, so its height is a trade the user can make. In landscape it
                // is a full-height side column and there is nothing to trade.
                onResize: (delta, {start = false}) => setState(() {
                  if (start) {
                    _panelHeightStart = _resolvedPanelHeight;
                    return;
                  }
                  // Dragging the header **up** grows the panel, which is what a grab
                  // handle implies; `delta` is positive downwards.
                  _panelHeight = (_panelHeightStart - delta).clamp(
                    _minPanelHeight,
                    _maxPanelHeight,
                  );
                }),
              )
            : null;

        // When the bottom band is too thin to hold chrome — a very wide or very
        // short window — everything stacks underneath the picture instead of
        // being squeezed into a space that cannot fit it.
        return Column(
          children: [
            // The layout's ask for the top band is a **floor**, not a ceiling.
            //
            // `_topBandWant` is `_topBandHeight` = 72, "the icon row plus the one-line
            // state strip", measured at the default text scale. At a 2.0 accessibility
            // scale that one line is 16 dp taller, and a `SizedBox` here clamped the band
            // back to 72 — so the `Column` inside painted its last 4 dp **outside the
            // box**, over the preview, because `_TopBand`'s wrapper is a `Container` with
            // no clip.
            //
            // At every scale the page has ever been looked at, 72 is still the answer and
            // nothing moves: the band is `max(72, its content)`. It grows only when the
            // reader's own font size makes the strip taller than the constant, and the
            // strip cannot grow past **one** line (see `_StateStrip`), so this is bounded
            // by one line of type rather than by how many values the camera reports. The
            // cost is a few dp of picture at the largest system font, which is the trade
            // this file already makes everywhere else: the readout yields, the picture is
            // what is being composed.
            if (bands.$2 > 0)
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: bands.$2),
                child: _TopBand(
                  app: app,
                  state: st,
                  histogram: _showHistogram ? _histogram : null,
                  onToggleGrid: () {
                    setState(() => _showGrid = !_showGrid);
                  },
                  onToggleHistogram: () =>
                      setState(() => _showHistogram = !_showHistogram),
                  histogramOn: _showHistogram,
                  gridOn: _showGrid,
                ),
              ),
            Expanded(child: preview),
            // The shutter is emitted before the panel in both branches, so opening
            // the menu never moves it out from under the user's thumb. Inside the
            // band the panel is therefore placed after the band, which reads as
            // "below the shutter" there too.
            if (bands.$4 > 0)
              SizedBox(
                height: bands.$4,
                child: _BottomBand(shutter: shutter, nav: nav),
              )
            else ...[
              shutter,
              if (settingsPanel != null) settingsPanel,
              if (bands.$2 <= 0 && st != null) _StateStrip(state: st),
              nav,
            ],
            // A **definite height**, not `Flexible`.
            //
            // It was `Flexible` to stop the panel overflowing the Column, and that
            // worked — but a `Flexible` sibling of an `Expanded` preview splits the
            // free space evenly with it, so the panel got 154dp of the 308dp going:
            // about two settings rows once the 44dp header and 34dp tab strip took
            // theirs. That is the "only two lines" that was reported, and it was a
            // consequence of the fix for the overflow rather than of the design.
            //
            // Now the end rows are sized to their content and the space they leave
            // (`endBandSlack`) is the panel's budget, so the picture is untouched. The
            // user can drag the header to trade preview height for more rows.
            if (bands.$4 > 0 && settingsPanel != null)
              SizedBox(height: panelHeight, child: settingsPanel),
            // NOTE: no second `nav` here. `_BottomBand` above already renders it,
            // and an extra copy put **two** navigation bars on screen whenever the
            // bottom band had room — reported from a device screenshot. The
            // redundant line looked harmless because the `else` branch also emits
            // `nav`; the two branches are mutually exclusive, so the duplicate was
            // only ever visible in the banded case.
          ],
        );
        },
      ),
    );
  }

  /// The top of the control column: identity, link health, and the two view toggles.
  ///
  /// Shared by both shapes of the column because it is the same row in both, and it is
  /// **not** part of this round's change — `analysis/54` measured it into the control
  /// band and nothing here revisits that. It is a method rather than a local so the two
  /// branches cannot drift apart by a copy-paste.
  ///
  /// It was in the left band and moved here with the full-screen band fix, and the reason
  /// is measured rather than aesthetic: with the preview running this row lays out at
  /// **264.5 dp** (identity chip 46, the `0/0 fps` chip 80.5, a 48 dp and a 40 dp toggle)
  /// while the readout band it used to sit in is **78 dp** wherever the two columns
  /// contend for the slack. Scaled to fit, that row's toggle buttons would be 14 dp
  /// across — less than a third of a tap target. The camera readout beside the shutter is
  /// text and survives being drawn small; a button does not.
  Widget _sideColumnTop(AppState app, _BottomNav nav) => _BandFitted(
        child: _TopBar(
          app: app,
          onToggleHistogram: () =>
              setState(() => _showHistogram = !_showHistogram),
          histogramOn: _showHistogram,
          onToggleGrid: () => setState(() => _showGrid = !_showGrid),
          gridOn: _showGrid,
          bare: true,
        ),
      );

  /// The full-screen control column with the dials on screen: **the shutter does not move**.
  ///
  /// ## The structure, and why it is explicit arithmetic rather than `Expanded`s
  ///
  /// `fullScreenColumnSlots(bandHeight)` splits the band into a dial region, a shutter row
  /// and a below region, from the band height alone — so the shutter's rectangle is the
  /// same in M, A, S and P and with the histogram on or off, which is the user's third
  /// report and is measured as `getRect(btn-shutter)` in `mode_aware_dials_test.dart`.
  ///
  /// The alternative — `Expanded` children with `flex` — cannot do this. A flex share is
  /// a fraction of the *leftover*, and the leftover depends on how tall the other children
  /// turned out, which for a `FittedBox`-wrapped control is a feedback loop: the dials would
  /// be given 2/7 of a space that changes as they scale into it. The slots are therefore
  /// computed in `lib/protocol/`, where they can be checked in the plain Dart VM with no
  /// engine, and this method only places them.
  ///
  /// ## The two ways a slot can be over-full, and what happens in each
  ///
  /// * the **dials** cannot overflow: their slot is a fixed height and the dial scales into
  ///   it (that is the whole point of the adaptive cell in `ExposureDial`);
  /// * the **below** slot can, because the camera's own explanation of a blocked shutter is
  ///   236.3 dp of bar (`analysis/60` §6). It is therefore a `SingleChildScrollView`, so
  ///   that message scrolls inside its slot instead of pushing anything. Nothing the user
  ///   presses lives in it — the navigation row is pinned below it, out of the scroll — and
  ///   that is the rule `_BottomBand` already applies in portrait: *"navigation is not
  ///   optional and status text is."*
  Widget _fullScreenControlColumn({
    required double bandHeight,
    required AppState app,
    required CameraState state,
    required String mode,
    required List<String> dialsAbove,
    required _ShutterBar shutter,
    required _BottomNav nav,
    required bool showExtras,
    required bool histogramOnRight,
  }) {
    final slots = fullScreenColumnSlots(bandHeight);
    // What a dial is allowed to fill: the region, less the slot's own padding and the 4 dp
    // between two dials. One dial gets the whole of it, which is what makes P's single EV
    // dial larger than either of M's two — the user's "scale adaptively to fill the blank
    // space" read literally, per dial rather than per region.
    final dialGap = 4.0 * (dialsAbove.length - 1);
    final dialCell =
        (slots.above - 2 * kColumnChildPadding - dialGap) / dialsAbove.length;

    return Column(
      children: [
        // Pinned to the bottom and outside the scroll, so the only route to Settings,
        // Video and Album survives the longest status message the camera can produce.
        SizedBox(
          height: kFullScreenNavHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                vertical: kColumnChildPadding),
            child: _BandFitted(child: nav),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              SizedBox(
                height: kFullScreenTopBarHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: kColumnChildPadding),
                  child: _sideColumnTop(app, nav),
                ),
              ),
              SizedBox(
                height: slots.above,
                child: dialsAbove.isEmpty
                    ? null
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: kColumnChildPadding),
                        child: _BandFitted(
                          child: _dialStack(
                            dialsAbove,
                            state,
                            l10nOf(context),
                            height: dialCell,
                            designWidth: kDialWidth,
                            steppers: true,
                          ),
                        ),
                      ),
              ),
              SizedBox(
                height: slots.shutter,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: kColumnChildPadding),
                    child: _BandFitted(child: shutter),
                  ),
                ),
              ),
              // ## The below slot, and why there is no `_BandFitted` around it
              //
              // Everything the column draws goes through `_BandFitted`, which is a
              // `FittedBox`: it measures its child and scales it to fit **both** axes of
              // whatever box it lands in. Here the box is this slot, which is
              // `fullScreenColumnSlots(...).below` tall — and the camera's blocked-shutter
              // explanation is 142 dp of content, taller than the 125.2 dp the slot has on
              // the reference body.
              //
              // Wrapped, that made the whole below slot a scrollable column **and** scaled
              // it, so the explanation was painted at about 0.8 of its type size — measured,
              // on the quarantine fixture. The scroll view alone is the right answer: it
              // clips at the slot's edge and the rest is reachable by scrolling, with the
              // text at full size. That is what "the status text is what scrolls" means in
              // portrait's `_BottomBand`, and it is the same sentence here.
              //
              // Nothing is lost horizontally: this column is inside a `SizedBox` of the
              // band's width, so an over-wide child already has a bounded width to fit
              // into.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // M's exposure compensation as a reference (the user's requirement
                      // B: *"in M exposure compensation is not adjustable, it is only an
                      // exposure reference"*) and the histogram. Both are information
                      // rather than controls, so when the column has to carry a status
                      // message instead they are what yields — `showExtras` is the caller
                      // deciding that, and it is measured: the longest explanation is
                      // 236.3 dp on its own.
                      if (showExtras && evIsReference(mode))
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: kColumnChildPadding),
                          child: _EvReference(state: state),
                        ),
                      if (showExtras && histogramOnRight)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: kColumnChildPadding),
                          child: _HistogramPanel(sampler: _histogram),
                        ),
                      // The camera's explanation of a refused shot, when there is one.
                      // **Here** and not inside the shutter bar: the bar's slot is 77 dp
                      // and its controls' row is 68 of them, so a message in the bar has
                      // no room at all — measured, it was drawn in a zero-height box, i.e.
                      // not drawn. This slot already scrolls, which is the same division of
                      // labour `_BottomBand` uses in portrait: the controls are fixed and
                      // the explanation is what scrolls.
                      //
                      // It and the extras below the shutter are mutually exclusive by
                      // construction — `showExtras` is `shutterBlockedReason == null` — so
                      // this is one slot with two possible occupants, not a stack.
                      if (!showExtras)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: kColumnChildPadding),
                          child: shutter.blockedExplanation(context) ??
                              const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One exposure dial, wired to the page's single pacing queue.
  ///
  /// [command] is one of the `RC…` names the dial plan returns; every one of them has
  /// an entry in [_dialCommand], which is also where the dial's `ValueKey` comes from
  /// — the identity carries it, so the key a Marionette script clicks and the command
  /// it provokes are the same fact written once.
  ///
  /// The value and the ladder come from the **camera**: `st` is the state JSON
  /// decoded out of the newest live-view frame, so the dial shows what the camera is
  /// actually set to rather than a client-side cache. That is deliberate and it is the
  /// failure mode `analysis/51` §1.3 records from Sony's app — pushing the last known
  /// setting at a camera that has moved on.
  Widget _dialFor(
    String command,
    CameraState st,
    AppLocalizations l, {
    required double height,
    required double designWidth,
    required bool steppers,
  }) {
    final enabled = AppState.isParamEffective(st.exposureMode, command);
    // Only ever shown on a dial that is actually dead — see `ExposureDial`'s
    // `disabledReason`. In practice the plan never seats a dial for a parameter the
    // mode owns, so this is the belt to the plan's braces: if `isParamEffective`
    // changes, the dial that appears says why instead of turning and doing nothing.
    //
    // The sentence is the ARB's, keyed by the mode the camera is in: it is the one
    // string in this file that used to be written in Chinese for every locale, so an
    // English user read a Chinese explanation of a disabled dial.
    final reason = l.settingsSetByCamera(st.exposureMode);

    Widget dial(ExposureParam? param, DialIdentity? identity, List<String> values,
            String? value) =>
        SizedBox(
          height: height,
          child: ExposureDial(
            param: param,
            identity: identity,
            values: values,
            value: value,
            enabled: enabled,
            disabledReason: reason,
            designWidth: designWidth,
            steppers: steppers,
            onSpin: _dials.spin((identity ?? param!.identity).keyName),
          ),
        );

    return switch (command) {
      kCmdAperture =>
        dial(ExposureParam.aperture, null, lensApertures(st), st.fNumber),
      kCmdShutter =>
        dial(ExposureParam.shutter, null, kShutterSpeeds, st.shutterSpeed),
      kCmdIso => dial(ExposureParam.iso, null, kIsoValues, st.isoSetting),
      kCmdEv =>
        dial(null, kEvDialIdentity, kEvValues, st.exposureCompensation),
      kCmdMode => dial(null, kModeDialIdentity, kExposureModes, st.exposureMode),
      _ => throw ArgumentError.value(command, 'command', 'no dial for this'),
    };
  }

  /// A vertical stack of dials, delivered as **one** child of a band column.
  ///
  /// One child and not several, because `_SideColumn` pads every child by 4 dp top
  /// and bottom: two dials as two children would pay 16 dp of padding for one 4 dp
  /// gap, and `analysis/60` measures the control column's budget to the dp.
  ///
  /// The `SizedBox(width:)` is load-bearing rather than cosmetic. `_BandFitted`
  /// measures its child through a `FittedBox`, which lays the child out with
  /// **unbounded** constraints — and `ExposureDial` fills `c.maxWidth`. A stack with
  /// no definite width therefore hands the dial an infinite one.
  Widget _dialStack(
    List<String> commands,
    CameraState st,
    AppLocalizations l, {
    required double height,
    required double designWidth,
    required bool steppers,
  }) =>
      SizedBox(
        width: designWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < commands.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              _dialFor(
                commands[i],
                st,
                l,
                height: height,
                designWidth: designWidth,
                steppers: steppers,
              ),
            ],
          ],
        ),
      );

  /// The preview plus the transient overlays that must track the frame itself.
  ///
  /// Kept separate from the chrome: these are the things that belong *on* the
  /// image — the composition grid, the focus marker, the warnings — because their
  /// position is meaningful relative to what is being photographed. Everything
  /// else moved into the bands.
  ///
  /// The key is what makes the layout measurable: `test/ui_smoke_test.dart` finds
  /// it and asserts how much of the screen the picture actually gets. That is the
  /// check that turns "landscape feels worse" into a number — the side bands are
  /// paid for out of the preview's width, so a band that reserves space for
  /// nothing is a picture that shrank for nothing.
  Widget _previewArea(CameraState? st) {
    return Stack(
      key: previewAreaKey,
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),

        // Only this subtree listens to the frame notifier, so a 30 fps stream
        // repaints one image instead of the whole screen. The surrounding chrome
        // updates on AppState's 250 ms ticker.
        ValueListenableBuilder<Uint8List?>(
          valueListenable: app.frameNotifier,
          builder: (context, f, _) {
            if (f == null) {
              // `FittedBox` is load-bearing, not decoration. The placeholder is a
              // fixed-height column (a 56dp icon, a gap, a line of text, 32dp of
              // padding), and in landscape the preview area is only as tall as the
              // 4:3 frame minus the chrome — so the column overflowed and its text
              // was drawn *underneath* the connect button. A device screenshot
              // showed the camera glyph and "not connected" spilling past the
              // picture area's bottom edge and being clipped by the button.
              //
              // `scaleDown` shrinks it to fit instead of overflowing, and never
              // enlarges it, so portrait is byte-for-byte unchanged.
              //
              // ## The message is gone entirely, and that is the fix
              //
              // It used to be shown here whenever the link was *not* idle, on the
              // theory that `_ConnectBar` already covers the idle case. But
              // `_ConnectBar` renders `app.link.message` unconditionally, so the
              // busy case printed the same sentence twice — an emulator screenshot
              // of "looking for the camera..." showed it in the middle of the
              // picture *and* in the bar six lines below. Two copies of one
              // status read as two different statuses, and the reader has to work
              // out which one is live. `_ConnectBar` is the single owner of that
              // text; the placeholder says nothing and only indicates activity.
              return FittedBox(
                fit: BoxFit.scaleDown,
                child: _Placeholder(busy: app.link.isBusy),
              );
            }
            return Center(
              child: AspectRatio(
                aspectRatio: _aspect,
                child: LayoutBuilder(
                  builder: (context, c) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _handleTap(
                        d.localPosition, Size(c.maxWidth, c.maxHeight)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Decode straight to the size that will be drawn.
                        //
                        // The frame is 800x600 and the box is usually smaller, so
                        // without `cacheWidth` the engine decodes all 480 000
                        // pixels and then discards most of them in the scale. That
                        // is the largest per-frame cost on a phone and it is pure
                        // waste — unlike frame-skipping, it costs nothing visible.
                        //
                        // `cacheWidth` is in *device* pixels, so the logical width
                        // is scaled by the device pixel ratio; passing the logical
                        // width would decode too few pixels and the preview would
                        // look soft.
                        Image.memory(
                          f,
                          gaplessPlayback: true,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.low,
                          cacheWidth:
                              (c.maxWidth * MediaQuery.devicePixelRatioOf(context))
                                  .round()
                                  .clamp(1, 800),
                          // A malformed or truncated frame is a normal event on
                          // this link — a datagram can be clipped, and the
                          // camera itself produces damaged frames under load.
                          // `Image.memory` throws `Exception: Invalid image data`
                          // for those, and an uncaught throw from a build reaches
                          // `FlutterError.onError`, which is how one corrupt frame
                          // became an error screen over a working live view.
                          //
                          // Returning an empty box keeps the previous frame on
                          // screen: `gaplessPlayback` is already holding it, and
                          // the honest reading of one bad frame is "the stream
                          // hiccuped, the picture did not change" — not "the app
                          // is broken". The next good frame replaces it.
                          errorBuilder: (context, error, stack) =>
                              const SizedBox.expand(),
                        ),
                        if (_showGrid) const _ThirdsGrid(),
                        if (_focusPoint != null)
                          Positioned(
                            left: _focusPoint!.dx - 22,
                            top: _focusPoint!.dy - 22,
                            child: const _FocusMarker(),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),

        // Transient banners stay over the image: they are about the image, and
        // they must be impossible to miss.
        if (app.link.isLost)
          Positioned(left: 0, right: 0, bottom: 8, child: _LostBanner(app: app)),
        if (app.streamPausedForTransfer)
          Positioned(
            left: 0,
            right: 0,
            top: 8,
            child: StreamPausedBanner(
              reason: app.sync.streamPauseReason,
              // The **recent** rate, not the session average: a banner telling
              // the user their preview is frozen must not quote a figure that
              // still looks healthy because of frames received a minute ago.
              fps: app.stats.recentFps,
              // The action the user wants when they are looking at a frozen
              // frame: get the picture back. Clearing the setting alone is not
              // enough — a transfer already running holds the stream — so the
              // hold is released explicitly.
              onKeepRunning: () {
                app.sync.pauseStreamDuringTransfer = false;
                unawaited(app.resumePreviewAfterPause());
              },
              onStopPreview: () => unawaited(app.stopPreview()),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Chrome that lives in the letterbox bands.
//
// These exist as separate widgets rather than inline children because the two
// layouts arrange the same controls differently: a wide short row in portrait, a
// tall narrow column in landscape. Reusing one arrangement and stretching it
// would give a shutter button the shape of a credit card in one orientation.
// ---------------------------------------------------------------------------

/// A vertical strip of chrome, for the bands either side of the frame.
///
/// The column supplies the *vertical* room that a landscape band has in plenty,
/// and scrolls when a short window gives it less than its contents need. Its
/// horizontal room is the band's width, which comes from the screen's aspect and
/// can be narrow enough to squeeze a row of buttons — that is `_BandFitted`'s job
/// rather than this one's, so the two concerns stay separable.
class _SideColumn extends StatelessWidget {
  final List<Widget> children;
  final Alignment alignment;

  const _SideColumn({
    required this.children,
    required this.alignment,
  });

  @override
  Widget build(BuildContext context) {
    Column columnOf(Iterable<Widget> kids) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in kids)
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: c),
          ],
        );

    return Align(
      alignment: alignment,
      child: SingleChildScrollView(child: columnOf(children)),
    );
  }
}

/// Shrinks chrome that was built for a panel down to whatever the band actually
/// is.
///
/// The band's width is a consequence of the screen's aspect and the camera's
/// frame aspect — a 4:3 preview on a 20:9 phone leaves roughly 120dp a side,
/// while the same build on a tablet leaves 400 — so there is no width a widget
/// can be designed against. Scaling down is chosen over clipping because a
/// clipped control looks broken, and over a hand-tuned compact variant per
/// widget because that would be a second layout to keep correct in both
/// orientations.
///
/// Only ever scales *down*: chrome narrower than its band is left at its own
/// size rather than stretched, which would give a shutter button the shape of a
/// credit card.
class _BandFitted extends StatelessWidget {
  final Widget child;

  const _BandFitted({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// The band above the frame in portrait: camera identity and link health.
class _TopBand extends StatelessWidget {
  final AppState app;
  final CameraState? state;
  final VoidCallback onToggleGrid;
  final VoidCallback onToggleHistogram;
  final bool gridOn;
  final bool histogramOn;

  /// Non-null only when the user has switched the histogram on.
  final HistogramSampler? histogram;

  const _TopBand({
    required this.app,
    required this.state,
    required this.onToggleGrid,
    required this.onToggleHistogram,
    required this.gridOn,
    required this.histogramOn,
    this.histogram,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0E0E0E),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Scaled to fit, like every other band child.
          //
          // This row is `M1CN · 0/0 fps · grid · histogram` and it was the one band
          // child left unwrapped, so it was also the one that overflowed: at a 2.0 text
          // scale it needed 391dp in a 387dp row and threw
          // `A RenderFlex overflowed by 4.0 pixels on the right`. Found by
          // `live_view_text_scale_test.dart`, which exists because the bands became
          // content-sized constants — the kind of figure that is measured at the
          // default text scale and breaks on a phone set to large text.
          // Every child of this band is wrapped, and that is the rule rather than a
          // coincidence.
          //
          // This row was once "the one band child left unwrapped", and it overflowed at a
          // 2.0 text scale — `live_view_page.dart` records that. The state strip and the
          // histogram panel then joined the band **unwrapped**, and the same thing happened
          // again: a hardware run for the burst work logged
          // `A RenderFlex overflowed by 55 pixels on the bottom` from this very `Column`,
          // drawn as the yellow-and-black stripe.
          //
          // The band's height is the constant `_topBandHeight`, measured from the contents
          // it had at the time. A constant measured against one set of contents and then
          // given another is the recurring shape here, so the answer is not a bigger number
          // — it is that nothing goes in unwrapped.
          // Every child of this band is wrapped, and that is the rule rather than a
          // coincidence.
          //
          // This row was once "the one band child left unwrapped", and it overflowed at a
          // 2.0 text scale — `live_view_page.dart` records that. The state strip and the
          // histogram panel then joined the band **unwrapped**, and the same thing happened
          // again: a hardware run for the burst work logged
          // `A RenderFlex overflowed by 55 pixels on the bottom` from this very `Column`,
          // drawn as the yellow-and-black stripe.
          //
          // The band's height is the constant `_topBandHeight`, measured from the contents
          // it had at the time. A constant measured against one set of contents and then
          // given another is the recurring shape here, so the answer is not a bigger number
          // — it is that nothing goes in unwrapped.
          _BandFitted(
            child: Row(
              children: [
                _TopBar(
                  app: app,
                  onToggleGrid: onToggleGrid,
                  gridOn: gridOn,
                  onToggleHistogram: onToggleHistogram,
                  histogramOn: histogramOn,
                  bare: true,
                ),
              ],
            ),
          ),
          // **Not** wrapped in `_BandFitted`, and that is a correction rather than an
          // oversight.
          //
          // The obvious reading of this file is "nothing goes in a band unwrapped" — the
          // comment above records this row overflowing horizontally when it was the one child
          // left bare. So these two were wrapped as well, and it did **not** fix the vertical
          // overflow: a `FittedBox` inside a `Column` is laid out with an unbounded main axis
          // and never scales along it. `_BandFitted` fixes horizontal overflow only.
          //
          // It also broke five focus-marker tests, which reach the preview's
          // `GestureDetector` through `find.descendant`. A wrapping that fixes nothing and
          // costs something is not a fix; the height is carried by `_topBandWant` instead.
          if (state != null) _StateStrip(state: state!, bare: true, dense: true),
          if (histogram != null) _HistogramPanel(sampler: histogram!),
        ],
      ),
    );
  }
}

/// The band below the frame in portrait: shutter and navigation.
///
/// The settings panel is deliberately *not* a child any more. It is placed by
/// the page between the shutter and this band, so the panel's height follows its
/// own content and only its list scrolls — nesting a second scroll view inside a
/// fixed-height band makes the two fight over the gesture.
/// The band below the frame in portrait: the shutter and the navigation row.
///
/// Both children are wrapped in [_BandFitted] for the same reason the landscape
/// branch wraps them: the band's width is the *screen's*, and a narrow phone cannot
/// fit a three-button navigation row. At 320dp the row measures ~386dp and
/// overflowed by 66 pixels — a Flutter **error**, drawn as the yellow-and-black
/// stripe, with the third button partly unreachable.
///
/// Scaling down is the choice this page already makes everywhere else rather than a
/// second compact variant: a clipped control looks broken, and `FittedBox` only ever
/// shrinks, so a phone with room keeps the controls at full size.
class _BottomBand extends StatelessWidget {
  final Widget shutter;
  final Widget nav;

  const _BottomBand({required this.shutter, required this.nav});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0E0E0E),
      // The navigation row is **pinned**; only the shutter bar scrolls.
      //
      // Before this the column was one scroll view, so a tall shutter bar pushed the
      // navigation off the bottom of the band and it stopped being tappable. That is
      // not a cosmetic failure — `live_view_overflow_test.dart` caught it as "the
      // toggle did not actually open the panel", i.e. the settings toggle was
      // unreachable — and it appeared the moment the blocked-state message started
      // wrapping to five lines instead of one.
      //
      // Navigation is not optional and status text is, so the status text is what
      // scrolls.
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(child: _BandFitted(child: shutter)),
          ),
          _BandFitted(child: nav),
        ],
      ),
    );
  }
}

/// The camera state, arranged for a narrow column.
///
/// A single joined line does not fit in a side band, so each value gets its own
/// row. This is the one place the two orientations show genuinely different
/// information density: portrait can afford a comma-separated line, landscape
/// cannot.
///
/// ## Scaling instead of wrapping, and why that is not enough on its own
///
/// The values are the camera's own strings and several of them are long, and a side
/// band can be as narrow as 78 dp. So each value is scaled down to the column rather
/// than left to wrap or clip: a wrapped value changes the row height on every frame
/// the camera reports a different setting, which makes the whole column jump while
/// the user is watching it. The same treatment is applied to the **labels**, which
/// used to be plain `Text` in a 74 dp row — `Aperture` measures 72.0 at 9 sp, so at
/// 1.3x the system text scale it wrapped to two lines and grew the row instead.
///
/// Scaling alone is what left the column unreadable, though: at 78 dp it gives a
/// value 66 dp, and `Incandescent` is 144.0 dp of type at 12 sp — measured on the
/// rendered tree, it was drawn at **0.458**, i.e. 5.5 dp. The column was complete,
/// unclipped and impossible to read. So when the band is the narrow one the values
/// are drawn in [compactReadoutValue]'s short forms, which are at most
/// [kCompactReadoutLength] characters and therefore land at 0.79 or better.
///
/// The earlier comment here named `CenterWeighted` as one of the long values. It is
/// the **metering mode**, and this column has no metering row.
class _SideState extends StatelessWidget {
  final CameraState state;

  /// Draw the values in the short forms the narrow band needs.
  ///
  /// Set from the width the column actually got, not from the screen: a body where
  /// the layout had to trim the want gets the short forms too.
  final bool compact;

  const _SideState({required this.state, this.compact = false});

  /// The height a **value** line occupies, whatever the value is.
  ///
  /// ## Why the slot is fixed rather than left to the text
  ///
  /// `FittedBox` sizes itself with `constrainSizeAndAttemptToPreserveAspectRatio`, so
  /// a value that has to be scaled down also becomes a **shorter** row: measured in
  /// the 78 dp column before the short forms existed, `Incandescent` — scaled to
  /// 0.458 — laid out **6.4 dp** tall against `Sunny`'s 14.0. Every row below it then
  /// moved by 7.6 dp each time the camera reported a different white balance, thirty
  /// times a second, under the user's eyes. Wrapping was already ruled out for the
  /// same reason in the other direction (a wrapped value is *taller*); this closes
  /// the shrinking direction, which scaling alone does not.
  ///
  /// 14.0 is the measured height of the value line at its own settings — 12 sp at a
  /// 1.15 line height, 13.8, rounded up by the paragraph's own line metrics. It is
  /// scaled by the system text scale, so a large-text setting still enlarges the
  /// readout rather than being pinned to this number.
  static const double _valueFontSize = 12;
  static const double _valueLineHeight = 1.15;

  /// The same, for the 9 sp label above it.
  static const double _labelFontSize = 9;
  static const double _labelLineHeight = 1.1;

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final rows = <(String, String)>[
      if (state.exposureMode.isNotEmpty) (l.readoutMode, state.exposureMode),
      if (state.shutterSpeed.isNotEmpty) (l.readoutShutter, state.shutterSpeed),
      if (state.fNumber.isNotEmpty)
        (l.readoutAperture, l.readoutApertureValue(state.fNumber)),
      (
        state.isAutoIso ? l.readoutIsoAuto : l.readoutIso,
        state.isAutoIso ? state.isoAutoValue : state.isoSetting
      ),
      if (state.exposureCompensation.isNotEmpty)
        (l.readoutEv, state.exposureCompensation),
      if (state.whiteBalance.isNotEmpty) (l.readoutWb, state.whiteBalance),
      if (state.colorMode.isNotEmpty) (l.readoutStyle, state.colorMode),
      // The camera reports `101` instead of a percentage while it is on external power
      // (the official app draws its `…_battery_charging` drawable for exactly that
      // value), so this row draws the word rather than a percentage that cannot exist —
      // and it draws it from `CameraState.isCharging` rather than testing the number
      // here, so the strip below cannot answer the same question differently.
      //
      // **Two words, not one, because the column has two widths.** The narrow band this
      // row gets in full screen is `kMinReadoutBand` = 78 dp and a value gets 66 of it
      // (`analysis/55`); `Charging` is measured at 96.0 dp, and 96 into 66 is **0.688**,
      // under the 0.75 floor that column is held to. The short form is within
      // `kCompactReadoutLength`, exactly like `Incand.` and `HC-BW` beside it.
      //
      // The word is already the display string, and it still goes through `shown()`
      // below like every other value. That is safe rather than accidental:
      // `paramLabel`'s documented fallback returns a value it was never taught
      // unchanged (`lib/l10n/param_labels.dart`), which is also the answer for the
      // short form, and `compactReadoutValue` only rewrites strings in its own table.
      (
        l.readoutBattery,
        state.isCharging
            ? (compact
                ? l.readoutBatteryChargingCompact
                : l.readoutBatteryCharging)
            : '${state.batteryLevel}%'
      ),
      (l.readoutLeft, state.surplusPhotoCounts),
    ];

    // An absent value is an em dash, and a dash is not a camera word: it is never
    // shortened.
    //
    // ## Why the two columns resolve the firmware's vocabulary differently
    //
    // Both go through `paramLabel`, which is the one path from a pool value to a drawn
    // word — the wire string is the code, the label is what the user reads, and the
    // camera still receives the wire string because nothing here can reach
    // `AppState.setParam`. The **narrow** column then goes through `readoutWord`
    // instead, which applies `compactReadoutValue`'s short table (`Incandescent` →
    // `Incand.`) only when this locale draws the firmware's own word: shortening is
    // English-onto-English, so a translated label is drawn as it stands rather than
    // looked up under a key it does not have.
    String shown(String value) {
      if (value.isEmpty) return '—';
      return compact ? readoutWord(l, value) : paramLabel(l, value);
    }

    // One `TextScaler` read for both slots, so the two cannot disagree about the
    // scale the rows are laid out at.
    final scaler = MediaQuery.textScalerOf(context);
    final labelSlot = (scaler.scale(_labelFontSize) * _labelLineHeight).ceilToDouble();
    final valueSlot = (scaler.scale(_valueFontSize) * _valueLineHeight).ceilToDouble();

    /// A line that is scaled to the column but occupies a **fixed** height, so the
    /// column's total height is a function of how many rows there are and nothing
    /// else.
    Widget slot(double height, Widget text) => SizedBox(
          height: height,
          // `Center` rather than a bare `SizedBox`: a tight height passed into the
          // `FittedBox` would be handed to its aspect-preserving size calculation,
          // which cannot satisfy a tight height and a maximum width at once and
          // returns a box wider than the column.
          child: Center(child: _BandFitted(child: text)),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
              child: Column(
                children: [
                  slot(
                    labelSlot,
                    Text(label,
                        style: const TextStyle(
                            color: Colors.white38,
                            fontSize: _labelFontSize,
                            height: _labelLineHeight)),
                  ),
                  slot(
                    valueSlot,
                    Text(
                      shown(value),
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: _valueFontSize,
                        height: _valueLineHeight,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Aperture choices, bounded by what the attached lens actually offers.
///
/// `FnumberMin`/`FnumberMax` arrive in every frame for free, so no control ever offers
/// an f-stop the lens cannot do — the original app's own rule (`analysis/51` §1.1). The
/// **fallback** matters as much as the clipping: a lens the camera has not identified
/// reports non-numeric bounds, and the answer then is the full ladder rather than an
/// empty one, so a dial over it still shows every stop.
///
/// ## Why the pool's own strings survive the clipping
///
/// The bounds are numbers, so the comparison parses; but the **entries stay the
/// firmware's own strings**, because what this list is for is a *lookup by equality*
/// against `CameraState.fNumber`. `ExposureDial` finds the current step with
/// `values.indexOf(value)` and draws `—` when the index is -1, so a list that spells a
/// stop differently from the state is a dial that renders as if the camera had no
/// aperture at all.
///
/// This is not hypothetical: the first version parsed each stop, filtered, and printed
/// the `double` back with `.toString()`, which always writes a decimal point —
/// `'10'`, `'11'`, `'13'` … came out as `'10.0'`, `'11.0'`, `'13.0'`. Every integer stop
/// from f/10 up then failed the lookup and the dial drew `—` in **M and in A** while the
/// readout column beside it (which never went through this transform) drew `f/11`
/// correctly. The maintainer reported exactly that, from a phone.
///
/// `analysis/51` §2.2 states the rule this broke: **the ladder uses the camera's own
/// spelling, the display uses what a photographer reads**, and the two must not be
/// converted into each other ([`apertureLabel`] is where `f/` is added).
List<String> lensApertures(CameraState s) {
  final range = s.apertureRange;
  if (range == null) return kFNumbers;
  // The parsed `double` is used **only** to test the bound; the string that goes into
  // the list is the one the camera sent. Printing the parsed value is what re-spelled
  // it, and `kFNumbers` is documented as "every f-stop the firmware knows".
  final out = <String>[
    for (final v in kFNumbers)
      if (double.tryParse(v) case final n?
          when n >= range.$1 - 1e-6 && n <= range.$2 + 1e-6)
        v,
  ];
  return out.isEmpty ? kFNumbers : out;
}

/// The exposure compensation in **M**, as a reference rather than an editor.
///
/// ## Why this is not a dial
///
/// The user's specification for the full-screen dials: *"in M exposure compensation is
/// not adjustable, it is only an exposure reference"* — so M stacks aperture and
/// shutter above the shutter button and puts the EV value here, below it, where A/S/P
/// put their EV dial. `evIsReference` in `protocol/viewfinder_layout.dart` owns that
/// rule and records its disagreement with `AppState.isParamEffective`, which answers
/// `true` for `RCEVSet` in every mode.
///
/// A read-only value with no explanation is indistinguishable from a control that has
/// been taken away, so the caption says what it is — the same reasoning that makes a
/// disabled dial show *why* it is disabled. The key is what lets a check assert the
/// difference: in M the tree must hold `ev-hint` and **not** `dial-ev`, and in A/S/P
/// the reverse.
class _EvReference extends StatelessWidget {
  final CameraState state;

  const _EvReference({required this.state});

  /// The width this is designed at.
  ///
  /// The control band's inner width on the reference body, so it is drawn at scale 1.0
  /// there and shrunk as one piece anywhere narrower — the same rule every other child
  /// of `_BandFitted` follows.
  static const double _width = 280;

  /// The height budget: one heading line and one value line. Measured against the
  /// column in `analysis/60`.
  static const double _height = 34;

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    // No text scaling, for the same reason the dials take none: this shares their
    // fixed pixel budget in a column that also holds the shutter and the navigation
    // row, and a larger system font would only be scaled back down here.
    return MediaQuery.withNoTextScaling(
      child: Container(
        key: const ValueKey<String>('ev-hint'),
        width: _width,
        height: _height,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Text(l.dialEv,
                style:
                    const TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.0)),
            const SizedBox(width: 4),
            // Says *why* it is not a dial. `reference` rather than "read-only": the
            // number still means something here — it is what the meter is offset by.
            Text(l.liveEvReference,
                style: const TextStyle(color: Colors.white38, fontSize: 8, height: 1.0)),
            const Spacer(),
            Text(
              evLabel(state.exposureCompensation.isEmpty
                  ? '—'
                  : state.exposureCompensation),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.0,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the link was up and has dropped.
///
/// Without this the app keeps displaying a frozen last frame and a dead shutter,
/// which reads as the app hanging rather than the camera going away.  Verified
/// user complaint: disconnecting the camera left the app "just stopped
/// previewing" with no indication of what happened.
class _LostBanner extends StatelessWidget {
  final AppState app;
  const _LostBanner({required this.app});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xE6B3261E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link_off, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(l.liveConnectionLost,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            // The transport owns the sentence (`AGENTS.md` §4.1); this only picks the
            // language it is drawn in, falling back to the status's own English when it
            // carries no code this build knows.
            linkStatusText(l, app.link),
            style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                key: const ValueKey<String>('btn-lost-check-again'),
                onPressed: () async {
                  // `verifyAlive` **first**, and this order is the fix.
                  //
                  // It used to call `waitForCameraAgain()` first, which declares the
                  // link ready as soon as HTTP answers — without re-pinning the
                  // process to the camera's network. Reporting a loss released that
                  // pin, and on Android an app-scoped specifier network is not routed
                  // by default, so the "recovered" state was one where the app said
                  // "connected" while every request left over cellular.
                  // `verifyAlive` goes through `clearLost`, which rebinds.
                  if (!await app.verifyAlive()) {
                    // Still gone. Spend the longer budget rather than making the
                    // user press again — the camera's AP takes 10-20s to come up.
                    await app.connection.waitForCameraAgain();
                  }
                },
                child: Text(l.liveCheckAgain),
              ),
              TextButton(
                key: const ValueKey<String>('btn-lost-disconnect'),
                onPressed: () => app.disconnect(),
                child: Text(l.disconnect),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Identifies the live-view picture area, so a test can measure it.
///
/// Public because `test/ui_smoke_test.dart` is in a different library, and a
/// private key would force the test to find the widget by type — which cannot
/// distinguish the picture from the placeholder a disconnected app shows.
final Key previewAreaKey = const ValueKey<String>('live-preview-area');

/// Identifies the placeholder shown while there is no frame.
///
/// Public for the same reason as [previewAreaKey], and used by a check that the
/// busy spinner really renders at a visible size: it is inside a `FittedBox`,
/// which an unsized `CircularProgressIndicator` collapses to a dot.
final Key previewPlaceholderKey = const ValueKey<String>('live-preview-placeholder');

/// Identifies the bottom navigation row, so a test can assert there is exactly
/// one of it.
///
/// The duplicate-navigation defect was literally two of these widgets in the tree
/// at once, and nothing about it was visible to a type checker: both call sites
/// were valid. Counting the widget is the precise statement of the bug, where
/// counting a label ("Capture", "Settings") only approximates it and breaks
/// whenever the wording changes.
final Key bottomNavKey = const ValueKey<String>('live-bottom-nav');

// ---------------------------------------------------------------------------

/// Says that the preview is still *on purpose*, and offers the ways out.
///
/// The camera has no way to report its stream state back, so the app cannot
/// verify a pause or a resume — it only knows what it asked for. That is the
/// reason the wording here is about intent ("paused while photos transfer")
/// rather than about the camera, and the reason there are manual escapes.
///
/// ## What was wrong with the first version
///
/// It had **no way to dismiss it** and only one action, "Stop the preview
/// instead" — which is the opposite of what a user staring at a frozen frame
/// wants. Reported from a device screenshot: the card sat over the middle of the
/// screen with no close affordance and no way to get the preview back.
///
/// So it is now dismissible, and the primary action is the one the user actually
/// wants: **turn the pause off**, which resumes the stream. Stopping the preview
/// entirely is still offered, because it is the only recovery this protocol has
/// if a resume never landed.
///
/// Dependencies are injected rather than read from [AppState] so
/// `test/ui_smoke_test.dart` can drive it: the banner only appears while the
/// camera is connected and a transfer holds the stream, which is not a state a
/// headless test can reach — and "the close button does not work" is exactly the
/// kind of thing that must be testable without a camera.
@visibleForTesting
class StreamPausedBanner extends StatefulWidget {
  final String? reason;
  final double fps;
  final VoidCallback onKeepRunning;
  final VoidCallback onStopPreview;

  const StreamPausedBanner({
    super.key,
    required this.reason,
    required this.fps,
    required this.onKeepRunning,
    required this.onStopPreview,
  });

  @override
  State<StreamPausedBanner> createState() => _StreamPausedBannerState();
}

class _StreamPausedBannerState extends State<StreamPausedBanner> {
  /// Hidden for this visit only.
  ///
  /// Deliberately **not** persisted: a pause is a per-transfer condition, and a
  /// banner suppressed forever would leave a later freeze unexplained. It comes
  /// back when the stream pauses again after a resume, which is the moment the
  /// information is useful again.
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    if (_dismissed) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      decoration: BoxDecoration(
        color: const Color(0xE6102A3C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.lightBlueAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.pause_circle_outline,
                  color: Colors.lightBlueAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l.livePreviewPausedForTransfer,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ),
              // The live frame rate, from the socket. It should read zero while
              // the pause holds, which is the honest version of "no frames are
              // arriving" rather than a spinner over a frozen image.
              Text(
                l.liveFps(widget.fps.toStringAsFixed(0)),
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              IconButton(
                key: const ValueKey<String>('banner-close'),
                tooltip: l.liveHideThis,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _dismissed = true),
                icon: const Icon(Icons.close, size: 18, color: Colors.white54),
              ),
            ],
          ),
          Text(
            widget.reason ?? l.livePausedBannerBody,
            style: const TextStyle(
                color: Colors.white70, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              // The action the user wants when they are looking at this: get the
              // picture back. Turning the setting off resumes immediately, so
              // this is one tap rather than a trip to the settings menu.
              FilledButton.tonal(
                onPressed: () {
                  widget.onKeepRunning();
                  setState(() => _dismissed = true);
                },
                child: Text(l.liveKeepPreviewRunning),
              ),
              TextButton(
                onPressed: () {
                  widget.onStopPreview();
                  setState(() => _dismissed = true);
                },
                child: Text(l.liveStopPreview),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// What the preview area shows when there is no frame to show.
///
/// ## Why the spinner is sized explicitly
///
/// The caller wraps this in `FittedBox(fit: BoxFit.scaleDown)`, and an
/// indeterminate [CircularProgressIndicator] has **no intrinsic size** — it
/// takes whatever its constraints allow.  Inside a `FittedBox` that means its
/// unconstrained intrinsic size is used, which is nothing, so the whole
/// indicator scaled down to a ~2 px dot.  An emulator screenshot of the connect
/// flow showed exactly that: a tiny blue square in the middle of the picture.
/// A loading indicator the user cannot see is not a loading indicator.
///
/// The `SizedBox` gives it a real size to be scaled *from*, so `scaleDown` now
/// has something to work with — and it still never enlarges, so portrait is
/// unchanged from the device-verified layout.
class _Placeholder extends StatelessWidget {
  /// Whether to show activity rather than the idle camera glyph.
  final bool busy;

  const _Placeholder({required this.busy});

  /// The indicator's boxed size, so it survives being scaled.
  static const double _spinnerSize = 44;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: previewPlaceholderKey,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: _spinnerSize,
                height: _spinnerSize,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            else
              Icon(Icons.photo_camera_outlined,
                  size: 56, color: Colors.white.withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final AppState app;
  final VoidCallback onToggleGrid;
  final bool gridOn;
  final VoidCallback onToggleHistogram;
  final bool histogramOn;

  /// Drop the gradient and the safe-area padding.
  ///
  /// Set when this no longer sits *over* the image but inside a band beside or
  /// above it: a gradient fading to transparent only makes sense against a
  /// picture, and inside a band it reads as a smudge.
  final bool bare;

  const _TopBar({
    required this.app,
    required this.onToggleGrid,
    required this.gridOn,
    required this.onToggleHistogram,
    this.histogramOn = false,
    this.bare = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final id = app.link.identity;
    final drawn = app.displayedFps;
    // `recentFps`, not `stats.fps`. `LiveViewStats.fps` is
    // `received / seconds-since-the-first-frame` — a **session average**. It
    // decays toward zero and never reaches it, so after a minute at 30 fps a
    // stream that stops dead still reads as ~20 fps: the one readout that could
    // answer "did the camera stop sending?" was structurally unable to answer it,
    // and stayed silent exactly when the user needed it. `recentFps` is measured
    // over the last couple of seconds, which is the question being asked.
    final received = app.stats.recentFps;
    final loss = app.stats.lossRatio;

    // Two different numbers, and the gap between them is the diagnosis:
    //   received ~30, drawn low   -> the UI cannot keep up (decode or rebuild)
    //   received low              -> the link is dropping frames
    // Showing only one of them would leave the cause ambiguous.
    final lagging = received > 5 && drawn < received * 0.6;

    // Stalled means **no datagram has arrived recently** — not "the session
    // average is low", which no real stall can produce.  Gated on frames
    // actually being consumed: a receiver that was never started, that was
    // deliberately stopped, or whose page is off screen has nothing to be late.
    // `framesLive` is that gate — `link.previewRunning` alone is a statement
    // about the camera, and while the album tab is open the camera is running
    // perfectly well with nobody watching.
    final stalled = app.framesLive && app.stats.isStalled;

    return Container(
      padding: bare
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 8, 12, 20),
      decoration: bare
          ? null
          : const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
      child: SafeArea(
        bottom: false,
        top: !bare,
        child: Row(
          mainAxisAlignment:
              bare ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            if (id != null)
              _Chip(text: id.regionMarker.isEmpty ? id.firmwareVersion.trim() : id.regionMarker),
            if (!bare) const Spacer(),
            if (app.link.previewRunning) ...[
              if (bare) const SizedBox(width: 6),
              _Chip(
                text: stalled
                    ? l.liveNoFrames
                    : l.liveDrawnOfReceivedFps(
                        drawn.toStringAsFixed(0),
                        received.toStringAsFixed(0)),
                // The first number is drawn frames; the second is received
                // frames. Keeping both visible prevents an idle sampling window
                // from being mistaken for a camera-side zero-rate stream — but
                // the stall verdict comes from the arrival clock, not from either
                // rate, so a healthy-but-slow link is not reported as dead.
                warn: stalled || lagging,
              ),
              if (loss > 0.02)
                _Chip(
                    text: l.liveLossPercent((loss * 100).toStringAsFixed(0)),
                    warn: loss > 0.2),
            ],
            IconButton(
              key: const ValueKey<String>('toggle-grid'),
              tooltip: l.liveCompositionGrid,
              onPressed: onToggleGrid,
              icon: Icon(gridOn ? Icons.grid_on : Icons.grid_off,
                  color: Colors.white70),
            ),
            // The histogram is opt-in because it costs an extra decode and a GPU
            // read-back per sample. A user who did not ask for it should not pay
            // for it with preview smoothness.
            //
            // The toggle is unconditional now. It used to appear only on the wide
            // build, which meant the histogram was unreachable in portrait — the
            // one orientation where the panel is widest and the readout easiest
            // to read. There is no cost to the button itself: the sampler is only
            // started when the user switches it on.
            IconButton(
              key: const ValueKey<String>('toggle-histogram'),
              tooltip: l.histogramTooltip,
              visualDensity: VisualDensity.compact,
              onPressed: onToggleHistogram,
              icon: Icon(
                histogramOn ? Icons.bar_chart : Icons.bar_chart_outlined,
                color: histogramOn ? Colors.lightBlueAccent : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final bool warn;
  const _Chip({required this.text, this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: warn ? Colors.red.withValues(alpha: 0.75) : Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 11.5, height: 1.3)),
    );
  }
}

class _ThirdsGrid extends StatelessWidget {
  const _ThirdsGrid();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GridPainter(), size: Size.infinite);
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.32)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), p);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// The tap-to-focus marker.
///
/// One state, at the point the user tapped.  It used to have two — a solid amber
/// box for "the camera named this point" and a thin outline for "the camera named
/// none" — which assumed the `RCDoFocus` reply carried a focus position.  It does
/// not: `Auto` answers a hard-coded `(360, 240)` for every request and `Manual`
/// echoes the request, so "the camera named this point" was a claim nothing
/// supported.  See the table at the top of `focus_mapper.dart`.
///
/// What the box says now is the one thing that is certainly true: a focus command
/// was sent to this point in the frame.
class _FocusMarker extends StatelessWidget {
  const _FocusMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('focus-marker'),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.amber, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// The state line, read out of the newest frame.
///
/// Every value here comes from the live-view JSON, so nothing is stale and
/// nothing needed an HTTP round trip.
///
/// ## One line, because that is what the band is sized for
///
/// `_topBandHeight` is **72**, documented as the icon row plus *"the one-line state
/// strip"*, and `_TopBand`'s wrapper is a plain `Container` with no clip. This `Text`
/// had no `maxLines`, so when the camera reported all seven values it wrapped — and
/// the `Column` above it painted the overflow **outside its box, over the live
/// preview**, as the yellow-and-black stripe.
///
/// Measured on 411x727 with a camera state injected (`test/live_view_text_scale_test`
/// now injects one; the older fixture never did, so this widget was not in the tree and
/// three checks asserted `takeException() == null` about a strip that did not exist).
/// The `Column`'s children summed against the 72 dp box it was given:
///
///     text scale   overflow, en     overflow, zh
///        1.0          44 px            28 px
///        1.3         106 px            85 px
///        1.5         196 px           148 px
///        2.0         427 px           459 px
///
/// ## Those are `flutter_test`'s font, and the device's font is a different one
///
/// The measurements above are ~4x the device's, and the reason is worth writing down
/// because it is a property of the **fixture**, not of `flutter_test` in general:
/// `MaterialApp` deliberately installs `fontFamily: 'monospace'` as its root
/// `DefaultTextStyle` ("consider putting your text in a `Material`"), the fixtures pump
/// `LiveViewPage` as `home:` with **no `Scaffold`**, and so the strip inherits that
/// family — read back off the `RenderParagraph`, `family=monospace`. In the app the page
/// is a `Scaffold`'s body (`lib/app.dart:1123`), where the theme's text style applies
/// and the family is `Roboto`.
///
/// Re-measured in Roboto — loaded from the copy the Flutter SDK ships
/// (`bin/cache/artifacts/material_fonts/roboto-regular.ttf`), with the page pumped the
/// way the app builds it (`Scaffold` body) so the family is really Roboto — the same
/// fixture overflows by:
///
///     text scale   overflow, en     overflow, zh
///        1.0          12 px             0 px
///        1.3          22 px            22 px
///        1.5          52 px            28 px
///        2.0         108 px            76 px
///
/// So the default text scale **was** broken on the device with this state (12 px of
/// yellow-and-black over the picture, in English), not only at accessibility sizes — and
/// the Chinese line did not overflow at 1.0 in this fixture. The zh column carries a
/// substitution caveat Roboto cannot fix: it has no CJK coverage, so those glyphs fall
/// back to the test font. Nothing here says what the maintainer's own phone shows, since
/// `adb shell settings get font_scale` was never run — but the defect no longer depends
/// on that answer.
///
/// The fix is the same answer this file already gives for the band: **nothing here may
/// grow past what the band was measured against.** The strip is a one-line summary; a
/// value that does not fit is elided rather than allowed to push the picture down or
/// paint over it. The cost is measured too: in Roboto at 1.0 the seven joined values need
/// **352.7 dp** and have **304**, so the ellipsis takes the last ~14% — and in the test
/// font, where the same line is 770.5 dp, it takes most of it.
class _StateStrip extends StatelessWidget {
  final CameraState state;

  /// Drop the gradient and the generous vertical padding.
  ///
  /// Set when the strip lives inside a band rather than over the picture. In a
  /// band the padding would only waste the little height there is, and the
  /// gradient has nothing to fade into.
  final bool bare;

  /// Tighten the type a little further, for a band that is thinner still.
  final bool dense;

  const _StateStrip({required this.state, this.bare = false, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    // The firmware's own words go through `paramLabel`: this strip is one joined
    // line, so there is no narrow variant to shorten them for, but the wire string is
    // still the code and the label is still what the user reads.
    final items = <String>[
      paramLabel(l, state.exposureMode),
      if (state.shutterSpeed.isNotEmpty) state.shutterSpeed,
      if (state.fNumber.isNotEmpty) l.readoutApertureValue(state.fNumber),
      if (state.isAutoIso)
        l.readoutIsoAutoValue(state.isoAutoValue)
      else
        l.readoutIsoValue(state.isoSetting),
      if (state.exposureCompensation.isNotEmpty && state.exposureCompensation != '0.0')
        l.readoutEvValue(state.exposureCompensation),
      paramLabel(l, state.whiteBalance),
      paramLabel(l, state.colorMode),
    ].where((s) => s.isNotEmpty).toList();

    return Container(
      key: const ValueKey<String>('state-strip'),
      padding: bare
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
          : const EdgeInsets.fromLTRB(12, 18, 12, 10),
      decoration: bare
          ? null
          : const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
      child: LayoutBuilder(builder: (context, strip) {
        // ## The one child that is not `Expanded`, and what keeps it honest
        //
        // The values line above yields — it is `Expanded`, it is capped at one line and it
        // elides. The battery fact beside it is **not** in an `Expanded`, because it should
        // take its own width rather than a share: a `Flexible` here would split the row
        // with the values (measured on Roboto at 1.0: 304 dp of values down to 297) and
        // waste the difference on a value that never needed it.
        //
        // What that leaves is one unbounded child, and a `Row` overflows when a single
        // inflexible child is wider than the row. Measured on a 320x568 body at text scale
        // 2.0 in Chinese — a surface `live_view_text_scale_test` sweeps — the battery line
        // alone asked for the whole 300 dp and threw
        // `A RenderFlex overflowed by 20 pixels on the right`. So it is capped, and the
        // cap is set where it cannot bind on any surface the tests sweep in the font the
        // device draws: in Roboto this line is **131.5 dp of the strip's 379** at scale 2.0
        // (35%) and 67 dp of them at 1.0 (18%), both under half. It only binds where the
        // battery text really is longer than half the strip, which is the case that used to
        // overflow.
        final cap =
            strip.maxWidth.isFinite ? strip.maxWidth * 0.5 : double.infinity;
        return Row(
          children: [
            Expanded(
              child: Text(
                items.join(dense ? '  ' : '   '),
                // The band's height is the contract; see this class's doc. `maxLines`
                // is what makes that contract true rather than hoped for, and it is the
                // difference between an elided value and a stripe across the picture.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: dense ? 11.5 : 12.5,
                  height: 1.4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: cap),
              child: Text(
                // The same fact the readout column draws, from the same getter — and the
                // long word rather than the column's short form, because this strip is the
                // page's full width and `analysis/55`'s 66 dp budget is the *column's*.
                state.isCharging
                    ? l.readoutBatteryChargingAndLeft(state.surplusPhotoCounts)
                    : l.readoutBatteryAndLeft(
                        state.batteryLevel, state.surplusPhotoCounts),
                // A second line here would be the same defect one widget along: the count
                // is bounded (a percentage and at most five digits) but it is drawn at the
                // reader's text scale, and the `Row` gives the values text whatever is
                // left — so this may not wrap either, and now it cannot overflow the row
                // by being wider than it.
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------

class _ShutterBar extends StatelessWidget {
  final AppState app;

  /// True when the window is wider than it is tall.
  ///
  /// Passed in rather than read from `MediaQuery` here so the widget stays a pure
  /// function of what it is given, and so a test can exercise both orientations
  /// without faking a media query.
  final bool wide;

  const _ShutterBar({required this.app, this.wide = false, this.maxHeight});

  /// How tall the bar may be, when the caller has a slot to put it in.
  ///
  /// ## Why the *status message* is what yields, and not the shutter
  ///
  /// `_ShutterBar` is a column of two things: the row of controls (68 dp) and — when the
  /// camera refuses a shot — the message explaining why. The message is long; measured,
  /// it takes the bar from 68 dp to **212.9 dp** in the blocked state.
  ///
  /// In a content-sized column that was survivable: the whole bar was scaled by
  /// `_BandFitted` and `analysis/60` records the shutter being painted at 0.188 in that
  /// state. In the **slotted** column it is not, because the slot is 77 dp and a 212.9 dp
  /// child inside it is scaled to **0.343** — the shutter at 23.3 dp, worse than before,
  /// and the position the pinning exists to fix would have been bought with an unusable
  /// button. `fullscreen_band_split_test.dart` caught exactly that, on the fixture whose
  /// capture is quarantined.
  ///
  /// So the bar is bounded when the caller has a slot: the controls keep their design size
  /// and the explanation **scrolls inside what is left**, which is the same decision
  /// `_SideColumn.pinLast` and `_BottomBand` already made in words — *"navigation is not
  /// optional and status text is, so the status text is what scrolls."* Here the thing
  /// that is not optional is the shutter.
  ///
  /// Null keeps the unbounded behaviour, which is what portrait and the normal landscape
  /// layout still use.
  final double? maxHeight;

  /// The shutter's tap target. Material's floor is 48dp; this is a camera's primary
  /// action and is set well above it.
  static const double _shutterSize = 68;

  /// The focus and preview buttons, which flank the shutter.
  static const double _sideControlSize = 56;
  static const double _sideControlIcon = 28;

  /// The row's design width: the controls plus even gaps. Made explicit so
  /// `_BandFitted` scales the row as a unit rather than letting one child overflow.
  /// Wide enough for the fourth (full-screen) control in landscape.
  ///
  /// ## Do not narrow this to make the row "fit" — it was tried and it is a trap
  ///
  /// It looks like free width: the four controls measure 236 dp, so the remaining
  /// 84 dp is gap, and cutting the row to 248 dp looks like 72 dp handed back to the
  /// band. It was tried during this round and **reverted**, because this `SizedBox`
  /// also sets the width the blocked-shutter message wraps in. Narrowing it made that
  /// sentence wrap to more lines, which made the whole control column taller than its
  /// band — and a column taller than its band is scrolled by `_SideColumn`'s
  /// `SingleChildScrollView` and scaled by the same `FittedBox` that shrank the
  /// shutter in the first place. Measured: the control column went from 293.1 dp
  /// (fits a 297 dp normal-landscape band) to 334.3 dp (does not), i.e. the fix made
  /// the blocked state worse than the defect it was fixing.
  ///
  /// `fullscreen_band_split_test.dart` now asserts that no side column exceeds its
  /// band, so this cannot be rediscovered quietly.
  static const double _shutterRowWidth = 320;

  /// The bar's horizontal padding.
  ///
  /// Named because the control row below is designed at exactly the width this
  /// leaves, and the two numbers drifting apart is what put every control in the
  /// bottom band at 0.925 instead of 1.0 — see the row's own comment.
  static const double _barPaddingX = 8;

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    // Resolved rather than read raw: the state layer owns the sentence and travels
    // with a code for it, so a locale this build ships strings for reads the camera's
    // explanation in its own language. `null` is preserved exactly — the busy gate
    // carries no code and falls back to the state layer's own English.
    final blocked = shutterBlockedText(l, app);
    final previewing = app.link.previewRunning;
    // Read every build: `startBurst`/`stopBurst` notify through `AppState`, so the fill and
    // the disabled state follow the held burst without the page tracking it separately.
    final bursting = app.burstActive;

    // The **whole** bar is given the row's design width, not just the row.
    //
    // ## The bug this fixes
    //
    // `_BandFitted` wraps this bar in a `FittedBox`, and a `FittedBox` measures its
    // child with **unbounded width**. The status message below the row was therefore
    // laid out as one unbroken line — "The camera is not in remote mode, so it will not
    // accept a shot. Start the preview — or press "Fix the shutter" below to do it." —
    // and the bar's natural width became that line, about 1490dp. The FittedBox then
    // scaled *everything*, shutter included, to fit 1490dp into the band.
    //
    // Measured scale of the 68dp shutter:
    //
    //     portrait, blocked     0.271   (drawn at 18.4dp)
    //     portrait, previewing  **0.925** (drawn at 62.9dp — see the row's comment;
    //                                      the "1.000" recorded here was the layout box,
    //                                      read with `getSize`, before the row's own
    //                                      `FittedBox`)
    //     landscape, blocked    0.188   (drawn at 12.8dp)
    //     landscape, previewing 0.809
    //
    // Reported from hardware as the interface "reverting to the old version" when the
    // shutter was touched: the controls were right until a message appeared beside them.
    // The two numbers above give it away — `403 / 0.271` and `280 / 0.188` are the same
    // ~1490dp, i.e. one unwrapped sentence.
    //
    // Constraining the bar to its design width makes the message wrap inside it, which
    // is what a status line is for.
    return SizedBox(
      width: _shutterRowWidth,
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.fromLTRB(_barPaddingX, 10, _barPaddingX, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          // The controls are a fixed-width row, so the row is given a definite
          // width and scaled as a unit. Left to itself in a narrow side band the
          // shutter would be the widget that overflowed, which is the one control
          // that must never be the thing that breaks. That width is now the one the
          // bar actually leaves it — see below.
          //
          // ## Sizes
          //
          // Reported from use: "in portrait the preview fills the width nicely, but
          // the elements in the top and bottom bars are small — especially the shutter
          // and the adjustment buttons". Measured before this change: the shutter's
          // design size was 56dp and `_BandFitted` rendered it at **15.2dp**, the focus
          // button at 13.0dp. 48dp is Material's *minimum* tap target; a camera's
          // primary action needs to be comfortably larger than the floor, and being
          // scaled to a quarter of it is not a fit-and-finish problem.
          //
          // The row is now `_shutterRowWidth - 2 * _barPaddingX` = 304dp wide with a
          // 68dp shutter, so the scale factor in
          // portrait is 1.0 (no scaling at all) and in a landscape side column it
          // degrades gracefully rather than to a speck.
          // ## The row is designed at the width the bar **gives** it
          //
          // It used to be `SizedBox(width: _shutterRowWidth)` wrapped in `_BandFitted`,
          // whose own 4 dp a side plus this container's 8 dp a side left the row
          // **296 dp** of design space — so the `FittedBox` inside scaled it to
          // **0.925** and every control in it was painted 7.5% smaller: the shutter at
          // **62.9 dp** against its 68 dp design, in the layout this comment used to
          // claim drew it at 1.0.
          //
          // That was invisible to every check, because `getSize` reports the box
          // *before* the `FittedBox` and 68 is exactly what it says;
          // `live_view_controls_size_test.dart` asserts the painted rect now, and the
          // portrait figure it read first was 62.9.
          //
          // The scaling is not removed here, it is left to the one place that has to do
          // it: the band's own `_BandFitted` scales the whole bar as a unit — that is
          // its job, and `analysis/54`'s defect was its absence — so a second scale
          // inside it only took a cut of the controls for nothing. This `FittedBox`
          // stays for the one layout that has no band around the bar (a window too short
          // for one, where the bar is a direct child of the page's column).
          FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: _shutterRowWidth - 2 * _barPaddingX,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    key: const ValueKey<String>('btn-focus-centre'),
                    tooltip: l.liveFocusAtCentre,
                    iconSize: _sideControlIcon,
                    constraints: const BoxConstraints.tightFor(
                        width: _sideControlSize, height: _sideControlSize),
                    onPressed: previewing ? () => app.focusAt(400, 300) : null,
                    icon:
                        const Icon(Icons.center_focus_strong, color: Colors.white),
                  ),

                  // The shutter.  Disabled while the interlock is recovering, a
                  // shot is in flight, or focus is still settling, and the reason
                  // is shown below rather than silently doing nothing — a button
                  // that looks pressed and has no effect is the worst possible
                  // outcome.
                  // Wrapped in a `Listener`, because `IconButton` has no pointer callbacks
                  // and the hold needs the raw down/up — a tap recogniser cannot express
                  // "still held".
                  //
                  // A tap in a bursting mode is a very short hold: down starts, up stops
                  // fifty milliseconds later. That is safe by construction rather than by a
                  // special case, and it is what makes this one control instead of two.
                  //
                  // ## Why the press and the release each tick, and differently
                  //
                  // The hold **is** the shutter here: down starts a burst and up stops it,
                  // and a burst nothing stops strands the camera until its battery is pulled
                  // (`analysis/59`). So the user needs two facts they cannot get by looking
                  // — the press registered, and the release went out — and they are
                  // opposite facts, so they are two different sensations
                  // (`ui/haptics.dart`, `shutterPress` / `shutterRelease`).
                  //
                  // The tick is on the **pointer**, not on `AppState.startBurst`, so the two
                  // halves stay symmetric: `stopBurst` is sent unconditionally and on every
                  // exit path, and the release tick is emitted on exactly the same paths
                  // (`onPointerUp` and `onPointerCancel`). A release the app decided not to
                  // send is not reachable from here, because in that state the whole listener
                  // is unwired — which is what the disabled-shutter check asserts.
                  Listener(
                    onPointerDown: blocked == null
                        ? (_) {
                            shutterPress();
                            app.startBurst();
                          }
                        : null,
                    onPointerUp: blocked == null
                        ? (_) {
                            shutterRelease();
                            app.stopBurst();
                          }
                        : null,
                    // `onPointerCancel` as well as up: a drag off the button, a second
                    // finger, the system stealing the pointer. A burst nothing ends runs
                    // until it strands the camera, so every exit has to send the stop —
                    // and every exit has to feel the same, or the one that does not tick
                    // reads as a release that did not register.
                    onPointerCancel: blocked == null
                        ? (_) {
                            shutterRelease();
                            app.stopBurst();
                          }
                        : null,
                    child: IconButton.filled(
                      key: const ValueKey<String>('btn-shutter'),
                      iconSize: 54,
                      constraints: const BoxConstraints.tightFor(
                          width: _shutterSize, height: _shutterSize),
                      // A no-op rather than null in a bursting mode, and that is a
                      // deliberate lie in the other direction: `onPressed: null` makes an
                      // `IconButton` **render as disabled** — grey — while the `Listener`
                      // above still receives every pointer event. The result is a shutter
                      // that looks broken and works, which is the same defect class as one
                      // that looks live and does nothing. Found by holding it on the real
                      // camera and reading `onPressed: (none)` off the widget tree while the
                      // burst ran.
                      //
                      // The behaviour is entirely in the `Listener`; this only decides how
                      // the button is drawn.
                      onPressed: blocked == null
                          ? (app.singleShotOnly ? () => app.shoot() : () {})
                          : null,
                      icon: (app.capturePending || bursting)
                          ? const SizedBox(
                              width: 34,
                              height: 34,
                              child: CircularProgressIndicator(
                                  strokeWidth: 3.5, color: Colors.black54),
                            )
                          : const Icon(Icons.circle),
                      style: IconButton.styleFrom(
                        // Red while the burst runs: the shutter is being held in camera
                        // terms, and the one thing the user needs to see is that it is
                        // still going.
                        backgroundColor: blocked != null
                            ? Colors.grey.shade700
                            : (bursting ? Colors.red.shade400 : Colors.white),
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: Colors.grey.shade800,
                        disabledForegroundColor: Colors.white38,
                      ),
                    ),
                  ),

                  IconButton(
                    key: const ValueKey<String>('btn-preview-toggle'),
                    tooltip: previewing ? l.liveStopPreviewTooltip : l.liveStartPreview,
                    iconSize: _sideControlIcon,
                    constraints: const BoxConstraints.tightFor(
                        width: _sideControlSize, height: _sideControlSize),
                    onPressed: app.link.isReady
                        ? () => previewing ? app.stopPreview() : app.startPreview()
                        : null,
                    icon: Icon(
                        previewing
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline,
                        color: Colors.white),
                  ),

                  // Full screen, for a wide window.
                  //
                  // In landscape the shell's app bar and tab strip take about 100dp of
                  // a 411dp-tall window — a quarter of the height, spent on chrome that
                  // does not help frame a shot. Turning them off gives that back to the
                  // status strip, the picture and the controls, which is what was asked
                  // for.
                  //
                  // It sits **in the shutter row** rather than on its own line. As a
                  // separate `TextButton` underneath it added ~36dp to a bar that
                  // already holds the shutter and the blocked-reason text, and at
                  // 800x600 that overflowed the page by 20px — caught by
                  // `focus_shutter_ui_test`. A spare place in a row that has room is the
                  // right home for a view mode anyway.
                  //
                  // Landscape only: in portrait the shell's bars are the navigation
                  // between Capture and Sync. The button stays on screen while the mode
                  // is on, so it is always escapable — full screen with no visible way
                  // out is a trap.
                  if (wide)
                    IconButton(
                      key: const ValueKey<String>('btn-fullscreen'),
                      tooltip:
                          app.fullScreen ? l.liveExitFullScreen : l.liveFullScreen,
                      iconSize: _sideControlIcon,
                      constraints: const BoxConstraints.tightFor(
                          width: _sideControlSize, height: _sideControlSize),
                      onPressed: () {
                        final next = !app.fullScreen;
                        app.fullScreen = next;
                        // Ask the platform too, so Android's own status and navigation
                        // bars go with the app's. `immersiveSticky` rather than
                        // `immersive`: a swipe reveals the bars temporarily instead of
                        // leaving a state the user has to hunt to undo.
                        SystemChrome.setEnabledSystemUIMode(
                          next
                              ? SystemUiMode.immersiveSticky
                              : SystemUiMode.edgeToEdge,
                        );
                      },
                      icon: Icon(
                          app.fullScreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          color: Colors.white),
                    ),
                ],
              ),
            ),
          ),

          // Drawn here in every layout **except** the slotted full-screen column, which
          // takes it through `blockedExplanation` and puts it in its own scrollable slot —
          // there is no room for a sentence inside a 77 dp bar. `maxHeight != null` is
          // exactly that case, so the two cannot both draw it.
          if (blocked != null && maxHeight == null)
            _blockedExplanation(context, blocked),
          ],
        ),
      ),
    );
  }

  /// The camera's explanation of a blocked shutter, as a widget the **page** can place.
  ///
  /// ## Why this is exposed at all, and where it goes
  ///
  /// In portrait and in the normal landscape layout it is a child of the bar, right under
  /// the controls — which is where it has always been, and what the `if (blocked != null)`
  /// above still does.
  ///
  /// In the **slotted** full-screen column it cannot stay there. That slot is
  /// `kMinShutterRowHeight` = 77 dp, the controls' row is 68 of them and the bar's own
  /// padding 16 — so a message inside the bar has **nothing** left. Measured on the
  /// quarantine fixture: `maxHeight` came to 69, the bar computed a room of -15, and the
  /// sentence was handed a zero-height box. **It was not drawn at all.** A blocked camera
  /// with a greyed-out shutter and no sentence saying why is the worst state this app has:
  /// that sentence is the only thing that says *"power-cycle the camera"*, and the escape
  /// button lives under it.
  ///
  /// So the page places it in the **below slot** instead — the one that is
  /// `fullScreenColumnSlots(...).below` = 85.2 dp tall and already a scroll view — and the
  /// shutter keeps every dp of its own slot. That is the division of labour `_BottomBand`
  /// uses in portrait, in that file's own words: the controls are fixed and the status text
  /// is what scrolls.
  ///
  /// The bar and the page cannot both draw it: the bar only draws it when `maxHeight` is
  /// null, and the page only asks for it in the slotted column, which is exactly the case
  /// where `maxHeight` is set.
  Widget? blockedExplanation(BuildContext context) {
    final blocked = shutterBlockedText(l10nOf(context), app);
    return blocked == null ? null : _blockedExplanation(context, blocked);
  }

  /// The message itself, at its own natural size.
  ///
  /// Never bounded from inside: the caller decides where it goes, which is the whole point
  /// of exposing it. A bound here is what produced the invisible message described above.
  Widget _blockedExplanation(BuildContext context, String blocked) {
    final l = l10nOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Column(
        children: [
          Text(
            blocked,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.orangeAccent, fontSize: 11.5, height: 1.35),
          ),
          // The interlock cannot tell a slow link from a wedged camera, and the user may
          // have power-cycled it in the meantime. A safety net with no way out is a dead
          // end, so the escape is always one tap away rather than hidden in a menu.
          //
          // Offered whenever a blocked shutter is something this app can act on — the link
          // is up and either the interlock or a stale in-flight reservation is holding it.
          // The old condition tied the escape to the one gate it could already clear by
          // itself, so in the case the user actually reported — a refusal or a timeout
          // recorded as a lost link, leaving the preview stopped — the button either was
          // absent or lifted a lock that was not the one holding the shutter, and pressing
          // it changed nothing on screen. `forceReleaseCapture` now clears every gate it
          // can and says so when it cannot.
          if (app.link.isReady && !app.capturePending)
            TextButton(
              key: const ValueKey<String>('btn-release-interlock'),
              // Disabled while the attempt is running, and showing that it is: the release
              // probes the camera, which against a wedged one runs to the probe's timeout,
              // and a button that looks identical before, during and after is
              // indistinguishable from a dead one.
              onPressed: app.releaseInFlight
                  ? null
                  : () async {
                      await app.forceReleaseCapture();
                      if (!context.mounted) return;
                      // Said out loud as well as written to the banner. The banner is easy
                      // to miss, and the whole complaint was that pressing this produced no
                      // visible change.
                      final reason = shutterBlockedText(l, app);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(reason == null
                            ? l.liveShutterReady
                            : l.liveStillBlocked(reason)),
                        duration: const Duration(seconds: 4),
                      ));
                    },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 2),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: app.releaseInFlight
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      app.captureQuarantined
                          ? l.liveReleaseAnyway
                          : l.liveFixShutter,
                      style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

/// The second level: a tab per use, a collapsible group per subject, and only
/// then the parameter controls.
///
/// ## Why it is arranged this way
///
/// The old surface was one flat list of every parameter, which put `RCImageAspect`
/// — a setting most users touch once — at the same depth as the shutter speed
/// they change between every frame. The cost was not scrolling: it was that the
/// list had to be *read* every time, because nothing in it said which entries
/// were the ones in play.
///
/// So the depth now encodes frequency of use:
///
/// * **level 1** — the two tabs, split by *when* the setting applies: while
///   shooting, or around the transfer that follows;
/// * **level 2** — collapsible groups, collapsed unless the user opens them;
/// * **inside** — the controls themselves.
///
/// The controls used while composing are in a group that cannot be collapsed at
/// all (`SettingsGroup.collapsible`), so "how do I change the ISO" never becomes
/// a two-tap question. Everything one level down is a setting the user decides
/// once and then leaves alone.
///
/// ## Why the tab state is not local
///
/// `ExpansionTile` keeps its own open/closed state, which is exactly right while
/// the page is alive and useless across a relaunch. Both it and the tab are
/// therefore read from and written back to `AppState.uiPrefs`. The group list is
/// rebuilt whenever the camera's state JSON changes — roughly 30 times a second —
/// so nothing here may hold that state in the widget itself.
///
/// ## Why this one *is* stateful
///
/// `TabBar` requires a real `TabController`: without one its `_handleTap` does
/// `_controller!.animateTo(index)` and throws on the first tap, in release as well
/// as in debug. Owning the controller here also keeps the tab indicator animating
/// through the 30 Hz rebuilds of the page above it, which is what a single tap on
/// a tab should look like. The *selection* still lives in `AppState`, so the
/// controller is a view of that value rather than a second copy of it.
class _SettingsPanel extends StatefulWidget {
  final AppState app;
  final CameraState? state;
  final String tab;
  final ValueChanged<String> onSelectTab;
  final ValueChanged<String> onToggleGroup;
  final VoidCallback onOpenVideo;
  final VoidCallback onOpenAlbum;
  final VoidCallback onClose;
  final VoidCallback onOpenBleLog;
  final VoidCallback onOpenWifiDiagnostics;

  /// Called when the user drags the header. `delta` is the vertical movement this
  /// frame; `start: true` marks the beginning of a gesture. Null when the panel's
  /// height is not the user's to change — in landscape it is a full-height column.
  final void Function(double delta, {bool start})? onResize;

  /// Fixed width when this is a sheet beside the frame in landscape. Null when it
  /// spans the bottom band in portrait, where the width is the screen's.
  final double? width;

  /// The parameter commands the exposure dials already cover, so this panel must not
  /// offer them a second time.
  ///
  /// ## Why the panel is filtered rather than the catalog
  ///
  /// The user's requirement A: *"these parameters the dials can adjust may be removed
  /// from Settings in landscape full-screen to avoid duplication"*. It is a filter here
  /// rather than an edit to `protocol/settings_menu.dart` because the menu is the
  /// **catalog** — `tool/verify_transport.dart` checks that every command the protocol
  /// can set has exactly one row in it, and a mode-dependent catalog would make that
  /// claim meaningless. What changes is what a given layout *shows*.
  ///
  /// Empty everywhere except landscape full screen with the dials on screen, so the
  /// portrait panel and the normal landscape panel are the catalog unchanged.
  final Set<String> dialedCommands;

  const _SettingsPanel({
    required this.app,
    required this.state,
    required this.tab,
    required this.onSelectTab,
    required this.onToggleGroup,
    required this.onOpenVideo,
    required this.onOpenAlbum,
    required this.onClose,
    required this.onOpenBleLog,
    required this.onOpenWifiDiagnostics,
    this.onResize,
    this.width,
    this.dialedCommands = const <String>{},
  });

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: kSettingsTabs.length,
      vsync: this,
      initialIndex: _indexOf(widget.tab),
    );
    _tabs.addListener(_onTabChanged);
  }

  @override
  void didUpdateWidget(_SettingsPanel old) {
    super.didUpdateWidget(old);
    // The saved tab is read asynchronously, so the panel can appear before it has
    // been restored and then be told the real value. Following it here keeps the
    // indicator honest without a second source of truth.
    if (widget.tab != old.tab && _tabs.index != _indexOf(widget.tab)) {
      _tabs.index = _indexOf(widget.tab);
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  static int _indexOf(String id) {
    final i = kSettingsTabs.indexWhere((t) => t.id == id);
    return i < 0 ? 0 : i;
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    final id = kSettingsTabs[_tabs.index].id;
    if (id != widget.tab) widget.onSelectTab(id);
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final tabs = kSettingsTabs;
    final shown =
        tabs.firstWhere((t) => t.id == widget.tab, orElse: () => tabs.first);

    return Container(
      // Keyed so its height can be measured: "the panel shows too few rows" is a
      // claim about a number, and without a key a test can only count the rows that
      // happen to be built rather than how much room the panel was given.
      key: const ValueKey<String>('live-settings-panel'),
      width: widget.width,
      decoration: const BoxDecoration(
        // Only meaningful as a sheet over the frame, and harmless otherwise: this
        // is what says the panel is in front of the picture rather than beside it.
        border: Border(left: BorderSide(color: Colors.white12)),
      ),
      // Bounded in both orientations. Portrait has far less room than landscape,
      // and the list scrolls rather than pushing the shutter off the screen.
      constraints: const BoxConstraints(maxHeight: 320, minHeight: 160),
      // The panel's background is a `Material`, not the `Container`'s own colour.
      //
      // ## Why, and what it was doing before
      //
      // `ListTile` — which `ExpansionTile` and every row below it is built from —
      // paints its background and its ink on the **nearest `Material` ancestor**, and
      // in debug it walks up looking for a `ColoredBox`/`DecoratedBox` in between and
      // reports a framework error for each one it finds: "ListTile background color or
      // ink splashes may be invisible". A `Container(color: ...)` between the rows and
      // the shell's `Material` is exactly that, so opening this sheet raised **six**
      // `FlutterError`s — one per row — and a widget test that checks
      // `takeException()` after opening it cannot pass. `AGENTS.md` §5.4's baseline is
      // "no reproducible `FlutterError`", so the colour moved onto a `Material` inside
      // the decoration: same pixels, no error, and the ink lands where it should.
      child: Material(
        color: const Color(0xFF121212),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _panelHeader(context),
          TabBar(
            controller: _tabs,
            // Compact: this is a menu over a live preview, and a 48dp tab strip
            // would take a third of the panel's height in portrait.
            labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            indicatorSize: TabBarIndicatorSize.tab,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            indicatorColor: Colors.lightBlueAccent,
            dividerColor: Colors.white12,
            labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 12.5),
            tabs: [
              for (final t in tabs)
                Tab(
                  height: 34,
                  iconMargin: EdgeInsets.zero,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_iconFor(t.icon), size: 15),
                      const SizedBox(width: 5),
                      // The catalog keeps its English and travels as ids:
                      // `lib/protocol/settings_menu.dart` is Flutter-free by contract, so
                      // the resolver — not the catalog — owns what the tab reads.
                      Text(settingsTabTitle(l, t)),
                    ],
                  ),
                ),
            ],
          ),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              // Any scroll dismisses the soft keyboard a dropdown may have opened,
              // which otherwise stays up over a panel this short.
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                if (widget.state == null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                    child: Text(
                      l.liveStartPreviewForSettings,
                      style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  )
                else
                  for (final g in shown.groups)
                    _SettingsGroupTile(
                      // The identity of the *group*, not of its position in this tab.
                      // Without it the two tabs' lists — different ids, different
                      // lengths — are matched positionally and one group inherits
                      // another's state; see `_SettingsGroupTile`'s class doc.
                      key: ValueKey<String>('settings-group-tile-${g.id}'),
                      group: g,
                      open: g.collapsible && app.isSettingsGroupOpen(g.id),
                      onToggle: () => widget.onToggleGroup(g.id),
                      onRow: (row) => _dispatch(context, row),
                      onSetParam: app.setParam,
                      toggleValue: _toggleValue,
                      state: widget.state!,
                      apertureChoices: lensApertures(widget.state!),
                      dialedCommands: widget.dialedCommands,
                      icon: _iconFor(g.icon),
                    ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  /// The current value of a client-side toggle.
  ///
  /// Read from `AppState` on every build rather than cached in the row: the
  /// album page changes the same underlying value, so a cached copy would show a
  /// switch in the position it was in when the panel was opened.
  bool _toggleValue(String rowKey) => switch (rowKey) {
        'pauseStreamDuringTransfer' => app.pauseStreamDuringTransfer,
        'keepScreenOn' => app.keepScreenOn,
        _ => false,
      };

  Widget _panelHeader(BuildContext context) {
    final l = l10nOf(context);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 0),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 16, color: Colors.white54),
          const SizedBox(width: 6),
          Expanded(
            child: Text(l.liveCameraSettings,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ),
          IconButton(
            key: const ValueKey<String>('btn-settings'),
              tooltip: l.liveHideSettings,
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, size: 18, color: Colors.white70),
          ),
        ],
      ),
    );

    // Draggable, because how many settings rows are worth seeing is a judgement the
    // user is better placed to make than a constant is. Dragging the header up grows
    // the panel at the preview's expense; dragging down gives the picture back.
    //
    // Only when the page offers a callback: in landscape the panel is a full-height
    // side column and has nothing to trade.
    if (widget.onResize == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        key: const ValueKey<String>('panel-drag-handle'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => widget.onResize!(0, start: true),
        onVerticalDragUpdate: (d) => widget.onResize!(d.delta.dy),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A grab affordance. Without one the header reads as a plain title and
            // nobody discovers the drag.
            Container(
              key: const ValueKey<String>('panel-drag-grip'),
              width: 34,
              height: 3,
              margin: const EdgeInsets.only(top: 5),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            row,
          ],
        ),
      ),
    );
  }

  /// Run a non-parameter row.
  ///
  /// Two of these duplicate a control that also exists elsewhere — the video page
  /// and the album's sync panel — and they deliberately *navigate* rather than
  /// re-implement. The video page is where the "these four commands were never
  /// verified on hardware" caution is stated, and a second copy of
  /// `RCVideoFormatSet` here would be a second entry point that never showed it.
  void _dispatch(BuildContext context, SettingsRow row) {
    final l = l10nOf(context);
    switch (row.key) {
      case 'nav.video':
        widget.onOpenVideo();
      case 'nav.album':
        widget.onOpenAlbum();
      case 'diag.ble':
        widget.onOpenBleLog();
      case 'diag.wifi':
        widget.onOpenWifiDiagnostics();
      case 'pauseStreamDuringTransfer':
        app.pauseStreamDuringTransfer = !app.pauseStreamDuringTransfer;
      case 'keepScreenOn':
        app.keepScreenOn = !app.keepScreenOn;
      // The language row. Without a case here it fell into `default:` and the panel
      // answered "nothing is wired to … yet" — a settings entry that does nothing is
      // the defect `analysis/41` §7.7 names, and on *this* row it would be worse than
      // usual: the control that changes the language would be the one control that
      // does not work.
      case 'locale':
        unawaited(showLocalePicker(
          context,
          current: app.localeTag,
          onChosen: (tag) => app.localeTag = tag,
        ));
      default:
        // A row with no handler is a wiring mistake, and a menu entry that does
        // nothing when tapped is the exact defect this surface exists to remove.
        // Routed through `AppState` rather than set here so it lands in the same
        // one-shot notice strip every other failure uses.
        //
        // The label is the *drawn* one, so the notice names the row the user
        // actually pressed rather than the catalog's English id.
        app.noteUnwiredRow(settingsRowLabel(l, row));
    }
  }
}

/// Maps a group's icon *name* to a real icon.
///
/// The catalog stores names because `protocol/settings_menu.dart` is imported by
/// `tool/verify_transport.dart`, which runs without a Flutter engine and cannot
/// load `IconData`. Keeping the lookup here means the catalog stays checkable
/// while the icons stay in the layer that renders them.
IconData _iconFor(String name) => switch (name) {
      'tune' => Icons.tune,
      'exposure' => Icons.exposure,
      'image' => Icons.image_outlined,
      'palette' => Icons.palette_outlined,
      'video' => Icons.videocam_outlined,
      'sync' => Icons.sync,
      'download' => Icons.download_outlined,
      'diagnostics' => Icons.wifi_tethering,
      'memory' => Icons.memory,
      _ => Icons.chevron_right,
    };

/// One collapsible group.
///
/// `ExpansionTile` is used rather than a hand-rolled equivalent because it already
/// has the header, chevron and reveal animation, and because its colours come from
/// the theme. It is **driven** by an `ExpansibleController` rather than only by
/// `initiallyExpanded`, for a reason that is not obvious from its API:
/// `initiallyExpanded` is only read when the tile's element is first created, so a
/// tile that is already built keeps whatever the user last did to it and ignores
/// the restored preference. The preference is this group's single source of truth,
/// so every rebuild pushes it into the tile.
///
/// ## Why the widget carries a key, and what happened without it
///
/// `_SettingsPanelState` builds one tab's groups as a plain list, and the two tabs have
/// different group ids and different counts (Capture four, Sync three). With no key on
/// this widget, Flutter matched them to the previous tab's elements **by position**, so
/// one group's `State` — and its `ExpansibleController` — was handed to a *different*
/// group. The `collapse()` that shake-out performed is a change on the controller, and
/// `ExpansionTile` reports every controller change through `onExpansionChanged`, which
/// here is `widget.onToggle()` — so **switching tabs wrote group preferences nobody
/// touched**. Measured: on Capture→Sync the tile that had been `image` collapsed as
/// `connection` and left `connection` open; on the way back `image` was built with the
/// state its *predecessor in that slot* had left behind, so it came back collapsed.
/// Giving the widget its group's identity makes each tile mount fresh and correct, which
/// is what removes the whole chain.
///
/// ## Why both `initState` and `initiallyExpanded` set the same thing
///
/// A fresh mount gets a fresh controller, and `ExpansibleController` starts collapsed.
/// `ExpansionTile` passes `initiallyExpanded` down and `Expansible` reads it, so the
/// first frame is right either way — that half is checked
/// (`settings_tab_switch_state_test.dart`, "a group remembered as open is open the moment
/// the panel is built"). Putting the controller into the same state in `initState` is
/// what keeps the two from disagreeing at all, and it is safe there because the
/// `ExpansionTile` that listens to the controller is a **child**: nothing is subscribed
/// yet, so no callback fires.
///
/// **What is measured and what is not** (so this docstring does not claim more than the
/// evidence): reverting the `key` above puts four of the five checks red; reverting the
/// `initState` block, or the guard on `onExpansionChanged`, leaves all five green. The
/// root cause is the identity, not the timing — the other two are what stop this widget
/// from *reporting a reconciliation as a user decision*, which is the class the key fixed
/// one instance of.
class _SettingsGroupTile extends StatefulWidget {
  final SettingsGroup group;
  final bool open;
  final VoidCallback onToggle;
  final void Function(SettingsRow row) onRow;
  final void Function(String command, String value) onSetParam;
  final bool Function(String rowKey) toggleValue;
  final CameraState state;
  final List<String> apertureChoices;

  /// Parameter commands the exposure dials already cover. Those rows are **not
  /// built**, so the panel cannot offer a setting that is on a dial a few centimetres
  /// away. Empty outside landscape full screen — see `_SettingsPanel.dialedCommands`.
  final Set<String> dialedCommands;

  final IconData icon;

  const _SettingsGroupTile({
    super.key,
    required this.group,
    required this.open,
    required this.onToggle,
    required this.onRow,
    required this.onSetParam,
    required this.toggleValue,
    required this.state,
    required this.apertureChoices,
    required this.icon,
    this.dialedCommands = const <String>{},
  });

  @override
  State<_SettingsGroupTile> createState() => _SettingsGroupTileState();
}

class _SettingsGroupTileState extends State<_SettingsGroupTile> {
  final ExpansibleController _tile = ExpansibleController();

  @override
  void initState() {
    super.initState();
    // Put the controller into the remembered state **before the tile is built**, so the
    // frame it is first laid out in is already the right one and the widget never has to
    // be reconciled after the fact. See the class doc: the first frame is really carried
    // by `initiallyExpanded`, and this is what keeps the two from disagreeing. Safe here
    // because the `ExpansionTile` that listens to this controller is a **child** —
    // nothing is subscribed yet, so no callback fires.
    if (widget.open) {
      _tile.expand();
    } else {
      _tile.collapse();
    }
  }

  @override
  void didUpdateWidget(_SettingsGroupTile old) {
    super.didUpdateWidget(old);
    // The widget is the source of truth, so the controller follows it — but only when it
    // is not already where it should be. `didUpdateWidget` runs on every frame the
    // camera's state JSON changes (about thirty times a second), and every controller
    // change is reported as an expansion, so asking a tile that is already correct would
    // both restart its animation and look like a tap.
    if (widget.open == _tile.isExpanded) return;
    if (widget.open) {
      _tile.expand();
    } else {
      _tile.collapse();
    }
  }

  /// The rows this group draws.
  ///
  /// Filtered, not disabled: a row that is on a dial is *absent* here rather than
  /// present-and-greyed, which is the difference between "removed to avoid duplication"
  /// (what was asked for) and "appears twice but one copy is dead".
  Iterable<Widget> get _rows => [
        for (final r in widget.group.rows)
          if (!widget.dialedCommands.contains(r.key))
            _MenuRow(
              row: r,
              state: widget.state,
              apertureChoices: widget.apertureChoices,
              onTap: () => widget.onRow(r),
              onParam: (v) => widget.onSetParam(r.key, v),
              toggleValue: widget.toggleValue,
            ),
      ];

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final group = widget.group;
    // A group with no state of its own: the controls used while shooting are
    // always on screen, so there is no tap between the user and the ISO.
    if (!group.collapsible) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GroupHeader(
            title: settingsGroupTitle(l, group),
            icon: widget.icon,
            summary: settingsGroupSummary(l, group),
          ),
          ..._rows,
        ],
      );
    }

    return ExpansionTile(
      // Keyed by id so the tile's own state survives the page's rebuilds without
      // being reset by the reordering of anything else in the list.
      key: PageStorageKey<String>('settings-group-${group.id}'),
      controller: _tile,
      // What makes the **first** frame of a freshly mounted tile correct: `ExpansionTile`
      // passes this to `Expansible`, which reads it in its own `initState`.
      initiallyExpanded: widget.open,
      // Only a change that leaves the tile out of step with the preference is a user
      // toggle. A programmatic `expand()`/`collapse()` arrives here too, and calling
      // `onToggle()` for one would flip the preference that asked for the change — which
      // is exactly how the tab-switch defect corrupted it. Kept as the guard against that
      // class of mistake, not as a fix for a case that is still reachable.
      onExpansionChanged: (open) {
        if (open == widget.open) return;
        widget.onToggle();
      },
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: EdgeInsets.zero,
      expansionAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 140),
        reverseDuration: Duration(milliseconds: 110),
      ),
      title: _GroupHeader(
        title: settingsGroupTitle(l, group),
        icon: widget.icon,
        summary: settingsGroupSummary(l, group),
        open: widget.open,
      ),
      children: _rows.toList(),
    );
  }
}

/// The two-line label on a group: what is inside, and — when collapsed — a
/// reminder, so a closed group is not a title the user has to remember.
class _GroupHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? summary;

  /// Null for the always-visible group, which has no open/closed state.
  final bool? open;

  const _GroupHeader({
    required this.title,
    required this.icon,
    this.summary,
    this.open,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: open == false ? Colors.white38 : Colors.white70),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, height: 1.3)),
              if (summary != null && open != true)
                Text(summary!,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10.5, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }
}

/// One control in the second level.
///
/// Three row shapes rather than one, because the three send different things: a
/// parameter goes to the camera, a toggle changes a client-side preference, and
/// an action opens another surface. Collapsing them into one row type is how a
/// toggle ends up being sent to the camera as a command it has never heard of.
class _MenuRow extends StatelessWidget {
  final SettingsRow row;
  final CameraState state;
  final List<String> apertureChoices;

  /// Send one camera parameter. Takes the value, not just the tap.
  final ValueChanged<String> onParam;

  /// Open a surface, or flip a client-side preference.
  final VoidCallback onTap;

  /// Read a client-side preference's current value.
  final bool Function(String rowKey) toggleValue;

  const _MenuRow({
    required this.row,
    required this.state,
    required this.apertureChoices,
    required this.onParam,
    required this.onTap,
    required this.toggleValue,
  });

  /// The `ValueKey` for this row, as `setting-<key>`.
  ///
  /// ## Why every row needs one now
  ///
  /// `AGENTS.md` §5: a control without a key can only be found by its text or its
  /// coordinates, and both drift. These rows were reachable only by label, which made
  /// "the panel no longer offers the parameters the dials cover" a check about
  /// *strings* — and a string can be reworded, or matched by a row in another group.
  /// With a key it is `find.byKey('setting-RCISOSet')`, which is the claim itself.
  ///
  /// Keyed by the row's own `key` (the `RC…` command for a parameter, the id for an
  /// action or a toggle) rather than by position, so reordering the catalog or hiding a
  /// row cannot silently repoint a check at a different control.
  String get valueKey => 'setting-${row.key}';

  @override
  Widget build(BuildContext context) => switch (row.type) {
        SettingsRowType.param => _param(context),
        SettingsRowType.toggle => _toggle(context),
        SettingsRowType.action => _action(context),
      };

  Widget _action(BuildContext context) {
    final l = l10nOf(context);
    final note = settingsRowNote(l, row);
    return ListTile(
      key: ValueKey<String>(valueKey),
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(settingsRowLabel(l, row),
          style: const TextStyle(color: Colors.white70, fontSize: 13)),
      subtitle: note == null
          ? null
          : Text(note,
              style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
      onTap: onTap,
    );
  }

  Widget _toggle(BuildContext context) {
    final l = l10nOf(context);
    final on = toggleValue(row.key);
    final note = settingsRowNote(l, row);
    return SwitchListTile(
      key: ValueKey<String>(valueKey),
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      value: on,
      onChanged: (_) => onTap(),
      title: Text(settingsRowLabel(l, row),
          style: const TextStyle(color: Colors.white70, fontSize: 13)),
      subtitle: note == null
          ? null
          : Text(note,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 10.5, height: 1.35)),
    );
  }

  /// A parameter row: grey does not mean hidden.
  ///
  /// The control is still built while it is ineffective, because its *value* is
  /// the camera's answer and the user needs to read it — "the camera chose
  /// 1/125" is information. Only the edit is refused, and a line says which
  /// exposure mode is overriding it, so the row explains itself instead of
  /// looking broken. This is the UI half of `AppState.isParamEffective`.
  Widget _param(BuildContext context) {
    final l = l10nOf(context);
    final command = row.key;
    final current = _currentValueOf(command);
    // The pool is looked up through the catalog's own command->pool table, not by
    // the wire key: `RCMeteringModeSet` sets `MeteringMode`, whose pool is
    // `meteringMode`, so a lookup by key finds nothing and the dropdown silently
    // renders empty. The aperture is the one pool the lens narrows.
    final options = command == 'RCFNSet'
        ? apertureChoices
        : (kRcValuePools[kSettingsRowPools[command]] ?? const <String>[]);

    // The camera reports values in its own spelling; if a value is not in the
    // list it is still shown, so the UI never claims a setting the camera is not
    // actually in.
    final has = options.contains(current);

    final mode = state.exposureMode;
    final effective = mode.isEmpty || AppState.isParamEffective(mode, command);

    return ListTile(
      key: ValueKey<String>(valueKey),
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(
        settingsRowLabel(l, row),
        style: TextStyle(
          color: effective ? Colors.white70 : Colors.white24,
          fontSize: 13,
        ),
      ),
      subtitle: effective
          ? null
          : Text(
              l.settingsSetByCamera(mode),
              style: const TextStyle(color: Colors.white24, fontSize: 10.5),
            ),
      // The dropdown is given a definite width and clipped. Left to itself it
      // sizes to its **widest menu item** — the Kelvin ladder and `RAWJ-L` are
      // both far wider than the panel a phone can afford — and would then be
      // clipped by the row instead, with the selected value off screen. The menu
      // itself is not constrained: it only has to fit the screen.
      trailing: SizedBox(
        width: 132,
        child: ClipRect(
          child: DropdownButton<String>(
            isExpanded: true,
            value: has ? current : null,
            // The *display* of the current value, and the menu's items, go through
            // `paramLabel`; `value:` above keeps the wire string, because that is
            // what `onParam` hands to the camera. Nothing here can put a label into
            // a request.
            hint: Text(current.isEmpty ? '—' : paramLabel(l, current),
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(color: effective ? Colors.white : Colors.white38)),
            dropdownColor: const Color(0xFF1E1E1E),
            underline: const SizedBox.shrink(),
            style: TextStyle(
                color: effective ? Colors.white : Colors.white38, fontSize: 13),
            // A disabled dropdown must not accept taps at all, rather than
            // accepting one and then explaining that it was ignored.
            onChanged:
                effective ? (v) { if (v != null) onParam(v); } : null,
            items: [
              // Wrapped, not translated in place: these strings are sent to the
              // camera verbatim, so the wire value stays the item's `value` and only
              // its child is the label.
              if (!has && current.isNotEmpty)
                DropdownMenuItem(
                    value: current, child: Text(paramLabel(l, current))),
              ...options.map((o) =>
                  DropdownMenuItem(value: o, child: Text(paramLabel(l, o)))),
            ],
          ),
        ),
      ),
    );
  }

  /// The camera's current value for a parameter command.
  ///
  /// Keyed by command rather than by row label so a label can be reworded
  /// without silently detaching the control from the state behind it.
  String _currentValueOf(String command) => switch (command) {
        'RCSwitchDialMode' => state.exposureMode,
        'RCISOSet' => state.isoSetting,
        'RCFNSet' => state.fNumber,
        'RCShutterSpeedSet' => state.shutterSpeed,
        'RCEVSet' => state.exposureCompensation,
        'RCWBSet' => state.whiteBalance,
        'RCMeteringModeSet' => state.meteringMode,
        'RCFocusModeSet' => state.focusMode,
        'RCDriveModeSet' => state.driveMode,
        'RCImageAspect' => state.imageAspect,
        'RCFileFormatSet' => state.fileFormat,
        'RCImageQualitySet' => state.imageQuality,
        'RCChooseColorMode' => state.colorMode,
        _ => '',
      };
}

// ---------------------------------------------------------------------------

class _ConnectBar extends StatelessWidget {
  final AppState app;
  const _ConnectBar({required this.app});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final busy = app.link.isBusy;
    final failed = app.link.stage == LinkStage.failed;

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The transport owns the sentence; this is the single place it is drawn
            // (the preview placeholder deliberately says nothing — two copies of one
            // status read as two statuses).
            Text(linkStatusText(l, app.link),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: failed ? Colors.redAccent : Colors.white70,
                    height: 1.4)),
            const SizedBox(height: 12),
            // A `Wrap`, not a `Row`, and the label is bounded rather than
            // intrinsic. This bar is the **first screen of the app** — it is what
            // is drawn on every launch, before any camera exists — and the `Row`
            // it used to be laid the three controls out at their own widths and
            // clipped whatever did not fit. Measured on a 411 dp body, which is
            // the maintainer's phone:
            //
            // ```
            // A RenderFlex overflowed by 31 pixels on the right.
            // Row  size=Size(379.0, 48.0)  constraints=BoxConstraints(0.0<=w<=379.0, …)
            //   ← … ← _ConnectBar ← Column ← LiveViewPage
            // ```
            //
            // 379 dp is what the bar has after its own 16 dp side padding; the
            // connect button alone wanted 305.7 and the two 48 dp icon buttons
            // took the rest. The label was the unbounded term, so nothing about
            // the bar was bounded: the same button measures 305.7 dp at the default
            // text scale, 369.9 at 1.3, 412.7 at 1.5 and 519.7 at 2.0, against the
            // 288 dp of room a 320 dp body leaves. There was no width to tune to.
            //
            // Wrapping is the shape that degrades instead of clipping: when the
            // three controls do not fit one line the icon buttons move to the
            // next, which keeps all three reachable at any width and any text
            // scale. `_ConnectBar`'s own check
            // (`test/connect_bar_overflow_test.dart`) sweeps 320…914 dp, both
            // orientations, 1.0/1.3/1.5/2.0 and both shipped languages, and
            // asserts each control is inside the bar and still at least a 48 dp
            // tap target — a control squeezed to nothing would otherwise satisfy
            // "it did not overflow".
            //
            // `LayoutBuilder` + `ConstrainedBox` is what bounds the label. A
            // `Flexible` here would not compile the layout: it applies
            // `FlexParentData`, and `Wrap` is not a `Flex`, which throws
            // "Incorrect use of ParentDataWidget" rather than laying out. The
            // button's own `Row` gives the label flexible width, so a label that
            // no longer fits its share **wraps inside the button** (two lines at
            // 1.3, as `maxLines` allows) instead of being truncated to an
            // ellipsis the user cannot read.
            LayoutBuilder(
              builder: (context, bar) => SizedBox(
                // The bar is black to the screen's edges, and this is what keeps it
                // so: a `Wrap` sizes to its **longest run**, so without a definite
                // width the black band would shrink to the controls and the page
                // would show through beside them — a second, unasked-for change.
                // Measured: 266.4 dp of black centred in a 411 dp screen.
                width: bar.maxWidth,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: bar.maxWidth),
                      child: FilledButton.icon(
                        key: const ValueKey<String>('btn-connect'),
                        onPressed: busy ? null : () => app.connect(),
                        icon: const Icon(Icons.bluetooth_searching),
                        label: Text(
                          failed ? l.liveConnectRetry : l.liveConnectToCamera,
                          // The words are the localization round's; this only
                          // decides where they may break.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    // The BLE log is the only place the camera's real
                    // characteristic properties appear, so it must be reachable
                    // without a debugger.
                    IconButton(
                      key: const ValueKey<String>('btn-ble-diagnostics'),
                      tooltip: l.liveBleDiagnostics,
                      onPressed: () => _showBleLog(context, app),
                      icon: const Icon(Icons.terminal, color: Colors.white54),
                    ),
                    // The Wi-Fi sheet is the only place the app states what the
                    // platform actually reported about permissions, and the only
                    // place the SSID and passkey are shown together.  Both are
                    // needed for the manual fallback, and neither exists anywhere
                    // else in the UI — a screenshot of this sheet is enough to
                    // diagnose a refused join without a logcat.
                    IconButton(
                      key: const ValueKey<String>('btn-wifi-diagnostics'),
                      tooltip: l.liveWifiDiagnostics,
                      onPressed: () => _showWifiDiagnostics(context, app),
                      icon: const Icon(Icons.wifi_tethering,
                          color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),

            // Dismissing Android's join prompt is a normal thing to do, so offer
            // the prompt back rather than making the user start over.  Without
            // this the only way to retry is a full reconnect, which re-pairs over
            // BLE for no reason.
            if (app.link.stage == LinkStage.waitingForWifi) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  final r = await app.connection.retryWifiJoin();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    // `r.explanation` is built from what the platform actually
                    // said plus the app's own measurement of its permissions.
                    // The previous text named a permission unconditionally, and
                    // sent the user to grant one they already held — twice.
                    content: Text(switch (r.outcome) {
                      WifiJoinOutcome.granted => l.joinOutcomeGranted,
                      WifiJoinOutcome.suggested => l.joinOutcomeSaved,
                      WifiJoinOutcome.dismissed => l.joinOutcomeDismissed,
                      WifiJoinOutcome.timeout => l.joinOutcomeTimeout,
                      WifiJoinOutcome.permissionDenied ||
                      WifiJoinOutcome.unsupported ||
                      WifiJoinOutcome.failed =>
                        r.explanation,
                    }),
                    duration: const Duration(seconds: 8),
                    action: r.isUserFixable
                        ? SnackBarAction(
                            label: l.liveRetryJoinLabel,
                            onPressed: () => app.connection.openPermissionSettings(),
                          )
                        : null,
                  ));
                },
                icon: const Icon(Icons.wifi_find, size: 18),
                label: Text(l.liveRetryJoin),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Show the BLE log.
///
/// A top-level function rather than a method of the connect bar, because it now
/// has two entry points — the connect bar, which is only on screen before the
/// link is up, and the settings menu's diagnostics group, which is reachable
/// while connected. That matters: a BLE failure is nearly always environmental,
/// and a user whose *second* connection attempt fails has no connect bar left to
/// open the log from.
void _showBleLog(BuildContext context, AppState app) {
  final l = l10nOf(context);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF141414),
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.liveBleDiagnostics,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            l.liveBleDiagnosticsBody,
            style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (app.bleLog.isEmpty)
            Text(l.liveNothingLoggedYet,
                style: const TextStyle(color: Colors.white38))
          else
            ...app.bleLog.map((l) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SelectableText(
                    l,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        height: 1.4),
                  ),
                )),
        ],
      ),
    ),
  );
}

/// Show what the app knows about joining the camera's Wi-Fi.
///
/// Three things live here and nowhere else, and all three are needed to get a
/// connection working by hand when the platform refuses to do it automatically:
/// the **SSID and passkey** (the camera does not display the passkey, so the app
/// is the only source), the **measured permission state**, and direct access to
/// the permission screen and the system Wi-Fi panel.
///
/// Top-level for the same reason as [_showBleLog]: the connect bar that used to
/// own it is only present before the link comes up, and the questions this sheet
/// answers ("which permission is actually missing?", "what is the passkey?")
/// arrive just as often while connected.
void _showWifiDiagnostics(BuildContext context, AppState app) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF141414),
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, controller) => _WifiDiagnosticsSheet(
        app: app,
        scrollController: controller,
      ),
    ),
  );
}

/// The Wi-Fi diagnostics sheet, with its own state so it can re-read the
/// platform report without rebuilding the whole live-view page.
class _WifiDiagnosticsSheet extends StatefulWidget {
  final AppState app;
  final ScrollController scrollController;

  const _WifiDiagnosticsSheet({
    required this.app,
    required this.scrollController,
  });

  @override
  State<_WifiDiagnosticsSheet> createState() => _WifiDiagnosticsSheetState();
}

class _WifiDiagnosticsSheetState extends State<_WifiDiagnosticsSheet> {
  WifiPermissionReport? _report;
  String? _busy;
  String? _note;

  @override
  void initState() {
    super.initState();
    // Seed with the measurement attached to the last join attempt, so the sheet
    // shows something immediately even before the fresh read lands.
    _report = widget.app.connection.lastPermissions;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final r = await widget.app.readPermissionReport();
    if (!mounted) return;
    setState(() => _report = r);
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final app = widget.app;
    final ssid = app.connection.knownSsid;
    final passkey = app.connection.knownPasskey;
    final report = _report;

    return ListView(
      key: const ValueKey<String>('wifi-diagnostics-sheet'),
      controller: widget.scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        Text(l.liveWifiDiagnostics,
            style: const TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          l.liveWifiDiagnosticsBody,
          style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 14),

        // ---------------------------------------------------------- credentials
        _diagHeader(l.liveCameraAccessPoint),
        if (ssid == null)
          Text(
            l.liveAccessPointUnknown,
            style: const TextStyle(color: Colors.white38, fontSize: 12.5, height: 1.4),
          )
        else ...[
          _diagRow(l.liveSsid, ssid),
          _diagRow(l.livePasskey, passkey ?? l.liveNotReadYet, emphasise: true),
        ],
        const SizedBox(height: 6),
        Row(children: [
          TextButton.icon(
            onPressed: _busy != null
                ? null
                : () async {
                    setState(() => _busy = 'panel');
                    final usedPanel = await app.openWifiPanel();
                    if (!mounted) return;
                    setState(() {
                      _busy = null;
                      _note = usedPanel
                          ? l.liveOpenedWifiPanel
                          : l.liveOpenedWifiSettings;
                    });
                  },
            icon: const Icon(Icons.wifi, size: 18),
            label: Text(l.liveOpenWifi),
          ),
          TextButton.icon(
            onPressed: _busy != null
                ? null
                : () async {
                    setState(() => _busy = 'perms');
                    await app.openPermissionSettings();
                    if (mounted) setState(() => _busy = null);
                  },
            icon: const Icon(Icons.shield_outlined, size: 18),
            label: Text(l.liveAppPermissions),
          ),
        ]),

        const SizedBox(height: 14),
        // ------------------------------------------------------------ measured
        _diagHeader(l.liveMeasuredState),
        if (report == null || report.sdkInt == null)
          Text(l.liveAndroidOnly,
              style: const TextStyle(color: Colors.white38, fontSize: 12.5))
        else ...[
          _diagRow(l.diagAndroid, '${report.android ?? "?"} (API ${report.sdkInt})'),
          _diagRow(l.diagTargetSdk, '${report.targetSdk ?? "?"}'),
          _diagRow(l.diagDevice, report.manufacturer ?? '?'),
          const Divider(height: 20, color: Colors.white12),
          _diagTri(l.diagLocationPermission, report.fineLocation),
          _diagTri(l.diagNearbyWifiPermission, report.nearbyWifiDevices),
          _diagTri(l.diagChangeWifiPermission, report.changeWifiState),
          // Not a Wi-Fi permission, but the join genuinely needs it: this is a
          // *normal* permission, so its absence is a build bug the user cannot fix
          // — which is exactly why it belongs here, where a screenshot says so
          // without a logcat.
          _diagTri(l.diagChangeNetworkPermission, report.changeNetworkState),
          _diagTri(l.diagLocationServices, report.locationServices),
          _diagTri(l.diagWifiRadio, report.wifiEnabled),
          // The suggestion rung asks for approval through a notification, so a
          // missing grant leaves it silent rather than failing loudly.
          _diagTri(l.diagNotifications, report.notifications),
          if (report.addNetworkResult != null)
            _diagRow(l.diagAddNetworkSheet, report.addNetworkResult!),
        ],

        // ------------------------------------------------------------- verdict
        if (report?.locationServicesBlocking == true) ...[
          const SizedBox(height: 12),
          _diagWarning(l.liveLocationServicesOffNote),
        ] else if (report != null && report.sdkInt != null && report.problems.isNotEmpty) ...[
          const SizedBox(height: 12),
          _diagWarning(report.problems),
        ],

        if (_note != null) ...[
          const SizedBox(height: 10),
          Text(_note!,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        ],

        const SizedBox(height: 14),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _busy != null ? null : _refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(l.liveReRead),
          ),
          const SizedBox(width: 8),
          if (app.link.stage == LinkStage.waitingForWifi)
            OutlinedButton.icon(
              onPressed: _busy != null
                  ? null
                  : () async {
                      setState(() => _busy = 'join');
                      final r = await app.connection.retryWifiJoin();
                      if (!mounted) return;
                      setState(() {
                        _busy = null;
                        _report = r.permissions.sdkInt == null
                            ? _report
                            : r.permissions;
                        _note = r.explanation;
                      });
                    },
              icon: const Icon(Icons.wifi_find, size: 18),
              label: Text(l.liveRetryJoin),
            ),
        ]),
      ],
    );
  }

  Widget _diagHeader(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600)),
      );

  Widget _diagRow(String label, String value, {bool emphasise = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
          ),
          Expanded(
            // Selectable: the passkey has to be copyable, because typing eight
            // digits into the system Wi-Fi dialog from a screenshot is the exact
            // friction this app exists to remove.
            child: SelectableText(
              value,
              style: TextStyle(
                color: emphasise ? Colors.lightGreenAccent : Colors.white,
                fontSize: emphasise ? 15 : 12.5,
                fontFamily: emphasise ? 'monospace' : null,
                fontWeight: emphasise ? FontWeight.w600 : null,
                letterSpacing: emphasise ? 1.5 : null,
              ),
            ),
          ),
        ]),
      );

  /// A three-state row. `null` is rendered as its own answer, not as "denied" —
  /// a permission that could not be read is not a permission that was refused.
  Widget _diagTri(String label, bool? value) {
    final l = l10nOf(context);
    final (text, colour, icon) = switch (value) {
      true => (l.diagGranted, Colors.lightGreenAccent, Icons.check_circle_outline),
      false => (l.diagNotGranted, Colors.redAccent, Icons.cancel_outlined),
      null => (l.diagUnknown, Colors.white38, Icons.help_outline),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(
          width: 150,
          child: Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
        ),
        Icon(icon, size: 15, color: colour),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(color: colour, fontSize: 12.5)),
      ]),
    );
  }

  Widget _diagWarning(String text) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.orange, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: Colors.orange, fontSize: 12.5, height: 1.4)),
          ),
        ]),
      );
}

class _BottomNav extends StatelessWidget {
  final bool settingsOpen;
  final VoidCallback onToggleSettings;
  final VoidCallback onOpenAlbum;
  final VoidCallback onOpenVideo;
  final AppState app;
  const _BottomNav(
      {required this.settingsOpen,
      required this.onToggleSettings,
      required this.onOpenAlbum,
      required this.onOpenVideo,
      required this.app});
  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return Container(
      key: bottomNavKey,
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              key: const ValueKey<String>('btn-settings-toggle'),
              onPressed: onToggleSettings,
              icon: Icon(settingsOpen ? Icons.expand_more : Icons.tune,
                  color: Colors.white70, size: 20),
              label: Text(
                  settingsOpen ? l.liveHideSettings : l.liveSettings,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
            TextButton.icon(
              onPressed: onOpenVideo,
              icon: const Icon(Icons.videocam_outlined,
                  color: Colors.white70, size: 20),
              label: Text(l.liveVideoTab,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
            TextButton.icon(
              onPressed: onOpenAlbum,
              icon: const Icon(Icons.photo_library_outlined,
                  color: Colors.white70, size: 20),
              label: Text(l.liveAlbumTab,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The histogram panel, sized for whichever band it lives in.
///
/// It listens to the sampler directly rather than being rebuilt by the page: the
/// sampler ticks at a few hertz on its own schedule, and routing that through the
/// page's state would rebuild the preview chrome for a number that changes
/// independently of it.
///
/// Keyed because which **column** it is drawn in became a fact worth checking: since
/// `analysis/60` it lives below the shutter in the control column in full screen (the
/// user's requirement B) and in the readout column everywhere else, and "the histogram
/// is still in the left column" is not something a text or type finder can tell you.
class _HistogramPanel extends StatelessWidget {
  final HistogramSampler sampler;
  const _HistogramPanel({required this.sampler});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey<String>('histogram-panel'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: ValueListenableBuilder<LumaHistogram>(
        valueListenable: sampler.value,
        builder: (context, h, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 132,
              child: HistogramView(histogram: h, height: 38),
            ),
            const SizedBox(height: 1),
            ValueListenableBuilder<String?>(
              valueListenable: sampler.error,
              builder: (context, err, _) => err == null
                  ? HistogramReadout(histogram: h)
                  : Text(l10nOf(context).histogramUnavailable,
                      style: const TextStyle(color: Colors.white24, fontSize: 9.5)),
            ),
          ],
        ),
      ),
    );
  }
}
