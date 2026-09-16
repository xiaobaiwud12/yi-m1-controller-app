/// The durable sync ledger, free of Flutter so it can be verified offline.
///
/// `analysis/ce-app-competitive-spec.md` §5.4 is explicit about why this is a
/// *ledger* rather than a "newest date seen" watermark: the camera has no RTC and
/// is set from the phone on connect, so if its battery went flat the clock can
/// move **backwards**, and a watermark would then quietly skip everything. A set
/// of identities has no such failure mode.
library;

/// The identity of one camera file, as used for deduplication and upgrades.
///
/// ## Why this is a triple and not a filename
///
/// All three reasons are observable on this camera:
///
/// * **The filename alone is not unique.** The M1 restarts at `YI000001.JPG`
///   after a card format, so a reformatted or swapped card would have new photos
///   silently treated as already-synced.
/// * **The capture time alone is not unique either** — it is second-resolution,
///   and burst shots share a second.
/// * **`date` can move backwards** (see the library comment), so nothing may
///   depend on ordering.
///
/// `path` + `date` survives all three, and the size is kept alongside as a
/// tie-breaker for the record.
class AssetId {
  final String path;
  final int dateSeconds;
  final int size;

  const AssetId({
    required this.path,
    required this.dateSeconds,
    this.size = 0,
  });

  /// The key used for the synced set and for pairing RAW with JPEG.
  ///
  /// Size is deliberately excluded: it is unknown until a transfer has happened,
  /// so including it would make the lookup key differ from the stored key and
  /// deduplication would never match.
  String get key => '$path|$dateSeconds';

  /// The complete identity, including size.
  String get fullKey => '$path|$dateSeconds|$size';

  @override
  bool operator ==(Object other) =>
      other is AssetId && other.path == path && other.dateSeconds == dateSeconds;

  @override
  int get hashCode => Object.hash(path, dateSeconds);

  @override
  String toString() => fullKey;
}

/// What has been transferred, and to what quality.
enum AssetQuality {
  /// Nothing yet.
  none,

  /// A `Thumbnail` rendition — enough to show in a grid.
  thumbnail,

  /// A `MidThumb` rendition: immediately viewable, upgradeable.  Measured on
  /// hardware at 1440x1080, against the original's 5184x3888.
  preview,

  /// The `Original` file.
  original;

  bool get isAtLeastPreview => index >= AssetQuality.preview.index;
  bool get isOriginal => this == AssetQuality.original;
}

/// Persistence for the ledger, injected so the ledger itself stays Flutter-free
/// and testable.
abstract class SyncStore {
  Future<String?> read();
  Future<void> write(String contents);
}

/// A store that keeps everything in memory.  Used by tests and by a dry run.
class MemorySyncStore implements SyncStore {
  String? _v;
  MemorySyncStore([this._v]);
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String contents) async => _v = contents;
}

/// The durable sync ledger.
///
/// One entry per transferred asset, keyed by [AssetId.key].
class SyncLedger {
  /// 2 added the local identifier (`content://` URI or path). Readable as 1.
  static const version = 2;

  final SyncStore store;
  final Map<String, AssetQuality> _quality = {};

  /// Where each asset actually landed on the phone, keyed like [_quality].
  ///
  /// Kept because "the file is on the phone" is not enough to *show* it: opening
  /// and sharing need the `content://` URI MediaStore assigned, and that URI is
  /// produced once, at insert time. Without it the album can display a photo it
  /// cannot hand to another app, which is exactly the share feature failing.
  final Map<String, String> _local = {};
  bool _dirty = false;

  /// Called for anything worth surfacing.  Injected so this file needs no
  /// logging framework.
  final void Function(String message)? onLog;

  SyncLedger({SyncStore? store, this.onLog})
      : store = store ?? MemorySyncStore();

  int get count => _quality.length;

  AssetQuality qualityOf(AssetId id) => _quality[id.key] ?? AssetQuality.none;

  bool has(AssetId id, {AssetQuality atLeast = AssetQuality.original}) =>
      qualityOf(id).index >= atLeast.index;

  void record(AssetId id, AssetQuality q) {
    // Never go backwards.  An upgrade that fails must not erase the record of a
    // preview that is already on disk, or the next run re-downloads it.
    if (q.index > qualityOf(id).index) {
      _quality[id.key] = q;
      _dirty = true;
    }
  }

  /// Remember where an asset was stored, and at which quality.
  ///
  /// Called with the sink's return value, which the sync engine previously
  /// discarded — so a synced photo was on the phone with nothing on the app side
  /// able to name it.
  ///
  /// The local id is only overwritten by a **better** rendition, for the same
  /// reason [record] never regresses: an upgrade replaces the preview, and letting
  /// a late-arriving preview clobber the original's URI would leave the album
  /// pointing at a 1440×1080 stand-in forever.
  void recordLocal(AssetId id, AssetQuality q, String localId) {
    final existing = _quality[id.key];
    if (existing != null && q.index < existing.index) return;
    final changed = _local[id.key] != localId;
    _local[id.key] = localId;
    if (changed) _dirty = true;
    record(id, q);
  }

  /// The local identifier for an asset, or null when it was never stored here.
  String? localIdOf(AssetId id) => _local[id.key];

  /// Forget where an asset was stored, e.g. after the user deleted the local copy.
  void forgetLocal(AssetId id) {
    if (_local.remove(id.key) != null) _dirty = true;
  }

  /// Forget one asset, e.g. because the user deleted it locally and wants it
  /// re-fetched.
  void forget(AssetId id) {
    if (_quality.remove(id.key) != null) _dirty = true;
    if (_local.remove(id.key) != null) _dirty = true;
  }

  /// Forget everything.  Offered as an explicit action, never automatic: silent
  /// re-downloading of a whole card is exactly the kind of surprise this ledger
  /// exists to prevent.
  void clear() {
    _quality.clear();
    _local.clear();
    _dirty = true;
  }

  Future<void> load() async {
    try {
      final text = await store.read();
      if (text == null || text.isEmpty) return;
      final decoded = _decode(text);
      _quality.addAll(decoded.quality);
      _local.addAll(decoded.local);
      onLog?.call(
          'sync ledger: ${_quality.length} known assets, ${_local.length} located');
    } on Object catch (e) {
      // A corrupt ledger costs duplicate transfers, which is far better than
      // refusing to sync at all.
      onLog?.call('sync ledger: unreadable ($e); starting empty');
    }
  }

  Future<void> save({bool force = false}) async {
    if (!_dirty && !force) return;
    try {
      await store.write(_encode());
      _dirty = false;
    } on Object catch (e) {
      onLog?.call('sync ledger: could not write ($e)');
    }
  }

  String _encode() {
    final sb = StringBuffer('{"version":$version,"assets":{');
    var first = true;
    _quality.forEach((k, v) {
      if (!first) sb.write(',');
      first = false;
      // `q` plus an optional `l`. The key order is fixed so the file diffs
      // cleanly, and `l` is omitted rather than encoded as null when absent — a
      // v2 file for an asset that was never located is still valid v1 shape.
      final local = _local[k];
      sb.write('${_quote(k)}:{"q":${_quote(v.name)}');
      if (local != null) sb.write(',${_quote("l")}:${_quote(local)}');
      sb.write('}');
    });
    sb.write('}}');
    return sb.toString();
  }

  /// Decode both the flat v1 shape (`"key":"original"`) and the v2 shape
  /// (`"key":{"q":"original","l":"content://…"}`).
  ///
  /// Both are accepted rather than migrating on write, because the cost of a
  /// failed migration is a re-download of the whole card: a user upgrading the app
  /// must not lose the record of what is already on their phone.
  ({Map<String, AssetQuality> quality, Map<String, String> local}) _decode(
      String text) {
    final quality = <String, AssetQuality>{};
    final local = <String, String>{};
    // A deliberately small parser rather than `dart:convert`'s map type: the
    // payload is one flat object, and keeping it here means the ledger has no
    // dependency at all.
    final m = RegExp(r'"assets"\s*:\s*\{(.*)\}', dotAll: true).firstMatch(text);
    if (m == null) return (quality: quality, local: local);
    final body = m.group(1) ?? '';

    AssetQuality? parseQuality(String? name) {
      if (name == null) return null;
      final q = AssetQuality.values.firstWhere(
        (e) => e.name == name,
        orElse: () => AssetQuality.none,
      );
      return q == AssetQuality.none ? null : q;
    }

    // v2 entries first.
    final v2 = RegExp(
      r'"((?:[^"\\]|\\.)*)"\s*:\s*\{\s*"q"\s*:\s*"([a-zA-Z]+)"'
      r'(?:\s*,\s*"(?:l|local)"\s*:\s*"((?:[^"\\]|\\.)*)")?\s*\}',
    );
    final consumed = <String>[];
    for (final e in v2.allMatches(body)) {
      final rawKey = e.group(1)!;
      consumed.add(rawKey);
      final key = _unquote(rawKey);
      final q = parseQuality(e.group(2));
      if (q != null) quality[key] = q;
      final l = e.group(3);
      if (l != null && l.isNotEmpty) local[key] = _unquote(l);
    }

    // v1 entries: any flat pair not already claimed by a v2 object.
    for (final pair
        in RegExp(r'"((?:[^"\\]|\\.)*)"\s*:\s*"([a-zA-Z]+)"').allMatches(body)) {
      final rawKey = pair.group(1)!;
      if (consumed.contains(rawKey)) continue;
      final key = _unquote(rawKey);
      final q = parseQuality(pair.group(2));
      if (q != null) quality[key] = q;
    }
    return (quality: quality, local: local);
  }

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
