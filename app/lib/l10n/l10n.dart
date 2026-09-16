/// Localization entry points.
///
/// ## Why this file exists next to the generated one
///
/// `flutter gen-l10n` writes `gen/app_localizations.dart` and one file per locale.
/// Those are generated: nothing in them should be hand-edited, and they know
/// nothing about this app's own choices — which languages are selectable, how a
/// stored preference tag becomes a `Locale`, and how a message raised by a
/// Flutter-free layer is resolved. That is what this file is for.
///
/// Import `l10n.dart`, not `gen/app_localizations.dart`, so there is one import
/// path and one place where the generated API is re-exported.
library;

import 'package:flutter/widgets.dart';

import '../sync/ui_prefs.dart';
import 'gen/app_localizations.dart';
import 'gen/app_localizations_en.dart';
import 'gen/app_localizations_zh.dart';

export 'gen/app_localizations.dart';

// The stored language tags ride along with the l10n API: a caller that renders a
// locale almost always also needs to name one, and making that a second import is how
// a widget ends up comparing against a hand-written `'zh'` literal.
export '../sync/ui_prefs.dart'
    show kLocaleSystem, kLocaleEnglish, kLocaleChinese, kLocaleTags;

/// The localization bundle for [context].
///
/// A named function rather than `AppLocalizations.of(context)` at every call site,
/// so a page has one import and one idiom — and so the day the generated getter
/// changes shape there is one line to fix instead of two hundred.
AppLocalizations l10nOf(BuildContext context) => AppLocalizations.of(context);

/// Turn a stored preference tag into the `Locale?` a `MaterialApp` takes.
///
/// `null` is load-bearing: it is how `MaterialApp` is told "no opinion — use the
/// phone's own locale list". Returning `Locale('en')` for [kLocaleSystem] would
/// silently pin every device to English, which is precisely the defect this round
/// exists to remove, and it would look like it worked on the developer's phone.
Locale? localeFromTag(String tag) => switch (tag) {
      kLocaleEnglish => const Locale(kLocaleEnglish),
      kLocaleChinese => const Locale(kLocaleChinese),
      _ => null,
    };

/// The tag for a `Locale`, for showing which language is currently chosen.
///
/// The inverse of [localeFromTag] for the tags this app stores. A locale this app
/// has no strings for reduces to its language subtag, so `zh_Hant_TW` reports as
/// [kLocaleChinese] rather than as an unknown tag.
String tagFromLocale(Locale? locale) {
  if (locale == null) return kLocaleSystem;
  for (final tag in kLocaleTags) {
    if (tag != kLocaleSystem && tag == locale.languageCode) return tag;
  }
  return kLocaleSystem;
}

/// The English strings, for code that has no `BuildContext`.
///
/// Used by the resolution helper for the Flutter-free layers when the caller has no
/// ambient locale, and by the widget tests so a test asserts on the *same* string the
/// user reads rather than on a literal copied out of the ARB.
AppLocalizations get englishStrings => AppLocalizationsEn();

/// The Simplified Chinese strings, for the same reason as [englishStrings].
AppLocalizations get chineseStrings => AppLocalizationsZh();

/// Every locale this build ships strings for, in the order the picker shows them.
///
/// Not `AppLocalizations.supportedLocales`, which the generator orders
/// alphabetically: the picker puts the language the app is written for first, and
/// "follow the phone" above both. Asserted by `test/l10n_arb_test.dart`.
const List<String> kSelectableLocaleTags = <String>[
  kLocaleSystem,
  kLocaleChinese,
  kLocaleEnglish,
];
