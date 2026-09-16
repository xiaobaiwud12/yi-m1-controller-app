/// Minimal HTTP transport for the camera, using only `dart:io`.
///
/// Deliberately flutter-free: this lets the protocol be exercised against the
/// real camera from the plain Dart VM (`dart run`) while the Flutter UI is still
/// being built, and it keeps the transport swappable for tests.
///
/// The camera serves its whole control surface over a single GET endpoint:
///
///     GET http://192.168.0.10/?data={"command":"...","<param>":"<value>"}
///
/// There is no authentication and no CSRF protection, and the camera is a
/// single-client AP - see docs/PROTOCOL.md section 5.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/http_commands.dart';

/// Thrown for transport-level failures, carrying the HTTP status when there was
/// one so callers can distinguish "camera said 404" from "not connected".
class CameraHttpException implements Exception {
  final String message;
  final int? statusCode;
  const CameraHttpException(this.message, [this.statusCode]);

  /// The camera answers **404** when a command's required JSON keys are missing
  /// or invalid - it does not send a distinct "bad parameter" status.  So a 404
  /// on a known command almost always means *we* built the request wrong, not
  /// that the endpoint is absent.
  ///
  /// Some commands are genuinely absent from this firmware revision (the
  /// official app sends two of them); those fail through exactly the same path.
  bool get isBadParameters => statusCode == 404;

  @override
  String toString() => statusCode == null
      ? 'CameraHttpException: $message'
      : 'CameraHttpException($statusCode): $message';
}

/// Authorisation to send **one** command that [kDangerousCommands] names.
///
/// ## Why this type exists, and why it is not a `bool`
///
/// `kDangerousCommands` is a claim about the camera: `UpdateFW` and `UpdateLenFW`
/// flash firmware over the SD card with no rollback, `UploadML` writes into
/// `/XIAOYI/MASTER/`, `DeleteFile` and `DeleteMLFile` remove files and `DeleteFile`
/// accepts `ALL`, and `CloseAP` switches the radio off although **no `OpenAP`
/// exists** in the 45-command table, so the only way back may be the battery.
///
/// Until this was added, nothing read that set. The sibling set beside it —
/// `isKnownCommand`, which guards a **typo** — was checked on every send, so the
/// set guarding a bricked camera was the one set with no enforcement at all.
///
/// The shape matters as much as the presence. A `bool dangerouslyApproved = false`
/// parameter would be fail-safe by default but opt-in *silently*: one word added at
/// a call site, or a named argument pasted from a neighbouring line, and a dangerous
/// command ships. So the authorisation is a value that:
///
/// * **has to be passed**, as a required named argument to [CameraHttpClient.sendApproved]
///   — the shape that would be an omission at a call site does not compile;
/// * **cannot be forged**: the constructor is private and [forCommand] is the only
///   way to obtain one, so holding an approval means having asked for one *by name*;
/// * **can only be about a dangerous command**: [forCommand] refuses everything else,
///   so an approval is evidence of a hazard rather than a token someone can wave;
/// * **is checked against the request**, so an approval for one command cannot
///   authorise another;
/// * **carries the caller's own authorisation** in [onRequest], which the transport
///   runs before anything is put on the wire, so the reason for the risk cannot be
///   separated from the act of taking it.
///
/// The runtime guard in [CameraHttpClient.send] is deliberately kept as well, even
/// though this type makes the omission unwritable: the set is data, it can be added
/// to without any call site changing, and the guard is what makes that addition
/// fail. Neither half is redundant — see the note on `send`.
sealed class DangerousApproval {
  final String command;

  /// Runs immediately before the request goes out, with the command actually being
  /// sent. Throwing here refuses the send, which is the intended way for a caller to
  /// re-check a condition that may have changed since it decided.
  final void Function(String command) onRequest;

  const DangerousApproval._(this.command, this.onRequest);

  /// The one way to obtain an approval, and therefore the one place a dangerous
  /// command is deliberately allowed to be sent.
  ///
  /// Refuses any command that is not in [kDangerousCommands]: authorising something
  /// harmless is a mistake in the caller's model of the risk, and it is cheaper to
  /// hear about it here than to have the set quietly outgrown by its own escape
  /// hatch.
  static DangerousApproval forCommand(
      String command, void Function(String command) onRequest) {
    if (!isDangerousCommand(command)) {
      throw ArgumentError.value(command, 'command',
          'is not in kDangerousCommands, so it needs no approval; sending it '
          'through sendApproved() would make the dangerous set meaningless');
    }
    return _ApprovedCommand(command, onRequest);
  }

  @override
  String toString() => 'DangerousApproval($command)';
}

/// The only implementation, private so that [DangerousApproval] cannot be extended
/// into a shape that skips [DangerousApproval.forCommand].
final class _ApprovedCommand extends DangerousApproval {
  const _ApprovedCommand(super.command, super.onRequest) : super._();
}

/// A response from the camera.
class CameraResponse {
  /// The `code` field the camera returns (200 on success).
  final int code;

  /// The `data` field, when present.
  final Object? data;

  /// The raw body, always available.
  final String raw;

  const CameraResponse({required this.code, required this.raw, this.data});

  bool get ok => code == 200;

  @override
  String toString() => 'CameraResponse(code: $code, data: $data)';
}

/// Talks to one camera over its HTTP control endpoint.
class CameraHttpClient {
  /// The camera has a fixed address; it runs its own AP and hands out one lease.
  static const String defaultHost = '192.168.0.10';

  final String host;
  final int port;
  final Duration timeout;
  final HttpClient _client;

  /// Optional test seam.
  ///
  /// When set, [send] delegates here instead of talking to a socket.  This keeps
  /// the transport `dart:io`-only in production while letting the higher layers
  /// (the capture interlock in particular) be exercised offline, which matters
  /// because the camera is battery-powered and usually unavailable.
  ///
  /// It is **assigned through a setter**, which wraps whatever is given so that a
  /// command which needs an approval but arrives here without one fails loudly
  /// instead of being answered. An offline harness is meant to stand in for a
  /// camera, and the one thing it must never do is succeed at a request the
  /// transport refused — a green test on an unapproved dangerous send is worse than
  /// no test, because it is the shape this seam is most likely to be asked to fake.
  /// A seam that genuinely needs to drive the approved path overrides
  /// [overrideApprovedSend] instead, which is the same deliberate act as approving.
  Future<CameraResponse> Function(String command, Map<String, Object> params)?
      get overrideSend => _overrideSend;
  set overrideSend(
      Future<CameraResponse> Function(String command, Map<String, Object> params)?
          handler) {
    if (handler == null) {
      _overrideSend = null;
      return;
    }
    // The wrapper closes over `handler`, **not** over `_overrideSend`. That is not
    // style: a closure that reads the field it is assigned to makes the field
    // self-referential, and a harness written the natural way — `overrideSend:
    // (cmd, p) => otherClient.send(cmd, p)` — then re-enters its own wrapper instead
    // of the client it named. Caught by the "one DeleteFile in flight" check, which
    // stopped observing deletes and would have passed by emptiness.
    Future<CameraResponse> guarded(
        String command, Map<String, Object> params) async {
      if (isDangerousCommand(command)) {
        throw CameraHttpException(
          'the offline send seam was handed "$command", which needs an '
          'approval; a harness that means to drive the approved path must '
          'override overrideApprovedSend instead',
        );
      }
      return handler(command, params);
    }

    _overrideSend = guarded;
  }

  Future<CameraResponse> Function(String command, Map<String, Object> params)?
      _overrideSend;

  /// Optional test seam for the approved path — the one [sendApproved] delegates to.
  ///
  /// Separate from [overrideSend] rather than a third argument on it, so that the
  /// ~30 existing offline harnesses keep compiling unchanged and, more importantly,
  /// keep their meaning: a harness that only knows how to answer ordinary commands
  /// cannot be mistaken for one that exercises a delete. Wiring this one is the same
  /// deliberate act as approving the command it exists to carry.
  Future<CameraResponse> Function(String command, Map<String, Object> params,
      DangerousApproval? approval)? overrideApprovedSend;

  CameraHttpClient({
    this.host = defaultHost,
    this.port = 80,
    this.timeout = const Duration(seconds: 8),
    HttpClient? httpClient,
    this.overrideApprovedSend,
    Future<CameraResponse> Function(String command, Map<String, Object> params)?
        overrideSend,
  }) : _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = timeout;
    // Through the setter, not `this.overrideSend`, so the wrapper above is applied
    // to a constructor argument exactly as it is to a later assignment. A seam that
    // could be installed un-wrapped by choosing the constructor form would be a
    // guard with two doors.
    this.overrideSend = overrideSend;
  }

  /// Send one command.  Throws [CameraHttpException] on transport failure.
  ///
  /// The command name is checked against the 45-entry dispatch table first: a
  /// typo would otherwise surface as an opaque 404 that looks identical to a
  /// parameter error.  (This is not theoretical - an earlier revision of this
  /// file called `StopRemoteCtl`, which is not a command; the real name is
  /// `RCStopRemoteCtl`.)
  ///
  /// It is then checked against [kDangerousCommands] and **refused** unless
  /// [approval] is given.  Two guards rather than one because the two sets are
  /// different kinds of claim: a name outside the dispatch table is a bug in this
  /// client, while a name inside `kDangerousCommands` is a working command whose
  /// effect on the camera is not undoable over HTTP.  They used to be enforced the
  /// other way round — the typo guard ran on every send and the dangerous guard was
  /// read by nothing at all.
  ///
  /// The refusal is here, at the last point before bytes leave the phone, and not
  /// only in the UI, because the caller reaching this method may be a new feature
  /// that has never heard of the set. `CloseAP` is one plausible sentence away from
  /// being sent by exactly such a feature — "release the camera's Wi-Fi when nobody
  /// is using it" — and there is **no `OpenAP`** in the dispatch table, so getting
  /// it wrong may only be recoverable by pulling the battery.
  ///
  /// The `approval != null` overload below exists so that an approval actually
  /// presented to this method is *used*: it is not accepted and ignored, because a
  /// parameter that does nothing is how the next reader concludes the guard is
  /// decorative.
  ///
  /// [params] is `Map<String, Object>` and not `Map<String, String>` for one
  /// command: `DeleteFile`'s `file_list` is a **JSON array** of paths, not a
  /// string (the handler parses it as an array at `text+0x153290` and the official
  /// app passes a `String[]`).  Everything else passes strings, and a string value
  /// encodes exactly as it did before.
  Future<CameraResponse> send(String command,
      [Map<String, Object> params = const {}, DangerousApproval? approval]) {
    if (approval != null) {
      return sendApproved(command, params, approval: approval);
    }
    if (!isKnownCommand(command)) {
      throw CameraHttpException(
        "'$command' is not one of the 45 commands in the firmware dispatch "
        'table, so the camera would answer 404',
      );
    }
    if (isDangerousCommand(command)) {
      throw CameraHttpException(
        'refusing to send "$command" — "$command" is in kDangerousCommands, and '
        'this firmware offers no way to undo what it does. A caller that has '
        'decided to take that risk must say so by passing an approval — see '
        'sendApproved() and DangerousApproval.forCommand()',
      );
    }
    return _send(command, params, null);
  }

  /// Send [command] with the approval that authorises it.
  ///
  /// The only way in for a dangerous command, and it is deliberately spelled out
  /// in full at every call site: `sendApproved('DeleteFile', …, approval:
  /// DangerousApproval.forCommand('DeleteFile', …))`. The approval is a **required
  /// named** argument, so the shape that would be an accident — the old
  /// `send(name, params)` with a name from the dangerous set — does not compile,
  /// and the name, the parameters and the authorisation line up in one place where
  /// a reviewer can see all three.
  ///
  /// The transport does the last two checks itself rather than trusting the
  /// approval's shape: that the approval names *this* command, and that the command
  /// really is one of [kDangerousCommands]. A mismatch throws [ArgumentError],
  /// because it is a programming error in the caller and not a camera failure — and
  /// it throws **before** the caller's own authorisation runs, so a mis-wired
  /// approval cannot execute anything on its way to being refused.
  Future<CameraResponse> sendApproved(String command, Map<String, Object> params,
      {required DangerousApproval approval}) {
    if (!isKnownCommand(command)) {
      throw ArgumentError.value(command, 'command',
          'is not one of the 45 commands in the firmware dispatch table');
    }
    if (!isDangerousCommand(command)) {
      throw ArgumentError.value(
          command,
          'command',
          'is not in kDangerousCommands, so it is sent with send(); routing it '
          'through sendApproved() would make the dangerous set meaningless');
    }
    if (approval.command != command) {
      throw ArgumentError.value(
          approval.command,
          'approval',
          'authorises "${approval.command}" and cannot authorise "$command"');
    }
    // Last, and only once everything above agrees: the caller's own reason for
    // taking the risk. Throwing here refuses the send.
    approval.onRequest(command);
    return _send(command, params, approval);
  }

  /// The one place a request is built, and therefore the one place a guard on the
  /// dangerous set cannot be bypassed by a new entry point.
  ///
  /// [approval] is `null` exactly when [send] has already refused anything that
  /// needed one; [sendApproved] passes the approval through so a seam can see it.
  Future<CameraResponse> _send(
      String command, Map<String, Object> params, DangerousApproval? approval) async {
    final payload = <String, Object>{'command': command, ...params};
    if (isDangerousCommand(command)) {
      // The approved seam is asked first, and is asked for **every** dangerous
      // command rather than only the ones carrying an approval: a harness that wires
      // it is saying "I answer deletes", and a harness that wires only the plain
      // seam still has to be handed the approved request, or a check like "one
      // DeleteFile in flight" would stop observing deletes and pass by emptiness.
      if (overrideApprovedSend != null) {
        return overrideApprovedSend!(command, payload, approval);
      }
      if (overrideSend != null) {
        if (approval == null) {
          // Unreachable through [send] and [sendApproved], which both refuse first.
          // Stated as a hard failure rather than left to the socket: an offline
          // harness that forgot the approved seam must not look like a camera that
          // answered, and must not spin for the connection timeout either.
          throw CameraHttpException(
            'refusing to send "$command": the offline send seam cannot carry a '
            'command that needs an approval; set overrideApprovedSend',
          );
        }
        return overrideSend!(command, payload);
      }
      // With no seam at all this is production, and the request would be real — so
      // the one thing that must be true of it is asserted here rather than inferred
      // from the two callers above. `AGENTS.md` §8's rule about wiring is that the
      // place the value leaves the app is the place to check it.
      if (approval == null) {
        throw CameraHttpException(
          'refusing to send "$command": it needs an approval and reached the '
          'socket without one',
        );
      }
    } else if (overrideSend != null) {
      return overrideSend!(command, payload);
    }
    final data = jsonEncode(payload);
    // Uri.queryParameters percent-encodes for us, which matches what the
    // official app does explicitly with URLEncoder.encode(..., "UTF-8").
    final uri = Uri(
      scheme: 'http',
      host: host,
      port: port,
      queryParameters: {'data': data},
    );

    try {
      final request = await _client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);

      if (response.statusCode != 200) {
        throw CameraHttpException(
          'HTTP ${response.statusCode} for $command: ${body.trim()}',
          response.statusCode,
        );
      }
      return _parse(body);
    } on CameraHttpException {
      rethrow;
    } on TimeoutException {
      throw CameraHttpException('timeout after ${timeout.inSeconds}s for $command');
    } on SocketException catch (e) {
      throw CameraHttpException(
        'cannot reach $host - is the computer joined to the camera Wi-Fi '
        '(${e.osError?.message ?? e.message})',
      );
    } catch (e) {
      throw CameraHttpException('$e');
    }
  }

  CameraResponse _parse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return CameraResponse(
          code: (decoded['code'] as num?)?.toInt() ?? -1,
          data: decoded['data'],
          raw: body,
        );
      }
      return CameraResponse(code: -1, raw: body);
    } catch (_) {
      return CameraResponse(code: -1, raw: body);
    }
  }

  // --- convenience wrappers, matching what the reference client does ---------

  /// Battery, remaining shots and lens info.
  Future<CameraResponse> status() => send('GetCameraStatus');

  /// Enter remote-control mode. The camera must be in this mode before most RC
  /// commands take effect.
  Future<CameraResponse> startRemoteControl() => send('RCStartRemoteCtl');

  Future<CameraResponse> stopRemoteControl() => send('RCStopRemoteCtl');

  /// Remote video recording - a capability the official app never exposed.
  Future<CameraResponse> videoStart() => send('VideoRecordingStart');
  Future<CameraResponse> videoStop() => send('VideoRecordingStop');

  /// Recording format, e.g. `4K_30`, `2K_30`, `FHD_60`.
  ///
  /// Note the firmware's own spelling of the parameter key: **`Resolution`**
  /// is spelled correctly here, but the neighbouring `GetFile` command uses
  /// the misspelled **`resulotion`**.  Do not "fix" either one.
  Future<CameraResponse> setVideoFormat(String format) =>
      send('RCVideoFormatSet', {'Resolution': format});

  /// Still-image format, e.g. `RAW`, `RAWJ-L`, `JPG-L`.
  Future<CameraResponse> setFileFormat(String format) =>
      send('RCFileFormatSet', {'FileFormat': format});

  /// Take a photo.
  ///
  /// Safe on this firmware: measured at ~30 fps live view before *and* after a
  /// single shot, with `SurplusPhotoCnts` decrementing.  Repeated/rapid shots
  /// are the case that has been observed to hang the camera, so callers should
  /// serialise captures and never issue them concurrently - see
  /// `docs/PROTOCOL.md`.
  Future<CameraResponse> shoot() => send('RCDoShooting');

  /// Master Guide file list.  `{"code":200,"data":[]}` is the **correct**
  /// answer on a card with no `/XIAOYI/MASTER/` files - Master Guide is the
  /// C-dial feature.  This is not a broken endpoint.
  Future<CameraResponse> masterFileList() => send('GetMLFileList');

  void close() => _client.close(force: true);
}
