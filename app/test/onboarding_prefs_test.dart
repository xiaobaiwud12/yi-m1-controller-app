import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';

import 'fakes.dart';

/// The preferences the **first-run flow** records.
///
/// ## Why this file is the one that caught the real defect
///
/// The codec is Flutter-free and would fit a `tool/verify_*.dart` script, but the
/// thing that was actually broken is only visible through the **file**: the first
/// version wrote through `FileSyncStore`, whose atomic write renames a temporary file
/// over the target, and on Windows that rename fails every time with
/// `errno = 32` — so `save()` reported nothing, `isDirty` stayed true, and the
/// preference was **never persisted**. Every in-memory assertion passed. The check
/// that caught it reloads from disk through a fresh object, which is what a later
/// launch does; `PrefsStore`'s own documentation carries the failing output.
void main() {
  // Not a widget test, but the file cases mock a platform channel, and a channel
  // needs a binding. Without this line every case fails with "Binding has not yet
  // been initialized", which says nothing about the codec.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_onboarding_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Left to the OS. The assertions are about the codec, not temp files.
    }
  });

  /// The store the app builds for itself.
  ///
  /// Deliberately the **real** one, with no path argument: the documents directory is
  /// the mocked channel above, so this is the production writer with only the
  /// directory swapped. A hand-built `FileSyncStore` here is what hid the defect.
  SyncStore fileStore() => PrefsStore();

  group('the codec', () {
    test('a fresh file means "never asked"', () async {
      final p = OnboardingPrefs(store: MemorySyncStore());
      await p.load();
      expect(p.isLoaded, isTrue);
      expect(p.onboardingDone, isFalse,
          reason: 'a first run must not look like a completed one');
      expect(p.syncMode, isNull,
          reason: 'no mode has been chosen, so there is nothing to say');
      expect(p.askedSyncMode, isFalse);
      expect(p.effectiveSyncMode, kDefaultSyncModeId,
          reason: 'a user who has answered nothing still needs a usable mode');
    });

    test('every mode name round-trips, and an unknown one is refused', () async {
      // The names are the contract with the sync engine's `SyncMode` enum, which
      // this layer may not import. An unknown name must read back as "no answer"
      // rather than as a mode that does not exist.
      for (final name in kSyncModeIds) {
        final store = MemorySyncStore();
        final p = OnboardingPrefs(store: store)
          ..setSyncMode(name)
          ..setOnboardingDone(true);
        await p.save();

        final back = OnboardingPrefs(store: store);
        await back.load();
        expect(back.syncMode, name);
        expect(back.onboardingDone, isTrue);
      }

      final p = OnboardingPrefs(store: MemorySyncStore())..setSyncMode('wat');
      expect(p.syncMode, isNull, reason: 'an unknown mode is not a mode');
    });

    test('a note with quotes and a backslash survives the codec', () async {
      // The note is written next to the values on purpose, so it has to be able to
      // contain whatever a person types there.
      final store = MemorySyncStore();
      final p = OnboardingPrefs(store: store, note: 'a "note" with \\ and \n')
        ..setSyncMode('manualOnly');
      await p.save();
      final text = await store.read();
      expect(text, contains(r'\"note\"'));
      // And it must not break the values it sits beside.
      final back = OnboardingPrefs(store: store);
      await back.load();
      expect(back.syncMode, 'manualOnly');
    });

    test('an unreadable file falls back to defaults instead of throwing',
        () async {
      // The startup path already hung once on code that could not fail safely. A
      // broken preferences file may cost the user the flow; it must never cost them
      // the launch.
      final p =
          OnboardingPrefs(store: MemorySyncStore('{"version":1,"syncMode'));
      await p.load();
      expect(p.onboardingDone, isFalse);
      expect(p.syncMode, isNull);
      expect(p.isLoaded, isTrue, reason: 'the gate must still be able to decide');
    });

    test('a file from a later build is read leniently', () async {
      // A newer file must not be treated as a first run: that would walk a
      // returning user through the whole introduction again.
      final store = MemorySyncStore('{"version":99,"onboardingDone":true,'
          '"syncMode":"manualOnly","somethingNew":42}');
      final p = OnboardingPrefs(store: store);
      await p.load();
      expect(p.onboardingDone, isTrue);
      expect(p.syncMode, 'manualOnly');
    });
  });

  group('the real file store', () {

    test('records the mode and the completion across a reload', () async {
      final first = OnboardingPrefs(store: fileStore());
      await first.load();
      first.setSyncMode('autoOriginalOnly');
      first.setOnboardingDone(true);
      await first.save();

      // A second instance, as a later launch would build it.
      final second = OnboardingPrefs(store: fileStore());
      await second.load();
      expect(second.onboardingDone, isTrue,
          reason: 'the flow would run again on every launch');
      expect(second.syncMode, 'autoOriginalOnly',
          reason: 'the mode the user chose at pairing time was not remembered');

      final file = File(
          '${tmp.path}${Platform.pathSeparator}$kOnboardingPrefsFileName');
      expect(file.existsSync(), isTrue,
          reason: 'nothing was written, so nothing can be remembered');
    });

    test('a clean save writes nothing and loses nothing', () async {
      final p = OnboardingPrefs(store: fileStore());
      await p.load();
      p.setSyncMode('manualOnly');
      await p.save();
      // A second `save` with no changes must be a no-op rather than a rewrite that
      // could land on a half-written file during an app kill.
      await p.save();
      expect(p.isDirty, isFalse);

      final again = OnboardingPrefs(store: fileStore());
      await again.load();
      expect(again.syncMode, 'manualOnly');
    });
  });
}
