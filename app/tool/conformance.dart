/// Cross-language conformance test for the wire formats.
///
/// Run with the plain Dart VM - no Flutter, no device:
///
///     dart run tool/conformance.dart
///
/// The CRC32 vectors below were produced by Python's `zlib.crc32`, the same
/// function the verified community client uses and the same one the official
/// app's `java.util.zip.CRC32` reproduces.  If this file passes, the Dart
/// implementation agrees with both, which is what the camera checks.
library;

import 'dart:convert';

import '../lib/protocol/wire_format.dart';

int _pass = 0;
int _fail = 0;

void check(String name, Object? got, Object? want) {
  final ok = got == want;
  if (ok) {
    _pass++;
    print('  PASS  $name');
  } else {
    _fail++;
    print('  FAIL  $name\n          got  $got\n          want $want');
  }
}

void main() {
  print('wire-format conformance\n');

  // ------------------------------------------------------------------ CRC32
  print('[crc32] must equal Python zlib.crc32');
  // vectors generated with: zlib.crc32(b"...")
  check('crc32("") == 0', zlibCrc32(const []), 0);
  check('crc32("a")', zlibCrc32(utf8.encode('a')), 0xE8B7BE43);
  check('crc32("abc")', zlibCrc32(utf8.encode('abc')), 0x352441C2);
  check('crc32("123456789")', zlibCrc32(utf8.encode('123456789')), 0xCBF43926);
  check('crc32("The quick brown fox jumps over the lazy dog")',
      zlibCrc32(utf8.encode('The quick brown fox jumps over the lazy dog')),
      0x414FA339);
  // the session material shape: "1" + key + token
  check('crc32("1" + 12345 + "928374651")',
      zlibCrc32(utf8.encode('112345928374651')), 0x65F4FD1F);

  // ------------------------------------------------------- firmware-info
  print('\n[firmware-info] real payload from the test camera');
  // exactly what YI_M1_XXXXXX returned
  final raw = ascii.encode('1,3.1-cn ,M1CN,0.0');
  final padded = [...raw, ...List<int>.filled(13, 0)];
  final id = parseFirmwareInfo(padded);
  check('parsed non-null', id != null, true);
  check('protocolVersion', id?.protocolVersion, 1);
  // The camera really does send a trailing space here ("1,3.1-cn ,M1CN,0.0"),
  // and the official app stores the field untrimmed rather than normalising it.
  // We preserve it verbatim so the value can be compared against the app's.
  check('firmwareVersion verbatim (trailing space kept)',
      id?.firmwareVersion, '3.1-cn ');
  check('regionMarker', id?.regionMarker, 'M1CN');
  check('lensFirmware', id?.lensFirmware, '0.0');
  check('isChinaModel', id?.isChinaModel, true);

  check('too-short payload rejected', parseFirmwareInfo(ascii.encode('1')), null);
  final intl = parseFirmwareInfo(ascii.encode('1,M1,M1INT,1.1'));
  check('international region', intl?.regionMarker, 'M1INT');
  check('international is not china', intl?.isChinaModel, false);
  check('three-field lens fallback',
      parseFirmwareInfo(ascii.encode('1,3.1-cn,M1CN'))?.lensFirmware, '');
  check('region is trimmed even when the field has padding',
      parseFirmwareInfo(ascii.encode('1,3.1-cn ,M1CN ,0.0'))?.regionMarker,
      'M1CN');

  // ------------------------------------------------------------- pairing
  print('\n[pairing]');
  check('pairing request shape',
      buildPairingRequest(protocolVersion: 1, key: 12345), '1,12345,android');
  check('empty notification means refusal', parsePairingResult(const []), null);
  check('nul-padded notification is empty',
      parsePairingResult(const [0, 0, 0]), null);
  check('token is returned verbatim',
      parsePairingResult(ascii.encode('928374651')), '928374651');
  final key = generatePairingKey();
  check('generated key in range', key >= 0 && key <= 99998, true);

  // ------------------------------------------------------------- session
  print('\n[session]');
  check(
      'session request shape',
      buildSessionRequest(protocolVersion: 1, key: 12345, token: '928374651'),
      '1,12345,1710554399');

  // --------------------------------------------------------------- wifi
  print('\n[wifi]');
  final creds = parseWifiCredentials(ascii.encode('YI_M1_XXXXXX,12345678'));
  check('ssid', creds?.ssid, 'YI_M1_XXXXXX');
  check('passkey', creds?.passkey, '12345678');
  check('malformed rejected', parseWifiCredentials(ascii.encode('onlyssid')), null);
  check('empty parts rejected',
      parseWifiCredentials(ascii.encode('ssid,')), null);

  // --------------------------------------------------------------- time
  print('\n[time-sync] epoch seconds, confirmed against the official app');
  check('epoch seconds',
      buildTimeSyncPayload(DateTime.utc(2026, 9, 13, 12, 0, 0)), '1789300800');
  check('ordering holds',
      int.parse(buildTimeSyncPayload(DateTime.utc(2026, 1, 1))) <
          int.parse(buildTimeSyncPayload(DateTime.utc(2026, 6, 1))),
      true);

  print('\n$_pass passed, $_fail failed');
}
