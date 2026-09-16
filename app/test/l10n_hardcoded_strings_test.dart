import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A source scan that fails when a user-visible string is left hardcoded in `lib/ui/`.
///
/// ## Why a scan and not a widget test
///
/// A widget test can only see the screens it happens to pump, and the screens that
/// were missed are precisely the ones nobody pumps — a dialog's body, a tooltip on a
/// button that only exists while connected, a `SnackBar`. The extraction this round
/// performed was a *source-level* change, so the check that it was complete has to be
/// source-level too.
///
/// ## What counts as user-visible
///
/// Only literals in a position the framework turns into pixels:
///
/// * the first argument of `Text` / `SelectableText` / `RichText`'s `TextSpan`;
/// * `tooltip`, `label`, `labelText`, `hintText`, `helperText`, `semanticsLabel`;
/// * the text-ish named arguments of this app's own small widgets (`note`, `detail`,
///   `message`, `reason`, `body`, `subtitle`, `description`);
/// * a literal assigned to a variable whose name says it is shown (`_error`, `_notice`,
///   `text`, `label`).
///
/// Everything else is deliberately out of scope, and the exclusions matter:
///
/// * `ValueKey`/`PageStorageKey` strings, `debugPrint` messages, `fontFamily`,
///   command names, MIME types and file paths are not language;
/// * **firmware wire vocabulary** (`'Single'`, `'JPG-S'`, `'4K_30'`, `'ON'`) must stay
///   verbatim — they are sent to the camera, and a translated one is a 404. Where they
///   are *displayed*, they go through `lib/l10n/param_labels.dart`, which is the point
///   of that file.
///
/// ## The allow-list, and why it is allowed to exist
///
/// Three files could not be localized this round; they are named in
/// [notYetLocalized] with the reason. The list is asserted to be *exact*: a file whose
/// strings have since been extracted must be removed from it, so it cannot quietly
/// grow into a place where new hardcoded strings hide.
void main() {
  /// Files still holding user-visible literals, with the reason each one is here.
  ///
  /// Empty is the goal. Anything added must name a concrete blocker.
  const notYetLocalized = <String, String>{};

  final dir = Directory('lib/ui');
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the scan is looking at real files', () {
    // `AGENTS.md` §8: a layer that found nothing because it ran over nothing looks
    // exactly like a layer that found nothing because there was nothing to find.
    expect(files.length, greaterThanOrEqualTo(5),
        reason: 'the scanner walked ${files.length} dart files under ${dir.path}');
    expect(files.map((f) => _rel(f.path)),
        contains('pages/album_page.dart'));
  });

  test('no user-visible string is hardcoded in lib/ui', () {
    final offenders = <String>[];
    for (final f in files) {
      if (notYetLocalized.containsKey(_rel(f.path))) continue;
      for (final hit in _scan(f.readAsStringSync())) {
        offenders.add('${_rel(f.path)}:${hit.line}  ${hit.why}  ${hit.text}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'these strings are drawn as-is, so they stay English no matter '
            'which locale is selected — move each through `l10nOf(context)`:\n'
            '${offenders.join('\n')}');
  });

  test('the not-yet-localized list names only files that still need it', () {
    final stale = <String>[];
    for (final entry in notYetLocalized.entries) {
      final f = File('lib/ui/${entry.key}');
      if (!f.existsSync()) {
        stale.add('${entry.key}: no such file');
        continue;
      }
      if (_scan(f.readAsStringSync()).isEmpty) {
        stale.add('${entry.key}: no offenders left — remove it from the list');
      }
    }
    expect(stale, isEmpty, reason: stale.join('\n'));
  });

  test('the scanner can fail', () {
    // The negative control. Without it, a regex that matches nothing would make the
    // check above pass forever — the "green but checking nothing" shape.
    final hits = _scan('''
      Text('Capture'),
      tooltip: 'Full screen',
      Text(l.navCapture),
      debugPrint('focus: tap -> camera'),
      const ValueKey<String>('btn-shutter'),
      onPressed: () => _send('RCEisSwitchSet', on ? _on : _off),
      _error = 'not connected to the camera';
    ''');
    final texts = hits.map((h) => h.text).toList();
    expect(texts, contains("'Capture'"));
    expect(texts, contains("'Full screen'"));
    expect(texts, contains("'not connected to the camera'"));
    expect(texts.any((t) => t.contains('navCapture')), isFalse);
    expect(texts.any((t) => t.contains('btn-shutter')), isFalse);
    expect(texts.any((t) => t.contains('focus: tap')), isFalse);
    expect(texts.any((t) => t.contains('RCEisSwitchSet')), isFalse);
  });
}

String _rel(String p) => p.replaceAll(r'\', '/').replaceFirst('lib/ui/', '');

class _Hit {
  final int line;
  final String why;
  final String text;
  const _Hit(this.line, this.why, this.text);
}

/// Sinks whose first string argument is drawn.
const _textCalls = ['Text', 'SelectableText', 'TextSpan'];

/// Named arguments that carry text rather than an identifier.
const _textArgs = [
  'tooltip',
  'label',
  'labelText',
  'hintText',
  'helperText',
  'semanticsLabel',
  'note',
  'detail',
  'message',
  'reason',
  'body',
  'subtitle',
  'description',
];

/// Variables whose value is put on screen.
const _shownVars = ['_error', '_notice', '_message', 'text', 'label'];

final _literal = RegExp(r"""^['"]([^'"\n]{2,})['"]""");

/// Any CJK character. Used as an independent trigger — see [_scan].
final _cjk = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]');
final _callOpen = RegExp('\\b(${_textCalls.join('|')})\\(\\s*(?:const\\s+)?\$');
final _argOpen = RegExp('\\b(${_textArgs.join('|')})\\s*:\\s*(?:const\\s+)?\$');
final _assignOpen =
    RegExp('(?:${_shownVars.map(RegExp.escape).join('|')})\\s*=\\s*\$');

List<_Hit> _scan(String src) {
  final clean = _stripComments(src);
  final lines = clean.split('\n');
  final hits = <_Hit>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    for (var c = 0; c < line.length; c++) {
      if (line[c] != "'" && line[c] != '"') continue;
      final before = line.substring(0, c);
      String? why;
      if (_callOpen.hasMatch(before)) {
        why = 'Text(';
      } else if (_argOpen.hasMatch(before)) {
        why = '${_argOpen.firstMatch(before)!.group(1)}:';
      } else if (_assignOpen.hasMatch(before)) {
        why = 'assigned to a shown variable';
      }
      if (why == null) continue;
      final m = _literal.firstMatch(line.substring(c));
      if (m == null) continue;
      final content = m.group(1)!;
      // A single word that reads as an identifier or a wire token is not prose. The
      // distinction this check needs is "would a reader notice", and one lowercase
      // word with no space is a key or a command far more often than a sentence.
      final looksLikeProse = content.contains(' ') ||
          RegExp(r'^[A-Z]').hasMatch(content) ||
          _cjk.hasMatch(content);
      if (!looksLikeProse) {
        continue;
      }
      hits.add(_Hit(i + 1, why, line.substring(c, c + m.end).trim()));
      break;
    }
  }

  // Chinese text anywhere in `lib/ui/`, whatever position it is in. There is no
  // legitimate wire value written in Chinese — this is a camera whose *protocol* is
  // Latin script — so a CJK literal in a widget file is either a hardcoded label that
  // will show up in an English UI, or a "bilingual" string like `'感光度 ISO'` that
  // reads as one language's UI with another's word glued on. Both are the defect this
  // round exists to remove, and neither is caught by the sink positions above: a
  // `_DialIdentity('dial-iso', '感光度', 'ISO')` call is not a `Text(`.
  for (var i = 0; i < lines.length; i++) {
    for (final m in RegExp("'[^'\\n]*${_cjk.pattern}[^'\\n]*'").allMatches(lines[i])) {
      final already = hits.any((h) => h.line == i + 1 && h.text == m.group(0));
      if (already) continue;
      hits.add(_Hit(i + 1, 'Chinese text in a widget file', m.group(0)!));
    }
  }
  return hits;
}

/// Removes `//` and `/* */` comments so a commented-out sample is not an offender.
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    if (src.startsWith('//', i)) {
      final nl = src.indexOf('\n', i);
      i = nl < 0 ? src.length : nl;
      continue;
    }
    if (src.startsWith('/*', i)) {
      final end = src.indexOf('*/', i + 2);
      // Keep the newlines so line numbers stay right.
      final block = src.substring(i, end < 0 ? src.length : end + 2);
      out.write('\n' * '\n'.allMatches(block).length);
      i = end < 0 ? src.length : end + 2;
      continue;
    }
    if (src[i] == "'" || src[i] == '"') {
      final quote = src[i];
      final start = i;
      i++;
      while (i < src.length && src[i] != quote) {
        if (src[i] == r'\') i++;
        i++;
      }
      i++;
      out.write(src.substring(start, i.clamp(0, src.length)));
      continue;
    }
    out.write(src[i]);
    i++;
  }
  return out.toString();
}
