/// A byte-for-byte copy of the private scanner, so it can be observed directly.
String? objectBody(String? text, Object marker) {
  if (text == null) return null;
  final int start;
  if (marker is int) {
    final brace = text.indexOf('{', marker);
    if (brace < 0) return null;
    start = brace;
  } else {
    final quoted = text.indexOf('"$marker"');
    if (quoted < 0) return null;
    final brace = text.indexOf('{', quoted);
    if (brace < 0) return null;
    start = brace;
  }

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

void main() {
  const torn = '{"version":1,"capacity":2000,"queue":{'
      '"/DCIM/101YICAM/YI000090|1700000000":'
      '{"path":"/DCIM/101YICAM/YI000090.JPG","date":1700000000,'
      '"filetype":"picture","quality":"none"},'
      '"/DCIM/101YICAM/YI000092|1700000000":{"path":';
  print('len=${torn.length}');
  print('has queue: ${torn.contains('"queue"')}');
  print('indexOf quote-queue: ${torn.indexOf('"queue"')}');
  final body = objectBody(torn, 'queue');
  print('body = $body');
  print('records = ${RegExp(r'"((?:[^"\\]|\\.)*)"\s*:\s*\{').allMatches(body ?? '').length}');

  // Trace the depth by hand.
  var depth = 0;
  var inString = false;
  for (var i = 0; i < torn.length; i++) {
    final c = torn[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
      print('  $i { -> $depth');
    } else if (c == '}') {
      depth--;
      print('  $i } -> $depth');
    }
  }
  print('final depth=$depth inString=$inString');
}
