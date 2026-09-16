/// Entry point.
///
/// All the real code lives in `lib/` proper:
///
///   protocol/   wire formats, BLE payloads, camera state, parameter tables
///   transport/  BLE, HTTP, UDP live view, album, capture interlock, connection
///   state/      the thin glue the UI binds to
///   ui/         the screens
///
/// The layering is deliberate: everything under `protocol/` and `transport/` is
/// free of Flutter, so the parts most likely to be wrong — the wire formats —
/// are verified against **packets captured from the real camera** by
/// `tool/verify_transport.dart`, without a device or an emulator.
library;

export 'app.dart';
