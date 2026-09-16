/// Pure protocol logic with NO Flutter or plugin dependencies.
///
/// `ble_pairing.dart` carries the full documentation, but it imports the UUID
/// table only for constants.  This file holds the parts that can be exercised by
/// the plain Dart VM, so the wire formats can be tested against the Python
/// reference implementation without a device, an emulator, or a Flutter engine.
library;

import 'dart:convert';
import 'dart:math';

/// Parsed payload of the firmware-info characteristic, e.g. `1,3.1-cn ,M1CN,0.0`.
class CameraIdentity {
  /// BLE protocol revision the camera reports (field 0).
  final int protocolVersion;

  /// Firmware version string (field 1), e.g. `3.1-cn `.
  final String firmwareVersion;

  /// Region marker (field 2): `M1INT` or `M1CN`.
  final String regionMarker;

  /// Lens firmware version (field 3), when present.
  final String lensFirmware;

  const CameraIdentity({
    required this.protocolVersion,
    required this.firmwareVersion,
    required this.regionMarker,
    this.lensFirmware = '',
  });

  /// Whether this is an international unit.
  ///
  /// The official app compares the camera's region against a stored app region
  /// and refuses to proceed on a mismatch (its error 112, "相机与App版本不兼容").
  /// That is a policy check in the app, not a capability of the hardware, so the
  /// value is exposed rather than enforced here.
  bool get isChinaModel => regionMarker == 'M1CN' || regionMarker == 'M1';

  @override
  String toString() => 'CameraIdentity(protocol: $protocolVersion, fw: '
      '"$firmwareVersion", region: "$regionMarker", lens: "$lensFirmware")';
}

/// Strip trailing NULs (the camera pads its strings) and decode as ASCII.
String trimAscii(List<int> raw) =>
    ascii.decode(raw, allowInvalid: true).replaceAll('\u0000', '').trim();

/// Parse the firmware-info payload.  Returns null when there are fewer than two
/// comma-separated fields, matching the official app's `length >= 2` guard.
CameraIdentity? parseFirmwareInfo(List<int> raw) {
  final parts = trimAscii(raw).split(',');
  if (parts.length < 2) return null;
  return CameraIdentity(
    protocolVersion: int.tryParse(parts[0]) ?? 0,
    firmwareVersion: parts[1],
    regionMarker: parts.length > 2 ? parts[2].trim() : '',
    lensFirmware: parts.length > 3 ? parts[3].trim() : '',
  );
}

/// Payload for the pairing characteristic: `"<protocol>,<key>,android"`.
///
/// Verified against the decompiled official app, which builds exactly
/// `protocolVersion + "," + randomKey + ",android"` with the key a random
/// integer in 0..99998.
String buildPairingRequest({
  required int protocolVersion,
  required int key,
}) =>
    '$protocolVersion,$key,android';

/// Payload for the session characteristic: `"<protocol>,<key>,<crc32>"`.
///
/// The official app computes the checksum as three successive CRC32 updates over
/// `"1"`, the key, and the token - which is identical to one CRC32 over the
/// concatenation, and that is what this does.
String buildSessionRequest({
  required int protocolVersion,
  required int key,
  required String token,
}) =>
    '$protocolVersion,$key,${zlibCrc32(utf8.encode('1$key$token'))}';

/// An empty pairing notification means the camera refused the request.
/// Verified: the official app maps that to its error 110, shown to the user as
/// "已忽略相机端蓝牙配对" (the camera ignored the pairing).
String? parsePairingResult(List<int> raw) {
  final token = trimAscii(raw);
  return token.isEmpty ? null : token;
}

/// Parse `"<ssid>,<passkey>"`.  Returns null unless both parts are present.
({String ssid, String passkey})? parseWifiCredentials(List<int> raw) {
  final parts = trimAscii(raw).split(',');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  return (ssid: parts[0], passkey: parts[1]);
}

/// Time-sync payload.
///
/// Verified against the official app: it writes `(currentTimeMillis / 1000)`
/// as an ASCII decimal string, i.e. Unix epoch seconds.  The camera has no RTC,
/// so this must be sent after the session is open or every photo gets a wrong
/// capture date.
String buildTimeSyncPayload(DateTime utcNow) =>
    '${utcNow.toUtc().millisecondsSinceEpoch ~/ 1000}';

/// A random pairing key in 0..99998 inclusive, as the official app generates.
int generatePairingKey([Random? random]) =>
    (random ?? Random.secure()).nextInt(99999);

/// zlib / IEEE 802.3 CRC-32, with an unsigned 32-bit result.
///
/// Dart ships no CRC, and the camera expects the same value Python's
/// `zlib.crc32` produces, so this must match bit for bit.
int zlibCrc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
