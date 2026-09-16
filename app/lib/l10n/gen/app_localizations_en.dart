// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'M1 Controller';

  @override
  String get startupFailedTitle => 'The app failed to start';

  @override
  String get startupFailedBody =>
      'This is a problem in the app, not the camera. The text below is what went wrong and is worth reporting.';

  @override
  String get startupUnknownError => 'unknown error';

  @override
  String get continueToApp => 'Continue to the app';

  @override
  String get disconnectTitle => 'Disconnect?';

  @override
  String get disconnectBody =>
      'This stops the preview and releases the camera\'s Wi-Fi, which is what it wants when nobody is using it. The pairing is kept, so reconnecting will not need a confirmation on the camera.';

  @override
  String get cancel => 'Cancel';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get guideTooltip => 'First run & pairing guide';

  @override
  String get disconnectTooltip => 'Disconnect from the camera';

  @override
  String get checkCameraTooltip => 'Check the camera is still there';

  @override
  String get licencesTooltip => 'Licences, credits and who made this';

  @override
  String get licencesLegalese =>
      'An unofficial, third-party app for the YI M1 (C59Y1) camera — not affiliated with, authorised by, or endorsed by YI Technology. The app itself is Apache-2.0; the open-source components bundled in this build are listed below, each under its own licence.';

  @override
  String get cameraResponding => 'Camera is responding.';

  @override
  String get cameraSilent => 'No answer from the camera.';

  @override
  String get navCapture => 'Capture';

  @override
  String get navSync => 'Sync';

  @override
  String get firmwareNotConnected => 'not connected';

  @override
  String albumListingRejected(String detail) {
    return 'The camera rejected the listing parameters, which points at a protocol mismatch:\n$detail';
  }

  @override
  String albumUnreachable(String detail) {
    return 'Could not reach the camera.\n$detail';
  }

  @override
  String albumOnThisPhone(String name) {
    return 'On this phone ($name)';
  }

  @override
  String get albumNotOnPhone => 'Not on this phone yet';

  @override
  String get actionShare => 'Share';

  @override
  String get actionShareSubtitleOnPhone => 'Send to another app';

  @override
  String get actionShareSubtitleNotOnPhone => 'Sync it first';

  @override
  String get actionOpen => 'Open';

  @override
  String get actionOpenSubtitleOnPhone => 'In the phone\'s own viewer';

  @override
  String get actionSyncThis => 'Sync this shot';

  @override
  String get actionRemoveFromPhone => 'Remove from this phone';

  @override
  String get actionRemoveFromPhoneSubtitle => 'Keeps it on the camera';

  @override
  String get actionDeleteFromCamera => 'Delete from the camera';

  @override
  String get actionDeleteFromCameraSubtitle =>
      'Cannot be undone; the camera has no undo';

  @override
  String albumShareSheetTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Share $count shots',
      one: 'Share shot',
    );
    return '$_temp0';
  }

  @override
  String get albumRemoveConfirmTitle => 'Remove from this phone?';

  @override
  String albumRemoveConfirmBody(String path) {
    return 'The copy in your gallery is deleted. The shot stays on the camera\'s card — this is the opposite of Delete.\n\n$path';
  }

  @override
  String get remove => 'Remove';

  @override
  String get albumDeleteStarting => 'starting';

  @override
  String albumSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String albumTitleCount(int count) {
    return 'Album  ·  $count shots';
  }

  @override
  String get albumSyncSelectedTooltip => 'Sync the selected shots';

  @override
  String get albumDeleteSelectedTooltip =>
      'Delete the selected shots from the camera';

  @override
  String get albumDeleteBusyTooltip => 'A delete is already running';

  @override
  String get albumSelectTooltip => 'Select shots';

  @override
  String get albumReloadTooltip => 'Reload everything, from the first page';

  @override
  String albumSyncCount(int count) {
    return 'Sync $count';
  }

  @override
  String albumShareCount(int count) {
    return 'Share $count';
  }

  @override
  String albumDeleteCount(int count) {
    return 'Delete $count';
  }

  @override
  String get albumNotConnectedTitle => 'Not connected';

  @override
  String get albumNotConnectedBody =>
      'The album is served over the camera\'s own Wi-Fi network. Connect to the camera first.';

  @override
  String get albumReadFailedTitle => 'Could not read the card';

  @override
  String albumReadFailedBody(String error) {
    return '$error\n\nThe camera serves photos over a slow link. Asking again usually works.';
  }

  @override
  String get albumRetryListing => 'Retry the listing';

  @override
  String get albumEmptyTitle => 'No photos found';

  @override
  String get albumEmptyBody =>
      'The card reports nothing. If the camera does have photos, the listing may have been cut short by a busy link.';

  @override
  String get albumLookAgain => 'Look for photos again';

  @override
  String get albumPreviewPending =>
      'A preview is saved; the full-resolution file is still pending.';

  @override
  String get albumPathTooLong =>
      'This path exceeds the 50-byte buffer the firmware copies it into, so it cannot be fetched.';

  @override
  String get albumNotConnectedShort => 'not connected to the camera';

  @override
  String albumLoadFailed(String error) {
    return 'loading from the camera failed: $error';
  }

  @override
  String get albumSavedCopyGone =>
      'This shot is recorded as saved, but its copy is no longer on the phone — it may have been deleted from the gallery.';

  @override
  String get syncNothingQueued => 'Nothing queued';

  @override
  String get syncPause => 'Pause';

  @override
  String get syncResume => 'Resume';

  @override
  String syncStart(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Start sync ($count photos)',
      one: 'Start sync (1 photo)',
    );
    return '$_temp0';
  }

  @override
  String get syncPreviewPausedWhileTransfer =>
      'The preview is paused while photos transfer.';

  @override
  String get syncLabel => 'Sync: ';

  @override
  String get syncModeAutoPreviewThenOriginal =>
      'Automatic — preview first, then full size';

  @override
  String get syncModeAutoOriginalOnly => 'Automatic — full size only';

  @override
  String get syncModeManualOnly => 'Manual — only what I pick';

  @override
  String get syncHideList => 'Hide list';

  @override
  String syncListCount(int count) {
    return 'List ($count)';
  }

  @override
  String get syncPauseStreamTitle => 'Pause the preview while syncing';

  @override
  String get syncPauseStreamDetail =>
      'The best speed for both. Turn this off to keep watching the preview, which makes the transfer slower.';

  @override
  String get syncRawTitle => 'RAW (.DNG) too — ~32 MB a shot';

  @override
  String get syncRawDetail =>
      'About 32 MB a shot against the JPEG\'s 5 MB, over the camera\'s own access point.';

  @override
  String syncRawQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'RAW added for $count shots already listed. Nothing transfers until you start it.',
      one:
          'RAW added for 1 shot already listed. Nothing transfers until you start it.',
    );
    return '$_temp0';
  }

  @override
  String get syncRetryFailed => 'Retry failed';

  @override
  String get syncNothingLeftToFetch => 'Nothing left to fetch.';

  @override
  String syncStillToFetch(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count shots still to fetch',
      one: '1 shot still to fetch',
    );
    return '$_temp0';
  }

  @override
  String syncRemovedFromList(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count shots removed from the sync list. Nothing was deleted from the camera.',
      one:
          '1 shot removed from the sync list. Nothing was deleted from the camera.',
    );
    return '$_temp0';
  }

  @override
  String get syncClearList => 'Clear the list';

  @override
  String get syncRemoveRowNote =>
      'Removing a row only cancels the transfer. The shot stays on the camera and nothing is sent to it.';

  @override
  String get syncCancelTransfer => 'Cancel this transfer';

  @override
  String get syncRetrying => 'Retrying…';

  @override
  String get syncStageInFlight =>
      'in flight — cancels when this request finishes';

  @override
  String get syncStagePreviewSaved => 'preview saved, full size pending';

  @override
  String get deleteNothingHereTitle => 'Nothing here can be deleted';

  @override
  String deleteConfirmTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count shots from the camera?',
      one: 'Delete 1 shot from the camera?',
    );
    return '$_temp0';
  }

  @override
  String deleteConfirmBody(int files, String pairs, int requests) {
    String _temp0 = intl.Intl.pluralLogic(
      files,
      locale: localeName,
      other: 'This removes $files files from the SD card in the camera',
      one: 'This removes 1 file from the SD card in the camera',
    );
    String _temp1 = intl.Intl.pluralLogic(
      requests,
      locale: localeName,
      other: '$requests requests',
      one: '1 request',
    );
    return '$_temp0$pairs in $_temp1.';
  }

  @override
  String deletePairsSuffix(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: ' ($count RAW+JPEG shots, where both halves go together)',
      one: ' (1 RAW+JPEG shot, where both halves go together)',
    );
    return '$_temp0';
  }

  @override
  String get deleteIrreversibleWarning =>
      'It cannot be undone from this app: the photos are not copied anywhere first, the camera keeps no copy, and this protocol has no way to restore them. Sync anything you want to keep before deleting.';

  @override
  String get deleteWillNotBeTouched => 'Will not be touched:';

  @override
  String get deleteKeepThem => 'Keep them';

  @override
  String deleteConfirmAction(int count) {
    return 'Delete $count from camera';
  }

  @override
  String deleteProgress(int index, int total, String label) {
    return 'Deleting — request $index of $total ($label)';
  }

  @override
  String get deleteNothingSent => 'Nothing was sent to the camera.';

  @override
  String get deleteHide => 'Hide';

  @override
  String get deleteDetails => 'Details';

  @override
  String deleteUnconfirmed(int count) {
    return '$count file(s) could not be confirmed either way — the camera accepted the request, but the card could not be listed again. Reload the album to see what is actually left.';
  }

  @override
  String deleteStillOnCard(int count) {
    return '$count file(s) are still on the card and were not deleted.';
  }

  @override
  String get viewerSaveToPhone => 'Save this shot to the phone';

  @override
  String get viewerQueued =>
      'Added to the sync queue. Start sync from the sync bar.';

  @override
  String get viewerUndecodable => 'This image could not be decoded.';

  @override
  String get viewerNotOnPhone => 'Not on this phone yet.';

  @override
  String get viewerFetchPreview => 'Load a preview from the camera';

  @override
  String get viewerCameraNotConnected => 'Camera not connected';

  @override
  String get viewerLocalCopy => 'Showing the copy saved on this phone.';

  @override
  String viewerLoadingFromCamera(String size) {
    return 'Loading from the camera — $size';
  }

  @override
  String get qualityOriginal => 'Full resolution';

  @override
  String get qualityPreview => 'Preview only';

  @override
  String get histogramNoData => 'no exposure data yet';

  @override
  String get histogramUnavailable => 'histogram unavailable';

  @override
  String get histogramTooltip => 'Exposure histogram';

  @override
  String histogramStats(String mean, String blown, String crushed) {
    return 'mean $mean$blown$crushed';
  }

  @override
  String histogramBlown(String percent) {
    return '  blown $percent%';
  }

  @override
  String histogramCrushed(String percent) {
    return '  crushed $percent%';
  }

  @override
  String get liveConnectionLost => 'Camera connection lost';

  @override
  String get liveCheckAgain => 'Check again';

  @override
  String get livePreviewPausedForTransfer => 'Preview paused for the transfer';

  @override
  String liveFps(String fps) {
    return '$fps fps';
  }

  @override
  String get liveHideThis => 'Hide this';

  @override
  String get livePausedBannerBody =>
      'Photos are being copied. The preview shares one Wi-Fi link with the transfer, so it is held still until the copy finishes.';

  @override
  String get liveKeepPreviewRunning => 'Keep the preview running';

  @override
  String get liveStopPreview => 'Stop the preview';

  @override
  String get liveNoFrames => 'no frames';

  @override
  String liveDrawnOfReceivedFps(String drawn, String received) {
    return '$drawn/$received fps';
  }

  @override
  String liveLossPercent(String percent) {
    return '$percent% loss';
  }

  @override
  String get liveCompositionGrid => 'Composition grid';

  @override
  String get liveFocusAtCentre => 'Focus at the centre';

  @override
  String get liveStartPreview => 'Start preview';

  @override
  String get liveStopPreviewTooltip => 'Stop preview';

  @override
  String get liveFullScreen => 'Full screen';

  @override
  String get liveExitFullScreen => 'Exit full screen';

  @override
  String get liveShutterReady => 'The shutter is ready again.';

  @override
  String liveStillBlocked(String reason) {
    return 'Still blocked: $reason';
  }

  @override
  String get liveReleaseAnyway => 'Release anyway';

  @override
  String get liveFixShutter => 'Fix the shutter';

  @override
  String get liveStartPreviewForSettings =>
      'Start the preview to read the camera settings.';

  @override
  String get liveCameraSettings => 'Camera settings';

  @override
  String get liveHideSettings => 'Hide settings';

  @override
  String get liveSettings => 'Settings';

  @override
  String get liveVideoTab => 'Video';

  @override
  String get liveAlbumTab => 'Album';

  @override
  String get liveEvReference => '· reference';

  @override
  String get liveRetry => 'Retry';

  @override
  String get liveConnectToCamera => 'Connect to camera';

  @override
  String get joinOutcomeGranted => 'Joined. Looking for the camera...';

  @override
  String get joinOutcomeSaved =>
      'Android saved the network. Allow the notification, or pick it in Wi-Fi.';

  @override
  String get joinOutcomeDismissed => 'Join prompt dismissed.';

  @override
  String get joinOutcomeTimeout => 'Android timed out joining.';

  @override
  String get liveRetryJoinLabel => 'Settings';

  @override
  String get liveConnectRetry => 'Retry';

  @override
  String get liveBleDiagnostics => 'BLE diagnostics';

  @override
  String get liveWifiDiagnostics => 'Wi-Fi diagnostics';

  @override
  String get liveOpenWifi => 'Open Wi-Fi';

  @override
  String get liveRetryJoin => 'Retry join';

  @override
  String get liveAppPermissions => 'App permissions';

  @override
  String get liveReRead => 'Re-read';

  @override
  String get liveNothingLoggedYet => '(nothing logged yet)';

  @override
  String get liveBleDiagnosticsBody =>
      'The camera advertises these properties itself. A write failure here is usually a write-type or permission mismatch, not a protocol error.';

  @override
  String get liveWifiDiagnosticsBody =>
      'The camera shows no passkey of its own, so this is where to read it. Nothing here is guessed: each line was measured on this phone just now.';

  @override
  String get liveCameraAccessPoint => 'Camera access point';

  @override
  String get liveAccessPointUnknown =>
      'Not known yet — the credentials arrive over Bluetooth when the camera switches its Wi-Fi on.';

  @override
  String get liveSsid => 'SSID';

  @override
  String get livePasskey => 'Passkey';

  @override
  String get liveNotReadYet => '(not read yet)';

  @override
  String get liveOpenedWifiPanel =>
      'Opened the Wi-Fi panel. Pick the camera network there.';

  @override
  String get liveOpenedWifiSettings =>
      'Opened Wi-Fi settings. Pick the camera network there.';

  @override
  String get liveMeasuredState => 'Measured state';

  @override
  String get liveAndroidOnly =>
      'Android only — nothing to report on this platform.';

  @override
  String get liveLocationServicesOffNote =>
      'Location services are switched OFF while the permission is granted. Android reports this as a missing permission, but the fix is the location tile in quick settings — granting the permission again will not help.';

  @override
  String get diagAndroid => 'Android';

  @override
  String get diagTargetSdk => 'Target SDK';

  @override
  String get diagDevice => 'Device';

  @override
  String get diagLocationPermission => 'Location permission';

  @override
  String get diagNearbyWifiPermission => 'Nearby-Wi-Fi permission';

  @override
  String get diagChangeWifiPermission => 'Change-Wi-Fi permission';

  @override
  String get diagChangeNetworkPermission => 'Change-network permission';

  @override
  String get diagLocationServices => 'Location services';

  @override
  String get diagWifiRadio => 'Wi-Fi radio';

  @override
  String get diagNotifications => 'Notifications';

  @override
  String get diagAddNetworkSheet => '“Add network” sheet';

  @override
  String get diagGranted => 'granted';

  @override
  String get diagNotGranted => 'NOT granted';

  @override
  String get diagUnknown => 'unknown';

  @override
  String get diagUnknownValue => '?';

  @override
  String get readoutMode => 'Mode';

  @override
  String get readoutShutter => 'Shutter';

  @override
  String get readoutAperture => 'Aperture';

  @override
  String get readoutIso => 'ISO';

  @override
  String get readoutIsoAuto => 'ISO auto';

  @override
  String get readoutEv => 'EV';

  @override
  String get readoutWb => 'WB';

  @override
  String get readoutStyle => 'Style';

  @override
  String get readoutBattery => 'Battery';

  @override
  String get readoutBatteryCharging => 'Charging';

  @override
  String get readoutBatteryChargingCompact => 'Chg';

  @override
  String get readoutLeft => 'Left';

  @override
  String readoutApertureValue(String value) {
    return 'f/$value';
  }

  @override
  String readoutIsoAutoValue(String value) {
    return 'ISO $value (auto)';
  }

  @override
  String readoutIsoValue(String value) {
    return 'ISO $value';
  }

  @override
  String readoutEvValue(String value) {
    return '$value EV';
  }

  @override
  String readoutBatteryAndLeft(String battery, String left) {
    return '$battery%  $left';
  }

  @override
  String readoutBatteryChargingAndLeft(String left) {
    return 'Charging  $left';
  }

  @override
  String settingsSetByCamera(String mode) {
    return 'Set by the camera in $mode mode — switch to M to control it';
  }

  @override
  String get dialAperture => 'Aperture';

  @override
  String get dialShutter => 'Shutter';

  @override
  String get dialIso => 'ISO';

  @override
  String get dialEv => 'EV';

  @override
  String get dialMode => 'Mode';

  @override
  String dialDecrease(String label) {
    return 'Lower $label';
  }

  @override
  String dialIncrease(String label) {
    return 'Raise $label';
  }

  @override
  String get dialDisabledByMode => 'not adjustable';

  @override
  String get albumRawJpgBadge => 'RAW+JPG';

  @override
  String get albumRawBadge => 'RAW';

  @override
  String get albumRawPending => 'RAW pending';

  @override
  String get albumVideoBadge => 'VIDEO';

  @override
  String get firstRunStepWhatItDoes => 'What this app does';

  @override
  String get firstRunStepHowPhotosCome => 'How photos should come across';

  @override
  String get firstRunStepPair => 'Pair with the camera';

  @override
  String firstRunStepOf(int step, int total) {
    return 'Step $step of $total';
  }

  @override
  String get firstRunTitle => 'First run & pairing';

  @override
  String get firstRunSkip => 'Skip';

  @override
  String get firstRunClose => 'Close';

  @override
  String get firstRunBack => 'Back';

  @override
  String get firstRunNext => 'Next';

  @override
  String get firstRunStartPairing => 'Start pairing';

  @override
  String get firstRunPairTryAgain => 'Try again';

  @override
  String get firstRunPairFailedHelp =>
      'That attempt is over — nothing is still waiting on the camera. Press Try again with the camera awake and in front of you, then press Accept on its screen within a few seconds.';

  @override
  String get firstRunDone => 'Done';

  @override
  String get firstRunIntro =>
      'It controls your YI M1 over Wi-Fi: a live viewfinder, the shutter, the settings the camera exposes, and a copy of the card in your phone\'s gallery. Nothing is sent to any server — the phone talks to the camera, and the photos land on the phone.';

  @override
  String get firstRunWifiOneDeviceTitle =>
      'The camera\'s Wi-Fi takes one device at a time';

  @override
  String get firstRunWifiOneDeviceDetail =>
      'If a PC or tablet is connected to the camera, this phone cannot be. Disconnect the other device first — otherwise the join fails in a way that reads like a wrong password.';

  @override
  String get firstRunAcceptOnCameraTitle =>
      'Pairing needs a press on the camera body';

  @override
  String get firstRunAcceptOnCameraDetail =>
      'When you start pairing, the camera asks you to confirm. You have a few seconds to press Accept on its screen. A PC that has already paired can take that turn, so pair from the device you actually want to use.';

  @override
  String get firstRunSyncIntro =>
      'Asked once, and remembered. You can change it later on the Sync screen, or by reopening this guide from the ? button in the top bar.';

  @override
  String get firstRunSyncFoot =>
      'Previews are small and appear in seconds; a full-size photo is several megabytes over a slow radio. This only decides what happens automatically — you can always pick individual photos in the album.';

  @override
  String get firstRunSyncAutoPreviewTitle =>
      'Automatic — a small preview first, then the full size';

  @override
  String get firstRunSyncAutoPreviewBody =>
      'A preview is small and appears in seconds, so the whole card is browsable quickly; the full-size file follows behind it.';

  @override
  String get firstRunSyncAutoOriginalTitle => 'Automatic — full size only';

  @override
  String get firstRunSyncAutoOriginalBody =>
      'Nothing lands on the phone that is not the real file, but each photo is several megabytes over a slow radio, so the first one takes a while.';

  @override
  String get firstRunSyncManualTitle => 'Manual — only what I pick';

  @override
  String get firstRunSyncManualBody =>
      'Nothing moves until you choose it. Browsing the card queues nothing, which is the safe choice on a metered or slow link.';

  @override
  String get firstRunKeepAwake =>
      'Keep the camera awake and powered on. If nothing happens for ten seconds, the camera did not get the confirmation and the attempt has to be made again.';

  @override
  String get firstRunKeepAwakeAfterAsk =>
      'Keep the camera awake and powered on. If nothing happens for ten seconds after you ask to pair, the camera did not get the confirmation and the attempt has to be made again.';

  @override
  String get firstRunFourThings => 'Four things happen, in this order:';

  @override
  String get firstRunPairFind => 'Find the camera over Bluetooth';

  @override
  String get firstRunPairConfirm => 'Confirm the pairing on the camera body';

  @override
  String get firstRunPairAccept =>
      'Press Accept on the camera — it belongs to the camera, not to the app';

  @override
  String get firstRunPairReadCredentials =>
      'Read the camera\'s Wi-Fi name and password';

  @override
  String get firstRunPairJoin =>
      'Join that network and check the camera answers';

  @override
  String get firstRunNotConnected =>
      'Not connected. Pressing Start pairing asks the camera to confirm — have the camera switched on and in front of you.';

  @override
  String get firstRunConnected =>
      'Connected. The Camera tab now has the live view, the shutter and the settings.';

  @override
  String get videoNotConnected => 'Not connected to the camera.';

  @override
  String get videoStartPreviewFirst =>
      'Start the preview first — the camera only accepts remote commands while remote mode is active.';

  @override
  String videoRefusedNotRemote(String label) {
    return '$label was refused because the camera is not in remote mode. Start the preview and try again.';
  }

  @override
  String videoFailed(String label, String detail) {
    return '$label failed: $detail';
  }

  @override
  String videoRejected404(String label) {
    return '$label was rejected: the camera answered 404, which on this firmware means the command or its value is not accepted by this body.';
  }

  @override
  String get videoStartRecording => 'Start recording';

  @override
  String get videoStopRecording => 'Stop recording';

  @override
  String get videoChangeFormat => 'Change format';

  @override
  String get videoCautionTitle => 'Remote video is partly unverified';

  @override
  String get videoCautionBody =>
      'Recording start/stop and the format command have been sent to a real camera and accepted. Nothing has confirmed yet that the clip reaches the SD card, so check the card before relying on it.\n\nThe stabilisation, noise reduction and audio controls have NOT been verified on hardware at all: they were read out of the firmware\'s command table, and a value that table lists can still be refused by this body.\n\nThis camera has no watchdog, so a command it does not expect can leave it unresponsive until the battery is removed. If it stops answering, power-cycle it.';

  @override
  String get videoNotNow => 'Not now';

  @override
  String get videoUnderstandContinue => 'I understand — continue';

  @override
  String get videoPageTitle => 'Video recording';

  @override
  String get videoWhatIsVerified => 'What is verified?';

  @override
  String get videoRecordingFormat => 'Recording format';

  @override
  String get videoFormatBlockedNote =>
      'Blocked while recording: the camera encodes the format it started with.';

  @override
  String get videoUnavailableUntilPreview =>
      'Unavailable until the preview is running.';

  @override
  String get videoStopRecordingFirst =>
      'Stop the recording before changing the format.';

  @override
  String get videoVideoQuality => 'Video quality';

  @override
  String get videoElectronicStabilisation => 'Electronic stabilisation';

  @override
  String get videoNoiseReduction => 'Noise reduction';

  @override
  String get videoAudio => 'Audio';

  @override
  String get videoRecordAudio => 'Record audio';

  @override
  String get videoNoStateYet =>
      'No camera state yet. These values are read from the preview stream, so they appear with the first frame.';

  @override
  String get videoReportedByCamera => 'Reported by the camera';

  @override
  String get videoRowFormat => 'Format';

  @override
  String get videoRowAudio => 'Audio';

  @override
  String get videoRowVolume => 'Volume';

  @override
  String get videoRowNoiseReduction => 'Noise reduction';

  @override
  String get videoRowStabilisation => 'Stabilisation';

  @override
  String videoRequestedNotReported(String format) {
    return 'Asked for $format. The camera has not reported it yet — the stream is the only acknowledgement that counts on this firmware, so this is not a change until it appears above.';
  }

  @override
  String get videoRecordingIndicator => 'RECORDING';

  @override
  String get videoIdle => 'Idle';

  @override
  String get videoTimerNote =>
      'Recording state and the timer are tracked by the app: the camera reports the video settings in every frame but says nothing about whether it is recording.';

  @override
  String get videoUnknown => 'unknown';

  @override
  String get videoUnconfirmed => 'unconfirmed';

  @override
  String videoRequestedWaiting(String format) {
    return '$format requested — waiting for the camera.';
  }

  @override
  String get videoFormatPoolNote =>
      'The list is the firmware\'s own value pool, which is shared across bodies: a format can exist in firmware and still be refused by this one. A refusal comes back as a 404 and is reported here.';

  @override
  String get videoStateNotReported => 'state not reported yet';

  @override
  String videoSending(String command) {
    return 'sending $command...';
  }

  @override
  String get videoVolume => 'Volume';

  @override
  String get videoNoVolumeYet => 'The camera reports no volume yet.';

  @override
  String videoCameraReports(String value) {
    return 'Camera reports $value.';
  }

  @override
  String get videoChangeInFlight => ' A change is in flight.';

  @override
  String get videoCautionFoot =>
      'These commands have not all been verified on real hardware. The camera has no watchdog, so if it stops responding, power-cycle it.';

  @override
  String get videoOn => 'ON';

  @override
  String get videoOff => 'OFF';

  @override
  String get linkScanning => 'looking for the camera...';

  @override
  String get linkNotFound =>
      'camera not found. Is it powered on, and not already held by the official app?';

  @override
  String get linkConnecting => 'connecting...';

  @override
  String get linkReadingIdentity => 'reading camera identity...';

  @override
  String get linkUnreadableIdentity =>
      'camera answered with an unreadable identity';

  @override
  String linkFound(String firmware, String region) {
    return 'found $firmware ($region)';
  }

  @override
  String linkReusingPairing(String refId) {
    return 'reusing the saved pairing (refId $refId)...';
  }

  @override
  String linkSavedPairingRejected(String detail) {
    return 'saved pairing did not take ($detail); pairing fresh';
  }

  @override
  String linkPressAllow(String refId) {
    return 'PRESS ALLOW ON THE CAMERA now (refId $refId)';
  }

  @override
  String get linkPairingNotConfirmed =>
      'the camera did not confirm the pairing. It must be accepted on the camera screen within a few seconds.';

  @override
  String get linkOpeningSession => 'opening the session...';

  @override
  String get linkEnablingWifi => 'switching the camera Wi-Fi on...';

  @override
  String get linkReadingCredentials => 'reading Wi-Fi credentials...';

  @override
  String get linkPairingForgotten =>
      'the camera refused the saved pairing, so it has been forgotten; press Connect again to pair from scratch (the camera will ask for confirmation).';

  @override
  String get linkNoCredentials =>
      'the camera did not hand over Wi-Fi credentials. The session may not have been accepted.';

  @override
  String linkAskingAndroidToJoin(String ssid) {
    return 'asking Android to join \"$ssid\"...';
  }

  @override
  String linkJoined(String ssid) {
    return 'joined \"$ssid\" — waiting for the camera to answer...';
  }

  @override
  String linkJoinedUnbound(String ssid) {
    return 'joined \"$ssid\" — waiting for the camera...';
  }

  @override
  String linkSavedNetworkInstead(String ssid, String credential) {
    return 'Android saved \"$ssid\" as a network instead of joining it. If a notification appears, allow it — otherwise open Wi-Fi and pick it. The passkey is already filled in ($credential). Waiting...';
  }

  @override
  String linkJoinDismissed(String ssid, String credential) {
    return 'the join prompt was dismissed. Tap \"Retry join\" to bring it back, or connect to \"$ssid\" yourself with the passkey $credential.';
  }

  @override
  String linkJoinTimedOut(String ssid) {
    return 'Android did not finish joining \"$ssid\" in time.';
  }

  @override
  String linkJoinUnsupported(String ssid, String credential) {
    return 'this phone will not let the app join \"$ssid\" by itself, so the Wi-Fi screen was opened. Choose \"$ssid\" there — the passkey is $credential (the camera does not show it).';
  }

  @override
  String linkJoinManual(
      String detail, String ssid, String credential, String permissions) {
    return '$detail You can also connect to \"$ssid\" by hand with the passkey $credential. [$permissions]';
  }

  @override
  String linkWaitingForCamera(int seconds) {
    return 'waiting for the camera to answer (${seconds}s left)...';
  }

  @override
  String linkCameraNotAnswering(String host, String ssid, String passkey) {
    return 'the camera is not answering on $host. Check that the phone is on \"$ssid\" — its passkey is $passkey — then retry.';
  }

  @override
  String get linkConnected => 'connected';

  @override
  String get linkPreviewRunning => 'preview running';

  @override
  String get linkPreviewStopped => 'preview stopped';

  @override
  String get linkDisconnected => 'disconnected';

  @override
  String get linkDisconnectedNoPairing =>
      'Disconnected, but the camera\'s Wi-Fi is still on — the camera no longer holds this phone\'s pairing, so the app has no authenticated channel to switch it with. Press the camera\'s power switch, or reconnect and disconnect again, to stop it advertising.';

  @override
  String get linkDisconnectedRadioRefused =>
      'Disconnected, but the camera\'s Wi-Fi is still on — the camera did not acknowledge the switch-off command. Press the camera\'s power switch, or reconnect and disconnect again, to stop it advertising.';

  @override
  String get linkDisconnectedNoBle =>
      'Disconnected, but the camera\'s Wi-Fi is still on — the Bluetooth link to the camera was already gone, so the switch-off command had no way to reach it. Press the camera\'s power switch, or reconnect and disconnect again, to stop it advertising.';

  @override
  String get linkIdle => 'not connected';

  @override
  String get linkLostContact =>
      'Lost contact with the camera. It may have been switched off, or the phone may have left the camera\'s Wi-Fi network.';

  @override
  String get stageQueued => 'Queued';

  @override
  String get stagePreview => 'Preview';

  @override
  String get stageDownloading => 'Downloading';

  @override
  String get stageStalled => 'Stalled, retrying';

  @override
  String get stagePausedNoCamera => 'Paused, camera away';

  @override
  String get stagePausedByUser => 'Paused by you';

  @override
  String get stagePausedLowBattery => 'Paused, camera battery low';

  @override
  String get stageDone => 'Saved';

  @override
  String get syncNoteCameraAway =>
      'The camera went away. Sync resumes when it is back.';

  @override
  String get syncNotePausedByUser => 'Paused by you.';

  @override
  String get syncStreamPauseReason =>
      'Preview paused while photos transfer — the live view and a full-resolution download share one Wi-Fi link, so they slow each other down. It comes back as soon as the transfer finishes.';

  @override
  String get deleteRefusalProtected =>
      'the camera lists this file as protected. What that flag means on this firmware is not verified, so the app treats it as a refusal to delete rather than guessing — remove the protection, or delete it on the camera';

  @override
  String deleteRefusalPathTooLong(int length, int limit) {
    return 'the path is $length characters, and DeleteFile copies each entry into a $limit-character slot, so the camera would truncate it and could delete the wrong file';
  }

  @override
  String get deleteRefusalListingFailed =>
      'the card could not be listed after the delete, so this file\'s fate is unknown';

  @override
  String albumErrListingRejected(int start, int end) {
    return 'GetFileList answered 404 for range $start..$end. On this firmware that means the parameters were rejected, not that the command is missing.';
  }

  @override
  String albumErrListingFailed(String raw) {
    return 'GetFileList failed: $raw';
  }

  @override
  String albumErrPathTooLong(int length, String path) {
    return 'path is $length chars; the firmware copies it into a 50-byte buffer so this can never be fetched: $path';
  }

  @override
  String albumErrDeleteRejected(int count) {
    return 'DeleteFile answered 404 for $count path(s). On this firmware that means the request shape was rejected — not that the file is gone.';
  }

  @override
  String get albumErrDeleteNoPaths => 'DeleteFile needs at least one path';

  @override
  String albumErrDeleteTooMany(int limit, int count) {
    return 'DeleteFile takes at most $limit paths per call and was given $count; the firmware clamps the list and silently drops the rest, so this would look like success while leaving files behind';
  }

  @override
  String get albumErrDeleteAll =>
      'refusing to send DeleteFile file_list \"ALL\": on this firmware that means delete every file on the card';

  @override
  String albumErrDeletePathTooLong(String path, int length, int limit) {
    return 'DeleteFile copies each path into a 56-byte slot, so \"$path\" ($length chars) would be truncated and could delete the wrong file; the limit is $limit';
  }

  @override
  String noticeUnwiredRow(String label) {
    return 'Nothing is wired to \"$label\" yet.';
  }

  @override
  String get errStorageDenied =>
      'Android will not let the app write to the photo library, so nothing can be saved. Grant the storage permission to this app, then start the sync again.';

  @override
  String get errPreviewRefused => 'the camera refused to start the preview';

  @override
  String get noticeShotsNotOnPhone =>
      'Those shots are not on this phone yet. Sync them first, or share from the camera by syncing and then sharing.';

  @override
  String get errShareAndroidOnly => 'sharing is only implemented on Android.';

  @override
  String get errShareSheetRefused =>
      'Android would not open a share sheet for those files.';

  @override
  String noticeSharedPartially(int missing, int total) {
    return 'Shared $missing of $total; the rest are still syncing.';
  }

  @override
  String get noticeShotNotOnPhone => 'That shot is not on this phone yet.';

  @override
  String get errNoViewerApp => 'No app on this phone would open that file.';

  @override
  String get errRemoveCopyFailed => 'Could not remove the phone\'s copy.';

  @override
  String get errDeleteNotConnected =>
      'not connected to the camera, so there is nothing to delete.';

  @override
  String get noticeNothingSentAllRefused =>
      'Nothing was sent: every selected shot is one the app will not delete. See the reasons listed.';

  @override
  String get noticeNothingToDelete => 'Nothing to delete.';

  @override
  String errDeleteFailed(String detail) {
    return 'the delete could not be carried out: $detail';
  }

  @override
  String get errNotConnectedShort => 'not connected';

  @override
  String errCommandFailed(String command, String detail) {
    return '$command failed: $detail';
  }

  @override
  String errCommandRejected404(String command) {
    return '$command was rejected — the camera answered 404, which on this firmware means the parameters were wrong';
  }

  @override
  String errShutterReleaseFailed(String detail) {
    return 'The shutter could not be released: $detail. If the camera has stopped answering, it needs a power cycle.';
  }

  @override
  String errShutterHealthCheckFailed(String detail) {
    return 'The camera did not answer the health check, so the shutter stays locked: $detail. If it was frozen, it needs a power cycle.';
  }

  @override
  String get errInterlockReleasedNoRemote =>
      'The interlock was released, but the camera did not re-enter remote mode. Power-cycle it if it was frozen.';

  @override
  String get errInterlockReleasedStillBlocked =>
      'The interlock was released, but the shutter is still blocked.';

  @override
  String get noticeInterlockReleased =>
      'Capture interlock released — the shutter is ready again.';

  @override
  String get errPhotoFail =>
      'The camera refused the shot (\"photo fail\"). That means it is not in remote mode, or the previous shot is still being written to the card.';

  @override
  String get errCaptureNotReached => 'the capture did not reach the camera';

  @override
  String get noticeFocusSkippedForShot =>
      'A shot is being taken, so the focus point was not sent.';

  @override
  String errFocusFailed(String detail) {
    return 'RCDoFocus failed: $detail';
  }

  @override
  String get errFocusRejected404 =>
      'RCDoFocus was rejected — the camera answered 404, which on this firmware means the parameters were wrong';

  @override
  String errUnknownParamCommand(String command) {
    return 'unknown parameter command $command';
  }

  @override
  String errCommandNotInTable(String command) {
    return '$command is not in the firmware command table';
  }

  @override
  String noticeParamSetByCamera(String mode) {
    return 'In $mode mode the camera sets this itself, so the change was not applied. Switch to M to control it directly.';
  }

  @override
  String get shutterBlockedNotConnected => 'Not connected to the camera.';

  @override
  String get shutterBlockedNotRemote =>
      'The camera is not in remote mode, so it will not accept a shot. Start the preview — or press \"Fix the shutter\" below to do it.';

  @override
  String shutterBlockedBurst(String drive) {
    return 'The camera is in $drive drive. A single command starts a burst that this app has no way to stop — the camera keeps shooting until it locks up and needs its battery removed. Set the drive mode to Single, or use the camera itself.';
  }

  @override
  String get shutterBlockedQuarantined =>
      'The camera refused the last capture and its capture state is now stuck — this is the fault the patched firmware fixes. Waiting will not clear it: power-cycle the camera, then reconnect.';

  @override
  String get settingsTabCapture => 'Capture';

  @override
  String get settingsTabSync => 'Sync';

  @override
  String get settingsGroupExposure => 'Exposure and focus';

  @override
  String get settingsGroupImage => 'Image output';

  @override
  String get settingsGroupImageSummary => 'Aspect, file format, quality';

  @override
  String get settingsGroupScene => 'Scene and look';

  @override
  String get settingsGroupSceneSummary => 'Picture style';

  @override
  String get settingsGroupVideo => 'Video and audio';

  @override
  String get settingsGroupVideoSummary =>
      'Format, stabilisation, noise reduction, volume';

  @override
  String get settingsGroupTransfer => 'Transfer';

  @override
  String get settingsGroupTransferSummary =>
      'Sync mode, preview during transfer';

  @override
  String get settingsGroupConnection => 'Connection diagnostics';

  @override
  String get settingsGroupConnectionSummary =>
      'Wi-Fi permissions, SSID, passkey';

  @override
  String get settingsGroupSystem => 'System and diagnostics';

  @override
  String get settingsGroupSystemSummary => 'Screen timeout, BLE log';

  @override
  String get settingsRowRCSwitchDialMode => 'Exposure mode';

  @override
  String get settingsRowRCISOSet => 'ISO';

  @override
  String get settingsRowRCFNSet => 'Aperture';

  @override
  String get settingsRowRCShutterSpeedSet => 'Shutter';

  @override
  String get settingsRowRCEVSet => 'Exposure comp.';

  @override
  String get settingsRowRCWBSet => 'White balance';

  @override
  String get settingsRowRCMeteringModeSet => 'Metering';

  @override
  String get settingsRowRCFocusModeSet => 'Focus mode';

  @override
  String get settingsRowRCDriveModeSet => 'Drive';

  @override
  String get settingsRowRCImageAspect => 'Aspect';

  @override
  String get settingsRowRCFileFormatSet => 'File format';

  @override
  String get settingsRowRCImageQualitySet => 'Image quality';

  @override
  String get settingsRowRCChooseColorMode => 'Picture style';

  @override
  String get settingsRowNavVideo => 'Open remote video';

  @override
  String get settingsRowNavAlbum => 'Open the sync page';

  @override
  String get settingsRowDiagWifi => 'Wi-Fi diagnostics';

  @override
  String get settingsRowDiagBle => 'BLE diagnostics';

  @override
  String get settingsRowPauseStream => 'Pause the preview during transfer';

  @override
  String get settingsRowPauseStreamNote =>
      'The preview and a bulk transfer share one 802.11n link, so a copy holds the stream still until it finishes.';

  @override
  String get settingsRowKeepScreenOn => 'Keep the screen on while previewing';

  @override
  String get settingsRowKeepScreenOnNote =>
      'A camera controller is held at arm\'s length with both hands busy, so a screen that times out mid-composition cannot be recovered without losing the shot.';

  @override
  String get settingsRowLocale => 'Language';

  @override
  String get localePickerTitle => 'Language';

  @override
  String get localePickerNote => 'Takes effect immediately and is remembered.';

  @override
  String get localeSystem => 'Follow the phone';

  @override
  String get localeEnglish => 'English';

  @override
  String get localeChinese => '简体中文';

  @override
  String localeSelected(String name) {
    return 'Selected: $name';
  }

  @override
  String get paramAuto => 'Auto';

  @override
  String get paramManual => 'Manual';

  @override
  String get paramMulti => 'Multi';

  @override
  String get paramSpot => 'Spot';

  @override
  String get paramCenterWeighted => 'Centre weighted';

  @override
  String get paramCAF => 'C-AF';

  @override
  String get paramSAF => 'S-AF';

  @override
  String get paramMF => 'MF';

  @override
  String get paramSingle => 'Single';

  @override
  String get paramContinuous => 'Continuous';

  @override
  String get paramDelay2s => '2 s timer';

  @override
  String get paramDelay10s => '10 s timer';

  @override
  String get paramSunny => 'Sunny';

  @override
  String get paramCloudy => 'Cloudy';

  @override
  String get paramShadow => 'Shadow';

  @override
  String get paramIncandescent => 'Incandescent';

  @override
  String get paramStandard => 'Standard';

  @override
  String get paramPortrait => 'Portrait';

  @override
  String get paramVivid => 'Vivid';

  @override
  String get paramNaturalBw => 'NaturalBW';

  @override
  String get paramHighContrastBw => 'HContrastBW';

  @override
  String get paramTime => 'TIME';

  @override
  String get paramBulb => 'BULB';

  @override
  String get paramVga => 'VGA';

  @override
  String get paramJpgSmall => 'JPG S';

  @override
  String get paramJpgMedium => 'JPG M';

  @override
  String get paramJpgLarge => 'JPG L';

  @override
  String get paramRawJpgSmall => 'RAW+JPG S';

  @override
  String get paramRawJpgMedium => 'RAW+JPG M';

  @override
  String get paramRawJpgLarge => 'RAW+JPG L';
}
