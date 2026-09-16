// GENERATED FILE - DO NOT EDIT BY HAND.
//
// The enum member names below deliberately mirror the camera's own wire values
// (`Manual`, `Auto`, `Vivid`, …) so that the code reads like the protocol and a
// typo is visible against the firmware's value tables.  That conflicts with
// Dart's naming lints, so those two rules are silenced for this file only —
// renaming the members would break the correspondence the file exists to
// capture.
// ignore_for_file: constant_identifier_names, camel_case_types

//
// Derived from the camera's own value tables and from the community
// reverse-engineering project bullbin/xiaoyi_m1_re_liveview (MIT).  The
// generation script and its inputs are not part of this repository.


/// Parameter values accepted by the camera's RC commands.
///
/// Each enum's wire value is the string the camera expects; use `.value`.
library;

/// Values for the corresponding RC parameter.
enum rcLensStatus {
  Disconnected('0'),
  Automatic('1'),
  Manual('2'),
  Unknown('3')
  ;

  const rcLensStatus(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcMeteringMode {
  Multi('Multi'),
  Spot('Spot'),
  CenterWeighted('CenterWeighted')
  ;

  const rcMeteringMode(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcExposureMode {
  Auto('Auto'),
  Program('P'),
  AperturePriority('A'),
  ShutterPriority('S'),
  Manual('M'),
  MasterGuide('C')
  ;

  const rcExposureMode(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcFocusMode {
  ContrastAutofocus('C-AF'),
  SingleAreaAutofocus('S-AF'),
  ManualFocus('MF')
  ;

  const rcFocusMode(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcTriggerFocusMode {
  Auto('Auto'),
  Manual('Manual')
  ;

  const rcTriggerFocusMode(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcImageQuality {
  MP50_Interpolated('50'),
  MP20('20'),
  MP16('16'),
  MP8('8'),
  MP3('3'),
  VGA('VGA')
  ;

  const rcImageQuality(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcImageAspect {
  A43('4:3'),
  A32('3:2'),
  Widescreen('16:9'),
  Square('1:1')
  ;

  const rcImageAspect(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcFileFormat {
  Raw('RAW'),
  JpegSmall('JPG-S'),
  JpegMedium('JPG-M'),
  JpegLarge('JPG-L'),
  RawAndJpegSmall('RAWJ-S'),
  RawAndJpegMedium('RAWJ-M'),
  RawAndJpegLarge('RAWJ-L')
  ;

  const rcFileFormat(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcDriveMode {
  Single('Single'),
  Continuous('Continuous'),
  Delay2('2SDelay'),
  Delay10('10SDelay')
  ;

  const rcDriveMode(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcFStop {
  F1p0('1.0'),
  F1p2('1.2'),
  F1p4('1.4'),
  F1p7('1.7'),
  F1p8('1.8'),
  F2p0('2.0'),
  F2p2('2.2'),
  F2p5('2.5'),
  F2p8('2.8'),
  F3p2('3.2'),
  F3p5('3.5'),
  F4p0('4.0'),
  F4p5('4.5'),
  F5p0('5.0'),
  F5p6('5.6'),
  F6p3('6.3'),
  F7p1('7.1'),
  F8p0('8.0'),
  F9p0('9.0'),
  F10('10'),
  F11('11'),
  F13('13'),
  F14('14'),
  F16('16'),
  F18('18'),
  F20('20'),
  F22('22'),
  F25('25'),
  F29('29'),
  F32('32')
  ;

  const rcFStop(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcIso {
  Auto('Auto'),
  I100('100'),
  I200('200'),
  I400('400'),
  I800('800'),
  I1600('1600'),
  I3200('3200'),
  I6400('6400'),
  I12800('12800'),
  I25600('25600')
  ;

  const rcIso(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcWhiteBalance {
  Auto('Auto'),
  Sunny('Sunny'),
  Cloudy('Cloudy'),
  Shadow('Shadow'),
  Incandescent('Incandescent'),
  K2000('2000'),
  K2050('2050'),
  K2100('2100'),
  K2150('2150'),
  K2200('2200'),
  K2250('2250'),
  K2300('2300'),
  K2350('2350'),
  K2400('2400'),
  K2450('2450'),
  K2500('2500'),
  K2550('2550'),
  K2600('2600'),
  K2650('2650'),
  K2700('2700'),
  K2750('2750'),
  K2800('2800'),
  K2850('2850'),
  K2900('2900'),
  K2950('2950'),
  K3000('3000'),
  K3100('3100'),
  K3200('3200'),
  K3300('3300'),
  K3400('3400'),
  K3500('3500'),
  K3600('3600'),
  K3700('3700'),
  K3800('3800'),
  K3900('3900'),
  K4000('4000'),
  K4200('4200'),
  K4400('4400'),
  K4600('4600'),
  K4800('4800'),
  K5000('5000'),
  K5200('5200'),
  K5400('5400'),
  K5600('5600'),
  K5800('5800'),
  K6000('6000'),
  K6200('6200'),
  K6400('6400'),
  K6600('6600'),
  K6800('6800'),
  K7000('7000'),
  K7500('7500'),
  K8000('8000'),
  K8500('8500'),
  K9000('9000'),
  K9500('9500'),
  K10000('10000'),
  K10500('10500'),
  K11000('11000'),
  K11500('11500')
  ;

  const rcWhiteBalance(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcShutterSpeed {
  Time('TIME'),
  Bulb('BULB'),
  S60('60s'),
  S50('50s'),
  S40('40s'),
  S30('30s'),
  S25('25s'),
  S20('20s'),
  S15('15s'),
  S13('13s'),
  S10('10s'),
  S8('8s'),
  S6('6s'),
  S5('5s'),
  S4('4s'),
  S3p2('3.2s'),
  S2p5('2.5s'),
  S2('2s'),
  S1p6('1.6s'),
  S1p3('1.3s'),
  S1('1s'),
  SF1p3('1/1.3s'),
  SF1p6('1/1.6s'),
  SF2('1/2s'),
  SF2p5('1/2.5s'),
  SF3('1/3s'),
  SF4('1/4s'),
  SF5('1/5s'),
  SF6('1/6s'),
  SF8('1/8s'),
  SF10('1/10s'),
  SF13('1/13s'),
  SF15('1/15s'),
  SF20('1/20s'),
  SF25('1/25s'),
  SF30('1/30s'),
  SF40('1/40s'),
  SF50('1/50s'),
  SF60('1/60s'),
  SF80('1/80s'),
  SF100('1/100s'),
  SF125('1/125s'),
  SF160('1/160s'),
  SF200('1/200s'),
  SF250('1/250s'),
  SF320('1/320s'),
  SF400('1/400s'),
  SF500('1/500s'),
  SF640('1/640s'),
  SF800('1/800s'),
  SF1000('1/1000s'),
  SF1250('1/1250s'),
  SF1600('1/1600s'),
  SF2000('1/2000s'),
  SF2500('1/2500s'),
  SF3200('1/3200s'),
  SF4000('1/4000s')
  ;

  const rcShutterSpeed(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcColorStyle {
  Standard('Standard'),
  Portrait('Portrait'),
  Vivid('Vivid'),
  NaturalBW('NaturalBW'),
  HighContrastBW('HContrastBW')
  ;

  const rcColorStyle(this.value);
  final String value;
}

/// Values for the corresponding RC parameter.
enum rcEvOffset {
  N5p0('-5.0'),
  N4p7('-4.7'),
  N4p3('-4.3'),
  N4p0('-4.0'),
  N3p7('-3.7'),
  N3p3('-3.3'),
  N3p0('-3.0'),
  N2p7('-2.7'),
  N2p3('-2.3'),
  N2p0('-2.0'),
  N1p7('-1.7'),
  N1p3('-1.3'),
  N1p0('-1.0'),
  N0p7('-0.7'),
  N0p3('-0.3'),
  Zero('0.0'),
  P0p3('0.3'),
  P0p7('0.7'),
  P1p0('1.0'),
  P1p3('1.3'),
  P1p7('1.7'),
  P2p0('2.0'),
  P2p3('2.3'),
  P2p7('2.7'),
  P3p0('3.0'),
  P3p3('3.3'),
  P3p7('3.7'),
  P4p0('4.0'),
  P4p3('4.3'),
  P4p7('4.7'),
  P5p0('5.0')
  ;

  const rcEvOffset(this.value);
  final String value;
}

/// Every enum above, keyed by the wire value it carries, so a UI can
/// render a picker from a pool without hardcoding the lists again.
const Map<String, List<String>> kRcValuePools = {
  'lensStatus': <String>['0', '1', '2', '3'],
  'meteringMode': <String>['Multi', 'Spot', 'CenterWeighted'],
  'exposureMode': <String>['Auto', 'P', 'A', 'S', 'M', 'C'],
  'focusMode': <String>['C-AF', 'S-AF', 'MF'],
  'triggerFocusMode': <String>['Auto', 'Manual'],
  'imageQuality': <String>['50', '20', '16', '8', '3', 'VGA'],
  'imageAspect': <String>['4:3', '3:2', '16:9', '1:1'],
  'fileFormat': <String>['RAW', 'JPG-S', 'JPG-M', 'JPG-L', 'RAWJ-S', 'RAWJ-M', 'RAWJ-L'],
  'driveMode': <String>['Single', 'Continuous', '2SDelay', '10SDelay'],
  'fStop': <String>['1.0', '1.2', '1.4', '1.7', '1.8', '2.0', '2.2', '2.5', '2.8', '3.2', '3.5', '4.0', '4.5', '5.0', '5.6', '6.3', '7.1', '8.0', '9.0', '10', '11', '13', '14', '16', '18', '20', '22', '25', '29', '32'],
  'iso': <String>['Auto', '100', '200', '400', '800', '1600', '3200', '6400', '12800', '25600'],
  'whiteBalance': <String>['Auto', 'Sunny', 'Cloudy', 'Shadow', 'Incandescent', '2000', '2050', '2100', '2150', '2200', '2250', '2300', '2350', '2400', '2450', '2500', '2550', '2600', '2650', '2700', '2750', '2800', '2850', '2900', '2950', '3000', '3100', '3200', '3300', '3400', '3500', '3600', '3700', '3800', '3900', '4000', '4200', '4400', '4600', '4800', '5000', '5200', '5400', '5600', '5800', '6000', '6200', '6400', '6600', '6800', '7000', '7500', '8000', '8500', '9000', '9500', '10000', '10500', '11000', '11500'],
  'shutterSpeed': <String>['TIME', 'BULB', '60s', '50s', '40s', '30s', '25s', '20s', '15s', '13s', '10s', '8s', '6s', '5s', '4s', '3.2s', '2.5s', '2s', '1.6s', '1.3s', '1s', '1/1.3s', '1/1.6s', '1/2s', '1/2.5s', '1/3s', '1/4s', '1/5s', '1/6s', '1/8s', '1/10s', '1/13s', '1/15s', '1/20s', '1/25s', '1/30s', '1/40s', '1/50s', '1/60s', '1/80s', '1/100s', '1/125s', '1/160s', '1/200s', '1/250s', '1/320s', '1/400s', '1/500s', '1/640s', '1/800s', '1/1000s', '1/1250s', '1/1600s', '1/2000s', '1/2500s', '1/3200s', '1/4000s'],
  'colorStyle': <String>['Standard', 'Portrait', 'Vivid', 'NaturalBW', 'HContrastBW'],
  'evOffset': <String>['-5.0', '-4.7', '-4.3', '-4.0', '-3.7', '-3.3', '-3.0', '-2.7', '-2.3', '-2.0', '-1.7', '-1.3', '-1.0', '-0.7', '-0.3', '0.0', '0.3', '0.7', '1.0', '1.3', '1.7', '2.0', '2.3', '2.7', '3.0', '3.3', '3.7', '4.0', '4.3', '4.7', '5.0'],
};

// ---------------------------------------------------------------------------
// Convenience handles onto [kRcValuePools].
//
// These are getters rather than duplicated `const` lists: the pools above are
// generated from the firmware's own value tables, and a second hand-maintained
// copy would be one more thing to drift.  A typo'd key fails loudly at first
// access instead of silently returning an empty picker.
// ---------------------------------------------------------------------------

List<String> _pool(String key) {
  final v = kRcValuePools[key];
  if (v == null) throw ArgumentError('no such RC value pool: $key');
  return v;
}

/// `Auto`, `P`, `A`, `S`, `M`, `C` — the `DialMode` values.
List<String> get kExposureModes => _pool('exposureMode');

/// `Multi`, `Spot`, `CenterWeighted`.
List<String> get kMeteringModes => _pool('meteringMode');

/// `C-AF`, `S-AF`, `MF`.
List<String> get kFocusModes => _pool('focusMode');

/// `50`, `20`, `16`, `8`, `3`, `VGA`.
List<String> get kImageQualities => _pool('imageQuality');

/// `4:3`, `3:2`, `16:9`, `1:1`.
List<String> get kImageAspects => _pool('imageAspect');

/// `RAW`, `JPG-S`…`RAWJ-L`.
List<String> get kFileFormats => _pool('fileFormat');

/// `Single`, `Continuous`, `2SDelay`, `10SDelay`.
List<String> get kDriveModes => _pool('driveMode');

/// Every f-stop the firmware knows; the UI narrows this to the attached lens.
List<String> get kFNumbers => _pool('fStop');

/// `Auto` plus the numeric ISO steps.
List<String> get kIsoValues => _pool('iso');

/// Named presets plus the numeric Kelvin ladder.
List<String> get kWbValues => _pool('whiteBalance');

/// `TIME`, `BULB`, then the exposure ladder.
List<String> get kShutterSpeeds => _pool('shutterSpeed');

/// The five picture styles the camera accepts.
///
/// Verified on hardware that `RCChooseColorMode` takes exactly these; the
/// imaging layer internally spells one of them `HighContrastBW` while the HTTP
/// side says `HContrastBW`, and only the HTTP spelling is accepted here.
List<String> get kColorModes => _pool('colorStyle');

/// Exposure compensation ladder.
List<String> get kEvValues => _pool('evOffset');

/// The recording-volume steps the client offers for `RCVAVolSet` (`Vol`).
///
/// **Not a firmware pool**, which is why it is hand-written while everything
/// above is generated. The firmware has no `Vol` value table at all: its own
/// volume readout is a `VOL %03d` format string, so the protocol states no bound
/// and there is nothing for the generator to emit.
///
/// `5` is the camera's factory default — observed as `"VAVol":"5"` in the
/// live-view state JSON (see `protocol/camera_state.dart`) — and `0` is silence.
/// The steps in between exist so the control has something to select; a camera
/// that refuses one answers 404, which the UI reports rather than swallowing.
const List<int> kAudioVolumes = <int>[0, 1, 2, 3, 4, 5];
