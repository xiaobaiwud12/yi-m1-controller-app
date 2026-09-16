import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// Checks on the ARB files themselves.
///
/// ## Why these and not `gen-l10n`'s own report
///
/// `flutter gen-l10n` writes `l10n_untranslated.json` and prints a summary, and that
/// is useful — but it only checks *presence*. It does not check that a Chinese value
/// is Chinese, and it does not notice a translation that is the English string with a
/// key next to it. Both are exactly what "a half-extracted app is worse than an
/// untranslated one" means at the file level, so they are asserted here instead of
/// assumed from a generator's exit code.
///
/// The report file is still checked, because the generator's notion of "translated"
/// and a reader's are different: an empty string counts as translated to the tool.
void main() {
  final dir = Directory('lib/l10n');
  final en = _arb(File('${dir.path}/app_en.arb'));
  final zh = _arb(File('${dir.path}/app_zh.arb'));

  /// Keys whose value is legitimately the same in both languages: brand marks,
  /// firmware vocabulary and pure format strings. Anything else that matches English
  /// is untranslated text wearing a translation's clothes.
  ///
  /// Kept short and explicit on purpose — this list is the *only* place a
  /// same-as-English value is allowed, so adding to it is a decision rather than an
  /// accident. `test/l10n_arb_test.dart` proves the check can fail by feeding it a
  /// deliberately untranslated pair.
  const identicalAllowed = <String>{
    'albumRawJpgBadge',
    'albumRawBadge',
    'albumVideoBadge',
    'localeEnglish',
    'localeChinese',
    'paramTime',
    'paramVga',
    'readoutApertureValue',
    'diagAndroid',
    'liveFps',
    'liveDrawnOfReceivedFps',
    'readoutEvValue',
  };

  test('every key in the English template exists in Chinese', () {
    final missing = en.keys.where((k) => !zh.containsKey(k)).toList()..sort();
    expect(missing, isEmpty,
        reason: 'these keys would silently render English inside a Chinese UI: '
            '$missing');
  });

  test('every key in Chinese exists in the English template', () {
    final extra = zh.keys.where((k) => !en.containsKey(k)).toList()..sort();
    expect(extra, isEmpty,
        reason: 'a key with no English original is a translation of nothing — '
            'either the template lost it or this is a typo: $extra');
  });

  test('no value is empty in either language', () {
    for (final locale in <String, Map<String, String>>{'en': en, 'zh': zh}.entries) {
      final empty = locale.value.entries
          .where((e) => e.value.trim().isEmpty)
          .map((e) => e.key)
          .toList()
          ..sort();
      expect(empty, isEmpty,
          reason: 'gen-l10n counts these as translated; the user sees a blank '
              'label (${locale.key}): $empty');
    }
  });

  test('the Chinese file is not the English file with Chinese keys', () {
    final same = <String>[];
    for (final k in en.keys) {
      if (zh[k] == en[k] && !identicalAllowed.contains(k)) same.add(k);
    }
    same.sort();
    expect(same, isEmpty,
        reason: 'these read identically in both languages, which for everything '
            'outside $identicalAllowed means they were never translated: $same');
  });

  test('the identical-value allow-list has no stale entries', () {
    // A key that has since been translated must leave the list, or the list slowly
    // becomes a place where untranslated keys hide.
    final stale = identicalAllowed
        .where((k) => en.containsKey(k) && zh[k] != en[k])
        .toList()
      ..sort();
    expect(stale, isEmpty,
        reason: 'these are on the allow-list but are no longer identical — remove '
            'them so the list keeps meaning "deliberately the same": $stale');
  });

  test('every placeholder in a message is declared, and every declaration is used',
      () {
    // `gen-l10n` needs the declaration to type the argument, and an *undeclared*
    // `{name}` is worse than an error: it is emitted as a literal `{name}` in the
    // UI. A declaration with no matching `{name}` is the opposite rot — a parameter
    // the generated method demands and the sentence never uses.
    final raw =
        jsonDecode(File('${dir.path}/app_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    final problems = <String>[];
    for (final e in en.entries) {
      final used = _simplePlaceholders(e.value);
      final declared =
          ((raw['@${e.key}'] as Map?)?['placeholders'] as Map?)
                  ?.keys
                  .cast<String>()
                  .toSet() ??
              const <String>{};
      if (!declared.containsAll(used)) {
        problems.add('${e.key}: uses ${used.difference(declared)} with no '
            'declaration — gen-l10n emits those braces literally');
      }
      if (!used.containsAll(declared)) {
        problems.add('${e.key}: declares ${declared.difference(used)} but the '
            'sentence never uses it');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the generated untranslated report is empty', () {
    final report = File('l10n_untranslated.json');
    if (!report.existsSync()) {
      // Not a failure: the file only exists after `flutter gen-l10n` has run, and a
      // check that fails on a cold checkout teaches people to ignore it.
      return;
    }
    final decoded = jsonDecode(report.readAsStringSync());
    expect(decoded, isEmpty,
        reason: 'gen-l10n reported untranslated messages: $decoded');
  });

  test('the selectable locale tags match the compiled locales', () {
    final supported = AppLocalizations.supportedLocales
        .map((l) => l.languageCode)
        .toSet();
    final selectable = kSelectableLocaleTags
        .where((t) => t != kLocaleSystem)
        .toSet();
    expect(selectable, supported,
        reason: 'Settings offers $selectable and the build ships $supported');
  });

  test('the picker names each language in itself', () {
    // A language list written only in the current language is the one place where
    // translation hurts: someone looking for Chinese in an English UI looks for 简体中文.
    expect(chineseStrings.localeChinese, '简体中文');
    expect(chineseStrings.localeEnglish, 'English');
    expect(englishStrings.localeChinese, '简体中文');
    expect(englishStrings.localeEnglish, 'English');
  });
}

/// Flattens one ARB file, dropping the `@`-metadata and the `@@locale` header.
Map<String, String> _arb(File f) {
  final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, String>{};
  for (final e in raw.entries) {
    if (e.key.startsWith('@')) continue;
    out[e.key] = '${e.value}';
  }
  return out;
}

/// The simple `{name}` placeholders in [message], ignoring ICU plural bodies.
///
/// An ICU message is `{count, plural, =1{…} other{…}}`, and a naive `\{\w+` scan
/// reads the *branch text* as placeholders — it reported `{Share}` from "Share shot"
/// and `{1}` from "=1{1 shot…}". Those are not placeholders and gen-l10n rightly does
/// not want them declared, so the branches are walked and only the simple `{name}`
/// forms are collected.
Set<String> _simplePlaceholders(String message) {
  final found = <String>{};

  void walk(String s) {
    var i = 0;
    while (i < s.length) {
      if (s[i] != '{') {
        i++;
        continue;
      }
      // Find the matching close brace.
      var depth = 0;
      var j = i;
      while (j < s.length) {
        if (s[j] == '{') depth++;
        if (s[j] == '}') {
          depth--;
          if (depth == 0) break;
        }
        j++;
      }
      final inner = s.substring(i + 1, j.clamp(i + 1, s.length));
      if (RegExp(r'^\w+$').hasMatch(inner)) {
        found.add(inner);
      } else if (RegExp(r'^\w+,\s*(plural|select|selectordinal)\s*,')
          .hasMatch(inner)) {
        // The selector itself is a declared placeholder (`{count, plural, …}`
        // declares `count`), and the branches may hold more.
        found.add(inner.split(',').first.trim());
        walk(inner.substring(inner.indexOf(',', inner.indexOf(',') + 1)));
      }
      i = j + 1;
    }
  }

  walk(message);
  return found;
}
