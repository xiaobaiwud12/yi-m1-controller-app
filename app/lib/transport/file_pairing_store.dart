import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_connection.dart';

/// Pairing state that survives an app restart.
///
/// ## Why this matters more than it looks
///
/// The camera stores **exactly one pairing at a time**, and pairing requires a
/// physical confirmation on the camera body.  Losing the stored `refId`/`token`
/// therefore costs the user a walk to the camera and a button press on every app
/// launch — which is precisely what happens with an in-memory store.  Verified
/// user report: reopening the app to test disconnect handling dropped straight
/// back into first-time pairing.
///
/// A stored pair is reused to open a session **without touching the camera**,
/// which was confirmed on hardware.
///
/// ## Why not `shared_preferences`
///
/// A JSON file needs no plugin, works identically on every platform, and is
/// inspectable when something goes wrong — and this record is exactly the thing
/// worth being able to inspect.  The file lives in the app's own documents
/// directory, so it is removed with the app and is not world-readable.
class FilePairingStore implements PairingStore {
  static const _fileName = 'camera_pairing.json';

  File? _resolved;

  Future<File> _file() async {
    final cached = _resolved;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$_fileName');
    _resolved = f;
    return f;
  }

  @override
  Future<Map<String, String>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final text = await f.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry('$k', '$v'));
      }
    } on Object catch (e) {
      // A corrupt or unreadable record must not stop the app: it only means the
      // user has to pair again.
      debugPrint('pairing store: could not read ($e); starting fresh');
    }
    return {};
  }

  @override
  Future<void> save(Map<String, String> values) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(values), flush: true);
    } on Object catch (e) {
      debugPrint('pairing store: could not write ($e)');
    }
  }
}
