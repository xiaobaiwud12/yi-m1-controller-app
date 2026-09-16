/// Localized text for the settings catalog.
///
/// ## The problem this solves
///
/// `lib/protocol/settings_menu.dart` holds the whole settings surface as data —
/// tab titles, group titles, group summaries, row labels and row notes. It is
/// **Flutter-free by contract** (`AGENTS.md` §4.1) because `tool/verify_transport.dart`
/// checks its *structure* in the plain Dart VM, and it cannot call
/// `AppLocalizations`, which is a Flutter widget-tree lookup.
///
/// ## What was done about it
///
/// The catalog keeps its English strings and gains no import — it is **unchanged**.
/// What travels to the UI is its **ids**, which already existed and already had to
/// be unique and stable: `SettingsTab.id`, `SettingsGroup.id`, `SettingsRow.key`.
/// Those ids *are* the message codes. The UI renders through the functions below,
/// which switch on the id and fall back to the catalog's own English string, so an
/// id this file has not been taught about shows readable English rather than
/// nothing.
///
/// That is the same decision as [UiMessage] in `lib/protocol/ui_message.dart`, and
/// for the same reason: the layer that knows *what happened* must not be the layer
/// that owns the sentence, but it must still be able to produce one.
///
/// ## Why the fallback matters and why the check matters more
///
/// The fallback makes a missing translation a cosmetic problem instead of a blank
/// row. It also means the failure is **invisible**, which is why
/// `test/l10n_settings_menu_test.dart` compares [kLocalizedTabIds],
/// [kLocalizedGroupIds] and [kLocalizedRowKeys] against the catalog in both
/// directions: a row added to the catalog without a case here fails the build, and a
/// case here with no row fails it too (a dead translation is how a table drifts).
library;

import '../protocol/settings_menu.dart';
import 'l10n.dart';

/// The tab ids [settingsTabTitle] handles.
const Set<String> kLocalizedTabIds = <String>{'capture', 'sync'};

/// The group ids [settingsGroupTitle] and [settingsGroupSummary] handle.
const Set<String> kLocalizedGroupIds = <String>{
  'exposure',
  'image',
  'scene',
  'video',
  'transfer',
  'connection',
  'system',
};

/// The row keys [settingsRowLabel] handles — parameter commands and action ids alike.
const Set<String> kLocalizedRowKeys = <String>{
  'RCSwitchDialMode',
  'RCISOSet',
  'RCFNSet',
  'RCShutterSpeedSet',
  'RCEVSet',
  'RCWBSet',
  'RCMeteringModeSet',
  'RCFocusModeSet',
  'RCDriveModeSet',
  'RCImageAspect',
  'RCFileFormatSet',
  'RCImageQualitySet',
  'RCChooseColorMode',
  'nav.video',
  'nav.album',
  'diag.ble',
  'diag.wifi',
  'pauseStreamDuringTransfer',
  'keepScreenOn',
  'locale',
};

/// The row keys whose `note` this file translates.
const Set<String> kLocalizedRowNoteKeys = <String>{
  'pauseStreamDuringTransfer',
  'keepScreenOn',
};

/// A tab's title.
String settingsTabTitle(AppLocalizations l, SettingsTab tab) =>
    switch (tab.id) {
      'capture' => l.settingsTabCapture,
      'sync' => l.settingsTabSync,
      _ => tab.title,
    };

/// A group's title.
String settingsGroupTitle(AppLocalizations l, SettingsGroup group) =>
    switch (group.id) {
      'exposure' => l.settingsGroupExposure,
      'image' => l.settingsGroupImage,
      'scene' => l.settingsGroupScene,
      'video' => l.settingsGroupVideo,
      'transfer' => l.settingsGroupTransfer,
      'connection' => l.settingsGroupConnection,
      'system' => l.settingsGroupSystem,
      _ => group.title,
    };

/// A group's one-line summary, shown while it is collapsed.
///
/// Returns null when the group declares none, so the caller keeps its own decision
/// about what to draw — an empty string here would draw an empty line.
String? settingsGroupSummary(AppLocalizations l, SettingsGroup group) {
  if (group.summary == null) return null;
  return switch (group.id) {
    'image' => l.settingsGroupImageSummary,
    'scene' => l.settingsGroupSceneSummary,
    'video' => l.settingsGroupVideoSummary,
    'transfer' => l.settingsGroupTransferSummary,
    'connection' => l.settingsGroupConnectionSummary,
    'system' => l.settingsGroupSystemSummary,
    _ => group.summary,
  };
}

/// A row's label, next to its control.
String settingsRowLabel(AppLocalizations l, SettingsRow row) =>
    switch (row.key) {
      'RCSwitchDialMode' => l.settingsRowRCSwitchDialMode,
      'RCISOSet' => l.settingsRowRCISOSet,
      'RCFNSet' => l.settingsRowRCFNSet,
      'RCShutterSpeedSet' => l.settingsRowRCShutterSpeedSet,
      'RCEVSet' => l.settingsRowRCEVSet,
      'RCWBSet' => l.settingsRowRCWBSet,
      'RCMeteringModeSet' => l.settingsRowRCMeteringModeSet,
      'RCFocusModeSet' => l.settingsRowRCFocusModeSet,
      'RCDriveModeSet' => l.settingsRowRCDriveModeSet,
      'RCImageAspect' => l.settingsRowRCImageAspect,
      'RCFileFormatSet' => l.settingsRowRCFileFormatSet,
      'RCImageQualitySet' => l.settingsRowRCImageQualitySet,
      'RCChooseColorMode' => l.settingsRowRCChooseColorMode,
      'nav.video' => l.settingsRowNavVideo,
      'nav.album' => l.settingsRowNavAlbum,
      'diag.ble' => l.settingsRowDiagBle,
      'diag.wifi' => l.settingsRowDiagWifi,
      'pauseStreamDuringTransfer' => l.settingsRowPauseStream,
      'keepScreenOn' => l.settingsRowKeepScreenOn,
      'locale' => l.settingsRowLocale,
      _ => row.label,
    };

/// A row's explanatory line, or null when the row has none.
String? settingsRowNote(AppLocalizations l, SettingsRow row) {
  if (row.note == null) return null;
  return switch (row.key) {
    'pauseStreamDuringTransfer' => l.settingsRowPauseStreamNote,
    'keepScreenOn' => l.settingsRowKeepScreenOnNote,
    _ => row.note,
  };
}
