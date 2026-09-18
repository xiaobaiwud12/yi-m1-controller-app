/// Camera state decoded out of the live-view stream.
///
/// ## The discovery
///
/// Every live-view datagram carries, in the 2272 bytes before the JPEG, a
/// **plaintext JSON object describing the camera's complete state**. Not a
/// binary TLV needing calibration — just JSON:
///
/// ```json
/// {"ExposureMode":"P","MeteringMode":"Multi","ImageQuality":"20",
///  "ImageAspect":"4:3","DriveMode":"Single","DelayShootCnt":"1",
///  "FileFormat":"RAWJ-L","Fnumber":"1.7","FnumberMin":"1.7","FnumberMax":"16",
///  "ShutterSpeed":"1/30s","EV":"0.0","ISOSetting":"Auto","ISOAutoValue":"200",
///  "WB":"Auto","ColorMode":"Standard","LensStatus":"1","BatteryLevel":"75",
///  "FocusMode":"S-AF","FocusSupport":"0","VideoFormat":"VGA_240",
///  "VASwitch":"ON","VAVol":"5","VANR":"OFF","VideoEis":"OFF",
///  "SurplusPhotoCnts":"1290"}
/// ```
///
/// Earlier analysis in this project called this region a "TLV parameter block"
/// and assumed it would need field-by-field calibration. That was wrong, and a
/// calibration tool was written against the wrong model before anyone dumped the
/// bytes as hex — at which point the JSON was immediately obvious. The lesson is
/// recorded in `analysis/11-liveview-state-json.md`.
///
/// ## Why this matters for the client
///
/// * **No polling.** State arrives with the frames already being received, so
///   the UI can show live exposure/ISO/WB/battery at the stream's own rate
///   (~30 Hz) at **zero additional bandwidth**.
/// * **It is the truth, not an echo.** Verified on hardware: after each
///   `*Set` command the corresponding field changes in the very next frames.
///   HTTP `200` alone proves nothing on this firmware, so this is a far better
///   basis for UI state than optimistic local updates.
/// * **`FnumberMin`/`FnumberMax` come for free**, letting the UI build a correct
///   aperture control without probing.
///
/// Verified against firmware DVR Ver1.42 on real hardware.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Decoded camera state, as carried inside live-view frames.
///
/// Fields are kept as strings because that is how the camera sends them — a
/// numeric parse would be lossy for values like `"1/30s"` and `"4:3"`.
class CameraState {
  final Map<String, String> raw;

  const CameraState(this.raw);

  /// Parse the state object out of a live-view parameter block.
  ///
  /// Returns `null` when no complete JSON object is present, which happens if
  /// the block layout ever changes.  Brace matching is used rather than
  /// searching for the last `}` so trailing padding cannot truncate the object.
  static CameraState? fromParameterBlock(Uint8List block) {
    final start = block.indexOf(0x7B); // '{'
    if (start < 0) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < block.length; i++) {
      final c = block[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == 0x5C) {
          escaped = true;
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      if (c == 0x22) {
        inString = true;
      } else if (c == 0x7B) {
        depth++;
      } else if (c == 0x7D) {
        depth--;
        if (depth == 0) {
          try {
            final decoded = jsonDecode(utf8.decode(block.sublist(start, i + 1)));
            if (decoded is Map) {
              return CameraState(decoded.map(
                  (k, v) => MapEntry(k.toString(), v?.toString() ?? '')));
            }
          } on Object {
            return null;
          }
          return null;
        }
      }
    }
    return null;
  }

  // --- control state -------------------------------------------------------

  /// `Auto`, `P`, `A`, `S`, `M`, `C`.
  String get exposureMode => raw['ExposureMode'] ?? '';

  /// `Multi`, `Spot`, `CenterWeighted`.
  String get meteringMode => raw['MeteringMode'] ?? '';

  /// The `ImageQuality` step, e.g. `50`, `20`, `8`, `VGA`.
  String get imageQuality => raw['ImageQuality'] ?? '';

  /// `4:3`, `3:2`, `16:9`, `1:1`.
  String get imageAspect => raw['ImageAspect'] ?? '';

  /// `Single`, `Continuous`, `2SDelay`, `10SDelay`.
  String get driveMode => raw['DriveMode'] ?? '';

  /// `RAW`, `RAWJ-S`, `RAWJ-M`, `RAWJ-L`, `JPG-S`, `JPG-M`, `JPG-L`.
  String get fileFormat => raw['FileFormat'] ?? '';

  /// `S-AF`, `C-AF`, `MF`.
  String get focusMode => raw['FocusMode'] ?? '';

  /// `Standard`, `Portrait`, `Vivid`, `NaturalBW`, `HContrastBW`.
  String get colorMode => raw['ColorMode'] ?? '';

  String get whiteBalance => raw['WB'] ?? '';

  /// `Auto` or a numeric ISO.
  String get isoSetting => raw['ISOSetting'] ?? '';

  /// The ISO the camera actually chose.  Only meaningful in auto ISO — and it is
  /// the only way to show the user what auto ISO picked, since no HTTP command
  /// reports it.
  String get isoAutoValue => raw['ISOAutoValue'] ?? '';

  /// e.g. `1/30s`.
  String get shutterSpeed => raw['ShutterSpeed'] ?? '';

  /// e.g. `1.7`.
  String get fNumber => raw['Fnumber'] ?? '';

  /// The lens's aperture range.  Free, and saves probing.
  String get fNumberMin => raw['FnumberMin'] ?? '';
  String get fNumberMax => raw['FnumberMax'] ?? '';

  /// e.g. `0.0`, `+1.0`.
  String get exposureCompensation => raw['EV'] ?? '';

  /// Seconds of self-timer delay.
  String get delayShootCount => raw['DelayShootCnt'] ?? '';

  // --- status --------------------------------------------------------------

  /// Percent, as a string.
  String get batteryLevel => raw['BatteryLevel'] ?? '';

  /// Remaining shots on the card.
  String get surplusPhotoCounts => raw['SurplusPhotoCnts'] ?? '';

  /// `0` disconnected, `1` automatic, `2` manual, `3` unknown.
  String get lensStatus => raw['LensStatus'] ?? '';

  // --- video ---------------------------------------------------------------

  String get videoFormat => raw['VideoFormat'] ?? '';
  String get videoAudioSwitch => raw['VASwitch'] ?? '';
  String get videoAudioVolume => raw['VAVol'] ?? '';
  String get videoNoiseReduction => raw['VANR'] ?? '';
  String get videoEis => raw['VideoEis'] ?? '';

  /// True when the lens is attached and talking.
  bool get hasLens => lensStatus == '1' || lensStatus == '2';

  /// Numeric battery percentage, or null when unparseable.
  ///
  /// **Unchanged by the charging fact below**, on purpose: this parses `101` into
  /// `101` and clamps nothing, so every consumer keeps seeing exactly what the camera
  /// sent. Making `isCharging` clamp this instead would be the silent `100%` the
  /// maintainer ruled out.
  int? get batteryPercent => int.tryParse(batteryLevel);

  /// The reading that means "on external power" rather than a percentage.
  ///
  /// `101` **exactly**, not a threshold. The camera's own official app tests equality,
  /// and rejects anything higher before it can reach its UI —
  /// `app/re/jadx-out/sources/com/xiaoyi/mirrorlesscamera/view/CustomBatteryLoading.java`:
  /// `handleMessage` tests `f14980c == 101` to draw
  /// `camera_liveview_statusbar_battery_charging`, and `setProgress` returns early for
  /// `i > 101 || i < 0`.
  static const int kBatteryChargingReading = 101;

  /// True when the camera is on external power and says so instead of giving a
  /// percentage.
  ///
  /// ## Two independent sources, and they say different things
  ///
  /// **Measured, on this body** — the maintainer's controlled pair: on the charger
  /// `BatteryLevel` reads `101`, and unplugging it and reading again gives `75`
  /// (`analysis/67` §7.3). Earlier readings of `100`, `75` and `50` were all taken
  /// unplugged, and `101` has only ever been seen on charge. That is what the value
  /// **correlates with**.
  ///
  /// **Stated by the manufacturer's own code** — the official app draws the drawable
  /// literally named `…_battery_charging` for exactly `101`, and empties the level
  /// instead of drawing one (`CustomBatteryLoading.java` lines 50-54). That is what the
  /// value **means**, and it is why this test is equality rather than "above 100":
  /// `setProgress` in the same class rejects any reading above `101` outright, so a
  /// `102` is not a charge state the camera's own client recognises at all.
  ///
  /// ## What is still not measured
  ///
  /// Whether the body reports `101` at every charge level, and what a partly charged
  /// one reports — the pair is one observation plus the manufacturer's constant. And
  /// this app, unlike the official one, does not reject an out-of-range reading: a
  /// `102` would draw as `102%` rather than being claimed as charging, which is the
  /// honest outcome for a value neither source explains.
  ///
  /// [batteryPercent] is untouched — this parses and clamps nothing — so nothing
  /// downstream of the raw reading changes meaning.
  ///
  /// Both draw sites (`_SideState`, `_StateStrip`) read this rather than comparing the
  /// reading themselves, so they cannot disagree and a third site cannot invent a third
  /// answer.
  bool get isCharging => batteryPercent == kBatteryChargingReading;

  /// True when auto ISO is active.
  bool get isAutoIso => isoSetting.toLowerCase() == 'auto';

  /// The aperture range the lens supports, in f-stops, when both are numeric.
  (double, double)? get apertureRange {
    final lo = double.tryParse(fNumberMin);
    final hi = double.tryParse(fNumberMax);
    if (lo == null || hi == null) return null;
    return (lo, hi);
  }

  /// Fields that differ from [other] — used to drive a UI diff, and to confirm a
  /// command actually landed rather than trusting an HTTP 200.
  Map<String, (String, String)> diffFrom(CameraState other) {
    final out = <String, (String, String)>{};
    for (final e in raw.entries) {
      final was = other.raw[e.key];
      if (was != null && was != e.value) out[e.key] = (was, e.value);
    }
    return out;
  }

  /// The state field holding the current value of [command], or null.
  ///
  /// The value the UI should draw beside a control: for `RCISOSet` this is
  /// `raw['ISOSetting']`, which is the same `isoSetting` accessor a widget would use.
  String? valueForParamCommand(String command) {
    final key = paramStateKeys[command];
    return key == null ? null : raw[key];
  }

  @override
  String toString() => 'CameraState(${raw.length} fields, '
      'mode=$exposureMode iso=$isoSetting $shutterSpeed f/$fNumber '
      'battery=$batteryLevel%)';
}

/// Where a parameter command's **result** appears in the live-view state JSON.
///
/// ## Why this table has to exist
///
/// There are two wire vocabularies for the same thirteen parameters and they are **not
/// the same strings**: the outbound `*Set` request carries a key this app chooses
/// (`AppState.paramCommands`), and the inbound state block carries the firmware's own
/// field name. For twelve of the thirteen they coincide, which is exactly what makes the
/// thirteenth dangerous:
///
/// | command | key sent | field read back |
/// |---|---|---|
/// | `RCISOSet` | `ISO` | **`ISOSetting`** |
/// | the other twelve | e.g. `WB`, `EV`, `Fnumber` | the same string |
///
/// `analysis/79` #8: nothing pinned the two, so the pair lived in two files
/// (`AppState.paramCommands` and a `switch` in `live_view_page.dart`) with no check
/// relating them. A typo on either side is silent in the worst way — the request is still
/// sent and the camera still answers `200`, and only the *displayed* value goes blank,
/// which reads as "the camera refused" rather than "this app looks in the wrong field".
///
/// So the read side is one declared table, keyed by the same command strings, and
/// `verify_transport.dart` asserts three things about it against the **recorded** block
/// from the hardware (not against this file): the two tables have the same keys, every
/// field name here occurs in the real block, and two commands never claim one field.
///
/// Twelve of these are the firmware's own names, taken from the JSON in the library
/// comment above and confirmed against `testdata/params_*.bin`. `ISOSetting` is the one
/// worth reading twice.
const Map<String, String> paramStateKeys = <String, String>{
  'RCSwitchDialMode': 'ExposureMode',
  'RCMeteringModeSet': 'MeteringMode',
  'RCFocusModeSet': 'FocusMode',
  'RCImageQualitySet': 'ImageQuality',
  'RCImageAspect': 'ImageAspect',
  'RCFileFormatSet': 'FileFormat',
  'RCDriveModeSet': 'DriveMode',
  'RCFNSet': 'Fnumber',
  'RCShutterSpeedSet': 'ShutterSpeed',
  'RCEVSet': 'EV',
  'RCISOSet': 'ISOSetting',
  'RCWBSet': 'WB',
  'RCChooseColorMode': 'ColorMode',
};
