import '../transport/album.dart';
import 'sync_ledger.dart';

/// Groups a RAW and its JPEG sibling into a single user-visible asset.
///
/// ## Why this matters
///
/// Showing the user two rows for one shutter press is wrong in three separate ways:
///
/// * the album count doubles, so "12 photos" is a lie;
/// * progress accounting counts one shot twice, so a sync looks half as far
///   along as it is;
/// * selecting the shot means selecting two things, and deleting one leaves the
///   other orphaned.
///
/// It is also where the album's **order** is decided. `GetFileList` returns a
/// ring, not a sequence (measured; see [compareGroupsNewestFirst]), so
/// [groupAssets] sorts what it groups. Nothing downstream re-sorts.
///
/// ## How the camera actually reports a pair — corrected by measurement
///
/// This file used to say a RAW+JPEG shot "appears in `GetFileList` as **two entries** —
/// one `rawJpeg` and one `raw`, or a `picture` plus a `raw`". **That is not what the
/// firmware does.** Measured on the real 3.1-cn body (`analysis/50`): the listing
/// returns **one entry per shutter press** — 25 entries for 25 files — and a pair is a
/// single entry whose `path` ends **`.JPG`** and whose `filetype` is **`rawJpeg`**. No
/// `.DNG` is listed at all.
///
/// So the pairing is not "find two entries that match": it is **derive the RAW from the
/// JPEG**, which is what [AlbumFile.rawSibling] does. The second entry that the old
/// rule looked for does not exist, which is why **no RAW has ever been synced** — the
/// code was waiting for a listing the camera never sends.
///
/// The RAW can only be fetched at `FileResolution.original` (see [AlbumFile.rawSibling]),
/// and it is **opt-in** because 18 of them is ~574 MB.
class AssetGroup {
  /// The JPEG (or the stand-in when there is no JPEG), which is what the user
  /// sees first and what transfers first.
  final AlbumFile primary;

  /// The RAW sibling, when there is one.
  final AlbumFile? raw;

  /// True when [primary] is actually the RAW, i.e. this shot has no JPEG.
  bool get isRawOnly => raw == null && primary.isRaw;

  /// True when this shot has both renditions.
  ///
  /// The one spelling of that fact. `needsRaw` used to sit beside it with a
  /// byte-identical body and a different reading ("the shot is incomplete until the
  /// RAW arrives"), which is how one fact becomes two names and then two meanings —
  /// `analysis/79` §17. What the "still waiting" question actually needs is
  /// [rawPending], which asks the ledger rather than the group.
  bool get isPair => raw != null;

  /// Everything that has to be transferred for this shot.
  ///
  /// Every rendition, regardless of policy — it answers "what is this shot made of",
  /// which is what `album_delete.dart` and `AppState.localIdsFor` ask. **What to
  /// *queue* is a different question with a different answer**, and it is
  /// [plannedQueue]: the RAW is ~32 MB against the JPEG's ~4.9 MB, so whether it rides
  /// along is the user's opt-in and not a property of the shot.
  List<AlbumFile> get assets => [primary, if (raw != null) raw!];

  AssetGroup(this.primary, [this.raw]);

  /// The shot's capture instant, as the order is decided.  Null when the
  /// listing did not carry a usable date.
  DateTime? get captureTime => primary.captureTime;

  /// The filename the tie-break compares.  Not the full path: two folders can
  /// hold the same basename (`100YICAM` and `101YICAM` both exist on the test
  /// card), and the folder says nothing about which shot came first.
  String get sortName => primary.fileName;

  /// A stable identity for the whole shot.
  ///
  /// Derived from the primary asset so that it does not change when the RAW
  /// arrives — otherwise the item would appear to be replaced mid-sync.
  AssetId get id => assetIdOf(primary);

  /// A short label for the badge on the album tile.
  String get badge {
    if (isPair) return 'RAW+JPG';
    if (isRawOnly) return 'RAW';
    if (primary.isVideo) return 'VIDEO';
    return '';
  }

  /// Whether the RAW is still outstanding, for the "RAW pending" badge.
  ///
  /// [synced] answers "is this asset already on the phone" — the ledger is the only
  /// thing that knows, which is why it is passed in rather than guessed at from the
  /// queue. A shot with no RAW is never pending.
  ///
  /// ## The caller still has to say whether the RAW is *coming*
  ///
  /// This answers "the RAW is not here". It deliberately does not answer "and it is on
  /// its way": a RAW the policy is not fetching will never arrive, and a badge that
  /// claimed otherwise would sit on every pair tile forever. The album page combines
  /// the two — see `_rawWaiting` in `ui/pages/album_page.dart`, which is the only
  /// caller and has the switch and the queue in hand.
  bool rawPending(bool Function(AlbumFile) synced) =>
      raw != null && !synced(raw!);

  @override
  String toString() => 'AssetGroup(${primary.path}${raw == null ? '' : ' + raw'})';
}

/// Compare two groups into **newest first**, with a tie-break that cannot move.
///
/// ## Why the order is computed rather than inherited
///
/// `GetFileList` does **not** return the album in capture order. Measured on the
/// real 3.1-cn body with 99 files (`analysis/61` §8): the first entry was
/// `P9150040.JPG` and the last was `P9150039.JPG` — a lower number, so the
/// listing **wraps**. It is a ring buffer, not a sequence, and it is neither
/// capture order nor filename order. The page used to append it verbatim
/// (`album_page.dart` `_loadPage`), so the album grid showed whatever the
/// firmware felt like returning, and the maintainer **nearly deleted the wrong
/// photo** by trusting "the first six entries are the newest".
///
/// So the order is derived here, in the Flutter-free layer, once per listing —
/// not re-sorted on every build by the page.
///
/// ## The key, and why it is two keys
///
/// 1. **`captureTime`, descending.** The camera's own instant, which is what the
///    tile already draws (`album_page.dart` `_tile`). Newest first, because that
///    is what every phone gallery does and what "the photo I just took" needs.
///
/// 2. **Filename, descending — the tie-break, and it is not decoration.** The
///    timestamps are **whole seconds** and a **burst is several frames inside one
///    second** (`analysis/`, burst work), so a time-only sort leaves those frames
///    tied, and a tied sort is free to return them in whatever order the input
///    happened to be in — i.e. the ring order, which is exactly the thing that
///    changes between listings. The frames of one burst would then **shuffle on
///    every reload**. The filename is the camera's own monotonic numbering
///    (`P9150099` follows `P9150098`), it is stable across listings, and
///    descending puts the last frame of the burst first. It is compared as a
///    plain string, which is correct **because** the camera zero-pads to a fixed
///    width — `P9150099` really does sort above `P9150100`.
///
///    (A plain string compare would be wrong for a camera that did not pad; this
///    one does, and the check in `tool/verify_sync.dart` pins it with a
///    roll-over pair.)
///
/// ## A missing capture time sorts **last**, not first
///
/// The listing carries `date` as a string and a firmware that answers `0` or
/// nothing leaves [AssetGroup.captureTime] null — the tile already handles that
/// by drawing the filename instead (`album_page.dart`). Sorting those on `0`
/// would put them at the **bottom of a descending list as if they were shot in
/// 1970**, and on an ascending one it would put them at the top as if they were
/// the newest thing on the card. Neither is a claim the listing supports, so
/// undated entries are placed after every dated one and ordered among themselves
/// by the same filename rule, which keeps the whole order total.
int compareGroupsNewestFirst(AssetGroup a, AssetGroup b) {
  final ta = a.captureTime?.millisecondsSinceEpoch;
  final tb = b.captureTime?.millisecondsSinceEpoch;
  if (ta != tb) {
    if (ta == null) return 1;
    if (tb == null) return -1;
    return tb.compareTo(ta);
  }
  return b.sortName.compareTo(a.sortName);
}

/// The listed order this app shows, newest first — see [compareGroupsNewestFirst].
List<AssetGroup> sortedByCapture(List<AssetGroup> groups) =>
    groups.toList()..sort(compareGroupsNewestFirst);

/// Group a flat listing into one entry per shutter press, newest first.
///
/// ## Two shapes, and both must work
///
/// * **What the real firmware sends** — one `rawJpeg` entry whose path is a `.JPG`.
///   The RAW is not in the listing; it is *derived* by [AlbumFile.rawSibling], so the
///   group is formed from a single element. This is the case that was missing, and its
///   absence is why no RAW had ever been queued.
/// * **Two entries with the same basename and second** — one JPEG, one RAW. Kept
///   because it is cheap, it is what the fake camera fixture emits, and a firmware that
///   does list both would otherwise silently produce two rows per shot again.
///
/// ## The order is **not** preserved, and that is the fix
///
/// This function used to promise "order is preserved: the first appearance of a
/// shot determines its position, so grouping never reorders the album", and it
/// kept that promise. The promise was the defect: the order it preserved is a
/// **ring** (see [compareGroupsNewestFirst]), so the grid was an arbitrary
/// rotation of the card. Grouping now returns the listing sorted newest-first by
/// capture time with the filename as the tie-break.
///
/// A fixture ordered so the camera's ring order is *not* capture order is what
/// makes this checkable; `tool/verify_sync.dart` uses the measured one.
List<AssetGroup> groupAssets(List<AlbumFile> files) {
  final out = <AssetGroup>[];
  // Index of an already-created group by pairing key.
  final index = <String, int>{};

  for (final f in files) {
    // A `rawJpeg` entry is a complete shot on its own: the JPEG that is listed, plus
    // the RAW derived from it. It never needs a second entry to pair with.
    final derived = f.rawSibling;
    if (derived != null) {
      index[_pairKey(f)] = out.length;
      out.add(AssetGroup(f, derived));
      continue;
    }

    final key = _pairKey(f);
    final at = index[key];
    if (at == null) {
      index[key] = out.length;
      out.add(AssetGroup(f));
      continue;
    }

    final g = out[at];
    // Two entries with the same basename and timestamp: one is the JPEG and one
    // is the RAW. Decide which is which without assuming the order they arrive
    // in — the listing has been observed to put either first.
    if (f.isRaw && !g.primary.isRaw) {
      out[at] = AssetGroup(g.primary, f);
    } else if (!f.isRaw && g.primary.isRaw) {
      out[at] = AssetGroup(f, g.primary);
    }
    // Anything else (e.g. two JPEGs with the same name in different folders
    // cannot reach here, because the key includes the folder) is left alone
    // rather than guessed at.
  }
  return sortedByCapture(out);
}

/// The identity the ledger and the queue file [f] under.
///
/// `path` plus the capture **second**, because the camera's date is second-resolution
/// and the filename repeats across folders. One spelling of the conversion, so a
/// ledger written from one call site is readable from another: a mismatch here is
/// silent in both directions — a file that looks unsynced forever, or a queued item the
/// ledger cannot find.
AssetId assetIdOf(AlbumFile f) => AssetId(
      path: f.path,
      dateSeconds: f.captureTime?.millisecondsSinceEpoch != null
          ? f.captureTime!.millisecondsSinceEpoch ~/ 1000
          : 0,
    );

/// The files a queue action adds for [groups], under [plan].
///
/// This is the **only** place the UI layer builds a queue, and [plan] is where the RAW
/// decision is taken. It exists because that decision was documented and never
/// implemented: `transport/album.dart` says RAW transfer ships off, while every queue
/// path enqueued `AssetGroup.assets` — `[primary, raw!]` — so one tap on a `rawJpeg`
/// shot queued the ~32 MB `.DNG` beside the measured 4.9 MB JPEG the user was thinking about
/// (`analysis/79`, finding #2). A single function means the next call site cannot
/// forget.
///
/// ## Why only the RAW is taken from [plan]
///
/// `SyncPlan.wants` also carries `since` and `skipVideos`, and neither is applied here,
/// deliberately:
///
/// * a queue action runs over shots the **user named** (a selection, the viewer's save
///   button) or over a page an **automatic mode already accepted** (`enqueueBrowsed`).
///   A video the user picked, or one the mode they chose decides to take, must not be
///   silently dropped by a size filter neither of them agreed to;
/// * `since` is a "sync what I shot after this" bound, and nothing in this app offers
///   it yet — there is no such control, so there is nothing for it to filter.
///
/// ## Why the RAW is decided per **shot** and not per file
///
/// Because a `.DNG` is two different things depending on what it is attached to. Beside
/// a JPEG it is the ~32 MB upgrade the opt-in is about. As the **only** file of a
/// shutter press (`AssetGroup.isRawOnly`, a listing that reports `filetype: 'raw'` with
/// no JPEG) it *is* the photo, and [plan]'s file-level `wants` would refuse it — leaving
/// a shot that can never be synced, with a `RAW` badge on the tile and no way for the
/// user to tell why. So the primary of every shot is queued and only the derived sibling
/// is put to the plan.
List<AlbumFile> plannedQueue(List<AssetGroup> groups, SyncPlan plan) => [
      for (final g in groups) ...[
        g.primary,
        if (g.raw != null && plan.wants(g.raw!)) g.raw!,
      ],
    ];

/// Folder + basename + capture second.
///
/// The folder is included because `100YICAM` and `101YICAM` both exist on the
/// test card and can hold the same basename.
String _pairKey(AlbumFile f) {
  final slash = f.path.lastIndexOf('/');
  final dir = slash < 0 ? '' : f.path.substring(0, slash);
  var base = slash < 0 ? f.path : f.path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  final secs = f.captureTime?.millisecondsSinceEpoch != null
      ? f.captureTime!.millisecondsSinceEpoch ~/ 1000
      : 0;
  return '$dir/$base|$secs';
}
