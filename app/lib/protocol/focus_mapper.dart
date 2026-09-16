/// Converts a tap on the preview into the camera's focus coordinate space.
///
/// ## This is a port of the official app's algorithm, with one subtlety that is
/// easy to get wrong
///
/// The camera's `RCDoFocus` does **not** take coordinates in the preview image's
/// pixel space.  The official app converts in `FocusView`, and it has **two**
/// related functions that are easy to conflate:
///
/// ```java
/// // forward: view -> camera   (m17225c, lines 403-407)
/// 4:3 / 1:1 :  x = localX * 640 / viewWidth + 40
///              y = localY * 640 / viewWidth
/// 16:9 / 3:2:  x = localX * 720 / viewWidth
///              y = localY * 720 / viewWidth - 30
///
/// // inverse: camera -> view   (m17223b, lines 497-507)
/// 4:3 / 1:1 :  viewX = (x - 40) * viewWidth  / 640
///              viewY =  y       * viewHeight / 480     // <-- HEIGHT
/// 16:9 / 3:2:  viewX =  x       * viewWidth  / 720
///              viewY = (y + 30) * viewWidth  / 720
/// ```
///
/// **The 4:3 vertical scale uses the view *height*, not the width.**  An earlier
/// version of this class used the width for both axes, which silently squashed
/// every focus point vertically — the focus landed above or below where the user
/// tapped, by an amount that grew toward the top and bottom of the frame.
///
/// That the two functions agree confirms the shape: `640/480` and `720/540` are
/// both exactly 4:3, and the camera plane keeps the preview's aspect.  Using one
/// divisor for both axes only works if the plane is square, which it is not.
///
/// ## The offsets are not optional either
///
/// The camera's coordinate range is **not** anchored at zero: on the narrow plane
/// `x` starts at `+40`, and on the wide plane `y` goes **negative**, down to
/// `-30`.  Clamping to a `0..size` box — the obvious thing to write — shifts every
/// point.
///
/// Verified against the real camera: `Mode` accepts exactly `Manual` and `Auto`,
/// `(0,0)` is rejected, and the command is refused outright outside remote mode.
///
/// ## The reply is not a focus position, so this class no longer parses one
///
/// An earlier version of this file carried `confirm`/`parseEcho`, which read
/// `Posx`/`Posy` out of the `RCDoFocus` reply and offered them as the point the AF
/// system had settled on, with a "plane centre, unconfirmed" fallback for replies
/// that named nothing usable.  **Measured on hardware, that model is wrong.**
/// From a PC against the real camera:
///
/// | `Mode`   | requested (Posx,Posy) | camera replied |
/// |----------|-----------------------|----------------|
/// | `Manual` | (642, 91)             | **(642, 91)**  |
/// | `Manual` | (100, 500)            | **(100, 500)** |
/// | `Auto`   | (642, 91)             | **(360, 240)** |
/// | `Auto`   | (100, 500)            | **(360, 240)** |
/// | `Auto`   | (800, 600)            | **(360, 240)** |
/// | `Auto`   | (0, 0)                | **(360, 240)** |
///
/// `Manual` echoes the request.  `Auto` is a **hard-coded constant**: moving the
/// AF point with `Mode=Manual` first — to (100,500), then to (700,60) — does not
/// change the `(360, 240)` a following `Auto` request still answers with.  So
/// neither mode reports where the camera focused, and "confirmed" would have meant
/// nothing checkable.  The app sends `Mode='Auto'`, which made every tap move the
/// marker to the centre of the frame — the observed defect, and visible in
/// `analysis/emulator/151_focus_topleft.png` against `152_focus_bottomright.png`:
/// two taps in opposite corners, one marker position.
///
/// What the reply *does* support is "the command was accepted", and that is all
/// `AppState.focusAt` now reads from it.  The inverse mapping below is kept because
/// it is the other half of the forward one — the two must agree, and
/// `tool/verify_transport.dart` checks that they do.
///
/// ## Why it is still free of `dart:ui`
///
/// This file must run under the plain Dart VM so the mapping can be checked
/// without a Flutter engine, which is how the vertical-scale bug was caught.
/// Callers pass and receive plain doubles.
library;

class FocusMapper {
  /// Width of the camera's focus plane, narrow aspects (4:3, 1:1).
  static const double _plane43W = 640.0;

  /// Height of the same plane.  640/480 is 4:3 — the plane keeps the preview's
  /// shape, and it is *not* square.
  static const double _plane43H = 480.0;

  /// Width of the wide plane (16:9, 3:2).  720/540 is also 4:3.
  static const double _planeWideW = 720.0;

  /// Horizontal origin on the narrow plane.
  static const double _offset43X = 40.0;

  /// Vertical origin on the wide plane; negative, because the plane starts above
  /// zero.
  static const double _offsetWideY = -30.0;

  /// Aspect values the firmware reports that use the wide plane.
  static const Set<String> _wideAspects = {'16:9', '3:2'};

  /// Map a tap to camera coordinates.
  ///
  /// [localX] / [localY] are the position inside the preview box in logical
  /// pixels, [viewWidth] / [viewHeight] that box's size, and [aspect] the
  /// camera's current `ImageAspect` value (`4:3`, `3:2`, `16:9`, `1:1`).  An
  /// unknown or empty aspect is treated as 4:3, the camera's default.
  ///
  /// Both dimensions are required: the narrow plane scales x by the width and y
  /// by the height.
  static (int x, int y) toCamera({
    required double localX,
    required double localY,
    required double viewWidth,
    required double viewHeight,
    required String aspect,
  }) {
    if (viewWidth <= 0 || viewHeight <= 0) return (320, 240);

    if (_wideAspects.contains(aspect)) {
      return (
        ((localX * _planeWideW) / viewWidth).round(),
        (((localY * _planeWideW) / viewWidth) + _offsetWideY).round(),
      );
    }
    return (
      (((localX * _plane43W) / viewWidth) + _offset43X).round(),
      ((localY * _plane43H) / viewHeight).round(),
    );
  }

  /// The inverse of [toCamera], for diagnostics.
  ///
  /// Two functions that must agree are two functions that can disagree, and this
  /// pair disagreeing is exactly how the vertical-scale bug stayed hidden: with a
  /// 4:3 view the wrong divisor gives the same number, so only a deliberately
  /// non-4:3 view tells them apart.  `tool/verify_transport.dart` round-trips
  /// points through both.
  ///
  /// The app itself no longer needs to draw at a coordinate the camera reported —
  /// it does not report one; see the note at the top of this file.
  static (double x, double y) fromCamera({
    required int x,
    required int y,
    required double viewWidth,
    required double viewHeight,
    required String aspect,
  }) {
    if (viewWidth <= 0 || viewHeight <= 0) return (0, 0);
    if (_wideAspects.contains(aspect)) {
      return (
        (x * viewWidth) / _planeWideW,
        ((y - _offsetWideY) * viewWidth) / _planeWideW,
      );
    }
    return (
      ((x - _offset43X) * viewWidth) / _plane43W,
      (y * viewHeight) / _plane43H,
    );
  }

  /// Whether a coordinate lies inside the plane the camera accepts.
  ///
  /// Exposed for diagnostics: a value outside this box means the caller used the
  /// wrong plane or the wrong divisor, which is exactly the mistake this class
  /// exists to prevent.
  static bool isPlausible(int x, int y, String aspect) {
    if (_wideAspects.contains(aspect)) {
      // 720 wide; y runs from -30 to 540-30 = 510.
      return x >= 0 && x <= 720 && y >= -30 && y <= 510;
    }
    // 640x480 with x offset by 40.
    return x >= 40 && x <= 680 && y >= 0 && y <= 480;
  }

  /// Whether an aspect value is one the camera actually reports.
  static bool isKnownAspect(String aspect) =>
      aspect == '4:3' || aspect == '3:2' || aspect == '16:9' || aspect == '1:1';
}
