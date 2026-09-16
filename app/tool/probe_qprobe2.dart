import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/sync/transfer_queue.dart';
import 'package:yi_m1_controller/transport/album.dart';

class S implements SyncStore {
  String? v;
  S([this.v]);
  @override
  Future<String?> read() async => v;
  @override
  Future<void> write(String c) async => v = c;
}

Future<void> main() async {
  final s = S();
  final q = TransferQueue(store: s);
  q.add(AlbumFile(
    path: '/DCIM/101YICAM/YI000071.JPG',
    fileType: 'picture',
    captureTime: DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
  ));
  await q.save();
  print('ENCODED: ${s.v}');

  final q2 = TransferQueue(store: s);
  await q2.load();
  for (final r in q2.pending) {
    print('reloaded: path=${r.path} date=${r.dateSeconds} key=${r.key}');
  }

  const torn = '{"version":1,"capacity":2000,"queue":{'
      '"/DCIM/101YICAM/YI000090|1700000000":'
      '{"path":"/DCIM/101YICAM/YI000090.JPG","date":1700000000,'
      '"filetype":"picture","quality":"none"},'
      '"/DCIM/101YICAM/YI000092|1700000000":{"path":';
  for (final t in ['this is not a queue at all',
      '{"version":1,"capacity":2000,"queue":{"/x|1":{"path":"/DCIM/1', torn]) {
    final log = <String>[];
    final qq = TransferQueue(store: S(t), onLog: log.add);
    try {
      await qq.load();
    } on Object catch (e, st) {
      print('THREW: $e\n${st.toString().split('\n').take(6).join('\n')}');
    }
    print('--- input len=${t.length}: records=${qq.length} '
        'dropped=${qq.droppedOnLoad} log=$log');
  }
}
