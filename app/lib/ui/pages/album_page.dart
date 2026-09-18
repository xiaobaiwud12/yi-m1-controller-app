import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../l10n/message_text.dart';
import '../../platform/media_store_bridge.dart';
import '../../state/app_state.dart';
import '../../sync/asset_group.dart';
import '../../sync/sync_engine.dart';
import '../../sync/sync_ledger.dart';
import '../../transport/album.dart';
import '../../transport/album_delete.dart';
import '../../transport/camera_request_gate.dart';
import '../../transport/http_transport.dart';
import '../haptics.dart';

/// Album browsing, selection and sync.
///
/// ## What this page does differently from the official app
///
/// The official app has **no background sync at all** — no service, no
/// work manager, and every transfer begins with a tap. It also cannot shoot
/// while downloading, because it pauses transfers whenever a control command is
/// dispatched. And it offers one quality per transfer, chosen in advance.
///
/// This page implements the project's own design guide
/// (`analysis/ce-app-competitive-spec.md`):
///
/// * **Preview first, upgrade in place** (§D2). A grid thumbnail is fetched at
///   `Thumbnail`, opening an item loads `MidThumb` immediately, and `Original`
///   arrives underneath. The user never waits to *see* a photo, and still gets
///   the real file. No major app can copy this: it needs three resolutions of the
///   same path, which their protocols do not expose.
/// * **One row per shutter press** (§5.4). A RAW+JPEG pair shows as one card
///   with a badge, so the count is not a lie and selecting the shot selects the
///   shot.
/// * **Every state is named** (§5.6). `stalled`, `paused (camera away)` and
///   `failed` are different things; a spinner for all three is how a sync
///   silently dies without anyone noticing.
class AlbumPage extends StatefulWidget {
  final AppState app;
  const AlbumPage({super.key, required this.app});

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  /// One entry per shutter press, newest first — see [groupAssets].
  final List<AssetGroup> _groups = [];

  /// The thumbnails on this page, by shot key.
  ///
  /// Memory for the life of this page — and *only* for its life. What makes opening the
  /// album twice cheap is [AppState.thumbnailCache] underneath it, which holds the same
  /// bytes on the phone; this map is what the tiles are drawn from and what makes
  /// scrolling back to a tile free.
  final Map<String, Uint8List> _thumbs = {};

  /// Shots whose thumbnail has been asked for, so nothing is asked for twice.
  ///
  /// ## Both failure modes this prevents, because they are opposites
  ///
  /// * **A retry in a loop.** The fetch is driven by what is on screen, so it runs on
  ///   every scroll notification — and a rebuild is not a reason to send a command.
  ///   Without this set a `.DNG` would ask for its (nonexistent) `Thumbnail` again on
  ///   every frame of a scroll: a **request storm against a single-threaded camera
  ///   with no watchdog** (`AGENTS.md` §4.6), which is the one thing a cosmetic
  ///   feature must never become.
  /// * **A transient failure becoming a permanent blank tile.** The comment above
  ///   says so, and this is the mitigation: nothing is *retried* on its own, but a
  ///   failure is not final either — the reload button clears both sets, and so does
  ///   a scroll that brings the tile back after it left the cache.
  final Set<String> _thumbAsked = {};

  /// Shots whose every rendition was refused. Drawn as a placeholder rather than a
  /// spinner, because nothing is in flight for them.
  final Set<String> _thumbFailed = {};

  /// Thumbnails wanted, in on-screen order, fetched by one serial loop.
  ///
  /// ## Why one loop and not one future per tile
  ///
  /// The camera serves **one request at a time** and the live view is streaming over
  /// the same radio, so the grid asks for at most one thumbnail at a time — the same
  /// reason the sync engine runs its queue serially. An `index` rather than a
  /// `removeAt(0)` so the wanted set can grow while the loop runs without the loop
  /// holding a list that changes under it.
  final Set<String> _thumbWanted = {};
  bool _thumbLoopRunning = false;

  bool _loading = false;
  bool _moreAvailable = true;
  String? _error;
  int _page = 0;

  /// Multi-select, for "sync these" and "delete these".
  final Set<String> _selected = {};
  bool _selecting = false;

  /// The delete in flight: which batch of how many, so the wait is named rather
  /// than spun (§5.6). Null when nothing is being deleted.
  ({int index, int total, String label})? _deleteProgress;

  /// What happened, per file. Cleared when the selection changes, because a stale
  /// result panel attached to a new selection is a lie by layout.
  DeleteReport? _deleteReport;
  List<DeleteRefusal> _deleteRefusals = const [];

  AppState get app => widget.app;
  SyncEngine get sync => app.sync;

  @override
  void initState() {
    super.initState();
    // ## Why this no longer takes the engine's `onChanged`
    //
    // This line used to be `sync.onChanged = _onSync`, and it was a **wiring bug that
    // read like a wiring fix**. `SyncEngine.onChanged` is a single slot: `AppState`
    // fills it in its constructor with its own `notifyListeners`, and the album page
    // then overwrote it the moment the album was first built. From that point on the
    // engine's every change — a stage moving, a run starting, the note changing — was
    // delivered to this one page and to **nobody else**. `AppState` never notified,
    // so the shell's `AnimatedBuilder` never rebuilt, so every screen reading sync
    // state *outside* this page went stale; and because the page's own copy was the
    // only consumer left, a rebuild that did happen (a tab switch, a route push) was
    // what appeared to "fix" the display.
    //
    // It was also the reason a widget test could only make the sync bar move by
    // calling `app.sync.onChanged?.call()` by hand: the production wiring had already
    // been replaced.
    //
    // The page reads sync state, so it rebuilds from the same source the rest of the
    // app does — `AppState` — through the [AnimatedBuilder] in `build`. There is one
    // subscriber to the engine, it belongs to `AppState`, and it notifies everything,
    // which is what the class's own documentation says it is for.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPage());
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ------------------------------------------------------------------ loading

  Future<void> _loadPage() async {
    final album = app.album;
    if (album == null || _loading) return;
    // ## A plain `if (_loading) return` does not guard an `async` body
    //
    // The guard above and this flag are both synchronous, but everything between them
    // and the *next* assignment is not: the first `await` yields, and any second caller
    // that arrives in that window sees `_loading == false` and starts its own fetch. Two
    // callers then both append the same page to `_groups`, so the grid holds every shot
    // twice — and since the thumbnail queue is keyed by shot, it asks the camera for
    // each thumbnail twice as well. On this hardware that is a doubled request stream
    // against a single-threaded server (`AGENTS.md` §4.6).
    //
    // Setting the flag **before** the first suspension point closes the window: there
    // is no `await` between the test and the set, so a second synchronous call cannot
    // get past it.
    _loading = true;
    setState(() => _error = null);
    try {
      // The ledger and the pending queue are read from disk before the first
      // page is enqueued, so a restore cannot race the initial enqueue and
      // present the same shots twice. Idempotent, and a no-op after the first
      // call.
      await app.loadDurableState();
      if (!mounted) return;

      final page = await album.listPage(_page);
      if (!mounted) return;

      // Group before adding: the listing reports a RAW+JPEG shot as two entries,
      // and showing two rows for one shutter press would double the count and
      // split the selection.
      final grouped = groupAssets(page);
      setState(() {
        _groups.addAll(grouped);
        // A short page is the firmware's own end-of-album signal.
        _moreAvailable = page.length >= CameraAlbum.pageSize;
        _page += 1;
      });

      // Feed the sync engine from the same listing, so browsing and syncing
      // agree about what exists. `enqueueBrowsed` is the mode-aware entry point:
      // in manual mode it adds nothing, which is what that mode promises.
      //
      // `grouped` rather than `page`, and through the plan: this is the path that
      // queues a whole card by the act of looking at it, so it is the one where a
      // RAW arriving unasked would be least visible. The grouping is what knows a
      // `.DNG` is a sibling of the listed JPEG rather than a second shutter press —
      // the firmware never lists it (`analysis/50`) — so without this the RAW switch
      // would do nothing at all in the two automatic modes.
      sync.enqueueBrowsed(plannedQueue(grouped, app.queuePlan));
      // Thumbnails for what is on screen, and a little beyond it. The rest arrive
      // when the user scrolls there: this used to be `grouped.take(18)`, which meant
      // **every shot past the eighteenth showed a spinner for the life of the page**,
      // however long the user waited.
      _markThumbsWanted(0, _firstScreen);
    } on AlbumException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on CameraHttpException catch (e) {
      if (mounted) {
        final l = l10nOf(context);
        setState(() => _error = e.isBadParameters
            ? l.albumListingRejected(e.message)
            : l.albumUnreachable(e.message));
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      // Cleared **synchronously**, for the mirror of the reason it is set
      // synchronously above: the next page is only allowed to start once this one has
      // finished, and an `await` between the last `setState` and this line would let a
      // caller in.
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  /// How many leading tiles are asked for as soon as a page arrives.
  ///
  /// Not "everything listed": the camera is single-threaded and the live view shares
  /// the radio, so the bound is deliberate. 24 covers the first screen in portrait
  /// (4 columns × 5 rows at the measured tile size) plus one screen of look-ahead, and
  /// the scroll handler picks everything else up as it comes into view.
  static const int _firstScreen = 24;

  /// How far past the bottom of the viewport a tile is still worth fetching.
  ///
  /// One grid row: far enough that scrolling does not outrun the fetches and show a
  /// spinner where a picture was a moment ago, close enough that a fast fling does not
  /// queue the whole card.
  static const int _thumbLookahead = 8;

  /// Ask for the thumbnails of `_groups[start .. end)`.
  ///
  /// Marking is free and synchronous; the requests are serialised by
  /// [_pumpThumbs]. Called from the scroll handler, so it must stay cheap.
  void _markThumbsWanted(int start, int end) {
    if (_groups.isEmpty) return;
    final from = start < 0 ? 0 : start;
    final to = end > _groups.length ? _groups.length : end;
    for (var i = from; i < to; i++) {
      final k = _groups[i].id.key;
      // A failure is asked for once per page visit, never in a loop: `_thumbAsked`
      // is the guard, and this is where a `.DNG`'s 204 stops being a request storm.
      if (_thumbs.containsKey(k) || _thumbAsked.contains(k)) continue;
      _thumbAsked.add(k);
      _thumbWanted.add(k);
    }
    unawaited(_pumpThumbs());
  }

  /// One serial loop over the wanted thumbnails, cheapest rendition first.
  ///
  /// ## What this replaced, and the two defects it carried
  ///
  /// It used to be `_fetchThumbs(grouped.take(18))` — a one-shot pass over the first
  /// eighteen tiles that called `album.download(primary, resolution: thumbnail)` and
  /// **swallowed every throw**:
  ///
  /// * **No fallback.** `downloadWithFallback` existed, with the exact chain this
  ///   needs, and the grid was the one caller not using it. A group whose primary is
  ///   a `.DNG` asks for `Thumbnail` and this firmware answers **`204` with a
  ///   zero-byte body** (`analysis/50` §2, `analysis/61` §1) — a *known* answer, and
  ///   the grid treated it as nothing at all. The tile span a spinner forever and the
  ///   log said nothing, because the `catch` was `on Object {}`.
  /// * **A silent empty body.** `204` is not the only way to get zero bytes, and
  ///   zero bytes handed to `Image.memory` is the phone's own reported failure
  ///   (`FlutterImageDecoderImplDefault: Failed to decode image`). `download` now
  ///   refuses an empty body outright, and this loop refuses to store one, so the
  ///   decoder cannot be handed nothing on either path.
  ///
  /// The chain is [CameraAlbum.gridChainFor] — `Thumbnail`, then `MidThumb`, then
  /// `Original`, except for a **video**, which stops at `MidThumb` because its
  /// `Original` is the video itself (`CameraAlbum.gridVideoThumbnailChain`). And
  /// `skipNoContent` is left false so a `204` still degrades to the next size: a `204`
  /// at `Thumbnail` is the camera saying "no small thumbnail for this file", and
  /// `MidThumb` is the same rendition the viewer asks for.
  ///
  /// ## Three things the loop has to get right, and why each is written down
  ///
  /// 1. **One request per tile, ever.** `_thumbAsked` is claimed *before* the request,
  ///    not after it, and it is claimed even when the request throws. A tile that
  ///    failed is not a tile to try again on the next rebuild: this camera serves one
  ///    request at a time and has no watchdog (`AGENTS.md` §4.6). Claiming it after
  ///    the `await` instead was a real bug in the first cut of this method — a rebuild
  ///    during the transfer re-asked for a `.DNG` whose `Original` was still in
  ///    flight, and the grid sent the whole three-rendition chain twice.
  /// 2. **A pass that ends with work still wanted must not strand it.** `_markThumbs`
  ///    runs from the scroll handler, so it can add to `_thumbWanted` while this loop
  ///    is inside an `await`. The `while (true)` re-checks after each pass instead of
  ///    returning on the first empty set, because the alternative is a tile that sits
  ///    on a spinner for the life of the page with nothing in flight for it — silent,
  ///    and exactly the shape of the defect this whole change is about.
  /// 3. **One pass at a time.** The flag covers the whole method, so a second caller
  ///    returns rather than competing with the transfer already on the wire.
  Future<void> _pumpThumbs() async {
    if (_thumbLoopRunning) return;
    final album = app.album;
    if (album == null) return;
    _thumbLoopRunning = true;
    try {
      while (true) {
        if (_thumbWanted.isEmpty) return;
        // `_thumbWanted` can grow while this runs; take them in listing order so the
        // grid fills top-down rather than in the order the user happened to scroll.
        final next = _groups
            .where((g) => _thumbWanted.contains(g.id.key))
            .map((g) => g.id.key)
            .firstOrNull;
        if (next == null) {
          // Wanted, but no group carries the key — the listing was replaced under us.
          _thumbWanted.clear();
          return;
        }
        _thumbWanted.remove(next);
        // `_markThumbsWanted` already claimed this key, so this only guards a second
        // path into the queue. Claiming happens **before** the request goes out,
        // which is the part that matters — see (1) above.
        _thumbAsked.add(next);
        // Gone from the listing (deleted, or the page was reloaded): nothing to draw.
        final group = _groups.where((g) => g.id.key == next).firstOrNull;
        if (group == null) continue;

        // ------------------------------------------------------------- the cache
        //
        // ## Before the camera, and that ordering is the feature
        //
        // A thumbnail the phone already has costs one local file read instead of a
        // request to a **single-threaded HTTP server with no watchdog** that is streaming
        // the live view over the same radio (`AGENTS.md` §4.6). Browsing the album while
        // the preview runs is the worst case those three rules exist for, so a hit here
        // does not merely avoid a wait — it **removes** pressure from a camera that has
        // none to spare. The report this answers is the maintainer's: *every time I
        // connect the camera and open the album the thumbnails reload.*
        //
        // Reads happen here, inside the serial loop, rather than in a pass of their own:
        // the loop is what bounds how fast the grid fills, and a cache hit does not touch
        // the radio at all — which is the resource this camera is short of.
        //
        // (What a hit costs instead — one local file read, and one small write for a miss
        // — is **[H]** as a device measurement: the round that added this did not run on
        // hardware. It is bounded by the request it replaces either way.)
        //
        // `read` is total — a cache that cannot read reports a miss rather than throwing
        // — so a broken or reclaimed cache directory degrades to exactly what this code
        // did before the cache existed. Nothing below changes, and no tile can be left
        // worse off by it.
        final cached = await app.thumbnailCache.read(next);
        if (!mounted) return;
        if (cached != null && cached.isNotEmpty) {
          setState(() => _thumbs[next] = cached);
          continue;
        }

        try {
          final (bytes, _) = await album.downloadWithFallback(
            group.primary,
            // `gridChainFor`, not the constant: a **video** is asked for its still
            // renditions and never for its `Original`, which is the video itself — an
            // MP4 the decoder cannot read, served over this one serial loop, in front
            // of every tile behind it. See `CameraAlbum.gridVideoThumbnailChain`.
            chain: CameraAlbum.gridChainFor(group.primary),
          );
          if (!mounted) return;
          if (bytes.isEmpty) continue; // see the second bullet above
          setState(() => _thumbs[next] = bytes);
          // ## Persisted here and nowhere else, and that placement is the rule
          //
          // This line is on the success path, so **absence is never cached**: a `.DNG`
          // whose every rendition was refused, a video with no still, a 500 that lasted
          // one scroll — none of them write anything, and every one of them is asked for
          // again on the next visit. `_thumbFailed` stays memory-only for the same
          // reason: "this file has no thumbnail" and "this request failed" are different
          // facts, and only the first is a property of the file.
          //
          // `put` is likewise stricter than "it returned 200": it refuses an empty body,
          // bytes that are not a JPEG, and anything past a thumbnail's size. So a
          // truncated transfer or a JSON error page cannot become a broken tile that
          // survives a reload either.
          //
          // Awaited, not fired and forgotten: this loop is serial on purpose, and the
          // write is ~7 KB to a local file — far cheaper than the request that produced
          // it, and already displayed by the `setState` above.
          await app.thumbnailCache.put(next, bytes);
        } on Object catch (e) {
          // Named rather than swallowed: "this tile has no picture" is cosmetic, but
          // it is also the only evidence that the camera refused, and a silent
          // `catch` here is what made the missing thumbnails undiagnosable.
          debugPrint('[album] no thumbnail for ${group.primary.path}: $e');
          if (mounted) setState(() => _thumbFailed.add(next));
        }
      }
    } finally {
      _thumbLoopRunning = false;
    }
  }

  /// The tiles the viewport is showing, from the grid's own scroll notification.
  ///
  /// ## Which of `ScrollMetrics`' numbers is which — the defect this fixes
  ///
  /// `ScrollMetrics.viewportDimension` is the viewport's extent along the **axis of the
  /// scroll**, which for this grid is its **height**. The arithmetic below needs the
  /// grid's **width**, because everything it mirrors — how many columns the delegate
  /// lays out, how wide a tile is, how tall a row is — is derived from the cross axis.
  /// This used to pass `viewportDimension` to both, so on any window that was not
  /// square the tile width and the row height were scaled by the wrong side.
  ///
  /// Measured, on a 130-file card at 411x727 (grid 490dp tall, and 3 columns of 129dp):
  /// the handler computed a 155dp tile and a 200dp row, so at the bottom of the card it
  /// asked for tiles **102..121** while the screen was showing **123..129** — the last
  /// five to eight tiles of the card were never asked for, never fetched, and spun
  /// forever. That is the reported "the oldest few thumbnails still never load", and it
  /// is why the previous round's fix (a leading window on load, plus a
  /// scroll-driven fetch) fixed everything except the end of the list.
  ///
  /// The width comes from the enclosing `LayoutBuilder`, which is the same box this
  /// grid is laid out in. The height stays `viewportDimension`, which is what that
  /// number genuinely is.
  ///
  /// ## Why it hid on the desk
  ///
  /// The error's **sign depends on the grid's shape**. At 411x2400 (grid 1688dp tall,
  /// the window `album_thumbnails_test.dart` scrolls on) the same mismatch made the
  /// first notification ask for tiles 0..190 — everything — so no check on a tall
  /// window could see it. `album_last_page_test.dart` therefore pins the band it
  /// measures in, and says so.
  ///
  /// Derived from the live metrics rather than from a widget-per-tile visibility
  /// library: the grid is a fixed-extent grid, so the range is arithmetic, and
  /// `AGENTS.md` §11 is the standing rule about adding a dependency for something the
  /// framework already reports.
  bool _onGridScroll(ScrollNotification n, BoxConstraints grid) {
    final m = n.metrics;
    if (m.axis == Axis.vertical &&
        m.viewportDimension > 0 &&
        grid.maxWidth > 0) {
      // Fixed extents: `SliverGridDelegateWithMaxCrossAxisExtent` derives them from the
      // **width** it is given, and `viewportDimension` is the height.
      final rowHeight = _rowHeight(grid.maxWidth);
      final first = (m.pixels / rowHeight).floor();
      final rows = (m.viewportDimension / rowHeight).ceil() + 1;
      final perRow = _columnsFor(grid.maxWidth);
      _markThumbsWanted(first * perRow,
          (first + rows) * perRow + _thumbLookahead);
    }
    return false;
  }

  /// Width of a tile, in dp, exactly as the grid delegate computes it.
  ///
  /// `SliverGridDelegateWithMaxCrossAxisExtent` divides the cross axis into as many
  /// extents of at most `maxCrossAxisExtent` as fit; mirroring the arithmetic is what
  /// lets the scroll handler name a tile index. [gridWidth] is the **width** of the
  /// grid's box — not `ScrollMetrics.viewportDimension`, which is a height on this
  /// axis, and passing that here is what made the end of the card unreachable.
  ///
  /// It is used for **look-ahead only** — no layout depends on it — so being
  /// conservative costs one extra fetch and never a wrong picture.
  static double _tileExtent(double gridWidth) {
    const maxExtent = 170.0;
    const spacing = 6.0;
    const padding = 12.0;
    final usable = gridWidth - padding;
    final columns = (usable / (maxExtent + spacing)).ceil().clamp(1, 64);
    return (usable - spacing * (columns - 1)) / columns;
  }

  static int _columnsFor(double gridWidth) {
    if (gridWidth <= 0) return 1;
    return ((gridWidth - 12.0) / (_tileExtent(gridWidth) + 6.0))
        .round()
        .clamp(1, 64);
  }

  /// Tile height: `childAspectRatio: 0.8`, so height = width / 0.8, plus the row gap.
  static double _rowHeight(double gridWidth) =>
      _tileExtent(gridWidth) / 0.8 + 6.0;

  // --------------------------------------------------------------- selection

  void _toggleSelect(AssetGroup g) {
    // One tick per tile, selection and deselection alike: they are the same one bit of
    // state, and the tile that was just tapped is under the thumb — a selection the user
    // cannot feel is the reason this exists. It is the same call the dials make for a
    // detent (`ui/haptics.dart`, `detentTick`), because it is the same event: a discrete
    // selection moved. Deliberately **not** the dials' `commandSent` — nothing leaves for
    // the camera when a tile is ticked.
    //
    // Nothing else on this page ticks. The sync, share and delete buttons act on the
    // whole selection and report through the list and the snackbar; a tick there would be
    // a second, weaker copy of a message the user can already read.
    detentTick();
    setState(() {
      final k = g.id.key;
      if (!_selected.remove(k)) _selected.add(k);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _syncSelected() async {
    final chosen = _groups.where((g) => _selected.contains(g.id.key)).toList();
    if (chosen.isEmpty) return;
    _syncGroups(chosen);
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  /// Queue [chosen] for transfer without touching the camera yet.
  ///
  /// The original app's download queue is user-driven and serialised; adding a
  /// task must not race the live-view HTTP control path. The sync bar owns the
  /// explicit start action, so preview remains safe until the user starts it.
  ///
  /// What each shot contributes is the plan's business, not this loop's: the RAW is
  /// ~32 MB against the JPEG's ~4.9 MB, so it rides along only if the user asked for
  /// it (`AppState.queuePlan`).
  void _syncGroups(List<AssetGroup> chosen) {
    if (chosen.isEmpty) return;
    for (final g in chosen) {
      sync.enqueueSelected(plannedQueue([g], app.queuePlan));
    }
    setState(() {});
  }

  /// Switch the sync mode, and re-derive the job list to match it.
  ///
  /// The page is the only widget that holds the listing, so it is the page that has
  /// to tell the engine what "everything I have seen so far" means. The *rule* —
  /// what each mode does to the list — lives in `SyncEngine.reinterpret`, because it
  /// is a statement about transfers rather than about pixels, and it is checked in
  /// the plain Dart VM.
  ///
  /// The confirmation is a snackbar rather than a dialog: this control is a selector
  /// the user may try three times in a row, and a modal in front of it would be
  /// dismissed unread. It says what moved, so "the list changed under me" has an
  /// answer on screen.
  void _applySyncMode(SyncMode m) {
    final note = app.setSyncMode(m, plannedQueue(_groups, app.queuePlan));
    if (note == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(note),
        duration: const Duration(seconds: 4),
      ));
  }

  /// Turn the RAW opt-in on or off, and make the queue agree with what it now means.
  ///
  /// ## Why switching it *on* adds to the queue, and switching it off does not remove
  ///
  /// The switch is the thing that decides what a sync spends, and a queue built under
  /// the old answer would silently mean something other than what the switch says —
  /// the defect `SyncEngine.reinterpret` exists to prevent for the mode selector. So
  /// turning it **on** queues the RAW of the shots already listed: otherwise a user who
  /// browsed the card, turned the RAW on and pressed start would get exactly nothing
  /// for it, which is the "control that appears and does nothing" failure this project
  /// keeps paying for.
  ///
  /// Turning it **off** adds nothing and removes nothing. Cancelling queued work from a
  /// switch would make a selector destructive, which is the argument
  /// `SyncEngine.reinterpret` already makes about the mode dropdown; and what is queued
  /// is visible and cancellable one row at a time in the job list, behind `List (N)`
  /// (`AGENTS.md` §4.6). The RAW already queued therefore still transfers, and the
  /// tiles keep saying so while it does — `_rawWaiting`.
  ///
  /// Either way nothing leaves for the camera until the user starts the sync, and the
  /// snackbar says so rather than leaving them to infer it.
  void _applyIncludeRaw(bool includeRaw) {
    app.includeRaw = includeRaw;
    if (!includeRaw || !mounted) return;
    final raws = [
      for (final f in plannedQueue(_groups, app.queuePlan))
        if (f.isRaw) f,
    ];
    final added = raws.isEmpty ? 0 : sync.enqueueSelected(raws);
    if (!mounted) return;
    setState(() {});
    if (added == 0) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(l10nOf(context).syncRawQueued(added)),
        duration: const Duration(seconds: 5),
      ));
  }

  /// The per-shot menu.
  ///
  /// Every entry is gated on the shot actually being on the phone first: a Share
  /// that opens a sheet attaching nothing, or an Open that does nothing at all, is
  /// worse than a disabled item that says why. [AppState.localIdsFor] is the
  /// single source of that truth, so the menu and the action cannot disagree.
  void _showShotMenu(AssetGroup g) {
    final l = l10nOf(context);
    final onPhone = app.localIdsFor([g]).isNotEmpty;
    final synced = app.sync.ledger.qualityOf(g.id);

    // No `backgroundColor`, deliberately, and no `Material` wrapper either.
    //
    // `showModalBottomSheet` builds its own `Material`, and a `backgroundColor`
    // argument makes it wrap that Material's child in a **`ColoredBox`** — which
    // then sits between the tiles and the Material they paint their ink splashes
    // on, covering the effects it was meant to tint. The framework asserts on
    // exactly that ("ListTile background color or ink splashes may be invisible /
    // The ListTile is wrapped in a ColoredBox that has a background color"), and
    // the assertion fires at build time, so the sheet crashed the album on long
    // press. The app's dark surface colour already comes from the theme.
    //
    // `test/ui_smoke_test.dart` is the only check in this repo that executes a
    // widget, and this is what it found.
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            ListTile(
              dense: true,
              title: Text(g.primary.path,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              subtitle: Text(
                onPhone
                    ? l.albumOnThisPhone(synced.name)
                    : l.albumNotOnPhone,
                style: TextStyle(
                    color: onPhone ? Colors.lightGreenAccent : Colors.white38,
                    fontSize: 11.5),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ListTile(
              leading: const Icon(Icons.ios_share, color: Colors.white70),
              title: Text(l.actionShare,
                  style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                onPhone
                    ? l.actionShareSubtitleOnPhone
                    : l.actionShareSubtitleNotOnPhone,
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
              enabled: onPhone,
              onTap: () {
                Navigator.pop(sheetContext);
                _shareOne(g);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new, color: Colors.white70),
              title: Text(l.actionOpen,
                  style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                onPhone
                    ? l.actionOpenSubtitleOnPhone
                    : l.actionShareSubtitleNotOnPhone,
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
              enabled: onPhone,
              onTap: () {
                Navigator.pop(sheetContext);
                _openGroup(g);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download, color: Colors.white70),
              title: Text(l.actionSyncThis,
                  style: const TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(sheetContext);
                _syncGroups([g]);
              },
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline,
                  color: Colors.orangeAccent),
              title: Text(l.actionRemoveFromPhone,
                  style: const TextStyle(color: Colors.orangeAccent)),
              subtitle: Text(l.actionRemoveFromPhoneSubtitle,
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11.5)),
              enabled: onPhone,
              onTap: () {
                Navigator.pop(sheetContext);
                _removeLocal(g);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text(l.actionDeleteFromCamera,
                  style: const TextStyle(color: Colors.redAccent)),
              subtitle: Text(l.actionDeleteFromCameraSubtitle,
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11.5)),
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() {
                  _selecting = true;
                  _selected
                    ..clear()
                    ..add(g.id.key);
                });
                _deleteSelected();
              },
            ),
            ],
          ),
        ),
      ),
    );
  }

  /// Share a single shot, without entering selection mode.
  Future<void> _shareOne(AssetGroup g) async {
    final l = l10nOf(context);
    await app.shareGroups([g], title: l.albumShareSheetTitle(1));
    if (mounted) _showNotice();
  }

  // ------------------------------------------------------------------ share

  /// Hand the selected shots to the system share sheet (spec T20–T24).
  ///
  /// Only the shots already on this phone can be shared, and [AppState.shareGroups]
  /// reports how many that was rather than failing outright — a partial share is
  /// the honest outcome when a sync is still running, and the alternative (refuse
  /// until everything is local) makes the button look broken during the one moment
  /// the user most wants it.
  Future<void> _shareSelected() async {
    final chosen = _selectedGroups;
    if (chosen.isEmpty) return;
    final l = l10nOf(context);
    final n = await app.shareGroups(chosen,
        title: l.albumShareSheetTitle(chosen.length));
    if (!mounted) return;
    if (n > 0) setState(() => _selecting = false);
    _showNotice();
  }

  /// Open one shot in whatever app the phone has for it.
  Future<void> _openGroup(AssetGroup g) async {
    await app.openGroup(g);
    if (mounted) _showNotice();
  }

  /// Remove the phone's copy, leaving the camera's alone.
  ///
  /// Confirmed first: this deletes from the user's gallery, which is outside the
  /// app and not undoable from it.
  Future<void> _removeLocal(AssetGroup g) async {
    final l = l10nOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF141414),
        title: Text(l.albumRemoveConfirmTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          l.albumRemoveConfirmBody(g.primary.path),
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.remove),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await app.removeLocalCopy(g);
    if (mounted) {
      setState(() {});
      _showNotice();
    }
  }

  /// Surface whatever the last action had to say, if anything.
  ///
  /// `lastError` and `lastNotice` are how [AppState] reports these without this
  /// page having to guess an outcome; both are cleared once shown so a stale
  /// message cannot be re-displayed by an unrelated rebuild.
  ///
  /// The strings come from the resolvers rather than the raw fields: `AppState`
  /// keeps its English as the fallback and travels with a code, so this is where the
  /// chosen language is picked (`lib/l10n/message_text.dart`). A message with no code
  /// — a `LinkStatus` sentence, a `DeleteReport` summary — is returned unchanged.
  void _showNotice() {
    final l = l10nOf(context);
    final err = appErrorText(l, app);
    final note = appNoticeText(l, app);
    if (err == null && note == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? note!),
      backgroundColor: err != null ? Colors.red.shade900 : null,
      duration: const Duration(seconds: 4),
    ));
    app.clearMessages();
  }

  // ------------------------------------------------------------------ delete

  /// The shots currently selected, in album order.
  List<AssetGroup> get _selectedGroups =>
      [for (final g in _groups) if (_selected.contains(g.id.key)) g];

  /// Delete the selection from the camera's card.
  ///
  /// Deleting is the one action in this app that cannot be taken back — the
  /// camera has no undo, no recycle bin, and **no watchdog**: a request it does
  /// not expect can wedge it until the battery comes out. So the order here is
  /// deliberate:
  ///
  /// 1. decide what would be sent, and what will be refused **with a reason**,
  ///    before anything is sent (`planDelete`);
  /// 2. make the user read the count that is about to leave the card, and that
  ///    the app cannot put it back;
  /// 3. send it one request at a time, naming the batch in flight;
  /// 4. report **per file**, from a fresh listing, and save that report rather
  ///    than flashing a snackbar — a toast that says "deleted" is the exact
  ///    failure this firmware invites, because it answers `200` to work it did
  ///    not do.
  Future<void> _deleteSelected() async {
    final chosen = _selectedGroups;
    if (chosen.isEmpty) return;

    final plan = planDelete(chosen);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteConfirmDialog(plan: plan),
    );
    if (ok != true || !mounted) return;

    if (plan.isEmpty) {
      // Everything selected was refused. Reload anyway: the refusals are now
      // shown permanently, and this is the only path on which the confirmation's
      // "irreversible" line is wrong.
      setState(() {
        _deleteRefusals = plan.refusals;
        _deleteReport = null;
      });
      return;
    }

    final l = l10nOf(context);
    setState(() {
      _deleteRefusals = plan.refusals;
      _deleteReport = null;
      _deleteProgress =
          (index: 0, total: plan.batches.length, label: l.albumDeleteStarting);
    });

    final report = await app.deleteFiles(
      chosen,
      onBatch: (batch, index, total) {
        if (mounted) {
          setState(() =>
              _deleteProgress = (index: index, total: total, label: batch.label));
        }
      },
    );

    if (!mounted) return;
    setState(() {
      _deleteProgress = null;
      _deleteReport = report;
      _selected.clear();
      _selecting = false;
      if (report != null) _dropDeletedRows(report);
    });

    // The delete failure is drawn through the resolver, not the raw field: `AppState`
    // keeps the English as the fallback and travels with a code, so this is where the
    // chosen language is picked (`lib/l10n/message_text.dart`).
    final deleteError = appErrorText(l10nOf(context), app);
    if (report == null && deleteError != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(deleteError),
        duration: const Duration(seconds: 5),
      ));
    }
  }

  /// Remove only the shots a fresh listing confirmed are gone.
  ///
  /// A RAW+JPEG row needs **both** halves confirmed: leaving the row up when one
  /// file is still on the card is the only way the user can see the orphan, and
  /// taking it down would hide it.
  void _dropDeletedRows(DeleteReport report) {
    final gone = report.removedShots;
    if (gone.isEmpty) return;
    final removedIds = {
      for (final g in _groups)
        if (gone.contains(shotIdentity(g.primary.path))) g.id.key,
    };
    _groups.removeWhere((g) => removedIds.contains(g.id.key));
    for (final k in removedIds) {
      _thumbs.remove(k);
      _selected.remove(k);
      // The disk entry goes with the row, and this is the one form of staleness the key
      // cannot see for itself. The key is `path|capture second`, so a **delete followed
      // by a same-named file inside the same second** is the same key with different
      // bytes. The app knows about its own deletes — the report in hand is a fresh
      // listing confirming these paths are gone — so it drops what it cached rather than
      // leaving a picture of a file that no longer exists to be served for a file that
      // does.
      unawaited(app.thumbnailCache.remove(k));
    }
  }

  // ------------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    // The whole page, including the sync bar, rebuilds when the app says something
    // changed. Sync state lives in the engine, the engine's one change callback
    // belongs to `AppState`, and `AppState` notifying its listeners is therefore the
    // only path by which an engine change reaches this screen — see the note in
    // `initState` for the reassignment that used to break exactly that.
    //
    // An `AnimatedBuilder` here rather than a `listener` plus `setState`: it is the
    // same pattern the shell uses, it needs no teardown, and it cannot be left
    // attached to a disposed state.
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => _pageShell(l),
    );
  }

  /// The page itself, built from whatever the app currently says.
  ///
  /// Split out of [build] only so the `AnimatedBuilder` above has a closure to run.
  Widget _pageShell(AppLocalizations l) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151515),
        foregroundColor: Colors.white,
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selecting = false;
                  _selected.clear();
                  _deleteReport = null;
                  _deleteRefusals = const [];
                }),
              )
            : null,
        title: Text(_selecting
            ? l.albumSelectedCount(_selected.length)
            : l.albumTitleCount(_groups.length)),
        actions: _selecting
            ? [
                IconButton(
                  key: const ValueKey<String>('btn-album-sync-selected'),
                  tooltip: l.albumSyncSelectedTooltip,
                  onPressed: _selected.isEmpty || _deleteProgress != null
                      ? null
                      : _syncSelected,
                  icon: const Icon(Icons.download),
                ),
                // Delete is not a long-press or a swipe: this camera has no undo
                // and no watchdog, so it lives behind a button that names what it
                // is about to do, and behind a confirmation that counts it.
                IconButton(
                  key: const ValueKey<String>('btn-album-delete-selected'),
                  tooltip: _deleteProgress == null
                      ? l.albumDeleteSelectedTooltip
                      : l.albumDeleteBusyTooltip,
                  color: Colors.redAccent,
                  onPressed: _selected.isEmpty || _deleteProgress != null
                      ? null
                      : _deleteSelected,
                  icon: const Icon(Icons.delete_outline),
                ),
              ]
            : [
                IconButton(
                  key: const ValueKey<String>('btn-album-select'),
                  tooltip: l.albumSelectTooltip,
                  onPressed: _groups.isEmpty
                      ? null
                      : () => setState(() => _selecting = true),
                  icon: const Icon(Icons.checklist),
                ),
                IconButton(
                  key: const ValueKey<String>('btn-album-reload'),
                  // ## Why this is no longer called "Reload"
                  //
                  // Three controls in this page read as "fetch the listing again",
                  // and the user reported that the toolbar button and the prompt
                  // shown right after connecting "conflict a little". They were
                  // right, and the reason is that these are three different
                  // operations:
                  //
                  // * this one throws away everything the page knows — the listing,
                  //   the thumbnails, the paging position, the delete report — and
                  //   then asks the card from the **first** page. That is what a
                  //   refresh icon on a toolbar should mean, and the tooltip says so;
                  // * the empty state's button (`btn-album-look-again`) only asks
                  //   again when the card reported nothing;
                  // * the read-failure button (`btn-album-retry-listing`) only
                  //   retries the page that failed.
                  //
                  // The words are distinct because the operations are: a user who
                  // taps "Reload everything" and one who taps "Look for photos
                  // again" are asking for different amounts of work from a
                  // single-threaded camera.
                  tooltip: l.albumReloadTooltip,
                  // The re-list is scheduled rather than called inline: `_loadPage`
                  // starts with `setState`, and calling it from inside this `setState`
                  // would be a callback during the build it is already in.
                  onPressed: () {
                    setState(() {
                      _groups.clear();
                      _thumbs.clear();
                      // The "already asked" record and the failed set go with the
                      // listing they describe. Without this a reload would keep a
                      // transient failure marked permanent for the life of the page
                      // — the "one failure becomes a blank tile forever" case.
                      //
                      // ## The disk cache deliberately does **not** go with them
                      //
                      // A reload means "ask the camera for the listing again". It does
                      // not mean the pictures on the card have changed, and every entry
                      // in the disk cache is keyed by the shot it was fetched for
                      // (`path|capture second`, `album_thumbnail_cache.dart`), so an
                      // entry can only ever describe the file it came from.
                      //
                      // Dropping it would also cost the user the thing this button is
                      // most often used for. `analysis/70` §18 documents the reload as
                      // **the way to retry failed thumbnails**, and the failures it
                      // exists to retry are not in the cache to begin with — nothing is
                      // ever written for a tile that failed. Clearing it would turn a
                      // retry into "re-fetch every thumbnail from a single-threaded
                      // camera", which is the request pressure (`AGENTS.md` §4.6) this
                      // cache was added to remove.
                      _thumbAsked.clear();
                      _thumbFailed.clear();
                      _thumbWanted.clear();
                      _page = 0;
                      _moreAvailable = true;
                      // The error goes with the listing it described: without this a
                      // failure message outlives the failure, and the next visit to
                      // this tab reads it as current.
                      _error = null;
                      _deleteReport = null;
                      _deleteRefusals = const [];
                      _selecting = false;
                      _selected.clear();
                    });
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _loadPage());
                  },
                  icon: const Icon(Icons.refresh),
                ),
              ],
      ),
      // The sync bar sits above the grid in portrait, and in a **side column** on a
      // wide, short window.
      //
      // Measured on a 914x411 landscape screen: stacked, the bar took ~140dp and the
      // grid was left about 60dp, so the tiles rendered as a sliver with their capture
      // dates cut off — the page worked and could not be used. Dropping the switch's
      // explanatory subtitle recovered ~28dp, which was not enough.
      //
      // The viewfinder already solved this shape of problem with `ViewfinderLayout`'s
      // side bands, and this is the same answer: a landscape window is wide and short,
      // so spend width, not height. It is also what the user asked for in general
      // terms — the empty margin beside a 4:3 image on a wide screen is where the
      // controls belong.
      //
      // Width is tested *and* compared against height: a wide-but-tall window (a
      // tablet in portrait) has room for the stack and reads better with it.
      body: LayoutBuilder(
        builder: (context, window) {
          final syncBar = _SyncBar(
            app: app,
            onSyncModeChanged: _applySyncMode,
            onIncludeRawChanged: _applyIncludeRaw,
          );

          // Everything that belongs above the photos stays above them in both
          // layouts; only the sync bar moves.
          final above = <Widget>[
            if (_deleteProgress != null)
              _DeleteProgressBar(
                index: _deleteProgress!.index,
                total: _deleteProgress!.total,
                label: _deleteProgress!.label,
              ),
            if (_deleteReport != null || _deleteRefusals.isNotEmpty)
              _DeleteResultPanel(
                report: _deleteReport,
                refusals: _deleteRefusals,
                onDismiss: () => setState(() {
                  _deleteReport = null;
                  _deleteRefusals = const [];
                }),
              ),
            if (_selecting && _selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                // `Wrap` rather than `Row`: three labelled buttons do not fit across
                // a phone in portrait, and a squashed "Share 12" is worse than one
                // that moves to a second line. The user explicitly asked for
                // landscape to be usable, and a `Row` here overflows in portrait.
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _deleteProgress == null ? _syncSelected : null,
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(l.albumSyncCount(_selected.length)),
                    ),
                    // Share sits next to Sync rather than behind a menu: after a
                    // sync finishes, sending the shots on is the very next thing the
                    // user does, and spec T20–T24 is the table-stakes feature the
                    // previous build shipped without entirely.
                    FilledButton.icon(
                      onPressed: _deleteProgress == null ? _shareSelected : null,
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: Text(l.albumShareCount(_selected.length)),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade900,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _deleteProgress == null ? _deleteSelected : null,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(l.albumDeleteCount(_selected.length)),
                    ),
                  ],
                ),
              ),
          ];

          // **Measured**, not chosen: the bar's rows have a minimum intrinsic width.
          // At 310dp it overflowed by 71px and at 384dp by 22px, which puts the floor
          // at about 406dp — the summary row's button plus the mode dropdown, neither
          // of which shrinks. 420 gives it a little room.
          //
          // A narrower column is therefore not an option until those rows are made
          // responsive in their own right (`Wrap`, or stacking the button under the
          // summary when the column is tight). That is the follow-up; this constant is
          // the honest current answer, and `album_landscape_test.dart` fails if the
          // bar grows past it.
          const minBarWidth = 420.0;
          final sideBySide = window.maxWidth >= minBarWidth + 300 &&
              window.maxWidth > window.maxHeight;
          if (!sideBySide) {
            return Column(
              children: [syncBar, ...above, Expanded(child: _body(l))],
            );
          }
          final columnWidth = window.maxWidth * 0.46 < minBarWidth
              ? minBarWidth
              : (window.maxWidth * 0.46 > 460 ? 460.0 : window.maxWidth * 0.46);
          return Row(
            children: [
              Expanded(
                child: Column(
                  children: [...above, Expanded(child: _body(l))],
                ),
              ),
              Container(
                width: columnWidth,
                color: const Color(0xFF151515),
                child: SingleChildScrollView(child: syncBar),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _body(AppLocalizations l) {
    if (app.album == null) {
      return _Message(
        icon: Icons.wifi_off,
        title: l.albumNotConnectedTitle,
        body: l.albumNotConnectedBody,
      );
    }

    if (_error != null && _groups.isEmpty) {
      return _Message(
        icon: Icons.error_outline,
        title: l.albumReadFailedTitle,
        body: l.albumReadFailedBody(_error!),
        action: FilledButton.icon(
          key: const ValueKey<String>('btn-album-retry-listing'),
          onPressed: _loadPage,
          icon: const Icon(Icons.refresh),
          label: Text(l.albumRetryListing),
        ),
      );
    }

    if (_groups.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_groups.isEmpty) {
      return _Message(
        icon: Icons.photo_outlined,
        title: l.albumEmptyTitle,
        body: l.albumEmptyBody,
        action: FilledButton.icon(
          key: const ValueKey<String>('btn-album-look-again'),
          onPressed: _loadPage,
          icon: const Icon(Icons.refresh),
          // Distinct from the toolbar's "Reload everything": this one re-asks for
          // the page that came back empty and touches nothing else. Calling both of
          // them "Reload" is what made the toolbar button and the post-connect
          // prompt look like one control doing two different things.
          label: Text(l.albumLookAgain),
        ),
      );
    }

    // A `GridView` asserts when it is laid out with zero cross-axis extent
    // (`crossAxisExtent > 0.0` is not true), and this page can genuinely be given
    // no room: in landscape the sync bar and the shutter chrome can consume the
    // whole body, and the grid then receives `crossAxisExtent: 0.0`. Reported from
    // the emulator as a framework assertion plus two follow-on null-check
    // exceptions, which is a crash rather than a cosmetic problem.
    //
    // Returning an empty box in that case keeps the page alive; the grid appears as
    // soon as there is space, because a `LayoutBuilder` rebuilds when the
    // constraints change.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            // Thumbnails first: the tile the user is looking at is the one worth a
            // request, and this is the only place that knows which it is. The grid's
            // own box is passed in because the notification's metrics carry the
            // **height** (`viewportDimension`) and the arithmetic needs the width —
            // see [_onGridScroll].
            _onGridScroll(n, constraints);
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 600 &&
                _moreAvailable &&
                !_loading) {
              _loadPage();
            }
            return false;
          },
          child: GridView.builder(
            padding: const EdgeInsets.all(6),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 170,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 0.8,
            ),
            itemCount: _groups.length,
            itemBuilder: (context, i) => _tile(l, _groups[i]),
          ),
        );
      },
    );
  }

  Widget _tile(AppLocalizations l, AssetGroup g) {
    final key = g.id.key;
    final thumb = _thumbs[key];
    final failed = _thumbFailed.contains(key);
    final selected = _selected.contains(key);

    // The ledger is the truth about what is on the phone, so the badge cannot
    // claim a file is saved when it is not.
    final saved = app.ledger.qualityOf(g.id);
    final rawWaiting = _rawWaiting(g);
    final inQueue = sync.items.where((i) => i.id.key == key).toList();
    final active = inQueue.where((i) => i.stage.isActive).firstOrNull;

    return GestureDetector(
      // Keyed per shot rather than one shared key, for the same reason the job list's
      // remove buttons are: a check (and Marionette) must be able to name **this**
      // tile, and `find.byType` cannot tell a tile that has a picture from one that
      // does not. `ValueKey` on the outer widget, so the grid's `find.byKey` lands on
      // the tile and not on the `Image` inside it.
      key: ValueKey<String>('album-tile-$key'),
      onTap: () {
        if (_selecting) {
          _toggleSelect(g);
        } else {
          Navigator.of(context).push(MaterialPageRoute<void>(
            // The whole listing, not just this shot: the viewer is a `PageView`, so
            // opening a photo has to hand it the photos either side or a flick has
            // nowhere to go. `_groups` is already newest-first (`groupAssets`), which is
            // the order the swipe should follow.
            builder: (_) => AssetViewerPage(
              app: app,
              groups: List<AssetGroup>.unmodifiable(_groups),
              initialIndex: _groups.indexOf(g),
            ),
          ));
        }
      },
      onLongPress: () {
        // Long-press opens the per-shot menu rather than jumping straight into
        // selection mode. Before this, the only way to share or open a single
        // shot was to enter selection mode and then find it again among the
        // action buttons — and there was no way at all to open the phone's copy
        // in another app.
        _showShotMenu(g);
      },
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(6),
          border: selected
              ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ## `thumb.isNotEmpty` is not defensive
            //
            // Zero bytes reach the decoder as the exact failure reported from the
            // phone: `FlutterImageDecoderImplDefault: Failed to decode image` /
            // `ImageDecoder$DecodeException`. The camera produces them — a `.DNG`
            // answers `Thumbnail` with `204` and no body — so the one thing this
            // widget must never do is hand an empty buffer to `Image.memory`.
            // `CameraAlbum.download` now refuses an empty body and `_pumpThumbs`
            // refuses to store one; this is the third and last guard, at the point
            // where the decoder is actually reached.
            if (thumb != null && thumb.isNotEmpty)
              Image.memory(thumb,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  // A thumbnail that will not decode is a thing this camera
                  // produces: the response is the raw file body, so a truncated
                  // transfer or a JSON error body lands here as bytes that are not
                  // a JPEG. `Image.memory` throws for those, and before this the
                  // throw reached `FlutterError.onError` and replaced the whole app
                  // with "The app failed to start" — reported from hardware as a
                  // sporadic `Exception: Invalid image data`. A tile with no
                  // picture is a far better outcome than a dead app.
                  errorBuilder: (context, error, stack) => const Center(
                    child: Icon(Icons.broken_image_outlined,
                        color: Colors.white24, size: 22),
                  ))
            // Asked for and refused: an icon, not a spinner. A spinner claims work
            // is in flight, and for a `.DNG` on this firmware none ever will be —
            // there is no thumbnail to wait for. It is drawn only after the whole
            // chain has failed, so it cannot appear over a tile that is still
            // loading.
            else if (failed)
              const Center(
                child: Icon(Icons.image_not_supported_outlined,
                    color: Colors.white24, size: 22),
              )
            else
              const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),

            // RAW / video badge: one row per shutter press, so the type has to
            // be visible on the row rather than implied by a second entry.
            //
            // And, under it, whether a RAW this shot owns is **still on its way** —
            // the other half of the same fact, and the half that used to be missing.
            // The tile said `RAW+JPG` from the moment the shot was listed, so a RAW
            // that had landed and one that was still waiting looked identical; that is
            // what `AssetGroup.rawPending` was written for and had no caller for
            // (`analysis/79`, finding #2).
            //
            // One `Column` under one `Positioned`: two `Positioned` at `top: 4` would
            // draw the second line on top of the first.
            if (g.badge.isNotEmpty || rawWaiting)
              Positioned(
                top: 4,
                left: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (g.badge.isNotEmpty) _Tag(text: _badgeText(l, g)),
                    if (rawWaiting) ...[
                      const SizedBox(height: 2),
                      _Tag(
                        key: ValueKey<String>('album-raw-pending-$key'),
                        text: l.albumRawPending,
                      ),
                    ],
                  ],
                ),
              ),

            // Saved state, read from the ledger rather than guessed.
            if (saved.isOriginal)
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.check_circle, size: 16, color: Colors.greenAccent),
              )
            else if (saved.isAtLeastPreview)
              Positioned(
                top: 4,
                right: 4,
                child: Tooltip(
                  message: l.albumPreviewPending,
                  child: const Icon(Icons.circle_outlined,
                      size: 16, color: Colors.orangeAccent),
                ),
              ),

            if (g.primary.isPathTooLong)
              Positioned(
                bottom: 22,
                right: 4,
                child: Tooltip(
                  message: l.albumPathTooLong,
                  child: const Icon(Icons.warning_amber,
                      color: Colors.amber, size: 16),
                ),
              ),

            if (active != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 20,
                child: _ProgressRibbon(item: active),
              ),

            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                color: Colors.black87,
                child: Text(
                  g.primary.captureTime == null
                      ? g.primary.fileName
                      : '${_two(g.primary.captureTime!.month)}/${_two(g.primary.captureTime!.day)} '
                          '${_two(g.primary.captureTime!.hour)}:${_two(g.primary.captureTime!.minute)}',
                  style: const TextStyle(color: Colors.white, fontSize: 10.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Whether this tile's shot owns a RAW that is on its way and not here yet.
  ///
  /// Two halves, and they live in two layers for a reason:
  ///
  /// * **`AssetGroup.rawPending`** is the sync layer's own answer — the shot owns a
  ///   RAW and the ledger does not have it. It takes the ledger lookup as a predicate
  ///   because only this page knows what "on the phone" means here (the ledger, at
  ///   original quality: a preview-quality `.DNG` is not the RAW that was asked for).
  /// * **"and it is still coming"** is this page's, because the policy is: the switch
  ///   says it for anything queued from now on, and the job list says it for a RAW
  ///   queued before the switch was turned off — `_applyIncludeRaw` does not cancel
  ///   work, so those keep arriving and the tiles keep saying so.
  ///
  /// Without the second half the badge would be wrong in the state the product
  /// **launches** in: with the switch off no RAW is fetched, and every pair tile would
  /// carry "RAW pending" forever, claiming work that will never happen.
  bool _rawWaiting(AssetGroup g) {
    final raw = g.raw;
    if (raw == null) return false;
    if (!g.rawPending(
        (f) => app.ledger.has(assetIdOf(f), atLeast: AssetQuality.original))) {
      return false;
    }
    return app.includeRaw || sync.items.any((i) => i.file.path == raw.path);
  }
}

// ---------------------------------------------------------------------------

/// Sync controls and progress.
///
/// The design guide's central warning (§5.6) is that the classic failure mode is
/// not an error message but a progress bar that stops moving. So: a named state
/// per item, a denominator, and distinguish "the camera went away" from "the
/// transfer failed".
///
/// ## Stateful, and only for one reason
///
/// Whether the job list is expanded. The engine calls `onChanged` every time an item
/// changes stage, so a `StatefulWidget` that remembers this is the difference between
/// a list the user opened and a list that snaps shut on the next progress tick.
/// Nothing else here is state.
class _SyncBar extends StatefulWidget {
  final AppState app;

  /// Called when the user picks a different sync mode.
  ///
  /// The page holds the album listing, so it is the only widget that can say what
  /// "everything I have seen so far" means; the bar just reports the intent.
  final void Function(SyncMode mode) onSyncModeChanged;

  /// Called when the user turns the RAW opt-in on or off.
  ///
  /// The page owns this too, and for a stronger version of the same reason: flipping it
  /// **on** has to queue the RAW of the shots already listed, and only the page has the
  /// listing. See `_applyIncludeRaw`.
  final void Function(bool includeRaw) onIncludeRawChanged;

  const _SyncBar({
    required this.app,
    required this.onSyncModeChanged,
    required this.onIncludeRawChanged,
  });

  @override
  State<_SyncBar> createState() => _SyncBarState();
}

class _SyncBarState extends State<_SyncBar> {
  /// Whether the queued shots are listed under the controls.
  ///
  /// ## Why the list starts closed
  ///
  /// It sits in the same column as the switch and the mode selector, and in
  /// landscape that column's height comes out of the photo grid's height. A
  /// permanently expanded list would push the mode selector off the bottom of a
  /// 297dp body on every sync — and a bar that takes the height it should be taking
  /// width for is the measured defect that left the grid a 60dp sliver before.
  /// Closed by default costs one line; opening it is one tap.
  bool _listOpen = false;

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final app = widget.app;
    final sync = app.sync;
    final s = sync.summary;
    // Only the shots a run would still fetch. An item already saved is history, and
    // an item the user struck out is gone — neither belongs in a list of what is
    // queued.
    final queued = sync.items
        .where((i) =>
            !i.stage.isTerminal && i.stage != SyncStage.pausedByUser)
        .toList();

    return Container(
      color: const Color(0xFF151515),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.total == 0
                      ? l.syncNothingQueued
                      : s.toString(),
                  // Named so a check (and Marionette's `getRect`) can measure **this**
                  // line rather than matching its words: the sentence is built by the
                  // Flutter-free sync layer (`SyncSummary.toString`) and is not
                  // localized, so matching text would pin English into the harness.
                  key: const ValueKey<String>('sync-bar-summary'),
                  // ## Why this line is capped, and why the cap is the fix
                  //
                  // `Expanded` above bounds this text's **width** and nothing bounded its
                  // **height**. The button beside it is laid out at its intrinsic width
                  // and cannot shrink — flex lays the inflexible children out first, with
                  // an unbounded main axis, and the `Expanded` gets what is left — so on a
                  // phone in English (`Start sync (60 photos)`: 22 characters against
                  // Chinese's 10) the text is left a sliver and, with no `maxLines`, wraps
                  // to **one character per line**. Measured at 411x727 with a 60-shot
                  // queue: the summary line came out **468.0dp tall and 14.8dp wide**, the
                  // bar took **656dp of the 671dp body**, and the photo grid was left
                  // **15dp** — the album was unusable, and it was unusable in the one mode
                  // the product launches in (an automatic one, which is what queues a
                  // browsed card).
                  //
                  // Two lines, not one: at this width the sentence really does use both
                  // (measured after the cap: 36.0dp in **both** locales, i.e. two lines),
                  // so a one-line cap would ellipsize a sentence that fits today — and the
                  // tail it would eat is where ", N failed" lives. Two lines is also the
                  // most height a status line may cost the grid.
                  //
                  // What the ellipsis eats is the **tail** (`N originals, N previews`,
                  // `N failed`), never the head: the head is "done of total", which is
                  // the part a glance needs. Nothing is hidden by this — the same counts
                  // are on the progress bar above, on `List (N)` beside it, and per shot
                  // in the job list behind that button — and the queue itself is never
                  // summarized away (`AGENTS.md` §4.6: queued is not transferring).
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ),
              // Three distinct states, because one toggle could not express them.
              //
              // This used to be a single button reading "Pause" whenever anything
              // was pending, so with a queue waiting and nothing running the only
              // control *paused* — and the run then needed a second tap to resume.
              // Reported from hardware as "you have to tap pause and then resume to
              // get a sync at all", which is exactly what that control did.
              //
              // Starting is now its own action, and it is the one the user reaches
              // for: after queueing photos the button says what it will do.
              if (s.running)
                TextButton.icon(
                  key: const ValueKey<String>('btn-sync-pause'),
                  onPressed: sync.pause,
                  icon: const Icon(Icons.pause, size: 18),
                  label: Text(l.syncPause),
                )
              else if (sync.paused)
                TextButton.icon(
                  key: const ValueKey<String>('btn-sync-resume'),
                  // `app.resumeSync()`, not `sync.resume()`.
                  //
                  // The engine's own `resume()` clears its flag and hands over to
                  // `run()`, and `run()` notifies **nothing** when it returns early —
                  // which it does whenever a run is already in flight or the camera
                  // is away (`analysis/57`). Tapping this button in either of those
                  // states then left the bar still reading "Resume" on an engine that
                  // was not paused, and tapping it again did the same silent thing.
                  // `AppState.resumeSync` is the same call with the notification the
                  // engine's early return skips.
                  onPressed: app.resumeSync,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(l.syncResume),
                )
              else if (s.pending > 0)
                FilledButton.icon(
                  key: const ValueKey<String>('btn-sync-start'),
                  onPressed: app.beginTransfer,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(l.syncStart(s.pending)),
                ),
            ],
          ),

          if (s.total > 0) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: s.total == 0 ? 0 : s.done / s.total,
                minHeight: 4,
                backgroundColor: Colors.white12,
              ),
            ),
          ],

          if (s.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(s.note!,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 11.5, height: 1.3)),
            ),

          // Why the preview went still, said out loud.
          //
          // §5.3 has the engine pause the live view for the length of a bulk
          // transfer, because the stream and a full-resolution download share one
          // 802.11n link. The user's screen is on the other tab, so this line and
          // the banner on the preview are what stop a deliberate pause from
          // reading as "the app broke" — the exact confusion the design guide
          // warns a silent pause produces.
          if (s.streamPausedForTransfer)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.pause_circle_outline,
                        size: 15, color: Colors.lightBlueAccent),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      s.streamPauseReason ??
                          l.syncPreviewPausedWhileTransfer,
                      style: const TextStyle(
                          color: Colors.lightBlueAccent,
                          fontSize: 11.5,
                          height: 1.3),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 6),
          Row(
            children: [
              Text(l.syncLabel,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(width: 4),
              Expanded(
                child: DropdownButton<SyncMode>(
                  key: const ValueKey<String>('btn-sync-mode'),
                  isExpanded: true,
                  value: sync.mode,
                  dropdownColor: const Color(0xFF1E1E1E),
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  items: [
                    DropdownMenuItem(
                      value: SyncMode.autoPreviewThenOriginal,
                      child: Text(l.syncModeAutoPreviewThenOriginal),
                    ),
                    DropdownMenuItem(
                      value: SyncMode.autoOriginalOnly,
                      child: Text(l.syncModeAutoOriginalOnly),
                    ),
                    DropdownMenuItem(
                      value: SyncMode.manualOnly,
                      child: Text(l.syncModeManualOnly),
                    ),
                  ],
                  onChanged: (m) {
                    if (m != null) widget.onSyncModeChanged(m);
                  },
                ),
              ),
              // The way into the job list. It lives in **this** row rather than one of
              // its own for the reason the whole bar's width is a measured constant:
              // the mode dropdown above is `isExpanded` and so absorbs the slack,
              // which means a button here costs the column nothing. A row of its own
              // would cost ~36dp of the grid's height in landscape, which is the
              // resource this page has least of.
              //
              // A labelled button and not a tappable summary line, because a list
              // nobody can find is a list that does not exist — the same mistake as
              // the landscape full-screen mode that shipped with no line in the
              // release notes, and was never used (`AGENTS.md` §7.1).
              TextButton(
                key: const ValueKey<String>('btn-sync-list'),
                onPressed: () => setState(() => _listOpen = !_listOpen),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _listOpen ? l.syncHideList : l.syncListCount(queued.length),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),

          // ------------------------------------------------------- the job list
          //
          // Reading this list touches the camera **not at all**: every row is built
          // from the engine's own items and the ledger. That matters on this hardware
          // — a list that refreshed itself with a `GetFileList` would be a second
          // request competing with the preview and with the transfer it is describing
          // (`analysis/37`–`39`).
          if (_listOpen) _jobList(l, queued, sync),

          // Opt-out. Pausing the stream is the right default — measured on the real
          // body the live view and a full-resolution download are in the same league
          // over the one 802.11n radio: the stream runs at ~52–57 KB per datagram at
          // ~30/s, about 12–14 Mbit/s, and a `GetFile` at ~13.5 Mbit/s — but someone
          // who wants to keep framing a shot while a backlog drains is making a
          // legitimate choice, and a preview that froze with no way to say "don't"
          // would read as a bug.
          //
          // This comment used to put the stream at ~4.2 Mbit/s. That figure came from
          // a 40-frame sample of a **flat** scene and understated it about threefold;
          // the 12–14 Mbit/s is 48 697 datagrams / 2.56 GB counted by
          // `tools/camera_bridge.py` (`analysis/49` §1.1). The contention argument
          // survives the correction; the arithmetic under it did not.
          //
          // Wrapped in `Material` because the enclosing bar is a coloured
          // `Container`, and `SwitchListTile` paints its background and ink
          // splashes on the **nearest** `Material` ancestor: without this the
          // framework throws at build time ("The ListTile is wrapped in a
          // ColoredBox that has a background color"), which meant this whole
          // screen failed to build. Found by `test/ui_smoke_test.dart` — the
          // first check in this repo that executes a widget rather than reading
          // it.
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              key: const ValueKey<String>('toggle-pause-stream'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              value: sync.pauseStreamDuringTransfer,
              onChanged: (v) => sync.pauseStreamDuringTransfer = v,
              title: Text(l.syncPauseStreamTitle,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              // Dropped on a short screen (landscape). Two lines of explanation
              // cost about 28dp, and on a 914x411 window that was most of what the
              // photo grid had left — measured on the emulator, the tiles came out
              // as a sliver with their dates cut off while the bar explained itself
              // at length. The title already says what the switch does; the
              // reasoning belongs here, in the source, and in `analysis/37`.
              //
              // Pausing the stream is the right default — measured on the real body
              // the live view and a full-resolution download are in the same league
              // over the one 802.11n radio (the stream ~12–14 Mbit/s, the transfer
              // ~13.5 Mbit/s) — but someone who wants to keep framing a shot while a
              // backlog drains is making a legitimate choice, and a preview that froze
              // with no way to say "don't" would read as a bug. (This used to say
              // ~4.2 Mbit/s for the stream; that was a flat-scene sample — see the
              // note on the comment above.)
              subtitle: MediaQuery.sizeOf(context).height < 520
                  ? null
                  : Text(
                      l.syncPauseStreamDetail,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11, height: 1.3),
                    ),
            ),
          ),

          // The RAW opt-in. **Off by default**, which is the decision
          // `transport/album.dart` documents and which nothing used to implement — so
          // until this switch existed, "ships off" was a sentence in a comment and the
          // queue did the opposite (`analysis/79`, finding #2).
          //
          // ## Why both lines are capped, and why the cost leads the title
          //
          // The bar shares a column with the photo grid, and in portrait that column's
          // height comes *out of the grid* — the measured defect
          // `album_sync_bar_height_test.dart` exists for. This switch is one more row
          // in that column, so it is capped like the summary line above it: **one**
          // line of label and **two** of note. Uncapped, the note alone came out around
          // eight lines at the phone's 1.6x font setting (the test font is about twice
          // Roboto's width, so the harness is the worst case) and took the grid from
          // 443dp to **275dp of a 671dp body** — the check caught exactly that.
          //
          // The cost is in the label — `RAW (.DNG) too — ~32 MB a shot` — rather than
          // only in the note, because the note is the *first* thing dropped when there
          // is no room: entirely on a short screen, and after two lines on a long one.
          // And the number sits in the **first half** of the label on purpose: an
          // ellipsized tail must never be where "32 MB" lives.
          //
          // `Material` for the same measured reason as the switch above: this bar is a
          // coloured `Container`, and a `SwitchListTile` paints its ink on the nearest
          // `Material` ancestor — without one the framework throws at build time and
          // the whole screen fails to draw.
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              key: const ValueKey<String>('toggle-sync-raw'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              value: app.includeRaw,
              // Through the page, not straight to `app`: turning it on has to queue
              // the RAW of the shots already listed, or the switch would do nothing
              // for a card the user has already browsed.
              onChanged: widget.onIncludeRawChanged,
              title: Text(l.syncRawTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              subtitle: MediaQuery.sizeOf(context).height < 520
                  ? null
                  : Text(
                      l.syncRawDetail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11, height: 1.3),
                    ),
            ),
          ),

          if (sync.items.any((i) => i.stage == SyncStage.failed))
            TextButton.icon(
              onPressed: () {
                for (final i in sync.items) {
                  if (i.stage == SyncStage.failed) {
                    i.stage = SyncStage.queued;
                    i.attempts = 0;
                  }
                }
                app.beginTransfer();
              },
              icon: const Icon(Icons.replay, size: 16),
              label: Text(l.syncRetryFailed,
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  /// The queued shots, one row each, with a way to strike one out.
  ///
  /// ## Why a list rather than just a count
  ///
  /// The queue is the only place in this page where a user can commit hundreds of
  /// megabytes over a slow radio without seeing what they agreed to. The summary
  /// tells them *how much* ("Start sync (312 photos)"); it cannot tell them *which*,
  /// and it offers no way back if the answer is "not that one".
  ///
  /// ## What removing a row does, and does not do
  ///
  /// * it does **not** touch the camera — no `DeleteFile`, no `GetFile`; the card
  ///   still holds the photo, and cancelling a transfer is not permission to start
  ///   one (`AGENTS.md` §4.6);
  /// * it does **not** delete anything already on the phone — that is the shot menu's
  ///   "Remove from this phone", a different action with its own confirmation;
  /// * it removes the shot from **this job list**, now and after a restart: the
  ///   durable record goes with it, or the next launch would restore work the user
  ///   just cancelled.
  Widget _jobList(AppLocalizations l, List<SyncItem> queued, SyncEngine sync) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 2),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  queued.isEmpty
                      ? l.syncNothingLeftToFetch
                      : l.syncStillToFetch(queued.length),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              if (queued.isNotEmpty)
                TextButton(
                  key: const ValueKey<String>('btn-sync-list-clear'),
                  onPressed: () {
                    final n = sync.clearPending();
                    setState(() {});
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(SnackBar(
                        content: Text(l.syncRemovedFromList(n)),
                        duration: const Duration(seconds: 3),
                      ));
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l.syncClearList,
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
          // A bounded height, because this list shares a column with the photo grid
          // and in landscape that column's height takes width from the grid.
          //
          // **`ConstrainedBox` and not `Flexible`.** A `Flexible` here makes the bar's
          // own `Column` a flex parent, and in landscape that `Column` sits inside the
          // side column's `SingleChildScrollView`, which hands it an **unbounded**
          // height — the framework then throws `RenderFlex children have non-zero flex
          // but incoming height constraints are unbounded` and the whole page fails to
          // build. `shrinkWrap` plus a cap gives the same result with no flex at all:
          // the list is as tall as its contents up to 220dp, and scrolls beyond that.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: queued.length,
              itemBuilder: (context, i) => _jobRow(l, queued[i], sync),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: Text(
              l.syncRemoveRowNote,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 10.5, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  /// One queued shot: what it is, how far along, and a way to cancel it.
  Widget _jobRow(AppLocalizations l, SyncItem item, SyncEngine sync) {
    final saved = sync.ledger.qualityOf(item.id);
    // The state is named rather than spun (§5.6): "Stalled, retrying" and "Paused,
    // camera away" are different things a user can act on differently.
    final state = _stateLine(l, item);
    // A row for a shot that is in flight says so, because cancelling it cannot be
    // instant: the request on the wire is allowed to finish and its reply is thrown
    // away. Saying "queued" there would promise an immediacy the camera cannot give
    // without a command that has never worked on it.
    final note = item.stage.isActive
        ? l.syncStageInFlight
        : saved.isAtLeastPreview
            ? l.syncStagePreviewSaved
            : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.file.fileName,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  note == null ? state : '$state · $note',
                  style: TextStyle(
                    color: item.stage == SyncStage.failed
                        ? Colors.redAccent
                        : item.stage.isActive
                            ? Colors.lightBlueAccent
                            : Colors.white38,
                    fontSize: 10.5,
                    height: 1.25,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Uniquely keyed per shot rather than one shared key, so a test can cancel
          // the *n*th row specifically — and so Marionette can reach any row of a
          // three-hundred-row queue rather than only the first match.
          IconButton(
            key: ValueKey<String>('btn-sync-list-remove-${item.id.key}'),
            tooltip: l.syncCancelTransfer,
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: () {
              sync.removeItem(item);
              setState(() {});
            },
            icon: const Icon(Icons.close, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  /// The state line for one queued shot.
  ///
  /// Bytes when there is no reliable size, matching the progress ribbon on the tile:
  /// a made-up percentage is worse than none.
  ///
  /// [l] is threaded in rather than read from a context because this is a `static`
  /// helper: the stage is a `SyncStage`, whose English `label` belongs to the
  /// Flutter-free sync layer (`AGENTS.md` §4.1), so the localized text comes from
  /// `syncStageText` in `lib/l10n/message_text.dart`, keyed by the stage's own code.
  static String _stateLine(AppLocalizations l, SyncItem item) {
    final stage = syncStageText(l, item.stage);
    if (!item.stage.isActive) return stage;
    final p = item.progress;
    final where = p == null
        ? _ProgressRibbon._kb(item.bytesReceived)
        : '${(p * 100).round()}%';
    return '$stage — $where';
  }
}

/// The confirmation. A dialog, and the **only** modal in this page.
///
/// §5.6 says never modal, and it is right about sync: a 200-frame backlog must not
/// block the app, so the sync UI is a bar and a notification. Deleting is the
/// documented exception, because it is the one action here that the app **cannot
/// undo** — the file is on the camera's card, the camera has no recycle bin, and
/// nothing in this protocol can put it back. The guide's own stance is that an app
/// which quietly does the wrong thing is worse than one that explains a gap; a
/// destructive action with no confirmation is the loudest version of that.
///
/// The dialog counts in **shots**, matching the grid, and names everything that
/// will *not* be deleted before the user agrees to the rest — so "delete 12" and
/// "nothing was sent for these 2" are both read before anything leaves the phone.
class _DeleteConfirmDialog extends StatelessWidget {
  final DeletePlan plan;
  const _DeleteConfirmDialog({required this.plan});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final n = plan.shotCount;
    final pairs = plan.files - plan.shotCount;

    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: Text(
        n == 0 ? l.deleteNothingHereTitle : l.deleteConfirmTitle(n),
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (n > 0)
              Text(
                l.deleteConfirmBody(plan.files,
                    pairs > 0 ? l.deletePairsSuffix(pairs) : '',
                    plan.batches.length),
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.4),
              ),
            if (n > 0)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  l.deleteIrreversibleWarning,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 12.5, height: 1.4),
                ),
              ),
            if (plan.hasRefusals) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(l.deleteWillNotBeTouched,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              for (final r in plan.refusals)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '• ${r.file.fileName} — ${r.reason}',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11.5, height: 1.35),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.deleteKeepThem),
        ),
        if (n > 0)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade900,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.deleteConfirmAction(n)),
          ),
      ],
    );
  }
}

/// The wait, named: which request of how many is in flight.
///
/// A spinner here would be the silent stall §5.6 warns about — a delete of 300
/// photos is ten round trips over a link that drops, and "batch 4 of 10" is the
/// difference between waiting and wondering.
class _DeleteProgressBar extends StatelessWidget {
  final int index;
  final int total;
  final String label;
  const _DeleteProgressBar({
    required this.index,
    required this.total,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return Container(
      color: const Color(0xFF2A1515),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.deleteProgress(index.clamp(1, total), total, label),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// The outcome, per file, and **kept on screen**.
///
/// This firmware answers `200` to work it did not do, so a snackbar reading
/// "deleted" would be a claim the app cannot support. What it can support is:
/// the request was accepted, and here is what a fresh listing says about each
/// path. Anything the listing could not settle is called *unconfirmed* and stays
/// visible with a Reload button, because the user's next move — checking the
/// camera, or deleting on it by hand — depends on knowing which files are in
/// doubt.
class _DeleteResultPanel extends StatefulWidget {
  final DeleteReport? report;
  final List<DeleteRefusal> refusals;
  final VoidCallback onDismiss;
  const _DeleteResultPanel({
    required this.report,
    required this.refusals,
    required this.onDismiss,
  });

  @override
  State<_DeleteResultPanel> createState() => _DeleteResultPanelState();
}

class _DeleteResultPanelState extends State<_DeleteResultPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final r = widget.report;
    final failed = r?.of(DeleteVerdict.failed) ?? const <DeleteOutcome>[];
    final unconfirmed =
        r?.of(DeleteVerdict.unconfirmed) ?? const <DeleteOutcome>[];
    final clean = r != null && r.allConfirmed && widget.refusals.isEmpty;

    return Container(
      color: const Color(0xFF151515),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                clean ? Icons.check_circle_outline : Icons.info_outline,
                size: 16,
                color: clean ? Colors.greenAccent : Colors.orangeAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r == null
                      ? l.deleteNothingSent
                      : r.summary,
                  style: TextStyle(
                    color: clean ? Colors.white70 : Colors.orangeAccent,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? l.deleteHide : l.deleteDetails,
                    style: const TextStyle(fontSize: 12)),
              ),
              IconButton(
                tooltip: l.dismiss,
                iconSize: 16,
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.close),
              ),
            ],
          ),

          // The two states that must never be summarised away, stated even when
          // the panel is collapsed.
          if (unconfirmed.isNotEmpty)
            Text(
              l.deleteUnconfirmed(unconfirmed.length),
              style: const TextStyle(
                  color: Colors.orangeAccent, fontSize: 11.5, height: 1.35),
            ),
          if (failed.isNotEmpty)
            Text(
              l.deleteStillOnCard(failed.length),
              style: const TextStyle(
                  color: Colors.orangeAccent, fontSize: 11.5, height: 1.35),
            ),

          if (_expanded) ...[
            const SizedBox(height: 6),
            for (final o in r?.outcomes ?? const <DeleteOutcome>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '${o.verdict == DeleteVerdict.confirmedGone ? '✓' : '•'} '
                  '${_short(o.path)} — ${o.message}',
                  style: TextStyle(
                    color: o.verdict == DeleteVerdict.confirmedGone
                        ? Colors.white38
                        : Colors.orangeAccent,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ),
            for (final f in widget.refusals)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '• ${f.file.fileName} — ${f.reason}',
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 11, height: 1.3),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _short(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}

class _ProgressRibbon extends StatelessWidget {
  final SyncItem item;
  const _ProgressRibbon({required this.item});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = item.progress;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      color: Colors.black.withValues(alpha: 0.72),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.stage == SyncStage.stalled
                  ? l.syncRetrying
                  : syncStageText(l, item.stage),
              style: const TextStyle(color: Colors.white, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Report bytes when there is no reliable size: a made-up percentage is
          // worse than no percentage.
          Text(
            p == null ? _kb(item.bytesReceived) : '${(p * 100).round()}%',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }

  static String _kb(int n) => n >= 1024 * 1024
      ? '${(n / 1048576).toStringAsFixed(1)}M'
      : '${(n / 1024).round()}K';
}

/// The badge for one album row, in the reader's language.
///
/// [AssetGroup.badge] is the sync layer's own tag, and that layer owns no strings
/// (`AGENTS.md` §4.1) — so the three kinds this app has words for are resolved here,
/// where a tag becomes pixels, and the group's own string is left as the fallback for
/// a kind this build has never been taught about.
String _badgeText(AppLocalizations l, AssetGroup g) {
  if (g.isPair) return l.albumRawJpgBadge;
  if (g.isRawOnly) return l.albumRawBadge;
  if (g.primary.isVideo) return l.albumVideoBadge;
  return g.badge;
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 9.5)),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.white24),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12.5, height: 1.45)),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Full-screen viewer, preview first.
///
/// This is the "preview-first, original-later" idea (§D2) applied to the thing
/// the user actually does: tapping a photo. The `MidThumb` rendition is roughly
/// 186 KB against the original's 9.4 MB, so the picture appears in well under a
/// second on this link instead of after several, and the full-resolution file
/// loads behind it.
class AssetViewerPage extends StatefulWidget {
  final AppState app;

  /// Every shot the viewer may show, newest first — the same order as the grid.
  ///
  /// A list rather than one shot, because the viewer is a `PageView`: a flick goes to
  /// the next photo, which is what any gallery does and what the counter in the app bar
  /// is for.
  final List<AssetGroup> groups;

  /// Which of [groups] to open on.
  final int initialIndex;

  const AssetViewerPage({
    super.key,
    required this.app,
    required this.groups,
    this.initialIndex = 0,
  });

  @override
  State<AssetViewerPage> createState() => _AssetViewerPageState();
}

/// The shot currently on screen, for anything above the viewer that has to name it.
///
/// Marionette presses buttons by `ValueKey` and a route pop is a tap on a *position*;
/// a check that has to click an overlay control needs to know where the page is first.
/// The index travels as a widget rather than as a global so it costs nothing and is
/// scoped to the frame that drew it — the same reasoning as the grid's per-tile keys
/// (`AGENTS.md` §5, and `analysis/70`'s note about tiles having no key at all).
class ViewerPageIndex extends InheritedWidget {
  final int index;

  const ViewerPageIndex({required this.index, required super.child, super.key});

  static int? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ViewerPageIndex>()?.index;

  @override
  bool updateShouldNotify(ViewerPageIndex old) => old.index != index;
}

class _AssetViewerPageState extends State<AssetViewerPage> {
  late final PageController _pages;
  late int _index;

  /// Bumped every time the page in view changes.
  ///
  /// ## What this is for, and what it is not
  ///
  /// A photo's preview request is allowed to be **dropped** when the user has moved on
  /// — see [CameraRequestTicket.wanted] for exactly what dropping can and cannot mean
  /// against a single-threaded server. The generation counter is how a pending load
  /// finds out: it captured a number, and a number that has moved on means nobody is
  /// waiting for those bytes any more.
  int _generation = 0;

  /// Whether the shot on screen is zoomed in.
  ///
  /// Read here rather than on each photo because it is the **PageView's** physics that
  /// depend on it: while a photo is magnified a horizontal drag has to pan it, and it
  /// cannot do both that and turn the page.
  bool _zoomed = false;

  AppState get app => widget.app;

  AssetGroup get group => widget.groups[_currentIndex];

  /// The index to draw, clamped — a caller that named a shot it no longer holds gets
  /// the first one rather than an exception inside `build`.
  int get _currentIndex =>
      widget.groups.isEmpty ? 0 : _index.clamp(0, widget.groups.length - 1);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _index = index;
      _generation++;
      // A page that was magnified keeps its own zoom — the controller is the photo's,
      // not this page's — but the *next* photo must start swipeable.
      _zoomed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final g = group;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(g.primary.fileName, style: const TextStyle(fontSize: 15)),
        actions: [
          if (widget.groups.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Text(
                  l.viewerPosition(_currentIndex + 1, widget.groups.length),
                  key: const ValueKey<String>('viewer-position'),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ),
          IconButton(
            // Keyed like every other control a check has to press (`AGENTS.md` §5):
            // Marionette and `flutter_test` otherwise have to locate it by its
            // tooltip, and a tap that resolves mid-route-transition derives an offset
            // outside the window and **silently misses** — which reads as "this button
            // does nothing" rather than as a harness problem.
            key: const ValueKey<String>('btn-viewer-save-to-phone'),
            tooltip: l.viewerSaveToPhone,
            onPressed: () {
              // The plan, not `group.assets`: this is a queue action, so the RAW comes
              // along only when the user's switch says so (`AppState.queuePlan`), and
              // the two used to disagree — the documentation said the RAW was opt-in
              // while this button queued it every time.
              app.sync.enqueueSelected(plannedQueue([g], app.queuePlan));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(l.viewerQueued),
                duration: const Duration(seconds: 2),
              ));
            },
            icon: const Icon(Icons.download),
          ),
        ],
      ),
      // ## The containment fix: the viewer IS the body, and the chrome floats over it
      //
      // This used to be `Column > Expanded > Center > InteractiveViewer`. `Center` sizes
      // itself to its **child**, and `InteractiveViewer` sizes its viewport to what it is
      // given — so the clip rect, the pan boundary and every drawn pixel were bounded by
      // the photo's own intrinsic size. That is the report, exactly: *"the zoomed viewer
      // cannot fill the screen — it is constrained to the area the un-zoomed photo
      // occupied."* Nothing was wrong with `maxScale`; the box was wrong.
      //
      // A `Stack` with `Positioned.fill` gives the viewer the whole body, and the badges
      // sit **on top of** it rather than above it, so a zoomed photo has the full screen
      // to pan in.
      body: Stack(
        children: [
          Positioned.fill(
            child: ViewerPageIndex(
              index: _currentIndex,
              child: PageView.builder(
                key: const ValueKey<String>('viewer-pages'),
                controller: _pages,
                // While a photo is magnified, a horizontal drag is a pan. The
                // alternative is what the report describes from the other side: every
                // attempt to look at the edge of a photo turns the page instead.
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                onPageChanged: _onPageChanged,
                itemCount: widget.groups.length,
                itemBuilder: (context, i) {
                  final shot = widget.groups[i];
                  return IndexedStack(
                    // ## Why every page is wrapped in an `IndexedStack`, with a key
                    //
                    // This is not decoration — it is the fix for a real state-loss bug
                    // found while writing the checks. `PageView` keeps its neighbours
                    // built, and without a stable key per **page index** the element for
                    // the page being scrolled to does not line up with the element that
                    // was there before. Flutter then builds a fresh element, which
                    // destroys and recreates that page's `State` — and a recreated state
                    // has `_autoTried == false`, so a photo the user had already been
                    // shown asks the camera for its preview **a second time**.
                    //
                    // A `PageView`-shaped widget cannot be relied on to give the same
                    // answer, so the key pins it: a page index is the same page for the
                    // life of this route.
                    key: ValueKey<String>('viewer-page-$i'),
                    index: 0,
                    children: [
                      _ViewerPhoto(
                        key: ValueKey<String>('viewer-photo-${shot.id.key}'),
                        app: app,
                        group: shot,
                        isCurrent: i == _currentIndex,
                        generation: _generation,
                        onZoomChanged: (z) {
                          if (z == _zoomed || !mounted) return;
                          setState(() => _zoomed = z);
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One photo in the viewer.
///
/// ## Why it is a widget of its own rather than state on the page
///
/// The viewer is a `PageView`, so "the photo on screen" is a *page*, and everything
/// about showing one — the local read, the camera request, the zoom, the pan, the
/// quality badge — belongs to that page rather than to the route. Keeping it on the
/// page would mean one set of fields being reset on every swipe, which is how a
/// previous shot's bytes end up labelled as the next one's.
///
/// ## The load, and the three rules it obeys
///
/// `analysis/39` and `AGENTS.md` §4.6 are the constraints, and this round added a
/// fourth requirement of its own (the maintainer asked for the preview to load when a
/// photo opens). In order:
///
/// 1. **The phone first, always.** A `content://` URI in the ledger means the shot is
///    already here, so it is read from the phone and the camera is not touched at all.
///    Not even for a thumbnail: a photo the user already owns must be viewable with the
///    camera switched off. This is the rule that was paid for with a wedged camera, and
///    the automatic preview does not weaken it — a sync happens precisely so the viewer
///    stops talking to the camera.
/// 2. **A ledger entry whose bytes are gone is reported, not re-fetched.** The user
///    deleted it from the gallery; silently re-downloading would hide that.
/// 3. **One request, at one rendition, only for the photo on screen.** `MidThumb` is
///    the measured middle size (`analysis/61` §1: 196,495 B against the original's
///    5,565,238 B), so the picture is on screen in well under a second on this link.
///    `Original` is never automatic — it is 4.9 MB for a JPEG and 31.9 MB for a RAW,
///    and the app bar's download button is how the user asks for the real file.
///    **No fallback chain on the automatic path**: `analysis/70` §15 shows why a chain
///    is right for the grid and wrong here — the grid's chain starts at the *cheapest*
///    rendition, so a `204` there is cheap to step past, while a chain from `MidThumb`
///    would send a second request to a single-threaded camera for a rendition this page
///    does not need. A failure here is shown, with the explicit button beside it.
/// 4. **Dropped when the user moves on.** A request still queued when the page changes
///    is never sent (see [CameraRequestTicket.wanted]); one already on the wire is
///    allowed to finish and its bytes are discarded.
///
/// ## And what it costs
///
/// One `GetFile` at `MidThumb` per photo opened: **196,495 B measured** on the real
/// body, against the live view's ~17.5 KB/frame at ~30 fps — about **0.5 MB/s** of
/// sustained UDP (`analysis/ce-app-competitive-spec.md` §5.3). So one preview is on the
/// order of **0.4 s** of the radio at the streaming rate, which is why it is worth
/// serialising and not worth doing speculatively.
class _ViewerPhoto extends StatefulWidget {
  const _ViewerPhoto({
    super.key,
    required this.app,
    required this.group,
    required this.isCurrent,
    required this.generation,
    required this.onZoomChanged,
  });

  final AppState app;
  final AssetGroup group;

  /// Whether this page is the one being shown.
  ///
  /// The `PageView` builds its neighbours too, so this is what keeps "only the photo on
  /// screen" true: a neighbour that is merely being kept alive does not ask the camera
  /// for anything.
  final bool isCurrent;

  /// The page-change counter this photo's pending requests were started under.
  final int generation;

  /// Told when this photo's zoom crosses back and forth over 1x, because the page's
  /// swipe physics depend on it.
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ViewerPhoto> createState() => _ViewerPhotoState();
}

class _ViewerPhotoState extends State<_ViewerPhoto> {
  Uint8List? _image;
  AssetQuality _shown = AssetQuality.none;
  bool _loading = false;
  bool _upgrading = false;
  String? _error;
  int _bytes = 0;

  /// The `content://` URI being displayed, when the bytes came from the phone.
  String? _localUri;

  /// Whether the automatic preview has already been tried for this photo.
  ///
  /// One shot per photo, like the grid's `_thumbAsked`: this camera has no watchdog and
  /// the page must not re-ask on every rebuild. Cleared when the load **fails**, so a
  /// transient failure leaves a way forward rather than a dead end.
  bool _autoTried = false;

  /// The zoom, owned here so that a page can be magnified and then swiped away from
  /// without the next photo inheriting the matrix.
  final TransformationController _zoom = TransformationController();

  /// What a double tap zooms to.
  ///
  /// Sized from the measurement rather than picked: on a portrait phone the fitted
  /// picture is limited by the screen's **width**, so covering the viewport needs
  /// `viewportHeight / fittedHeight` ≈ 2.5x for a 4:3 photo. 3 is that with margin, and
  /// stays inside `maxScale` so the clamp is not what makes the assertion true.
  static const double _doubleTapScale = 3.0;

  /// The largest scale the viewer offers.
  static const double _maxScale = 6.0;

  /// Where the last tap landed, in the viewer's own coordinates — the focal point a
  /// double tap zooms about.
  Offset? _lastTap;

  AppState get app => widget.app;
  AssetGroup get group => widget.group;

  /// Whether asking the camera for this photo is still the right thing to do.
  bool get _wanted =>
      widget.isCurrent && app.link.isReady && app.album != null;

  @override
  void initState() {
    super.initState();
    unawaited(_ensureLoaded());
  }

  @override
  void didUpdateWidget(_ViewerPhoto old) {
    super.didUpdateWidget(old);
    // Two ways this photo becomes loadable after it was built: the page arrived (the
    // `PageView` may have built it as a neighbour first), or the link came up while the
    // viewer was open. Both are the same question, so both go through the same gate.
    if (!old.isCurrent && widget.isCurrent) {
      _autoTried = false;
      unawaited(_ensureLoaded());
    } else if (old.generation != widget.generation && widget.isCurrent) {
      unawaited(_ensureLoaded());
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// Load this photo: the phone's copy if there is one, otherwise one preview from the
  /// camera.
  Future<void> _ensureLoaded() async {
    if (!mounted || _autoTried || _image != null) return;
    _autoTried = true;

    // ---- 1. the phone, and it is not a fallback
    final localUri = app.ledger.localIdOf(group.id);
    if (localUri != null && localUri.isNotEmpty) {
      final bytes = await MediaStoreBridge.read(localUri);
      if (!mounted) return;
      if (bytes != null && bytes.isNotEmpty) {
        setState(() {
          _image = bytes;
          _shown = app.ledger.qualityOf(group.id);
          _bytes = bytes.length;
          _localUri = localUri;
        });
        return;
      }
      // The ledger says it is here and the bytes are not: the user deleted it from the
      // gallery. Say so rather than silently re-downloading — and **do not** let the
      // automatic preview cover for it, because then the deletion is invisible and the
      // camera is asked for a photo the user thought they had.
      if (mounted) {
        final l = l10nOf(context);
        setState(() {
          _error = l.albumSavedCopyGone;
          _autoTried = false;
        });
      }
      return;
    }

    // ---- 2. nothing local, so one preview from the camera — if it is the right moment
    await _fetch(preview: true, automatic: true);
  }

  /// Fetch from the camera, automatically or on an explicit request.
  Future<void> _fetch({required bool preview, required bool automatic}) async {
    final album = app.album;
    if (automatic) {
      // Not connected, not the page in view, or the page moved on while this was being
      // scheduled: the camera is not asked. Silently — this is the normal outcome of a
      // flick through a card, not a failure to report.
      final generation = widget.generation;
      if (!_wanted) {
        _clearProvisional();
        return;
      }
      final started = generation;
      setState(() {
        _error = null;
        _loading = true;
      });
      try {
        final bytes = await album!.download(
          group.primary,
          resolution: FileResolution.midThumb,
          // Interactive: the user is looking at this photo, and the grid's chain can be
          // holding the camera for a 31.9 MB `.DNG`. See `CameraRequestGate`.
          priority: CameraRequestPriority.interactive,
        );
        if (!mounted) return;
        // ^ the page is gone
        if (started != widget.generation) {
          // Dropped: the user moved on. The bytes are discarded rather than drawn, and
          // nothing is reported — an error message about a photo nobody is looking at
          // is a lie about what happened.
          return;
        }
        setState(() {
          _image = bytes;
          _shown = AssetQuality.preview;
          _loading = false;
          _bytes = bytes.length;
        });
      } on CameraRequestDropped {
        // Never sent: the gate skipped it because the page had already moved on.
        if (mounted) setState(() => _loading = false);
      } on Object catch (e) {
        if (!mounted) return;
        _reportFailure(e, allowAutoRetry: false);
      }
      return;
    }

    // ---- the explicit path: the user pressed the button
    if (album == null) {
      setState(() => _error = l10nOf(context).albumNotConnectedShort);
      return;
    }
    setState(() {
      _error = null;
      _upgrading = true;
      _bytes = 0;
    });
    try {
      final bytes = await album.download(
        group.primary,
        resolution: preview ? FileResolution.midThumb : FileResolution.original,
        priority: CameraRequestPriority.interactive,
        onProgress: (n) {
          if (mounted) setState(() => _bytes = n);
        },
      );
      if (!mounted) return;
      setState(() {
        _image = bytes;
        _shown = preview ? AssetQuality.preview : AssetQuality.original;
        _upgrading = false;
        _bytes = bytes.length;
      });
    } on CameraRequestDropped {
      if (mounted) setState(() => _upgrading = false);
    } on Object catch (e) {
      if (!mounted) return;
      _reportFailure(e, allowAutoRetry: preview);
    }
  }

  /// Put a failure on screen, and decide whether it may be retried on its own.
  ///
  /// A failure that is never retried and never shown is the spinner-forever defect
  /// `analysis/70` records; a failure that is retried on every rebuild is a request
  /// storm against a single-threaded camera. So the automatic path is allowed to fail
  /// **once**: [allowAutoRetry] is false for the automatic preview, which means the
  /// next attempt is the user pressing the button — and the message names what happened
  /// so they know there is something to press it for.
  void _reportFailure(Object e, {required bool allowAutoRetry}) {
    final l = l10nOf(context);
    setState(() {
      _loading = false;
      _upgrading = false;
      _autoTried = allowAutoRetry;
      _error = l.albumLoadFailed('$e');
    });
    debugPrint('[viewer] ${group.primary.path}: $e');
  }

  /// Clear the "still loading" state of a request that was never sent.
  void _clearProvisional() {
    if (!mounted) return;
    if (_loading) setState(() => _loading = false);
  }

  void _onTapDown(TapDownDetails d) => _lastTap = d.localPosition;

  /// Double tap: fit-to-screen, or zoom to [_doubleTapScale] about the tap.
  void _toggleZoom() {
    final v = context.size;
    if (v == null) return;
    final zoomedIn = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (zoomedIn) {
      _zoom.value = Matrix4.identity();
    } else {
      final at = _lastTap ?? Offset(v.width / 2, v.height / 2);
      _zoom.value = Matrix4.identity()
        ..translateByDouble(
            -at.dx * (_doubleTapScale - 1),
            -at.dy * (_doubleTapScale - 1),
            0,
            1)
        ..scaleByDouble(_doubleTapScale, _doubleTapScale, 1, 1);
    }
    widget.onZoomChanged(!zoomedIn);
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final bytes = _image;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null)
          // ## The viewer is the box, and the picture fits inside it
          //
          // Nothing here sizes anything to the photo. `Positioned.fill` above gives the
          // `PageView` the whole body, the page is that size, and this fills the page —
          // so the clip rect and the pan boundary are the **screen**, which is the fix
          // for "the zoom is trapped in the un-zoomed photo's box". `BoxFit.contain`
          // then letterboxes the picture inside it, which is what makes one box work for
          // a panorama and for a portrait crop.
          GestureDetector(
            key: const ValueKey<String>('viewer-zoom-surface'),
            onTapDown: _onTapDown,
            onDoubleTap: _toggleZoom,
            child: InteractiveViewer(
              transformationController: _zoom,
              // Both finite and on purpose. `maxScale` is the ceiling the double tap and
              // the pinch are clamped to; there is no `boundaryMargin`, so the picture
              // cannot be flung into empty space and always covers the viewport.
              maxScale: _maxScale,
              minScale: 1.0,
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                // The same guard as the grid: honours the "a bad frame is not a dead
                // app" rule for the full-size view too.
                errorBuilder: (context, error, stack) => Center(
                  child: Text(
                    l.viewerUndecodable,
                    style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                  ),
                ),
              ),
            ),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.4)),
            ),
          )
        else if (_loading)
          // Named work, not an indefinite spinner: the request is real, countable and
          // finishes. When it fails the spinner goes away — see [_reportFailure].
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 10),
              Text(l.viewerLoadingPreview,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        _statusPanel(l),
      ],
    );
  }

  /// The band under the photo: what it is, how good the copy is, and what to do next.
  ///
  /// **On top of the photo, not below it.** It used to be a `Column` sibling, which cost
  /// the viewer whatever height the text happened to need — and the text is localized,
  /// so English and Chinese reserved different amounts. That is a box whose size depends
  /// on the language, and on a page whose job is to show a picture edge to edge it is the
  /// wrong box to be measuring. Over a scrim, in the ordinary photo-viewer shape, the
  /// language can no longer move the picture.
  Widget _statusPanel(AppLocalizations l) {
    final showFetchButton = _image == null && !_loading && !_upgrading;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          // Translucent rather than solid: a magnified photo has to be able to show
          // through, or the bottom of every zoomed picture would sit behind a panel with
          // no pan that could reveal it.
          color: Color(0xB3121212),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.primary.path,
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (group.badge.isNotEmpty) ...[
                      _Tag(text: _badgeText(l, group)),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      switch (_shown) {
                        AssetQuality.original => l.qualityOriginal,
                        AssetQuality.preview => l.qualityPreview,
                        _ => '',
                      },
                      style: TextStyle(
                        color: _shown == AssetQuality.original
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
                // The band says one of these, never two: the centre carries the same
                // sentence when there is no picture, and saying it twice in one view is
                // the duplication this app has been reported for before.
                if (_localUri != null) ...[
                  const SizedBox(height: 4),
                  Text(l.viewerLocalCopy,
                      style:
                          const TextStyle(color: Colors.greenAccent, fontSize: 11.5)),
                ] else if (_image == null && _error == null) ...[
                  // The other half of the sentence the centre is showing while a preview
                  // is on its way: *where* it is coming from. `viewerNotOnPhone` says the
                  // honest thing about the phone and nothing about the camera, so it is
                  // right in both states — before the fetch and during it.
                  const SizedBox(height: 4),
                  Text(l.viewerNotOnPhone,
                      style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                ] else if (_error != null && _image != null) ...[
                  const SizedBox(height: 4),
                  Text(_error!,
                      style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 11, height: 1.3)),
                ],
                if (showFetchButton) ...[
                  const SizedBox(height: 8),
                  // ## Why the automatic preview still leaves a button here
                  //
                  // Three states reach it, and all three need a way forward: nothing
                  // loaded yet (the camera was unreachable, or the preview is still to
                  // come), the automatic preview **failed**, and the app is not
                  // connected. It reads "Load a preview" for a preview and "Load the
                  // full size" once a preview is on screen — one control, whose label is
                  // the rendition it will actually fetch.
                  FilledButton.icon(
                    key: const ValueKey<String>('btn-viewer-fetch-camera'),
                    onPressed: app.link.isReady
                        ? () => unawaited(
                            _fetch(preview: _image == null, automatic: false))
                        : null,
                    icon: const Icon(Icons.cloud_download, size: 18),
                    label: Text(app.link.isReady
                        ? (_image == null
                            ? l.viewerFetchPreview
                            : l.viewerFetchFullSize)
                        : l.viewerCameraNotConnected),
                  ),
                ],
                if (_upgrading) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(l.viewerLoadingFromCamera(_mb(_bytes)),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Bytes as megabytes, for the one line that reports a transfer in progress.
  static String _mb(int n) => '${(n / 1048576).toStringAsFixed(1)} MB';
}
