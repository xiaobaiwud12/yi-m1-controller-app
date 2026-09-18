/// Localized rendering for the messages the Flutter-free layers raise.
///
/// ## The decision this file implements
///
/// `AGENTS.md` §4.1 forbids `package:flutter` in `lib/protocol/`, `lib/transport/`
/// and `lib/sync/`, and §4.2 forbids even `dart:ui` in `viewfinder_layout.dart`. Those
/// layers must stay drivable in the plain Dart VM — that is why 686 assertions run in
/// seconds — so `AppLocalizations` (a widget-tree lookup) can never be called there.
///
/// But their messages are user-visible, and several of them are the *only* place a
/// measured firmware behaviour is written down:
///
/// * `DeleteFile answered 404 … means the request shape was rejected — not that the
///   file is gone.` A translation that lost that clause would turn a retry into a
///   user believing their photo was deleted;
/// * `the camera is not answering on <host> … its passkey is <passkey>` — the three
///   values needed to fix the problem are in the sentence;
/// * `no frames` versus a frame rate, which exists precisely because the session
///   average never falls and cannot show a stall.
///
/// ## The two shapes considered
///
/// **1. Move the prose up into the UI.** The transport would emit structured facts
/// (a stage, a status code, a count) and the UI would compose every sentence. This
/// keeps the lower layers free of user-facing language entirely, which is elegant —
/// and it puts the sentences at the *wrong end of the wire*. `linkCameraNotAnswering`
/// is written where `host`, `ssid` and `passkey` are simultaneously in hand, inside
/// the branch that has just proved the camera unreachable; `deleteRejected` is written
/// inside `catch (e) { if (e.isBadParameters) }`. Lifting them means either passing
/// every parameter up through three layers (and keeping the branch's *reasoning* in
/// the UI, which is where the firmware knowledge would then have to live), or
/// reconstructing the branch condition in the UI, which is the "parts wired wrong"
/// failure `analysis/41` §7.11 describes.
///
/// **2. A message code plus parameters, with the English prose kept as the fallback.**
/// Chosen. The sentence stays where the knowledge is; a stable code and the values it
/// interpolates travel with it; the UI resolves the code here. `toString()` and the
/// `message` field still produce exactly the English they produced before, so logs,
/// the offline assertions and the pre-existing UI all keep working unchanged.
///
/// ## What this shape costs, and how the cost is paid
///
/// The cost is that a code with no case here renders English — **correct, and
/// invisible**. That is exactly the "green but not checking anything" failure
/// `AGENTS.md` §8 warns about, so it is asserted instead:
/// `test/l10n_message_codes_test.dart` compares [kHandledMessageCodes] against
/// `LinkCodes.all`, `AlbumErrorCodes.all`, `SyncStageCodes.all`,
/// `DeleteRefusalCodes.all` and `AppNoticeCodes.all` **in both directions**. A new
/// code with no translation fails the suite; a translation with no code fails it too.
///
/// ## What is deliberately not translated
///
/// [linkStatusText] returns the English when a status carries no code, and
/// `CameraConnection.connect`'s bare `catch` deliberately attaches none: `'$e'` is an
/// arbitrary platform exception this app did not write, and inventing a Chinese
/// sentence for a message whose content is unknown would replace a true diagnostic
/// with a plausible false one.
library;

import 'package:flutter/widgets.dart';

import '../protocol/http_params.dart' show kRcValuePools;
import '../state/app_state.dart';
import '../sync/sync_engine.dart';
import '../transport/album.dart';
import '../transport/album_delete.dart';
import '../transport/camera_connection.dart';
import 'l10n.dart';
import 'param_labels.dart';

/// Every message code this file knows how to render.
///
/// The union of the producers' own code sets. Asserted equal to them, key by key, by
/// `test/l10n_message_codes_test.dart` — see the library comment for why the check is
/// the point rather than a nicety.
final Set<String> kHandledMessageCodes = <String>{
  ...LinkCodes.all,
  ...AlbumErrorCodes.all,
  ...SyncStageCodes.all,
  ...SyncNoteCodes.all,
  ...DeleteRefusalCodes.all,
  ...AppNoticeCodes.all,
};

/// Every **UI-facing** resolver this file publishes, by the name a caller uses.
///
/// ## Why this list exists
///
/// Three different things can go wrong with a message code, and they need three
/// different checks:
///
/// 1. a code with **no case here** — English on a Chinese screen. Checked by
///    `l10n_message_codes_test.dart`, which compares this file's cases against
///    `LinkCodes.all` and friends.
/// 2. a code that is **never attached** to the value it belongs to — the same English,
///    for a different reason. Checked by `l10n_link_status_test.dart`, which drives a
///    real `CameraConnection`.
/// 3. a resolver that is **never called**. The code is attached, the case exists, and
///    the widget draws the raw English field instead. Nothing else can see this: the
///    tables on both sides agree perfectly.
///
/// This list is what makes (3) checkable — `every resolver is wired to a widget` in
/// `l10n_message_codes_test.dart` reads `lib/ui/` and fails for any name here that no
/// widget calls.
///
/// [linkCodeText] and [albumErrorText] are deliberately **not** on it: they are
/// building blocks the other resolvers call, so no widget is expected to reach for them
/// and listing them would make the check fail for a correct program.
const List<String> kResolvers = <String>[
  'linkStatusText',
  'thrownText',
  'syncStageText',
  'syncNoteText',
  'syncStreamPauseText',
  'deleteRefusalText',
  'appErrorText',
  'appNoticeText',
  'shutterBlockedText',
];

/// A value from a message's parameter map, as text.
///
/// Numbers are the common case (a count of paths, a remaining-seconds reading). A
/// missing key renders as the empty string rather than throwing: a translation
/// function that crashed the frame it was drawn in would turn a wording mistake into
/// a blank screen, and the fallback sentence is still one field away.
String _p(Map<String, Object?> params, String key) {
  final v = params[key];
  if (v == null) return '';
  return '$v';
}

int _pInt(Map<String, Object?> params, String key) {
  final v = params[key];
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse('${v ?? ''}') ?? 0;
}

/// A message raised by the connection layer, or null when [code] is not one of its.
///
/// ## Why this is a function of the code rather than of the status
///
/// A sentence and its code do not always travel together all the way to the screen.
/// `AppState.lastError` is the case that proved it: it holds *text* copied out of a
/// `LinkStatus` (`lastError = connection.current.message`), and the strip that draws it
/// knows nothing about statuses. Returning a nullable string here — rather than
/// switching inside [linkStatusText] — is what lets [appErrorText] resolve a link code
/// it received through a field of its own, so a code resolves **wherever it arrives**
/// instead of only in the shape it was minted in.
///
/// That is the answer to "why did the check not catch this": the check compared the
/// *set* of codes the producers declare against the set the resolver handles, and both
/// contained `linkIdle`. It never asked whether the code was **attached** to a status at
/// all. `test/l10n_link_status_test.dart` now asks that.
String? linkCodeText(
    AppLocalizations l, String? code, Map<String, Object?> params) {
  return switch (code) {
    LinkCodes.scanning => l.linkScanning,
    LinkCodes.notFound => l.linkNotFound,
    LinkCodes.connecting => l.linkConnecting,
    LinkCodes.readingIdentity => l.linkReadingIdentity,
    LinkCodes.unreadableIdentity => l.linkUnreadableIdentity,
    LinkCodes.found =>
      l.linkFound(_p(params, 'firmware'), _p(params, 'region')),
    LinkCodes.reusingPairing => l.linkReusingPairing(_p(params, 'refId')),
    LinkCodes.savedPairingRejected =>
      l.linkSavedPairingRejected(_p(params, 'detail')),
    LinkCodes.pressAllow => l.linkPressAllow(_p(params, 'refId')),
    LinkCodes.pairingNotConfirmed => l.linkPairingNotConfirmed,
    LinkCodes.openingSession => l.linkOpeningSession,
    LinkCodes.enablingWifi => l.linkEnablingWifi,
    LinkCodes.readingCredentials => l.linkReadingCredentials,
    LinkCodes.pairingForgotten => l.linkPairingForgotten,
    LinkCodes.noCredentials => l.linkNoCredentials,
    LinkCodes.askingAndroidToJoin =>
      l.linkAskingAndroidToJoin(_p(params, 'ssid')),
    LinkCodes.joined => l.linkJoined(_p(params, 'ssid')),
    LinkCodes.joinedUnbound => l.linkJoinedUnbound(_p(params, 'ssid')),
    LinkCodes.savedNetworkInstead => l.linkSavedNetworkInstead(
        _p(params, 'ssid'), _p(params, 'credential')),
    LinkCodes.joinDismissed => l.linkJoinDismissed(
        _p(params, 'ssid'), _p(params, 'credential')),
    LinkCodes.joinTimedOut => l.linkJoinTimedOut(_p(params, 'ssid')),
    LinkCodes.joinUnsupported => l.linkJoinUnsupported(
        _p(params, 'ssid'), _p(params, 'credential')),
    LinkCodes.joinManual => l.linkJoinManual(_p(params, 'detail'),
        _p(params, 'ssid'), _p(params, 'credential'), _p(params, 'permissions')),
    LinkCodes.waitingForCamera =>
      l.linkWaitingForCamera(_pInt(params, 'seconds')),
    LinkCodes.cameraNotAnswering => l.linkCameraNotAnswering(
        _p(params, 'host'), _p(params, 'ssid'), _p(params, 'passkey')),
    LinkCodes.connected => l.linkConnected,
    LinkCodes.previewRunning => l.linkPreviewRunning,
    LinkCodes.previewStopped => l.linkPreviewStopped,
    LinkCodes.disconnected => l.linkDisconnected,
    LinkCodes.disconnectedNoPairing => l.linkDisconnectedNoPairing,
    LinkCodes.disconnectedRadioRefused => l.linkDisconnectedRadioRefused,
    LinkCodes.disconnectedNoBle => l.linkDisconnectedNoBle,
    LinkCodes.idle => l.linkIdle,
    LinkCodes.lostContact => l.linkLostContact,
    _ => null,
  };
}

/// What the connection status line should say.
///
/// Resolves [LinkStatus.messageCode]; falls back to [LinkStatus.message] — the
/// transport's own English — when there is no code or the code is unknown.
String linkStatusText(AppLocalizations l, LinkStatus status) =>
    linkCodeText(l, status.messageCode, status.messageParams) ?? status.message;

/// What an album failure should say.
///
/// Used for a listing error, a viewer fetch failure and a delete outcome alike —
/// they all carry [AlbumException]s. Falls back to the exception's own English.
String albumErrorText(AppLocalizations l, AlbumException e) {
  final params = e.messageParams;
  return switch (e.messageCode) {
    AlbumErrorCodes.listingRejected =>
      l.albumErrListingRejected(_pInt(params, 'start'), _pInt(params, 'end')),
    AlbumErrorCodes.listingFailed => l.albumErrListingFailed(_p(params, 'raw')),
    AlbumErrorCodes.pathTooLong => l.albumErrPathTooLong(
        _pInt(params, 'length'), _p(params, 'path')),
    AlbumErrorCodes.deleteRejected =>
      l.albumErrDeleteRejected(_pInt(params, 'count')),
    AlbumErrorCodes.deleteNoPaths => l.albumErrDeleteNoPaths,
    AlbumErrorCodes.deleteTooMany => l.albumErrDeleteTooMany(
        _pInt(params, 'limit'), _pInt(params, 'count')),
    AlbumErrorCodes.deleteAll => l.albumErrDeleteAll,
    AlbumErrorCodes.deletePathTooLong => l.albumErrDeletePathTooLong(
        _p(params, 'path'), _pInt(params, 'length'), _pInt(params, 'limit')),
    _ => e.message,
  };
}

/// What an arbitrary object thrown by the album or sync layer should say.
///
/// The single entry point for `'$e'` at a call site: an [AlbumException] goes through
/// [albumErrorText], anything else keeps its own `toString()`, which is the honest
/// answer for a platform exception this app did not write.
String thrownText(AppLocalizations l, Object e) =>
    e is AlbumException ? albumErrorText(l, e) : '$e';

/// A sync stage's label.
///
/// Falls back to [SyncStage.label] — the enum's own English — for the stage that has
/// no code and for any code this build does not know.
String syncStageText(AppLocalizations l, SyncStage stage) =>
    switch (stage.labelCode) {
      SyncStageCodes.queued => l.stageQueued,
      SyncStageCodes.downloadingPreview => l.stagePreview,
      SyncStageCodes.downloadingOriginal => l.stageDownloading,
      SyncStageCodes.stalled => l.stageStalled,
      SyncStageCodes.pausedNoCamera => l.stagePausedNoCamera,
      SyncStageCodes.pausedByUser => l.stagePausedByUser,
      SyncStageCodes.done => l.stageDone,
      _ => stage.label,
    };

/// Why the engine is holding the live-view stream paused.
///
/// Falls back to the engine's own sentence for a reason with no code.
String? syncStreamPauseText(AppLocalizations l, String? code, String? fallback) {
  if (fallback == null) return null;
  return switch (code) {
    SyncNoteCodes.streamPauseReason => l.syncStreamPauseReason,
    _ => fallback,
  };
}

/// The engine's run-level note (why the queue stopped, or that it was paused).
String? syncNoteText(AppLocalizations l, String? code, String? fallback) {
  if (fallback == null) return null;
  return switch (code) {
    SyncNoteCodes.cameraAway => l.syncNoteCameraAway,
    SyncNoteCodes.pausedByUser => l.syncNotePausedByUser,
    _ => fallback,
  };
}

/// Why a file in the delete plan cannot be deleted.
String deleteRefusalText(AppLocalizations l, DeleteRefusal refusal) {
  final params = refusal.reasonParams;
  return switch (refusal.reasonCode) {
    DeleteRefusalCodes.protectedOnCamera => l.deleteRefusalProtected,
    DeleteRefusalCodes.pathTooLong => l.deleteRefusalPathTooLong(
        _pInt(params, 'length'), _pInt(params, 'limit')),
    DeleteRefusalCodes.listingFailed => l.deleteRefusalListingFailed,
    _ => refusal.reason,
  };
}

/// What the app's own error line should say, or null when there is none.
///
/// Resolves [AppState.lastErrorCode] against the ARB and falls back to
/// [AppState.lastError] for the branches that deliberately carry no code (see the
/// field's doc comment: a `LinkStatus` sentence, an `AlbumException`, the capture
/// guard's own reason). Returns null when there is no error at all.
///
/// Why `AppState` needs this at all, given that it *may* import `package:flutter`:
/// it has no `BuildContext` and must not hold the current locale, so it cannot reach
/// `AppLocalizations` — and the sentence belongs to the branch that decides it, where
/// `captureGuard.describe()` and `mode` are in hand. It is the same decision
/// `lib/transport/` and `lib/sync/` made, applied to the last producer of
/// user-visible prose; `AppState` keeps the English and the code travels beside it.
String? appErrorText(AppLocalizations l, AppState app) {
  final params = app.lastErrorParams;
  return switch (app.lastErrorCode) {
    AppNoticeCodes.errStorageDenied => l.errStorageDenied,
    AppNoticeCodes.errPreviewRefused => l.errPreviewRefused,
    AppNoticeCodes.errShareAndroidOnly => l.errShareAndroidOnly,
    AppNoticeCodes.errShareSheetRefused => l.errShareSheetRefused,
    AppNoticeCodes.errNoViewerApp => l.errNoViewerApp,
    AppNoticeCodes.errRemoveCopyFailed => l.errRemoveCopyFailed,
    AppNoticeCodes.errDeleteNotConnected => l.errDeleteNotConnected,
    AppNoticeCodes.errDeleteFailed => l.errDeleteFailed(_p(params, 'detail')),
    AppNoticeCodes.errNotConnectedShort => l.errNotConnectedShort,
    AppNoticeCodes.errCommandFailed =>
      l.errCommandFailed(_p(params, 'command'), _p(params, 'detail')),
    AppNoticeCodes.errCommandRejected404 =>
      l.errCommandRejected404(_p(params, 'command')),
    AppNoticeCodes.errShutterReleaseFailed =>
      l.errShutterReleaseFailed(_p(params, 'detail')),
    AppNoticeCodes.errShutterHealthCheckFailed =>
      l.errShutterHealthCheckFailed(_p(params, 'detail')),
    AppNoticeCodes.errInterlockReleasedNoRemote =>
      l.errInterlockReleasedNoRemote,
    AppNoticeCodes.errInterlockReleasedStillBlocked =>
      l.errInterlockReleasedStillBlocked,
    AppNoticeCodes.errPhotoFail => l.errPhotoFail,
    AppNoticeCodes.errCaptureNotReached => l.errCaptureNotReached,
    AppNoticeCodes.errFocusFailed => l.errFocusFailed(_p(params, 'detail')),
    AppNoticeCodes.errFocusRejected404 => l.errFocusRejected404,
    AppNoticeCodes.errUnknownParamCommand =>
      l.errUnknownParamCommand(_p(params, 'command')),
    AppNoticeCodes.errCommandNotInTable =>
      l.errCommandNotInTable(_p(params, 'command')),
    // **Not** `_ => app.lastError`. A code from another producer can arrive in this
    // field — `AppState.connect` copies a `LinkStatus`'s sentence *and its code* here —
    // and falling straight through to the English is what put `not connected` on a
    // Chinese screen. So the other producers' tables are tried first, and the raw
    // string is the last resort rather than the first.
    _ => linkCodeText(l, app.lastErrorCode, params) ?? app.lastError,
  };
}

/// The same for the notice line.
///
/// One that is not an error — a sync summary, a refusal the app decided on purpose —
/// and the same fallback rule: no code, or a code this build does not know, renders
/// [AppState.lastNotice] exactly as the state layer wrote it.
String? appNoticeText(AppLocalizations l, AppState app) {
  final params = app.lastNoticeParams;
  return switch (app.lastNoticeCode) {
    AppNoticeCodes.noticeUnwiredRow =>
      l.noticeUnwiredRow(_p(params, 'label')),
    AppNoticeCodes.noticeShotsNotOnPhone => l.noticeShotsNotOnPhone,
    AppNoticeCodes.noticeSharedPartially => l.noticeSharedPartially(
        _pInt(params, 'missing'), _pInt(params, 'total')),
    AppNoticeCodes.noticeShotNotOnPhone => l.noticeShotNotOnPhone,
    AppNoticeCodes.noticeNothingSentAllRefused =>
      l.noticeNothingSentAllRefused,
    AppNoticeCodes.noticeNothingToDelete => l.noticeNothingToDelete,
    AppNoticeCodes.noticeInterlockReleased => l.noticeInterlockReleased,
    AppNoticeCodes.noticeFocusSkippedForShot => l.noticeFocusSkippedForShot,
    AppNoticeCodes.noticeParamSetByCamera =>
      l.noticeParamSetByCamera(_p(params, 'mode')),
    _ => linkCodeText(l, app.lastNoticeCode, params) ?? app.lastNotice,
  };
}

/// Why the shutter is unavailable, or null when it is available.
///
/// Resolves [AppState.shutterBlockedReasonCode] and falls back to
/// [AppState.shutterBlockedReason] — the state layer's own English — for a shutter
/// that is merely busy (that gate carries no code) or for a code this build does not
/// know.
///
/// The burst gate interpolates the firmware's own drive word, so it is rendered
/// through [paramLabel]: `Continuous` is what gets sent and 连拍 is what the user
/// reads. Translating the value in place would put a label into the wire format.
String? shutterBlockedText(AppLocalizations l, AppState app) {
  final params = app.shutterBlockedReasonParams;
  return switch (app.shutterBlockedReasonCode) {
    AppNoticeCodes.shutterBlockedNotConnected => l.shutterBlockedNotConnected,
    AppNoticeCodes.shutterBlockedNotRemote => l.shutterBlockedNotRemote,
    AppNoticeCodes.shutterBlockedBurst =>
      l.shutterBlockedBurst(paramLabel(l, _p(params, 'drive'))),
    AppNoticeCodes.shutterBlockedQuarantined => l.shutterBlockedQuarantined,
    _ => app.shutterBlockedReason,
  };
}

/// Convenience for a widget that only has a `BuildContext`.
AppLocalizations l10nFor(BuildContext context) => l10nOf(context);

/// True when [wire] is a value the parameter pool actually contains.
///
/// Exposed so `test/l10n_param_labels_test.dart` can assert that every *named* value
/// in [kRcValuePools] — the ones that read as English words — has a display label in
/// `lib/l10n/param_labels.dart`, while the numeric ladders deliberately do not.
bool isNamedPoolValue(String wire) => RegExp(r'[A-Za-z]').hasMatch(wire);
