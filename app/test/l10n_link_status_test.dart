import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/l10n/message_text.dart';
import 'package:yi_m1_controller/transport/camera_connection.dart';

import 'fakes.dart';

/// Does a message code actually **reach** the status it belongs to?
///
/// ## Why this file exists, and what it says about the check next door
///
/// `l10n_message_codes_test.dart` compares the *set* of codes the producers declare
/// (`LinkCodes.all`, …) against the set the resolver handles. That check passes when a
/// code is declared and resolvable — and it passed while the app displayed **lowercase
/// English `not connected`** on a Chinese phone, because the code was never *attached*
/// to anything. `LinkCodes.idle` was in the set, `linkIdle` was in the ARB, the
/// resolver had a case for it, and `CameraConnection._current` — a `const` value that
/// does not go through `_emit` — carried no code at all.
///
/// That is `AGENTS.md` §8's "green but checking nothing" in a new shape: the check
/// compared two **tables** and never exercised a **producer**. This file exercises the
/// producers: it drives a real `CameraConnection` and asserts that every status it hands
/// to the UI can be drawn in the reader's language.
void main() {
  // `AppState` registers itself as a `WidgetsBindingObserver` in its constructor, so
  // the binding has to exist before one is built — the same requirement every widget
  // test satisfies implicitly by pumping.
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Codes whose sentence this app did not write, so there is nothing to translate.
  ///
  /// Exactly one entry, and it is a decision rather than an oversight:
  /// `CameraConnection.connect`'s bare `catch (e)` emits `'$e'`, an arbitrary platform
  /// exception. Inventing a Chinese sentence for text whose content is unknown would
  /// replace a true diagnostic with a plausible false one.
  const untranslatableByDesign = <String>{};

  test('every status the connection hands the UI carries a code', () async {
    final connection = CameraConnection(
      ble: FakeBleTransport(),
      store: MemoryPairingStore(),
    );

    final seen = <LinkStatus>[];
    final sub = connection.status.listen(seen.add);
    addTearDown(sub.cancel);
    addTearDown(connection.dispose);

    // The status the shooting page draws *before anybody presses Connect* — the one
    // that shipped without a code, and the one the maintainer saw.
    seen.add(connection.current);

    // Then a real sequence. `FakeBleTransport.findCamera` answers null, so `connect`
    // walks the first two `_emit` calls and fails; a liveness miss is reported the way
    // the app layer reports it.
    await connection.connect(pairWait: const Duration(milliseconds: 1));
    connection.reportLost('a sentence the app layer composed',
        code: LinkCodes.lostContact);

    // `status` is a broadcast controller, so a listener is called on a later microtask.
    // Without this the check would inspect one status and pass.
    await pumpEventQueue();

    expect(seen.length, greaterThanOrEqualTo(4),
        reason: 'the fixture did not drive the connection — it saw ${seen.length} '
            'statuses, and a check over an empty list passes for the wrong reason');

    final uncoded = <String>[];
    for (final s in seen) {
      if (s.messageCode == null && !untranslatableByDesign.contains(s.message)) {
        uncoded.add('${s.stage}: "${s.message}"');
      }
    }
    expect(uncoded, isEmpty,
        reason: 'these statuses can only ever be drawn in English, because nothing '
            'in them names a translation:\n${uncoded.join('\n')}');
  });

  test('the idle status the app launches with reads Chinese on a Chinese phone',
      () {
    // The defect, asserted at the level it was reported: the sentence drawn before any
    // interaction, resolved for a reader whose phone is in Chinese.
    const idle = LinkStatus(
      stage: LinkStage.idle,
      message: 'not connected',
      messageCode: LinkCodes.idle,
    );
    expect(linkStatusText(chineseStrings, idle), '未连接');
    expect(linkStatusText(englishStrings, idle), 'not connected');

    // And the control: with no code the English is what a Chinese reader gets, which
    // is exactly what was on the phone.
    const uncoded = LinkStatus(stage: LinkStage.idle, message: 'not connected');
    expect(linkStatusText(chineseStrings, uncoded), 'not connected');
  });

  test('a link code resolves even when it arrives through AppState', () {
    // The second half of the leak. `AppState.connect` copies a `LinkStatus`'s sentence
    // into `lastError`, and the strip that draws `lastError` never calls
    // `linkStatusText` — so before `linkCodeText` existed the code was either stripped
    // (and the string fell through as English) or would have been ignored as a foreign
    // code. Both fields go through one table now.
    final app = testAppState();
    addTearDown(app.dispose);

    app
      ..lastError = 'not connected'
      ..lastErrorCode = LinkCodes.idle;
    expect(appErrorText(chineseStrings, app), '未连接');
    expect(appErrorText(englishStrings, app), 'not connected');

    app
      ..lastError = 'Lost contact with the camera.'
      ..lastErrorCode = LinkCodes.lostContact;
    expect(appErrorText(chineseStrings, app), contains('失去联系'));

    // And an unknown code still falls back to the string rather than to nothing.
    app
      ..lastError = 'something from a newer build'
      ..lastErrorCode = 'linkSomethingNewer';
    expect(appErrorText(chineseStrings, app), 'something from a newer build');
  });
}
