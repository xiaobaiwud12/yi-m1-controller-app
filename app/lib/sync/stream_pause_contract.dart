/// The stream-pause seam the sync engine talks to during a bulk transfer.
///
/// `analysis/ce-app-competitive-spec.md` §5.3 is the specification for this file: a
/// full-resolution `GetFile(Original)` moves several megabytes (4.9–5.6 MB for a JPEG,
/// 31.9 MB for a `.DNG` — `measured_sizes.dart`) and the live-view stream shares **one**
/// 802.11n link with it, so running them together makes both slower — which is why the
/// engine pauses the stream around a bulk run.
///
/// ## Two rates were wrong here, and they were wrong in opposite directions
///
/// This said "~4.2 Mbit/s (800x600 at ~30 fps, ~17.5 KB per datagram)". That came from a
/// 40-frame sample of a plain scene, where consecutive frames differ by 374 bytes.
/// **Measured** (`tools/camera_bridge.py`, 2026-09-15, a real scene): **~52-57 KB per
/// datagram at ~30/s, about 12-14 Mbit/s** — 48,697 datagrams / 2.56 GB.
///
/// It also said the transfer "runs at ~13.5 Mbit/s (9.4 MB in 5.6 s)". **That has now
/// been withdrawn too**, and for the same reason as the first: one unrepresentative
/// observation presented as a property of the link. The size was wrong — the recorded
/// `Original` is 4,897,837 B and 5,565,238 B, not 9.4 MB — and 5.6 s is a single
/// wall-clock reading with no record of whether the preview was running, which is the one
/// variable this file exists to manage. `analysis/16` stage 2 retracted the *stream's*
/// rate on exactly this ground; the transfer's rate was derived the same way and is
/// withdrawn on the same ground, not on a new measurement.
///
/// So the picture is **not** "a cheap 4.2 against an expensive 13.5". What is [V] is the
/// file sizes and that the live view runs at 12–14 Mbit/s. Whether the stream costs more
/// or less than a download has **not** been measured, and this comment no longer implies
/// it has. "4.2 Mbit/s" and "13.5 Mbit/s" must not be quoted as either side's bandwidth
/// again (see `analysis/50` §3, `analysis/16` stage 2).
///
/// Frame geometry was **not** re-measured in that round, so 800x600 remains [H] rather
/// than [V].
///
/// ## Why this is an interface here and an HTTP call elsewhere
///
/// `lib/sync/` must stay free of `package:flutter` **and** of `dart:io`, so that
/// `tool/verify_sync.dart` can drive the whole engine — including the pause and
/// the watchdog — in the plain Dart VM. The engine therefore needs a *contract*
/// it can call and a *fake* it can be given; the real implementation, which does
/// speak HTTP, lives in `transport/stream_pause.dart`.
///
/// This is the same shape as the sink (`asset_sink_contract.dart` interface,
/// `asset_sink.dart` Android implementation) and as the `onChanged`/`onLog`
/// callbacks: the engine depends on what it needs, not on who provides it.
library;

/// Pause and resume the camera's live-view stream.
///
/// Two commands, both undocumented in the official app: `PauseMovieStream` and
/// `ResumeMovieStream`. They are structurally verified in firmware but **not
/// hardware-tested**, which is why every method here is allowed to fail and
/// reports failure instead of throwing — see [pause] and [resume].
abstract class StreamPauseController {
  /// Ask the camera to pause the stream.
  ///
  /// Returns `true` only when the camera confirmed the pause. A `false` is a
  /// **normal** outcome, not an error: the caller must carry on with the
  /// transfer rather than fail it, because an untested command being refused is
  /// exactly the risk of a feature like this, and a sync that refuses to run
  /// because an optional optimisation was declined is worse than a slow sync.
  ///
  /// Implementations must not throw; they report.
  Future<bool> pause();

  /// Ask the camera to resume.  Same contract: report, never throw.
  ///
  /// Note the asymmetry with [pause] that the design guide insists on: a failed
  /// pause merely costs bandwidth, while a **failed resume leaves the user with a
  /// frozen view** — the command's own warning about a client that pauses and
  /// never resumes. That is why the engine counts its holds, keeps a watchdog,
  /// and retries a failed resume rather than dropping it.
  Future<bool> resume();
}
