import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/key_readers.dart';

/// Finding #18 of `analysis/79`: the localization mechanism has no key → call-site
/// direction, so a key that nothing reads is invisible in every existing check.
///
/// The scan lives in `lib/l10n/key_readers.dart` — one implementation, read here rather
/// than reimplemented — because the failure this project keeps shipping is *the test and
/// the code deriving the same answer from the same source and being wrong together*
/// (`analysis/79` header). This test owns only the assertions.
///
/// ## What each assertion is for
///
/// * `the scan read a real tree` and `the ARB really does declare hundreds of keys` are
///   the co-findings' own guard. `AGENTS.md` §8: a check that walked nothing looks
///   exactly like a check that found nothing, and this one would report "no dead keys"
///   for an empty tree.
/// * `no key is declared and never read` is the finding.
/// * `the generated class and the ARB agree` catches the other half of a stale
///   `gen-l10n`, which is what makes removing a dead key safe: delete it from the ARB,
///   regenerate, and the generated getter goes with it.
/// * the `readsKey` unit cases prove the scanner can fail. Without them a scanner that
///   returned `true` unconditionally would satisfy the whole file.
void main() {
  group('reading keys', () {
    // The scanner has to be able to say **no**. A member access counts, a mention in a
    // comment does not, a longer key is not a prefix match, and a key used as a map
    // string counts. Each of these has been a wrong answer at some point in this
    // project's checks; the third is the "the test reads the same source" shape in
    // miniature — `liveRetry` must not be satisfied by `liveRetryJoin`.
    test('a member access is a read', () {
      expect(readsKey('Text(l.liveRetry)', 'liveRetry'), isTrue);
      expect(readsKey('l.liveRetryJoin', 'liveRetry'), isFalse,
          reason: 'a longer name that starts with this one is not a read of it');
    });

    test('a string literal is a read, a comment is not', () {
      expect(readsKey("resolve('liveRetry')", 'liveRetry'), isTrue);
      expect(readsKey('/// see liveRetry for the wording', 'liveRetry'), isFalse,
          reason: 'a key named in prose is not a call site — otherwise the fix for a '
              'dead key would be to write its name in a comment');
      expect(readsKey('// l.liveRetry was removed\nvoid f() {}', 'liveRetry'),
          isFalse);
    });

    test('a URL inside a string literal does not swallow the rest of the line', () {
      // The comment stripper is a character walk because of this case: a regex that
      // stripped from `//` to end-of-line would delete `l.liveRetry` here and report a
      // live key as dead.
      expect(readsKey("const u = 'http://x'; Text(l.liveRetry)", 'liveRetry'),
          isTrue);
    });

    test('the ARB parser takes message keys and not placeholder names', () {
      // The fixture is shaped like the real file, and the trap is deliberate: a line
      // scan reports `count` here. The first version of the parser did exactly that —
      // 26 placeholder names came back as ARB keys.
      const fixture = <String>[
        '{',
        '  "@@locale": "en",',
        '  "liveRetry": "Retry",',
        '  "@liveRetry": {',
        '    "description": "note"',
        '  },',
        '  "localeSelected": "Selected: {name}",',
        '  "@localeSelected": {',
        '    "placeholders": {',
        '      "name": {"type": "String"}',
        '    }',
        '  }',
        '}',
      ];
      expect(arbKeysFromLines(fixture), {'liveRetry', 'localeSelected'});
    });

    test('the generated-name parser finds getters and methods', () {
      final names = generatedNamesFromLines(const [
        'abstract class AppLocalizations {',
        '  String get liveRetry;',
        '  String localeSelected(String name);',
        '  String get diagUnknownValue;',
        '}',
      ]);
      expect(names, {'liveRetry', 'localeSelected', 'diagUnknownValue'});
    });
  });

  group('the tree', () {
    final scan = scanL10nReaders();

    test('the scan read a real tree', () {
      expect(scan.filesScanned, greaterThanOrEqualTo(20),
          reason: 'the scanner walked ${scan.filesScanned} non-generated dart files '
              'under lib/ — a check over nothing reports no dead keys');
      expect(scan.generatedNames, contains('liveRetryJoin'),
          reason: 'the generated class did not yield the getters it declares, so the '
              'ARB/generated comparison below would be vacuous');
    });

    test('the ARB really does declare hundreds of keys', () {
      expect(scan.arbKeys.length, greaterThan(400),
          reason: 'parsed ${scan.arbKeys.length} keys out of app_en.arb');
    });

    test('no key is declared and never read', () {
      final dead = scan.unread.toList()..sort();
      expect(dead, isEmpty,
          reason: 'these keys are generated, translated in both locales, drawn '
              'nowhere, and every other localization check passes for them. Either '
              'wire the call site or delete the key from app_en.arb and app_zh.arb '
              'and run `flutter gen-l10n`:\n  ${dead.join('\n  ')}');
    });

    test('the generated class and the ARB agree', () {
      // `flutter gen-l10n` is a required step after editing an ARB. If it was skipped,
      // the generated file still carries a removed key — and that stale getter is a
      // dead key the ARB no longer even mentions.
      expect(scan.generatedNamesMissingFromArb, isEmpty,
          reason: 'the generated class offers names app_en.arb does not declare, so '
              '`flutter gen-l10n` has not been run since the ARB changed');
      expect(scan.arbKeysMissingFromGenerated, isEmpty,
          reason: 'app_en.arb declares keys the generated class does not offer, so '
              '`flutter gen-l10n` has not been run since the ARB changed');
    });
  });
}
