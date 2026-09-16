/// Display labels for the camera's own parameter values.
///
/// ## The rule this file exists to keep
///
/// The value pools in `lib/protocol/http_params.dart` are the firmware's **wire
/// vocabulary**: `Single`, `Continuous`, `Multi`, `C-AF`, `Sunny`, `JPG-S`. The
/// camera parses those exact strings, so they must be sent verbatim — a "translated"
/// value would be a 404 at best, and the album's delete path already carries a
/// comment about what this firmware does with a request shape it does not expect.
///
/// So the translation happens **only at the point of display**, keyed by the wire
/// value, exactly like [UiMessage] and the settings catalog: the wire value is the
/// code, the label is what the user reads, and there is no path from a label back
/// into a request. [paramLabel] returns a [String] and nothing here can be handed to
/// `AppState.setParam`, which takes the pool value the user picked from the list.
///
/// ## What is deliberately *not* translated
///
/// The numeric ladders — `f/2.8`, `1/250s`, `ISO 1600`, `-0.7`, `5600`, `4:3` — are
/// the same in every camera UI and in every language; a Chinese photographer reads
/// `1/250s` and `f/2.8` exactly as an English one does. Translating them would be
/// noise, and worse, it would put a mapping between the number and the request where
/// none is needed.
library;

import '../protocol/viewfinder_layout.dart' show compactReadoutValue;
import 'l10n.dart';

/// Pool values that carry a word but are shown verbatim in every language.
///
/// Only acronyms the camera industry prints in Latin script in Chinese menus too.
/// Kept as one entry with a name, so the "does every named value have a label?" check
/// has an explicit answer rather than a regex that quietly excludes things.
const Set<String> kVerbatimWireValues = <String>{
  /// The raw-image format. 中文相机菜单同样写 RAW.
  'RAW',
};

/// Every wire value [paramLabel] has a label for.
///
/// Compared against the pools in `lib/protocol/http_params.dart` by
/// `test/l10n_message_codes_test.dart`, so a value added to a pool is a decision about
/// how it reads rather than a string that quietly stays English. The numeric ladders
/// are excluded there by the same rule the file's library comment states: a value with
/// no run of two or more Latin letters is a measurement, not a word.
const Set<String> kLabelledWireValues = <String>{
  'Auto',
  'Manual',
  'Multi',
  'Spot',
  'CenterWeighted',
  'C-AF',
  'S-AF',
  'MF',
  'Single',
  'Continuous',
  '2SDelay',
  '10SDelay',
  'Sunny',
  'Cloudy',
  'Shadow',
  'Incandescent',
  'Standard',
  'Portrait',
  'Vivid',
  'NaturalBW',
  'HContrastBW',
  'TIME',
  'BULB',
  'VGA',
  'JPG-S',
  'JPG-M',
  'JPG-L',
  'RAWJ-S',
  'RAWJ-M',
  'RAWJ-L',
};

/// How [wire] reads on screen.
///
/// Anything not in [kLabelledWireValues] is returned unchanged — which is the
/// correct answer for every numeric ladder, and a legible answer for a value this
/// build has never seen (a newer firmware's pool entry shows as itself rather than
/// as a blank).
///
/// `Auto` is ambiguous on purpose: it is the metering pool's, the exposure mode
/// pool's, the ISO pool's and the white balance pool's word for four different
/// things, and it reads as 自动 in all four. Splitting it per pool would mean a
/// per-pool lookup for one shared word.
String paramLabel(AppLocalizations l, String wire) => switch (wire) {
      'Auto' => l.paramAuto,
      'Manual' => l.paramManual,
      'Multi' => l.paramMulti,
      'Spot' => l.paramSpot,
      'CenterWeighted' => l.paramCenterWeighted,
      'C-AF' => l.paramCAF,
      'S-AF' => l.paramSAF,
      'MF' => l.paramMF,
      'Single' => l.paramSingle,
      'Continuous' => l.paramContinuous,
      '2SDelay' => l.paramDelay2s,
      '10SDelay' => l.paramDelay10s,
      'Sunny' => l.paramSunny,
      'Cloudy' => l.paramCloudy,
      'Shadow' => l.paramShadow,
      'Incandescent' => l.paramIncandescent,
      'Standard' => l.paramStandard,
      'Portrait' => l.paramPortrait,
      'Vivid' => l.paramVivid,
      'NaturalBW' => l.paramNaturalBw,
      'HContrastBW' => l.paramHighContrastBw,
      'TIME' => l.paramTime,
      'BULB' => l.paramBulb,
      'VGA' => l.paramVga,
      'JPG-S' => l.paramJpgSmall,
      'JPG-M' => l.paramJpgMedium,
      'JPG-L' => l.paramJpgLarge,
      'RAWJ-S' => l.paramRawJpgSmall,
      'RAWJ-M' => l.paramRawJpgMedium,
      'RAWJ-L' => l.paramRawJpgLarge,
      _ => wire,
    };

/// How a value reads in the **narrow readout column**.
///
/// ## Why this is not just [paramLabel]
///
/// `compactReadoutValue` in `lib/protocol/viewfinder_layout.dart` exists to shorten
/// four long English words — `Incandescent` → `Incand.`, `Standard` → `Std.`,
/// `Portrait` → `Port.`, `NaturalBW` → `Nat-BW`, `HContrastBW` → `HC-BW` — so the
/// readout column fits the width budget `analysis/55` measured. Its map is keyed by
/// the **wire value** and `test/readout_legibility_test.dart` asserts it is injective
/// over the firmware's pools, which makes it correct exactly for the language those
/// words are in.
///
/// Applying it to a translated label would therefore be mapping English words onto
/// English words: `paramLabel(zh, 'Incandescent')` is 白炽灯, and `compactReadoutValue`
/// would either leave it alone or — worse — replace it with `Incand.` if the lookup
/// were done on the wrong key. So the short form is used **only when this locale shows
/// the firmware's own word** (`label == wire`, which is English for all five entries),
/// and a translated label is used as it stands. Those labels are shorter than the
/// English ones they replace, so the column gains room rather than losing it; if that
/// ever stops being true, `readout_legibility_test.dart` measures dp, not words, and
/// will say so.
String readoutWord(AppLocalizations l, String wire) {
  final label = paramLabel(l, wire);
  return label == wire ? compactReadoutValue(wire) : label;
}
