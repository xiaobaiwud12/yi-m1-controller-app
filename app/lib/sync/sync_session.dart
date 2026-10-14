import 'dart:async';

import '../transport/album.dart';
import '../transport/http_transport.dart';
import '../transport/stream_pause.dart';
import 'asset_sink_contract.dart';
import 'sync_engine.dart';
import 'sync_ledger.dart';
import 'transfer_queue.dart';

/// Owns the resources for one durable sync session, independently of widgets.
/// Platform stores/sinks and current camera providers are injected by the app.
class SyncSession {
  final SyncLedger ledger;
  final TransferQueue queue;
  late final SyncEngine engine;
  late final HttpStreamPauseController streamPause;

  SyncSession({
    required SyncStore ledgerStore,
    required SyncStore queueStore,
    required AssetSink sink,
    required CameraAlbum Function() album,
    required CameraHttpClient Function() http,
    required bool Function() previewRunning,
    void Function()? onChanged,
    void Function(String)? onLog,
  })  : ledger = SyncLedger(store: ledgerStore),
        queue = TransferQueue(store: queueStore) {
    streamPause = HttpStreamPauseController(
      http: http,
      isAvailable: previewRunning,
      onLog: onLog,
    );
    engine = SyncEngine(
      album: album,
      ledger: ledger,
      sink: sink,
      queue: queue,
      streamPause: streamPause,
      onQueueChanged: () => unawaited(queue.save()),
      onChanged: onChanged,
      onLog: onLog,
    );
  }

  /// The ledger must precede the queue restore: it decides what already arrived.
  /// Preference loading and restore stay with the existing AppState startup order.
  Future<void> loadStores() async {
    await ledger.load();
    await queue.load();
  }
}
