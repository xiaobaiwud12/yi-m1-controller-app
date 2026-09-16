import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'M1 Controller'**
  String get appTitle;

  /// No description provided for @startupFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'The app failed to start'**
  String get startupFailedTitle;

  /// No description provided for @startupFailedBody.
  ///
  /// In en, this message translates to:
  /// **'This is a problem in the app, not the camera. The text below is what went wrong and is worth reporting.'**
  String get startupFailedBody;

  /// No description provided for @startupUnknownError.
  ///
  /// In en, this message translates to:
  /// **'unknown error'**
  String get startupUnknownError;

  /// No description provided for @continueToApp.
  ///
  /// In en, this message translates to:
  /// **'Continue to the app'**
  String get continueToApp;

  /// No description provided for @disconnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Disconnect?'**
  String get disconnectTitle;

  /// No description provided for @disconnectBody.
  ///
  /// In en, this message translates to:
  /// **'This stops the preview and releases the camera\'s Wi-Fi, which is what it wants when nobody is using it. The pairing is kept, so reconnecting will not need a confirmation on the camera.'**
  String get disconnectBody;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @guideTooltip.
  ///
  /// In en, this message translates to:
  /// **'First run & pairing guide'**
  String get guideTooltip;

  /// No description provided for @disconnectTooltip.
  ///
  /// In en, this message translates to:
  /// **'Disconnect from the camera'**
  String get disconnectTooltip;

  /// No description provided for @checkCameraTooltip.
  ///
  /// In en, this message translates to:
  /// **'Check the camera is still there'**
  String get checkCameraTooltip;

  /// No description provided for @licencesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Licences, credits and who made this'**
  String get licencesTooltip;

  /// No description provided for @licencesLegalese.
  ///
  /// In en, this message translates to:
  /// **'An unofficial, third-party app for the YI M1 (C59Y1) camera — not affiliated with, authorised by, or endorsed by YI Technology. The app itself is Apache-2.0; the open-source components bundled in this build are listed below, each under its own licence.'**
  String get licencesLegalese;

  /// No description provided for @cameraResponding.
  ///
  /// In en, this message translates to:
  /// **'Camera is responding.'**
  String get cameraResponding;

  /// No description provided for @cameraSilent.
  ///
  /// In en, this message translates to:
  /// **'No answer from the camera.'**
  String get cameraSilent;

  /// No description provided for @navCapture.
  ///
  /// In en, this message translates to:
  /// **'Capture'**
  String get navCapture;

  /// No description provided for @navSync.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get navSync;

  /// No description provided for @firmwareNotConnected.
  ///
  /// In en, this message translates to:
  /// **'not connected'**
  String get firmwareNotConnected;

  /// No description provided for @albumListingRejected.
  ///
  /// In en, this message translates to:
  /// **'The camera rejected the listing parameters, which points at a protocol mismatch:\n{detail}'**
  String albumListingRejected(String detail);

  /// No description provided for @albumUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the camera.\n{detail}'**
  String albumUnreachable(String detail);

  /// No description provided for @albumOnThisPhone.
  ///
  /// In en, this message translates to:
  /// **'On this phone ({name})'**
  String albumOnThisPhone(String name);

  /// No description provided for @albumNotOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Not on this phone yet'**
  String get albumNotOnPhone;

  /// No description provided for @actionShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get actionShare;

  /// No description provided for @actionShareSubtitleOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Send to another app'**
  String get actionShareSubtitleOnPhone;

  /// No description provided for @actionShareSubtitleNotOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Sync it first'**
  String get actionShareSubtitleNotOnPhone;

  /// No description provided for @actionOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get actionOpen;

  /// No description provided for @actionOpenSubtitleOnPhone.
  ///
  /// In en, this message translates to:
  /// **'In the phone\'s own viewer'**
  String get actionOpenSubtitleOnPhone;

  /// No description provided for @actionSyncThis.
  ///
  /// In en, this message translates to:
  /// **'Sync this shot'**
  String get actionSyncThis;

  /// No description provided for @actionRemoveFromPhone.
  ///
  /// In en, this message translates to:
  /// **'Remove from this phone'**
  String get actionRemoveFromPhone;

  /// No description provided for @actionRemoveFromPhoneSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keeps it on the camera'**
  String get actionRemoveFromPhoneSubtitle;

  /// No description provided for @actionDeleteFromCamera.
  ///
  /// In en, this message translates to:
  /// **'Delete from the camera'**
  String get actionDeleteFromCamera;

  /// No description provided for @actionDeleteFromCameraSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Cannot be undone; the camera has no undo'**
  String get actionDeleteFromCameraSubtitle;

  /// Title of the Android share sheet, which is drawn by the system outside the app.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Share shot} other{Share {count} shots}}'**
  String albumShareSheetTitle(int count);

  /// No description provided for @albumRemoveConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove from this phone?'**
  String get albumRemoveConfirmTitle;

  /// No description provided for @albumRemoveConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'The copy in your gallery is deleted. The shot stays on the camera\'s card — this is the opposite of Delete.\n\n{path}'**
  String albumRemoveConfirmBody(String path);

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @albumDeleteStarting.
  ///
  /// In en, this message translates to:
  /// **'starting'**
  String get albumDeleteStarting;

  /// No description provided for @albumSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String albumSelectedCount(int count);

  /// No description provided for @albumTitleCount.
  ///
  /// In en, this message translates to:
  /// **'Album  ·  {count} shots'**
  String albumTitleCount(int count);

  /// No description provided for @albumSyncSelectedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sync the selected shots'**
  String get albumSyncSelectedTooltip;

  /// No description provided for @albumDeleteSelectedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete the selected shots from the camera'**
  String get albumDeleteSelectedTooltip;

  /// No description provided for @albumDeleteBusyTooltip.
  ///
  /// In en, this message translates to:
  /// **'A delete is already running'**
  String get albumDeleteBusyTooltip;

  /// No description provided for @albumSelectTooltip.
  ///
  /// In en, this message translates to:
  /// **'Select shots'**
  String get albumSelectTooltip;

  /// No description provided for @albumReloadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reload everything, from the first page'**
  String get albumReloadTooltip;

  /// No description provided for @albumSyncCount.
  ///
  /// In en, this message translates to:
  /// **'Sync {count}'**
  String albumSyncCount(int count);

  /// No description provided for @albumShareCount.
  ///
  /// In en, this message translates to:
  /// **'Share {count}'**
  String albumShareCount(int count);

  /// No description provided for @albumDeleteCount.
  ///
  /// In en, this message translates to:
  /// **'Delete {count}'**
  String albumDeleteCount(int count);

  /// No description provided for @albumNotConnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get albumNotConnectedTitle;

  /// No description provided for @albumNotConnectedBody.
  ///
  /// In en, this message translates to:
  /// **'The album is served over the camera\'s own Wi-Fi network. Connect to the camera first.'**
  String get albumNotConnectedBody;

  /// No description provided for @albumReadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not read the card'**
  String get albumReadFailedTitle;

  /// No description provided for @albumReadFailedBody.
  ///
  /// In en, this message translates to:
  /// **'{error}\n\nThe camera serves photos over a slow link. Asking again usually works.'**
  String albumReadFailedBody(String error);

  /// No description provided for @albumRetryListing.
  ///
  /// In en, this message translates to:
  /// **'Retry the listing'**
  String get albumRetryListing;

  /// No description provided for @albumEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No photos found'**
  String get albumEmptyTitle;

  /// No description provided for @albumEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'The card reports nothing. If the camera does have photos, the listing may have been cut short by a busy link.'**
  String get albumEmptyBody;

  /// No description provided for @albumLookAgain.
  ///
  /// In en, this message translates to:
  /// **'Look for photos again'**
  String get albumLookAgain;

  /// No description provided for @albumPreviewPending.
  ///
  /// In en, this message translates to:
  /// **'A preview is saved; the full-resolution file is still pending.'**
  String get albumPreviewPending;

  /// No description provided for @albumPathTooLong.
  ///
  /// In en, this message translates to:
  /// **'This path exceeds the 50-byte buffer the firmware copies it into, so it cannot be fetched.'**
  String get albumPathTooLong;

  /// No description provided for @albumNotConnectedShort.
  ///
  /// In en, this message translates to:
  /// **'not connected to the camera'**
  String get albumNotConnectedShort;

  /// No description provided for @albumLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'loading from the camera failed: {error}'**
  String albumLoadFailed(String error);

  /// No description provided for @albumSavedCopyGone.
  ///
  /// In en, this message translates to:
  /// **'This shot is recorded as saved, but its copy is no longer on the phone — it may have been deleted from the gallery.'**
  String get albumSavedCopyGone;

  /// No description provided for @syncNothingQueued.
  ///
  /// In en, this message translates to:
  /// **'Nothing queued'**
  String get syncNothingQueued;

  /// No description provided for @syncPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get syncPause;

  /// No description provided for @syncResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get syncResume;

  /// No description provided for @syncStart.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Start sync (1 photo)} other{Start sync ({count} photos)}}'**
  String syncStart(int count);

  /// No description provided for @syncPreviewPausedWhileTransfer.
  ///
  /// In en, this message translates to:
  /// **'The preview is paused while photos transfer.'**
  String get syncPreviewPausedWhileTransfer;

  /// No description provided for @syncLabel.
  ///
  /// In en, this message translates to:
  /// **'Sync: '**
  String get syncLabel;

  /// No description provided for @syncModeAutoPreviewThenOriginal.
  ///
  /// In en, this message translates to:
  /// **'Automatic — preview first, then full size'**
  String get syncModeAutoPreviewThenOriginal;

  /// No description provided for @syncModeAutoOriginalOnly.
  ///
  /// In en, this message translates to:
  /// **'Automatic — full size only'**
  String get syncModeAutoOriginalOnly;

  /// No description provided for @syncModeManualOnly.
  ///
  /// In en, this message translates to:
  /// **'Manual — only what I pick'**
  String get syncModeManualOnly;

  /// No description provided for @syncHideList.
  ///
  /// In en, this message translates to:
  /// **'Hide list'**
  String get syncHideList;

  /// No description provided for @syncListCount.
  ///
  /// In en, this message translates to:
  /// **'List ({count})'**
  String syncListCount(int count);

  /// No description provided for @syncPauseStreamTitle.
  ///
  /// In en, this message translates to:
  /// **'Pause the preview while syncing'**
  String get syncPauseStreamTitle;

  /// No description provided for @syncPauseStreamDetail.
  ///
  /// In en, this message translates to:
  /// **'The best speed for both. Turn this off to keep watching the preview, which makes the transfer slower.'**
  String get syncPauseStreamDetail;

  /// Label of the sync bar's RAW opt-in, on the album page. The cost is in the label rather than only in the note below it, because the note is dropped on a short screen (landscape) and capped at two lines on a tall one — and the one thing this switch must never do is spend 32 MB a shot without saying so. The number sits in the first half of the label on purpose: the label is capped at one line, so an ellipsized tail must not be where the number lives.
  ///
  /// In en, this message translates to:
  /// **'RAW (.DNG) too — ~32 MB a shot'**
  String get syncRawTitle;

  /// The note under the RAW opt-in. Dropped on short screens and capped at two lines, which is why the label above it carries the number too.
  ///
  /// In en, this message translates to:
  /// **'About 32 MB a shot against the JPEG\'s 5 MB, over the camera\'s own access point.'**
  String get syncRawDetail;

  /// Snackbar after the RAW opt-in is switched on. It says what was added to the list AND that queued is not transferring, because one tap on this switch can add hundreds of megabytes to the queue.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{RAW added for 1 shot already listed. Nothing transfers until you start it.} other{RAW added for {count} shots already listed. Nothing transfers until you start it.}}'**
  String syncRawQueued(int count);

  /// No description provided for @syncRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry failed'**
  String get syncRetryFailed;

  /// No description provided for @syncNothingLeftToFetch.
  ///
  /// In en, this message translates to:
  /// **'Nothing left to fetch.'**
  String get syncNothingLeftToFetch;

  /// No description provided for @syncStillToFetch.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 shot still to fetch} other{{count} shots still to fetch}}'**
  String syncStillToFetch(int count);

  /// No description provided for @syncRemovedFromList.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 shot removed from the sync list. Nothing was deleted from the camera.} other{{count} shots removed from the sync list. Nothing was deleted from the camera.}}'**
  String syncRemovedFromList(int count);

  /// No description provided for @syncClearList.
  ///
  /// In en, this message translates to:
  /// **'Clear the list'**
  String get syncClearList;

  /// No description provided for @syncRemoveRowNote.
  ///
  /// In en, this message translates to:
  /// **'Removing a row only cancels the transfer. The shot stays on the camera and nothing is sent to it.'**
  String get syncRemoveRowNote;

  /// No description provided for @syncCancelTransfer.
  ///
  /// In en, this message translates to:
  /// **'Cancel this transfer'**
  String get syncCancelTransfer;

  /// No description provided for @syncRetrying.
  ///
  /// In en, this message translates to:
  /// **'Retrying…'**
  String get syncRetrying;

  /// No description provided for @syncStageInFlight.
  ///
  /// In en, this message translates to:
  /// **'in flight — cancels when this request finishes'**
  String get syncStageInFlight;

  /// No description provided for @syncStagePreviewSaved.
  ///
  /// In en, this message translates to:
  /// **'preview saved, full size pending'**
  String get syncStagePreviewSaved;

  /// No description provided for @deleteNothingHereTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing here can be deleted'**
  String get deleteNothingHereTitle;

  /// No description provided for @deleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1 shot from the camera?} other{Delete {count} shots from the camera?}}'**
  String deleteConfirmTitle(int count);

  /// No description provided for @deleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'{files, plural, =1{This removes 1 file from the SD card in the camera} other{This removes {files} files from the SD card in the camera}}{pairs} in {requests, plural, =1{1 request} other{{requests} requests}}.'**
  String deleteConfirmBody(int files, String pairs, int requests);

  /// No description provided for @deletePairsSuffix.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{ (1 RAW+JPEG shot, where both halves go together)} other{ ({count} RAW+JPEG shots, where both halves go together)}}'**
  String deletePairsSuffix(int count);

  /// No description provided for @deleteIrreversibleWarning.
  ///
  /// In en, this message translates to:
  /// **'It cannot be undone from this app: the photos are not copied anywhere first, the camera keeps no copy, and this protocol has no way to restore them. Sync anything you want to keep before deleting.'**
  String get deleteIrreversibleWarning;

  /// No description provided for @deleteWillNotBeTouched.
  ///
  /// In en, this message translates to:
  /// **'Will not be touched:'**
  String get deleteWillNotBeTouched;

  /// No description provided for @deleteKeepThem.
  ///
  /// In en, this message translates to:
  /// **'Keep them'**
  String get deleteKeepThem;

  /// No description provided for @deleteConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} from camera'**
  String deleteConfirmAction(int count);

  /// No description provided for @deleteProgress.
  ///
  /// In en, this message translates to:
  /// **'Deleting — request {index} of {total} ({label})'**
  String deleteProgress(int index, int total, String label);

  /// No description provided for @deleteNothingSent.
  ///
  /// In en, this message translates to:
  /// **'Nothing was sent to the camera.'**
  String get deleteNothingSent;

  /// No description provided for @deleteHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get deleteHide;

  /// No description provided for @deleteDetails.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get deleteDetails;

  /// No description provided for @deleteUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'{count} file(s) could not be confirmed either way — the camera accepted the request, but the card could not be listed again. Reload the album to see what is actually left.'**
  String deleteUnconfirmed(int count);

  /// No description provided for @deleteStillOnCard.
  ///
  /// In en, this message translates to:
  /// **'{count} file(s) are still on the card and were not deleted.'**
  String deleteStillOnCard(int count);

  /// No description provided for @viewerSaveToPhone.
  ///
  /// In en, this message translates to:
  /// **'Save this shot to the phone'**
  String get viewerSaveToPhone;

  /// No description provided for @viewerQueued.
  ///
  /// In en, this message translates to:
  /// **'Added to the sync queue. Start sync from the album bar.'**
  String get viewerQueued;

  /// No description provided for @viewerUndecodable.
  ///
  /// In en, this message translates to:
  /// **'This image could not be decoded.'**
  String get viewerUndecodable;

  /// No description provided for @viewerNotOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Not on this phone yet.'**
  String get viewerNotOnPhone;

  /// No description provided for @viewerFetchPreview.
  ///
  /// In en, this message translates to:
  /// **'Load a preview from the camera'**
  String get viewerFetchPreview;

  /// No description provided for @viewerCameraNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Camera not connected'**
  String get viewerCameraNotConnected;

  /// No description provided for @viewerLocalCopy.
  ///
  /// In en, this message translates to:
  /// **'Showing the copy saved on this phone.'**
  String get viewerLocalCopy;

  /// No description provided for @viewerLoadingFromCamera.
  ///
  /// In en, this message translates to:
  /// **'Loading from the camera — {size}'**
  String viewerLoadingFromCamera(String size);

  /// No description provided for @qualityOriginal.
  ///
  /// In en, this message translates to:
  /// **'Full resolution'**
  String get qualityOriginal;

  /// No description provided for @qualityPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview only'**
  String get qualityPreview;

  /// No description provided for @histogramNoData.
  ///
  /// In en, this message translates to:
  /// **'no exposure data yet'**
  String get histogramNoData;

  /// No description provided for @histogramUnavailable.
  ///
  /// In en, this message translates to:
  /// **'histogram unavailable'**
  String get histogramUnavailable;

  /// No description provided for @histogramTooltip.
  ///
  /// In en, this message translates to:
  /// **'Exposure histogram'**
  String get histogramTooltip;

  /// Numeric readout under the histogram. {blown} and {crushed} are empty strings when the clipped fractions are below the display threshold.
  ///
  /// In en, this message translates to:
  /// **'mean {mean}{blown}{crushed}'**
  String histogramStats(String mean, String blown, String crushed);

  /// No description provided for @histogramBlown.
  ///
  /// In en, this message translates to:
  /// **'  blown {percent}%'**
  String histogramBlown(String percent);

  /// No description provided for @histogramCrushed.
  ///
  /// In en, this message translates to:
  /// **'  crushed {percent}%'**
  String histogramCrushed(String percent);

  /// No description provided for @liveConnectionLost.
  ///
  /// In en, this message translates to:
  /// **'Camera connection lost'**
  String get liveConnectionLost;

  /// No description provided for @liveCheckAgain.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get liveCheckAgain;

  /// No description provided for @livePreviewPausedForTransfer.
  ///
  /// In en, this message translates to:
  /// **'Preview paused for the transfer'**
  String get livePreviewPausedForTransfer;

  /// No description provided for @liveFps.
  ///
  /// In en, this message translates to:
  /// **'{fps} fps'**
  String liveFps(String fps);

  /// No description provided for @liveHideThis.
  ///
  /// In en, this message translates to:
  /// **'Hide this'**
  String get liveHideThis;

  /// No description provided for @livePausedBannerBody.
  ///
  /// In en, this message translates to:
  /// **'Photos are being copied. The preview shares one Wi-Fi link with the transfer, so it is held still until the copy finishes.'**
  String get livePausedBannerBody;

  /// No description provided for @liveKeepPreviewRunning.
  ///
  /// In en, this message translates to:
  /// **'Keep the preview running'**
  String get liveKeepPreviewRunning;

  /// No description provided for @liveStopPreview.
  ///
  /// In en, this message translates to:
  /// **'Stop the preview'**
  String get liveStopPreview;

  /// No description provided for @liveNoFrames.
  ///
  /// In en, this message translates to:
  /// **'no frames'**
  String get liveNoFrames;

  /// Frame rate actually drawn out of the frames the camera sent. Replaces the average, which never falls to zero and therefore cannot show that the stream stopped.
  ///
  /// In en, this message translates to:
  /// **'{drawn}/{received} fps'**
  String liveDrawnOfReceivedFps(String drawn, String received);

  /// No description provided for @liveLossPercent.
  ///
  /// In en, this message translates to:
  /// **'{percent}% loss'**
  String liveLossPercent(String percent);

  /// No description provided for @liveCompositionGrid.
  ///
  /// In en, this message translates to:
  /// **'Composition grid'**
  String get liveCompositionGrid;

  /// No description provided for @liveFocusAtCentre.
  ///
  /// In en, this message translates to:
  /// **'Focus at the centre'**
  String get liveFocusAtCentre;

  /// No description provided for @liveStartPreview.
  ///
  /// In en, this message translates to:
  /// **'Start preview'**
  String get liveStartPreview;

  /// No description provided for @liveStopPreviewTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop preview'**
  String get liveStopPreviewTooltip;

  /// No description provided for @liveFullScreen.
  ///
  /// In en, this message translates to:
  /// **'Full screen'**
  String get liveFullScreen;

  /// No description provided for @liveExitFullScreen.
  ///
  /// In en, this message translates to:
  /// **'Exit full screen'**
  String get liveExitFullScreen;

  /// No description provided for @liveShutterReady.
  ///
  /// In en, this message translates to:
  /// **'The shutter is ready again.'**
  String get liveShutterReady;

  /// No description provided for @liveStillBlocked.
  ///
  /// In en, this message translates to:
  /// **'Still blocked: {reason}'**
  String liveStillBlocked(String reason);

  /// No description provided for @liveReleaseAnyway.
  ///
  /// In en, this message translates to:
  /// **'Release anyway'**
  String get liveReleaseAnyway;

  /// No description provided for @liveFixShutter.
  ///
  /// In en, this message translates to:
  /// **'Fix the shutter'**
  String get liveFixShutter;

  /// No description provided for @liveStartPreviewForSettings.
  ///
  /// In en, this message translates to:
  /// **'Start the preview to read the camera settings.'**
  String get liveStartPreviewForSettings;

  /// No description provided for @liveCameraSettings.
  ///
  /// In en, this message translates to:
  /// **'Camera settings'**
  String get liveCameraSettings;

  /// No description provided for @liveHideSettings.
  ///
  /// In en, this message translates to:
  /// **'Hide settings'**
  String get liveHideSettings;

  /// No description provided for @liveSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get liveSettings;

  /// No description provided for @liveVideoTab.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get liveVideoTab;

  /// No description provided for @liveAlbumTab.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get liveAlbumTab;

  /// No description provided for @liveEvReference.
  ///
  /// In en, this message translates to:
  /// **'· reference'**
  String get liveEvReference;

  /// No description provided for @liveRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get liveRetry;

  /// No description provided for @liveConnectToCamera.
  ///
  /// In en, this message translates to:
  /// **'Connect to camera'**
  String get liveConnectToCamera;

  /// No description provided for @joinOutcomeGranted.
  ///
  /// In en, this message translates to:
  /// **'Joined. Looking for the camera...'**
  String get joinOutcomeGranted;

  /// The platform registered the network as a suggestion instead of joining; the passkey is already filled in, so the only missing step is the user allowing it.
  ///
  /// In en, this message translates to:
  /// **'Android saved the network. Allow the notification, or pick it in Wi-Fi.'**
  String get joinOutcomeSaved;

  /// No description provided for @joinOutcomeDismissed.
  ///
  /// In en, this message translates to:
  /// **'Join prompt dismissed.'**
  String get joinOutcomeDismissed;

  /// No description provided for @joinOutcomeTimeout.
  ///
  /// In en, this message translates to:
  /// **'Android timed out joining.'**
  String get joinOutcomeTimeout;

  /// The snackbar action that opens the system permission screen, shown after a join the user can fix.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get liveRetryJoinLabel;

  /// No description provided for @liveConnectRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get liveConnectRetry;

  /// No description provided for @liveBleDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'BLE diagnostics'**
  String get liveBleDiagnostics;

  /// No description provided for @liveWifiDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi diagnostics'**
  String get liveWifiDiagnostics;

  /// No description provided for @liveOpenWifi.
  ///
  /// In en, this message translates to:
  /// **'Open Wi-Fi'**
  String get liveOpenWifi;

  /// No description provided for @liveRetryJoin.
  ///
  /// In en, this message translates to:
  /// **'Retry join'**
  String get liveRetryJoin;

  /// No description provided for @liveAppPermissions.
  ///
  /// In en, this message translates to:
  /// **'App permissions'**
  String get liveAppPermissions;

  /// No description provided for @liveReRead.
  ///
  /// In en, this message translates to:
  /// **'Re-read'**
  String get liveReRead;

  /// No description provided for @liveNothingLoggedYet.
  ///
  /// In en, this message translates to:
  /// **'(nothing logged yet)'**
  String get liveNothingLoggedYet;

  /// No description provided for @liveBleDiagnosticsBody.
  ///
  /// In en, this message translates to:
  /// **'The camera advertises these properties itself. A write failure here is usually a write-type or permission mismatch, not a protocol error.'**
  String get liveBleDiagnosticsBody;

  /// No description provided for @liveWifiDiagnosticsBody.
  ///
  /// In en, this message translates to:
  /// **'The camera shows no passkey of its own, so this is where to read it. Nothing here is guessed: each line was measured on this phone just now.'**
  String get liveWifiDiagnosticsBody;

  /// No description provided for @liveCameraAccessPoint.
  ///
  /// In en, this message translates to:
  /// **'Camera access point'**
  String get liveCameraAccessPoint;

  /// No description provided for @liveAccessPointUnknown.
  ///
  /// In en, this message translates to:
  /// **'Not known yet — the credentials arrive over Bluetooth when the camera switches its Wi-Fi on.'**
  String get liveAccessPointUnknown;

  /// No description provided for @liveSsid.
  ///
  /// In en, this message translates to:
  /// **'SSID'**
  String get liveSsid;

  /// No description provided for @livePasskey.
  ///
  /// In en, this message translates to:
  /// **'Passkey'**
  String get livePasskey;

  /// No description provided for @liveNotReadYet.
  ///
  /// In en, this message translates to:
  /// **'(not read yet)'**
  String get liveNotReadYet;

  /// No description provided for @liveOpenedWifiPanel.
  ///
  /// In en, this message translates to:
  /// **'Opened the Wi-Fi panel. Pick the camera network there.'**
  String get liveOpenedWifiPanel;

  /// No description provided for @liveOpenedWifiSettings.
  ///
  /// In en, this message translates to:
  /// **'Opened Wi-Fi settings. Pick the camera network there.'**
  String get liveOpenedWifiSettings;

  /// No description provided for @liveMeasuredState.
  ///
  /// In en, this message translates to:
  /// **'Measured state'**
  String get liveMeasuredState;

  /// No description provided for @liveAndroidOnly.
  ///
  /// In en, this message translates to:
  /// **'Android only — nothing to report on this platform.'**
  String get liveAndroidOnly;

  /// No description provided for @liveLocationServicesOffNote.
  ///
  /// In en, this message translates to:
  /// **'Location services are switched OFF while the permission is granted. Android reports this as a missing permission, but the fix is the location tile in quick settings — granting the permission again will not help.'**
  String get liveLocationServicesOffNote;

  /// No description provided for @diagAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android'**
  String get diagAndroid;

  /// No description provided for @diagTargetSdk.
  ///
  /// In en, this message translates to:
  /// **'Target SDK'**
  String get diagTargetSdk;

  /// No description provided for @diagDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get diagDevice;

  /// No description provided for @diagLocationPermission.
  ///
  /// In en, this message translates to:
  /// **'Location permission'**
  String get diagLocationPermission;

  /// No description provided for @diagNearbyWifiPermission.
  ///
  /// In en, this message translates to:
  /// **'Nearby-Wi-Fi permission'**
  String get diagNearbyWifiPermission;

  /// No description provided for @diagChangeWifiPermission.
  ///
  /// In en, this message translates to:
  /// **'Change-Wi-Fi permission'**
  String get diagChangeWifiPermission;

  /// No description provided for @diagChangeNetworkPermission.
  ///
  /// In en, this message translates to:
  /// **'Change-network permission'**
  String get diagChangeNetworkPermission;

  /// No description provided for @diagLocationServices.
  ///
  /// In en, this message translates to:
  /// **'Location services'**
  String get diagLocationServices;

  /// No description provided for @diagWifiRadio.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi radio'**
  String get diagWifiRadio;

  /// No description provided for @diagNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get diagNotifications;

  /// No description provided for @diagAddNetworkSheet.
  ///
  /// In en, this message translates to:
  /// **'“Add network” sheet'**
  String get diagAddNetworkSheet;

  /// No description provided for @diagGranted.
  ///
  /// In en, this message translates to:
  /// **'granted'**
  String get diagGranted;

  /// No description provided for @diagNotGranted.
  ///
  /// In en, this message translates to:
  /// **'NOT granted'**
  String get diagNotGranted;

  /// No description provided for @diagUnknown.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get diagUnknown;

  /// No description provided for @diagUnknownValue.
  ///
  /// In en, this message translates to:
  /// **'?'**
  String get diagUnknownValue;

  /// No description provided for @readoutMode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get readoutMode;

  /// No description provided for @readoutShutter.
  ///
  /// In en, this message translates to:
  /// **'Shutter'**
  String get readoutShutter;

  /// No description provided for @readoutAperture.
  ///
  /// In en, this message translates to:
  /// **'Aperture'**
  String get readoutAperture;

  /// No description provided for @readoutIso.
  ///
  /// In en, this message translates to:
  /// **'ISO'**
  String get readoutIso;

  /// No description provided for @readoutIsoAuto.
  ///
  /// In en, this message translates to:
  /// **'ISO auto'**
  String get readoutIsoAuto;

  /// No description provided for @readoutEv.
  ///
  /// In en, this message translates to:
  /// **'EV'**
  String get readoutEv;

  /// No description provided for @readoutWb.
  ///
  /// In en, this message translates to:
  /// **'WB'**
  String get readoutWb;

  /// No description provided for @readoutStyle.
  ///
  /// In en, this message translates to:
  /// **'Style'**
  String get readoutStyle;

  /// No description provided for @readoutBattery.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get readoutBattery;

  /// The battery row's value while the camera is on external power. The camera reports charging as the reading 101 instead of a percentage, so this word replaces the number: the row used to draw '101%', which cannot exist. What is measured, and what the manufacturer's own code states, is in CameraState.isCharging.
  ///
  /// In en, this message translates to:
  /// **'Charging'**
  String get readoutBatteryCharging;

  /// The same fact in the narrow (78 dp) readout column, where a value gets 66 dp of text room. 'Charging' is 8 characters, which this app's metrics draw at 96.0 dp — 0.688 of the 66 dp, below the 0.75 floor analysis/55 set for this column. The short form is the one the column's own budget (kCompactReadoutLength = 7) allows.
  ///
  /// In en, this message translates to:
  /// **'Chg'**
  String get readoutBatteryChargingCompact;

  /// No description provided for @readoutLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get readoutLeft;

  /// No description provided for @readoutApertureValue.
  ///
  /// In en, this message translates to:
  /// **'f/{value}'**
  String readoutApertureValue(String value);

  /// No description provided for @readoutIsoAutoValue.
  ///
  /// In en, this message translates to:
  /// **'ISO {value} (auto)'**
  String readoutIsoAutoValue(String value);

  /// No description provided for @readoutIsoValue.
  ///
  /// In en, this message translates to:
  /// **'ISO {value}'**
  String readoutIsoValue(String value);

  /// No description provided for @readoutEvValue.
  ///
  /// In en, this message translates to:
  /// **'{value} EV'**
  String readoutEvValue(String value);

  /// No description provided for @readoutBatteryAndLeft.
  ///
  /// In en, this message translates to:
  /// **'{battery}%  {left}'**
  String readoutBatteryAndLeft(String battery, String left);

  /// The compact strip's battery half while the camera is on external power: the same word as readoutBatteryCharging, with the remaining-shot count. There is no number to show because there is no percentage.
  ///
  /// In en, this message translates to:
  /// **'Charging  {left}'**
  String readoutBatteryChargingAndLeft(String left);

  /// No description provided for @settingsSetByCamera.
  ///
  /// In en, this message translates to:
  /// **'Set by the camera in {mode} mode — switch to M to control it'**
  String settingsSetByCamera(String mode);

  /// No description provided for @dialAperture.
  ///
  /// In en, this message translates to:
  /// **'Aperture'**
  String get dialAperture;

  /// No description provided for @dialShutter.
  ///
  /// In en, this message translates to:
  /// **'Shutter'**
  String get dialShutter;

  /// No description provided for @dialIso.
  ///
  /// In en, this message translates to:
  /// **'ISO'**
  String get dialIso;

  /// No description provided for @dialEv.
  ///
  /// In en, this message translates to:
  /// **'EV'**
  String get dialEv;

  /// No description provided for @dialMode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get dialMode;

  /// No description provided for @dialDecrease.
  ///
  /// In en, this message translates to:
  /// **'Lower {label}'**
  String dialDecrease(String label);

  /// No description provided for @dialIncrease.
  ///
  /// In en, this message translates to:
  /// **'Raise {label}'**
  String dialIncrease(String label);

  /// Shown on a dial the camera will not accept changes for right now — the value is displayed as a reference rather than as a control. The Chinese is the maintainer's own word (不可调).
  ///
  /// In en, this message translates to:
  /// **'not adjustable'**
  String get dialDisabledByMode;

  /// Badge on a RAW+JPEG pair in the album grid. One row, not two: the pair is one shot.
  ///
  /// In en, this message translates to:
  /// **'RAW+JPG'**
  String get albumRawJpgBadge;

  /// No description provided for @albumRawBadge.
  ///
  /// In en, this message translates to:
  /// **'RAW'**
  String get albumRawBadge;

  /// Second badge on an album tile whose shot owns a RAW that is not on the phone yet AND is still being fetched — either because the RAW switch is on, or because the RAW is already in the sync list. The tile above it says RAW+JPG, which is the fact that the shot owns a RAW at all; this one answers 'and is it here yet'. Only drawn while the answer is 'no, but it is coming': with the switch off a RAW will never arrive, and a badge that claimed it was pending would sit on every pair tile forever.
  ///
  /// In en, this message translates to:
  /// **'RAW pending'**
  String get albumRawPending;

  /// Badge on a video clip in the album grid. Chinese keeps the Latin word: it is what Chinese camera menus print, and a 10 dp badge has no room for 视频.
  ///
  /// In en, this message translates to:
  /// **'VIDEO'**
  String get albumVideoBadge;

  /// No description provided for @firstRunStepWhatItDoes.
  ///
  /// In en, this message translates to:
  /// **'What this app does'**
  String get firstRunStepWhatItDoes;

  /// No description provided for @firstRunStepHowPhotosCome.
  ///
  /// In en, this message translates to:
  /// **'How photos should come across'**
  String get firstRunStepHowPhotosCome;

  /// No description provided for @firstRunStepPair.
  ///
  /// In en, this message translates to:
  /// **'Pair with the camera'**
  String get firstRunStepPair;

  /// No description provided for @firstRunStepOf.
  ///
  /// In en, this message translates to:
  /// **'Step {step} of {total}'**
  String firstRunStepOf(int step, int total);

  /// No description provided for @firstRunTitle.
  ///
  /// In en, this message translates to:
  /// **'First run & pairing'**
  String get firstRunTitle;

  /// No description provided for @firstRunSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get firstRunSkip;

  /// No description provided for @firstRunClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get firstRunClose;

  /// No description provided for @firstRunBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get firstRunBack;

  /// No description provided for @firstRunNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get firstRunNext;

  /// No description provided for @firstRunStartPairing.
  ///
  /// In en, this message translates to:
  /// **'Start pairing'**
  String get firstRunStartPairing;

  /// The pairing button after an attempt has failed: the same control, in the same place, relabelled. Every attempt needs a person standing at the camera, so the retry is manual, and this label is what tells the user the button is live again.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get firstRunPairTryAgain;

  /// Drawn under the app's own failure sentence in the pairing step's status card. It names the control to press, which the failure sentence cannot do on its own.
  ///
  /// In en, this message translates to:
  /// **'That attempt is over — nothing is still waiting on the camera. Press Try again with the camera awake and in front of you, then press Accept on its screen within a few seconds.'**
  String get firstRunPairFailedHelp;

  /// No description provided for @firstRunDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get firstRunDone;

  /// No description provided for @firstRunIntro.
  ///
  /// In en, this message translates to:
  /// **'It controls your YI M1 over Wi-Fi: a live viewfinder, the shutter, the settings the camera exposes, and a copy of the card in your phone\'s gallery. Nothing is sent to any server — the phone talks to the camera, and the photos land on the phone.'**
  String get firstRunIntro;

  /// No description provided for @firstRunWifiOneDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'The camera\'s Wi-Fi takes one device at a time'**
  String get firstRunWifiOneDeviceTitle;

  /// No description provided for @firstRunWifiOneDeviceDetail.
  ///
  /// In en, this message translates to:
  /// **'If a PC or tablet is connected to the camera, this phone cannot be. Disconnect the other device first — otherwise the join fails in a way that reads like a wrong password.'**
  String get firstRunWifiOneDeviceDetail;

  /// No description provided for @firstRunAcceptOnCameraTitle.
  ///
  /// In en, this message translates to:
  /// **'Pairing needs a press on the camera body'**
  String get firstRunAcceptOnCameraTitle;

  /// No description provided for @firstRunAcceptOnCameraDetail.
  ///
  /// In en, this message translates to:
  /// **'When you start pairing, the camera asks you to confirm. You have a few seconds to press Accept on its screen. A PC that has already paired can take that turn, so pair from the device you actually want to use.'**
  String get firstRunAcceptOnCameraDetail;

  /// No description provided for @firstRunSyncIntro.
  ///
  /// In en, this message translates to:
  /// **'Asked once, and remembered. You can change it later on the Sync screen, or by reopening this guide from the ? button in the top bar.'**
  String get firstRunSyncIntro;

  /// No description provided for @firstRunSyncFoot.
  ///
  /// In en, this message translates to:
  /// **'Previews are small and appear in seconds; a full-size photo is several megabytes over a slow radio. This only decides what happens automatically — you can always pick individual photos in the album.'**
  String get firstRunSyncFoot;

  /// No description provided for @firstRunSyncAutoPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatic — a small preview first, then the full size'**
  String get firstRunSyncAutoPreviewTitle;

  /// No description provided for @firstRunSyncAutoPreviewBody.
  ///
  /// In en, this message translates to:
  /// **'A preview is small and appears in seconds, so the whole card is browsable quickly; the full-size file follows behind it.'**
  String get firstRunSyncAutoPreviewBody;

  /// No description provided for @firstRunSyncAutoOriginalTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatic — full size only'**
  String get firstRunSyncAutoOriginalTitle;

  /// No description provided for @firstRunSyncAutoOriginalBody.
  ///
  /// In en, this message translates to:
  /// **'Nothing lands on the phone that is not the real file, but each photo is several megabytes over a slow radio, so the first one takes a while.'**
  String get firstRunSyncAutoOriginalBody;

  /// No description provided for @firstRunSyncManualTitle.
  ///
  /// In en, this message translates to:
  /// **'Manual — only what I pick'**
  String get firstRunSyncManualTitle;

  /// No description provided for @firstRunSyncManualBody.
  ///
  /// In en, this message translates to:
  /// **'Nothing moves until you choose it. Browsing the card queues nothing, which is the safe choice on a metered or slow link.'**
  String get firstRunSyncManualBody;

  /// No description provided for @firstRunKeepAwake.
  ///
  /// In en, this message translates to:
  /// **'Keep the camera awake and powered on. If nothing happens for ten seconds, the camera did not get the confirmation and the attempt has to be made again.'**
  String get firstRunKeepAwake;

  /// The portrait variant of firstRunKeepAwake. The extra clause is load-bearing there: that layout puts the button under the sentence, so "after you ask to pair" is what says when the ten seconds start.
  ///
  /// In en, this message translates to:
  /// **'Keep the camera awake and powered on. If nothing happens for ten seconds after you ask to pair, the camera did not get the confirmation and the attempt has to be made again.'**
  String get firstRunKeepAwakeAfterAsk;

  /// No description provided for @firstRunFourThings.
  ///
  /// In en, this message translates to:
  /// **'Four things happen, in this order:'**
  String get firstRunFourThings;

  /// No description provided for @firstRunPairFind.
  ///
  /// In en, this message translates to:
  /// **'Find the camera over Bluetooth'**
  String get firstRunPairFind;

  /// No description provided for @firstRunPairConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm the pairing on the camera body'**
  String get firstRunPairConfirm;

  /// No description provided for @firstRunPairAccept.
  ///
  /// In en, this message translates to:
  /// **'Press Accept on the camera — it belongs to the camera, not to the app'**
  String get firstRunPairAccept;

  /// No description provided for @firstRunPairReadCredentials.
  ///
  /// In en, this message translates to:
  /// **'Read the camera\'s Wi-Fi name and password'**
  String get firstRunPairReadCredentials;

  /// No description provided for @firstRunPairJoin.
  ///
  /// In en, this message translates to:
  /// **'Join that network and check the camera answers'**
  String get firstRunPairJoin;

  /// No description provided for @firstRunNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected. Pressing Start pairing asks the camera to confirm — have the camera switched on and in front of you.'**
  String get firstRunNotConnected;

  /// No description provided for @firstRunConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected. The Camera tab now has the live view, the shutter and the settings.'**
  String get firstRunConnected;

  /// No description provided for @videoNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected to the camera.'**
  String get videoNotConnected;

  /// No description provided for @videoStartPreviewFirst.
  ///
  /// In en, this message translates to:
  /// **'Start the preview first — the camera only accepts remote commands while remote mode is active.'**
  String get videoStartPreviewFirst;

  /// No description provided for @videoRefusedNotRemote.
  ///
  /// In en, this message translates to:
  /// **'{label} was refused because the camera is not in remote mode. Start the preview and try again.'**
  String videoRefusedNotRemote(String label);

  /// No description provided for @videoFailed.
  ///
  /// In en, this message translates to:
  /// **'{label} failed: {detail}'**
  String videoFailed(String label, String detail);

  /// No description provided for @videoRejected404.
  ///
  /// In en, this message translates to:
  /// **'{label} was rejected: the camera answered 404, which on this firmware means the command or its value is not accepted by this body.'**
  String videoRejected404(String label);

  /// No description provided for @videoStartRecording.
  ///
  /// In en, this message translates to:
  /// **'Start recording'**
  String get videoStartRecording;

  /// No description provided for @videoStopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get videoStopRecording;

  /// No description provided for @videoChangeFormat.
  ///
  /// In en, this message translates to:
  /// **'Change format'**
  String get videoChangeFormat;

  /// No description provided for @videoCautionTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote video is partly unverified'**
  String get videoCautionTitle;

  /// No description provided for @videoCautionBody.
  ///
  /// In en, this message translates to:
  /// **'Recording start/stop and the format command have been sent to a real camera and accepted. Nothing has confirmed yet that the clip reaches the SD card, so check the card before relying on it.\n\nThe stabilisation, noise reduction and audio controls have NOT been verified on hardware at all: they were read out of the firmware\'s command table, and a value that table lists can still be refused by this body.\n\nThis camera has no watchdog, so a command it does not expect can leave it unresponsive until the battery is removed. If it stops answering, power-cycle it.'**
  String get videoCautionBody;

  /// No description provided for @videoNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get videoNotNow;

  /// No description provided for @videoUnderstandContinue.
  ///
  /// In en, this message translates to:
  /// **'I understand — continue'**
  String get videoUnderstandContinue;

  /// No description provided for @videoPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Video recording'**
  String get videoPageTitle;

  /// No description provided for @videoWhatIsVerified.
  ///
  /// In en, this message translates to:
  /// **'What is verified?'**
  String get videoWhatIsVerified;

  /// No description provided for @videoRecordingFormat.
  ///
  /// In en, this message translates to:
  /// **'Recording format'**
  String get videoRecordingFormat;

  /// No description provided for @videoFormatBlockedNote.
  ///
  /// In en, this message translates to:
  /// **'Blocked while recording: the camera encodes the format it started with.'**
  String get videoFormatBlockedNote;

  /// No description provided for @videoUnavailableUntilPreview.
  ///
  /// In en, this message translates to:
  /// **'Unavailable until the preview is running.'**
  String get videoUnavailableUntilPreview;

  /// No description provided for @videoStopRecordingFirst.
  ///
  /// In en, this message translates to:
  /// **'Stop the recording before changing the format.'**
  String get videoStopRecordingFirst;

  /// No description provided for @videoVideoQuality.
  ///
  /// In en, this message translates to:
  /// **'Video quality'**
  String get videoVideoQuality;

  /// No description provided for @videoElectronicStabilisation.
  ///
  /// In en, this message translates to:
  /// **'Electronic stabilisation'**
  String get videoElectronicStabilisation;

  /// No description provided for @videoNoiseReduction.
  ///
  /// In en, this message translates to:
  /// **'Noise reduction'**
  String get videoNoiseReduction;

  /// No description provided for @videoAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get videoAudio;

  /// No description provided for @videoRecordAudio.
  ///
  /// In en, this message translates to:
  /// **'Record audio'**
  String get videoRecordAudio;

  /// No description provided for @videoNoStateYet.
  ///
  /// In en, this message translates to:
  /// **'No camera state yet. These values are read from the preview stream, so they appear with the first frame.'**
  String get videoNoStateYet;

  /// No description provided for @videoReportedByCamera.
  ///
  /// In en, this message translates to:
  /// **'Reported by the camera'**
  String get videoReportedByCamera;

  /// No description provided for @videoRowFormat.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get videoRowFormat;

  /// No description provided for @videoRowAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get videoRowAudio;

  /// No description provided for @videoRowVolume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get videoRowVolume;

  /// No description provided for @videoRowNoiseReduction.
  ///
  /// In en, this message translates to:
  /// **'Noise reduction'**
  String get videoRowNoiseReduction;

  /// No description provided for @videoRowStabilisation.
  ///
  /// In en, this message translates to:
  /// **'Stabilisation'**
  String get videoRowStabilisation;

  /// No description provided for @videoRequestedNotReported.
  ///
  /// In en, this message translates to:
  /// **'Asked for {format}. The camera has not reported it yet — the stream is the only acknowledgement that counts on this firmware, so this is not a change until it appears above.'**
  String videoRequestedNotReported(String format);

  /// No description provided for @videoRecordingIndicator.
  ///
  /// In en, this message translates to:
  /// **'RECORDING'**
  String get videoRecordingIndicator;

  /// No description provided for @videoIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get videoIdle;

  /// No description provided for @videoTimerNote.
  ///
  /// In en, this message translates to:
  /// **'Recording state and the timer are tracked by the app: the camera reports the video settings in every frame but says nothing about whether it is recording.'**
  String get videoTimerNote;

  /// No description provided for @videoUnknown.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get videoUnknown;

  /// No description provided for @videoUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'unconfirmed'**
  String get videoUnconfirmed;

  /// No description provided for @videoRequestedWaiting.
  ///
  /// In en, this message translates to:
  /// **'{format} requested — waiting for the camera.'**
  String videoRequestedWaiting(String format);

  /// No description provided for @videoFormatPoolNote.
  ///
  /// In en, this message translates to:
  /// **'The list is the firmware\'s own value pool, which is shared across bodies: a format can exist in firmware and still be refused by this one. A refusal comes back as a 404 and is reported here.'**
  String get videoFormatPoolNote;

  /// No description provided for @videoStateNotReported.
  ///
  /// In en, this message translates to:
  /// **'state not reported yet'**
  String get videoStateNotReported;

  /// No description provided for @videoSending.
  ///
  /// In en, this message translates to:
  /// **'sending {command}...'**
  String videoSending(String command);

  /// No description provided for @videoVolume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get videoVolume;

  /// No description provided for @videoNoVolumeYet.
  ///
  /// In en, this message translates to:
  /// **'The camera reports no volume yet.'**
  String get videoNoVolumeYet;

  /// No description provided for @videoCameraReports.
  ///
  /// In en, this message translates to:
  /// **'Camera reports {value}.'**
  String videoCameraReports(String value);

  /// No description provided for @videoChangeInFlight.
  ///
  /// In en, this message translates to:
  /// **' A change is in flight.'**
  String get videoChangeInFlight;

  /// No description provided for @videoCautionFoot.
  ///
  /// In en, this message translates to:
  /// **'These commands have not all been verified on real hardware. The camera has no watchdog, so if it stops responding, power-cycle it.'**
  String get videoCautionFoot;

  /// No description provided for @videoOn.
  ///
  /// In en, this message translates to:
  /// **'ON'**
  String get videoOn;

  /// No description provided for @videoOff.
  ///
  /// In en, this message translates to:
  /// **'OFF'**
  String get videoOff;

  /// No description provided for @linkScanning.
  ///
  /// In en, this message translates to:
  /// **'looking for the camera...'**
  String get linkScanning;

  /// No description provided for @linkNotFound.
  ///
  /// In en, this message translates to:
  /// **'camera not found. Is it powered on, and not already held by the official app?'**
  String get linkNotFound;

  /// No description provided for @linkConnecting.
  ///
  /// In en, this message translates to:
  /// **'connecting...'**
  String get linkConnecting;

  /// No description provided for @linkReadingIdentity.
  ///
  /// In en, this message translates to:
  /// **'reading camera identity...'**
  String get linkReadingIdentity;

  /// No description provided for @linkUnreadableIdentity.
  ///
  /// In en, this message translates to:
  /// **'camera answered with an unreadable identity'**
  String get linkUnreadableIdentity;

  /// No description provided for @linkFound.
  ///
  /// In en, this message translates to:
  /// **'found {firmware} ({region})'**
  String linkFound(String firmware, String region);

  /// No description provided for @linkReusingPairing.
  ///
  /// In en, this message translates to:
  /// **'reusing the saved pairing (refId {refId})...'**
  String linkReusingPairing(String refId);

  /// No description provided for @linkSavedPairingRejected.
  ///
  /// In en, this message translates to:
  /// **'saved pairing did not take ({detail}); pairing fresh'**
  String linkSavedPairingRejected(String detail);

  /// No description provided for @linkPressAllow.
  ///
  /// In en, this message translates to:
  /// **'PRESS ALLOW ON THE CAMERA now (refId {refId})'**
  String linkPressAllow(String refId);

  /// No description provided for @linkPairingNotConfirmed.
  ///
  /// In en, this message translates to:
  /// **'the camera did not confirm the pairing. It must be accepted on the camera screen within a few seconds.'**
  String get linkPairingNotConfirmed;

  /// No description provided for @linkOpeningSession.
  ///
  /// In en, this message translates to:
  /// **'opening the session...'**
  String get linkOpeningSession;

  /// No description provided for @linkEnablingWifi.
  ///
  /// In en, this message translates to:
  /// **'switching the camera Wi-Fi on...'**
  String get linkEnablingWifi;

  /// No description provided for @linkReadingCredentials.
  ///
  /// In en, this message translates to:
  /// **'reading Wi-Fi credentials...'**
  String get linkReadingCredentials;

  /// No description provided for @linkPairingForgotten.
  ///
  /// In en, this message translates to:
  /// **'the camera refused the saved pairing, so it has been forgotten; press Connect again to pair from scratch (the camera will ask for confirmation).'**
  String get linkPairingForgotten;

  /// No description provided for @linkNoCredentials.
  ///
  /// In en, this message translates to:
  /// **'the camera did not hand over Wi-Fi credentials. The session may not have been accepted.'**
  String get linkNoCredentials;

  /// No description provided for @linkAskingAndroidToJoin.
  ///
  /// In en, this message translates to:
  /// **'asking Android to join \"{ssid}\"...'**
  String linkAskingAndroidToJoin(String ssid);

  /// No description provided for @linkJoined.
  ///
  /// In en, this message translates to:
  /// **'joined \"{ssid}\" — waiting for the camera to answer...'**
  String linkJoined(String ssid);

  /// The same moment as linkJoined, but the process could not be pinned to the camera's network, so the app cannot yet promise the camera will answer. The distinction is real: without the pin, requests leave over cellular.
  ///
  /// In en, this message translates to:
  /// **'joined \"{ssid}\" — waiting for the camera...'**
  String linkJoinedUnbound(String ssid);

  /// No description provided for @linkSavedNetworkInstead.
  ///
  /// In en, this message translates to:
  /// **'Android saved \"{ssid}\" as a network instead of joining it. If a notification appears, allow it — otherwise open Wi-Fi and pick it. The passkey is already filled in ({credential}). Waiting...'**
  String linkSavedNetworkInstead(String ssid, String credential);

  /// No description provided for @linkJoinDismissed.
  ///
  /// In en, this message translates to:
  /// **'the join prompt was dismissed. Tap \"Retry join\" to bring it back, or connect to \"{ssid}\" yourself with the passkey {credential}.'**
  String linkJoinDismissed(String ssid, String credential);

  /// No description provided for @linkJoinTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Android did not finish joining \"{ssid}\" in time.'**
  String linkJoinTimedOut(String ssid);

  /// No description provided for @linkJoinUnsupported.
  ///
  /// In en, this message translates to:
  /// **'this phone will not let the app join \"{ssid}\" by itself, so the Wi-Fi screen was opened. Choose \"{ssid}\" there — the passkey is {credential} (the camera does not show it).'**
  String linkJoinUnsupported(String ssid, String credential);

  /// {detail} is the platform's own explanation and {permissions} is the measured permission summary — an identifier list, not prose. Both are inserted verbatim in every language.
  ///
  /// In en, this message translates to:
  /// **'{detail} You can also connect to \"{ssid}\" by hand with the passkey {credential}. [{permissions}]'**
  String linkJoinManual(
      String detail, String ssid, String credential, String permissions);

  /// No description provided for @linkWaitingForCamera.
  ///
  /// In en, this message translates to:
  /// **'waiting for the camera to answer ({seconds}s left)...'**
  String linkWaitingForCamera(int seconds);

  /// No description provided for @linkCameraNotAnswering.
  ///
  /// In en, this message translates to:
  /// **'the camera is not answering on {host}. Check that the phone is on \"{ssid}\" — its passkey is {passkey} — then retry.'**
  String linkCameraNotAnswering(String host, String ssid, String passkey);

  /// No description provided for @linkConnected.
  ///
  /// In en, this message translates to:
  /// **'connected'**
  String get linkConnected;

  /// No description provided for @linkPreviewRunning.
  ///
  /// In en, this message translates to:
  /// **'preview running'**
  String get linkPreviewRunning;

  /// No description provided for @linkPreviewStopped.
  ///
  /// In en, this message translates to:
  /// **'preview stopped'**
  String get linkPreviewStopped;

  /// No description provided for @linkDisconnected.
  ///
  /// In en, this message translates to:
  /// **'disconnected'**
  String get linkDisconnected;

  /// Shown after the Disconnect button when the camera's access point could not be switched off over Bluetooth. This one is the gate: the camera keeps exactly ONE pairing, and a newer client (the official app, another phone) silently replaces it, so there is no authenticated BLE channel left to send the switch-off through. The sentence must stay a *disclosure* — the radio really is still on, which costs the camera battery and occupies the single client slot its access point admits. It must not promise that the app can fix it.
  ///
  /// In en, this message translates to:
  /// **'Disconnected, but the camera\'s Wi-Fi is still on — the camera no longer holds this phone\'s pairing, so the app has no authenticated channel to switch it with. Press the camera\'s power switch, or reconnect and disconnect again, to stop it advertising.'**
  String get linkDisconnectedNoPairing;

  /// Same place as linkDisconnectedNoPairing. Here a pairing existed and the command was sent, but the camera did not take it. A BLE write is fire-and-forget on this hardware, so 'no acknowledgement' is the strongest thing the app can honestly say — do not translate it as a confirmed failure.
  ///
  /// In en, this message translates to:
  /// **'Disconnected, but the camera\'s Wi-Fi is still on — the camera did not acknowledge the switch-off command. Press the camera\'s power switch, or reconnect and disconnect again, to stop it advertising.'**
  String get linkDisconnectedRadioRefused;

  /// Same place as linkDisconnectedNoPairing. The normal case while the camera's network stack is wedged: HTTP is dead but Bluetooth still works, so reconnecting is what actually switches the radio off.
  ///
  /// In en, this message translates to:
  /// **'Disconnected, but the camera\'s Wi-Fi is still on — the Bluetooth link to the camera was already gone, so the switch-off command had no way to reach it. Press the camera\'s power switch, or reconnect and disconnect again, to stop it advertising.'**
  String get linkDisconnectedNoBle;

  /// No description provided for @linkIdle.
  ///
  /// In en, this message translates to:
  /// **'not connected'**
  String get linkIdle;

  /// No description provided for @linkLostContact.
  ///
  /// In en, this message translates to:
  /// **'Lost contact with the camera. It may have been switched off, or the phone may have left the camera\'s Wi-Fi network.'**
  String get linkLostContact;

  /// No description provided for @stageQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get stageQueued;

  /// No description provided for @stagePreview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get stagePreview;

  /// No description provided for @stageDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get stageDownloading;

  /// No description provided for @stageStalled.
  ///
  /// In en, this message translates to:
  /// **'Stalled, retrying'**
  String get stageStalled;

  /// No description provided for @stagePausedNoCamera.
  ///
  /// In en, this message translates to:
  /// **'Paused, camera away'**
  String get stagePausedNoCamera;

  /// No description provided for @stagePausedByUser.
  ///
  /// In en, this message translates to:
  /// **'Paused by you'**
  String get stagePausedByUser;

  /// No description provided for @stagePausedLowBattery.
  ///
  /// In en, this message translates to:
  /// **'Paused, camera battery low'**
  String get stagePausedLowBattery;

  /// No description provided for @stageDone.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get stageDone;

  /// No description provided for @syncNoteCameraAway.
  ///
  /// In en, this message translates to:
  /// **'The camera went away. Sync resumes when it is back.'**
  String get syncNoteCameraAway;

  /// No description provided for @syncNotePausedByUser.
  ///
  /// In en, this message translates to:
  /// **'Paused by you.'**
  String get syncNotePausedByUser;

  /// Drawn over a still frame in the live view while a bulk transfer holds the stream. The cause (one shared Wi-Fi link) is the part that stops the user thinking the app has hung.
  ///
  /// In en, this message translates to:
  /// **'Preview paused while photos transfer — the live view and a full-resolution download share one Wi-Fi link, so they slow each other down. It comes back as soon as the transfer finishes.'**
  String get syncStreamPauseReason;

  /// No description provided for @deleteRefusalProtected.
  ///
  /// In en, this message translates to:
  /// **'the camera lists this file as protected. What that flag means on this firmware is not verified, so the app treats it as a refusal to delete rather than guessing — remove the protection, or delete it on the camera'**
  String get deleteRefusalProtected;

  /// No description provided for @deleteRefusalPathTooLong.
  ///
  /// In en, this message translates to:
  /// **'the path is {length} characters, and DeleteFile copies each entry into a {limit}-character slot, so the camera would truncate it and could delete the wrong file'**
  String deleteRefusalPathTooLong(int length, int limit);

  /// No description provided for @deleteRefusalListingFailed.
  ///
  /// In en, this message translates to:
  /// **'the card could not be listed after the delete, so this file\'s fate is unknown'**
  String get deleteRefusalListingFailed;

  /// No description provided for @albumErrListingRejected.
  ///
  /// In en, this message translates to:
  /// **'GetFileList answered 404 for range {start}..{end}. On this firmware that means the parameters were rejected, not that the command is missing.'**
  String albumErrListingRejected(int start, int end);

  /// No description provided for @albumErrListingFailed.
  ///
  /// In en, this message translates to:
  /// **'GetFileList failed: {raw}'**
  String albumErrListingFailed(String raw);

  /// No description provided for @albumErrPathTooLong.
  ///
  /// In en, this message translates to:
  /// **'path is {length} chars; the firmware copies it into a 50-byte buffer so this can never be fetched: {path}'**
  String albumErrPathTooLong(int length, String path);

  /// No description provided for @albumErrDeleteRejected.
  ///
  /// In en, this message translates to:
  /// **'DeleteFile answered 404 for {count} path(s). On this firmware that means the request shape was rejected — not that the file is gone.'**
  String albumErrDeleteRejected(int count);

  /// No description provided for @albumErrDeleteNoPaths.
  ///
  /// In en, this message translates to:
  /// **'DeleteFile needs at least one path'**
  String get albumErrDeleteNoPaths;

  /// No description provided for @albumErrDeleteTooMany.
  ///
  /// In en, this message translates to:
  /// **'DeleteFile takes at most {limit} paths per call and was given {count}; the firmware clamps the list and silently drops the rest, so this would look like success while leaving files behind'**
  String albumErrDeleteTooMany(int limit, int count);

  /// No description provided for @albumErrDeleteAll.
  ///
  /// In en, this message translates to:
  /// **'refusing to send DeleteFile file_list \"ALL\": on this firmware that means delete every file on the card'**
  String get albumErrDeleteAll;

  /// No description provided for @albumErrDeletePathTooLong.
  ///
  /// In en, this message translates to:
  /// **'DeleteFile copies each path into a 56-byte slot, so \"{path}\" ({length} chars) would be truncated and could delete the wrong file; the limit is {limit}'**
  String albumErrDeletePathTooLong(String path, int length, int limit);

  /// Shown in the live-view notice strip when a settings row has no handler — a wiring mistake made visible rather than silent.
  ///
  /// In en, this message translates to:
  /// **'Nothing is wired to \"{label}\" yet.'**
  String noticeUnwiredRow(String label);

  /// No description provided for @errStorageDenied.
  ///
  /// In en, this message translates to:
  /// **'Android will not let the app write to the photo library, so nothing can be saved. Grant the storage permission to this app, then start the sync again.'**
  String get errStorageDenied;

  /// No description provided for @errPreviewRefused.
  ///
  /// In en, this message translates to:
  /// **'the camera refused to start the preview'**
  String get errPreviewRefused;

  /// No description provided for @noticeShotsNotOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Those shots are not on this phone yet. Sync them first, or share from the camera by syncing and then sharing.'**
  String get noticeShotsNotOnPhone;

  /// No description provided for @errShareAndroidOnly.
  ///
  /// In en, this message translates to:
  /// **'sharing is only implemented on Android.'**
  String get errShareAndroidOnly;

  /// No description provided for @errShareSheetRefused.
  ///
  /// In en, this message translates to:
  /// **'Android would not open a share sheet for those files.'**
  String get errShareSheetRefused;

  /// No description provided for @noticeSharedPartially.
  ///
  /// In en, this message translates to:
  /// **'Shared {missing} of {total}; the rest are still syncing.'**
  String noticeSharedPartially(int missing, int total);

  /// No description provided for @noticeShotNotOnPhone.
  ///
  /// In en, this message translates to:
  /// **'That shot is not on this phone yet.'**
  String get noticeShotNotOnPhone;

  /// No description provided for @errNoViewerApp.
  ///
  /// In en, this message translates to:
  /// **'No app on this phone would open that file.'**
  String get errNoViewerApp;

  /// No description provided for @errRemoveCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove the phone\'s copy.'**
  String get errRemoveCopyFailed;

  /// No description provided for @errDeleteNotConnected.
  ///
  /// In en, this message translates to:
  /// **'not connected to the camera, so there is nothing to delete.'**
  String get errDeleteNotConnected;

  /// No description provided for @noticeNothingSentAllRefused.
  ///
  /// In en, this message translates to:
  /// **'Nothing was sent: every selected shot is one the app will not delete. See the reasons listed.'**
  String get noticeNothingSentAllRefused;

  /// No description provided for @noticeNothingToDelete.
  ///
  /// In en, this message translates to:
  /// **'Nothing to delete.'**
  String get noticeNothingToDelete;

  /// No description provided for @errDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'the delete could not be carried out: {detail}'**
  String errDeleteFailed(String detail);

  /// No description provided for @errNotConnectedShort.
  ///
  /// In en, this message translates to:
  /// **'not connected'**
  String get errNotConnectedShort;

  /// No description provided for @errCommandFailed.
  ///
  /// In en, this message translates to:
  /// **'{command} failed: {detail}'**
  String errCommandFailed(String command, String detail);

  /// The 404 clause is load-bearing: on this firmware a 404 means the parameters were rejected, not that the command is missing. Never translate it as 'command not found'.
  ///
  /// In en, this message translates to:
  /// **'{command} was rejected — the camera answered 404, which on this firmware means the parameters were wrong'**
  String errCommandRejected404(String command);

  /// No description provided for @errShutterReleaseFailed.
  ///
  /// In en, this message translates to:
  /// **'The shutter could not be released: {detail}. If the camera has stopped answering, it needs a power cycle.'**
  String errShutterReleaseFailed(String detail);

  /// `{detail}` is the capture interlock's own description of what is still held — an identifier list, inserted verbatim.
  ///
  /// In en, this message translates to:
  /// **'The camera did not answer the health check, so the shutter stays locked: {detail}. If it was frozen, it needs a power cycle.'**
  String errShutterHealthCheckFailed(String detail);

  /// No description provided for @errInterlockReleasedNoRemote.
  ///
  /// In en, this message translates to:
  /// **'The interlock was released, but the camera did not re-enter remote mode. Power-cycle it if it was frozen.'**
  String get errInterlockReleasedNoRemote;

  /// No description provided for @errInterlockReleasedStillBlocked.
  ///
  /// In en, this message translates to:
  /// **'The interlock was released, but the shutter is still blocked.'**
  String get errInterlockReleasedStillBlocked;

  /// No description provided for @noticeInterlockReleased.
  ///
  /// In en, this message translates to:
  /// **'Capture interlock released — the shutter is ready again.'**
  String get noticeInterlockReleased;

  /// The `photo fail` string in quotes is the firmware's own reply and is kept verbatim in both languages: it is what a user reports, and what a log search matches.
  ///
  /// In en, this message translates to:
  /// **'The camera refused the shot (\"photo fail\"). That means it is not in remote mode, or the previous shot is still being written to the card.'**
  String get errPhotoFail;

  /// No description provided for @errCaptureNotReached.
  ///
  /// In en, this message translates to:
  /// **'the capture did not reach the camera'**
  String get errCaptureNotReached;

  /// No description provided for @noticeFocusSkippedForShot.
  ///
  /// In en, this message translates to:
  /// **'A shot is being taken, so the focus point was not sent.'**
  String get noticeFocusSkippedForShot;

  /// No description provided for @errFocusFailed.
  ///
  /// In en, this message translates to:
  /// **'RCDoFocus failed: {detail}'**
  String errFocusFailed(String detail);

  /// No description provided for @errFocusRejected404.
  ///
  /// In en, this message translates to:
  /// **'RCDoFocus was rejected — the camera answered 404, which on this firmware means the parameters were wrong'**
  String get errFocusRejected404;

  /// No description provided for @errUnknownParamCommand.
  ///
  /// In en, this message translates to:
  /// **'unknown parameter command {command}'**
  String errUnknownParamCommand(String command);

  /// No description provided for @errCommandNotInTable.
  ///
  /// In en, this message translates to:
  /// **'{command} is not in the firmware command table'**
  String errCommandNotInTable(String command);

  /// No description provided for @noticeParamSetByCamera.
  ///
  /// In en, this message translates to:
  /// **'In {mode} mode the camera sets this itself, so the change was not applied. Switch to M to control it directly.'**
  String noticeParamSetByCamera(String mode);

  /// No description provided for @shutterBlockedNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected to the camera.'**
  String get shutterBlockedNotConnected;

  /// Names the button, not just the problem: this is the state a user lands in after a failed shot, and 'start the preview first' left them to work out that the fix button does exactly that.
  ///
  /// In en, this message translates to:
  /// **'The camera is not in remote mode, so it will not accept a shot. Start the preview — or press \"Fix the shutter\" below to do it.'**
  String get shutterBlockedNotRemote;

  /// Safety text. One command in a burst drive mode starts a burst that only RCCancelShooting stops, and this firmware has no watchdog: a user who does not understand this can strand the camera and have to pull the battery. The wording is the capture guard's own sentence, so both must be reworded together if either is.
  ///
  /// In en, this message translates to:
  /// **'The camera is in {drive} drive. A single command starts a burst that this app has no way to stop — the camera keeps shooting until it locks up and needs its battery removed. Set the drive mode to Single, or use the camera itself.'**
  String shutterBlockedBurst(String drive);

  /// The power cycle is named because nothing else works: the firmware clears the capture-state flags only on the ready branch, so a power cycle is the only recovery and the patched firmware the only prevention.
  ///
  /// In en, this message translates to:
  /// **'The camera refused the last capture and its capture state is now stuck — this is the fault the patched firmware fixes. Waiting will not clear it: power-cycle the camera, then reconnect.'**
  String get shutterBlockedQuarantined;

  /// No description provided for @settingsTabCapture.
  ///
  /// In en, this message translates to:
  /// **'Capture'**
  String get settingsTabCapture;

  /// No description provided for @settingsTabSync.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get settingsTabSync;

  /// No description provided for @settingsGroupExposure.
  ///
  /// In en, this message translates to:
  /// **'Exposure and focus'**
  String get settingsGroupExposure;

  /// No description provided for @settingsGroupImage.
  ///
  /// In en, this message translates to:
  /// **'Image output'**
  String get settingsGroupImage;

  /// No description provided for @settingsGroupImageSummary.
  ///
  /// In en, this message translates to:
  /// **'Aspect, file format, quality'**
  String get settingsGroupImageSummary;

  /// No description provided for @settingsGroupScene.
  ///
  /// In en, this message translates to:
  /// **'Scene and look'**
  String get settingsGroupScene;

  /// No description provided for @settingsGroupSceneSummary.
  ///
  /// In en, this message translates to:
  /// **'Picture style'**
  String get settingsGroupSceneSummary;

  /// No description provided for @settingsGroupVideo.
  ///
  /// In en, this message translates to:
  /// **'Video and audio'**
  String get settingsGroupVideo;

  /// No description provided for @settingsGroupVideoSummary.
  ///
  /// In en, this message translates to:
  /// **'Format, stabilisation, noise reduction, volume'**
  String get settingsGroupVideoSummary;

  /// No description provided for @settingsGroupTransfer.
  ///
  /// In en, this message translates to:
  /// **'Transfer'**
  String get settingsGroupTransfer;

  /// No description provided for @settingsGroupTransferSummary.
  ///
  /// In en, this message translates to:
  /// **'Sync mode, preview during transfer'**
  String get settingsGroupTransferSummary;

  /// No description provided for @settingsGroupConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection diagnostics'**
  String get settingsGroupConnection;

  /// No description provided for @settingsGroupConnectionSummary.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi permissions, SSID, passkey'**
  String get settingsGroupConnectionSummary;

  /// No description provided for @settingsGroupSystem.
  ///
  /// In en, this message translates to:
  /// **'System and diagnostics'**
  String get settingsGroupSystem;

  /// No description provided for @settingsGroupSystemSummary.
  ///
  /// In en, this message translates to:
  /// **'Screen timeout, BLE log'**
  String get settingsGroupSystemSummary;

  /// No description provided for @settingsRowRCSwitchDialMode.
  ///
  /// In en, this message translates to:
  /// **'Exposure mode'**
  String get settingsRowRCSwitchDialMode;

  /// No description provided for @settingsRowRCISOSet.
  ///
  /// In en, this message translates to:
  /// **'ISO'**
  String get settingsRowRCISOSet;

  /// No description provided for @settingsRowRCFNSet.
  ///
  /// In en, this message translates to:
  /// **'Aperture'**
  String get settingsRowRCFNSet;

  /// No description provided for @settingsRowRCShutterSpeedSet.
  ///
  /// In en, this message translates to:
  /// **'Shutter'**
  String get settingsRowRCShutterSpeedSet;

  /// No description provided for @settingsRowRCEVSet.
  ///
  /// In en, this message translates to:
  /// **'Exposure comp.'**
  String get settingsRowRCEVSet;

  /// No description provided for @settingsRowRCWBSet.
  ///
  /// In en, this message translates to:
  /// **'White balance'**
  String get settingsRowRCWBSet;

  /// No description provided for @settingsRowRCMeteringModeSet.
  ///
  /// In en, this message translates to:
  /// **'Metering'**
  String get settingsRowRCMeteringModeSet;

  /// No description provided for @settingsRowRCFocusModeSet.
  ///
  /// In en, this message translates to:
  /// **'Focus mode'**
  String get settingsRowRCFocusModeSet;

  /// No description provided for @settingsRowRCDriveModeSet.
  ///
  /// In en, this message translates to:
  /// **'Drive'**
  String get settingsRowRCDriveModeSet;

  /// No description provided for @settingsRowRCImageAspect.
  ///
  /// In en, this message translates to:
  /// **'Aspect'**
  String get settingsRowRCImageAspect;

  /// No description provided for @settingsRowRCFileFormatSet.
  ///
  /// In en, this message translates to:
  /// **'File format'**
  String get settingsRowRCFileFormatSet;

  /// No description provided for @settingsRowRCImageQualitySet.
  ///
  /// In en, this message translates to:
  /// **'Image quality'**
  String get settingsRowRCImageQualitySet;

  /// No description provided for @settingsRowRCChooseColorMode.
  ///
  /// In en, this message translates to:
  /// **'Picture style'**
  String get settingsRowRCChooseColorMode;

  /// No description provided for @settingsRowNavVideo.
  ///
  /// In en, this message translates to:
  /// **'Open remote video'**
  String get settingsRowNavVideo;

  /// No description provided for @settingsRowNavAlbum.
  ///
  /// In en, this message translates to:
  /// **'Open the sync page'**
  String get settingsRowNavAlbum;

  /// No description provided for @settingsRowDiagWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi diagnostics'**
  String get settingsRowDiagWifi;

  /// No description provided for @settingsRowDiagBle.
  ///
  /// In en, this message translates to:
  /// **'BLE diagnostics'**
  String get settingsRowDiagBle;

  /// No description provided for @settingsRowPauseStream.
  ///
  /// In en, this message translates to:
  /// **'Pause the preview during transfer'**
  String get settingsRowPauseStream;

  /// No description provided for @settingsRowPauseStreamNote.
  ///
  /// In en, this message translates to:
  /// **'The preview and a bulk transfer share one 802.11n link, so a copy holds the stream still until it finishes.'**
  String get settingsRowPauseStreamNote;

  /// No description provided for @settingsRowKeepScreenOn.
  ///
  /// In en, this message translates to:
  /// **'Keep the screen on while previewing'**
  String get settingsRowKeepScreenOn;

  /// No description provided for @settingsRowKeepScreenOnNote.
  ///
  /// In en, this message translates to:
  /// **'A camera controller is held at arm\'s length with both hands busy, so a screen that times out mid-composition cannot be recovered without losing the shot.'**
  String get settingsRowKeepScreenOnNote;

  /// No description provided for @settingsRowLocale.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsRowLocale;

  /// No description provided for @localePickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get localePickerTitle;

  /// No description provided for @localePickerNote.
  ///
  /// In en, this message translates to:
  /// **'Takes effect immediately and is remembered.'**
  String get localePickerNote;

  /// No description provided for @localeSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow the phone'**
  String get localeSystem;

  /// No description provided for @localeEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get localeEnglish;

  /// No description provided for @localeChinese.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get localeChinese;

  /// No description provided for @localeSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected: {name}'**
  String localeSelected(String name);

  /// No description provided for @paramAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get paramAuto;

  /// No description provided for @paramManual.
  ///
  /// In en, this message translates to:
  /// **'Manual'**
  String get paramManual;

  /// No description provided for @paramMulti.
  ///
  /// In en, this message translates to:
  /// **'Multi'**
  String get paramMulti;

  /// No description provided for @paramSpot.
  ///
  /// In en, this message translates to:
  /// **'Spot'**
  String get paramSpot;

  /// No description provided for @paramCenterWeighted.
  ///
  /// In en, this message translates to:
  /// **'Centre weighted'**
  String get paramCenterWeighted;

  /// No description provided for @paramCAF.
  ///
  /// In en, this message translates to:
  /// **'C-AF'**
  String get paramCAF;

  /// No description provided for @paramSAF.
  ///
  /// In en, this message translates to:
  /// **'S-AF'**
  String get paramSAF;

  /// No description provided for @paramMF.
  ///
  /// In en, this message translates to:
  /// **'MF'**
  String get paramMF;

  /// No description provided for @paramSingle.
  ///
  /// In en, this message translates to:
  /// **'Single'**
  String get paramSingle;

  /// No description provided for @paramContinuous.
  ///
  /// In en, this message translates to:
  /// **'Continuous'**
  String get paramContinuous;

  /// No description provided for @paramDelay2s.
  ///
  /// In en, this message translates to:
  /// **'2 s timer'**
  String get paramDelay2s;

  /// No description provided for @paramDelay10s.
  ///
  /// In en, this message translates to:
  /// **'10 s timer'**
  String get paramDelay10s;

  /// No description provided for @paramSunny.
  ///
  /// In en, this message translates to:
  /// **'Sunny'**
  String get paramSunny;

  /// No description provided for @paramCloudy.
  ///
  /// In en, this message translates to:
  /// **'Cloudy'**
  String get paramCloudy;

  /// No description provided for @paramShadow.
  ///
  /// In en, this message translates to:
  /// **'Shadow'**
  String get paramShadow;

  /// No description provided for @paramIncandescent.
  ///
  /// In en, this message translates to:
  /// **'Incandescent'**
  String get paramIncandescent;

  /// No description provided for @paramStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get paramStandard;

  /// No description provided for @paramPortrait.
  ///
  /// In en, this message translates to:
  /// **'Portrait'**
  String get paramPortrait;

  /// No description provided for @paramVivid.
  ///
  /// In en, this message translates to:
  /// **'Vivid'**
  String get paramVivid;

  /// The camera's own token, kept verbatim: the readout column draws the camera's vocabulary and compares against its screen, and the narrow column's short-form table is keyed by this exact string.
  ///
  /// In en, this message translates to:
  /// **'NaturalBW'**
  String get paramNaturalBw;

  /// The camera's own token, kept verbatim — see @paramNaturalBw.
  ///
  /// In en, this message translates to:
  /// **'HContrastBW'**
  String get paramHighContrastBw;

  /// No description provided for @paramTime.
  ///
  /// In en, this message translates to:
  /// **'TIME'**
  String get paramTime;

  /// No description provided for @paramBulb.
  ///
  /// In en, this message translates to:
  /// **'BULB'**
  String get paramBulb;

  /// No description provided for @paramVga.
  ///
  /// In en, this message translates to:
  /// **'VGA'**
  String get paramVga;

  /// No description provided for @paramJpgSmall.
  ///
  /// In en, this message translates to:
  /// **'JPG S'**
  String get paramJpgSmall;

  /// No description provided for @paramJpgMedium.
  ///
  /// In en, this message translates to:
  /// **'JPG M'**
  String get paramJpgMedium;

  /// No description provided for @paramJpgLarge.
  ///
  /// In en, this message translates to:
  /// **'JPG L'**
  String get paramJpgLarge;

  /// No description provided for @paramRawJpgSmall.
  ///
  /// In en, this message translates to:
  /// **'RAW+JPG S'**
  String get paramRawJpgSmall;

  /// No description provided for @paramRawJpgMedium.
  ///
  /// In en, this message translates to:
  /// **'RAW+JPG M'**
  String get paramRawJpgMedium;

  /// No description provided for @paramRawJpgLarge.
  ///
  /// In en, this message translates to:
  /// **'RAW+JPG L'**
  String get paramRawJpgLarge;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
