import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/l10n/message_text.dart';
import 'package:yi_m1_controller/protocol/settings_menu.dart';
import 'package:yi_m1_controller/l10n/settings_menu_l10n.dart';
import 'package:yi_m1_controller/l10n/param_labels.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/sync_engine.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/album_delete.dart';
import 'package:yi_m1_controller/transport/camera_connection.dart';

/// The checks that keep the message-code decision honest, plus the two catalogs that
/// are keyed by a Flutter-free layer's own ids.
///
/// ## What is actually at risk
///
/// The design (`lib/l10n/message_text.dart` records the argument) lets the transport
/// and sync layers raise a *code plus parameters* while keeping their English sentence
/// as the fallback. The cost of that shape is the failure mode these tests exist for:
/// **a code with no case in the resolver renders English, silently and correctly**, so
/// nothing else in the suite would ever notice. Comparing the producers' own code sets
/// against [kHandledMessageCodes] turns that into a build failure.
void main() {
  group('message codes', () {
    test('every code the producers raise is handled by the resolver', () {
      final unhandled = <String>[
        ...LinkCodes.all,
        ...AlbumErrorCodes.all,
        ...SyncStageCodes.all,
        ...SyncNoteCodes.all,
        ...DeleteRefusalCodes.all,
        ...AppNoticeCodes.all,
      ].where((c) => !kHandledMessageCodes.contains(c)).toList()
        ..sort();
      expect(unhandled, isEmpty,
          reason: 'these codes would render the English fallback in a Chinese UI: '
              '$unhandled');
    });

    test('the resolver handles nothing the producers do not raise', () {
      final all = <String>{
        ...LinkCodes.all,
        ...AlbumErrorCodes.all,
        ...SyncStageCodes.all,
        ...SyncNoteCodes.all,
        ...DeleteRefusalCodes.all,
        ...AppNoticeCodes.all,
      };
      final orphans = kHandledMessageCodes.difference(all).toList()..sort();
      expect(orphans, isEmpty,
          reason: 'a case for a code nobody raises is a translation that can never '
              'be seen, and it hides the next real omission: $orphans');
    });

    test('every link status code renders English as the transport wrote it', () {
      // The anti-drift check. English is the source of truth in the ARB *and* the
      // fallback lives in the transport; if those two ever disagree, one of them is
      // lying about what the app says. Comparing them forces any rewording to be
      // deliberate in both places.
      final wrong = <String>[];
      for (final code in LinkCodes.all) {
        final status = LinkStatus(
          stage: LinkStage.ready,
          message: _englishFor(code),
          messageCode: code,
          messageParams: _paramsFor(code),
        );
        final rendered = linkStatusText(englishStrings, status);
        if (rendered != status.message) {
          wrong.add('$code:\n  ARB:     $rendered\n  transport: ${status.message}');
        }
      }
      expect(wrong, isEmpty,
          reason: 'the ARB English and the transport sentence disagree:\n'
              '${wrong.join('\n')}');
    });

    test('a status with no code renders its own sentence', () {
      // The documented fallback path. `CameraConnection.connect`'s bare `catch`
      // deliberately attaches no code: `$e` is a platform exception this app did not
      // write, and inventing a translation for unknown text would replace a true
      // diagnostic with a plausible false one.
      const status = LinkStatus(
        stage: LinkStage.failed,
        message: 'SocketException: Connection refused (OS Error: ...)',
      );
      expect(linkStatusText(englishStrings, status), status.message);
      expect(linkStatusText(chineseStrings, status), status.message);
    });

    test('an unknown code renders its own sentence', () {
      const status = LinkStatus(
        stage: LinkStage.ready,
        message: 'a sentence from a newer build',
        messageCode: 'linkSomethingThisBuildHasNeverHeardOf',
      );
      expect(linkStatusText(chineseStrings, status), status.message);
    });

    test('the album 404 sentence keeps the firmware fact, in both languages', () {
      // The single most load-bearing sentence in this round: a translator who drops
      // "not that the file is gone" turns a retry into a user believing their photo
      // was deleted. Asserted in both languages so the check covers the translation,
      // not just the English.
      const e = AlbumException(
        'DeleteFile answered 404 for 3 path(s). On this firmware that means the '
        'request shape was rejected — not that the file is gone.',
        404,
        AlbumErrorCodes.deleteRejected,
        {'count': 3},
      );
      for (final strings in <AppLocalizations>[englishStrings, chineseStrings]) {
        final text = albumErrorText(strings, e);
        expect(text, contains('404'));
        expect(text, contains('3'));
        expect(text, contains('DeleteFile'));
      }
      expect(albumErrorText(englishStrings, e), e.message);
      // The Chinese must contradict "the file is gone" explicitly, not merely omit it.
      expect(albumErrorText(chineseStrings, e), contains('而不是'));
    });

    test('an album failure with no code keeps its own sentence', () {
      const e = AlbumException('timeout opening download for /DCIM/x.JPG');
      expect(albumErrorText(chineseStrings, e), e.message);
      expect(thrownText(chineseStrings, e), e.message);
      expect(thrownText(chineseStrings, StateError('boom')), 'Bad state: boom');
    });

    test('every sync stage that shows a label resolves one', () {
      final unresolved = <SyncStage>[];
      for (final s in SyncStage.values) {
        if (s == SyncStage.failed) continue; // documented: its reason is the item's
        if (syncStageText(englishStrings, s) != s.label) unresolved.add(s);
      }
      expect(unresolved, isEmpty,
          reason: 'the ARB English and the enum disagree for: $unresolved');
    });

    test('a delete refusal states the unverified protection flag', () {
      // `analysis/` records that `protectStatus` is reported by the listing and
      // appears nowhere in the official app's delete path. The sentence says the flag
      // is unverified rather than claiming the file is locked; a translation that
      // asserted "protected" outright would be a claim the reverse engineering does
      // not support.
      expect(chineseStrings.deleteRefusalProtected, contains('尚未验证'));
      expect(englishStrings.deleteRefusalProtected, contains('not verified'));
    });
  });

  group('resolvers', () {
    /// Resolvers that no widget calls yet, each naming the site that should call it.
    ///
    /// This is a **shrink-only** list: `the unwired list has no stale entries` fails as
    /// soon as a resolver gains a call site, so an entry cannot quietly become a
    /// permanent excuse. Every entry here is a live leak of English into the Chinese UI
    /// — the code is attached, the case exists, and the widget draws the state layer's
    /// own field instead.
    const awaitingCallSite = <String, String>{
      'thrownText':
          'album_page.dart:540 resolves its own error field but not the AlbumException '
              'it catches',
      'syncNoteText':
          'album_page.dart:1167 draws `s.note!`; `SyncSummary.noteCode` exists and is '
              'never read',
      'syncStreamPauseText':
          'album_page.dart:1194 and live_view_page.dart:1423 draw '
              '`s.streamPauseReason` raw, so the banner prefers the English reason over '
              'the localized fallback drawn beside it',
      'deleteRefusalText':
          'album_page.dart:1595 and :1775 draw `r.reason`; `DeleteRefusal.reasonCode` '
              'exists and is never read',
    };

    String uiSource() => <String>[
          for (final f in Directory('lib/ui')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart')))
            f.readAsStringSync(),
        ].join('\n');

    test('every resolver is wired to a widget', () {
      // The **third** failure shape, and the one no table comparison can see: both
      // sides agree, the code is attached, and the widget draws the raw field anyway.
      // A resolver nothing calls is indistinguishable from a resolver that does not
      // exist — except that it makes the work look finished.
      final src = uiSource();
      final unwired = <String>[
        for (final name in kResolvers)
          if (!src.contains('$name(')) name,
      ]..sort();

      expect(unwired, awaitingCallSite.keys.toList()..sort(),
          reason: 'a resolver nothing calls is a translation that never happens:\n'
              '${unwired.map((n) => '  $n — ${awaitingCallSite[n] ?? "NEW, no call site"}').join('\n')}');
    });

    test('the unwired list has no stale entries', () {
      final src = uiSource();
      final wired = <String>[
        for (final name in awaitingCallSite.keys)
          if (src.contains('$name(')) name,
      ]..sort();
      expect(wired, isEmpty,
          reason: 'these now have call sites — remove them from the list so it keeps '
              'meaning "still leaking": $wired');
    });
  });

  group('settings catalog', () {
    test('every tab, group and row in the catalog has a translation', () {
      final missing = <String>[];
      for (final t in kSettingsTabs) {
        if (!kLocalizedTabIds.contains(t.id)) missing.add('tab ${t.id}');
        for (final g in t.groups) {
          if (!kLocalizedGroupIds.contains(g.id)) missing.add('group ${g.id}');
          for (final r in g.rows) {
            if (!kLocalizedRowKeys.contains(r.key)) missing.add('row ${r.key}');
          }
        }
      }
      expect(missing, isEmpty,
          reason: 'these would draw their English catalog string in every locale, '
              'and the fallback makes that invisible: $missing');
    });

    test('the translations do not name tabs, groups or rows that do not exist', () {
      final ids = <String>{
        for (final t in kSettingsTabs) t.id,
        for (final g in kSettingsGroups) g.id,
        for (final g in kSettingsGroups)
          for (final r in g.rows) r.key,
      };
      final orphans = <String>[
        ...kLocalizedTabIds,
        ...kLocalizedGroupIds,
        ...kLocalizedRowKeys,
      ].where((id) => !ids.contains(id)).toList()
        ..sort();
      expect(orphans, isEmpty, reason: 'dead translations: $orphans');
    });

    test('a row note is only claimed where the catalog declares one', () {
      final missing = <String>[];
      for (final g in kSettingsGroups) {
        for (final r in g.rows) {
          if (r.note == null) continue;
          if (settingsRowNote(englishStrings, r) == null) missing.add(r.key);
        }
      }
      expect(missing, isEmpty, reason: 'rows whose note would vanish: $missing');
      expect(kLocalizedRowNoteKeys.length, 2);
    });

    test('the catalog itself is unchanged in English', () {
      // The catalog is Flutter-free and was **not** edited for this round: its labels
      // remain the fallback. Proving that here means the "the panel is English in a
      // Chinese UI" regression cannot be introduced by editing the catalog alone.
      final row = kSettingsGroups
          .expand((g) => g.rows)
          .firstWhere((r) => r.key == 'RCISOSet');
      expect(row.label, 'ISO');
      expect(settingsRowLabel(englishStrings, row), 'ISO');
      expect(settingsRowLabel(chineseStrings, row), '感光度');
    });

    test('the locale row exists and is dispatchable', () {
      // The control this round adds has to be in the offline-checked set, or the
      // "everything reachable is declared in the catalog" rule stops covering it.
      expect(kSettingsActionKeys, contains('locale'));
      expect(kSettingsGroups.any((g) => g.rows.any((r) => r.key == 'locale')),
          isTrue);
    });
  });

  group('parameter labels', () {
    test('every named value in the firmware pools has a display label', () {
      // A value "carries a word" when it holds a run of two or more Latin letters.
      // That single rule keeps `1/250s`, `f/2.8`, `1600`, `4:3` and the single-letter
      // exposure modes out — they are measurements, they read the same in every
      // language, and `lib/l10n/param_labels.dart` says so in its library comment.
      final wordy = RegExp('[A-Za-z]{2,}');
      final missing = <String>{};
      for (final pool in kRcValuePools.entries) {
        for (final v in pool.value) {
          if (!wordy.hasMatch(v)) continue;
          if (kVerbatimWireValues.contains(v)) continue;
          if (!kLabelledWireValues.contains(v)) missing.add('${pool.key}: $v');
        }
      }
      expect(missing, isEmpty,
          reason: 'these render as the firmware wire string in every locale: '
              '${missing.toList()..sort()}');
    });

    test('the label set has no entries the pools do not contain', () {
      final all = <String>{for (final p in kRcValuePools.values) ...p};
      final stale = kLabelledWireValues.difference(all).toList()..sort();
      expect(stale, isEmpty, reason: 'labels for values nothing offers: $stale');
    });

    test('a numeric ladder is passed through untouched', () {
      // Translating `1/250s` or `f/2.8` would be noise, and would put a mapping
      // between a number and the request where none belongs.
      for (final v in <String>['1/250s', '2.8', '1600', '4:3', '-0.7', '5600']) {
        expect(paramLabel(chineseStrings, v), v);
      }
    });

    test('the labels differ from the wire value where a word is involved', () {
      expect(paramLabel(englishStrings, 'Continuous'), 'Continuous');
      expect(paramLabel(chineseStrings, 'Continuous'), '连拍');
      expect(paramLabel(chineseStrings, 'Single'), '单张');
      expect(paramLabel(chineseStrings, 'Spot'), '点测光');
      expect(paramLabel(chineseStrings, 'AUTO_NOT_A_VALUE'), 'AUTO_NOT_A_VALUE');
    });

    test('a display label is never the value that gets sent', () {
      // The whole point of routing labels through `paramLabel`: `AppState.setParam`
      // takes a pool value, and there is no function here that goes the other way.
      // Asserted by behaviour — the Chinese label for `Auto` is not a pool member, so
      // sending it would be refused by the camera.
      expect(kRcValuePools['driveMode'], contains('Continuous'));
      expect(kRcValuePools['driveMode']!.contains('连拍'), isFalse);
    });
  });
}

/// The English sentence `CameraConnection` attaches to [code].
///
/// Duplicated here on purpose: the test's job is to compare the ARB against the
/// transport, and reading the sentence out of the transport would make the comparison
/// vacuous. Kept in the same order as [LinkCodes] so a missing entry is easy to see.
String _englishFor(String code) => switch (code) {
      LinkCodes.scanning => 'looking for the camera...',
      LinkCodes.notFound => 'camera not found. Is it powered on, and not already '
          'held by the official app?',
      LinkCodes.connecting => 'connecting...',
      LinkCodes.readingIdentity => 'reading camera identity...',
      LinkCodes.unreadableIdentity => 'camera answered with an unreadable identity',
      LinkCodes.found => 'found 3.1-cn (M1CN)',
      LinkCodes.reusingPairing => 'reusing the saved pairing (refId 12345)...',
      LinkCodes.savedPairingRejected =>
        'saved pairing did not take (oops); pairing fresh',
      LinkCodes.pressAllow => 'PRESS ALLOW ON THE CAMERA now (refId 12345)',
      LinkCodes.pairingNotConfirmed => 'the camera did not confirm the pairing. It '
          'must be accepted on the camera screen within a few seconds.',
      LinkCodes.openingSession => 'opening the session...',
      LinkCodes.enablingWifi => 'switching the camera Wi-Fi on...',
      LinkCodes.readingCredentials => 'reading Wi-Fi credentials...',
      LinkCodes.pairingForgotten => 'the camera refused the saved pairing, so it '
          'has been forgotten; press Connect again to pair from scratch (the camera '
          'will ask for confirmation).',
      LinkCodes.noCredentials => 'the camera did not hand over Wi-Fi credentials. '
          'The session may not have been accepted.',
      LinkCodes.askingAndroidToJoin => 'asking Android to join "YI_M1_x"...',
      LinkCodes.joined =>
        'joined "YI_M1_x" — waiting for the camera to answer...',
      LinkCodes.joinedUnbound => 'joined "YI_M1_x" — waiting for the camera...',
      LinkCodes.savedNetworkInstead => 'Android saved "YI_M1_x" as a network '
          'instead of joining it. If a notification appears, allow it — otherwise '
          'open Wi-Fi and pick it. The passkey is already filled in '
          '(YI_M1_x / 12345678). Waiting...',
      LinkCodes.joinDismissed => 'the join prompt was dismissed. Tap "Retry join" '
          'to bring it back, or connect to "YI_M1_x" yourself with the passkey '
          'YI_M1_x / 12345678.',
      LinkCodes.joinTimedOut =>
        'Android did not finish joining "YI_M1_x" in time.',
      LinkCodes.joinUnsupported => 'this phone will not let the app join "YI_M1_x" '
          'by itself, so the Wi-Fi screen was opened. Choose "YI_M1_x" there — the '
          'passkey is YI_M1_x / 12345678 (the camera does not show it).',
      LinkCodes.joinManual => 'permission denied. You can also connect to '
          '"YI_M1_x" by hand with the passkey YI_M1_x / 12345678. [fine:no]',
      LinkCodes.waitingForCamera =>
        'waiting for the camera to answer (68s left)...',
      LinkCodes.cameraNotAnswering => 'the camera is not answering on '
          '192.168.0.10. Check that the phone is on "YI_M1_x" — its passkey is '
          '12345678 — then retry.',
      LinkCodes.connected => 'connected',
      LinkCodes.previewRunning => 'preview running',
      LinkCodes.previewStopped => 'preview stopped',
      LinkCodes.disconnected => 'disconnected',
      LinkCodes.disconnectedNoPairing => 'Disconnected, but the camera\'s Wi-Fi '
          'is still on — the camera no longer holds this phone\'s pairing, so the '
          'app has no authenticated channel to switch it with. Press the camera\'s '
          'power switch, or reconnect and disconnect again, to stop it '
          'advertising.',
      LinkCodes.disconnectedRadioRefused => 'Disconnected, but the camera\'s Wi-Fi '
          'is still on — the camera did not acknowledge the switch-off command. '
          'Press the camera\'s power switch, or reconnect and disconnect again, to '
          'stop it advertising.',
      LinkCodes.disconnectedNoBle => 'Disconnected, but the camera\'s Wi-Fi is '
          'still on — the Bluetooth link to the camera was already gone, so the '
          'switch-off command had no way to reach it. Press the camera\'s power '
          'switch, or reconnect and disconnect again, to stop it advertising.',
      LinkCodes.idle => 'not connected',
      LinkCodes.lostContact => 'Lost contact with the camera. It may have been '
          'switched off, or the phone may have left the camera\'s Wi-Fi network.',
      _ => throw ArgumentError('no English sentence recorded for $code'),
    };

/// The parameter values [_englishFor] interpolates.
Map<String, Object?> _paramsFor(String code) => switch (code) {
      LinkCodes.found => {'firmware': '3.1-cn', 'region': 'M1CN'},
      LinkCodes.reusingPairing => {'refId': '12345'},
      LinkCodes.savedPairingRejected => {'detail': 'oops'},
      LinkCodes.pressAllow => {'refId': '12345'},
      LinkCodes.askingAndroidToJoin ||
      LinkCodes.joined ||
      LinkCodes.joinedUnbound ||
      LinkCodes.joinTimedOut =>
        {'ssid': 'YI_M1_x'},
      LinkCodes.savedNetworkInstead ||
      LinkCodes.joinDismissed ||
      LinkCodes.joinUnsupported =>
        {'ssid': 'YI_M1_x', 'credential': 'YI_M1_x / 12345678'},
      LinkCodes.joinManual => {
          'detail': 'permission denied.',
          'ssid': 'YI_M1_x',
          'credential': 'YI_M1_x / 12345678',
          'permissions': 'fine:no',
        },
      LinkCodes.waitingForCamera => {'seconds': 68},
      LinkCodes.cameraNotAnswering => {
          'host': '192.168.0.10',
          'ssid': 'YI_M1_x',
          'passkey': '12345678',
        },
      _ => const {},
    };
