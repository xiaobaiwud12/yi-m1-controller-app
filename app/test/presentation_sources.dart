import 'dart:io';

/// Source scans must follow presentation when pages move out of lib/ui.
bool isPresentationSource(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.startsWith('lib/ui/') ||
      normalized.startsWith('lib/app/') ||
      normalized == 'lib/app.dart' ||
      (normalized.startsWith('lib/features/') &&
          normalized.contains('/presentation/'));
}

List<File> presentationSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart') &&
        isPresentationSource(file.path))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));
