/// The language picker.
///
/// ## Where it lives, and why
///
/// It is opened from **Settings → System and diagnostics → Language**
/// (`ValueKey('setting-locale')`, the row added to the settings catalog in
/// `lib/protocol/settings_menu.dart`). It is a dialog rather than a dropdown in the
/// row because the row lives inside a scrolling, `FittedBox`-scaled panel whose
/// width budget is already tight — `analysis/55` measured the readout band down to
/// 9.4 dp of legibility — and a dropdown menu drawn at natural size inside that
/// panel is what overflowed the app bar once already.
///
/// ## What it changes
///
/// `AppState.localeTag`, which persists through the existing `UiPrefs` file and
/// reaches `MaterialApp.locale`. No restart, no confirmation: the frame after the tap
/// is already in the chosen language, which is the only honest way to offer the
/// choice — a user who picks 简体中文 and sees English until the next launch cannot
/// tell whether the setting worked.
///
/// ## Why "Follow the phone" is first and is the default
///
/// This is a Chinese camera and a Chinese-speaking maintainer, but the phone is the
/// authority on which language its owner reads: a user whose phone is in English and
/// who never opens this dialog must not be handed Chinese. So the stored default is
/// [kLocaleSystem] and `MaterialApp.locale` is left null, which is what makes
/// Flutter resolve against the device's own preference list.
library;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Opens the language picker. Returns after the dialog is dismissed.
Future<void> showLocalePicker(
  BuildContext context, {
  required String current,
  required ValueChanged<String> onChosen,
}) {
  final l = l10nOf(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey<String>('locale-picker'),
      title: Text(l.localePickerTitle),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: RadioGroup<String>(
        groupValue: current,
        onChanged: (v) {
          if (v != null) onChosen(v);
          Navigator.of(ctx).pop();
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final tag in kSelectableLocaleTags)
              RadioListTile<String>(
                key: ValueKey<String>('locale-option-$tag'),
                value: tag,
                dense: true,
                title: Text(localeTagName(l, tag)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                l.localePickerNote,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey<String>('btn-locale-cancel'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l.cancel),
        ),
      ],
    ),
  );
}

/// How a stored tag reads in the picker.
///
/// The two languages are named **in themselves** — English is "English" and Chinese
/// is "简体中文" in both locales — because a language list written in a language the
/// reader cannot read is the one place where a translation is worse than nothing. A
/// user looking for Chinese in an English UI is looking for the glyphs 简体中文.
String localeTagName(AppLocalizations l, String tag) => switch (tag) {
      kLocaleSystem => l.localeSystem,
      kLocaleEnglish => l.localeEnglish,
      kLocaleChinese => l.localeChinese,
      _ => tag,
    };
