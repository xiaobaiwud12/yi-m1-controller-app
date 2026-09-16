import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';

import 'fakes.dart';

/// The capture interlock must resolve its HTTP client **at capture time**.
///
/// ## The bug this exists for
///
/// `AppState` built the guard with `http: _liveHttp`, and `_liveHttp` is a getter that
/// answers `connection.http` when the link is ready and a detached stub that throws
/// `"not connected to the camera"` when it is not. Passing a getter to a value parameter
/// evaluates it **once** — and `AppState` is constructed at startup, before any link
/// exists. So the guard held the stub for the life of the process and every capture threw
/// before touching the network.
///
/// Reported from hardware as: the shutter does nothing, while parameter changes and the
/// preview work perfectly. Those go to `connection.http` directly; only the capture
/// interlock went through the frozen reference. The camera was blamed for refusing a
/// command it never received.
///
/// ## Why the existing tests missed it
///
/// Every transport test constructs a `CaptureGuard` directly and hands it a working fake.
/// The defect was never in the guard — it was in the **wiring**, in a file none of them
/// touch. So this test builds the real `AppState` and drives a capture through it.
void main() {
  testWidgets('a capture reaches the camera after the link becomes ready',
      (tester) async {
    final commands = <String>[];

    // The seam puts the link straight into `ready`, which is also what makes this a
    // regression test: the guard must see the *ready* client even though it was built
    // during construction.
    final app = AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testPreviewRunning: true,
      testIdentity: const CameraIdentity(
        protocolVersion: 1,
        firmwareVersion: '3.1-cn ',
        regionMarker: 'M1CN',
      ),
      testHttp: CameraHttpClient(overrideSend: (command, params) async {
        commands.add(command);
        return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
      }),
    );
    addTearDown(app.dispose);

    // `runAsync`, because the capture path contains a real `Future.delayed` (the
    // minimum interval between captures) and a widget test's fake-async zone waits for
    // it forever — the suite hung until this was wrapped. Same trap as the album page's
    // disk read.
    late CaptureResult r;
    await tester.runAsync(() async {
      // Let the constructor's `_onLinkStatus` run, so the link is ready as it is on a
      // real connect.
      await Future<void>.delayed(Duration.zero);
      r = await app.shoot();
    });

    expect(commands, contains('RCDoShooting'),
        reason: 'the shutter must reach the camera. If this fails the guard is holding '
            'a client captured before the link existed, and the camera is being blamed '
            'for a command it never received');
    expect(r.outcome, isNot(CaptureOutcome.transportError),
        reason: 'a transport error here is the wiring defect, not a camera problem: '
            '${r.reason}');
  });

  testWidgets('the refused message names the camera only when the camera answered',
      (tester) async {
    final app = AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testPreviewRunning: true,
      testIdentity: const CameraIdentity(
        protocolVersion: 1,
        firmwareVersion: '3.1-cn ',
        regionMarker: 'M1CN',
      ),
      testHttp: CameraHttpClient(overrideSend: (command, params) async {
        if (command == 'RCDoShooting') {
          return const CameraResponse(
            code: 1000,
            data: 'photo fail',
            raw: '{"code":1000,"data":"photo fail"}',
          );
        }
        return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
      }),
    );
    addTearDown(app.dispose);

    late CaptureResult r;
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      r = await app.shoot();
    });

    // A real refusal: the reply is carried, so the UI can quote the camera rather than
    // a sentence the app composed.
    expect(r.outcome, CaptureOutcome.rejected);
    expect(r.response?.code, 1000);
  });
}
