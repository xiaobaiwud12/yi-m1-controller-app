import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/state/app_state.dart';

/// Finding #8 of `analysis/79`: the ISO wire key has two spellings and nothing pinned
/// them.
///
/// `setParam('RCISOSet', …)` sends the parameter key **`ISO`**; the result of that
/// command appears in the live-view state JSON under **`ISOSetting`**. The audit called
/// this the only one of the thirteen where send and read differ — **it is not**; writing
/// the check in `verify_transport.dart` turned up a second, `RCSwitchDialMode`
/// (`DialMode` → `ExposureMode`). Both are now declared, and the count is asserted, so
/// the corrected fact cannot drift back.
///
/// ## Why this file exists rather than more of `verify_transport.dart`
///
/// `AppState` imports `package:flutter`, so the pure-VM `verify_transport.dart` cannot
/// read it — that file keeps a hand-written copy of the send keys for exactly that
/// reason. This test runs in the widget layer, where `AppState` **is** reachable, so it
/// is the half that compares the two tables against the real declarations instead of
/// against a copy.
///
/// The other half — that the read-back field names are fields the firmware really sends,
/// pinned against the recorded parameter block — is in `verify_transport.dart`, because
/// the capture is read with `dart:io` and needs no engine.
void main() {
  /// The two commands whose outbound key is not the field it is read back from.
  ///
  /// Both are the firmware's own vocabulary on the inbound side, so neither can be
  /// "tidied" to match the other without breaking the read.
  const knownRenames = <String, (String, String)>{
    'RCISOSet': ('ISO', 'ISOSetting'),
    'RCSwitchDialMode': ('DialMode', 'ExposureMode'),
  };

  test('the two parameter tables cover exactly the same commands', () {
    final send = AppState.paramCommands;
    final read = paramStateKeys;
    expect(send.keys.toSet(), read.keys.toSet(),
        reason: 'a command that sends a parameter but names no state field draws a '
            'blank control; one that names a field but cannot be sent is a control '
            'that does nothing');
    expect(send.length, 13, reason: 'the firmware has thirteen settable parameters');
  });

  test('only the two known commands rename their key, and both are named here', () {
    final observed = <String, (String, String)>{
      for (final e in AppState.paramCommands.entries)
        if (paramStateKeys[e.key] != e.value)
          e.key: (e.value, paramStateKeys[e.key]!),
    };
    expect(observed, knownRenames,
        reason: 'this is the finding, stated as a check. A tidy-up that renames ISO or '
            'DialMode to match their neighbours fails here, and so does a **third** '
            'rename — which is what the audit missed when it said ISO was the only one');
  });

  test('every send key is a value the firmware parameter pools know', () {
    // Not every send key is a *pool* key — `DialMode`, `EV` and `ColorMode` are not —
    // so this asserts the weaker, true thing: the key is one the camera-state JSON also
    // uses, or the command is one of the three the pools do not carry. Asserted so a
    // typo in `paramCommands` lands somewhere rather than being sent verbatim.
    for (final e in AppState.paramCommands.entries) {
      expect(e.value, isNotEmpty, reason: '${e.key} has an empty parameter key');
      expect(e.value.trim(), e.value,
          reason: '${e.key} has whitespace in its parameter key');
    }
  });

  test('the read-back accessor and the raw field agree, for every command', () {
    // `CameraState.isoSetting` reads `raw['ISOSetting']` and `paramStateKeys['RCISOSet']`
    // is `ISOSetting`. If those two ever disagree, this file's whole subject is back:
    // one of them is the truth and the other is a blank control.
    const st = CameraState({
      'ExposureMode': 'M',
      'MeteringMode': 'Spot',
      'ImageQuality': '20',
      'ImageAspect': '4:3',
      'FileFormat': 'RAWJ-L',
      'DriveMode': 'Single',
      'Fnumber': '1.7',
      'ShutterSpeed': '1/30s',
      'EV': '0.0',
      'ISOSetting': '400',
      'WB': 'Auto',
      'ColorMode': 'Standard',
      'FocusMode': 'S-AF',
    });
    expect(st.valueForParamCommand('RCISOSet'), '400');
    expect(st.valueForParamCommand('RCISOSet'), st.isoSetting,
        reason: 'the UI table and the typed accessor must read the same field');
    expect(st.valueForParamCommand('RCFNSet'), st.fNumber);
    expect(st.valueForParamCommand('RCWBSet'), st.whiteBalance);
    expect(st.valueForParamCommand('RCSwitchDialMode'), st.exposureMode);
    expect(st.valueForParamCommand('RCShutterSpeedSet'), st.shutterSpeed);
    expect(st.valueForParamCommand('RCEVSet'), st.exposureCompensation);
    // The trap the finding is about: neither *send* key is a state field.
    expect(st.raw.containsKey('ISO'), isFalse,
        reason: 'if `ISO` ever appears in the state block, the read-back field name has '
            'changed and `paramStateKeys` is now wrong for a different reason');
    expect(st.raw.containsKey('DialMode'), isFalse,
        reason: 'the same for the mode command: `DialMode` is a request key, and the '
            'state carries `ExposureMode`');
  });
}
