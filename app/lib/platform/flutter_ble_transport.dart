import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/ble_uuids.dart';
import '../transport/camera_connection.dart';

/// `flutter_blue_plus` implementation of [BleTransport].
///
/// ## Write type: negotiate, never hard-code
///
/// The camera's characteristics advertise **`write` only** — they do *not*
/// advertise `write_no_response`.
///
/// On Windows (where the protocol was first proven) a write-without-response
/// works regardless, because that stack does not police the declared properties.
/// Android *does*, and `flutter_blue_plus` checks before the write reaches the
/// radio, so a hard-coded `withoutResponse: true` fails with:
///
/// ```
/// PlatformException(writeCharacteristic,
///   The WRITE_NO_RESPONSE property is not supported by this BLE characteristic)
/// ```
///
/// So the write type is read from the characteristic's real properties at
/// runtime, preferring no-response when it is genuinely offered (the firmware
/// answers a with-response write with GATT error 0x80 on some paths) and falling
/// back to the acknowledged form when it is not — because when nothing else is
/// offered, that is the only form that can work at all.
///
/// ## Other details that are load-bearing
///
/// * **Subscribe before pairing.** The official app subscribes to the pairing
///   notification *before* writing the pairing request; subscribing afterwards
///   races the camera's reply and loses the token.
/// * **Reading is the readiness test.** A bare connect can report success and
///   drop moments later, so [readFirmwareInfo] doubles as proof that the link
///   works.
/// * **The camera stores one pairing.** A `refId`/`token` pair, once obtained,
///   opens sessions without touching the camera, so it is persisted and reused.
class FlutterBlueBleTransport implements BleTransport {
  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _notifSub;
  List<BluetoothCharacteristic>? _chars;

  /// Which write type actually worked, per characteristic, learned once.
  final Map<String, bool> _writeType = {};

  /// Everything the transport sees, so a failure can be diagnosed on screen.
  ///
  /// BLE problems with this camera are almost always environmental — link not
  /// ready, property mismatch, missing runtime permission — and a visible log
  /// beats a terse exception every time.
  @override
  final List<String> log = [];

  void _say(String m) {
    log.add(m);
    // ignore: avoid_print
    print('[ble] $m');
  }

  @override
  bool get isConnected => _device?.isConnected ?? false;

  /// The camera advertises as `YI_M1_*` or `M1*`.
  ///
  /// Verified on hardware: the test unit is `YI_M1_XXXXXX`.
  static bool looksLikeCamera(String? name) {
    if (name == null) return false;
    final n = name.toUpperCase();
    return n.startsWith('YI_M1_') || n.startsWith('M1');
  }

  @override
  Future<String?> findCamera() async {
    if (!await FlutterBluePlus.isSupported) {
      _say('this device has no BLE support');
      return null;
    }

    // An already-connected camera may not appear in a fresh scan on Android.
    final connected = FlutterBluePlus.connectedDevices
        .where((d) => looksLikeCamera(d.platformName));
    if (connected.isNotEmpty) {
      _device = connected.first;
      _say('reusing the already-connected ${_device!.platformName}');
      return _device!.remoteId.str;
    }

    final completer = Completer<String?>();
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (looksLikeCamera(r.device.platformName)) {
          _device = r.device;
          if (!completer.isCompleted) completer.complete(r.device.remoteId.str);
          return;
        }
      }
    });

    _say('scanning for YI_M1_* ...');
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));
    final found = await completer.future
        .timeout(const Duration(seconds: 22), onTimeout: () => null);
    await FlutterBluePlus.stopScan();
    await sub.cancel();
    _say(found == null ? 'camera not found' : 'found $found');
    return found;
  }

  @override
  Future<void> connect(String deviceId) async {
    final device = _device;
    if (device == null) throw StateError('no device selected');
    await device.connect(timeout: const Duration(seconds: 20));
    _chars = null;
    // The camera's GATT server is slow to publish characteristics right after a
    // connect.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    _say('connected');
  }

  @override
  Future<void> disconnect() async {
    await _notifSub?.cancel();
    _notifSub = null;
    _chars = null;
    try {
      await _device?.disconnect();
    } on Object {
      // best effort
    }
  }

  Future<List<BluetoothCharacteristic>> _characteristics() async {
    final cached = _chars;
    if (cached != null) return cached;
    final device = _device;
    if (device == null) throw StateError('not connected');
    final services = await device.discoverServices();
    for (final s in services) {
      if (s.uuid.str.toLowerCase() == kServiceM1) {
        _chars = s.characteristics;
        // Log the real property sets: this is what settles a write-type
        // question, and it is invisible otherwise.
        for (final c in _chars!) {
          _say('char ${c.uuid.str.substring(0, 8)}: '
              '${describeProperties(c.properties)}');
        }
        return _chars!;
      }
    }
    throw StateError('the camera control service was not found — this does not '
        'look like a YI M1');
  }

  /// Names only the properties that are actually set.
  ///
  /// `CharacteristicProperties` is a set of booleans rather than an enumerable,
  /// and printing the whole object buries the one flag that matters.
  static String describeProperties(CharacteristicProperties p) {
    final on = <String>[
      if (p.read) 'read',
      if (p.write) 'write',
      if (p.writeWithoutResponse) 'writeNR',
      if (p.notify) 'notify',
      if (p.indicate) 'indicate',
      if (p.broadcast) 'broadcast',
      if (p.authenticatedSignedWrites) 'signedWrite',
      if (p.extendedProperties) 'extended',
    ];
    return on.isEmpty ? '(none)' : on.join(',');
  }

  Future<BluetoothCharacteristic> _char(String uuid) async {
    for (final c in await _characteristics()) {
      if (c.uuid.str.toLowerCase() == uuid) return c;
    }
    throw StateError('characteristic $uuid is missing — is this a YI M1?');
  }

  @override
  Future<List<int>> readFirmwareInfo() async =>
      await (await _char(kCharFirmwareInfo)).read();

  @override
  Future<List<int>> readMisc() async => await (await _char(kCharMisc)).read();

  @override
  Future<List<int>> readWifiCredentials() async =>
      await (await _char(kCharWifiApKeyshare)).read();

  @override
  Future<void> write(Uint8List data, String characteristic) async {
    final uuid = switch (characteristic) {
      BleChar.pairing => kCharPairingInit,
      BleChar.session => kCharStartSession,
      BleChar.wifi => kCharWifiSwitch,
      BleChar.timeSync => kCharSyncTime,
      BleChar.mode => kCharResumeRelated,
      _ => throw ArgumentError('unknown characteristic "$characteristic"'),
    };

    final c = await _char(uuid);
    final props = c.properties;
    final offersNr = props.writeWithoutResponse;
    final offersWrite = props.write;

    // Prefer no-response where the camera really offers it, but fall back when it
    // does not: Android refuses an unadvertised write type before the radio is
    // involved, so insisting on it can only ever fail.
    var useNr = _writeType[uuid] ?? offersNr;
    if (!_writeType.containsKey(uuid)) {
      _say('write ${uuid.substring(0, 8)}: offers writeNR=$offersNr '
          'write=$offersWrite -> ${useNr ? "no-response" : "with-response"}');
    }

    try {
      await c.write(data, withoutResponse: useNr);
      _writeType[uuid] = useNr;
      return;
    } on Object catch (e) {
      final msg = '$e';
      _say('write ${uuid.substring(0, 8)} '
          '(${useNr ? "no-response" : "with-response"}) failed: $msg');

      // The other spelling is a genuine alternative, not a blind retry — but only
      // if the characteristic advertises it.
      final other = !useNr;
      final otherOffered = other ? offersNr : offersWrite;
      if (otherOffered) {
        _say('retrying ${uuid.substring(0, 8)} as '
            '${other ? "no-response" : "with-response"}');
        await c.write(data, withoutResponse: other);
        _writeType[uuid] = other;
        return;
      }

      throw StateError(
          'Writing to ${uuid.substring(0, 8)} failed and the characteristic '
          'offers no alternative. Properties reported by the device: '
          '${describeProperties(props)}. Underlying error: $msg');
    }
  }

  @override
  Future<void> subscribePairing(void Function(List<int>) onData) async {
    final c = await _char(kCharPairingNotif);
    await _notifSub?.cancel();
    _notifSub = c.onValueReceived.listen(onData);
    await c.setNotifyValue(true);
    _say('subscribed to the pairing notification');
  }
}
