import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/transport/album_thumbnail_cache.dart';
import 'package:yi_m1_controller/transport/measured_sizes.dart';

/// The check for `analysis/79` #19 and #20: **a size figure in a comment has to be a
/// measurement this tree can point at.**
///
/// ## What it catches, and the evidence that it does
///
/// `9.4 MB` was written into nine comments across five files as the size of one
/// `Original`. The source those comments cite records **4,897,837 B** (4.9 MB) and a
/// second pass records 5,565,238 B (5.6 MB). `~186 KB, measured` was written for
/// `MidThumb`, whose two measurements are 104 KB and 192 KB. Both figures were defensible
/// as prose and neither was a measurement, and one of them — the cache cap argument in
/// `album_thumbnail_cache.dart` — is load-bearing for a constant.
///
/// This test fails on the tree as the audit found it, naming every stale figure at once.
///
/// ## What it does not try to do
///
/// It does not parse units rigorously or police rounding. It extracts every
/// `\d+(\.\d+)? MB` and `\d+ KB` from `.dart` sources under `lib/` and `tool/`, and each
/// one must be within a percent of a value declared in `lib/transport/measured_sizes.dart`
/// — or be on [otherUnits], which names the figures that measure something else entirely
/// (a cache cap, a frame size, a text scale). The allow-list is explicit and asserted not
/// to be stale, the same shape as `l10n_arb_test.dart`'s identical-value list: adding to
/// it is a decision, not an accident.
void main() {
  /// Size figures that are **not** camera file sizes, with what they do measure.
  ///
  /// Every entry has to still occur in the sources, or the test fails and says so — the
  /// same shape as `l10n_arb_test.dart`'s identical-value list, so adding one is a
  /// decision rather than an accident.
  const otherUnits = <String, String>{
    '8 KB': 'a prose comparison of what a file write costs, not a camera file',
    '6.8 MB': 'kMeasuredCardOfThumbnailsBytes, declared in measured_sizes.dart',
    '2.47 GB': 'a byte total the frame gate recorded over one session',
    '2.56 GB': 'the live-view capture total — 48,697 datagrams',
    '17.5 KB': 'the retracted live-view datagram size, kept in the retraction itself',
    '32 MB': 'the RAW original, rounded down in prose about RAW sync',
    '31.9 MB': 'kMeasuredRawOriginalBytes as a comment writes it',
    // Memory budgets this app chooses, not camera file sizes. Named so that a figure
    // drifting between the two categories is visible rather than convenient.
    '0.5 MB': 'a per-tile decode budget in the viewer, this app\'s choice',
    '1.9 MB': 'the startup image-cache budget\'s measured usage, in app.dart',
    '100 MB': 'a memory ceiling named in app.dart, not a file size',
    '20 MB': 'a viewer/transfer ceiling named in prose, not a file size',
    '200 KB': 'a queue\'s own inline-payload bound, this app\'s choice',
    '20.0 KB': 'the live-view datagram payload the transport documents',
    '13 KB': 'a per-frame figure quoted in verify_sync, not a camera file size',
    '256 KB': 'the progress-notification cadence in sync_engine, this app\'s choice',
    '7 KB': 'a prose size for a cache write, not a camera file',
    '8 MB': 'the decoded-image cache budget and a transfer ceiling in prose',
    '6.8 KB': 'the rounded form of the measured 6,785 B thumbnail, in app.dart',
    '57 KB': 'the live-view datagram size, in the retraction that corrected it',
    '574 MB': '18 measured RAW originals, rounded — a card arithmetic, not one file',
  };

  /// Figures that were **withdrawn**, and the exact places each may still appear.
  ///
  /// ## Why these are pinned by location and not allow-listed by name
  ///
  /// The first version of this file put them on the same list as the memory budgets, and
  /// that made the check unable to fail in the one case it exists for: a perturbation that
  /// wrote `9.4 MB` into a **new** sentence still passed, because the figure was allowed
  /// somewhere else. That is the "check that cannot fail" shape `analysis/79` is about,
  /// reproduced in the check written to fix it — and it was found by perturbing the check,
  /// not by reading it.
  ///
  /// So each withdrawn figure is pinned to the **files** that retract it. They exist to be
  /// *recognised*: every occurrence names the number that was withdrawn so the next reader
  /// can spot it if it reappears in a citation. Deleting them from the prose to satisfy
  /// this scanner would delete the record of what was wrong, which is the opposite of the
  /// point. A new occurrence in a new file fails, and the failure names both.
  const retractedFigures = <String, Set<String>>{
    // The invented original size: the three retraction paragraphs, the cache's own
    // argument, and the album viewer note whose cited source this whole finding is about.
    '9.4 MB': {
      'lib/sync/stream_pause_contract.dart',
      'lib/sync/sync_engine.dart',
      'lib/transport/album.dart',
      'lib/transport/album_thumbnail_cache.dart',
      'lib/ui/pages/album_page.dart',
      'tool/verify_sync.dart',
      'tool/verify_transport.dart',
    },
    // The invented transfer size, in the retractions that round it — including this
    // one, which says in the same breath that the photo used to be quoted as ~9 MB.
    '9 MB': {
      'lib/sync/sync_engine.dart',
      'lib/transport/camera_connection.dart',
      'tool/verify_transport.dart',
    },
    // The invented MidThumb size, in the cache's own retraction.
    '186 KB': {
      'lib/transport/album_thumbnail_cache.dart',
      'lib/ui/pages/album_page.dart',
    },
  };

  /// Every `N MB` / `N KB` / `N GB` figure in a dart source under [dir].
  ///
  /// The negative lookahead matters: a word boundary would read the number out of
  /// `13.5 M**bit**` and `12-14 M**bit**`, which are rates rather than sizes, and then
  /// report them as undeclared sizes.
  Map<String, List<String>> figuresIn(String dir) {
    final unit = RegExp(r'\b(\d+(?:\.\d+)?)\s*(MB|KB|GB)(?![A-Za-z])');
    final out = <String, List<String>>{};
    for (final f in Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.replaceAll('\\', '/').contains('/l10n/gen/'))) {
      final rel = f.path.replaceAll('\\', '/');
      var line = 0;
      for (final text in f.readAsLinesSync()) {
        line++;
        for (final m in unit.allMatches(text)) {
          final key = '${m.group(1)} ${m.group(2)}';
          out.putIfAbsent(key, () => []).add('$rel:$line');
        }
      }
    }
    return out;
  }

  /// The figures a declared measurement produces, in the form a comment writes them.
  ///
  /// The unit is **appended here** rather than returned by the label helpers: `mbLabel`
  /// gives a bare number (`4.9`) because a caller may want it without a unit, so building
  /// this set as `mbLabel(b)` alone produced `{4.9, 5.6, 0.1, …}` — every entry missing
  /// its unit, and therefore every real figure still reported as undeclared. It took a
  /// print of the set to see it, which is itself the lesson this finding is about: a check
  /// whose own bookkeeping is wrong reports the right things for the wrong reason.
  final declared = <String>{
    for (final b in kMeasuredJpegOriginalBytes) '${mbLabel(b)} MB',
    for (final b in kMeasuredMidThumbBytes) '${mbLabel(b)} MB',
    for (final b in kMeasuredThumbnailBytes) '${mbLabel(b)} MB',
    '${mbLabel(kMeasuredRawOriginalBytes)} MB',
    // The same measurements as whole kilobytes, which is how a comment writes a small
    // rendition: `106 KB` for 106,375 B, `196 KB` for 196,495 B.
    for (final b in kMeasuredMidThumbBytes) '${kbLabel(b)} KB',
    for (final b in kMeasuredThumbnailBytes) '${kbLabel(b)} KB',
    // The cache states its own constant in prose alongside the measurements.
    '512 KB',
  };

  test('the scan is looking at real sources', () {
    final found = figuresIn('lib');
    expect(found, isNotEmpty,
        reason: 'no size figures at all under lib/ means the scanner walked nothing');
    expect(found.keys, contains('6.8 MB'),
        reason: 'the cache comment quotes the measured card total — if the scan cannot '
            'see that, it is not reading the file the finding is about');
  });

  test('every megabyte figure is a declared measurement or a named other unit', () {
    final offenders = <String>[];
    for (final dir in ['lib', 'tool']) {
      for (final entry in figuresIn(dir).entries) {
        final key = entry.key;
        if (otherUnits.containsKey(key)) continue;
        if (declared.contains(key)) continue;
        final where = entry.value.join(', ');
        final allowedFiles = retractedFigures[key];
        if (allowedFiles != null) {
          // A withdrawn figure may appear only in the files that retract it. A new file
          // quoting it fails here, which is the case the name-only allow-list missed.
          final strayFiles = entry.value
              .map((loc) => loc.split(':').first)
              .where((f) => !allowedFiles.contains(f))
              .toSet()
              .toList()
            ..sort();
          if (strayFiles.isEmpty) continue;
          offenders.add('$key at $where — this is a **withdrawn** figure and it has '
              'appeared in $strayFiles, which do not retract it. A comment quoting it '
              'is quoting a size that was already withdrawn');
          continue;
        }
        if (key.endsWith(' GB')) {
          offenders.add('$key at $where — a GB figure with no declared measurement '
              'behind it');
          continue;
        }
        offenders.add('$key at $where');
      }
    }
    offenders.sort();
    expect(offenders, isEmpty,
        reason: 'these figures are not measurements this tree can point at. Either '
            'quote a value from lib/transport/measured_sizes.dart, or add the figure to '
            'otherUnits naming what it actually measures. A number in a comment is '
            'untestable, which is how one invented size reached five files while its own '
            'source recorded a different one:\n  ${offenders.join('\n  ')}');
  });

  test('every withdrawn figure still appears, in a file that retracts it', () {
    // The other half: a retracted figure that has been *deleted* from the prose is a rule
    // that no longer guards anything, and it would then allow the figure back one
    // occurrence at a time.
    final all = <String>{...figuresIn('lib').keys, ...figuresIn('tool').keys};
    final gone = retractedFigures.keys.where((k) => !all.contains(k)).toList()..sort();
    expect(gone, isEmpty,
        reason: 'these were retracted but no longer appear at all, so their entries '
            'have stopped guarding anything: $gone');
  });

  test('the other-units allow-list has no stale entries', () {
    final all = <String>{...figuresIn('lib').keys, ...figuresIn('tool').keys};
    final stale = otherUnits.keys.where((k) => !all.contains(k)).toList()..sort();
    expect(stale, isEmpty,
        reason: 'these no longer appear anywhere, so they have stopped meaning "a '
            'figure that measures something else" and started being a place where a '
            'stale size can hide: $stale');
  });

  test('the declared measurements are the ones the analysis records', () {
    // Pinned to the numbers in `analysis/50` §2 and `analysis/61` §1. If a future
    // measurement replaces them, it has to be recorded in both places — which is the
    // rule this finding is about.
    expect(kMeasuredJpegOriginalBytes, [4897837, 5565238]);
    expect(kMeasuredMidThumbBytes, [106375, 196495]);
    expect(kMeasuredThumbnailBytes, [3552, 6785]);
    expect(kMeasuredRawOriginalBytes, 31931408);
    expect(mbLabel(4897837), '4.9',
        reason: 'analysis/50 records 4,897,837 B and the comment that quoted 9.4 MB '
            'cited it — this is that figure');
    expect(mbLabel(31931408), '31.9',
        reason: 'analysis/50 and analysis/61 both write 31.9 MB for this byte count');
  });

  test('the cache cap holds a measured card, and is still bounded', () {
    // **This test used to assert the opposite, and the opposite was wrong.**
    //
    // It required the cap to be *smaller than one photograph* — a bound argued from an
    // invented 9 MB figure. Once both sides came from the recorded byte counts it could
    // only be satisfied by shrinking the cap to 2 MiB, which is ~295 tiles: a 1000-shot
    // card then re-fetches ~705 of them every session, from a single-threaded camera.
    // That gives back what the cache was built to save, to protect 8 MB of a directory
    // Android can reclaim.
    //
    // **Holding a card is the requirement — it is the maintainer's own complaint** ("every
    // time I connect and open the album the thumbnails reload"), so that is what is
    // asserted. The upper bound stays, because a cache has to be a cache.
    expect(kAlbumThumbnailCacheMaxBytes, greaterThanOrEqualTo(kThousandShotCardBytes),
        reason: 'the cap must hold a measured 1000-shot card, or the oldest tiles are '
            'fetched from the camera again — which is the feature this cache exists to be');
    expect(kAlbumThumbnailCacheMaxBytes, lessThanOrEqualTo(32 * 1024 * 1024),
        reason: 'and it is still a bound: a cache that grows without one is a data store');
    expect(kAlbumThumbnailCacheMaxBytes, greaterThan(kMeasuredThumbnailBytes.last * 200),
        reason: 'and it has to be worth having: at least a couple of hundred tiles, or '
            'browsing re-fetches what the user just looked at');
  });
}
