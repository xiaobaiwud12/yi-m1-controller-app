/// The durable transfer queue, free of Flutter so it can be verified offline.
///
/// ## Why the queue is a separate file from the ledger
///
/// The two answer different questions, and it matters which one is asked when:
///
/// * the **ledger** records what has actually *arrived* on the phone, and at what
///   quality — it is a property of the photo library;
/// * the **queue** records what the user asked for and has not got yet — it is a
///   property of the job in progress.
///
/// The spec (§5.5) requires the second one to survive an app kill, because
/// without it a swipe-away costs a full album re-list: a 1290-file card is 22
/// `GetFileList` round trips against a single-threaded httpd, over a link the
/// user has to stay joined to. The *files* are what the queue exists to protect.
///
/// ## Why one record is a whole shot, not a file
///
/// `GetFileList` reports a RAW+JPEG exposure as **two entries** (§5.4). Enqueuing
/// them as two records would double the queue's size and its startup cost, and —
/// worse — could restore the RAW of a shot whose JPEG was already deleted from
/// the queue, resurrecting half a shutter press. A record therefore holds one
/// shot and however many of its assets are still outstanding, which is also the
/// granularity the rest of the app works in (`AssetGroup`).
///
/// ## Why filetype is stored rather than inferred from the extension
///
/// It is not always inferable. The camera reports `rawJpeg` for a pair and
/// `picture` for a lone JPEG; its RAW container is `.DNG` on the test card but
/// nothing in the protocol promises that, and `isRaw` is derived from `filetype`.
/// A restored item that guessed wrong would be filed as a JPEG and would then be
/// integrity-checked against the JPEG EOI marker — a check a RAW can never pass,
/// which would make the item fail forever.
library;

import '../transport/album.dart';
import 'sync_ledger.dart';

/// One shot waiting to be transferred, as it is persisted.
///
/// [quality] is a *hint* copied from the ledger so the queue file describes the
/// job on its own; the ledger is what the restore actually believes (see
/// `SyncEngine.restore`). It is written per asset because a RAW+JPEG pair really
/// can sit at two different qualities — the preview tier puts the JPEG on the
/// phone seconds before the RAW follows.
class TransferRecord {
  final String path;

  /// Capture time as Unix seconds, exactly as `GetFileList` reports it.
  ///
  /// Part of the identity, never the filename alone: the M1 restarts at
  /// `YI000001.JPG` after a card format.
  final int dateSeconds;

  final String fileType;
  final bool protectStatus;

  final AssetQuality quality;

  /// Only ever set for the second asset of a RAW+JPEG pair.
  final TransferRecord? raw;

  final DateTime lastAttempt;

  const TransferRecord({
    required this.path,
    required this.dateSeconds,
    required this.fileType,
    this.protectStatus = false,
    this.quality = AssetQuality.none,
    this.raw,
    required this.lastAttempt,
  });

  /// True when both renditions of one shutter press are outstanding.
  bool get isPair => raw != null;

  /// The existing identity triple, kept in one place so the queue cannot drift
  /// from the ledger's idea of what an asset is.
  AssetId get assetId =>
      AssetId(path: path, dateSeconds: dateSeconds, size: sizeBytes);

  /// The listing gives no size, so it is only ever known once the album has been
  /// browsed this session. Zero means "unknown", which is also what `AssetId`
  /// means by it.
  int get sizeBytes => 0;

  /// The identity of the whole shot, which is what a queue record is keyed by.
  ///
  /// Taken from the primary asset — for a pair that is the JPEG, matching
  /// `AssetGroup`, so the key does not change when the RAW arrives.
  String get key => TransferQueue.shotKey(path, dateSeconds);

  /// The album entry the engine should work with before the listing is known.
  AlbumFile get file => toAlbumFile();

  /// A [TransferRecord] that carries only what the queue stores, for merging the
  /// engine's newer quality back into an existing record.
  TransferRecord withQuality(AssetQuality q) => TransferRecord(
        path: path,
        dateSeconds: dateSeconds,
        fileType: fileType,
        protectStatus: protectStatus,
        quality: q,
        raw: raw?.withQuality(
            raw!.fileType == fileType ? q : raw!.quality),
        lastAttempt: lastAttempt,
      );

  AlbumFile toAlbumFile() => AlbumFile(
        path: path,
        fileType: fileType,
        protectStatus: protectStatus,
        captureTime: dateSeconds == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(dateSeconds * 1000),
      );

  @override
  String toString() =>
      'TransferRecord($path|$dateSeconds${raw == null ? '' : ' + RAW'})';
}

/// The durable queue of pending work.
class TransferQueue {
  static const version = 1;

  /// The hard bound on the queue, and it is a **bound on the file**, not a
  /// policy.
  ///
  /// 1290 entries is the largest card this project has seen, so the cap is set
  /// where it never bites in practice. A record is bounded too: the firmware
  /// copies `path` into a 50-byte buffer (§5.5), so a path longer than that can
  /// never be fetched and is refused at [add] rather than queued.
  static const capacity = 2000;

  /// The largest queue file that will be *read*, in bytes.
  ///
  /// A bound on startup cost as much as on the file: the whole queue is decoded
  /// before the first album page is fetched, and decoding a file of unknown size
  /// on the launch path is how one bad write turns into an app that hangs at
  /// startup. At full [capacity] a record is ~100 bytes, so a legitimate file is
  /// around 200 KB and this is two orders of magnitude clear of it.
  static const maxFileBytes = 4 * 1024 * 1024;

  final SyncStore store;
  final void Function(String message)? onLog;

  TransferQueue({SyncStore? store, this.onLog})
      : store = store ?? MemorySyncStore();

  final Map<String, TransferRecord> _pending = {};
  bool _dirty = false;
  String? _lastText;
  int _dropped = 0;

  int get length => _pending.length;
  bool get isEmpty => _pending.isEmpty;
  bool get isNotEmpty => _pending.isNotEmpty;

  /// How many records the last [load] could not use, for the log line and the
  /// offline checks.
  int get droppedOnLoad => _dropped;

  List<TransferRecord> get pending => List.unmodifiable(_pending.values);

  TransferRecord? recordFor(String path, int dateSeconds) =>
      _pending[shotKey(path, dateSeconds)];

  /// The identity of one shutter press: folder + basename + capture second.
  ///
  /// The **same rule as `asset_group.dart`**, and deliberately so — if the queue
  /// paired on anything else, a record could hold a RAW whose JPEG the engine
  /// considers a different shot. The extension is dropped because that is the
  /// only thing that differs between the two entries of a pair; the capture
  /// second is kept because the same basename really does recur after a card
  /// format, and the folder because `100YICAM` and `101YICAM` both exist.
  static String shotKey(String path, int dateSeconds) {
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash);
    var base = slash < 0 ? path : path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    return '$dir/$base|$dateSeconds';
  }

  /// Queue a shot. Returns false when it could never be fetched anyway.
  ///
  /// Queuing the JPEG and the RAW of one exposure collapses them into a single
  /// record, in either arrival order, because the listing has been observed to
  /// put either first.
  bool add(AlbumFile f) {
    if (f.isPathTooLong) {
      // Queuing it would cost a record and a request that the firmware answers
      // with an opaque failure (the 50-byte copy), so it is refused up front.
      onLog?.call(
          'sync queue: refusing ${f.path} — ${f.path.length} chars exceeds the '
          'firmware\'s 50-byte path buffer');
      return false;
    }

    final seconds = f.captureTime?.millisecondsSinceEpoch != null
        ? f.captureTime!.millisecondsSinceEpoch ~/ 1000
        : 0;
    final key = shotKey(f.path, seconds);
    final previous = _pending[key];

    // `TransferRecord.assets` is the pair as the *queue* stores it; the engine
    // works in `AlbumFile`, so the record is converted back on the way in.
    final files = <AlbumFile>[
      if (previous != null) ...previous.assets.map((a) => a.toAlbumFile()),
    ];
    // Re-adding an asset that is already queued refreshes its metadata instead of
    // duplicating it: the album can be browsed again while a sync runs.
    final at = files.indexWhere((e) => e.path == f.path);
    if (at < 0) {
      files.add(f);
    } else {
      files[at] = f;
    }

    _pending[key] = _build(key, files, previous);
    _dirty = true;
    // Enforce the bound, oldest first. The record just added is the one the user
    // is looking at, so it is the last that should go; what is dropped is work
    // from an older session, which the browse that is running now re-lists
    // anyway. Dropping silently is not an option — a queue that quietly forgets
    // is indistinguishable from one that was never durable.
    while (_pending.length > capacity) {
      final evicted = _pending.keys.first;
      _pending.remove(evicted);
      onLog?.call('sync queue: at capacity ($capacity), dropped $evicted');
    }
    onLog?.call('sync queue: $length pending (${f.path})');
    return true;
  }

  /// Note that one asset of a shot has been transferred.
  ///
  /// **One asset, not the whole record.** A RAW+JPEG shot is one record with two
  /// assets, and the JPEG finishes first (§5.4), so retiring the record on the
  /// first completion would drop the RAW that has not been fetched yet — losing
  /// exactly the work the queue exists to protect.
  ///
  /// Returns true when the record left the queue entirely.
  bool markDone(String path, int dateSeconds) {
    final key = shotKey(path, dateSeconds);
    final r = _pending[key];
    if (r == null) return false;

    final left = r.assets.where((a) => a.path != path).toList();
    if (left.length == r.assets.length) return false; // not one of ours
    _dirty = true;

    if (left.isEmpty) {
      _pending.remove(key);
      return true;
    }
    // The survivor becomes the new primary: a lone RAW is a `raw`/`rawJpeg`
    // filetype, so it is labelled and integrity-checked as RAW rather than as a
    // JPEG whose EOI marker it could never match.
    final head = left.first;
    _pending[key] = TransferRecord(
      path: head.path,
      dateSeconds: head.dateSeconds,
      fileType: head.fileType,
      protectStatus: head.protectStatus,
      quality: head.quality,
      lastAttempt: DateTime.now(),
    );
    return false;
  }

  /// Forget one shot outright, e.g. because the user removed it.
  void remove(TransferRecord r) {
    if (_pending.remove(r.key) != null) _dirty = true;
  }

  /// Forget **one asset**, leaving the rest of its shot queued.
  ///
  /// ## Why this rather than [drop]
  ///
  /// [drop] exists for a file that left the card, and it takes the whole record
  /// with it because a deleted JPEG's RAW went with it too. This is the opposite
  /// case: the user looked at the list and struck one line out. The other asset of
  /// the shot is *not* being refused — it is a separate file that they still asked
  /// for — so removing it as well would throw away work nobody objected to.
  ///
  /// The survivor is promoted to be the record's primary, and its `fileType` goes
  /// with it: a lone RAW has to stay labelled `raw`, or the engine would
  /// integrity-check it against the JPEG end-of-image marker that a RAW can never
  /// carry.
  ///
  /// Returns the paths no longer queued, so the caller can report what it did.
  List<String> removeAsset(String path, int dateSeconds) {
    final key = shotKey(path, dateSeconds);
    final r = _pending[key];
    if (r == null || !r.assets.any((a) => a.path == path)) return const [];

    final left = r.assets.where((a) => a.path != path).toList();
    if (left.isEmpty) {
      _pending.remove(key);
      _dirty = true;
      return [path];
    }

    final head = left.first;
    _pending[key] = TransferRecord(
      path: head.path,
      dateSeconds: head.dateSeconds,
      fileType: head.fileType,
      protectStatus: head.protectStatus,
      quality: head.quality,
      lastAttempt: r.lastAttempt,
    );
    _dirty = true;
    return [path];
  }

  /// Forget the shot one asset belongs to, whatever else it still holds.
  ///
  /// The whole record goes, not just the named asset: if the file was deleted on
  /// the card, its RAW sibling went with it, and [markDone] would leave that
  /// sibling queued as `failed` work that can never succeed. Returns the paths
  /// that were dropped.
  List<String> drop(String path, int dateSeconds) {
    final r = _pending.remove(shotKey(path, dateSeconds));
    if (r == null) return const [];
    _dirty = true;
    return [for (final a in r.assets) a.path];
  }

  /// Drop everything the ledger already holds at [AssetQuality.original].
  ///
  /// Without this the queue would keep one record per file ever enqueued, which
  /// is the unbounded file the bound exists to prevent — and a done item would
  /// be re-offered to the engine on every launch.
  int prune(bool Function(AssetId, AssetQuality) hasQuality) {
    final before = _pending.length;
    _pending.removeWhere((_, r) =>
        r.assets.every((a) => hasQuality(a.assetId, a.quality)));
    final removed = before - _pending.length;
    if (removed > 0) _dirty = true;
    return removed;
  }

  /// Note the quality an asset actually reached.
  ///
  /// Only ever moves forward, for the same reason the ledger never moves
  /// backwards: a failed upgrade must not erase the record of what is already on
  /// disk, because the next launch would then re-download it.
  bool mergeQuality(String path, int dateSeconds, AssetQuality q) {
    final key = shotKey(path, dateSeconds);
    final r = _pending[key];
    if (r == null) return false;

    var changed = false;
    TransferRecord? raw = r.raw;
    var primary = r.quality;
    if (r.path == path) {
      if (q.index > primary.index) {
        primary = q;
        changed = true;
      }
    } else if (raw != null && raw.path == path) {
      if (q.index > raw.quality.index) {
        raw = raw.withQuality(q);
        changed = true;
      }
    } else {
      return false;
    }

    if (changed) {
      _pending[key] = TransferRecord(
        path: r.path,
        dateSeconds: r.dateSeconds,
        fileType: r.fileType,
        protectStatus: r.protectStatus,
        quality: primary,
        raw: raw,
        lastAttempt: DateTime.now(),
      );
      _dirty = true;
    }
    return changed;
  }

  void clear() {
    if (_pending.isEmpty) return;
    _pending.clear();
    _dirty = true;
  }

  /// Read the queue back.
  ///
  /// **Never throws, and never fails the app.** A corrupt queue costs a re-list,
  /// which is a nuisance; refusing to start costs the app, which is not a trade
  /// worth making. Anything unreadable is therefore reported and treated as an
  /// empty queue.
  Future<void> load() async {
    String? text;
    try {
      text = await store.read();
    } on Object catch (e) {
      onLog?.call('sync queue: unreadable ($e); starting empty');
      return;
    }
    if (text == null || text.isEmpty) return;

    if (text.length > maxFileBytes) {
      // Treating an implausible file as empty is the safe direction: it costs a
      // re-list, where parsing it costs the launch.
      onLog?.call('sync queue: ${text.length} bytes exceeds '
          '$maxFileBytes; ignoring it');
      return;
    }

    if (!text.contains('"queue"')) {
      // e.g. the ledger's file under this name: a real parse would find nothing
      // and leave a half-filled queue behind.
      onLog?.call('sync queue: not a queue file; starting empty');
      return;
    }

    final header = RegExp(r'"version"\s*:\s*(\d+)').firstMatch(text);
    if (header == null || int.tryParse(header.group(1)!) != version) {
      onLog?.call('sync queue: unknown version; starting empty');
      return;
    }

    final body = _objectBody(text, 'queue');
    if (body == null) {
      // The queue object never closes, which is precisely what a write that the
      // OS killed looks like: every record before the tear is still on disk and
      // still wanted. So instead of giving up on the file, the records are
      // recovered individually — a record is self-contained, and everything up to
      // the torn one parses.
      final recovered = _readRecords(text, salvage: true);
      _pending.addAll(recovered.records);
      _dropped = recovered.dropped;
      _dirty = true;
      onLog?.call('sync queue: file was cut off; recovered $length record(s), '
          '${recovered.dropped} unusable');
      return;
    }

    final read = _readRecords(body);
    _pending.addAll(read.records);
    _dropped = read.dropped;
    // Rewrite once, which also drops any records that failed to parse.
    _dirty = true;
    onLog?.call('sync queue: $length pending'
        '${read.dropped > 0 ? ', ${read.dropped} unusable' : ''}');
  }

  /// Read every `"key":{...}` record out of [body].
  ///
  /// ## Why the records are walked rather than matched with a regex
  ///
  /// A power loss during a write leaves the last record cut off mid-string, and a
  /// regex for a record then simply does not match — including any record after
  /// it. Walking the structure instead means every record before the tear is read
  /// back and only the torn one is lost: the difference between losing one file's
  /// queued work and losing the whole session's.
  ///
  /// [salvage] additionally guards each attempt with the record's own shape,
  /// because in that mode [body] is not a well-formed object and a "field" may
  /// well be a key belonging to something else.
  ({Map<String, TransferRecord> records, int dropped}) _readRecords(
    String body, {
    bool salvage = false,
  }) {
    final records = <String, TransferRecord>{};
    var dropped = 0;

    // A record is introduced by its key, and the key's shape — a quoted shot key
    // with a capture second after a pipe — is what distinguishes a record from the
    // queue's own header fields (`"version"`, `"capacity"`, `"queue"`). Matching
    // the key rather than "the next quoted thing" is what lets the salvage walk
    // skip the header instead of stopping on it.
    final heads =
        RegExp(r'"((?:[^"\\]|\\.)*\|[0-9]+)"\s*:\s*\{').allMatches(body);
    for (final head in heads) {
      final brace = body.indexOf('{', head.start);
      if (brace < 0) break;
      final record = _objectBody(body, brace);
      if (record == null) {
        // Unterminated: this and everything after it is the torn tail.
        if (salvage) dropped++;
        break;
      }
      final r = _parseRecord(record);
      if (r == null) {
        dropped++;
        continue;
      }
      // The record is identified by path + seconds, and the key is rebuilt from
      // those rather than trusted from the file: a key that had drifted would make
      // `recordFor` miss, so the record would sit in the file forever without ever
      // being retried.
      records[r.key] = r;
    }
    return (records: records, dropped: dropped);
  }

  /// Persist, if anything changed since the last write.
  Future<void> save({bool force = false}) async {
    if (!_dirty && !force) return;
    final text = _encode();
    // The engine writes at every item boundary, so an idle queue must not
    // rewrite an identical file — on a phone that is flash wear for nothing.
    if (text == _lastText) {
      _dirty = false;
      return;
    }
    try {
      await store.write(text);
      _lastText = text;
      _dirty = false;
    } on Object catch (e) {
      // Losing the write costs a re-list, not the queue in memory.
      onLog?.call('sync queue: could not write ($e)');
    }
  }

  // ------------------------------------------------------------------ encode

  String _encode() {
    final sb = StringBuffer('{"version":$version,"capacity":$capacity,'
        '"queue":{');
    var first = true;
    for (final r in _pending.values) {
      if (!first) sb.write(',');
      first = false;
      sb.write('${_quote(r.key)}:{');
      sb.write('${_quote("path")}:${_quote(r.path)},');
      sb.write('${_quote("date")}:${r.dateSeconds},');
      sb.write('${_quote("filetype")}:${_quote(r.fileType)}');
      if (r.protectStatus) sb.write(',${_quote("protect")}:true');
      sb.write(',${_quote("quality")}:${_quote(r.quality.name)}');
      if (r.raw != null) {
        sb.write(',${_quote("raw")}:{${_quote("path")}:'
            '${_quote(r.raw!.path)},${_quote("date")}:${r.raw!.dateSeconds},'
            '${_quote("filetype")}:${_quote(r.raw!.fileType)}');
        if (r.raw!.protectStatus) sb.write(',${_quote("protect")}:true');
        sb.write(',${_quote("quality")}:${_quote(r.raw!.quality.name)}}');
      }
      sb.write('}');
    }
    sb.write('}}');
    return sb.toString();
  }

  /// One record out of a decoded `{...}` body.
  TransferRecord? _parseRecord(String body) {
    // Nested objects are blanked out first, so no `path`, `date` or `quality`
    // search can reach past the record and pick up the RAW's value for the JPEG
    // — which would give the pair one identity instead of two and make the
    // second asset unreachable, or worse, look already fetched.
    final nested = _objectBody(body, 'raw');
    final src = nested == null
        ? body
        : body.replaceFirst(nested, ' ' * nested.length);

    String? field(String name, [String? within]) {
      final text = within ?? src;
      // A string is quoted and a number is bare, and both forms have to be
      // accepted: a date the reader refuses leaves the record with a capture
      // second of zero, which changes its identity and so its deduplication.
      final m = RegExp('"$name"\\s*:\\s*(?:"((?:[^"\\\\]|\\\\.)*)"|([^,}\\s]+))')
          .firstMatch(text);
      if (m == null) return null;
      final quoted = m.group(1);
      return quoted == null ? m.group(2) : _unquote(quoted);
    }

    final path = field('path');
    if (path == null || !path.startsWith('/')) return null;
    final date = int.tryParse(field('date') ?? '') ?? 0;
    final fileType = field('filetype') ?? '';
    final protect = _isTrue(src, 'protect');

    TransferRecord? raw;
    if (nested != null) {
      final rawPath = field('path', nested);
      if (rawPath != null) {
        raw = TransferRecord(
          path: rawPath,
          dateSeconds: int.tryParse(field('date', nested) ?? '') ?? date,
          fileType: field('filetype', nested) ?? '',
          protectStatus: _isTrue(nested, 'protect'),
          quality: _qualityOf(field('quality', nested)),
          lastAttempt: DateTime.now(),
        );
      }
    }

    return TransferRecord(
      path: path,
      dateSeconds: date,
      fileType: fileType,
      protectStatus: protect,
      quality: _qualityOf(field('quality')),
      raw: raw,
      lastAttempt: DateTime.now(),
    );
  }

  /// Whether the flag [name] appears in [text] as `true`.
  ///
  /// The value is inspected rather than merely matched, so a `false` written by a
  /// later version cannot be read back as set.
  static bool _isTrue(String text, String name) {
    final m = RegExp('"$name"\\s*:\\s*(true|false)').firstMatch(text);
    return m != null && m.group(1) == 'true';
  }

  /// The `{...}` that follows the field [name], matched by brace depth.
  ///
  /// A regex cannot do this: the record body contains a nested RAW object, and
  /// both contain braces, so the first `}` is not the end of anything.
  ///
  /// [name] is a bare identifier, **not** a pattern and not pre-quoted: it is
  /// looked up with `indexOf`, so no amount of quoting or escaping in the payload
  /// can change what is matched.
  static String? _objectBody(String? text, Object marker) {
    if (text == null) return null;
    final int start;
    if (marker is int) {
      final brace = text.indexOf('{', marker);
      if (brace < 0) return null;
      start = brace;
    } else {
      final quoted = text.indexOf('"$marker"');
      if (quoted < 0) return null;
      final brace = text.indexOf('{', quoted);
      if (brace < 0) return null;
      start = brace;
    }

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final c = text.codeUnitAt(i);
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
        if (depth == 0) return text.substring(start + 1, i);
      }
    }
    return null;
  }

  static AssetQuality _qualityOf(String? name) => AssetQuality.values.firstWhere(
        (e) => e.name == name,
        orElse: () => AssetQuality.none,
      );

  /// Folder + basename + second, matching [shotKey].
  static String keyOfFile(AlbumFile f) => shotKey(
        f.path,
        f.captureTime?.millisecondsSinceEpoch != null
            ? f.captureTime!.millisecondsSinceEpoch ~/ 1000
            : 0,
      );

  /// One record per shot, with the baseline as `path` and the RAW as [raw].
  static TransferRecord _build(
      String key, List<AlbumFile> files, TransferRecord? previous) {
    // The baseline is the JPEG whenever there is one: §5.4 transfers it first
    // because it is the immediately viewable, shareable file, and the record's
    // identity must not change when the RAW shows up.
    final primary = files.firstWhere((f) => !f.isRaw, orElse: () => files.first);
    AlbumFile? rawFile;
    for (final f in files) {
      if (f.isRaw && f.path != primary.path) {
        rawFile = f;
        break;
      }
    }
    final raw = rawFile;

    AssetQuality qualityFor(String path) {
      if (previous == null) return AssetQuality.none;
      if (previous.path == path) return previous.quality;
      if (previous.raw?.path == path) return previous.raw!.quality;
      return AssetQuality.none;
    }

    return TransferRecord(
      path: primary.path,
      dateSeconds: _seconds(primary),
      fileType: primary.fileType,
      protectStatus: primary.protectStatus,
      quality: qualityFor(primary.path),
      raw: raw == null
          ? null
          : TransferRecord(
              path: raw.path,
              dateSeconds: _seconds(raw),
              fileType: raw.fileType,
              protectStatus: raw.protectStatus,
              quality: qualityFor(raw.path),
              // A pair shares one shutter press, so it shares one attempt time.
              lastAttempt: previous?.lastAttempt ?? DateTime.now(),
            ),
      // Browsing the same album twice must not look like a retry.
      lastAttempt: previous?.lastAttempt ?? DateTime.now(),
    );
  }

  static int _seconds(AlbumFile f) =>
      f.captureTime?.millisecondsSinceEpoch != null
          ? f.captureTime!.millisecondsSinceEpoch ~/ 1000
          : 0;

  // Hand-written rather than `dart:convert`, for the same reason the ledger is:
  // the payload is a flat object of strings, and this file then has no
  // dependency at all — which is what lets `tool/verify_sync.dart` drive it.
  static String _quote(String s) {
    final b = StringBuffer('"');
    for (final r in s.runes) {
      switch (r) {
        case 0x22:
          b.write(r'\"');
        case 0x5C:
          b.write(r'\\');
        case 0x0A:
          b.write(r'\n');
        case 0x0D:
          b.write(r'\r');
        case 0x09:
          b.write(r'\t');
        default:
          if (r < 0x20) {
            b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
          } else {
            b.writeCharCode(r);
          }
      }
    }
    b.write('"');
    return b.toString();
  }

  static String _unquote(String s) => s
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', '\u0000')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t')
      .replaceAll('\u0000', r'\');
}

/// The two assets of a shot, in transfer order.
///
/// A helper on the record rather than a second public class, because the queue's
/// unit of work is the shot and everything it iterates is a shot.
extension TransferRecordAssets on TransferRecord {
  List<TransferRecord> get assets => [this, if (raw != null) raw!];
}
