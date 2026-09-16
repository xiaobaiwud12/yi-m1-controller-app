Future<void> main() async {
  const torn = '{"version":1,"capacity":2000,"queue":{'
      '"/DCIM/101YICAM/YI000090|1700000000":'
      '{"path":"/DCIM/101YICAM/YI000090.JPG","date":1700000000,'
      '"filetype":"picture","quality":"none"},'
      '"/DCIM/101YICAM/YI000092|1700000000":{"path":"/DCIM/1}}';
  for (var i = 0; i < torn.length; i++) {
    final c = torn[i];
    if (c == '{' || c == '}' || c == '"' || c == ':') {
      print('$i: $c');
    }
  }
}
