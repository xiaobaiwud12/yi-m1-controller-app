/// Stable public entry for the application and its existing verification seams.
library;

export 'app/application.dart';
export 'app/bootstrap.dart' show main;
export 'app/configuration.dart'
    show kDirectCameraHost, kDirectCameraPort, kFakeCameraMarker, kDirectCameraMarker;
export 'app/home_shell.dart' show HomeShell;
export 'app/verification_camera.dart';
