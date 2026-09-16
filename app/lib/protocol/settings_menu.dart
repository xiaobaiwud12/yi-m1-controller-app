/// The settings menu's structure, as data.
///
/// ## Why this is here and not in the widget tree
///
/// This file is imported by `tool/verify_transport.dart`, which runs in the plain
/// Dart VM with no Flutter engine. Two claims about the menu are worth checking
/// mechanically, and both are claims about *structure*:
///
/// * **nothing is unreachable** — every parameter the protocol can set has one
///   and only one row, compared against `AppState.paramCommands`;
/// * **nothing used while shooting is behind a tap** — the controls that change
///   between frames are in a group that cannot be collapsed, and the settings the
///   user decides once are in ones that start collapsed.
///
/// Neither claim is visible in a running app until it is wrong, and a widget test
/// would need a Flutter engine to make them. So the structure lives here, next to
/// the other tables the offline verifier reads.
///
/// ## Why icons are names
///
/// `IconData` is `dart:ui` and would drag Flutter into this file. A group
/// therefore carries the *name* of its icon, and the UI resolves it
/// (`_iconFor` in the live-view page). [kKnownSettingsIcons] is what makes a typo
/// detectable: otherwise a misspelled name silently renders a fallback chevron.
library;

enum SettingsRowType {
  /// A `DropdownButton` sending one `RC…` command.
  param,

  /// A `Switch` over a client-side preference; `AppState` holds the field.
  toggle,

  /// A navigation or diagnostics entry point.
  action,
}

/// One control in the second level.
class SettingsRow {
  final SettingsRowType type;

  /// Row label, shown next to the control.
  final String label;

  /// For [SettingsRowType.param], the `RC…` command. For the other two, the id
  /// the UI dispatches on.
  final String key;

  /// One line under the control saying what it affects, for the rows whose
  /// consequence is not visible in the row itself.
  final String? note;

  const SettingsRow.param(this.label, this.key)
      : type = SettingsRowType.param,
        note = null;

  const SettingsRow.toggle(this.label, this.key, {this.note})
      : type = SettingsRowType.toggle;

  const SettingsRow.action(this.key, this.label)
      : type = SettingsRowType.action,
        note = null;

  @override
  String toString() => '${type.name}:$key';
}

/// One collapsible section, or the always-visible exposure section.
class SettingsGroup {
  final String id;
  final String title;

  /// A name resolved to an `IconData` by the UI — see the library comment.
  final String icon;

  /// Shown on the collapsed header, so a closed group still says what is inside
  /// it. Without this a collapsed group is a label the user has to remember.
  final String? summary;

  /// False only for the group holding the controls used while shooting.
  ///
  /// A non-collapsible group is not a group whose state is forced open: it has no
  /// state at all, so there is no way to lose the shutter behind a tap.
  final bool collapsible;

  final bool openByDefault;
  final List<SettingsRow> rows;

  const SettingsGroup({
    required this.id,
    required this.title,
    required this.icon,
    required this.rows,
    this.summary,
    this.collapsible = true,
    this.openByDefault = false,
  });

  /// The rows that set a camera parameter.
  Iterable<SettingsRow> get paramRows =>
      rows.where((r) => r.type == SettingsRowType.param);

  /// The rows that open a surface or toggle a client-side preference.
  Iterable<SettingsRow> get actionRows =>
      rows.where((r) => r.type != SettingsRowType.param);
}

/// One top-level tab of the settings surface.
///
/// Tabs split the menu by *when* the settings are used — capture versus the
/// transfer that follows it — so the groups under them stay short enough to read.
class SettingsTab {
  final String id;
  final String title;
  final String icon;
  final List<SettingsGroup> groups;

  const SettingsTab({
    required this.id,
    required this.title,
    required this.icon,
    required this.groups,
  });
}

// ---------------------------------------------------------------------------
// The menu itself.
//
// The depth encodes how often a setting is used, and that is the whole point of
// the second level:
//
//   level 1  the tabs, split by when the setting applies;
//   level 2  collapsible groups, collapsed until opened;
//   inside   the controls.
//
// The shot controls are in a group that cannot be collapsed, so "how do I change
// the ISO" is never a two-tap question. Everything below them is a setting the
// user decides once and then leaves alone.
// ---------------------------------------------------------------------------

const List<SettingsTab> kSettingsTabs = [
  SettingsTab(
    id: 'capture',
    title: 'Capture',
    icon: 'tune',
    groups: [
      SettingsGroup(
        id: 'exposure',
        title: 'Exposure and focus',
        icon: 'exposure',
        collapsible: false,
        rows: [
          SettingsRow.param('Exposure mode', 'RCSwitchDialMode'),
          SettingsRow.param('ISO', 'RCISOSet'),
          SettingsRow.param('Aperture', 'RCFNSet'),
          SettingsRow.param('Shutter', 'RCShutterSpeedSet'),
          SettingsRow.param('Exposure comp.', 'RCEVSet'),
          SettingsRow.param('White balance', 'RCWBSet'),
          SettingsRow.param('Metering', 'RCMeteringModeSet'),
          SettingsRow.param('Focus mode', 'RCFocusModeSet'),
          SettingsRow.param('Drive', 'RCDriveModeSet'),
        ],
      ),
      SettingsGroup(
        id: 'image',
        title: 'Image output',
        icon: 'image',
        summary: 'Aspect, file format, quality',
        rows: [
          SettingsRow.param('Aspect', 'RCImageAspect'),
          SettingsRow.param('File format', 'RCFileFormatSet'),
          SettingsRow.param('Image quality', 'RCImageQualitySet'),
        ],
      ),
      SettingsGroup(
        id: 'scene',
        title: 'Scene and look',
        icon: 'palette',
        summary: 'Picture style',
        rows: [
          SettingsRow.param('Picture style', 'RCChooseColorMode'),
        ],
      ),
      SettingsGroup(
        id: 'video',
        title: 'Video and audio',
        icon: 'video',
        summary: 'Format, stabilisation, noise reduction, volume',
        // A single action rather than the controls themselves. The video page is
        // where the "these four commands were never verified on hardware" caution
        // is stated, and duplicating `RCVideoFormatSet`/`RCEisSwitchSet`/
        // `RCVANoiseReduceSet` here would put commands the firmware may refuse
        // behind a second entry point that never showed that text.
        rows: [SettingsRow.action('nav.video', 'Open remote video')],
      ),
    ],
  ),
  SettingsTab(
    id: 'sync',
    title: 'Sync',
    icon: 'sync',
    groups: [
      SettingsGroup(
        id: 'transfer',
        title: 'Transfer',
        icon: 'download',
        summary: 'Sync mode, preview during transfer',
        rows: [
          SettingsRow.action('nav.album', 'Open the sync page'),
          // A duplicate of the album page's toggle over one shared value, so the
          // shooting screen can answer "will the preview stop if I leave it
          // running" without a second implementation of the setting.
          SettingsRow.toggle(
            'Pause the preview during transfer',
            'pauseStreamDuringTransfer',
            note: 'The preview and a bulk transfer share one 802.11n link, so a '
                'copy holds the stream still until it finishes.',
          ),
        ],
      ),
      SettingsGroup(
        id: 'connection',
        title: 'Connection diagnostics',
        icon: 'diagnostics',
        summary: 'Wi-Fi permissions, SSID, passkey',
        rows: [
          SettingsRow.action('diag.wifi', 'Wi-Fi diagnostics'),
        ],
      ),
      SettingsGroup(
        id: 'system',
        title: 'System and diagnostics',
        icon: 'memory',
        summary: 'Screen timeout, BLE log',
        rows: [
          SettingsRow.toggle(
            'Keep the screen on while previewing',
            'keepScreenOn',
            note: 'A camera controller is held at arm\'s length with both hands '
                'busy, so a screen that times out mid-composition cannot be '
                'recovered without losing the shot.',
          ),
          // The interface language. Client-side like `keepScreenOn` above — it is
          // not a camera parameter, and nothing is sent to the camera when it
          // changes — which is why it sits in this group rather than in a group of
          // its own.
          //
          // It is a catalog row rather than a control bolted onto the panel so that
          // `analysis/41` §7.7's rule holds: everything reachable from the settings
          // surface is declared in the catalog, and the offline check that compares
          // the catalog against the ids the UI dispatches on therefore covers it.
          // The label is English here because this file is Flutter-free
          // (`AGENTS.md` §4.1) — the UI renders it through
          // `lib/l10n/settings_menu_l10n.dart`, keyed by `key`, like every other row.
          SettingsRow.action('locale', 'Language'),
          SettingsRow.action('diag.ble', 'BLE diagnostics'),
        ],
      ),
    ],
  ),
];

/// Every group in the menu, in tab order.
List<SettingsGroup> get kSettingsGroups =>
    [for (final t in kSettingsTabs) ...t.groups];

/// Every parameter command the menu exposes, in menu order.
List<String> get kMenuParamCommands => [
      for (final g in kSettingsGroups)
        for (final r in g.paramRows) r.key,
    ];

/// Looks a group up by id, or null when nothing declares it.
SettingsGroup? kSettingsGroupById(String id) {
  for (final g in kSettingsGroups) {
    if (g.id == id) return g;
  }
  return null;
}

/// Which firmware value pool each settable command takes its choices from.
///
/// The command name and the pool name are **not** the same string —
/// `RCMeteringModeSet` sets `MeteringMode`, whose pool is `meteringMode`, and
/// `RCFNSet` sets `Fnumber`, whose pool is `fStop`. Looking a pool up by the wire
/// key therefore finds nothing for eleven of the thirteen commands and renders an
/// empty dropdown: a control that appears and cannot set anything.
///
/// Kept here beside the catalog for the same reason the catalog is here —
/// `tool/verify_transport.dart` checks it against `kRcValuePools` without a
/// Flutter engine.
const Map<String, String> kSettingsRowPools = {
  'RCSwitchDialMode': 'exposureMode',
  'RCISOSet': 'iso',
  'RCFNSet': 'fStop',
  'RCShutterSpeedSet': 'shutterSpeed',
  'RCEVSet': 'evOffset',
  'RCWBSet': 'whiteBalance',
  'RCMeteringModeSet': 'meteringMode',
  'RCFocusModeSet': 'focusMode',
  'RCDriveModeSet': 'driveMode',
  'RCImageAspect': 'imageAspect',
  'RCFileFormatSet': 'fileFormat',
  'RCImageQualitySet': 'imageQuality',
  'RCChooseColorMode': 'colorStyle',
};

/// Every icon name the menu may use.
///
/// The UI falls back to a chevron for an unknown name rather than failing, so a
/// typo here is invisible in a running app and is caught in
/// `tool/verify_transport.dart` instead.
const Set<String> kKnownSettingsIcons = {
  'tune',
  'exposure',
  'image',
  'palette',
  'video',
  'sync',
  'download',
  'diagnostics',
  'memory',
};

/// The non-parameter row keys the settings panel knows how to dispatch.
///
/// Kept beside the catalog because the two must agree: a row whose key is not in
/// this set is a menu entry that does nothing when tapped, and the set is what
/// the offline check compares the catalog against.
const Set<String> kSettingsActionKeys = {
  'nav.video',
  'nav.album',
  'diag.ble',
  'diag.wifi',
  'pauseStreamDuringTransfer',
  'keepScreenOn',
  'locale',
};
