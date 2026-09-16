import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/sync/transfer_queue.dart';

class S implements SyncStore {
  String? v;
  S([this.v]);
  @override
  Future<String?> read() async => v;
  @override
  Future<void> write(String c) async => v = c;
}

/// The private scanner, copied so the queue body can be observed.
String? queueBody(String text) {
  final quoted = text.indexOf('"queue"');
  if (quoted < 0) return null;
  final start = text.indexOf('{', quoted);
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5C) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7B) {
      depth++;
    } else if (c == 0x7D) {
      depth--;
      if (depth == 0) return text.substring(start + 1, i);
    }
  }
  return null;
}

Future<void> main() async {
  const torn = '{"version":1,"capacity":2000,"queue":{'
      '"/DCIM/101YICAM/YI000090|1700000000":'
      '{"path":"/DCIM/101YICAM/YI000090.JPG","date":1700000000,'
      '"filetype":"picture","quality":"none"},'
      '"/DCIM/101YICAM/YI000092|1700000000":{"path":"/DCIM/1}}';
  print('len=${torn.length}');
  final body = queueBody(torn);
  print('body=<<$body>>');
  if (body != null) {
    print('first quote at ${body.indexOf('"')}');
    final open = body.indexOf('"');
    final colon = body.indexOf(':', open + 1);
    final brace = body.indexOf('{', colon + 1);
    print('open=$open colon=$colon brace=$brace');
    print('tail after first record: <<'
        '${body.substring(0, 0)}'
        '${body.indexOf('}')}>>');
  }
  final log = <String>[];
  final q = TransferQueue(store: S(torn), onLog: log.add);
  await q.load();
  print('records=${q.length} dropped=${q.droppedOnLoad} log=$log');
  for (final r in q.pending) {
    print('  ${r.path} ${r.dateSeconds} ${r.fileType}');
  }
}
