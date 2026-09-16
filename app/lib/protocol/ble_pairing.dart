/// BLE pairing / session handshake for the YI M1.
///
/// This is a faithful port of the verified community implementation
/// (`xiaoyi_m1_re_liveview/prot_ble/ble_keyhack.py`).  The important thing to
/// understand about this protocol is that it is **plaintext and effectively
/// unauthenticated**:
///
///  * the pairing key is a random integer in 0..99998 sent in the clear;
///  * the session "checksum" is a plain CRC32 over `"1" + key + token`, not a
///    MAC and not a signature - it proves nothing, it only keeps the camera's
///    parser happy;
///  * the camera stores exactly ONE pairing at a time, so pairing from a new
///    client silently invalidates the official app's pairing.
///
/// Ported here as pure functions with no I/O so it can be unit-tested without a
/// camera, and so the transport layer stays swappable.
library;

import 'dart:convert';
import 'dart:math';

import 'ble_uuids.dart';

/// Result of reading [kCharFirmwareInfo].
class CameraIdentity {
  /// BLE protocol revision the camera negotiated (field 0), e.g. 1.
  final int protocolVersion;

  /// Body firmware / model id, e.g. `M1`.
  final String bodyFirmware;

  /// Region marker: `M1INT` for the international build, `M1CN` / `M1` for China.
  final String regionMarker;

  /// Lens firmware version, if reported.
  final String lensFirmware;

  const CameraIdentity({
    required this.protocolVersion,
    required this.bodyFirmware,
    required this.regionMarker,
    this.lensFirmware = '',
  });

  /// Whether this is a global (non-China) unit.
  ///
  /// A region marker that is empty falls back to the body firmware string, and
  /// anything that is neither empty nor one of the China markers (`M1CN`, `M1`)
  /// counts as global.
  ///
  /// NOTE: the community reference implementation's helper
  /// (`check_is_global_variant` -> `str_check_china`) is a tautology - its
  /// `or id != "M1INT"` clause makes it true for every string, so the reference
  /// effectively reports "global" only when the marker is exactly `M1INT`.
  /// This port implements the *stated* intent instead. In practice both agree on
  /// all real payloads, because the firmware only ever emits `M1INT` or `M1CN`.
  bool get isGlobalVariant {
    final marker = regionMarker.isEmpty ? bodyFirmware : regionMarker;
    return marker.isNotEmpty && marker != 'M1CN' && marker != 'M1';
  }

  @override
  String toString() =>
      'CameraIdentity(protocol=$protocolVersion, body=$bodyFirmware, '
      'region=$regionMarker, lens=$lensFirmware, global=$isGlobalVariant)';
}

/// Parse the ASCII payload of [kCharFirmwareInfo], e.g. `"1,M1,M1INT,1.1"`.
///
/// Returns null when the payload is too short to identify the camera.
CameraIdentity? parseFirmwareInfo(List<int> raw) {
  final text = trimAscii(raw);
  final parts = text.split(',');
  if (parts.length < 3) return null;

  return CameraIdentity(
    protocolVersion: int.tryParse(parts[0]) ?? 0,
    bodyFirmware: parts[1],
    regionMarker: parts[2],
    lensFirmware: parts.length > 3 ? parts[3] : '',
  );
}

/// Strip trailing NULs and decode as ASCII - the camera pads its strings.
String trimAscii(List<int> raw) =>
    ascii.decode(raw, allowInvalid: true).replaceAll('\u0000', '').trim();

/// Payload for [kCharPairingInit]: `"<protocol>,<key>,<clientName>"`.
///
/// The reference client uses the literal client name `android`.
String buildPairingRequest({required int protocolVersion, required int key}) =>
    '$protocolVersion,$key,android';

/// Payload for [kCharStartSession]: `"<protocol>,<key>,<checksum>"`.
///
/// The checksum is `crc32(ascii("1" + key + token))` - a plain CRC32, not a
/// keyed MAC.  `crc32` must be the zlib variant, which Dart does not ship; see
/// [zlibCrc32].
String buildSessionRequest({
  required int protocolVersion,
  required int key,
  required String token,
}) {
  final material = utf8.encode('1$key$token');
  return '$protocolVersion,$key,${zlibCrc32(material)}';
}

/// Parse the [kCharPairingNotif] payload.
///
/// An empty payload means the pairing request was denied; anything else is the
/// session token.
String? parsePairingResult(List<int> raw) {
  final token = trimAscii(raw);
  return token.isEmpty ? null : token;
}

/// Parse the [kCharWifiApKeyshare] payload `"<ssid>,<passkey>"`.
///
/// Returns null unless both fields are present and non-empty.
({String ssid, String passkey})? parseWifiCredentials(List<int> raw) {
  final parts = trimAscii(raw).split(',');
  if (parts.length != 2) return null;
  if (parts[0].isEmpty || parts[1].isEmpty) return null;
  return (ssid: parts[0], passkey: parts[1]);
}

/// A random pairing key in 0..99998 inclusive, matching the reference client.
int generatePairingKey([Random? random]) =>
    (random ?? Random.secure()).nextInt(99999);

/// zlib/IEEE 802.3 CRC-32, computed with an unsigned 32-bit result.
///
/// Dart's `dart:convert` has no CRC, and the camera expects the same value the
/// Python reference obtains from `zlib.crc32`.
int zlibCrc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Time-sync payload: Unix epoch seconds as ASCII decimal.
///
/// Not confirmed against the official app - see [kCharSyncTime].  Kept as a
/// single function so that, once confirmed, only one place needs changing.
String buildTimeSyncPayload(DateTime now) =>
    '${now.toUtc().millisecondsSinceEpoch ~/ 1000}';
