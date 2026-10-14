import 'sync_engine.dart';

/// Kept so `SyncMode` remains the single authority on what the names mean.
///
/// [kSyncModeChoices] stores the *names* the preference file holds; this maps them
/// back for anyone who needs the enum, and it is the reason the ids above are not
/// invented strings. `analysis/56` §6 names the call the sync owner has to add.
SyncMode syncModeFromId(String id) => switch (id) {
      'autoOriginalOnly' => SyncMode.autoOriginalOnly,
      'manualOnly' => SyncMode.manualOnly,
      _ => SyncMode.autoPreviewThenOriginal,
    };
