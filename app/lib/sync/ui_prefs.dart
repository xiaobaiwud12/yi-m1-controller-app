/// Durable UI preferences — the parts of the *layout* the user arranged.
///
/// Flutter-free like the ledger and the queue, for the same reason: the codec is
/// the part that can silently lose a setting, and this way
/// `tool/verify_transport.dart` exercises it in the plain Dart VM.
///
/// ## Why this is not `shared_preferences`
///
/// `pubspec.yaml` carries no `shared_preferences`, and two things already need
/// file-backed state with an atomic write (the ledger and the queue). Reusing
/// `SyncStore` keeps one storage pattern in the project instead of introducing a
/// second mechanism whose failure modes nobody has exercised.
///
/// ## What is stored, and what is deliberately not
///
/// Only **layout and UI** state: which settings groups the user left open, which
/// settings tab they were last on, and whether they want the screen pinned on.
/// No camera parameter is remembered here — every parameter control reads the
/// camera's own value from the live-view JSON, because this firmware answers
/// `200` to commands it ignored and a remembered local value would then be a
/// control that lies. Layout has no such problem: it is the user's, not the
/// camera's.
///
/// The RAW switch is the one entry here that is not layout, and it is stored for the
/// opposite reason to the rest: it decides **how much data a sync spends**, and a
/// choice with a data bill attached must not be re-made by the app on every launch.
/// [includeRaw] carries the argument.
///
/// ## Why the codec is tolerant
///
/// Every read is defensive. A preference file that fails to parse must cost the
/// user their panel arrangement, never their ability to launch the app — the
/// startup path already had one hang caused by code that could not fail safely.
library;

import 'sync_ledger.dart';

/// The language tags this app understands, as stored in the preference file.
///
/// `kLocaleSystem` is not a locale: it means "follow the phone", and it is the
/// default. The other two are the tags the ARB files are named after, so the value
/// in the file is the same string a reader of `lib/l10n/` sees.
///
/// The list lives here, in the Flutter-free half of the app, because that is where
/// the *stored vocabulary* belongs — the same reason the sync mode ids live beside
/// the ledger. `app/lib/l10n/gen` owns what each tag renders as.
const String kLocaleSystem = 'system';
const String kLocaleEnglish = 'en';
const String kLocaleChinese = 'zh';

/// Every value [UiPrefs.localeTag] may legitimately hold.
const List<String> kLocaleTags = <String>[kLocaleSystem, kLocaleEnglish, kLocaleChinese];

/// The user's layout choices, as persisted.
class UiPrefs {
  static const version = 1;

  /// Called for anything worth surfacing. Injected so this file needs no
  /// logging framework.
  final void Function(String message)? onLog;

  final SyncStore _store;

  /// Group ids the user has opened. Absence from both sets means "use the
  /// group's own default", which is why these are *overrides* rather than a full
  /// snapshot: a group added in a later build then gets its own default instead
  /// of being closed because an older file does not mention it.
  final Set<String> _openGroups = {};
  final Set<String> _closedGroups = {};

  /// The last tab the user was on, or null before one has been chosen.
  String? _lastTab;

  /// Whether the live view should pin the screen on while previewing.
  ///
  /// Defaults to true: that is the behaviour the app shipped with, so a first
  /// run must not silently gain a screen timeout it never had.
  bool _keepScreenOn = true;

  /// Which language the interface is drawn in.
  ///
  /// Stored as the tag `'system'` rather than as a `Locale`, because this file is
  /// Flutter-free by contract (`AGENTS.md` §4.1) and `dart:ui`'s `Locale` is not
  /// available in the plain Dart VM the offline checks run in. The UI layer turns
  /// the tag into a `Locale?` — `null` meaning "whatever the phone is set to".
  ///
  /// **`'system'` is the default, and an absent field means `'system'`.** A
  /// preference file written before this setting existed must not decide the
  /// language for a user who never chose one, and a user whose phone is in
  /// Chinese must get Chinese on first launch without touching anything.
  String _localeTag = kLocaleSystem;

  /// Whether a sync should also fetch the RAW half of a RAW+JPEG shot.
  ///
  /// ## Off, and this is the product decision rather than an omission
  ///
  /// Measured on the real 3.1-cn body (`analysis/50`): a `rawJpeg` shot's `.DNG` is
  /// **31,931,408 bytes** against the JPEG's **4,897,837**, and the card that was
  /// measured holds **18** such shots — ~574 MB, over the camera's own access point,
  /// which has **no internet passthrough**, so the phone is offline for the whole
  /// transfer and the 4,897,837 bytes the user has in mind is 31,931,408 per tap.
  ///
  /// `transport/album.dart` (`SyncPlan.skipRaw`) decided this and wrote the reasoning
  /// down. What it did not have was an implementation: `SyncPlan` was constructed
  /// nowhere in `lib/`, every queue path enqueued `AssetGroup.assets` — which includes
  /// the RAW — and so the queue did the opposite of what the documentation said, with
  /// nothing on screen to say so (`analysis/79`, finding #2).
  ///
  /// So the default stays **off**, and the capability becomes reachable instead of
  /// dead: the album's sync bar carries a switch (`toggle-sync-raw`) whose label states
  /// the cost, and this field is what it writes. A user who wants the RAW turns that on
  /// once and it stays on.
  ///
  /// ## Why it is remembered, when the rest of this file is layout
  ///
  /// Because re-deciding it per launch is the failure mode, not the safety. A control
  /// that silently reverts to "off" half-way through a card is a control the user has
  /// to keep re-arming, and the RAW they asked for once is a standing preference about
  /// their own data — the same class of choice as the screen pin beside it.
  bool _includeRaw = false;

  bool _dirty = false;
  bool _loaded = false;

  UiPrefs({SyncStore? store, this.onLog})
      : _store = store ?? MemorySyncStore();

  bool get isLoaded => _loaded;
  String? get lastTab => _lastTab;
  bool get keepScreenOn => _keepScreenOn;
  bool get includeRaw => _includeRaw;
  String get localeTag => _localeTag;
  Set<String> get openGroups => Set.unmodifiable(_openGroups);
  Set<String> get closedGroups => Set.unmodifiable(_closedGroups);

  void setKeepScreenOn(bool on) {
    if (_keepScreenOn == on) return;
    _keepScreenOn = on;
    _dirty = true;
  }

  /// Turn the RAW opt-in on or off. See [includeRaw] for why the default is off.
  void setIncludeRaw(bool on) {
    if (_includeRaw == on) return;
    _includeRaw = on;
    _dirty = true;
  }

  /// Choose the interface language. [tag] is `'system'` or a locale tag.
  ///
  /// An empty tag is ignored rather than stored: `Locale('')` is not a locale, and
  /// a stored empty string would read back as "no preference expressed" at one call
  /// site and as "an unknown locale" at another.
  void setLocaleTag(String tag) {
    if (tag.isEmpty || tag == _localeTag) return;
    _localeTag = tag;
    _dirty = true;
  }

  /// Whether [groupId] should be open.
  ///
  /// [fallback] is the group's own default. An explicit choice always wins, so a
  /// group the user opened stays open even if the default later changes.
  bool isGroupOpen(String groupId, {bool fallback = false}) {
    if (_openGroups.contains(groupId)) return true;
    if (_closedGroups.contains(groupId)) return false;
    return fallback;
  }

  void setGroupOpen(String groupId, bool open) {
    if (groupId.isEmpty) return;
    if (open) {
      if (_openGroups.contains(groupId) && !_closedGroups.contains(groupId)) {
        return;
      }
      _openGroups.add(groupId);
      _closedGroups.remove(groupId);
    } else {
      if (_closedGroups.contains(groupId) && !_openGroups.contains(groupId)) {
        return;
      }
      _closedGroups.add(groupId);
      _openGroups.remove(groupId);
    }
    _dirty = true;
  }

  void toggleGroup(String groupId, {bool fallback = false}) =>
      setGroupOpen(groupId, !isGroupOpen(groupId, fallback: fallback));

  void setLastTab(String tabId) {
    if (tabId.isEmpty || tabId == _lastTab) return;
    _lastTab = tabId;
    _dirty = true;
  }

  bool get isDirty => _dirty;

  Future<void> load() async {
    _loaded = true;
    try {
      final text = await _store.read();
      if (text == null || text.isEmpty) return;
      final decoded = _decode(text);
      _openGroups
        ..clear()
        ..addAll(decoded.open);
      _closedGroups
        ..clear()
        ..addAll(decoded.closed);
      _lastTab = decoded.lastTab;
      _keepScreenOn = decoded.keepScreenOn;
      _includeRaw = decoded.includeRaw;
      _localeTag = decoded.localeTag;
      onLog?.call('ui prefs: ${_openGroups.length} open, '
          '${_closedGroups.length} closed, tab ${_lastTab ?? "(unset)"}, '
          'keep-screen-on $_keepScreenOn, include-raw $_includeRaw, '
          'locale $_localeTag');
    } on Object catch (e) {
      // A layout preference is never worth a failed launch. The panel falls back
      // to its own defaults, which is the same state as a first run.
      onLog?.call('ui prefs: unreadable ($e); using defaults');
    }
  }

  Future<void> save({bool force = false}) async {
    if (!_dirty && !force) return;
    try {
      await _store.write(encode());
      _dirty = false;
    } on Object catch (e) {
      onLog?.call('ui prefs: could not write ($e)');
    }
  }

  /// The wire form. Public so the offline checks can round-trip it directly.
  String encode() {
    final b = StringBuffer('{"version":$version');
    b.write(',"open":[');
    var first = true;
    for (final g in _openGroups) {
      if (!first) b.write(',');
      first = false;
      b.write(quoteJson(g));
    }
    b.write('],"closed":[');
    first = true;
    for (final g in _closedGroups) {
      if (!first) b.write(',');
      first = false;
      b.write(quoteJson(g));
    }
    b.write(']');
    if (_lastTab != null) b.write(',"lastTab":${quoteJson(_lastTab!)}');
    b.write(',"keepScreenOn":$_keepScreenOn');
    b.write(',"includeRaw":$_includeRaw');
    b.write(',"locale":${quoteJson(_localeTag)}');
    b.write('}');
    return b.toString();
  }

  /// What a stored file says.
  ///
  /// A named record rather than a positional one: the three fields are all
  /// collections of the same shape, and transposing two of them by accident
  /// would read back as a plausible but wrong arrangement.
  static ({Set<String> open, Set<String> closed, String? lastTab,
      bool keepScreenOn, bool includeRaw, String localeTag}) _decode(String text) {
    Set<String> list(String key) {
      final m =
          RegExp('"$key"\\s*:\\s*\\[(.*?)\\]', dotAll: true).firstMatch(text);
      if (m == null) return <String>{};
      return RegExp('"((?:[^"\\\\]|\\\\.)*)"')
          .allMatches(m.group(1) ?? '')
          .map((x) => unquoteJson(x.group(1)!))
          .where((s) => s.isNotEmpty)
          .toSet();
    }

    final tabMatch =
        RegExp('"lastTab"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(text);
    final tab = tabMatch == null ? null : unquoteJson(tabMatch.group(1)!);

    // Absent means the default (on), so only an explicit `false` turns it off:
    // a file written by an older build must not switch the screen timeout back
    // on for a user who never touched it.
    final keep = !RegExp('"keepScreenOn"\\s*:\\s*false').hasMatch(text);

    // The mirror of the screen pin, and for the mirror of the reason: absent means
    // the default, and here the default is **off**. A file written before this
    // setting existed must not commit its reader to ~32 MB a shot, and a file written
    // by a build that had the switch must not lose it — `"includeRaw":false` is
    // written explicitly for that reason, so "off" and "never asked" are the same
    // reading and the switch is not silently re-armed or silently disarmed.
    final includeRaw = RegExp('"includeRaw"\\s*:\\s*true').hasMatch(text);

    // Anything that is not one of the tags this build knows reads as "follow the
    // phone" rather than as an unknown locale that renders as English. A file
    // written by a *newer* build — one that added a third language — must leave an
    // older build following the system, not pinned to a language it cannot draw.
    final localeMatch =
        RegExp('"locale"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(text);
    final locale = localeMatch == null ? null : unquoteJson(localeMatch.group(1)!);

    return (
      open: list('open'),
      closed: list('closed'),
      lastTab: (tab?.isEmpty ?? true) ? null : tab,
      keepScreenOn: keep,
      includeRaw: includeRaw,
      localeTag: kLocaleTags.contains(locale) ? locale! : kLocaleSystem,
    );
  }

  /// A JSON string literal for [s], escaped by hand.
  ///
  /// A deliberately small codec rather than `dart:convert`, matching the ledger:
  /// the payload is one flat object of short strings, and keeping it here leaves
  /// this file with no dependency beyond the store. Public because
  /// `tool/verify_transport.dart` checks that the escaping survives a round trip.
  static String quoteJson(String s) {
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

  /// The inverse of [quoteJson].
  static String unquoteJson(String s) => s
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', '\u0000')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t')
      .replaceAll('\u0000', r'\');
}
