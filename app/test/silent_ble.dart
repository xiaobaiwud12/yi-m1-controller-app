import 'dart:typed_data';

import 'fakes.dart';

/// A BLE transport that finds the camera, reads its identity — and then never
/// answers the pairing write.
///
/// ## Why this exists
///
/// `LinkStage.awaitingUserConfirm` is the state a real body sits in while the user
/// walks over and presses **Accept**: the request is out, the camera has it, and
/// the outcome belongs to a human. No seam in the project could produce that state
/// — `FakeBleTransport` refuses at `findCamera()` and the injected-HTTP seam jumps
/// straight to `ready` — so a screen whose whole job is to render "this is waiting
/// for you, not for the app" could only be tested against a fabricated status,
/// which is the thing the screen must not do.
///
/// It is deliberately **not** in `fakes.dart`: that file is shared with the rest of
/// the suite, and a transport whose contract is "never completes" is the kind of
/// fixture that quietly makes another test hang rather than fail.
///
/// Nothing here is a claim about the camera. The firmware-info bytes are the shape
/// `parseFirmwareInfo` expects, which is all the state machine needs; whether a real
/// camera answers that way is verified at the BLE layer, not here.
class SilentBleTransport extends FakeBleTransport {
  @override
  Future<String?> findCamera() async => 'AA:BB:CC:DD:EE:FF';

  @override
  Future<void> connect(String deviceId) async {}

  @override
  Future<List<int>> readFirmwareInfo() async {
    // The real characteristic's payload shape — `1,3.1-cn ,M1CN,0.0` — because
    // `parseFirmwareInfo` splits on commas and returns null for anything with fewer
    // than two fields. A first version returned the fields with no separators, and
    // the state machine stopped at "camera answered with an unreadable identity",
    // which is a failure of the *fixture* that looks like a failure of the app.
    return '1,3.1-cn ,M1CN,0.0'.codeUnits;
  }

  @override
  Future<void> subscribePairing(void Function(List<int>) onData) async {
    // Subscribed and then silent, exactly as the real characteristic is until
    // somebody presses the button on the camera.
  }

  @override
  Future<void> write(Uint8List data, String characteristic) async {
    // A BLE write is fire-and-forget; the pairing result arrives on the
    // characteristic above, which never fires.
  }
}
