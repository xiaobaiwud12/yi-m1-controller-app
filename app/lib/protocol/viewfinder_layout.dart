/// How the live view is laid out for the current screen geometry.
///
/// ## The idea
///
/// A 4:3 preview on a modern phone screen **cannot fill it**. In portrait the
/// frame is wide and short, so there are black bands above and below; in
/// landscape it is tall and narrow, so the bands are on the left and right.
///
/// Every camera app in the world treats those bands as waste and puts a
/// translucent bar over the image instead — which covers the very thing the user
/// is trying to compose. But the bands are *exactly* the right shape for controls:
/// wide and short in portrait, tall and narrow in landscape.
///
/// So this computes, for a given screen and preview aspect, how much band space
/// exists on each edge and whether there is enough of it to be worth using.
///
/// ## Why there is no `dart:ui` here
///
/// The geometry is the part most likely to be wrong — a sign error puts the
/// shutter on top of the picture — and keeping it free of Flutter means it can be
/// checked in the plain Dart VM by `tool/verify_transport.dart`, with no device
/// and no emulator. Sizes are therefore plain doubles, and rects are returned as
/// four numbers rather than a `Rect`.
library;

/// A rectangle as four doubles, ordered left, top, width, height.
typedef PlainRect = ({double left, double top, double width, double height});

/// The narrowest a band can be and still hold a control, matching
/// [ViewfinderLayout.sideBandFitsControls].
///
/// A band narrower than this clips its own button, which reads as a layout bug
/// rather than as a deliberate compact layout — so anything that does not fit is
/// scaled down instead (see `_BandFitted` in the live-view page).
const double kMinControlBand = 56;

/// The shortest an end row may be when it is sized from its content.
///
/// Below this a row cannot hold a 44dp target with its padding, so clamping to it is
/// what keeps a measured want from producing an unusable band.
const double kMinEndBand = 44;

/// The width a side band falls back to when the caller does not say what its
/// content needs.
///
/// Not a taste: it is what a column of icon buttons measures (three 48dp buttons
/// with padding) and comfortably more than a camera-state readout needs. It is a
/// **floor for the fallback**, not a ceiling — a caller that knows its controls
/// are wider passes [ViewfinderLayout.controlBandWant] and gets a band that fits
/// them, because a band that is too narrow for its content is scaled down until it
/// is unreadable rather than merely tight.
const double kMaxSideBand = 160;

/// The narrowest a camera-readout column can be and still be read.
///
/// ## What this number is, and what it deliberately is not
///
/// It is **not** chosen from the readout's own content width. That is 156 dp: the
/// widest string that actually reaches this column is `Incandescent` — 12 characters
/// at 12 sp, measured at **144.0 dp** against this app's font metrics, plus the 12 dp
/// of padding each row carries — and in full screen there is not 156 dp to give it.
///
/// (Earlier revisions of this comment said 192 dp, measured from
/// `AperturePriority`. That is an **enum constant name**, and what the UI draws is
/// the enum's `value` field: `rcExposureMode.AperturePriority` carries `'A'`.
/// `app/tools/measure_readout_strings.py` prints all 232 constants against the 219
/// values they display; the longest display value in the whole protocol is
/// `CenterWeighted`, which is the **metering mode** and is not one of this column's
/// rows at all. The readout's rows are Mode / Shutter / Aperture / ISO / EV / WB /
/// Style / Battery / Left, and their longest values are `Incandescent` (12) and
/// `HContrastBW` (11).)
///
/// It is the largest floor that still lets the **control** column reach the width the
/// shutter needs. On a 914x411 dp 4:3 body the slack is 366 dp, the controls' design
/// width is 288, so the readout can have at most 78 without the shutter being drawn
/// smaller in full screen than in the normal layout — which is the defect
/// (`analysis/54`).
///
/// ## What the floor costs, and what it stopped costing
///
/// Giving the column the camera's own words at this width is what made it illegible:
/// measured on the widget tree, a 78 dp band leaves 66 dp for a value, so
/// `Incandescent` (144.0 dp at 12 sp) was drawn at **0.458 — 5.5 dp of type** and
/// `HContrastBW` (132.0) at 0.500. The column was complete and unclipped, and
/// unreadable.
///
/// The width is not negotiable — see above, and `analysis/55` for the alternatives
/// that were built and measured — so the **content** is what changes: in a band this
/// narrow the page draws [compactReadoutValue]'s short forms. Measured in the full
/// screen layout on that body, with every row holding the longest value its pool
/// allows:
///
///     row        value drawn    width drawn / wanted   type drawn
///     WB         Incand.            66.0 / 84.0           9.4 dp
///     Shutter    1/4000             66.0 / 72.0          11.0 dp
///     Mode, Aperture, ISO, EV,      60.0 / 60.0 or less  12.0 dp
///     Style, Battery, Left
///
/// — so seven of the nine rows are drawn at **1.0**, the shutter row at 0.92 and the
/// white balance at **0.79** (9.4 dp), and no *value* in the column is smaller than
/// that. (The labels are 9 sp and are
/// scaled only where one does not fit: `Aperture` is 72.0 dp against the same 66 and
/// is drawn at 0.917, i.e. 8.3 dp. They are wrapped in the same `_BandFitted` so that
/// a large system text scale shrinks them instead of wrapping them into a second
/// line, which would change the column's height.)
///
/// The floor is still a floor rather than a target: a screen narrower than the
/// reference body cannot drive the readout below it, and the interactive column is
/// the one whose usability wins.
const double kMinReadoutBand = 78;

/// The longest a readout value may be as the narrow column draws it.
///
/// The band leaves the text 66 dp ([kMinReadoutBand], less the 2+2 dp row padding and
/// the 4+4 dp `_BandFitted` puts around a value), and this app's font metrics measure
/// one em per character — so seven characters is 84.0 dp, drawn at 0.79, which is
/// 9.4 dp of type. Eight would be 96.0 and 0.69, which is a texture rather than a
/// readout.
const int kCompactReadoutLength = 7;

/// The camera's value as the **narrow** readout column draws it, or unchanged.
///
/// ## Why short forms exist at all
///
/// [kMinReadoutBand] is 78 dp because that is what the *controls* leave in full
/// screen, and the camera's longest words do not fit in 78 — see the measurements
/// there. Taking the width back from the controls is the defect `analysis/54` fixed,
/// so what changes is the content.
///
/// ## What may be shortened, and what may not
///
/// Only strings this function **knows**. Anything else passes through whole, because
/// the failure mode of guessing is truncating a *number*: `12345` drawn as `1234` is
/// not an abbreviation, it is a different value. That is also why the Kelvin ladder
/// (`11500`) and the remaining-shot count are left alone.
///
/// The table is deliberately tiny. `app/tools/measure_readout_strings.py` prints the
/// camera's whole vocabulary — 232 constants, 219 display values — and the only
/// strings over [kCompactReadoutLength] that reach these rows are the two words
/// below, which get a table entry because a word abbreviates well, and the shutter's
/// fractions, which are handled by rule.
///
/// The full words are not lost. The **wide** column draws them unchanged: the page
/// asks for a band wide enough to do that whenever the controls leave it (which is
/// every landscape body with room, including the reference body's normal layout), and
/// the settings menu's white-balance and picture-style dropdowns list the camera's
/// own spellings regardless of layout.
String compactReadoutValue(String value) {
  final known = _kCompactReadoutValues[value];
  if (known != null) return known;
  // `1/4000s` -> `1/4000`. The unit is the row's, and dropping it cannot collide
  // with the whole-second entries (`60s`, `2.5s`), which keep their suffix because
  // there it carries the meaning: `60` alone would read as a fraction.
  if (value.length > 6 && value.startsWith('1/') && value.endsWith('s')) {
    return value.substring(0, value.length - 1);
  }
  return value;
}

/// The short form of every value that is too long for the narrow column.
///
/// Each entry is the shortest form that is still unambiguous *against the whole
/// value pool it comes from*: `Incand.` cannot be confused with `Auto`, `Sunny`,
/// `Cloudy`, `Shadow` or a Kelvin number, and `Std.` / `Port.` / `Nat-BW` / `HC-BW`
/// are distinct from each other and from `Vivid`. The check is mechanical:
/// `test/readout_legibility_test.dart` walks those pools and asserts that this map is
/// injective over them, that no short form collides with another value's full word,
/// and — the assertion that found `Standard` and `Portrait` — that **no** value in
/// any of the readout's pools is longer than [kCompactReadoutLength] after mapping.
/// A new firmware value that overflows the column therefore fails a test instead of
/// quietly shrinking.
const Map<String, String> _kCompactReadoutValues = {
  'Incandescent': 'Incand.',
  'Standard': 'Std.',
  'Portrait': 'Port.',
  'NaturalBW': 'Nat-BW',
  'HContrastBW': 'HC-BW',
};

/// The width the second-level settings panel needs to stay usable.
///
/// It is a panel of label-plus-dropdown rows, so below this the value column is
/// clipped rather than merely tight. Above it the extra width buys nothing.
const double kMinSettingsPanelWidth = 240;

/// The width above which the panel stops growing: past this it covers picture
/// for no gain, and a dropdown does not read better for being wide.
const double kMaxSettingsPanelWidth = 360;

class ViewfinderLayout {
  /// The full area available to the preview and its chrome.
  final double availableWidth;
  final double availableHeight;

  /// The camera's current frame aspect (4:3, 3:2, 16:9 or 1:1).
  final double previewAspect;

  /// Which edge carries the buttons.
  ///
  /// True means the **trailing** edge (right, or bottom in a right-to-left
  /// layout) gets the control column. It exists so the two sides can be
  /// configured independently without the caller reimplementing the split, and so
  /// an RTL locale does not put the shutter under the wrong thumb.
  final bool controlsOnTrailingEdge;

  /// How wide the control column's content actually is, when the caller knows.
  ///
  /// ## Why this is a parameter and not a constant
  ///
  /// The band width used to come from the screen's *height* (`availableHeight/3`,
  /// capped at [kMaxSideBand]), which has nothing to do with what goes in it. On a
  /// 914×411 dp landscape screen that yielded a 99 dp column, and the content
  /// destined for it — a 184 dp shutter bar and a ~280 dp navigation row — was
  /// then squeezed by `FittedBox(scaleDown)` to roughly a third, leaving 12 sp
  /// labels at about 4 sp. Measured on the emulator: the controls were illegible.
  ///
  /// The spare width was there the whole time. A 4:3 frame on that screen needs
  /// 332 of 914 dp, so 582 dp sat unused while the bands fought over 198 of it.
  /// A band is therefore sized from its content first, and only then capped by the
  /// room actually available.
  ///
  /// **This is the number the controls are entitled to.** It is not a wish that a
  /// `FittedBox` may quietly reduce: the caller's own content is built at this
  /// width, and a band narrower than it is scaled down rather than merely tight.
  /// When it cannot be honoured, [ViewfinderLayout.controlBandWidth] is smaller
  /// than this and the caller can tell — see `analysis/54`, where the full-screen
  /// layout used to hand back 183 for a 320 dp row.
  ///
  /// Null keeps the old height-derived sizing, so a caller that has not measured
  /// its content is no worse off.
  final double? controlBandWant;

  /// How wide the camera-readout column's content actually is. See
  /// [controlBandWant].
  ///
  /// Unlike the control band this one is **soft**: the readout is text, so when the
  /// two cannot both be served the split is made in proportion to the two wants —
  /// which is why the number here is chosen as a *share* of the pair rather than as
  /// an absolute width. See [kMinReadoutBand] for the floor underneath it.
  final double? infoBandWant;

  const ViewfinderLayout({
    required this.availableWidth,
    required this.availableHeight,
    required this.previewAspect,
    this.controlsOnTrailingEdge = true,
    this.controlBandWant,
    this.infoBandWant,
    this.topBandWant,
    this.bottomBandWant,
  });

  /// The largest rectangle with [previewAspect] that fits inside the available
  /// area, **ignoring the bands**.
  ///
  /// `BoxFit.contain` semantics, spelled out because the band sizes below are
  /// derived from it and a mismatch would put controls over the picture.
  ///
  /// This is the whole geometry's single source: [horizontalBand] and
  /// [verticalBand] read it, so [bands] and [frameRect] cannot disagree about how
  /// much room there is. The frame it returns is what [frameRect] reports — the
  /// picture is never cropped or stretched to make room for chrome, because
  /// misrepresenting the framing is the one thing this page must not do.
  ({double width, double height}) get frameSize {
    if (availableWidth <= 0 || availableHeight <= 0 || previewAspect <= 0) {
      return (width: 0, height: 0);
    }
    final screenAspect = availableWidth / availableHeight;
    if (screenAspect > previewAspect) {
      // The screen is wider than the frame, so the frame is height-limited and
      // the bands are on the left and right.
      return (width: availableHeight * previewAspect, height: availableHeight);
    }
    // The screen is taller, so the frame is width-limited and the bands are above
    // and below.
    return (width: availableWidth, height: availableWidth / previewAspect);
  }

  /// Empty space above and below the frame, in total.
  double get verticalBand {
    final f = frameSize;
    final v = availableHeight - f.height;
    return v > 0 ? v : 0;
  }

  /// Empty space left and right of the frame, in total.
  double get horizontalBand {
    final f = frameSize;
    final v = availableWidth - f.width;
    return v > 0 ? v : 0;
  }

  /// True when the screen is wider than the frame, i.e. the bands are at the
  /// sides.
  bool get isLandscapeLayout =>
      verticalBand <= horizontalBand && horizontalBand > 0;

  /// True when there is enough side band to hold a column of controls.
  ///
  /// The threshold is roughly a control's width plus a margin. Below it, forcing
  /// controls into the band would either clip them or make them unusably narrow,
  /// so the caller falls back to overlaying the image.
  bool get sideBandFitsControls => horizontalBand / 2 >= kMinControlBand;

  /// True when there is enough top/bottom band to hold a row of controls.
  bool get endBandFitsControls => verticalBand / 2 >= 44;

  /// How wide the top row's content is, when the caller knows its height.
  ///
  /// ## Why the end bands became content-driven too
  ///
  /// Portrait used to split [verticalBand] evenly between the top and bottom rows,
  /// which is a decision made by the *screen's* shape rather than by what goes in
  /// them. On a 411x727 body that is 209.5dp above and 209.5dp below, to hold a
  /// one-line state strip and a shutter bar. Measured: the settings panel was left
  /// **154dp** — header and tabs take 78 of that, so about two settings rows, which
  /// is the "only two lines" that was reported.
  ///
  /// The 419dp of band was never needed. Sizing each end row to its content leaves
  /// the difference as [endBandSlack], which is exactly the white space the user
  /// pointed at between the panel's header and the navigation row.
  ///
  /// Null keeps the old even split, so a caller that has not measured its chrome is
  /// no worse off.
  final double? topBandWant;

  /// How tall the bottom row's content is (shutter bar plus navigation).
  /// See [topBandWant].
  final double? bottomBandWant;

  /// Empty space left over after the end rows have taken what they need.
  ///
  /// This is the room a panel can occupy without taking anything from the picture:
  /// the frame is sized from the screen's width in portrait, so the space around it
  /// is free. Negative is clamped to zero.
  double get endBandSlack {
    final b = bands;
    final used = b.$2 + b.$4;
    final left = verticalBand - used;
    return left > 0 ? left : 0;
  }

  /// The side band width used when the caller did not say what its content needs.
  ///
  /// Derived from the screen **height**, which is the only signal available without
  /// measuring a widget: a third of the height is roughly what a column of controls
  /// with a margin occupies. It is a heuristic and was the whole story until the
  /// emulator showed what it does to wide content — see [controlBandWant], which is
  /// the measured answer and takes precedence.
  double get _preferredSideBand {
    final cap = availableHeight / 3;
    final wanted = cap < kMaxSideBand ? cap : kMaxSideBand;
    return wanted < kMinControlBand ? kMinControlBand : wanted;
  }

  /// The bands that are actually reserved, in the order `(leading, trailing)`,
  /// or `(0, 0)` when the side columns are not in use at all.
  ///
  /// ## Sizing
  ///
  /// Each side is sized from **its own content** when the caller supplied a want
  /// ([controlBandWant] / [infoBandWant]), because the two hold different things —
  /// a column of buttons and a column of numbers — and forcing them equal either
  /// starves the buttons or widens the numbers for nothing.
  ///
  /// The pair is then clamped into the horizontal slack, which is all the room the
  /// bands ever had: the frame's size is derived from the screen height alone, so
  /// anything the bands take beyond that slack comes out of the picture.
  ///
  /// ## When the wants do not both fit: they are scaled together, in proportion
  ///
  /// This used to split the slack **evenly** — and on a 914x411 dp full-screen body
  /// that is the defect behind `analysis/54`. The frame wants 548 of the 914 dp
  /// width, leaving 366 for both bands, and the page asks for 288 + 107. An even
  /// split gave each **183**, so the 320 dp shutter row was scaled by `FittedBox` to
  /// 0.547 and the 68 dp shutter was **painted at 34.4 dp** — below Material's 48 dp
  /// minimum, in the mode whose entire purpose is to make the camera easier to use.
  /// The two sides are not interchangeable: a thumb has to hit the control column,
  /// and the readout is something to glance at.
  ///
  /// Splitting evenly is also *not* the neutral choice it reads as, and this is the
  /// part worth keeping: the two columns are not equally damaged by the same
  /// percentage. The control column's content is 320 dp of controls that stop being
  /// hittable when they shrink, while the readout is text that is merely harder to
  /// read. So the split is made **in proportion to what each column asked for**,
  /// which keeps the controls' share of the band at the ratio their own content
  /// implies, and each side is held at [kMinControlBand] so neither can be given a
  /// width no control fits in.
  ///
  /// The page's two wants are therefore a ratio, not two independent requests: they
  /// are chosen so that the controls' share of 366 dp lands at or above the width
  /// the shutter needs. `analysis/54` has the arithmetic.
  ///
  /// **Negative result, stated so it is not rediscovered, and measured on that
  /// body:** 288 + 107 = 395 dp of band is being asked for out of 366 dp of slack,
  /// so neither column gets its own width. Any rule that hands the controls
  /// everything leaves the readout 78 dp and scales its text to 0.34; any rule that
  /// reserves the readout's own width takes the shutter back below the size the
  /// *normal* layout gives it. There is no split of 366 that satisfies both, and the
  /// proportional one is the compromise that keeps both usable.
  (double, double) get _sideBands {
    if (!isLandscapeLayout || !sideBandFitsControls) return (0, 0);

    final slack = horizontalBand;

    final wantControl =
        (controlBandWant ?? _preferredSideBand).clamp(kMinControlBand, slack);
    final wantInfo =
        (infoBandWant ?? _preferredSideBand).clamp(kMinControlBand, slack);

    if (wantControl + wantInfo <= slack) {
      return (wantInfo, wantControl);
    }

    // Not enough room for both wants. Scale the pair back in proportion to what
    // each asked for, then hold both at the width a control needs.
    //
    // The floor is applied **after** the scaling and the pair is re-clamped to the
    // slack, so on a screen too small for two control bands this degrades to the
    // even split it replaced rather than to a negative width.
    final scale = slack / (wantControl + wantInfo);
    var control = wantControl * scale;
    var info = slack - control;
    if (info < kMinReadoutBand) {
      info = kMinReadoutBand.clamp(0.0, slack);
      control = slack - info;
    }
    if (control < kMinControlBand) {
      control = kMinControlBand.clamp(0.0, slack);
      info = slack - control;
    }
    return (info, control);
  }

  /// The width of the band on the control edge: the shutter, the nav, the
  /// settings toggle.
  double get controlBandWidth => _sideBands.$2;

  /// The width of the band opposite the controls, holding the camera readout.
  double get infoBandWidth => _sideBands.$1;

  /// What is left for the readout once the controls have what they asked for.
  ///
  /// ## Why a caller needs this before it can say what the readout wants
  ///
  /// The two columns are sized from their own content ([controlBandWant] /
  /// [infoBandWant]), and when both wants fit they are served independently — but
  /// when they do not, the pair is scaled back in proportion, so *any* readout want
  /// above [kMinReadoutBand] silently costs the controls width on a body with no
  /// slack. On the 914x411 dp full-screen body the slack is 366 dp and the controls
  /// ask for 288, so a readout want of 156 would hand them 242 and paint the shutter
  /// at 45.9 dp instead of 55.0 — the defect `analysis/54` fixed, reachable again
  /// through the want alone.
  ///
  /// The readout's want is therefore a *choice between two contents* rather than one
  /// number: the camera's own words, which need 156 dp, or their short forms, which
  /// need [kMinReadoutBand]. This getter is the test for which one is affordable, and
  /// it is arithmetic on the geometry alone — [frameSize] is derived from the screen
  /// and the preview aspect, never from the bands — so asking it before constructing
  /// the layout the page actually uses is not circular.
  ///
  /// Zero when the sides are not carrying chrome at all, and never negative: a body
  /// with no slack has nothing to lend.
  double get readoutRoom {
    if (!usesSideColumns) return 0;
    final left = horizontalBand - (controlBandWant ?? kMinControlBand);
    return left > 0 ? left : 0;
  }

  /// Thickness of the band on each of the four edges, in the order
  /// `(left, top, right, bottom)`.
  ///
  /// Only one axis is ever non-zero: the frame is fitted rather than cropped, so
  /// a screen leaves bands on *either* the sides or the ends, never both. That is
  /// what makes the bands a reliable home for chrome instead of a variable to
  /// hedge against.
  (double left, double top, double right, double bottom) get bands {
    if (isLandscapeLayout && sideBandFitsControls) {
      return controlsOnTrailingEdge
          ? (infoBandWidth, 0, controlBandWidth, 0)
          : (controlBandWidth, 0, infoBandWidth, 0);
    }
    if (!isLandscapeLayout && endBandFitsControls) {
      // Content-driven when the caller measured its chrome, even split otherwise.
      // See [topBandWant]: the even split is what starved the settings panel.
      if (topBandWant == null && bottomBandWant == null) {
        final v = verticalBand / 2;
        return (0, v, 0, v);
      }
      final half = verticalBand / 2;
      final fallback = half < kMinControlBand ? kMinControlBand : half;
      // Each row gets what it asked for, but neither may take so much that the other
      // loses its minimum — two rows that both want everything is how a Column ends up
      // overflowing, which is a Flutter error rather than a tight fit.
      var top = topBandWant ?? fallback;
      var bottom = bottomBandWant ?? fallback;
      top = top.clamp(kMinEndBand, verticalBand - kMinEndBand);
      bottom = bottom.clamp(kMinEndBand, verticalBand - kMinEndBand);
      if (top + bottom > verticalBand) {
        final scale = verticalBand / (top + bottom);
        top *= scale;
        bottom *= scale;
      }
      return (0, top, 0, bottom);
    }
    return (0, 0, 0, 0);
  }

  /// Whether the chrome should be laid out as side columns rather than end rows.
  ///
  /// This is the flag the UI branches on. A control that reads well as a wide
  /// short row reads badly as a tall narrow column, so the two are genuinely
  /// different arrangements rather than one stretched.
  bool get usesSideColumns => isLandscapeLayout && sideBandFitsControls;

  /// Where the frame sits inside the available area.
  ///
  /// The frame is centred in the **banded** region, and what the bands do not
  /// claim is split evenly around it. The bands are capped at [kMaxSideBand], so
  /// on a very wide screen both the frame *and* the bands have slack; centring
  /// the whole group is what keeps the picture looking deliberately placed rather
  /// than shoved against one edge. The leftover cannot go to the frame instead —
  /// a 4:3 frame cannot fill a 21:9 screen without cropping, and cropping would
  /// misrepresent the framing, which is the one thing this page must not do.
  PlainRect get frameRect {
    final f = frameSize;
    final b = bands;
    final slack = horizontalBand - b.$1 - b.$3;
    return (
      left: b.$1 + slack / 2,
      // Only one axis ever carries a band, so the vertical band is zero whenever
      // this matters and a plain centre is exact.
      top: b.$2 + ((availableHeight - b.$2 - b.$4) - f.height) / 2,
      width: f.width,
      height: f.height,
    );
  }

  /// The width for the second-level settings panel.
  ///
  /// In landscape the panel is a sheet over the frame rather than a replacement
  /// for a side column. Keeping it at panel width instead of band width is a
  /// deliberate trade: the side band is sized for *buttons*, and squeezing a
  /// label-plus-dropdown row into it clips the value column, while widening the
  /// band to fit the panel would shrink the 4:3 frame until it is too small to
  /// focus with. A sheet costs the picture for as long as it is open, which is
  /// the only moment the user is not composing.
  ///
  /// In portrait the panel already spans the full width inside the end band, and
  /// that stays as it is.
  double get settingsPanelWidth {
    if (!usesSideColumns) return availableWidth;
    final wanted = availableWidth * 0.44;
    final width = wanted > kMaxSettingsPanelWidth
        ? kMaxSettingsPanelWidth
        : wanted;
    return width < kMinSettingsPanelWidth ? kMinSettingsPanelWidth : width;
  }

  @override
  String toString() => 'ViewfinderLayout(${availableWidth.toInt()}x'
      '${availableHeight.toInt()}, aspect $previewAspect, '
      '${usesSideColumns ? "side columns" : "end rows"}, bands $bands)';
}

// ---------------------------------------------------------------------------
// The exposure dials of the full-screen layout.
//
// ## Why this table is in a geometry file
//
// Which dial a mode gets is a **pure function of the mode**, so it belongs at the
// lowest layer that can catch it being wrong (`AGENTS.md` §3) rather than in a
// screenshot test. It is here, beside the band arithmetic, because the two are the
// same question asked twice: `analysis/60` measures that two dials fit above the
// shutter and no more, so the layout's shape *is* this table.
//
// What it deliberately does **not** do is re-state which parameters the camera owns
// in each mode. That table is `AppState.isParamEffective` — this library may not
// import it (`lib/protocol/` is Flutter-free, and `AppState` needs Flutter), so the
// predicate is **passed in** and the caller hands over the real one. A mode that
// gains a parameter there changes this function's answer with no second copy to
// drift.
// ---------------------------------------------------------------------------

/// `RCFNSet` — the aperture command.
const String kCmdAperture = 'RCFNSet';

/// `RCShutterSpeedSet` — the shutter command.
const String kCmdShutter = 'RCShutterSpeedSet';

/// `RCEVSet` — the exposure-compensation command.
const String kCmdEv = 'RCEVSet';

/// `RCISOSet` — the ISO command.
const String kCmdIso = 'RCISOSet';

/// `RCSwitchDialMode` — the exposure-mode command.
const String kCmdMode = 'RCSwitchDialMode';

/// How many dials the full-screen control column stacks above the shutter.
///
/// **Two**, and it is a measured budget rather than a preference: the column is
/// 411 dp tall on the reference body and already holds the toggle row (56 dp), the
/// shutter bar (77 dp with the preview running, 194 dp with the camera's longest
/// explanation under it) and the navigation row (42.8 dp). Two dials at the stacked
/// height plus their padding are 108 dp; see `analysis/60` for the arithmetic that
/// makes it two and not three.
const int kDialsAboveShutter = 2;

/// Whether exposure compensation is a **reference** rather than an edit in [mode].
///
/// ## This is the user's rule, and it disagrees with `isParamEffective`
///
/// The user's specification for the full-screen dials says: *"note that exposure
/// compensation is not adjustable in M, it is only an exposure reference"*, which is
/// why M stacks **aperture and shutter** above the shutter button and shows the EV
/// value as a read-only hint underneath. `AppState.isParamEffective('M', 'RCEVSet')`
/// answers `true` — its `default` branch treats an unknown or M mode as "everything is
/// the user's" — so this is the one place the dial layout does **not** follow that
/// table.
///
/// Per `analysis/41` (user instructions outrank everything, and a conflict is stated
/// rather than resolved silently) the user's rule wins here, and the conflict is
/// recorded in this comment, in `analysis/60` §conflicts, and in the delivery report.
/// It is deliberately a function of the mode alone so the exception is one line in one
/// place rather than a condition inside the layout.
///
/// **What it does not change:** the settings panel's `RCEVSet` row in M. That row
/// keeps `isParamEffective` as its authority, so a user who wants to send the command
/// anyway still can — this function only decides that M's *dial* is a hint rather than
/// an editor.
bool evIsReference(String mode) => mode == 'M';

/// The dials the full-screen control column stacks **above the shutter**, as `RC…`
/// command names, top to bottom.
///
/// [effective] is `AppState.isParamEffective` — passed in rather than reimplemented,
/// see the section comment above.
///
/// ## The order is the user's, and it is not arbitrary
///
/// The specification names the A/S pair as "the exposure compensation dial **and** the
/// corresponding adjustable parameter dial", and M's pair as "aperture **and** shutter"
/// — so exposure compensation is listed first wherever it is a dial, and the parameter
/// the mode leaves to the user sits directly above the shutter button. That is also the
/// ergonomic reading: the bottom dial is the one nearest the thumb's rest position on
/// the shutter, and in A/S the parameter being chosen is the primary control.
///
///     mode      above the shutter (top to bottom)
///     M         aperture, shutter            (EV is a reference, not a dial)
///     A         EV, aperture
///     S         EV, shutter
///     P/Auto/C  EV
///
/// The result is capped at [kDialsAboveShutter]. M is the only mode where a third could
/// otherwise appear, and [evIsReference] removes it there; a mode the firmware has not
/// told us about falls out of the same cap — `isParamEffective`'s default branch makes
/// every command effective for it, so the cap leaves the exposure compensation and the
/// aperture. No special case is needed, and none is written.
List<String> fullScreenDialsAboveShutter(
  String mode,
  bool Function(String mode, String command) effective,
) {
  const ordered = <String>[kCmdEv, kCmdAperture, kCmdShutter];
  final dials = <String>[
    for (final c in ordered)
      if (effective(mode, c) && !(c == kCmdEv && evIsReference(mode))) c,
  ];
  return dials.length <= kDialsAboveShutter
      ? dials
      : dials.sublist(0, kDialsAboveShutter);
}

/// The dials **every** exposure mode keeps on the left, below the camera readout:
/// ISO, and the shooting mode itself.
///
/// Both are effective in every mode (`isParamEffective` returns true for `RCISOSet`
/// and `RCSwitchDialMode` in all of them), which is what makes the left column the
/// fixed half of the layout and the control logic the same in every mode — the
/// property the user asked for. ISO first, then the mode, matching the order the
/// specification names them in.
const List<String> kFullScreenDialsLeftColumn = <String>[kCmdIso, kCmdMode];

/// Every command the full-screen layout puts on a dial in [mode].
///
/// This is the set the **settings panel must not offer a second time** while the
/// dials are on screen (`analysis/60`; the user's requirement A: "the parameters the
/// dials can adjust may be removed from Settings in landscape full-screen to avoid
/// duplication"). Written as a function of the same table the dials are built from, so
/// a mode whose dials change cannot leave a stale duplicate behind in the menu.
Set<String> fullScreenDialCommands(
  String mode,
  bool Function(String mode, String command) effective,
) =>
    {
      ...kFullScreenDialsLeftColumn,
      ...fullScreenDialsAboveShutter(mode, effective),
    };

// ---------------------------------------------------------------------------
// Where the shutter sits, and who fills the space around it.
//
// ## Why this is arithmetic in a geometry file and not three `Expanded`s
//
// The user's third report, verbatim: *"the shutter position should not move, and then
// the dials above and below and the histogram should scale adaptively to fill the blank
// space, to make them easier to touch and to use the space."*
//
// Those are two requirements that pull against each other, and the pull is the whole
// design. "The dials fill the space" wants each slot sized from the space it can have;
// "the shutter does not move" wants its position to be a constant. If the slot is sized
// from its contents — which is what the column did before, a content-sized `Column`
// centred in the band — then a mode with one dial puts the shutter in a different place
// from a mode with two, and toggling the histogram moves it again. That is exactly the
// defect: the shutter is the one control the user aims at without looking, and it moved
// whenever anything else on the screen changed.
//
// So the shutter is placed **first**, from the band alone, and the dials and the
// read-only extras are what scale into what is left. The four bands are:
//
//     top bar        [_topBarHeight]                  fixed, its content is a button row
//     dials above    [dialRegionHeight]               the slot that scales
//     shutter row    [shutterSlotHeight]              the shutter is centred in it
//     below          whatever is left                 EV hint, histogram, status text
//     navigation     [_navHeight]                     fixed, pinned to the bottom
//
// The dials get a **floor**, the extras take the remainder, and both are fixed fractions
// of the band — which is why the shutter's rectangle is a function of the band and nothing
// else. On the reference body (411 dp, `analysis/60`) the arithmetic is
//
//     fixed    56 (top bar) + 42.8 (nav) + 5 * 2 * 4 (padding)   = 138.8
//     free     411 - 138.8                                        = 272.2
//     shutter  min(272.2, 77)                                     =  77.0
//     rest     272.2 - 77                                         = 195.2
//     above    max(195.2 * 0.55, 110)                             = 110.0  (floor wins)
//     below    195.2 - 110.0                                      =  85.2
//
// and the shutter's own box is centred in its 77 dp slot, so the button starts at
// `8 + 56 + 4 + 4 + 110 + 4 = 186` dp from the top of the band. The check that matters is
// not that number but that it is the **same** number in M, A, S and P and with the
// histogram on and off, which `mode_aware_dials_test.dart` measures as
// `getRect(btn-shutter)` over all eight.
//
// ## What is deliberately *not* a parameter
//
// Which dials a mode gets. A slot sized differently per mode would move the shutter, which
// is the requirement. The dials scale to the region they share (the dial widget reads its
// cell's height and grows into it — see `ExposureDial`), so M's two dials are each half of
// it and P's one dial is all of it, with the **region** the same size in both.
// ---------------------------------------------------------------------------

/// The padding `_SideColumn` puts above and below every child of a band column.
const double kColumnChildPadding = 4;

/// The full-screen control column's toggle row — identity, fps, grid, histogram.
///
/// The same 56 dp the landscape split already assumes, and the row's own measured
/// height; it is repeated here because the slot arithmetic below needs it and the two
/// must not drift.
const double kFullScreenTopBarHeight = 56;

/// The navigation row — the only route to Settings, Video and Album.
///
/// 42.8 dp measured on the reference body, and it is **pinned** rather than scrolled:
/// `analysis/60` §6 records that the camera's longest blocked-shutter explanation is
/// 236.3 dp of bar in a 411 dp band, so something has to give, and `_BottomBand` settled
/// which: *"Navigation is not optional and status text is, so the status text is what
/// scrolls."*
const double kFullScreenNavHeight = 42.8;

/// The shortest the shutter row may be given.
///
/// 77 dp is the shutter bar with the preview running — the preview toggle and the two
/// 48 dp buttons on either side of a 68 dp shutter. Below this the row would be scaled
/// by `_BandFitted`, and a scaled shutter is the defect `analysis/45` records.
const double kMinShutterRowHeight = 77;

/// How tall the **dial region** is, at minimum, when the dials are on screen.
///
/// **110 dp**: two [kStackedDialHeight] cells (48 each) and the 4 dp between them, inside
/// the 8 dp the column puts around the slot — `2 * 48 + 4 + 8 = 108`, rounded up.
///
/// This is the floor that keeps the user's third requirement from being paid for by the
/// first two. Pinning the shutter and filling the band divides a fixed 411 dp, and the
/// read-only side below the shutter is not free either: in M with the histogram on it
/// holds a 34 dp exposure reference and a 57 dp live histogram, 107 dp together. Both
/// cannot have everything, so the arithmetic that decides is this: the dials hold **at
/// least** what they are drawn at today, and the extras take what is left.
///
/// Measured on the reference body: the region lands at 110.0 of the 360.2 the column has
/// between its toggle row and its navigation row, which gives cells of **49.0** — a hair
/// above the 48 they were drawn at before this round — and leaves **109.2** below, which
/// holds a live histogram together with M's reference at 0.98 of their design size.
const double kMinDialRegionHeight = 110;

/// How the space left over once the shutter is placed is shared between the two sides.
///
/// **55 / 45**, and the larger half is the **dials**, because that is the side where a dp
/// buys a bigger tap target rather than a longer sentence. The floor
/// [kMinDialRegionHeight] is what actually binds on the reference body — the share is what
/// decides the split on a **taller** screen, where there is room for both to grow and the
/// controls are the side worth growing.
///
///     dials = max(free - shutter - extras share, kMinDialRegionHeight)
///
/// At 411 dp: free 272.2, shutter 77, so 195.2 to split — 55 % is 107.4, under the 110
/// floor, so the floor wins and the dials get 110.0. On a 500 dp band the same split gives
/// them 133.2.
const double kDialsRegionShare = 0.55;

/// Where each part of the full-screen control column goes, in a band [bandHeight] tall.
///
/// See the section comment above for why the shutter is placed from the band rather
/// than from its neighbours. Returned as plain doubles, and computed by a free function,
/// so this can be checked in the plain Dart VM with no Flutter engine — the same reason
/// this library imports neither `package:flutter` nor `dart:ui`.
///
/// All three heights are **content** boxes. The caller draws each inside a slot that adds
/// [kColumnChildPadding] above and below it, and the navigation row outside them costs one
/// more pair; `fixed` below is exactly that, and getting it wrong by one pair is 8 dp of
/// shutter drift. The two are held against each other by the layout checks in
/// `test/mode_aware_dials_test.dart`, which measure the rendered rects rather than
/// recomputing this arithmetic.
({double above, double shutter, double below}) fullScreenColumnSlots(
  double bandHeight, {
  double topBarHeight = kFullScreenTopBarHeight,
  double navHeight = kFullScreenNavHeight,
  double minShutter = kMinShutterRowHeight,
  double minDials = kMinDialRegionHeight,
  double dialsShare = kDialsRegionShare,
}) {
  // Five children of the column pay 4 dp above and below: the navigation row, the toggle
  // row, the dials, the shutter, and whatever is below the shutter.
  const children = 5;
  final fixed = topBarHeight + navHeight + children * 2 * kColumnChildPadding;
  final free = bandHeight - fixed;
  if (free <= 0) {
    return (above: 0, shutter: minShutter, below: 0);
  }
  // The shutter takes what it needs and no more, so what it does with the leftover is
  // what decides where it sits. The `minShutter` floor only bites on a band too short to
  // hold the row at all, where it is the honest answer: the row overflows visibly rather
  // than being silently scaled, which is the defect `analysis/45` records.
  final shutter = free < minShutter ? free : minShutter;
  final rest = free - shutter;
  // The dials get the larger share, but never less than what two cells need: a band that
  // cannot give them that would otherwise shrink them below the tap target they are drawn
  // at today, which is the cost the user is asking to remove rather than accept.
  final share = rest * dialsShare;
  final above = share < minDials
      ? (minDials < rest ? minDials : rest)
      : share;
  return (above: above, shutter: shutter, below: rest - above);
}

/// Whether a band is tall enough for [fullScreenColumnSlots] to lay the column out.
///
/// **Not every band the full-screen layout reaches is 411 dp**, and the slot arithmetic
/// does not degrade gracefully on a short one: measured on the 914x297 landscape body, a
/// 297 dp band leaves `free < 0`, the shutter is handed the whole of it as 62.9 dp (its
/// floor, `min(free, 77)`), the dial region and the below slot get zero — and the
/// **control band collapses to 62.9 dp wide**, because the column's cross axis is sized by
/// its widest child and every child in the slots is inside a `FittedBox` that can shrink
/// to nothing. The whole shutter row was then drawn at **0.3** of its size, which is the
/// `analysis/54` defect reproduced by the fix for a different one.
///
/// `fullscreen_band_split_test.dart` caught it, in the one test that pumps the **normal**
/// landscape body with `fullScreen` set — i.e. the shape `btn-fullscreen` cannot actually
/// reach, but which the layout still has to survive.
///
/// So the page asks this first and keeps the content-sized column when the answer is no.
/// The sum is the height at which every slot is at its floor and the below slot has
/// nothing left; below it there is no honest way to pin the shutter and fill the band at
/// the same time, and the old behaviour is the better failure.
bool fullScreenColumnFits(
  double bandHeight, {
  double topBarHeight = kFullScreenTopBarHeight,
  double navHeight = kFullScreenNavHeight,
  double minShutter = kMinShutterRowHeight,
  double minDials = kMinDialRegionHeight,
}) =>
    bandHeight >=
    topBarHeight + navHeight + minShutter + minDials + 5 * 2 * kColumnChildPadding;

/// What the second-level settings sheet covers, as widths in `(left, right)`
/// order.
/// The sheet is drawn over the frame rather than beside it, so the question worth
/// answering is not "how wide is it" but "what does it hide": a sheet narrower
/// than the control band would not even cover the buttons it belongs to, and one
/// that reached the opposite band would black out the readout the user is
/// watching while they change a setting.
///
/// Returned as plain numbers and computed by a free function so
/// `tool/verify_transport.dart` can check it without a Flutter engine — the same
/// reason this library has no `dart:ui`.
({double left, double right}) settingsSheetCoverage({
  required double availableWidth,
  required double availableHeight,
  required double previewAspect,
  double panelWidth = kMinSettingsPanelWidth,
  bool controlsOnTrailingEdge = true,
}) {
  final layout = ViewfinderLayout(
    availableWidth: availableWidth,
    availableHeight: availableHeight,
    previewAspect: previewAspect,
    controlsOnTrailingEdge: controlsOnTrailingEdge,
  );
  if (!layout.usesSideColumns) return (left: 0, right: 0);
  final b = layout.bands;
  return controlsOnTrailingEdge
      ? (left: 0, right: panelWidth + b.$3)
      : (left: panelWidth + b.$1, right: 0);
}
