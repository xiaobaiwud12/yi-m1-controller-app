/// BLE identifiers for the YI M1 (C59Y1) camera.
///
/// Source of truth: the community reverse-engineering project
/// `bullbin/xiaoyi_m1_re_liveview` (prot_ble/const_ble_uuid.py), cross-checked
/// against an independent firmware analysis that located the identical UUID
/// table in the `.data` image (12 characteristics, stride 0x1C) plus the
/// time-sync characteristic.
///
/// DO NOT invent identifiers here.  Everything in this file is either taken from
/// that project or from the firmware analysis; anything uncertain is marked.
library;

/// Primary service exposing the whole camera control surface.
const String kServiceM1 = '41106dd9-25ad-477b-a884-5038b6de4649';

/// Write the pairing request.  Payload: `"<protocol>,<key>,<client>"`,
/// e.g. `"1,12345,android"`.  The camera shows a confirmation prompt.
const String kCharPairingInit = '41106da0-25ad-477b-a884-5038b6de4649';

/// Notify: the pairing result.  Empty payload means the request was denied;
/// otherwise the payload is the session token as ASCII.
const String kCharPairingNotif = '41106da7-25ad-477b-a884-5038b6de4649';

/// Write to forget the stored pairing.  (Present in the reverse-engineered
/// table; the official app exposes this as an explicit "unpair" action.)
const String kCharPairingForget = '41106da9-25ad-477b-a884-5038b6de4649';

/// Read: a short status string (the camera answers `"OK"`).  Used by the
/// reference client as an extra liveness probe.
const String kCharMisc = '41106da3-25ad-477b-a884-5038b6de4649';

/// Declared in the official app's source, but **not present on the real
/// hardware**.
///
/// Two independent scans of the test unit (`YI_M1_XXXXXX`) enumerated this
/// service and found 12 characteristics, with no `41106da1` among them.  The
/// official app tolerates its absence, so this app does too — it is recorded
/// only so nobody re-derives it and assumes it exists.
const String kCharResponseToken = '41106da1-25ad-477b-a884-5038b6de4649';

/// Read: `"<protocol>,<bodyFw>,<region>,<lensFw>"`, e.g. `"1,M1,M1INT,1.1"`.
/// The reference client splits on ',' and treats field 2 as the region
/// (`M1INT` = international, `M1CN`/`M1` = China).
const String kCharFirmwareInfo = '41106da2-25ad-477b-a884-5038b6de4649';

/// Write to open the authenticated control session.
/// Payload: `"<protocol>,<key>,<crc32>"`.
const String kCharStartSession = '41106da4-25ad-477b-a884-5038b6de4649';

/// Write `"ON"` / probably `"OFF"` to switch the camera Wi-Fi on or off.
const String kCharWifiSwitch = '41106da5-25ad-477b-a884-5038b6de4649';

/// Read: `"<ssid>,<passkey>"`.  Only valid once the session is authenticated.
const String kCharWifiApKeyshare = '41106da6-25ad-477b-a884-5038b6de4649';

/// Write the camera clock.  The firmware parses an ASCII decimal string with
/// `strtol` and splits it into six calendar fields, which strongly implies Unix
/// epoch seconds - but the exact payload has NOT been confirmed against the
/// official app yet.  Treat as high-confidence, not verified.
///
/// This call is not optional: the camera has no RTC, so without it every photo
/// gets a wrong capture date.
const String kCharSyncTime = '41106dac-25ad-477b-a884-5038b6de4649';

/// Only present on some firmware revisions; when it exists the reference client
/// subscribes to it and to [kCharUnkNotify0] after starting a session, then
/// writes `'3'` to [kCharResumeRelated].
const String kCharUnkNotifyF = '41106daf-25ad-477b-a884-5038b6de4649';
const String kCharUnkNotify0 = '41106dae-25ad-477b-a884-5038b6de4649';
const String kCharResumeRelated = '41106dad-25ad-477b-a884-5038b6de4649';

// Standard GATT device-information characteristics.
const String kCharDeviceName = '00002a00-0000-1000-8000-00805f9b34fb';
const String kCharAppearance = '00002a01-0000-1000-8000-00805f9b34fb';
const String kCharModelNumber = '00002a24-0000-1000-8000-00805f9b34fb';
const String kCharManufacturer = '00002a29-0000-1000-8000-00805f9b34fb';
