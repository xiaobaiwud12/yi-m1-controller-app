/// Deleting photos on the camera's card — table stake T17.
///
/// The command itself is one line; everything hard about this file is what
/// surrounds it, and each piece exists because of a measured fact about the
/// firmware rather than a taste in UI:
///
/// * **`DeleteFile` takes at most 30 paths per call.** The handler clamps with
///   `cmp r0,#0x1e / movgt r0,#0x1e` (`text+0x153290`), so a 40-path request is
///   accepted and 10 paths are dropped. The official app sends the whole
///   selection and lets that happen. Here the list is chunked, and a chunk is
///   only ever as large as the firmware can actually carry.
/// * **The camera answers `200` to work it did not do.** This is the same
///   behaviour the rest of the app already designs around (`AppState.send` does
///   not treat `ok` as proof a command landed, and `SyncEngine` re-reads state
///   rather than trusting a status code). A delete is the worst place to forget
///   it: "Deleted 12 photos" when 12 files are still on the card is how a user
///   clears a card that is not clear. So the outcome is established by **re-listing
///   the album** and looking for the paths, and a path that cannot be looked for
///   is reported as *unconfirmed* rather than as success.
/// * **A RAW+JPEG shot is two entries and one thing.** Deleting half a pair
///   orphans the other half, so a pair is planned as a unit: both siblings or
///   neither, and the siblings are never split across two batches.
/// * **The camera has no watchdog.** A command it does not expect can wedge it
///   until the battery is pulled, and a wrong path is unrecoverable. Everything
///   that would be sent is therefore decided — and refused, with a reason — before
///   a request is built. Execution is strictly serial: one request in flight,
///   never two, for the same reason a bulk transfer is (§5.3).
///
/// Free of Flutter and of `dart:io`, so `tool/verify_transport.dart` drives the
/// whole decision — batching, pair atomicity, refusals and unconfirmed outcomes —
/// in the plain Dart VM against a scripted camera.
library;

import '../sync/asset_group.dart';
import 'album.dart';

/// Why an item is **not** going to be deleted.
///
/// Named reasons rather than a bool, because "we did not do what you asked, and
/// here is which of three things stopped us" is the entire difference between an
/// app that explains a gap and one that quietly does the wrong thing.
///
/// The enum is also what the UI localizes on: [DeleteRefusalCodes] maps it to an ARB
/// key, and the English sentence stays in [protectedReason] / [tooLongReason] as the
/// fallback. `AGENTS.md` §4.1 keeps this file free of `package:flutter`, so the
/// sentence cannot be built here for the screen — but it *is* built here, beside the
/// firmware reasoning it states, and the code travels with it. See
/// `lib/l10n/message_text.dart` for the full argument.
enum DeleteBlock {
  /// `protectStatus: true` on the listing. What that flag means on this firmware
  /// is **unverified** — it is reported by `GetFileList` and appears nowhere in
  /// the official app's delete path — so it is treated as "protected" and left
  /// alone, which is the direction whose worst case is a file the user deletes
  /// from the camera itself.
  protectedOnCamera,

  /// Longer than the 52-character slot the handler copies a `file_list` entry
  /// into. Sending it would truncate the path, i.e. delete a different file.
  pathTooLong,

  /// The other half of a RAW+JPEG pair was refused. Deleting this half would
  /// leave an orphan that the album no longer shows as one shot.
  orphanedPairSibling,
}

/// The ARB keys behind a [DeleteBlock].
///
/// [orphanedPairSibling] has **no** code on purpose: it is never rendered as a
/// sentence of its own — the pair is reported through the sibling that provoked it —
/// and inventing wording for a string nothing draws would be a translation that can
/// never be checked against a screen.
abstract final class DeleteRefusalCodes {
  static const protectedOnCamera = 'deleteRefusalProtected';
  static const pathTooLong = 'deleteRefusalPathTooLong';
  static const listingFailed = 'deleteRefusalListingFailed';

  static const Set<String> all = {
    protectedOnCamera,
    pathTooLong,
    listingFailed,
  };
}

/// What stayed, and why.
class DeleteRefusal {
  final AlbumFile file;
  final DeleteBlock block;

  /// The sentence, in English — what `toString()` prints and what the UI falls back
  /// to. See [DeleteRefusalCodes].
  final String reason;

  /// The ARB key for [reason], or null for a refusal whose wording the UI composes
  /// itself.
  final String? reasonCode;

  /// The values [reason] interpolates.
  final Map<String, Object?> reasonParams;

  const DeleteRefusal(this.file, this.block, this.reason,
      {this.reasonCode, this.reasonParams = const {}});

  @override
  String toString() => '${file.fileName}: $reason';
}

/// One request's worth of paths.
class DeleteBatch {
  final List<String> paths;

  /// Human-readable label for the progress row.
  final String label;

  const DeleteBatch(this.paths, this.label);

  @override
  String toString() => 'DeleteBatch($label, ${paths.length} paths)';
}

/// Everything that *would* be sent, and everything that will not be.
class DeletePlan {
  final List<DeleteBatch> batches;
  final List<DeleteRefusal> refusals;

  /// Every path the plan will ask the camera to remove, in send order.
  final List<String> paths;

  /// Paths in [paths] that were **derived**, not read from the listing — so a fresh
  /// listing is not evidence about them either way.
  ///
  /// ## What can be known about a derived path
  ///
  /// A RAW+JPEG shot is **one** listing record, not two. Measured on the real 3.1-cn
  /// body (`analysis/50` §1): 25 records for 25 shutter presses, 18 of them `rawJpeg`
  /// whose `path` ends `.JPG` — and **not one `.DNG`**. The RAW beside that record is
  /// derived from it by naming convention ([AlbumFile.rawSibling], and `asset_group.dart`
  /// §"How the camera actually reports a pair"), which is why [AssetGroup.assets] hands
  /// this planner two paths for a shot the listing describes with one.
  ///
  /// So `DeleteFile` gets asked for a path the album never shows. That is the whole of
  /// what is known here, and it is enough to break the verification: such a path is
  /// absent from the listing before the delete, absent from it after, and absent
  /// whatever the camera did. **Reading that absence as success is how the app reports
  /// a ~32 MB RAW as deleted while it is still on the card** — and because the pair's
  /// row then leaves the grid, the file that is still there is invisible and cannot be
  /// retried, on a camera where a delete cannot be undone.
  ///
  /// ## What this is *not*
  ///
  /// It is **not** a claim that the camera cannot delete a derived path. Whether
  /// `DeleteFile` on a derived `.DNG` removes the RAW **has never been measured by
  /// anyone** (`analysis/79`, "what this audit did not cover"), and nothing here
  /// assumes either answer: [FileDeleter] reports such a path
  /// [DeleteVerdict.unconfirmed], the one verdict that is the same under both.
  /// [planDelete] is the only construction site, and the parameter is **required
  /// rather than defaulted** on purpose. A default of "nothing here is derived" is a
  /// default that fails open: the next caller that builds a plan without stating what
  /// it derived would silently get finding #1 of `analysis/79` back, with a green
  /// suite, because that is exactly what the lie looked like. Requiring it makes that
  /// call site fail to compile instead.
  final Set<String> derivedPaths;

  const DeletePlan({
    required this.batches,
    required this.refusals,
    required this.paths,
    required this.derivedPaths,
  });

  bool get isEmpty => batches.isEmpty;

  /// Files that will actually be sent.
  int get files => paths.length;

  /// Shots that will actually be sent.
  ///
  /// A RAW+JPEG pair is **one** photo to the user (§5.4), so "delete 3 photos"
  /// for two JPEGs and a pair must count three, not four.
  int get shotCount => _identities(batches).length;

  /// Shots the user selected that nothing will happen to, counted the same way.
  int get refusedShotCount => refusedShotIdentities.length;

  bool get hasRefusals => refusals.isNotEmpty;

  /// Shot identities that have at least one refusal and no path being sent.
  Set<String> get refusedShotIdentities {
    final sent = _identities(batches);
    return {
      for (final r in refusals)
        if (!sent.contains(shotIdentity(r.file.path))) shotIdentity(r.file.path),
    };
  }

  /// `{path: reason}` for what cannot be deleted — what the confirmation has to
  /// show *before* anything is sent.
  Map<String, String> get refusalReasons => {
        for (final r in refusals) r.file.path: r.reason,
      };

  /// Every path the user selected, deletable or not.
  List<String> get selectedPaths =>
      [...paths, for (final r in refusals) r.file.path];

  static Set<String> _identities(List<DeleteBatch> batches) => {
        for (final b in batches)
          for (final p in b.paths) shotIdentity(p),
      };
}

/// Folder + basename, i.e. the sibling rule `asset_group.dart` pairs on.
///
/// Deliberately duplicated rather than imported: `sync/` depends on `transport/`
/// and not the other way round, and a pair is defined by this string in both
/// places. `tool/verify_transport.dart` asserts the two agree.
String shotIdentity(String path) {
  final slash = path.lastIndexOf('/');
  final dir = slash < 0 ? '' : path.substring(0, slash);
  var base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  return '$dir/$base';
}

/// Decide what to send, and what to refuse, without sending anything.
///
/// [groups] is what the user selected, as `AssetGroup`s — one entry per shutter
/// press — so a pair arrives here as one unit and leaves as one unit.
///
/// The two-phase shape is not incidental. Phase 1 decides per **group** whether it
/// is deletable at all, which is where pair atomicity lives: a pair is refused as
/// a whole if either sibling is protected or too long, and the surviving sibling is
/// then named as [DeleteBlock.orphanedPairSibling] rather than quietly deleted.
/// Phase 2 packs the survivors into batches, boundary-testing whole groups so the
/// siblings of one pair can never land in different requests — if they did, a
/// failure between the two requests would orphan the file the first one removed,
/// which is the exact outcome this exists to prevent.
DeletePlan planDelete(
  List<AssetGroup> groups, {
  int batchSize = CameraAlbum.deleteBatchSize,
  int pathLimit = AlbumFile.deletePathLimit,
}) {
  final batches = <List<String>>[];
  final refusals = <DeleteRefusal>[];
  final derived = <String>{};

  for (final g in groups) {
    final assets = g.assets;

    // --- phase 1: does anything block this whole shot?
    DeleteBlock? blocked;
    for (final f in assets) {
      if (f.protectStatus) {
        blocked = DeleteBlock.protectedOnCamera;
        break;
      }
      if (f.path.length > pathLimit) {
        blocked = DeleteBlock.pathTooLong;
        break;
      }
    }

    if (blocked != null) {
      for (final f in assets) {
        if (f.protectStatus) {
          refusals.add(DeleteRefusal(
              f, DeleteBlock.protectedOnCamera, protectedReason,
              reasonCode: DeleteRefusalCodes.protectedOnCamera,
              reasonParams: {'fileName': f.fileName}));
        } else if (f.path.length > pathLimit) {
          refusals.add(DeleteRefusal(
              f, DeleteBlock.pathTooLong, tooLongReason(f, pathLimit),
              reasonCode: DeleteRefusalCodes.pathTooLong,
              reasonParams: {'length': f.path.length, 'limit': pathLimit}));
        } else {
          refusals.add(DeleteRefusal(f, DeleteBlock.orphanedPairSibling,
              'the other half of this RAW+JPEG shot cannot be deleted, and '
              'removing this half would leave a file on the card that the '
              'album can no longer show as one photo'));
        }
      }
      continue;
    }

    // --- phase 2: pack whole groups in, and never split one across a boundary.
    final paths = assets.map((f) => f.path).toList(growable: false);

    // A `rawJpeg` record **is** the JPEG; the RAW beside it has no record of its own,
    // so it is a path this camera's listing cannot speak about. See
    // [DeletePlan.derivedPaths] — this is the one place that knows it, and it is
    // recorded here rather than re-derived at verification time, where the only
    // evidence left is a listing that never carried it.
    if (g.raw != null && g.primary.hasRawSibling) derived.add(g.raw!.path);

    final current = batches.isEmpty ? null : batches.last;
    if (current == null || current.length + paths.length > batchSize) {
      batches.add(List<String>.of(paths));
    } else {
      current.addAll(paths);
    }
  }

  return DeletePlan(
    batches: [
      for (var i = 0; i < batches.length; i++)
        DeleteBatch(
          List<String>.unmodifiable(batches[i]),
          batches.length == 1
              ? '${batches[i].length} files'
              : 'batch ${i + 1} of ${batches.length} — ${batches[i].length} files',
        ),
    ],
    refusals: List<DeleteRefusal>.unmodifiable(refusals),
    paths: List<String>.unmodifiable([for (final b in batches) ...b]),
    derivedPaths: Set<String>.unmodifiable(derived),
  );
}

/// Every protected file in [groups], deleted or not.
///
/// The album uses this to warn **before** a selection is acted on, so a protected
/// photo is explained while the user is looking at it rather than after they have
/// asked for it to go.
List<AlbumFile> protectedFiles(List<AssetGroup> groups) => [
      for (final g in groups)
        for (final f in g.assets)
          if (f.protectStatus) f,
    ];

/// Stated once, because it is a limitation rather than a decision: the firmware
/// reports the flag and nothing in this project's reverse engineering says what
/// it guards, so the app takes it at face value.
const String protectedReason =
    'the camera lists this file as protected. What that flag means on this '
    'firmware is not verified, so the app treats it as a refusal to delete '
    'rather than guessing — remove the protection, or delete it on the camera';

String tooLongReason(AlbumFile f, int limit) =>
    'the path is ${f.path.length} characters, and DeleteFile copies each entry '
    'into a $limit-character slot, so the camera would truncate it and could '
    'delete the wrong file';

// ---------------------------------------------------------------------------

/// How one path ended up.
enum DeleteVerdict {
  /// The request carrying it was accepted **and** a fresh listing no longer shows
  /// it. As close to proof as this firmware allows, and still evidence rather
  /// than a guarantee — see [FileDeleter.submit].
  ///
  /// Only ever given to a path the listing can carry: a [DeletePlan.derivedPaths]
  /// entry is never this, because its absence from a listing it was never in is not
  /// evidence of anything.
  confirmedGone,

  /// The request carrying it was accepted and there is **no evidence** either way:
  /// either the card could not be re-listed, or the path is one the listing never
  /// carries, so no re-listing could have spoken about it. **Not** success, in both
  /// cases — see [DeleteOutcome.unlisted] for telling them apart.
  unconfirmed,

  /// Either the request failed, or the fresh listing still shows the file. The
  /// file is on the card.
  failed,
}

/// Per-path outcome, which is what the UI shows instead of a success toast.
class DeleteOutcome {
  final String path;

  /// Folder + basename of the shot this path belongs to, so a pair reports as one
  /// row.
  final String shot;

  final DeleteVerdict verdict;

  /// What to tell the user, in their words.
  final String message;

  /// True when this path is one the album listing does not carry
  /// ([DeletePlan.derivedPaths]), i.e. the RAW half of a RAW+JPEG shot on this
  /// firmware.
  ///
  /// Only ever true with [DeleteVerdict.unconfirmed], and it is the difference
  /// between the two reasons a file can be unconfirmed: *"the card could not be
  /// listed again"* is a hiccup the user can retry, while *"the album never lists
  /// this file"* is one no amount of retrying will settle. [DeleteReport.summary]
  /// says so out loud, because the two must not read the same.
  final bool unlisted;

  const DeleteOutcome({
    required this.path,
    required this.shot,
    required this.verdict,
    required this.message,
    this.unlisted = false,
  });

  @override
  String toString() => 'DeleteOutcome($path, ${verdict.name})';
}

/// The whole result of a delete run.
class DeleteReport {
  final List<DeleteOutcome> outcomes;

  /// Before/after counts, when both listings were available.
  final int? listedBefore;
  final int? listedAfter;

  /// Set when the post-delete listing itself failed — the reason every accepted
  /// path comes back [DeleteVerdict.unconfirmed].
  final String? verifyError;

  const DeleteReport({
    required this.outcomes,
    this.listedBefore,
    this.listedAfter,
    this.verifyError,
  });

  List<DeleteOutcome> of(DeleteVerdict v) =>
      [for (final o in outcomes) if (o.verdict == v) o];

  int get confirmed => of(DeleteVerdict.confirmedGone).length;
  int get unconfirmed => of(DeleteVerdict.unconfirmed).length;
  int get failed => of(DeleteVerdict.failed).length;

  /// Unconfirmed because the album listing does not carry the path, rather than
  /// because the listing could not be read — see [DeleteOutcome.unlisted].
  ///
  /// The two are worth separating in the count the user reads: the first cannot be
  /// settled by looking again, the second might be. The verdict is required as well
  /// as the flag, and not as a formality: this number is interpolated into a sentence
  /// about *the unconfirmed*, so an outcome that is not unconfirmed must not be able
  /// to make that sentence describe a file it is not about.
  int get unconfirmedUnlisted => [
        for (final o in outcomes)
          if (o.unlisted && o.verdict == DeleteVerdict.unconfirmed) o,
      ].length;

  int get total => outcomes.length;

  /// True only when every path was both accepted and absent from the new listing.
  ///
  /// A RAW+JPEG shot therefore never reaches this — its RAW cannot be checked — and
  /// the UI draws no green tick for it. That is the honest reading: the app verified
  /// the JPEG and has nothing to say about the RAW.
  bool get allConfirmed => total > 0 && confirmed == total;

  /// Shot identities whose every listed asset is confirmed gone.
  ///
  /// The album removes exactly these rows and no others: a RAW+JPEG row must stay
  /// on screen if one half is still on the card, or the orphan it is warning
  /// about would be invisible.
  ///
  /// Since finding #1 of `analysis/79` the second half of that sentence is enforced
  /// rather than hoped for: the RAW of a `rawJpeg` shot [DeleteVerdict.unconfirmed]
  /// by construction, so a pair whose delete *worked* still keeps its row. Removing
  /// it would hide a file the app cannot prove is gone, and the doubt is only
  /// visible while the row is. A reload settles it — the JPEG is gone from the
  /// listing, so a fresh grouping no longer has the shot at all.
  Set<String> get removedShots {
    final confirmed = of(DeleteVerdict.confirmedGone);
    final confirmedShots = {for (final o in confirmed) o.shot};
    return {
      for (final s in confirmedShots)
        if (outcomes.every((o) => o.shot != s || o.verdict == DeleteVerdict.confirmedGone))
          s,
    };
  }

  /// A one-line summary for the UI, stated per file and never rounded up.
  String get summary {
    if (outcomes.isEmpty) return 'Nothing was deleted.';
    final counts = listedBefore != null && listedAfter != null
        ? ' The card listed $listedBefore files before and $listedAfter after.'
        : '';
    final extra = <String>[
      if (unconfirmed > 0) '$unconfirmed unconfirmed',
      if (failed > 0) '$failed still on the card',
    ];
    final head = '$confirmed of $total file${total == 1 ? '' : 's'} deleted and '
        'checked against a fresh listing';
    // A path the listing never carries is unconfirmed for a reason that looking
    // again cannot fix, and it must not read like the retryable kind. Without this
    // sentence "1 unconfirmed" for a RAW is indistinguishable from "1 unconfirmed"
    // for a listing that timed out, and the user's next move is different — one is
    // "reload", the other is "the app will never be able to tell you".
    //
    // It can say the listing was read because the two kinds cannot occur together:
    // [DeleteOutcome.unlisted] is only ever set on the path where the post-delete
    // listing succeeded, and a failed post-delete listing is the only source of the
    // other kind.
    final derived = unconfirmedUnlisted;
    final clause = derived == 0
        ? ''
        : ' The listing after the delete was read, so this is not a listing '
            'failure: $derived of the unconfirmed cannot be settled by looking '
            'again at all, because the album lists the JPEG of a RAW+JPEG shot and '
            'never its RAW.';
    return extra.isEmpty
        ? '$head.$counts$clause'
        : '$head — ${extra.join(', ')}.$counts$clause';
  }
}

/// The sentence for a RAW the album listing does not carry.
///
/// Stated once, beside the reasoning it states: the app asked, the camera answered
/// `200`, and there is no way to find out what happened. It has to read as "not
/// known" rather than as either outcome, and it says **why** it cannot be checked,
/// because the generic unconfirmed sentence blames the listing — and here the
/// listing worked.
const String derivedRawUnconfirmed =
    'the camera accepted the request, but this is the RAW half of a RAW+JPEG shot '
    'and the album listing never carries it, so there is nothing to check it '
    'against — whether the RAW was removed is not known, and this is not a '
    'confirmation that it was';

/// Sends the batches and establishes what actually happened.
///
/// ## One request in flight
///
/// Batches are submitted strictly one after another. Parallel `DeleteFile` calls
/// against a single-threaded embedded httpd do not go faster and raise the chance
/// of the stall that wedges a camera with no watchdog (§5.3).
///
/// ## Why a re-listing is the verification
///
/// The firmware's `200` proves the request was understood, not that a file was
/// removed. There is no confirmation body for deletion, so the only evidence is
/// the album itself:
///
/// * **present in the new listing ⇒ definitely not deleted.** This is the strong
///   direction and the one that matters: it is what turns a cheerful toast into
///   "3 files are still on the card". It is also the only direction that survives
///   the next bullet unchanged, because presence is evidence about *any* path.
/// * **absent ⇒ treated as deleted, but only for a path the listing is known to
///   carry.** [DeleteVerdict.confirmedGone] therefore means "accepted, and no longer
///   listed", not "the card's filesystem was interrogated". A file could also
///   disappear because it was moved or the card was swapped, and this protocol
///   cannot tell those apart.
/// * **absent, and the listing never carried it ⇒ `unconfirmed`.** A
///   [DeletePlan.derivedPaths] entry — the RAW half of a `rawJpeg` shot — has no
///   listing record of its own, so it is absent before the delete, absent after it,
///   and absent whatever the camera did. Counting that absence as confirmation is
///   the defect `analysis/79` finding #1 records: a 32 MB RAW reported as *"deleted
///   and checked against a fresh listing"* while it is still on the card, with the
///   pair's row already gone from the grid and nothing left to see or retry.
///
/// If the listing itself fails, every accepted path is reported
/// [DeleteVerdict.unconfirmed] with the reason attached. That is deliberate: the
/// honest failure mode of this feature is "we asked, we could not confirm", and it
/// must never be rendered as success.
class FileDeleter {
  final CameraAlbum album;
  final void Function(String message)? onLog;

  /// Called before each request, so the UI can name the batch in flight rather
  /// than showing an indeterminate spinner (§5.6).
  final void Function(DeleteBatch batch, int index, int total)? onBatch;

  const FileDeleter({required this.album, this.onLog, this.onBatch});

  Future<DeleteReport> submit(DeletePlan plan) async {
    if (plan.isEmpty) return const DeleteReport(outcomes: []);

    // Taken from the same walk that decides what "gone" means, so the two counts
    // in the summary cannot come from different moments in the card's life.
    final before = await _listPaths();
    final sent = <String>{};
    final sendError = <String, String>{};

    // The paths a fresh listing cannot speak about. The plan knows a RAW was
    // *derived* rather than read ([DeletePlan.derivedPaths]); the pre-delete listing
    // then decides whether that mattered, because `groupAssets` also supports a card
    // that really does list the RAW, and there absence is evidence like any other.
    // With no pre-listing the question cannot be asked, and the answer is the
    // conservative one — unknown is never "gone".
    final unverifiable = <String>{
      for (final p in plan.derivedPaths)
        if (before == null || !before.contains(p)) p,
    };

    for (var i = 0; i < plan.batches.length; i++) {
      final batch = plan.batches[i];
      onBatch?.call(batch, i + 1, plan.batches.length);
      try {
        final r = await album.deleteFileList(batch.paths);
        if (!r.ok) {
          // A non-200 is the firmware refusing outright, so every path in this
          // batch is known to still be on the card — no re-listing needed.
          for (final p in batch.paths) {
            sendError[p] = 'the camera answered ${r.code} to the delete request, '
                'so this file was not removed';
          }
          continue;
        }
        sent.addAll(batch.paths);
      } on Object catch (e) {
        _log('delete batch ${i + 1} of ${plan.batches.length} failed: $e');
        for (final p in batch.paths) {
          sendError[p] = '$e';
        }
      }
    }

    if (sent.isEmpty) {
      return DeleteReport(
        listedBefore: before?.length,
        outcomes: [
          for (final p in plan.paths)
            DeleteOutcome(
              path: p,
              shot: shotIdentity(p),
              verdict: DeleteVerdict.failed,
              message: sendError[p] ??
                  'the request never reached the camera, so this file is still '
                      'on the card',
            ),
        ],
      );
    }

    final after = await _listPaths();
    if (after == null) {
      return DeleteReport(
        listedBefore: before?.length,
        verifyError: 'the album could not be listed again after deleting, so '
            'there is no way to tell which files actually went',
        outcomes: [
          for (final p in plan.paths)
            if (!sent.contains(p))
              DeleteOutcome(
                path: p,
                shot: shotIdentity(p),
                verdict: DeleteVerdict.failed,
                message: sendError[p] ?? 'the delete request failed',
              )
            else
              DeleteOutcome(
                path: p,
                shot: shotIdentity(p),
                verdict: DeleteVerdict.unconfirmed,
                message: 'the camera accepted the request, but the card could '
                    'not be re-listed, so whether this file is gone is unknown',
              ),
        ],
      );
    }

    return DeleteReport(
      listedBefore: before?.length,
      listedAfter: after.length,
      outcomes: [
        for (final p in plan.paths)
          if (!sent.contains(p))
            DeleteOutcome(
              path: p,
              shot: shotIdentity(p),
              verdict: DeleteVerdict.failed,
              message: sendError[p] ?? 'the delete request failed',
            )
          else if (after.contains(p))
            DeleteOutcome(
              path: p,
              shot: shotIdentity(p),
              verdict: DeleteVerdict.failed,
              message: 'the camera accepted the delete and still lists this '
                  'file, so it is still on the card',
            )
          // The path was never in the listing and is not in this one either. That is
          // not evidence, and it is the shape finding #1 of `analysis/79` was about:
          // calling it confirmed is a 32 MB RAW reported gone while it is on the card.
          else if (unverifiable.contains(p))
            DeleteOutcome(
              path: p,
              shot: shotIdentity(p),
              verdict: DeleteVerdict.unconfirmed,
              message: derivedRawUnconfirmed,
              unlisted: true,
            )
          else
            DeleteOutcome(
              path: p,
              shot: shotIdentity(p),
              verdict: DeleteVerdict.confirmedGone,
              message: 'gone from the card',
            ),
      ],
    );
  }

  /// The whole album as a path set, or null when it could not be read.
  ///
  /// A full walk rather than the first page: the verification is worth nothing
  /// unless it can see every file, and the paths being checked can sit past page
  /// 1. `listAll` already carries the firmware's end-of-album signal and a page
  /// cap, so this terminates even against a camera that answers full pages
  /// forever.
  Future<Set<String>?> _listPaths() async {
    try {
      final out = <String>{};
      await for (final f in album.listAll()) {
        out.add(f.path);
      }
      return out;
    } on Object catch (e) {
      _log('could not re-list the album to verify the delete: $e');
      return null;
    }
  }

  void _log(String m) => onLog?.call('[delete] $m');
}
