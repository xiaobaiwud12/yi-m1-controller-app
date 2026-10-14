import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';

/// Bridges values produced by the shell to the MaterialApp above it.
/// Camera sessions, queues and ledgers remain owned by AppState.
final appPresentation = AppPresentationState();

class AppPresentationState {
  final localeTag = ValueNotifier<String>(kLocaleSystem);
  final launchError = ValueNotifier<String?>(null);
  bool starting = true;
}
