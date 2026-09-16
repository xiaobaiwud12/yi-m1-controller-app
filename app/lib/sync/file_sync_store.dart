import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'sync_ledger.dart';

/// File-backed persistence for the sync ledger, the transfer queue **and the
/// UI layout preferences**.
///
/// Separate from [SyncLedger] so the ledger itself stays free of Flutter and of
/// file I/O, and can therefore be exercised by `tool/verify_sync.dart` in the
/// plain Dart VM.
///
/// The ledger is small — one short key per transferred asset — and is written
/// atomically: a temporary file beside the target, then a rename over it. A kill
/// during the write therefore cannot leave a truncated ledger, which matters
/// because the ledger is what decides whether a photo gets downloaded again.
///
/// The queue needs exactly the same guarantee for exactly the same reason: it is
/// written while transfers are in flight, so the window in which a kill can
/// interrupt a write is large, and a truncated queue would otherwise be read
/// back as a *smaller* queue — silently dropping the work the user asked for.
/// One implementation covers all three; the file name is the only difference.
///
/// The UI preferences use it for a weaker but still real reason: a half-written
/// preferences file is a preferences file that fails to parse, and the user's
/// panel arrangement then resets for no reason they can see. The atomic rename
/// costs nothing here.
class FileSyncStore implements SyncStore {
  static const _ledgerFileName = 'sync_ledger.json';

  /// Kept beside the ledger, for the same reason: losing it costs a full album
  /// re-list over a link the user has to stay joined to.
  static const _queueFileName = 'sync_queue.json';

  /// Which settings groups the user left open, and the last tab they were on.
  static const _uiPrefsFileName = 'ui_prefs.json';

  final String _fileName;

  FileSyncStore({String? fileName}) : _fileName = fileName ?? _ledgerFileName;

  /// The store the pending transfer queue is kept in.
  factory FileSyncStore.forQueue() =>
      FileSyncStore(fileName: _queueFileName);

  /// The store the live-view layout preferences are kept in.
  factory FileSyncStore.forUiPrefs() =>
      FileSyncStore(fileName: _uiPrefsFileName);

  File? _resolved;

  Future<File> _file() async {
    final cached = _resolved;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$_fileName');
    _resolved = f;
    return f;
  }

  @override
  Future<String?> read() async {
    final f = await _file();
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  @override
  Future<void> write(String contents) async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(f.path);
  }
}
