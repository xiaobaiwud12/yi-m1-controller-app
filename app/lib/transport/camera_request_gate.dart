/// One camera request at a time, with the screen's request ahead of the grid's.
///
/// ## Why this exists
///
/// The camera runs a **single-threaded HTTP server with no watchdog**
/// (`AGENTS.md` §4.6). Two `GetFile` requests in flight do not go faster — they
/// queue inside the camera and raise the chance that something stalls, and the
/// project has paid for that three times (`analysis/37`–`39`).
///
/// Before this file existed, each caller kept that promise **locally**: the album
/// grid's thumbnail loop is serial and the sync engine's queue is serial. That is
/// correct as long as there is exactly one of them, and there stopped being exactly
/// one the moment the photo viewer began loading a preview when it opens. Two
/// independently-serial loops make a parallel pair between them — which is the failure
/// mode the whole rule is about, arrived at without either loop doing anything wrong.
///
/// So the serialisation moves down to the one place every file request already goes
/// through, and the loops above keep their own ordering without having to know about
/// each other.
///
/// ## Why "queued" and not "refused"
///
/// A gate that refused the second caller would be a fourth interlock with its own
/// opinion about when the camera is busy, and the project already has three
/// (`CaptureGuard`, the sync engine's pause contract, the stream-pause controller)
/// that are each other's business. This one does not decide *whether* a request is
/// legitimate; it decides *when* it goes, which is a question with one answer and no
/// policy in it.
///
/// ## Why the priority, and why it is not a nicety
///
/// The grid walks its chain cheapest-rendition-first, and a file with no small
/// rendition walks all of it: a `.DNG` reaches `Original`, which is **31.9 MB** over
/// the camera's own access point (`analysis/50`). A tap on a photo must not wait behind
/// that. The maintainer's own framing is the rule: *only the photo actually on
/// screen*.
///
/// Nothing is starved: [CameraRequestPriority.background] work is served whenever no
/// [CameraRequestPriority.interactive] work is waiting, and every caller releases the
/// gate as soon as its one request is done.
///
/// ## What is deliberately not here
///
/// * **No timing.** No minimum interval, no rate limit. The camera publishes no rate
///   limit, and the loops above already bound their own request rate by what is on
///   screen; a timer here would be a number with nothing measured behind it.
/// * **No cancellation.** See [CameraRequestTicket.wanted] — a single-threaded server
///   cannot un-send a request, and nothing here pretends it can.
library;

import 'dart:async';

/// What a request is for, which is the only thing that decides its turn.
enum CameraRequestPriority {
  /// Something the user is looking at right now: a photo they just opened.
  interactive,

  /// Work that will still be worth doing in a second: grid thumbnails, a sync run.
  background,
}

/// A place in the queue, handed out before the request goes out.
///
/// Returned by [CameraRequestGate.acquire] rather than followed by an opaque
/// `wait()`, because the caller has to be able to ask one question **between** being
/// given the turn and issuing the request — [wanted] — and that question is the
/// difference between a camera doing useful work and a camera serving a photo nobody
/// is looking at.
class CameraRequestTicket {
  CameraRequestTicket._(this._gate, this.priority);

  final CameraRequestGate _gate;

  /// What this request is for, kept so the gate can name what it served.
  final CameraRequestPriority priority;

  bool _released = false;
  bool _dropped = false;

  /// Whether this request is still worth making.
  ///
  /// ## What "dropped" means here, and what it cannot mean
  ///
  /// A single-threaded server **cannot un-send a request**. Once the bytes are on the
  /// wire the camera will answer them, and there is no command in the 45-entry table
  /// that recalls one — so this is not a cancellation and nothing in this project
  /// pretends otherwise. What it is:
  ///
  /// * a request still **in the queue** when its subject goes away is **never sent**.
  ///   That is free, and it is the case that matters when the queue is long;
  /// * a request already **in flight** is allowed to finish, and its bytes are
  ///   discarded by the caller. Starting a second request to "replace" it would put
  ///   two on the camera at once, which is the thing being prevented.
  ///
  /// The gate skips a dropped waiter itself, so a caller that forgets to check cannot
  /// send one; the check at the call site is what makes the *intent* readable. Same
  /// shape as `SyncItem.removed` in `sync_engine.dart`, which drops a transfer's bytes
  /// when the user strikes the shot out of the queue while the request is on the wire.
  bool get wanted => !_dropped;

  /// Mark this ticket as no longer wanted. Idempotent, and safe at any point.
  void drop() => _dropped = true;

  /// Give up the turn.
  ///
  /// **Must be called on every path**, including a throw: a ticket that is never
  /// released holds the gate for the life of the process, which is a camera that stops
  /// answering. [CameraRequestGate.run] does it in a `finally`; a caller that acquires
  /// by hand owns that.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _gate._release();
  }
}

/// Serialises camera file requests, screen-first.
///
/// One at a time, in priority then arrival order. Attach one to a `CameraAlbum`; every
/// `download` on that album goes through it, so the album grid, the sync engine and
/// the photo viewer cannot overlap however they are driven.
///
/// ## The invariant, and why it is stated in terms of what a check can count
///
/// **The last caller only starts when the previous caller's `body` has finished.**
/// That is the whole contract, and it is what makes `maxLive == 1` an assertion rather
/// than a hope: a caller's request is inside `body`, and `body` is inside the gate.
class CameraRequestGate {
  CameraRequestGate({void Function(String)? onLog}) : _onLog = onLog;

  final void Function(String)? _onLog;

  final List<_Waiter> _queue = [];

  /// True while somebody holds the gate — that is, from the moment a turn is handed
  /// out until its ticket is released.
  bool _serving = false;
  int _seq = 0;

  /// Requests waiting for a turn, excluding whoever is being served.
  ///
  /// Read by checks; no app behaviour depends on it.
  int get waiting => _queue.length;

  /// Whether the camera is being asked for something right now.
  bool get busy => _serving;

  /// Queue for a turn, and take it immediately when the gate is free.
  ///
  /// **Always** pair this with [CameraRequestTicket.release] — [run] is the shape that
  /// cannot forget.
  Future<CameraRequestTicket> acquire(
      {CameraRequestPriority priority = CameraRequestPriority.background}) {
    final ticket = CameraRequestTicket._(this, priority);
    if (!_serving) {
      // Handed out synchronously, so a caller that acquires and immediately checks
      // `wanted` sees a coherent gate rather than racing a microtask it cannot see.
      _serving = true;
      return Future.value(ticket);
    }
    final completer = Completer<void>();
    _queue.add(_Waiter(ticket, priority, _seq++, completer));
    return completer.future.then((_) => ticket);
  }

  /// Acquire, run [body], release — including when [body] throws.
  ///
  /// The shape callers should use. A camera that stops answering because a transfer
  /// threw before its `release` is the "spinner forever" class of defect this project
  /// has shipped before (`analysis/70`), and a `finally` is what makes it unwritable.
  ///
  /// [body] is given the ticket so it can ask [CameraRequestTicket.wanted] after the
  /// wait — the one question that turns a queued request into a skipped one.
  Future<T> run<T>(
    Future<T> Function(CameraRequestTicket ticket) body, {
    CameraRequestPriority priority = CameraRequestPriority.background,
  }) async {
    final ticket = await acquire(priority: priority);
    try {
      return await body(ticket);
    } finally {
      await ticket.release();
    }
  }

  /// Hand the turn to the next waiter, skipping any that are no longer wanted.
  void _release() {
    while (_queue.isNotEmpty) {
      final next = _takeNext()!;
      if (!next.ticket.wanted) {
        // Dropped while it queued: **never sent**. Skipped here rather than at the
        // call site so that a caller which forgot to check cannot send it either.
        _log('skipped a queued request that is no longer wanted');
        // Released upfront: the waiter's `acquire` completes, it checks `wanted`,
        // does nothing and its own `release` is a no-op.
        next.ticket._released = true;
        next.completer.complete();
        continue;
      }
      _serving = true;
      next.completer.complete();
      return;
    }
    _serving = false;
  }

  _Waiter? _takeNext() {
    if (_queue.isEmpty) return null;
    // Interactive first, then arrival. `_seq` is unique, so two requests of the same
    // priority never swap — the queue is a total order, not a sort that happens to
    // look stable.
    _queue.sort((a, b) {
      final byPriority = a.priority.index.compareTo(b.priority.index);
      return byPriority != 0 ? byPriority : a.seq.compareTo(b.seq);
    });
    return _queue.removeAt(0);
  }

  void _log(String message) => _onLog?.call('[camera] $message');
}

class _Waiter {
  _Waiter(this.ticket, this.priority, this.seq, this.completer);
  final CameraRequestTicket ticket;
  final CameraRequestPriority priority;
  final int seq;
  final Completer<void> completer;
}
