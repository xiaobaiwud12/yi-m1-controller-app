package com.cem1.yi_m1_controller.media


import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.media.MediaScannerConnection
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import io.flutter.plugin.common.MethodChannel

import io.flutter.plugin.common.BinaryMessenger

/** Activity-scoped media operations and permission replies. */
class MediaStoreChannel(private val activity: Activity) {
    private companion object {
        const val REQ_LEGACY_STORAGE = 7002
        const val MAX_READ_BYTES = 64L * 1024 * 1024
    }
    private val mediaChannelName = "com.cem1.yi_m1_controller/media"
    private var pendingStorageResult: MethodChannel.Result? = null

    // ------------------------------------------------------------ media store

    /**
     * The media channel: storing, deleting, opening and sharing fetched assets.
     *
     * Separate from the Wi-Fi channel on purpose. The two have nothing in common,
     * and a failure in one must not be diagnosable as the other — the Wi-Fi
     * channel already caused three rounds of misdiagnosis, and folding photo
     * storage into it would guarantee a repeat.
     */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, mediaChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(true)
                    "requestLegacyStorage" -> {
                        // Only meaningful below Android 10, which is the only place
                        // the legacy path runs. Answering "granted" above Q keeps
                        // the caller from showing a prompt that cannot appear.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            result.success(true)
                        } else if (activity.checkSelfPermission(
                                Manifest.permission.WRITE_EXTERNAL_STORAGE,
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else {
                            pendingStorageResult = result
                            activity.requestPermissions(
                                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                REQ_LEGACY_STORAGE,
                            )
                        }
                    }
                    "storeMedia" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null) {
                            result.error("bad_args", "bytes is required", null)
                        } else {
                            result.success(
                                storeMedia(
                                    bytes = bytes,
                                    displayName = call.argument<String>("displayName"),
                                    mimeType = call.argument<String>("mimeType"),
                                    relativePath = call.argument<String>("relativePath"),
                                    capturedAtEpochSeconds =
                                        call.argument<Number>("capturedAtEpochSeconds")?.toLong(),
                                )
                            )
                        }
                    }
                    "deleteMedia" ->
                        result.success(deleteMedia(call.argument<String>("uri")))
                    "readMedia" -> {
                        val bytes = readMedia(call.argument<String>("uri"))
                        if (bytes == null) {
                            result.success(null)
                        } else {
                            result.success(bytes)
                        }
                    }
                    "openUri" -> result.success(
                        openUri(
                            call.argument<String>("uri"),
                            call.argument<String>("mimeType"),
                        )
                    )
                    "shareUris" -> result.success(
                        shareUris(
                            // The channel decodes a Dart `List<String>` as a raw
                            // `ArrayList`; the explicit type argument is what makes
                            // `call.argument` cast it instead of returning null.
                            call.argument<List<String>>("uris"),
                            call.argument<String>("mimeType"),
                            call.argument<String>("title"),
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Write fetched bytes into the **shared** media store and answer its
     * `content://` URI.
     *
     * ## Why this replaced writing a file
     *
     * The previous implementation wrote into `getExternalStorageDirectory()`,
     * i.e. `Android/data/<package>/files/Pictures/…`, and then shelled out to
     * `am broadcast … MEDIA_SCANNER_SCAN_FILE` to have it indexed. Both halves of
     * that are broken on the releases this app targets, and neither failure is
     * visible from the app:
     *
     *  * **Android 11+ hides `Android/data/` from other apps.** The gallery has
     *    no read access to that directory at all, so a synced photo was invisible
     *    in the one place the user looks for it. The old comment claimed it was
     *    "visible in the gallery after scanning", which is not true.
     *  * **`MEDIA_SCANNER_SCAN_FILE` is a no-op on Android 10+.** The receiver is
     *    not exported, so the `am broadcast` fails silently — and `am` itself is
     *    not runnable from an app without `android.permission.DUMP`, which is
     *    signature-level and can never be granted.
     *
     * MediaStore is the sanctioned route and needs **no runtime permission** on
     * any supported release, because the app is inserting its own contributions.
     *
     * ## Why `IS_PENDING`
     *
     * A row inserted with `IS_PENDING = 1` is visible to this app and to nobody
     * else, so a half-written 40 MB video never appears in the gallery as a
     * truncated file. Publishing is `update(…, IS_PENDING = 0)`, and it must
     * happen even on failure — a row left pending is invisible and unfixable from
     * the user's side, which is worse than no file at all.
     *
     * ## Why the camera's filename is preserved
     *
     * `DISPLAY_NAME` is set to the camera's own name (`YI000123.JPG`). The reason
     * the old code gave for avoiding MediaStore — that it renames the asset — is
     * wrong: MediaStore only appends a suffix on a genuine collision, which for
     * this camera would mean two different shots sharing a name. Keeping the name
     * matters because a RAW+JPEG pair is identified by the name stem, and because
     * the user should find the same file they see on the camera.
     *
     * Returns a map with `uri`, or `null` uri plus an `error` string when the
     * platform refused — never throws into the channel, because a lost photo must
     * be reported as a failed transfer rather than as an app crash.
     */
    private fun storeMedia(
        bytes: ByteArray,
        displayName: String?,
        mimeType: String?,
        relativePath: String?,
        capturedAtEpochSeconds: Long?,
    ): Map<String, Any?> {
        val resolver = activity.contentResolver
        val name = displayName?.takeIf { it.isNotBlank() } ?: "YI_${System.currentTimeMillis()}.jpg"
        // Classified by the camera's own filename; see `MediaKind` for why the
        // table matters and why an unknown extension is not guessed as an image.
        val kind = MediaKind.of(name)
        val mime = mimeType?.takeIf { it.isNotBlank() } ?: kind.mimeType

        // `DIRECTORY_DCIM` rather than `DIRECTORY_PICTURES`: a camera's output
        // belongs in DCIM, which is what "sync to the phone's gallery" means to
        // every other camera app, and it keeps the M1's files distinguishable
        // from screenshots and downloads.
        val relPath = relativePath?.takeIf { it.isNotBlank() }?.let {
            if (it.endsWith("/")) it else "$it/"
        } ?: "${Environment.DIRECTORY_DCIM}/YI M1/"

        // Before Android 10 the scoped-storage API does not exist: rows carry no
        // `RELATIVE_PATH`, insertion needs `WRITE_EXTERNAL_STORAGE`, and the media
        // scanner does the indexing. This app installs on API 24 (its manifest
        // declares the legacy storage permission with `maxSdkVersion="28"`), so the
        // legacy route is a supported configuration rather than dead code — it was
        // dead, and every sync on Android 7-9 failed with a permission-shaped
        // error.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return storeMediaLegacy(bytes, name, mime, relPath, capturedAtEpochSeconds)
        }

        val collection = when (kind.table) {
            MediaKind.Table.IMAGE -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            MediaKind.Table.VIDEO -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            MediaKind.Table.OTHER -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relPath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            // Hand the date over explicitly rather than relying on a scan: with
            // MediaStore there is no scan, so this is the only chance to make a
            // 2019 photo sort under 2019 instead of today.
            if (capturedAtEpochSeconds != null && capturedAtEpochSeconds > 0) {
                val millis = capturedAtEpochSeconds * 1000
                put(MediaStore.MediaColumns.DATE_ADDED, capturedAtEpochSeconds)
                put(MediaStore.MediaColumns.DATE_MODIFIED, capturedAtEpochSeconds)
                put(MediaStore.MediaColumns.DATE_TAKEN, millis)
            }
        }

        var uri: android.net.Uri? = null
        return try {
            uri = resolver.insert(collection, values)
                ?: return mapOf("uri" to null, "error" to "MediaStore returned no row")
            resolver.openOutputStream(uri)?.use { out ->
                out.write(bytes)
                out.flush()
            } ?: return abandonRow(uri, "could not open an output stream")

            // `IS_PENDING` exists from API 29, and this branch only runs there.
            //
            // The row count is **checked**, not discarded. An update that matched
            // nothing returns 0 and throws nothing, which leaves the row pending
            // — visible to this app and to no other — while every layer above
            // reports a stored photo. That was the reported "the sync shows a
            // tick but the gallery is empty". See `MediaStorePublish`.
            //
            // ## Why the dates are written *here* as well as at insert
            //
            // Clearing `IS_PENDING` makes MediaProvider index the file, and that
            // indexing **re-derives the date columns**: `DATE_TAKEN` comes from the
            // image's EXIF and `DATE_ADDED` from the moment the row was published.
            // The insert-time values are therefore overwritten. Measured on the
            // emulator: the Dart side sent `capturedAt=2023-11-14T22:13:20` and the
            // stored row read `date_added=<now>, datetaken=NULL`, so a 2023 photo
            // filed under today — the exact T15 defect, arriving by a different route
            // than the one the insert-time code was written for.
            //
            // Writing them in the same update that publishes the row means they land
            // *after* the scan, which is the last write and therefore the one that
            // survives.
            val publish = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
                if (capturedAtEpochSeconds != null && capturedAtEpochSeconds > 0) {
                    put(MediaStore.MediaColumns.DATE_ADDED, capturedAtEpochSeconds)
                    put(MediaStore.MediaColumns.DATE_MODIFIED, capturedAtEpochSeconds)
                    put(MediaStore.MediaColumns.DATE_TAKEN, capturedAtEpochSeconds * 1000)
                }
            }
            val cleared = resolver.update(uri, publish, null, null)
            when (val verdict = MediaStorePublish.verdictForPublish(cleared)) {
                is MediaStorePublish.Verdict.Published ->
                    // ## `DATE_TAKEN` is deliberately not written again here
                    //
                    // The obvious follow-up — a second `update` setting `DATE_TAKEN`
                    // after the publish scan — was tried and **measured not to stick**:
                    // the row still read `datetaken=NULL` afterwards. MediaProvider
                    // derives `DATE_TAKEN` from the image's own EXIF, and refuses to
                    // take it from `ContentValues`.
                    //
                    // That derivation is why the date *inside* the file matters more
                    // than any column written here, and it is why the Dart side now
                    // normalises that field before the bytes are ever handed over:
                    // `SyncEngine` rewrites the EXIF date to the instant the app
                    // displays (`lib/sync/exif_wall_clock.dart`). This comment used to
                    // assert the opposite — that the camera's EXIF was "already
                    // intact", so MediaProvider would fill `DATE_TAKEN` correctly from
                    // it. Measured otherwise on a real photo from this body: the three
                    // date fields in `capture_test/probe_original.jpg` hold the UTC
                    // wall clock of the shot, so on a phone at +08:00 the column came
                    // out eight hours early and a gallery displayed 10:40 for a photo
                    // the app showed as 18:40. See `analysis/80`.
                    //
                    // Kept as a comment rather than as a call that looks like it works.
                    mapOf("uri" to uri.toString(), "error" to null)
                is MediaStorePublish.Verdict.NotPublished ->
                    abandonRow(uri, verdict.reason)
            }
        } catch (e: Exception) {
            abandonRow(uri, "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * The Android 7-9 storage path: a real file in the public DCIM directory, then
     * a media scan.
     *
     * ## Why this is not the same code as the modern path
     *
     * Before API 29 there is no `RELATIVE_PATH`, no `IS_PENDING`, and no
     * contribution-scoped write: inserting a row needs `WRITE_EXTERNAL_STORAGE`
     * granted at runtime, and the gallery only learns about a new file when the
     * scanner indexes it. None of that can be expressed through the Q+ code above,
     * which is why the earlier version — which refused below Q — made **every**
     * sync on those releases fail.
     *
     * The permission is checked rather than assumed. It is a *dangerous* permission,
     * so unlike `CHANGE_NETWORK_STATE` it cannot simply be declared, and the app
     * only asks for it while this branch is reachable — a modern phone never sees
     * the prompt.
     *
     * `MediaScannerConnection.scanFile` is used rather than a
     * `MEDIA_SCANNER_SCAN_FILE` broadcast: the broadcast was deprecated in API 29
     * and its receiver is not exported on later releases, so the in-process API is
     * the one that keeps working.
     */
    private fun storeMediaLegacy(
        bytes: ByteArray,
        name: String,
        mime: String,
        relPath: String,
        capturedAtEpochSeconds: Long?,
    ): Map<String, Any?> {
        if (activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return mapOf(
                "uri" to null,
                "error" to ("storage permission is not granted, which Android 9 and " +
                    "older require to write into the shared photo library"),
            )
        }
        return try {
            val dir = File(Environment.getExternalStorageDirectory(), relPath)
            if (!dir.exists() && !dir.mkdirs()) {
                return mapOf("uri" to null, "error" to "could not create ${dir.path}")
            }
            val target = uniqueFile(dir, name)
            target.writeBytes(bytes)
            // `setLastModified` is what the scanner turns into DATE_ADDED /
            // DATE_MODIFIED, so this is the pre-Q equivalent of writing those
            // columns — the same reason the modern path sets them explicitly.
            if (capturedAtEpochSeconds != null && capturedAtEpochSeconds > 0) {
                runCatching { target.setLastModified(capturedAtEpochSeconds * 1000) }
            }
            // The scanner answers on a binder thread, so the verdict is awaited
            // rather than assumed: a file that was never indexed sits in DCIM and
            // is absent from the gallery, which is the same missing-photo symptom
            // as an unpublished pending row.
            val latch = java.util.concurrent.CountDownLatch(1)
            val indexed = java.util.concurrent.atomic.AtomicBoolean(false)
            MediaScannerConnection.scanFile(
                activity,
                arrayOf(target.absolutePath),
                arrayOf(mime),
            ) { _, _ -> indexed.set(true); latch.countDown() }
            latch.await(10, java.util.concurrent.TimeUnit.SECONDS)

            val verdict = MediaStorePublish.verdictForLegacy(
                fileExists = target.exists(),
                scanned = indexed.get(),
            )
            when (verdict) {
                is MediaStorePublish.Verdict.Published ->
                    mapOf("uri" to target.absolutePath, "error" to null)
                is MediaStorePublish.Verdict.NotPublished ->
                    mapOf("uri" to null, "error" to verdict.reason)
            }
        } catch (e: Exception) {
            mapOf("uri" to null, "error" to "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * A path in [dir] for [name] that does not collide.
     *
     * The camera's filenames are reused after a card format, so writing straight
     * over an existing file would silently destroy the earlier photo of the same
     * name — the failure mode being a user who syncs a fresh card and loses the old
     * shots without any error.
     */
    private fun uniqueFile(dir: File, name: String): File {
        val direct = File(dir, name)
        if (!direct.exists()) return direct
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (n in 1..999) {
            val candidate = File(dir, "$stem ($n)$ext")
            if (!candidate.exists()) return candidate
        }
        return direct
    }

    /**
     * Delete a row whose bytes could not be written in full, and report the failure.
     *
     * ## Why delete rather than publish
     *
     * The first version published the partial row so the user could see and delete
     * it. That is the worse of the two: a truncated photo appears in the gallery
     * **under the camera's own filename**, which is indistinguishable from a good
     * one until it is opened — and when the retry succeeds, MediaStore resolves the
     * name collision by writing `YI000123 (1).JPG`, so the user is left with two
     * files and no way to tell which is real.
     *
     * Deleting costs nothing that matters: the transfer is reported as failed, the
     * sync engine retries it, and the name is free for that retry to reuse. A
     * failed transfer should leave no trace in the user's gallery.
     *
     * `null` is accepted because the failure may predate the insert.
     */
    private fun abandonRow(
        uri: android.net.Uri?,
        reason: String,
    ): Map<String, Any?> {
        if (uri != null) {
            // Best effort. If the delete fails there is nothing further to try, and
            // the transfer's failure is the part the caller must act on.
            runCatching { activity.contentResolver.delete(uri, null, null) }
        }
        return mapOf("uri" to null, "error" to reason)
    }

    /**
     * Remove a row this app created.
     *
     * Used when the user removes a synced photo from the app as well as from the
     * camera — leaving it on the phone would make the album grid and the gallery
     * disagree about what exists.
     */
    private fun deleteMedia(uri: String?): Boolean {
        if (uri.isNullOrEmpty()) return false
        return try {
            activity.contentResolver.delete(android.net.Uri.parse(uri), null, null) > 0
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Read a stored asset back out of the media store.
     *
     * ## Why this exists
     *
     * The album viewer used to fetch every rendition over HTTP even when the
     * original was already on the phone. On this camera that means a photo the
     * user had already synced still drove `GetFile` against a single-threaded
     * server that is busy streaming live view — the reported "opening a photo
     * freezes the camera". A synced photo must be readable with the camera
     * switched off, so the bytes come from the phone's own copy.
     *
     * Bounded on purpose: a full-resolution file is ~9 MB, and an unbounded read
     * of a URI that is not a file (a cloud-backed row, for instance) would block
     * a platform thread with no way out.
     */
    private fun readMedia(uri: String?): ByteArray? {
        if (uri.isNullOrEmpty()) return null
        return try {
            activity.contentResolver.openInputStream(android.net.Uri.parse(uri))?.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_READ_BYTES) return null
                    out.write(buffer, 0, read)
                }
                out.toByteArray()
            }
        } catch (e: Exception) {
            null
        }
    }

    /** Open a stored asset in whatever app the user has for it. */
    private fun openUri(uri: String?, mimeType: String?): Boolean {
        if (uri.isNullOrEmpty()) return false
        return try {
            activity.startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(android.net.Uri.parse(uri), mimeType ?: "*/*")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Hand one or more stored assets to another app (spec T20–T24).
     *
     * `ACTION_SEND` with multiple items needs `ACTION_SEND_MULTIPLE`, and the
     * `content://` URIs are the MediaStore ones this app inserted, so the read
     * grant below is sufficient and no file provider is needed.
     *
     * `ClipData` is set as well as the extra: several receivers (notably Gmail's
     * attachment resolver on some builds) read the clip data and ignore
     * `EXTRA_STREAM`, and a share that silently attaches nothing is worse than no
     * share button.
     */
    private fun shareUris(uris: List<String>?, mimeType: String?, title: String?): Boolean {
        val parsed = uris.orEmpty()
            .filter { it.isNotEmpty() }
            .mapNotNull { runCatching { android.net.Uri.parse(it) }.getOrNull() }
        if (parsed.isEmpty()) return false
        return try {
            val intent = if (parsed.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    putExtra(Intent.EXTRA_STREAM, parsed.first())
                    clipData = android.content.ClipData.newRawUri(null, parsed.first())
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(parsed))
                    clipData = android.content.ClipData.newRawUri(null, parsed.first())
                    parsed.drop(1).forEach { clipData?.addItem(android.content.ClipData.Item(it)) }
                }
            }
            intent.type = mimeType ?: "*/*"
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            title?.takeIf { it.isNotBlank() }?.let { intent.putExtra(Intent.EXTRA_TITLE, it) }
            activity.startActivity(Intent.createChooser(intent, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * A MIME type for the camera's own filenames.
     *
     * Delegates to [MediaKind] so the classification is unit-tested rather than
     * living in an untestable branch of this activity. Kept as a thin wrapper
     * because the channel's `mimeType` argument may be absent.
     */
    private fun guessMime(name: String): String = MediaKind.of(name).mimeType


    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_LEGACY_STORAGE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingStorageResult?.success(granted)
        pendingStorageResult = null
    }

    fun dispose() {
        pendingStorageResult?.success(false)
        pendingStorageResult = null
    }
}
