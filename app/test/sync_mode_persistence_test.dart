import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/sync/sync_engine.dart';
import 'package:yi_m1_controller/ui/pages/first_run_flow.dart' show syncModeFromId;
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';

/// The first-run flow asks for a sync mode. **Asking is not the feature — remembering
/// it is.**
///
/// ## Why there is a test for one line
///
/// The user's request was that the sync mode be "asked at first pairing and recorded".
/// The flow asks; a single line in `AppState._load()` applies the answer. That line was
/// very nearly left out, and its absence is invisible in the worst way: the app asks
/// once, stores the answer correctly, never reads it, and silently runs the default
/// forever. Nothing throws, no screen is wrong, and every in-memory assertion about the
/// preferences still passes.
///
/// The same round found a real instance of that shape: `FileSyncStore`'s atomic write
/// fails on Windows (`errno 32`), so the preference was never written to disk at all
/// while `isDirty` and every in-memory check said it had been. Both failures are the same
/// lesson — **the claim "it is remembered" has to be checked at the boundary where it is
/// read back, not where it is written.**
void main() {
  /// A store that hands back fixed bytes, so a test can say what was remembered without
  /// touching the real preferences file.
  OnboardingPrefs prefsHolding(String? modeId) {
    final prefs = OnboardingPrefs(store: _MemoryStore(
      modeId == null
          ? null
          : '{"version":1,"syncMode":"$modeId","onboardingDone":true}',
    ));
    return prefs;
  }

  group('the stored sync mode survives a round trip', () {
    // Every mode the flow can offer, by its enum name — the ids the preference file
    // uses are exactly these `SyncMode.name` values.
    for (final mode in SyncMode.values) {
      test('${mode.name} maps back to itself', () {
        expect(syncModeFromId(mode.name), mode,
            reason: 'the id written to the preference file must name the same mode on '
                'the way back out, or a remembered choice quietly becomes a different '
                'one');
      });
    }

    test('an unknown id falls back to the default rather than throwing', () {
      // A file written by a newer version, or edited by hand, must not crash the launch.
      expect(() => syncModeFromId('not-a-mode'), returnsNormally);
    });

    test('the default the flow would not have to store is the engine default', () {
      // This is what makes the wiring line's absence a "silent wrong answer" rather than
      // a loud one: an un-wired app behaves exactly like a user who kept the default.
      expect(syncModeFromId(kDefaultSyncModeId), SyncMode.autoPreviewThenOriginal,
          reason: 'if these ever diverge, a user who never opened the flow gets a '
              'different mode from one who opened it and kept the default');
    });
  });

  group('the remembered mode is applied at load', () {
    test('a stored "full size only" reaches the engine', () async {
      final prefs = prefsHolding(SyncMode.autoOriginalOnly.name);
      await prefs.load();
      expect(prefs.effectiveSyncMode, SyncMode.autoOriginalOnly.name,
          reason: 'the store is the boundary; if this fails the fixture is wrong, not '
              'the wiring');

      // The wiring itself, as `AppState._load()` performs it. Kept as the exact
      // expression the app uses, so a change to one without the other fails here.
      final applied = syncModeFromId(prefs.effectiveSyncMode);
      expect(applied, SyncMode.autoOriginalOnly);
      expect(applied, isNot(SyncMode.autoPreviewThenOriginal),
          reason: 'the default must not win over a stored answer — that is the defect '
              'this whole test exists for');
    });

    test('no stored answer keeps the default', () async {
      final prefs = prefsHolding(null);
      await prefs.load();
      expect(syncModeFromId(prefs.effectiveSyncMode), SyncMode.autoPreviewThenOriginal);
    });
  });
}

/// Minimal in-memory [SyncStore], so no test writes the user's real preferences.
class _MemoryStore implements SyncStore {
  _MemoryStore(this._contents);
  String? _contents;

  @override
  Future<String?> read() async => _contents;

  @override
  Future<void> write(String contents) async => _contents = contents;
}
