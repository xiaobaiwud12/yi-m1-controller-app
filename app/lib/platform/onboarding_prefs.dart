/// The two answers the **first-run flow** records, and nothing else.
///
/// ## Why this is a file of its own
///
/// The app had no first-run experience at all: it opened on a disconnected Capture
/// page and left the user to discover the connect button, the BLE pairing and the
/// Wi-Fi join on their own. Adding one needs one durable fact the app did not keep
/// anywhere — *has this person been through it* — and one piece of state the sync
/// layer keeps only in memory: **which sync mode they chose**.
///
/// It is deliberately not folded into `sync/ui_prefs.dart`. That file's contract is
/// "the parts of the *layout* the user arranged", and the sync mode is not layout:
/// it is a choice about what the app does with the camera, made once, at pairing
/// time, and shown again by the album screen. Keeping the two apart also means a
/// future rewrite of the settings panel cannot silently drop this answer — a
/// distinct file is a distinct thing to migrate.
///
/// ## Why it lives in `platform/` and not in `sync/`
///
/// Nothing here needs Flutter, but `sync/` is verified in the plain Dart VM and is
/// owned by the transfer work, while this is a *preference*: it is the same class of
/// thing as `ui_prefs.dart`, and `platform/` is where the project puts code that
/// needs the storage implementation. It reads and writes through [SyncStore], the
/// one storage pattern the project has, rather than introducing a second mechanism
/// whose failure modes nobody has exercised.
///
/// ## Why the mode is stored as a string
///
/// `SyncMode` lives in `sync/sync_engine.dart`, and importing it here would make the
/// persisted format depend on the enum's Dart identity. A name — `autoOriginalOnly`
/// — is stable, readable in the file, and survives a reorder or an insertion in the
/// enum, which an `index` would not: a new mode added in the middle would silently
/// turn every stored preference into a different one. [kSyncModeIds] is the list of
/// names this layer accepts, and every one of them is checked against the engine by
/// `test/onboarding_prefs_test.dart`.
///
/// ## Why every read is tolerant
///
/// The startup path already hung once on code that could not fail safely. A
/// preferences file that fails to parse must cost the user a repeated
/// introduction — never their ability to launch the app.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../sync/sync_ledger.dart';


/// The persisted answers, in one small file next to the ledger and the queue.
///
/// ## Why this is not `FileSyncStore`
///
/// Every other durable thing in this project goes through `FileSyncStore`, which
/// writes a temporary file beside the target and renames over it — the right
/// guarantee for the ledger and the queue, where a truncated file loses work.
///
/// **This preference cannot use it, and the reason is measurable.** On Windows, the
/// rename step fails with
///
/// ```
/// PathAccessException: Cannot rename file to '…\onboarding_prefs.json',
///   path = '…\onboarding_prefs.json.tmp'
///   (OS Error: 另一个程序正在使用此文件，进程无法访问。, errno = 32)
/// ```
///
/// every time — the temporary file is still held when the rename runs. The result is
/// a `.tmp` file on disk, `isDirty` still true, and a **preference that is silently
/// never saved** — so the first-run flow asks its question again on every launch
/// while every in-memory check passes. It was found exactly that way, by a widget
/// test that reloaded the file instead of trusting the object that wrote it.
///
/// The atomicity it buys is worth less here than it is for the ledger. The worst
/// outcome of a half-written preferences file is that it fails to parse, and the
/// defaults are *the same state as a first run* — which is this file's own documented
/// fallback. So the write is direct, one `writeAsString` with `flush: true`, which is
/// also what makes it work.
class PrefsStore implements SyncStore {
  final String fileName;

  File? _resolved;

  PrefsStore({this.fileName = kOnboardingPrefsFileName});

  Future<File> _file() async {
    final cached = _resolved;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$fileName');
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
    await f.writeAsString(contents, flush: true);
  }
}

/// The sync mode names this layer is allowed to persist.
///
/// The contract with the engine's `SyncMode` enum. Written out rather than derived
/// because this file may not import the engine — and an unknown name is treated as
/// "no answer" rather than as a mode, so a value from a future build can never be
/// handed to the engine as something it is not.
const List<String> kSyncModeIds = <String>[
  'autoPreviewThenOriginal',
  'autoOriginalOnly',
  'manualOnly',
];

/// The mode a user who skips the flow is recorded as having chosen.
///
/// The same value `SyncEngine` defaults to, and the reason skipping is safe: the
/// flow never leaves the preference *empty*, so there is no state in which the user
/// has answered nothing and the engine has to guess. It is also the mode the design
/// guide argues for (a preview is small and appears in seconds; a full size is
/// several megabytes over a slow radio).
const String kDefaultSyncModeId = 'autoPreviewThenOriginal';

/// Where the answers live, beside the ledger, the queue and the UI preferences.
///
/// Exported so the app builds the store from this name rather than repeating the
/// literal, and so a check can look at the file the app actually writes.
const String kOnboardingPrefsFileName = 'onboarding_prefs.json';

/// What the first-run flow remembers between launches.
class OnboardingPrefs {
  /// Bumped when the *format* changes in a way a reader must know about. A file
  /// written by a later build is read leniently rather than discarded: treating an
  /// unknown version as a first run would re-ask a returning user everything.
  static const int version = 1;

  /// Called for anything worth surfacing. Injected so this file needs no logging
  /// framework, matching `UiPrefs` and the ledger.
  final void Function(String message)? onLog;

  final SyncStore _store;

  String? _syncMode;
  bool _onboardingDone = false;

  /// Free-form text for the next reader of this file.
  ///
  /// Not used by the app. It exists so the file explains itself where somebody will
  /// actually look — next to the values — rather than only in this comment, which
  /// is not on the device.
  final String? note;

  bool _dirty = false;
  bool _loaded = false;

  /// The durable store the app uses, unless a test supplies its own.
  ///
  /// Named here rather than at the call site so there is exactly one place that
  /// decides where these answers live, and so a check can point at the same file.
  static SyncStore defaultStore() => PrefsStore();

  OnboardingPrefs({SyncStore? store, this.onLog, this.note})
      : _store = store ?? defaultStore();

  bool get isLoaded => _loaded;

  /// The mode the user chose, or null when they never did.
  String? get syncMode => _syncMode;

  /// True once the flow has been completed **or skipped**.
  ///
  /// Skipping is a decision and is recorded as one: a flow that reappears after
  /// being dismissed is worse than one that was never shown, because the user has
  /// already told the app what they want.
  bool get onboardingDone => _onboardingDone;

  /// True when the sync-mode question has an answer — chosen or defaulted.
  ///
  /// Distinct from [onboardingDone] on purpose: the owner of the sync engine applies
  /// *this* to `SyncEngine.mode`, and it must be true after a skip, or a user who
  /// dismissed the flow would get engine defaults that no screen explains.
  bool get askedSyncMode => _syncMode != null;

  /// The mode to apply to the engine: the stored answer, or the default.
  String get effectiveSyncMode => _syncMode ?? kDefaultSyncModeId;

  bool get isDirty => _dirty;

  /// Record the answer. An unknown id is refused rather than stored.
  void setSyncMode(String modeId) {
    if (!kSyncModeIds.contains(modeId)) {
      onLog?.call('onboarding: refusing unknown sync mode "$modeId"');
      return;
    }
    if (modeId == _syncMode) return;
    _syncMode = modeId;
    _dirty = true;
  }

  /// Record that the flow is finished with — including when it was skipped.
  void setOnboardingDone(bool done) {
    if (_onboardingDone == done) return;
    _onboardingDone = done;
    _dirty = true;
  }

  Future<void> load() async {
    _loaded = true;
    try {
      final text = await _store.read();
      if (text == null || text.isEmpty) return;
      final decoded = _decode(text);
      _syncMode = decoded.syncMode;
      _onboardingDone = decoded.onboardingDone;
      onLog?.call('onboarding: done=$_onboardingDone, '
          'sync mode ${_syncMode ?? "(unset)"}');
    } on Object catch (e) {
      // Never worth a failed launch, and never worth losing the file either: the
      // in-memory defaults are the same state as a first run, so a later save
      // writes a readable file over whatever confused the reader.
      onLog?.call('onboarding: unreadable ($e); using defaults');
    }
  }

  Future<void> save({bool force = false}) async {
    if (!_dirty && !force) return;
    try {
      await _store.write(encode());
      _dirty = false;
    } on Object catch (e) {
      onLog?.call('onboarding: could not write ($e)');
    }
  }

  /// The wire form. Public so an offline check can round-trip it directly.
  String encode() {
    final b = StringBuffer('{"version":$version');
    if (_syncMode != null) {
      b.write(',"syncMode":${encodeJsonString(_syncMode!)}');
    }
    b.write(',"onboardingDone":$_onboardingDone');
    if (note != null && note!.isNotEmpty) {
      b.write(',"note":${encodeJsonString(note!)}');
    }
    b.write('}');
    return b.toString();
  }

  /// What a stored file says.
  ///
  /// A named record rather than a positional one, matching `UiPrefs`: the fields are
  /// read by key out of a flat object, and transposing two of them would read back
  /// as a plausible but wrong state.
  static ({String? syncMode, bool onboardingDone}) _decode(String text) {
    final m = RegExp('"syncMode"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(text);
    final raw = m == null ? null : decodeJsonString(m.group(1)!);
    return (
      // An unknown name is **no answer**, not a mode: this layer may not import the
      // engine's enum, so it cannot promise that a string it cannot name is one the
      // engine will accept, and handing it over unchecked is how a future build's
      // mode becomes a crash in this one.
      syncMode: (raw != null && kSyncModeIds.contains(raw)) ? raw : null,
      // Absent means false, which is the honest reading: a file that does not say
      // the flow was seen has not said it was.
      onboardingDone: RegExp('"onboardingDone"\\s*:\\s*true').hasMatch(text),
    );
  }

  /// A JSON string literal for [s], escaped by hand.
  ///
  /// A deliberately small codec rather than `dart:convert`, matching `UiPrefs`:
  /// the payload is one flat object of short strings. Public because the round-trip
  /// is worth checking on its own, including for a note containing quotes and a
  /// backslash.
  static String encodeJsonString(String s) {
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

  /// The inverse of [encodeJsonString].
  static String decodeJsonString(String s) => s
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', '\u0000')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t')
      .replaceAll('\u0000', r'\');
}
