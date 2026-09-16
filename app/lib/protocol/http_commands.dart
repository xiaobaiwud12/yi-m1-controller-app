// GENERATED FILE - DO NOT EDIT BY HAND.
//
// Derived from the camera's own dispatch table and from the community
// reverse-engineering project bullbin/xiaoyi_m1_re_liveview (MIT).  The
// generation script and its inputs are not part of this repository.
//   values   : tools/xiaoyi_m1_re_liveview/prot_http/const_http_cmd_rc_params.py


/// The camera's complete HTTP command surface.
///
/// All 45 commands, transcribed from the firmware's dispatch table.  The
/// camera server takes a single GET parameter:
///
///     GET http://192.168.0.10/?data={"command":"..."}
///
/// It has **no authentication and no CSRF protection**, and the camera
/// serves only one Wi-Fi client, so treat the radio as a trusted network.
library;

/// Every command name the firmware dispatches on.
const List<String> kHttpCommands = <String>[
  'ChangeCurrentFrame',
  'CheckPreUpdate',
  'CloseAP',
  'DeleteFile',
  'DeleteMLFile',
  'GetCameraStatus',
  'GetFile',
  'GetFileInfo',
  'GetFileList',
  'GetMLFileList',
  'PauseMovieStream',
  'RCCancelShooting',
  'RCCancelShooting1',
  'RCChooseColorMode',
  'RCDShootCntSet',
  'RCDoFocus',
  'RCDoShooting',
  'RCDriveModeSet',
  'RCEVSet',
  'RCEisSwitchSet',
  'RCFNSet',
  'RCFileFormatSet',
  'RCFocusModeSet',
  'RCISOSet',
  'RCImageAspect',
  'RCImageQualitySet',
  'RCMFAdjust',
  'RCMeteringModeSet',
  'RCShutterSpeedSet',
  'RCStartRemoteCtl',
  'RCStopRemoteCtl',
  'RCSwitchDialMode',
  'RCVANoiseReduceSet',
  'RCVASwitchSet',
  'RCVAVolSet',
  'RCVideoFormatSet',
  'RCWBSet',
  'ResumeMovieStream',
  'StartMovieStream',
  'StopMovieStream',
  'UpdateFW',
  'UpdateLenFW',
  'UploadML',
  'VideoRecordingStart',
  'VideoRecordingStop',
];

/// Commands that exist in the firmware but are NOT exercised by the
/// official app - the capabilities a third-party client can unlock.
///
/// Every entry is asserted to be part of kHttpCommands; a value that is
/// not in the dispatch table would simply be rejected by the camera.
const Set<String> kCommandsUnusedByOfficialApp = <String>{
  'VideoRecordingStart',
  'VideoRecordingStop',
  'RCVideoFormatSet',
  'RCEisSwitchSet',
  'RCVANoiseReduceSet',
  'RCVASwitchSet',
  'RCVAVolSet',
  'StartMovieStream',
  'StopMovieStream',
  'PauseMovieStream',
  'ResumeMovieStream',
  'ChangeCurrentFrame',
  'RCCancelShooting',
  'RCCancelShooting1',
};

/// Commands that can destroy data or brick the camera.  A UI should
/// require explicit confirmation, and an automated client should refuse
/// them outright.
const Set<String> kDangerousCommands = <String>{
  'UpdateFW',
  'UpdateLenFW',
  'UploadML',
  'DeleteFile',
  'DeleteMLFile',
  'CloseAP',
};

/// True when [command] is one of the 45 commands in the dispatch table.
bool isKnownCommand(String command) => kHttpCommands.contains(command);

/// True when [command] is one this client will not send without an explicit
/// opt-in — see [kDangerousCommands].
///
/// A named function rather than a bare `kDangerousCommands.contains(...)` at each
/// use, for the same reason [isKnownCommand] is one: the set is a policy, and the
/// question "is this command dangerous?" should read the same everywhere it is
/// asked. `lib/transport/http_transport.dart` enforces it on both send entry
/// points; `tool/verify_transport.dart` checks that every member of the set is
/// actually refused.
bool isDangerousCommand(String command) => kDangerousCommands.contains(command);
