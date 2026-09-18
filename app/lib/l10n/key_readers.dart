/// The check that gives the localization mechanism its missing direction:
/// **key → call site**.
///
/// ## What was missing, and why it mattered
///
/// `analysis/79` §18, and it is the highest-leverage finding in that audit because it
/// retires a class rather than an item. Every existing check runs *key ↔ key* or
/// *code ↔ code*:
///
/// * `l10n_arb_test.dart` — every English key exists in Chinese, no value is empty, the
///   two files do not read identically, placeholders match their declarations;
/// * `l10n_message_codes_test.dart` — every message code a producer raises has a case in
///   the resolver, and every case has a producer;
/// * `l10n_hardcoded_strings_test.dart` — no user-visible literal is drawn raw.
///
/// All of those hold for a key that **nothing ever reads**. A dead key is generated,
/// type-checks, is translated in both locales, and is drawn nowhere: it is invisible in
/// English *and* in Chinese, so every one of those checks stays green. Three such keys
/// were sitting in the ARB when this file was written (`diagUnknownValue`, `liveRetry`,
/// `localeSelected`), and one of them had a hardcoded `'?'` at the call site that was
/// meant to read it — the definition of a translation that can never be seen.
///
/// ## Why this is a library and not the body of a test
///
/// `analysis/79`'s own header states the failure shape this project keeps shipping:
/// **the test reads the same source as the code, so they are wrong together.** If the
/// test recomputed "the set of ARB keys" from its own list, or asked the generated class
/// for its own getter names while the test walked the ARB, the two could drift and the
/// check would keep reporting green. So the implementation lives here, once, and
/// `test/l10n_key_reader_test.dart` does nothing but call it and assert three things:
/// the scan saw files, the ARB really does have hundreds of keys, and the unread set is
/// empty. There is no second copy to disagree with.
///
/// ## The two sides, and why they are both read from disk
///
/// * **The keys.** Read from `lib/l10n/app_en.arb` — the template is the source of every
///   generated getter, so a key that is not in it does not exist.
/// * **The key list used for the "is this real?" sanity count.** Read from the
///   *generated* `lib/l10n/gen/app_localizations.dart` getters, not from the ARB again.
///   `flutter gen-l10n` is a required step after editing an ARB (`AGENTS.md` §"user-visible
///   strings go through the ARB"): if someone hand-edits the ARB and forgets to regenerate,
///   the generated file still carries the old key, and this mismatch is the only place
///   that would notice. It is reported as [L10nScan.arbsKeysMissingFromGenerated] rather
///   than silently ignored.
/// * **The reads.** Every `.dart` under `lib/` **except** the generated directory, with
///   each key looked for as a member access (`.key`, not preceded by `.`) or as a
///   `'key'` string literal.
///
/// ## Why a member access and not a resolved type
///
/// Resolving `l` to `AppLocalizations` needs the analyzer, which a `flutter test` cannot
/// handily run over the tree. A lexical member access is the honest approximation, and it
/// errs in the one direction that is safe here: it can only *over*-count reads, so the
/// check can miss a dead key but cannot invent one. Over-counting is exactly the mistake
/// `analysis/79` warns about, so the escape hatch is closed the other way as well — a key
/// mentioned only inside a **doc comment** does not count, because the scan strips
/// comments before matching. Otherwise the fix for a reported dead key would be to write
/// its name in a comment, and the check would be satisfied by prose rather than by a
/// screen that reads it.
library;

import 'dart:convert';
import 'dart:io';

/// What one run of the scan saw. Exposed so the test can assert the scan itself worked.
class L10nScan {
  /// Keys declared in `lib/l10n/app_en.arb`.
  final Set<String> arbKeys;

  /// Getter/method names declared in the generated `AppLocalizations`.
  final Set<String> generatedNames;

  /// How many non-generated `.dart` files under `lib/` were read.
  final int filesScanned;

  /// Keys with no reader anywhere in `lib/` outside `lib/l10n/gen/`.
  final Set<String> unread;

  /// Keys the generated class offers that the ARB does not declare.
  ///
  /// Non-empty means `flutter gen-l10n` is stale relative to the ARB — a key was
  /// removed or renamed in the template and the generated files were not rebuilt.
  final Set<String> generatedNamesMissingFromArb;

  /// Keys the ARB declares that the generated class does not offer.
  final Set<String> arbKeysMissingFromGenerated;

  const L10nScan({
    required this.arbKeys,
    required this.generatedNames,
    required this.filesScanned,
    required this.unread,
    required this.generatedNamesMissingFromArb,
    required this.arbKeysMissingFromGenerated,
  });

  /// Keys that are in the ARB but not in the generated class.
  ///
  /// Declared and never compiled: a `gen-l10n` run that was never done.
  @override
  String toString() => 'L10nScan(${arbKeys.length} arb keys, '
      '${generatedNames.length} generated, $filesScanned files, '
      '${unread.length} unread)';
}

/// Every key declared in an ARB file, with the `@`-metadata and `@@locale` dropped.
///
/// Parsed as JSON rather than line by line, because an ARB is JSON and a line scan
/// cannot tell a message key from a *placeholder* key nested inside the metadata block
/// that follows it — `"@foo": { "placeholders": { "count": … } }` puts `count` at the
/// same indentation as a real key. The first version of this function did it by line and
/// reported 26 placeholder names as ARB keys, which is precisely the "the test reads the
/// source wrong, so it is confidently wrong" shape `analysis/79` is about.
///
/// Takes the lines of a JSON object, so the unit test can feed it a fixture.
Set<String> arbKeysFromLines(Iterable<String> lines) {
  final raw = jsonDecode(lines.join('\n')) as Map<String, dynamic>;
  return raw.keys.where((k) => !k.startsWith('@')).toSet();
}

/// The member names the generated [AppLocalizations] API offers.
///
/// Read from the abstract class only — the per-locale subclasses add nothing but
/// overrides, and reading them would make one name in three files count three times.
Set<String> generatedNamesFromLines(Iterable<String> lines) {
  final out = <String>{};
  final getter = RegExp(r'^\s*String\s+get\s+(\w+)\s*;');
  final method = RegExp(r'^\s*String\s+(\w+)\s*\(');
  for (final line in lines) {
    final g = getter.firstMatch(line);
    if (g != null) {
      out.add(g.group(1)!);
      continue;
    }
    final m = method.firstMatch(line);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

/// True when [source] reads [key] as a member, or names it as a string literal.
///
/// Comments are stripped first, deliberately: a key's name in a doc comment is a
/// description of the key, not a call site, and counting it would let the check be
/// satisfied by prose. A `'key'` literal counts because a real indirection in this
/// project goes through maps keyed by message code (`kHandledMessageCodes`), and a
/// future one keyed by an ARB key must not be reported as dead.
bool readsKey(String source, String key) {
  final code = _withoutComments(source);
  final member = RegExp('\\.${RegExp.escape(key)}' r'\b');
  if (member.hasMatch(code)) return true;
  return RegExp("'${RegExp.escape(key)}'").hasMatch(code);
}

/// The scan that `test/l10n_key_reader_test.dart` asserts on.
///
/// [root] is the `app` directory — the one holding `lib/`, which is what the test's
/// working directory already is.
L10nScan scanL10nReaders({String root = '.'}) {
  final sep = Platform.pathSeparator;
  final l10nDir = '$root${sep}lib${sep}l10n';
  final genDir = '$l10nDir${sep}gen';

  final arbKeys = arbKeysFromLines(
      File('$l10nDir${sep}app_en.arb').readAsLinesSync());

  final generated = File('$genDir${sep}app_localizations.dart');
  final generatedNames = generatedNamesFromLines(generated.readAsLinesSync());

  final sources = <String>[];
  for (final f in Directory('$root${sep}lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))) {
    final path = f.path.replaceAll('\\', '/');
    if (path.contains('/lib/l10n/gen/')) continue;
    sources.add(f.readAsStringSync());
  }

  final unread = <String>{};
  for (final key in arbKeys) {
    if (!sources.any((s) => readsKey(s, key))) unread.add(key);
  }

  return L10nScan(
    arbKeys: arbKeys,
    generatedNames: generatedNames,
    filesScanned: sources.length,
    unread: unread,
    generatedNamesMissingFromArb: generatedNames.difference(arbKeys),
    arbKeysMissingFromGenerated: arbKeys.difference(generatedNames),
  );
}

/// [source] with `//`, `///` and `/* … */` removed.
///
/// A character walk rather than a regex: `//` inside a string literal (`'http://x'`) is
/// not a comment, and stripping from there to end-of-line would delete the rest of a
/// real line — which for this scan means deleting call sites and reporting live keys as
/// dead. The walk tracks whether it is inside a `'` or `"` literal.
String _withoutComments(String source) {
  final out = StringBuffer();
  var i = 0;
  var inSingle = false;
  var inDouble = false;
  while (i < source.length) {
    final c = source[i];
    if (inSingle || inDouble) {
      out.write(c);
      if (c == r'\' && i + 1 < source.length) {
        out.write(source[i + 1]);
        i += 2;
        continue;
      }
      if (c == "'" && inSingle) inSingle = false;
      if (c == '"' && inDouble) inDouble = false;
      i++;
      continue;
    }
    if (c == "'") {
      inSingle = true;
      out.write(c);
      i++;
      continue;
    }
    if (c == '"') {
      inDouble = true;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      i += 2;
      while (i + 1 < source.length &&
          !(source[i] == '*' && source[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// The keys in `app_en.arb`, for a caller that wants them without the scan.
Set<String> englishArbKeys({String root = '.'}) => arbKeysFromLines(
    File('$root${Platform.pathSeparator}lib${Platform.pathSeparator}l10n'
            '${Platform.pathSeparator}app_en.arb')
        .readAsLinesSync());
