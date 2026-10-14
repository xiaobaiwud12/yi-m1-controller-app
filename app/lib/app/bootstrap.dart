import 'dart:async';

import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import 'application.dart';
import 'configuration.dart';
import 'presentation_state.dart';

/// The app shell.
///
/// Material 3, dark by default, because this is a camera controller: it is used
/// next to a viewfinder, often at night, and a light UI next to the preview is
/// actively unpleasant.
///
/// The **mode badge** in the app bar is the visible half of the dual-firmware
/// design (see `analysis/APPLICATION.md#source-08`): the app never assumes a
/// patched camera, it reports what it found and disables what is unavailable with
/// an explanation rather than hiding it.
void main() {
  // `runZonedGuarded` comes **first**, and the binding is initialised inside it.
  //
  // That ordering is a bug fix, not tidiness. The binding used to be initialised
  // in the root zone while `runApp` ran inside a guarded child zone, and the
  // framework treats that mismatch as an error:
  //
  //   Zone mismatch. The Flutter bindings were initialized in a different zone
  //   than is now being used.
  //
  // It goes through `FlutterError.onError`, which this app sets to surface a
  // startup failure — so the app did not merely warn, it replaced its whole UI with
  // "The app failed to start" and the zone-mismatch text. **Every debug build was
  // broken this way** while release worked, because the check is debug-only, which
  // is why it survived: the artifact that gets tested by hand was the release one.
  //
  // It was found by driving the running app with `marionette` (see
  // `tools/marionette.ps1`) rather than by reading this file.
  runZonedGuarded(
    () {
      // `PaintingBinding.instance` throws unless a binding exists, and it throws
      // *before* `runApp`, which produces a splash screen that never goes away and
      // no error the user can see. So the binding comes first — inside this zone.
      //
      // The binding choice is where `marionette_flutter` hooks in; see
      // [useMarionette] for why it is a compile-time flag rather than `kDebugMode`.
      if (useMarionette) {
        MarionetteBinding.ensureInitialized();
      } else {
        WidgetsFlutterBinding.ensureInitialized();
      }

      // Bound the image cache before anything decodes.
      //
      // The live view repaints with a **new byte array every frame**, and
      // `MemoryImage` hashes the array's *identity* rather than its contents, so
      // every frame becomes a fresh cache entry. Decoded frames accumulate at
      // roughly 1.9 MB each, thirty times a second, on top of the encoded bytes —
      // enough to churn the default 100 MB cache and keep the eviction policy busy
      // for the whole preview. Evicting each frame by hand would mean reconstructing
      // the exact cache key (a `MemoryImage` plus whichever `cacheWidth` the widget
      // happened to use), which is fragile; a small ceiling achieves the same thing
      // robustly.
      //
      // Non-zero rather than zero so a frame already on screen is not evicted out
      // from under itself, which would show as a flash. It must not be fatal: an
      // optimisation that can prevent the app from launching is worse than the
      // memory churn it avoids.
      try {
        // 8 MiB of decoded images and 12 entries. This is the **Flutter image cache**,
        // which holds decoded bitmaps in memory — a different budget from the album's
        // on-disk thumbnail cache (`AlbumThumbnailCache`), and the two numbers are
        // unrelated even though both are "8 MB"-ish.
        PaintingBinding.instance.imageCache.maximumSizeBytes = 8 << 20; // 8 MiB
        PaintingBinding.instance.imageCache.maximumSize = 12;
      } on Object catch (e) {
        debugPrint('could not bound the image cache ($e); continuing');
      }

      // Surface a startup failure instead of sitting on the splash screen.
      //
      // A throw during the first build — a platform channel that is missing, a file
      // store that cannot be reached — otherwise leaves a **blank screen with no
      // explanation**, which is indistinguishable from a hang and gives the user
      // nothing to report. Recording the first error lets the shell render it.
      //
      // ## Why this is scoped to startup
      //
      // The first version recorded *any* `FlutterError` for the life of the
      // process, so a single mid-session failure replaced the entire app with
      // "The app failed to start" — permanently, because nothing ever cleared the
      // notifier. It was reported from hardware as a sporadic screen reading
      // `Exception: Invalid image data`: one corrupt preview frame (the camera and
      // the radio both produce them) was enough to end the session, and the text
      // told the user it was a start-up problem, which it was not.
      //
      // So the latch is armed only until the first frame is on screen. After that
      // an error is still printed, but the app keeps running — and the image path
      // has its own `errorBuilder`, so a bad frame does not reach here at all.
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        if (appPresentation.starting) {
          appPresentation.launchError.value = details.exceptionAsString();
        }
      };
      runApp(const YiM1ControllerApp());

      // Armed until the first frame is drawn. `addPostFrameCallback` runs after
      // the first successful build, which is the earliest point at which "the app
      // started" is a true statement.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => appPresentation.starting = false);
    },
    (e, s) {
      debugPrint('uncaught: $e\n$s');
      if (appPresentation.starting) appPresentation.launchError.value = '$e';
    },
  );
}
