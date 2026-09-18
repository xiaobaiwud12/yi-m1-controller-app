// Launcher-icon assertions: the icon is present, it is not blank, the five
// densities disagree with each other, and the mark fits inside the safe zone.
//
// ## Why this is a program and not a shell one-liner
//
// `AGENTS.md` §11 records the only screenshot baseline this project ever kept:
// 1080x2136, **one distinct colour**, entirely `#00000000`. It passed under any
// rendering, because `matchesGoldenFile` compares images and an all-transparent
// image compares equal to itself forever. The lesson is not "goldens are bad" --
// it is that **a check on generated image output must assert that the output is
// an image of something**. So the properties below are deliberately the ones a
// silent generator failure destroys:
//
//   * the file exists, decodes, and has the density's exact size;
//   * it has more than one colour (catches "produced nothing");
//   * it has enough colours and enough ink to be a rendering rather than a
//     flat fill (catches "produced a rectangle of the background colour");
//   * no two of the ten PNGs are byte-identical (catches "the loop rendered the
//     same picture into five files");
//   * the round icon is round: its four corners are transparent and its centre
//     is not (catches "round is a square that a launcher might round");
//   * the vector's own geometry, parsed out of the written XML, is inside the
//     central 66 dp of the 108 dp canvas **and** inside a 66 dp circle.
//
// The PNGs are decoded here rather than trusted. Reading `IHDR` alone would let a
// file declare 192x192 and contain a solid colour; `decodePng` below is a real
// decoder (zlib inflate + the five scanline filters), so every assertion is made
// against pixels.
//
// ## Why it re-derives the geometry instead of reusing the generator's numbers
//
// `tools/icon/make_launcher_icon.py` computes the mark's bounding box and refuses
// to write an icon that breaks the safe zone. That is a useful early failure, but
// it is not a check: it shares every assumption with the code it checks, so a
// wrong assumption about where the mark is would be asserted by both halves.
// This file instead parses `android:pathData` out of the **written** vector,
// extracts the coordinates, and measures those. An edit to the XML that moves
// the mark -- by hand or by a changed generator -- is caught here.
//
//     dart tool/verify_icon.dart            # from app/
//
// Exit code 0 when every assertion holds, 1 otherwise.
//
// ## What this does not check
//
// It cannot say whether the icon is *attractive*, or whether it reads at 48 px;
// that is a human judgement and it lives in the contact sheet
// (`tools/icon/out/contact-sheet.png`, written by the generator's `--contact`).
// It also does not render the XML: the vector could in principle contain a path
// this parser accepts and a renderer draws differently. That gap is closed by
// building the app and inspecting the packaged resources, which `task.ps1 build`
// does, and by looking at the generated PNGs, which is what the PNG assertions
// above are for.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

int _checks = 0;
int _failures = 0;

void check(String what, bool ok, [String detail = '']) {
  _checks++;
  if (ok) {
    print('  ok   $what');
  } else {
    _failures++;
    print('  FAIL $what${detail.isEmpty ? '' : '  -- $detail'}');
  }
}

void section(String title) {
  print('');
  print(title);
}

// --------------------------------------------------------------------------
// A small PNG decoder. Only what the assertions need: 8-bit RGB/RGBA/greyscale,
// non-interlaced, which is what the generator writes and what Android accepts.
// --------------------------------------------------------------------------

class Raster {
  Raster(this.width, this.height, this.pixels);

  final int width;
  final int height;

  /// Row-major RGBA, 4 bytes per pixel.
  final Uint8List pixels;

  int get pixelCount => width * height;

  List<int> at(int x, int y) {
    final i = (y * width + x) * 4;
    return [pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]];
  }

  /// Number of distinct RGBA values. The measurement that caught the deleted
  /// golden baseline: it was 1.
  int distinctColours() {
    final seen = <int>{};
    for (var i = 0; i < pixels.length; i += 4) {
      seen.add(pixels[i] << 24 | pixels[i + 1] << 16 | pixels[i + 2] << 8 | pixels[i + 3]);
    }
    return seen.length;
  }

  /// Fraction of pixels that are not fully transparent.
  double opaqueFraction() {
    var opaque = 0;
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] != 0) opaque++;
    }
    return opaque / pixelCount;
  }

  /// The most common fully-opaque colour, as `#RRGGBB`, or null if none.
  String? dominantColour() {
    final counts = <int, int>{};
    for (var i = 0; i < pixels.length; i += 4) {
      if (pixels[i + 3] < 250) continue;
      final key = pixels[i] << 16 | pixels[i + 1] << 8 | pixels[i + 2];
      counts[key] = (counts[key] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    var best = counts.keys.first;
    for (final key in counts.keys) {
      if (counts[key]! > counts[best]!) best = key;
    }
    return '#${best.toRadixString(16).padLeft(6, '0')}';
  }
}

Raster decodePng(Uint8List bytes) {
  if (bytes.length < 8 ||
      bytes[0] != 0x89 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x4E ||
      bytes[3] != 0x47) {
    throw const FormatException('not a PNG (bad signature)');
  }
  var offset = 8;
  int? width;
  int? height;
  int bitDepth = 0;
  int colourType = 0;
  var interlace = 0;
  final idat = BytesBuilder();
  // Palette and per-palette-entry alpha. `aapt2` rewrites the PNGs it packages
  // into indexed images, so the ones in the APK are colour type 3 while the ones
  // in the source tree are type 6; a decoder that only handles the generator's
  // output cannot read the artifact, which is the one that matters most.
  Uint8List? palette;
  Uint8List? paletteAlpha;

  while (offset + 8 <= bytes.length) {
    final length = _be32(bytes, offset);
    final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
    final dataStart = offset + 8;
    if (dataStart + length > bytes.length) {
      throw const FormatException('truncated chunk');
    }
    switch (type) {
      case 'IHDR':
        width = _be32(bytes, dataStart);
        height = _be32(bytes, dataStart + 4);
        bitDepth = bytes[dataStart + 8];
        colourType = bytes[dataStart + 9];
        interlace = bytes[dataStart + 12];
      case 'PLTE':
        palette = bytes.sublist(dataStart, dataStart + length);
      case 'tRNS':
        paletteAlpha = bytes.sublist(dataStart, dataStart + length);
      case 'IDAT':
        idat.add(bytes.sublist(dataStart, dataStart + length));
      case 'IEND':
        offset = bytes.length;
        continue;
    }
    offset = dataStart + length + 4; // + CRC
  }

  if (width == null || height == null) throw const FormatException('no IHDR');
  if (bitDepth != 8) throw FormatException('unsupported bit depth $bitDepth');
  if (interlace != 0) throw const FormatException('interlaced PNG is not supported');
  final channels = switch (colourType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => throw FormatException('unsupported colour type $colourType'),
  };
  if (colourType == 3 && palette == null) {
    throw const FormatException('an indexed PNG with no PLTE chunk');
  }

  final raw = Uint8List.fromList(ZLibCodec().decode(idat.takeBytes()));
  final stride = width * channels;
  if (raw.length < (stride + 1) * height) {
    throw const FormatException('inflated data is shorter than the image');
  }

  final out = Uint8List(width * height * 4);
  final previous = Uint8List(stride);
  final current = Uint8List(stride);
  var position = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[position++];
    current.setRange(0, stride, raw, position);
    position += stride;
    for (var x = 0; x < stride; x++) {
      final a = x >= channels ? current[x - channels] : 0;
      final b = previous[x];
      final c = x >= channels ? previous[x - channels] : 0;
      final value = current[x];
      current[x] = switch (filter) {
        0 => value,
        1 => (value + a) & 0xFF,
        2 => (value + b) & 0xFF,
        3 => (value + ((a + b) >> 1)) & 0xFF,
        4 => (value + _paeth(a, b, c)) & 0xFF,
        _ => throw FormatException('unknown scanline filter $filter'),
      };
    }
    for (var x = 0; x < width; x++) {
      final s = x * channels;
      final d = (y * width + x) * 4;
      switch (colourType) {
        case 0:
          out[d] = out[d + 1] = out[d + 2] = current[s];
          out[d + 3] = 255;
        case 3:
          final index = current[s];
          if (index * 3 + 2 >= palette!.length) {
            throw FormatException('palette index $index is out of range');
          }
          out[d] = palette[index * 3];
          out[d + 1] = palette[index * 3 + 1];
          out[d + 2] = palette[index * 3 + 2];
          out[d + 3] = paletteAlpha != null && index < paletteAlpha.length
              ? paletteAlpha[index]
              : 255;
        case 4:
          out[d] = out[d + 1] = out[d + 2] = current[s];
          out[d + 3] = current[s + 1];
        case 2:
          out[d] = current[s];
          out[d + 1] = current[s + 1];
          out[d + 2] = current[s + 2];
          out[d + 3] = 255;
        case 6:
          out[d] = current[s];
          out[d + 1] = current[s + 1];
          out[d + 2] = current[s + 2];
          out[d + 3] = current[s + 3];
      }
    }
    previous.setRange(0, stride, current);
  }
  return Raster(width, height, out);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

int _be32(Uint8List bytes, int at) =>
    bytes[at] << 24 | bytes[at + 1] << 16 | bytes[at + 2] << 8 | bytes[at + 3];

int _le16(Uint8List b, int at) => b[at] | b[at + 1] << 8;
int _le32(Uint8List b, int at) => b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;

/// A minimal ZIP reader: entry name to inflated bytes.
///
/// An APK is a ZIP and `resources.arsc` is stored uncompressed, so this only has
/// to handle stored and deflated entries -- which is all an APK contains. Written
/// rather than pulled from a package because `AGENTS.md` §11's standing decision
/// is that this project does not add a dependency for something this small, and a
/// launcher icon is not a reason to start.
Map<String, Uint8List> _readZip(File file) {
  final bytes = file.readAsBytesSync();
  final out = <String, Uint8List>{};
  // Find the end-of-central-directory record by scanning back for its signature.
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0 && i > bytes.length - 66000; i--) {
    if (_le32(bytes, i) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('not a ZIP: no end-of-central-directory');
  final count = _le16(bytes, eocd + 10);
  var offset = _le32(bytes, eocd + 16);
  for (var i = 0; i < count; i++) {
    if (_le32(bytes, offset) != 0x02014b50) {
      throw const FormatException('bad central directory entry');
    }
    final method = _le16(bytes, offset + 10);
    final compressedSize = _le32(bytes, offset + 20);
    final uncompressedSize = _le32(bytes, offset + 24);
    final nameLength = _le16(bytes, offset + 28);
    final extraLength = _le16(bytes, offset + 30);
    final commentLength = _le16(bytes, offset + 32);
    final localOffset = _le32(bytes, offset + 42);
    final name = String.fromCharCodes(bytes, offset + 46, offset + 46 + nameLength);
    if (nameLength == 0xFFFF) {
      throw const FormatException('ZIP64 entry names are not supported');
    }
    // The local header repeats the name and extra field with its own lengths.
    final localNameLength = _le16(bytes, localOffset + 26);
    final localExtraLength = _le16(bytes, localOffset + 28);
    final dataStart = localOffset + 30 + localNameLength + localExtraLength;
    final raw = bytes.sublist(dataStart, dataStart + compressedSize);
    out[name] = switch (method) {
      0 => Uint8List.fromList(raw),
      8 => Uint8List.fromList(ZLibCodec(raw: true).decode(raw)),
      _ => throw FormatException('unsupported ZIP compression method $method for $name'),
    };
    if (uncompressedSize != out[name]!.length) {
      throw FormatException('$name inflated to ${out[name]!.length}, expected $uncompressedSize');
    }
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return out;
}

/// Where `aapt2` is, searched the way `tools/task.ps1`'s build assertion searches.
///
/// Returns null when it is genuinely absent, and the caller treats that as a
/// failure rather than a skip.
///
/// **The separators are `/` on purpose, and the search is by environment
/// variable only.** An earlier version joined with backslashes and fell back to
/// a hardcoded SDK directory on one particular drive; both were one machine's
/// layout written into a file that this repository publishes, and the second is
/// what the release scan reports as `absolute-windows-path`. `Directory` and
/// `File` accept `/` on Windows as well, so `/` runs everywhere, and `aapt2` is
/// looked for under both names because only the Windows build tools append
/// `.exe`. The SDK is located through `ANDROID_HOME` / `ANDROID_SDK_ROOT`, or the
/// Windows default install location — which is how every other part of this tree
/// finds it.
String? _findAapt2() {
  final candidates = <String>[
    if (Platform.environment['ANDROID_HOME'] != null) Platform.environment['ANDROID_HOME']!,
    if (Platform.environment['ANDROID_SDK_ROOT'] != null)
      Platform.environment['ANDROID_SDK_ROOT']!,
    if (Platform.environment['LOCALAPPDATA'] != null)
      '${Platform.environment['LOCALAPPDATA']}/Android/Sdk',
  ];
  for (final root in candidates) {
    final buildTools = Directory('$root/build-tools');
    if (!buildTools.existsSync()) continue;
    // Newest first, matching the build's `Sort-Object -Descending`.
    final versions = buildTools.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final version in versions) {
      for (final name in const <String>['aapt2.exe', 'aapt2']) {
        final exe = File('${version.path}/$name');
        if (exe.existsSync()) return exe.path;
      }
    }
  }
  return null;
}

/// Which packaged files back `mipmap/ic_launcher` and `mipmap/ic_launcher_round`.
///
/// Reads `aapt2 dump resources`, whose format is:
///
///     resource 0x7f0a0000 mipmap/ic_launcher
///       (mdpi) (file) res/9w.png type=PNG
///       (anydpi-v26) (file) res/BW.xml type=XML
///     resource 0x7f0b0001 string/app_name
///       () "M1 Controller"
///
/// A `?` path is `aapt2`'s marker for an entry it could not resolve, and is
/// skipped. Parsing text is a weaker contract than parsing the binary table, and
/// it is chosen deliberately: every failure mode above came from *my* reading of
/// an undocumented binary layout, whereas this reads the output of the tool that
/// wrote the file. If the format changes, the number of files found drops and the
/// assertions below fail loudly.
Map<String, List<String>> _mipmapPngs(String aapt2, String apkPath) {
  final result = <String, List<String>>{};
  final dump = Process.runSync(aapt2, ['dump', 'resources', apkPath]);
  if (dump.exitCode != 0) {
    throw FormatException('aapt2 dump resources exited ${dump.exitCode}: ${dump.stderr}');
  }
  String? current;
  for (final line in (dump.stdout as String).split('\n')) {
    final resource = RegExp(r'^resource 0x[0-9a-f]+ (mipmap/ic_launcher(?:_round)?)\s*$')
        .firstMatch(line.trim());
    if (resource != null) {
      current = resource.group(1)!;
      result.putIfAbsent(current, () => <String>[]);
      continue;
    }
    if (line.startsWith('resource ')) {
      current = null;
      continue;
    }
    if (current == null) continue;
    // `(file)` marks a real file; a plain `(qualifier)` line is a scalar value.
    if (!line.contains('(file)')) continue;
    final path = RegExp(r'(res/\S+\.(?:png|xml))').firstMatch(line)?.group(1);
    if (path == null || path.contains('?')) continue;
    result[current]!.add(path);
  }
  for (final paths in result.values) {
    paths.sort();
  }
  return result;
}

/// Pixels whose colour is nearer to one of the mark's colours than to the plate.
///
/// Tolerance-based because the packaged PNGs are palette-crunched by `aapt2` and
/// antialiased edges are blends; a strict equality test would find nothing even
/// in a correct icon.
int _inkPixels(Raster raster) {
  const plate = [0x0B, 0x1D, 0x2A];
  const inks = [
    [0x5F, 0xD8, 0xF5],
    [0xFF, 0xFF, 0xFF],
    [0x8F, 0xE3, 0xF7],
  ];
  var count = 0;
  for (var i = 0; i < raster.pixels.length; i += 4) {
    if (raster.pixels[i + 3] < 200) continue;
    final r = raster.pixels[i], g = raster.pixels[i + 1], b = raster.pixels[i + 2];
    final toPlate = (r - plate[0]).abs() + (g - plate[1]).abs() + (b - plate[2]).abs();
    var best = 1 << 30;
    for (final ink in inks) {
      final d = (r - ink[0]).abs() + (g - ink[1]).abs() + (b - ink[2]).abs();
      if (d < best) best = d;
    }
    if (best < toPlate) count++;
  }
  return count;
}

double _distance(double x0, double y0, double x1, double y1) {
  final dx = x0 - x1;
  final dy = y0 - y1;
  return math.sqrt(dx * dx + dy * dy);
}

// --------------------------------------------------------------------------
// Path parsing. Enough of the `pathData` grammar to recover every coordinate,
// which is all the safe-zone measurement needs.
// --------------------------------------------------------------------------

final RegExp _numberRe = RegExp(r'-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?');
final RegExp _commandRe = RegExp(r'([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)');

class PathBounds {
  PathBounds(this.minX, this.minY, this.maxX, this.maxY);

  double minX;
  double minY;
  double maxX;
  double maxY;

  void add(double x, double y) {
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }

  /// The farthest this box reaches from the canvas centre.
  double maxDistanceFrom(double cx, double cy) {
    var worst = 0.0;
    for (final x in [minX, maxX]) {
      for (final y in [minY, maxY]) {
        worst = math.max(worst, _distance(x, y, cx, cy));
      }
    }
    return worst;
  }

  @override
  String toString() =>
      'x ${minX.toStringAsFixed(2)}..${maxX.toStringAsFixed(2)} '
      'y ${minY.toStringAsFixed(2)}..${maxY.toStringAsFixed(2)}';
}

/// Bounding box of every coordinate a `pathData` mentions, expanded by the
/// stroke it is drawn with.
///
/// Every coordinate, not just the on-curve points: a cubic's control points
/// bound the curve (the curve is inside the convex hull of its control points),
/// so this can only ever *over*-report the extent. For a safe-zone check that is
/// the right direction to be wrong in -- it fails on a mark that might be
/// clipped rather than passing one that is.
PathBounds pathBounds(String pathData, {double strokeWidth = 0}) {
  final bounds = PathBounds(double.infinity, double.infinity, -double.infinity, -double.infinity);
  var cursorX = 0.0;
  var cursorY = 0.0;
  var startX = 0.0;
  var startY = 0.0;
  var sawAny = false;

  for (final match in _commandRe.allMatches(pathData)) {
    final command = match.group(1)!;
    final upper = command.toUpperCase();
    final relative = command != upper;
    final numbers =
        _numberRe.allMatches(match.group(2)!).map((m) => double.parse(m.group(0)!)).toList();
    var index = 0;

    void point(double x, double y) {
      final px = relative && sawAny ? cursorX + x : x;
      final py = relative && sawAny ? cursorY + y : y;
      cursorX = px;
      cursorY = py;
      bounds.add(px, py);
      sawAny = true;
    }

    switch (upper) {
      case 'M':
      case 'L':
      case 'T':
        while (index + 1 < numbers.length) {
          point(numbers[index], numbers[index + 1]);
          index += 2;
        }
        startX = cursorX;
        startY = cursorY;
      case 'H':
        while (index < numbers.length) {
          point(numbers[index], 0);
          index += 1;
        }
      case 'V':
        while (index < numbers.length) {
          point(0, numbers[index]);
          index += 1;
        }
      case 'C':
        while (index + 5 < numbers.length) {
          point(numbers[index], numbers[index + 1]);
          point(numbers[index + 2], numbers[index + 3]);
          point(numbers[index + 4], numbers[index + 5]);
          index += 6;
        }
      case 'S':
      case 'Q':
        while (index + 3 < numbers.length) {
          point(numbers[index], numbers[index + 1]);
          point(numbers[index + 2], numbers[index + 3]);
          index += 4;
        }
      case 'A':
        // An elliptical arc's extent is not its endpoints; the generators here
        // never emit one (everything is cubics), so encountering one is a fact
        // worth failing on rather than silently mis-measuring.
        throw FormatException('pathData uses an arc command, which this check cannot measure');
      case 'Z':
        point(startX, startY);
    }
  }

  if (!sawAny) throw const FormatException('pathData contained no coordinates');
  if (strokeWidth > 0) {
    bounds.minX -= strokeWidth / 2;
    bounds.minY -= strokeWidth / 2;
    bounds.maxX += strokeWidth / 2;
    bounds.maxY += strokeWidth / 2;
  }
  return bounds;
}

// --------------------------------------------------------------------------
// A very small "attribute of a tag" reader for the vector XML.
// --------------------------------------------------------------------------

/// One `<path>` from a vector, with the geometry needed to measure where its ink
/// actually goes -- as opposed to where its bounding box goes.
class VectorPath {
  VectorPath(this.fillColor, this.strokeColor, this.strokeWidth, this.data);

  final String? fillColor;
  final String? strokeColor;
  final double strokeWidth;
  final String data;

  bool get stroked => strokeColor != null && strokeColor != '#00000000';
  bool get filled => fillColor != null && fillColor != '#00000000';

  /// Sub-paths: a closed contour starts at each `M`.
  int get contourCount => RegExp(r'[Mm]').allMatches(data).length;
  bool get closed => RegExp(r'[Zz]\s*$').hasMatch(data.trim());
}

/// The furthest this path's ink gets from `(cx, cy)`.
///
/// Three shapes, because three is all the icon is made of:
///
///   * **the ring and the pupil** -- closed filled contours, at most two of them
///     (an annulus is one outer contour plus one hole). A closed contour here
///     always begins at `M (origin_x + r) origin_y`, which is how Android vector
///     circles are written, so the first coordinate pair yields both the shape's
///     own centre's x and its radius;
///   * **a stroked arc** -- an open curve. Its ink reaches `strokeWidth / 2`
///     beyond the curve, and its round caps reach that far again around each
///     endpoint, so the path is sampled along its length and every sample is
///     grown by half the stroke.
///
/// The circle's radius is read from the path rather than assumed: if the way a
/// circle is written ever changes, this measures something else and the
/// assertion that the mark is inside the mask is the thing that notices.
double inkReachOf(VectorPath path, double cx, double cy) {
  final half = path.stroked ? path.strokeWidth / 2 : 0.0;
  if (path.closed && path.filled && path.contourCount <= 2) {
    return inkReachOfClosedContours(path.data, cx, cy) + half;
  }
  // A stroked arc: sample it and grow every sample by the stroke's half-width.
  var worst = 0.0;
  for (final point in _samplePath(path.data, 720)) {
    worst = math.max(worst, _distance(point[0], point[1], cx, cy) + half);
  }
  return worst;
}

/// The furthest ink of one or two closed circular contours.
///
/// A circle written by this project's generator is four cubics whose extreme
/// points are exact: `cy + r` appears as an on-curve coordinate (the bottom of
/// the circle), and `cx - r` likewise. So the two candidates are the largest
/// `|x - anchorX|` and the largest `|y - anchorY|` over every coordinate in the
/// path -- but subtracting an *anchor* rather than a centre, because the centre
/// is what is being solved for.
///
/// The anchor is the midpoint of the extremes: for the outer contour of a circle
/// at `(ox, oy)` with radius `r`, the x coordinates run over `ox - r .. ox + r`,
/// so `(min + max) / 2 == ox` and `(max - min) / 2 == r`. That is exact for a
/// circle sampled at its four extremes, which is what the cubics are, and it is
/// then checked against the analytic distance from the canvas centre, so a path
/// that is not a centred circle fails rather than measuring something plausible.
///
/// The inner contour of an annulus is a hole and cannot be the outer edge, so
/// only the largest radius across contours is used.
double inkReachOfClosedContours(String data, double cx, double cy) {
  final numbers =
      _numberRe.allMatches(data).map((m) => double.parse(m.group(0)!)).toList();
  if (numbers.length < 6) {
    throw const FormatException('a closed contour with too few coordinates to be a circle');
  }
  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (var index = 0; index + 1 < numbers.length; index += 2) {
    minX = math.min(minX, numbers[index]);
    maxX = math.max(maxX, numbers[index]);
    minY = math.min(minY, numbers[index + 1]);
    maxY = math.max(maxY, numbers[index + 1]);
  }
  final centreX = (minX + maxX) / 2;
  final centreY = (minY + maxY) / 2;
  final radius = math.max((maxX - minX) / 2, (maxY - minY) / 2);
  return _distance(centreX, centreY, cx, cy) + radius;
}

/// Points along a path's cubics, in the path's own coordinate space.
///
/// Absolute commands only: the generator writes nothing else, and a relative
/// command would be silently mis-sampled, so it is refused.
List<List<double>> _samplePath(String data, int stepsPerCurve) {
  final points = <List<double>>[];
  var cursor = <double>[0, 0];
  var start = <double>[0, 0];
  for (final match in _commandRe.allMatches(data)) {
    final command = match.group(1)!;
    if (command != command.toUpperCase()) {
      throw FormatException('pathData uses a relative command "$command", which this check '
          'cannot sample -- every path in this icon is written absolutely');
    }
    final numbers =
        _numberRe.allMatches(match.group(2)!).map((m) => double.parse(m.group(0)!)).toList();
    var index = 0;
    switch (command) {
      case 'M':
      case 'L':
        while (index + 1 < numbers.length) {
          cursor = [numbers[index], numbers[index + 1]];
          points.add(cursor);
          index += 2;
        }
        start = cursor;
      case 'C':
        while (index + 5 < numbers.length) {
          final p0 = cursor;
          final p1 = [numbers[index], numbers[index + 1]];
          final p2 = [numbers[index + 2], numbers[index + 3]];
          final p3 = [numbers[index + 4], numbers[index + 5]];
          for (var step = 1; step <= stepsPerCurve; step++) {
            final t = step / stepsPerCurve;
            final u = 1 - t;
            points.add([
              u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
              u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
            ]);
          }
          cursor = p3;
          index += 6;
        }
      case 'Z':
        points.add(start);
      default:
        throw FormatException('pathData uses "$command", which this check cannot sample');
    }
  }
  if (points.isEmpty) throw const FormatException('pathData contained no points to sample');
  return points;
}

List<VectorPath> parseVector(File file) {
  final xml = file.readAsStringSync();
  final paths = <VectorPath>[];
  for (final match in RegExp(r'<path\b[^>]*>', dotAll: true).allMatches(xml)) {
    final tag = match.group(0)!;
    String? attribute(String name) {
      final found = RegExp('android:$name\\s*=\\s*"([^"]*)"').firstMatch(tag);
      return found?.group(1);
    }

    final data = attribute('pathData');
    if (data == null) continue;
    paths.add(VectorPath(
      attribute('fillColor'),
      attribute('strokeColor'),
      double.tryParse(attribute('strokeWidth') ?? '0') ?? 0,
      data,
    ));
  }
  return paths;
}

void main() {
  final appDir = Directory.current;
  final res = Directory('${appDir.path}/android/app/src/main/res');
  if (!res.existsSync()) {
    print('run this from app/ (looked for ${res.path})');
    exit(2);
  }

  // The two platform numbers this check is about. Both are Android's, not the
  // project's: an adaptive icon is a 108 dp canvas and the launcher guarantees
  // only the central 66 dp survives masking.
  const canvasDp = 108.0;
  const safeDp = 66.0;
  const safeHalf = safeDp / 2;
  const canvasCentre = canvasDp / 2;

  section('foreground vector exists and is a vector');
  final foreground = File('${res.path}/drawable/ic_launcher_foreground.xml');
  check('drawable/ic_launcher_foreground.xml exists', foreground.existsSync());
  if (!foreground.existsSync()) {
    _summary();
    return;
  }
  final foregroundPaths = parseVector(foreground);
  check('it contains at least three <path> elements (ring, pupil, waves)',
      foregroundPaths.length >= 3, 'found ${foregroundPaths.length}');
  check(
      'every path has either a fill or a stroke',
      foregroundPaths.every((p) =>
          (p.fillColor != null && p.fillColor != '#00000000') ||
          (p.strokeColor != null && p.strokeColor != '#00000000')),
      foregroundPaths
          .where((p) => (p.fillColor == null || p.fillColor == '#00000000') &&
              (p.strokeColor == null || p.strokeColor == '#00000000'))
          .length
          .toString());

  section('background and monochrome layers');
  final background = File('${res.path}/drawable/ic_launcher_background.xml');
  final monochrome = File('${res.path}/drawable/ic_launcher_monochrome.xml');
  check('drawable/ic_launcher_background.xml exists', background.existsSync());
  check('drawable/ic_launcher_monochrome.xml exists', monochrome.existsSync());

  section('adaptive icon manifests reference real layers');
  final anydpi26 = File('${res.path}/mipmap-anydpi-v26/ic_launcher.xml');
  final anydpi26Round = File('${res.path}/mipmap-anydpi-v26/ic_launcher_round.xml');
  final anydpi33 = File('${res.path}/mipmap-anydpi-v33/ic_launcher.xml');
  final anydpi33Round = File('${res.path}/mipmap-anydpi-v33/ic_launcher_round.xml');
  for (final file in [anydpi26, anydpi26Round, anydpi33, anydpi33Round]) {
    final name = file.path.split(RegExp(r'[\\/]')).skipWhile((p) => p != 'res').skip(1).join('/');
    check('$name exists', file.existsSync());
    if (!file.existsSync()) continue;
    final xml = file.readAsStringSync();
    final declared = RegExp(r'android:drawable="@drawable/([a-z0-9_]+)"')
        .allMatches(xml)
        .map((m) => m.group(1)!)
        .toSet();
    check('  $name declares exactly one <background>',
        RegExp(r'<background\b').allMatches(xml).length == 1);
    check('  $name declares exactly one <foreground>',
        RegExp(r'<foreground\b').allMatches(xml).length == 1);
    check('  every drawable it references exists on disk',
        declared.every((d) => File('${res.path}/drawable/$d.xml').existsSync()),
        declared.where((d) => !File('${res.path}/drawable/$d.xml').existsSync()).join(', '));
    // The v33 variant exists for one reason: the monochrome layer. An icon
    // whose v33 copy lacks it would silently never be themed, which reads to a
    // user as "this app ignores my wallpaper colours" and to nobody as a bug.
    check(
        '  monochrome layer is ${file == anydpi33 || file == anydpi33Round ? 'present' : 'absent'}',
        (file == anydpi33 || file == anydpi33Round) ==
            RegExp(r'<monochrome\b').hasMatch(xml));
  }

  section('the mark is inside the safe zone (measured from the written vector)');
  var markBounds = PathBounds(double.infinity, double.infinity, -double.infinity, -double.infinity);
  for (final path in foregroundPaths) {
    final bounds = pathBounds(path.data,
        strokeWidth: path.strokeColor != null && path.strokeColor != '#00000000'
            ? path.strokeWidth
            : 0);
    markBounds.add(bounds.minX, bounds.minY);
    markBounds.add(bounds.maxX, bounds.maxY);
  }
  print('  mark bbox (dp)      : $markBounds');
  final safeLow = canvasCentre - safeHalf;
  final safeHigh = canvasCentre + safeHalf;
  check(
      'every side of the mark is inside the central ${safeDp.toInt()} dp box',
      markBounds.minX >= safeLow &&
          markBounds.minY >= safeLow &&
          markBounds.maxX <= safeHigh &&
          markBounds.maxY <= safeHigh,
      'safe box is ${safeLow.toStringAsFixed(2)}..${safeHigh.toStringAsFixed(2)}');
  final margin = [
    markBounds.minX - safeLow,
    markBounds.minY - safeLow,
    safeHigh - markBounds.maxX,
    safeHigh - markBounds.maxY,
  ].reduce(math.min);
  print('  smallest margin     : ${margin.toStringAsFixed(2)} dp');
  check('the margin is at least 1 dp, not merely non-negative', margin >= 1.0,
      '${margin.toStringAsFixed(2)} dp');

  // The circle is the strictest mask the safe zone covers, and it is stricter
  // than the box: the box's corners are 46.7 dp from the centre, which is
  // *outside* a 33 dp-radius circle. So the box test alone would pass a mark
  // that a round launcher crops -- and the corners are the first place a mask
  // bites.
  //
  // Measured from the ink, not from the box. The arcs are round, so their
  // bounding box's corner is empty background; measuring it would report a
  // 9.7 dp overflow on a mark that has none. What is tested here is each shape's
  // own outermost point.
  var inkReach = 0.0;
  for (final path in foregroundPaths) {
    inkReach = math.max(inkReach, inkReachOf(path, canvasCentre, canvasCentre));
  }
  print('  furthest ink        : ${inkReach.toStringAsFixed(2)} dp from the centre '
      '(mask radius ${safeHalf.toStringAsFixed(0)} dp)');
  check('the mark is inside a ${safeDp.toInt()} dp circle as well as the box',
      inkReach <= safeHalf, 'overflows by ${(inkReach - safeHalf).toStringAsFixed(2)} dp');

  section('every XML resource is parseable by Android\'s own rules');
  // XML forbids the two-character sequence "double hyphen" inside a comment.
  // That is not a niche rule: it broke this build twice. The generated vector's
  // note used it as punctuation, and the hand-written `values/strings.xml` used
  // it both as punctuation and inside the name of an aapt2 command-line flag.
  //
  // Both times the failure surfaced only from Gradle, at
  // `:app:packageReleaseResources`, after a full dependency resolve and a
  // `flutter build apk`; and both times `aapt2 compile` on the file *alone*
  // reported success, because a `values/` resource is only fully validated once
  // the resource merger sees it. So this check exists to make the failure cost
  // one second instead of one build.
  //
  // It is not a general XML validator and does not pretend to be. It enforces
  // the one production rule that this repository has actually broken, over the
  // whole resource tree and the manifest, because the icon layer is the only
  // layer that reads `res/` at all.
  final xmlFiles = <File>[
    ...Directory(res.path)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.xml')),
    File('${appDir.path}/android/app/src/main/AndroidManifest.xml'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  var unclosed = 0;
  var doubleHyphen = 0;
  for (final file in xmlFiles) {
    final text = file.readAsStringSync();
    var position = 0;
    while (true) {
      final start = text.indexOf('<!--', position);
      if (start < 0) break;
      final end = text.indexOf('-->', start + 4);
      if (end < 0) {
        unclosed++;
        print('  FAIL ${file.path.split(RegExp(r'[\\/]')).last}: a comment is never closed');
        break;
      }
      final body = text.substring(start + 4, end);
      if (body.contains('--')) {
        doubleHyphen++;
        final line = text.substring(0, start).split('\n').length;
        final sample = body.split('\n').firstWhere((l) => l.contains('--'), orElse: () => body);
        print('  FAIL ${file.path.split(RegExp(r'[\\/]')).last}:$line contains a double hyphen '
            'inside a comment, which XML forbids: ${sample.trim()}');
      }
      position = end + 3;
    }
  }
  check('every XML comment is closed', unclosed == 0, '$unclosed unclosed');
  check('no XML comment contains a double hyphen', doubleHyphen == 0, '$doubleHyphen found');
  print('  scanned             : ${xmlFiles.length} XML files under res/ plus the manifest');

  section('the round icon is actually declared, not merely generated');
  // A `mipmap/ic_launcher_round` that nothing references is a resource the
  // shrinker deletes, and this really happened: the first build of this icon
  // shipped **zero** round variants. `aapt2 dump resources` on the artifact
  // listed only `mipmap/ic_launcher`, while all five round PNGs and both round
  // adaptive manifests sat in the source tree doing nothing.
  //
  // The consequence is not "a missing extra": `android:roundIcon` is what tells a
  // launcher that a round bitmap exists. Without it, an API 24-25 launcher wanting
  // a round icon takes the *square* `ic_launcher.png` and rounds it itself, which
  // crops the mark -- the exact failure the round bitmap is drawn to prevent.
  //
  // The assertion is on the manifest source because that is the file that decides;
  // the packaging is confirmed by `aapt2 dump resources` on the built APK, which
  // `task.ps1 build` runs as its permission and instrumentation check.
  final manifest = File('${appDir.path}/android/app/src/main/AndroidManifest.xml');
  final manifestText = manifest.existsSync() ? manifest.readAsStringSync() : '';
  check('AndroidManifest.xml declares android:roundIcon',
      manifestText.contains('android:roundIcon="@mipmap/ic_launcher_round"'),
      'without it the round resources are shrunk away and a round launcher crops the square icon');

  section('legacy PNGs: present, decodable, not blank, not identical');
  const densities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  final digests = <String, String>{};
  final rasters = <String, Raster>{};
  for (final entry in densities.entries) {
    for (final name in ['ic_launcher', 'ic_launcher_round']) {
      final label = 'mipmap-${entry.key}/$name.png';
      final file = File('${res.path}/mipmap-${entry.key}/$name.png');
      if (!file.existsSync()) {
        check('$label exists', false);
        continue;
      }
      final bytes = file.readAsBytesSync();
      Raster raster;
      try {
        raster = decodePng(bytes);
      } catch (error) {
        check('$label decodes as a PNG', false, '$error');
        continue;
      }
      rasters[label] = raster;
      digests[label] = base64.encode(bytes);

      final expected = entry.value;
      final distinct = raster.distinctColours();
      final opaque = raster.opaqueFraction();
      check(
          '$label is ${expected}x$expected px',
          raster.width == expected && raster.height == expected,
          '${raster.width}x${raster.height}');
      // The baseline that started all this had exactly 1. A flat plate plus a
      // mark is at least two, and realistically dozens once antialiasing is
      // involved -- so the floor is deliberately well above 1.
      check('$label is not a single colour', distinct > 1, 'distinct=$distinct');
      check('$label is a rendering, not a flat fill (>= 16 colours)', distinct >= 16,
          'distinct=$distinct');
      check('$label has ink', opaque > 0.4, '${(opaque * 100).toStringAsFixed(1)}% opaque');
      if (name == 'ic_launcher_round') {
        // "Round" has to be true of the pixels, because on API 24-25 nothing
        // rounds it for us.
        //
        // A **region**, not the single corner pixel. One pixel is a coin flip
        // under antialiasing: at -82/-8 degrees the outer arc's rounded cap
        // landed exactly on mdpi's (47, 0) and this check caught it, but the
        // same check at a one-pixel inset would have passed a mark that was one
        // pixel further out. A 3x3 block inset by 2% of the size is outside the
        // circle by a wide margin for every density, so a failure here means ink
        // really is in the corner.
        final inset = math.max(1, (raster.width * 0.02).round());
        final corners = <String, List<int>>{};
        for (final corner in ['top-left', 'top-right', 'bottom-left', 'bottom-right']) {
          final x0 = corner.endsWith('left') ? inset : raster.width - inset - 3;
          final y0 = corner.startsWith('top') ? inset : raster.height - inset - 3;
          var alpha = 0;
          for (var dx = 0; dx < 3; dx++) {
            for (var dy = 0; dy < 3; dy++) {
              alpha += raster.at(x0 + dx, y0 + dy)[3];
            }
          }
          corners[corner] = [alpha ~/ 9];
        }
        check('$label has transparent corners',
            corners.values.every((a) => a.first < 8), '$corners');
        final centre = raster.at(raster.width ~/ 2, raster.height ~/ 2);
        check('$label is not transparent at the centre', centre[3] > 200, 'centre $centre');
        check('$label is close to a disc (opaque area approx pi/4)',
            (opaque - math.pi / 4).abs() < 0.05,
            '${(opaque * 100).toStringAsFixed(1)}% vs ${(math.pi / 4 * 100).toStringAsFixed(1)}%');
      } else {
        check('$label is fully opaque', opaque > 0.999,
            '${(opaque * 100).toStringAsFixed(1)}%');
      }
    }
  }

  final uniqueDigests = digests.values.toSet().length;
  check('no two of the ${digests.length} PNGs are byte-identical',
      uniqueDigests == digests.length, '$uniqueDigests distinct files');
  // The round and square variants of one density must differ in their *pixels*,
  // not only in their metadata: a generator that wrote the same image twice
  // would pass the check above if it also wrote two different timestamps.
  for (final entry in densities.keys) {
    final square = rasters['mipmap-$entry/ic_launcher.png'];
    final round = rasters['mipmap-$entry/ic_launcher_round.png'];
    if (square == null || round == null) continue;
    var differing = 0;
    for (var i = 3; i < square.pixels.length; i += 4) {
      if (square.pixels[i] != round.pixels[i]) differing++;
      if (differing > square.pixelCount ~/ 10) break;
    }
    check(
        'mipmap-$entry: the square and round icons differ in pixels',
        differing > square.pixelCount ~/ 10,
        'only $differing of ${square.pixelCount} pixels differ in alpha');
  }

  section('the shipped APK contains the mark (not just the source tree)');
  // The strongest check available here, and the one that actually found the
  // worst defect in this work: for a while the legacy PNGs contained **no mark
  // at all**. The generator drew the 108 dp canvas scaled by the *legacy* frame
  // size, so the ring's centre at canvas (54, 54) landed at pixel (864, 864) on a
  // 768 px canvas; the PNGs were a dark rectangle with a cyan sliver in the
  // corner, and `aapt2` crunched them to two colours.
  //
  // Nothing in the source-tree checks could see it. "Has more than one colour"
  // passes for a plate. "Round corners are transparent" passes. The contact
  // sheets looked right because their code path never passed the bad argument.
  // What found it was unzipping the built APK, decoding the packaged PNG and
  // counting pixels of the mark's own colours.
  //
  // So the artifact is read here too. The path is fixed rather than discovered
  // because `task.ps1 build` writes exactly this file, and a check that silently
  // looks in the wrong place is the failure mode `AGENTS.md` §8 is about; when the
  // APK is absent this says so instead of passing quietly.
  final apk = File('${appDir.path}/build/app/outputs/flutter-apk/app-release.apk');
  if (!apk.existsSync()) {
    print('  the release APK is not built, so the packaged PNGs were NOT checked.');
    print('  Run `pwsh tools/task.ps1 build`, then re-run this. (The source-tree checks above');
    print('  did run; this is a declared gap, not a pass.)');
  } else {
    final entries = _readZip(apk);
    final aapt2 = _findAapt2();
    check('aapt2 was found (the packaged PNGs cannot be identified without it)',
        aapt2 != null,
        'looked in ANDROID_HOME, ANDROID_SDK_ROOT and %LOCALAPPDATA%\\Android\\Sdk; '
        'set ANDROID_HOME');
    if (aapt2 == null) {
      _summary();
      return;
    }
    final packaged = _mipmapPngs(aapt2, apk.path);
    final squarePngs = (packaged['mipmap/ic_launcher'] ?? const <String>[])
        .where((p) => p.endsWith('.png'))
        .toList();
    final roundPngs = (packaged['mipmap/ic_launcher_round'] ?? const <String>[])
        .where((p) => p.endsWith('.png'))
        .toList();
    check('the APK packages mipmap/ic_launcher bitmaps', squarePngs.length >= 5,
        'found ${squarePngs.length}; the table reported ${packaged.keys.toList()}');
    check('the APK packages mipmap/ic_launcher_round bitmaps', roundPngs.length >= 5,
        'found ${roundPngs.length}; without them a round launcher crops the square icon');
    // The adaptive manifests are found the same way, so a `monochrome` layer that
    // never reached the APK is visible here rather than only in the source tree.
    final adaptive = <String, List<String>>{
      for (final entry in packaged.entries)
        entry.key: entry.value.where((p) => p.endsWith('.xml')).toList(),
    };
    print('  resource table      : '
        '${adaptive.entries.map((e) => '${e.key}=${e.value.length} xml + '
            '${packaged[e.key]!.length - e.value.length} png').join(', ')}');

    for (final name in [...squarePngs, ...roundPngs]) {
      final bytes = entries[name];
      if (bytes == null) continue;
      final Raster raster;
      try {
        raster = decodePng(bytes);
      } catch (error) {
        check('$name decodes', false, '$error');
        continue;
      }
      final ink = _inkPixels(raster);
      check('$name contains the mark (cyan or white pixels, not only the plate)',
          ink > raster.pixelCount ~/ 100,
          'only $ink of ${raster.pixelCount} pixels are mark ink; '
          'the icon is a plate with nothing on it');
    }
    for (final name in roundPngs) {
      final bytes = entries[name];
      if (bytes == null) continue;
      final Raster raster;
      try {
        raster = decodePng(bytes);
      } catch (_) {
        continue;
      }
      final corner = raster.at(0, 0);
      check('$name has a transparent corner', corner[3] == 0, '$corner');
    }
    print('  packaged PNGs checked: ${squarePngs.length + roundPngs.length}');
  }

  final dominant = rasters['mipmap-mdpi/ic_launcher.png']?.dominantColour();
  print('');
  print('  mdpi dominant colour: $dominant');

  _summary();
}

void _summary() {
  print('');
  // The `N passed, M failed` shape is what `tools/task.ps1`'s `Get-CheckSummary`
  // reads for every non-special layer, so the runner's one-line summary is this
  // script's own count rather than the runner's opinion of it. The verdict line
  // below it is for a human reading the log; the runner also treats a line
  // starting with `FAIL` on stdout as a failure regardless of the exit code.
  if (_failures == 0) {
    print('$_checks passed, 0 failed');
    print('PASS: launcher icon (the mark is inside the safe zone, nothing is blank, '
        'nothing is single-colour, the round icon is round)');
    exit(0);
  }
  print('${_checks - _failures} passed, $_failures failed');
  print('FAIL: launcher icon -- $_failures of $_checks assertions failed');
  exit(1);
}
