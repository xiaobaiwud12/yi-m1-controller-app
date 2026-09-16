/// The date a gallery will **display** for a synced photo, as opposed to the date
/// the app writes into MediaStore's columns.
///
/// ## The defect this exists for
///
/// A photo the app displays as **18:40** — correct, because the app renders the
/// camera's `date` field in the phone's own zone — read **10:40** once it was on
/// the phone. Eight hours, which is the offset of the phone that reported it.
///
/// Every date the app itself hands to Android was already right: `DATE_ADDED`,
/// `DATE_MODIFIED` and `DATE_TAKEN` are epoch seconds, so a gallery that *sorts*
/// by date comes out correct — which is what an earlier round measured before it
/// withdrew a `date_taken` claim. **Sorting is not display.** What a gallery
/// shows as the capture time, and what MediaProvider re-derives `DATE_TAKEN` from
/// when the pending row is published, is the date **inside the file**.
///
/// ## Why the date inside the file is wrong, and in which direction
///
/// * **EXIF has no timezone field.** `DateTime` / `DateTimeOriginal` /
///   `DateTimeDigitized` are the camera's *local wall clock*, a naive
///   `YYYY:MM:DD HH:MM:SS` string, and every consumer — Android's
///   `ExifInterface`, MediaProvider's `DATE_TAKEN` derivation, a desktop viewer —
///   reads it in the zone of whoever is looking. [V]
/// * **The body has no timezone either.** The firmware image contains exactly one
///   timezone name, `GMT`, with no offset table and no DST logic
///   (`analysis/_frag-clock.md` §D.5, negative result across three images). The
///   RTC is set from the app's BLE time-sync, which sends Unix epoch seconds
///   (`wire_format.dart`, verified against the official app). So the clock reads
///   the true instant and its naive date fields are formatted as GMT — the **UTC
///   wall clock**. [V-]
/// * **Measured on a real body.** `app/capture_test/probe_original.jpg`, an
///   `Original` fetched from the 3.1-cn camera, carries three date fields —
///   IFD0 `0x0132` and ExifIFD `0x9003` / `0x9004`, each ASCII count 20 — and all
///   three read `2026:09:14 00:49:06`, i.e. the same instant its `date` field
///   names, rendered in GMT rather than in the zone of the phone that fetched it.
///   [V] for the three fields and the shared value; [V-] for the zone, since no
///   independent wall-clock reference was recorded in that session.
///
/// So on a phone at +08:00 the app shows `18:40` and the file says `10:40`, and
/// the gallery believes the file.
///
/// ## What this does about it
///
/// It rewrites the three date fields **in place** to the local wall clock of the
/// capture instant — the very time the app displayed — so that every consumer,
/// whatever tag it prefers and whatever arithmetic it uses, arrives back at the
/// instant the app already had right.
///
/// The rewrite is **fixed length**: nineteen characters for nineteen characters,
/// inside a field that already holds nineteen. Nothing moves, no offset in the
/// TIFF structure changes, no image data is decoded and no thumbnail is
/// regenerated. That is what makes it defensible where "rewrite the metadata" is
/// normally the start of ruining a photo: the alternative (`DATE_TAKEN` alone)
/// cannot work, because MediaProvider derives that column from this same EXIF and
/// ignores the value it is given (measured: `analysis/44` §4).
///
/// ## The one thing it will not do
///
/// Nothing is written unless the existing field is already a plausible date — or
/// blank — **and** the tag is ASCII **and** the field is the EXIF standard's 20
/// bytes with its NUL terminator **and** the characters lie inside the APP1
/// segment that declared them. A file whose structure disagrees with any of that
/// is returned **unchanged**, because a photo with an eight-hour-old date is a
/// nuisance whereas a photo with a rewritten entropy-coded section is a lost
/// photo.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What [stampExifWallClock] did.
class ExifDateStamp {
  /// The bytes to publish.
  ///
  /// The same instance that was passed in when nothing was rewritten, so an
  /// untouched file is handed on without a copy of a 32 MB RAW.
  final Uint8List bytes;

  /// How many date fields now carry the capture instant.
  final int fields;

  /// How many candidate fields were found and **refused** — wrong type, a count
  /// that is not the standard 20, no NUL terminator, a value that is neither a
  /// date nor blank, or a value outside the segment that declared it.
  final int refused;

  /// Why no field was rewritten, or null when [fields] is greater than zero.
  final String? note;

  const ExifDateStamp({
    required this.bytes,
    required this.fields,
    this.refused = 0,
    this.note,
  });

  bool get changed => fields > 0;

  @override
  String toString() => changed
      ? 'ExifDateStamp($fields field(s) stamped)'
      : 'ExifDateStamp(unchanged: $note)';
}

/// The EXIF `DateTime` tag in IFD0.
const int _tagDateTime = 0x0132;

/// The pointer from IFD0 to the Exif sub-IFD.
const int _tagExifIfd = 0x8769;

/// `DateTimeOriginal`, the tag a gallery prefers when it is present.
const int _tagDateTimeOriginal = 0x9003;

/// `DateTimeDigitized`.
const int _tagDateTimeDigitized = 0x9004;

/// `YYYY:MM:DD HH:MM:SS` — nineteen characters, and what EXIF stores plus a NUL.
const int _stampLength = 19;

/// The ASCII `count` the EXIF specification gives a date field: 19 + NUL.
const int _stampFieldBytes = 20;

/// Rewrite the EXIF date fields in [bytes] to the **local** wall clock of
/// [capturedAt], so that a gallery on this phone shows the time the app showed.
///
/// Returns the input unchanged (and says why in [ExifDateStamp.note]) when there
/// is no capture instant, when the instant looks like a broken clock, when there
/// is no EXIF, or when no date field passed the checks in [ExifDateStamp.refused].
///
/// **[capturedAt] is the instant, not a wall clock.** The zone conversion happens
/// here, from `toLocal()`, because the value that belongs in an EXIF date field is
/// by definition the wall clock of the device that owns the file — and the phone
/// the photo is being saved to is that device. The alternative reading, "write the
/// UTC wall clock", is the defect this function exists to remove: [capturedAt] and
/// the string written are two different values, and conflating them is exactly
/// what happened on the camera side.
ExifDateStamp stampExifWallClock(Uint8List bytes, DateTime? capturedAt) {
  if (capturedAt == null) {
    return ExifDateStamp(bytes: bytes, fields: 0, note: 'no capture instant');
  }
  final local = capturedAt.toLocal();
  // The same floor `MediaStoreSink` applies before it dates a file: a camera that
  // does not know the time reports 0, and stamping 1970 over a real photo's
  // metadata replaces one wrong date with a worse one — a wrong date looks like a
  // wrong date, whereas 1970 looks deliberate.
  //
  // The ceiling is not cosmetic either: `YYYY` is four characters in this field, so
  // a five-digit year would make the string twenty bytes and the fixed-length write
  // below impossible. A clock that far out is broken in the same way as one at zero,
  // and is refused rather than allowed to reach a `setRange` that would throw in the
  // middle of publishing a photo.
  if (local.year < 1990 || local.year > 9999) {
    return ExifDateStamp(
      bytes: bytes,
      fields: 0,
      note: 'the capture instant (${local.toIso8601String()}) looks like a broken '
          'clock, so no field was overwritten',
    );
  }

  final found = _dateFields(bytes);
  if (found.fields.isEmpty) {
    return ExifDateStamp(
      bytes: bytes,
      fields: 0,
      refused: found.refused,
      note: found.exifAt == null
          ? 'no EXIF segment to correct'
          : 'no EXIF date field passed its checks (${found.refused} candidate(s))',
    );
  }

  final text = ascii.encode(_format(local));
  final out = Uint8List.fromList(bytes);
  for (final f in found.fields) {
    out.setRange(f, f + _stampLength, text);
  }
  return ExifDateStamp(bytes: out, fields: found.fields.length, refused: found.refused);
}

/// `YYYY:MM:DD HH:MM:SS`, the only shape an EXIF date field may take.
String _format(DateTime t) {
  String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
  return '${p(t.year, 4)}:${p(t.month)}:${p(t.day)} '
      '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

/// Where the EXIF date fields are, and what was refused on the way to finding them.
class _DateFields {
  /// Offsets of the first character of each field that may be overwritten.
  final List<int> fields;
  final int refused;

  /// The TIFF header's offset when an EXIF segment was found at all; null when the
  /// buffer carries none, which is a different report to the user of this class
  /// than "it has one and nothing in it was safe".
  final int? exifAt;

  const _DateFields(this.fields, this.refused, this.exifAt);
}

_DateFields _dateFields(Uint8List b) {
  final exif = _findExif(b);
  if (exif == null) return const _DateFields([], 0, null);
  final tiff = exif.tiffAt;
  final limit = exif.limit;
  if (tiff < 0 || tiff + 8 > limit) return _DateFields(const [], 0, tiff);

  final le = b[tiff] == 0x49 && b[tiff + 1] == 0x49;
  final be = b[tiff] == 0x4D && b[tiff + 1] == 0x4D;
  if (!le && !be) return _DateFields(const [], 0, tiff);
  if (_u16(b, tiff + 2, le) != 42) return _DateFields(const [], 0, tiff);

  final fields = <int>[];
  var refused = 0;
  final visited = <int>{};

  void walk(int ifd, Set<int> wanted, {required bool followExifIfd}) {
    if (ifd <= 0 || ifd + 2 > limit || !visited.add(ifd)) return;
    final n = _u16(b, ifd, le);
    // A real IFD has tens of entries. A wild count means the structure is not what
    // it claims, and walking it would be reading offsets the file does not own.
    if (n > 256) return;
    for (var i = 0; i < n; i++) {
      final e = ifd + 2 + i * 12;
      if (e + 12 > limit) return;
      final tag = _u16(b, e, le);
      if (wanted.contains(tag)) {
        final at = _asciiValueAt(b, e, tiff, limit);
        if (at != null &&
            at + _stampFieldBytes <= limit &&
            b[at + _stampLength] == 0 &&
            _looksLikeDateOrBlank(b, at)) {
          if (!fields.contains(at)) fields.add(at);
        } else {
          refused++;
        }
      } else if (tag == _tagExifIfd && followExifIfd) {
        walk(tiff + _u32(b, e + 8, le), {_tagDateTimeOriginal, _tagDateTimeDigitized},
            followExifIfd: false);
      }
    }
  }

  walk(tiff + _u32(b, tiff + 4, le), {_tagDateTime}, followExifIfd: true);
  return _DateFields(fields, refused, tiff);
}

/// The offset of an entry's ASCII value, or null when the entry is not a
/// well-formed 20-byte ASCII field.
///
/// The type is checked here rather than by the caller because writing nineteen
/// bytes into a field another type declared is how a metadata rewrite corrupts a
/// file: a `count` of 20 on a `SHORT` is 40 bytes, and on a `RATIONAL` it is 160.
int? _asciiValueAt(Uint8List b, int entry, int tiff, int limit) {
  final le = b[tiff] == 0x49 && b[tiff + 1] == 0x49;
  const asciiType = 2;
  if (_u16(b, entry + 2, le) != asciiType) return null;
  if (_u32(b, entry + 4, le) != _stampFieldBytes) return null;
  // Twenty bytes never fit in the entry's four-byte value slot, so the value is
  // always out of line; a file that puts it inline is not a file this understands.
  final at = tiff + _u32(b, entry + 8, le);
  if (at < 0 || at >= limit) return null;
  return at;
}

/// Whether the nineteen bytes at [at] are a date, or an empty field.
///
/// The blank case is allowed deliberately: a body whose clock was never set writes
/// zeros, and replacing a blank field with the capture instant the app is holding
/// is the whole point. Anything that is *neither* a date nor blank is not a field
/// this may write into, because there is no way to tell what it is for.
bool _looksLikeDateOrBlank(Uint8List b, int at) {
  // A body whose clock was never set writes zeros into these fields. Checked
  // first, because such a field has no separators either and would otherwise be
  // refused by the shape test below.
  var blank = true;
  for (var i = 0; i < _stampLength && blank; i++) {
    final c = b[at + i];
    blank = c == 0x00 || c == 0x20;
  }
  if (blank) return true;

  var digits = 0;
  for (var i = 0; i < _stampLength; i++) {
    final c = b[at + i];
    // `YYYY:MM:DD HH:MM:SS` — colons at 4, 7, 13 and 16; a space at 10. The two
    // in the time half are easy to miss, and missing them refuses every field the
    // camera actually writes.
    if (i == 4 || i == 7 || i == 13 || i == 16) {
      if (c != 0x3A) return false; // ':'
      continue;
    }
    if (i == 10) {
      if (c != 0x20) return false; // ' '
      continue;
    }
    if (c < 0x30 || c > 0x39) return false;
    digits++;
  }
  return digits == 14;
}

/// The EXIF segment's TIFF header, and the offset its structures must stay below.
class _Exif {
  final int tiffAt;

  /// The end of the APP1 segment that declared it — or the end of the file for a
  /// bare TIFF (a DNG).
  ///
  /// Bounded on purpose: a malformed entry whose value offset points past the
  /// segment would otherwise have nineteen bytes written into whatever happens to
  /// be there, which for a JPEG means the compressed image data.
  final int limit;

  const _Exif(this.tiffAt, this.limit);
}

/// Find the EXIF/TIFF header in [b], or null.
///
/// Two container shapes are handled, and nothing else: a JPEG, whose EXIF lives in
/// an `APP1` segment, and a bare little- or big-endian TIFF, which is what the
/// camera's `.DNG` files are. Anything else — video, PNG, an unknown extension —
/// answers null and is published exactly as it arrived.
_Exif? _findExif(Uint8List b) {
  if (b.length >= 4 && b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) {
    return _Exif(0, b.length);
  }
  if (b.length >= 4 && b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A) {
    return _Exif(0, b.length);
  }
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;

  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null; // out of step with the marker structure
    final marker = b[i + 1];
    // Standalone markers carry no length: padding, and the restart markers.
    if (marker == 0xFF || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    // The scan starts here: no EXIF segment, or none before the image data.
    if (marker == 0xDA || marker == 0xD9) return null;
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) return null;
    if (marker == 0xE1 &&
        len >= 8 &&
        b[i + 4] == 0x45 && // 'E'
        b[i + 5] == 0x78 && // 'x'
        b[i + 6] == 0x69 && // 'i'
        b[i + 7] == 0x66 && // 'f'
        b[i + 8] == 0 &&
        b[i + 9] == 0) {
      return _Exif(i + 10, i + 2 + len);
    }
    i += 2 + len;
  }
  return null;
}

int _u16(Uint8List b, int o, bool le) {
  if (o < 0 || o + 2 > b.length) return 0;
  return le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1];
}

int _u32(Uint8List b, int o, bool le) {
  if (o < 0 || o + 4 > b.length) return 0;
  return le
      ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
      : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
}
