package com.cem1.yi_m1_controller

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.media.MediaScannerConnection
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import java.io.File
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Wi-Fi joining and network binding for the camera's access point.
 *
 * ## Why a platform channel is needed
 *
 * The camera runs its own AP whose 8-digit passkey **changes on every power
 * cycle**, so the user cannot save the network once and forget it. Finding the
 * SSID in Settings and retyping the passkey every session is the most tedious
 * part of using this camera, and Android can do it — but only through
 * `WifiNetworkSpecifier`, which has no Flutter binding.
 *
 * ## What the official app did, and why it cannot be copied
 *
 * The official app (`com.xiaoyi.mirrorlesscamera`, `targetSdkVersion=26`) joins
 * the camera with `WifiManager.addNetwork()` + `enableNetwork()`, retries five
 * times, and binds the process to the resulting network
 * (`YiWifiManager.m16491h` / `m16459a` / `m16476p`). That is the right *design* —
 * and this file keeps the same shape: ask the platform to join, then bind, then
 * poll — but the API itself was closed to third-party apps in Android 10. On any
 * current release `addNetwork` returns `-1` for a normal app, so the official app
 * can no longer connect on a modern phone either. Only `WifiNetworkSpecifier`
 * (API 29+), `WifiNetworkSuggestion` (API 29+), and the system Wi-Fi panel
 * remain.
 *
 * Two behaviours were worth carrying across from it:
 *
 *  * it **verifies the SSID after associating** rather than trusting that
 *    `enableNetwork` returning true means anything, which is why this file
 *    confirms `WifiInfo.ssid` after `onAvailable`; and
 *  * it **binds the process** to the camera's network, without which requests to
 *    `192.168.0.10` leave over cellular.
 *
 * ## Why binding is mandatory, and why unbinding matters just as much
 *
 * A network joined via `WifiNetworkSpecifier` is scoped to this app and is
 * requested **without** `NET_CAPABILITY_INTERNET`, because the camera's AP has no
 * internet and must not become the phone's default route. The side effect is that
 * the system does not route to it by default: with mobile data up, a request to
 * `192.168.0.10` leaves over cellular and fails even though the Wi-Fi associated.
 *
 * So the process is bound to the camera's network after a successful join. The
 * binding is **process-wide**, which means the app has no internet while it is in
 * force — so it is released on disconnect, on link loss, and when the app leaves
 * the foreground. Binding without unbinding is how "auto-connect" becomes
 * "auto-disconnect".
 *
 * ## Why every answer carries a permission report
 *
 * Reporting only *that* the join failed is what made this feature look broken
 * three times over: the user was told to grant a permission they already held,
 * because the app had guessed. Every result now carries the measured state —
 * which permissions are held, and whether the device's location master switch is
 * on — so the UI can show facts and the next attempt can be diagnosed from a
 * screenshot instead of a logcat.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        /** Request code for the system "add Wi-Fi network" sheet. */
        const val REQ_ADD_NETWORKS = 7001

        /** Request code for the pre-Android-10 storage permission. */
        const val REQ_LEGACY_STORAGE = 7002

        /**
         * Ceiling for one `readMedia` call.
         *
         * The camera's largest file is a ~9 MB JPEG, so this leaves generous room
         * while refusing a URI that would stream without end.
         */
        const val MAX_READ_BYTES = 64L * 1024 * 1024
    }

    private val channelName = "com.cem1.yi_m1_controller/wifi"
    private val screenChannelName = "com.cem1.yi_m1_controller/screen"
    private val mediaChannelName = "com.cem1.yi_m1_controller/media"

    private var pendingResult: MethodChannel.Result? = null
    private var connectivityManager: ConnectivityManager? = null
    private var wifiManager: WifiManager? = null

    /** The network the user granted, kept so it can be bound and released. */
    private var cameraNetwork: Network? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var bound = false

    /**
     * The SSID currently being joined, so the association broadcast can be
     * matched against it. The official app does the same check
     * (`YiWifiManager.m16488e`) and it is the difference between "the join
     * reported success" and "the phone is actually on the camera's network".
     */
    private var pendingSsid: String? = null

    /**
     * The suggestion added for the current camera, if the specifier route failed.
     *
     * Kept so it can be withdrawn: a suggestion persists on the device and will
     * silently auto-join the camera's AP in future sessions — useful, but only if
     * it is ours to remove when the user asks to forget the camera.
     */
    private var activeSuggestion: WifiNetworkSuggestion? = null

    /** Watches for the association a suggestion eventually produces. */
    private var wifiStateReceiver: BroadcastReceiver? = null

    /**
     * How the system "add network" sheet ended, for the diagnostics panel.
     *
     * `null` until it has been shown. Kept because from the network's point of
     * view "the user cancelled" and "the platform refused to save it" are
     * identical, and they need different advice.
     */
    private var lastAddNetworkResult: String? = null

    /**
     * Answers the pending `requestLegacyStorage` call once the user decides.
     *
     * Held rather than dropped because the caller is deciding whether to start a
     * sync: a `MethodChannel.Result` that is never answered makes the Dart future
     * hang forever, so the sync button would simply never come back.
     */
    private var pendingStorageResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        configureScreenChannel(flutterEngine)
        configureMediaChannel(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "joinCameraAp" -> {
                        val ssid = call.argument<String>("ssid")
                        val passphrase = call.argument<String>("passphrase")
                        if (ssid.isNullOrEmpty()) {
                            result.error("bad_args", "ssid is required", null)
                        } else {
                            joinCameraAp(ssid, passphrase, result)
                        }
                    }
                    "suggestCameraAp" -> {
                        val ssid = call.argument<String>("ssid")
                        val passphrase = call.argument<String>("passphrase")
                        if (ssid.isNullOrEmpty()) {
                            result.error("bad_args", "ssid is required", null)
                        } else {
                            result.success(suggestCameraAp(ssid, passphrase))
                        }
                    }
                    "forgetCameraAp" -> {
                        val ssid = call.argument<String>("ssid")
                        result.success(forgetCameraAp(ssid))
                    }
                    "permissionReport" -> result.success(permissionReport())
                    "openWifiSettings" -> {
                        openWifiSettings()
                        result.success(true)
                    }
                    "openWifiPanel" -> result.success(openWifiPanel())
                    "addNetworkViaSystem" -> {
                        val ssid = call.argument<String>("ssid")
                        val passphrase = call.argument<String>("passphrase")
                        result.success(addNetworkViaSystem(ssid, passphrase))
                    }
                    "bindNetwork" -> result.success(bindToCamera())
                    "adoptNetworkForSsid" -> {
                        val ssid = call.argument<String>("ssid")
                        result.success(adoptNetworkForSsid(ssid))
                    }
                    "unbindNetwork" -> {
                        unbindFromCamera()
                        result.success(true)
                    }
                    "releaseAssociation" -> result.success(releaseAssociation())
                    else -> result.notImplemented()
                }
            }
    }

    // ------------------------------------------------------------ media store

    /**
     * The media channel: storing, deleting, opening and sharing fetched assets.
     *
     * Separate from the Wi-Fi channel on purpose. The two have nothing in common,
     * and a failure in one must not be diagnosable as the other — the Wi-Fi
     * channel already caused three rounds of misdiagnosis, and folding photo
     * storage into it would guarantee a repeat.
     */
    private fun configureMediaChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(true)
                    "requestLegacyStorage" -> {
                        // Only meaningful below Android 10, which is the only place
                        // the legacy path runs. Answering "granted" above Q keeps
                        // the caller from showing a prompt that cannot appear.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            result.success(true)
                        } else if (checkSelfPermission(
                                Manifest.permission.WRITE_EXTERNAL_STORAGE,
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else {
                            pendingStorageResult = result
                            requestPermissions(
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
        val resolver = contentResolver
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
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
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
                this,
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
            runCatching { contentResolver.delete(uri, null, null) }
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
            contentResolver.delete(android.net.Uri.parse(uri), null, null) > 0
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
            contentResolver.openInputStream(android.net.Uri.parse(uri))?.use { input ->
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
            startActivity(
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
            startActivity(Intent.createChooser(intent, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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

    // ------------------------------------------------------------ diagnostics

    /**
     * The measured state behind every join answer.
     *
     * This is the part that was missing when the app told a user to grant a
     * permission they had already granted. Nothing here is inferred from the
     * Android version: each field is read from the platform at the moment of the
     * attempt.
     */
    private fun permissionReport(): Map<String, Any?> {
        val fine = hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
        // Absent below API 33, where `hasPermission` answers false for a
        // permission that does not exist — accurate, and the fields are labelled.
        val nearby =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                hasPermission(Manifest.permission.NEARBY_WIFI_DEVICES)
        val locationServices = locationServicesEnabled()

        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "targetSdk" to applicationInfo.targetSdkVersion,
            "android" to (Build.VERSION.RELEASE ?: "?"),
            "manufacturer" to (Build.MANUFACTURER ?: "?"),
            "fineLocation" to fine,
            "coarseLocation" to coarse,
            "nearbyWifiDevices" to nearby,
            "changeWifiState" to hasPermission(Manifest.permission.CHANGE_WIFI_STATE),
            "accessWifiState" to hasPermission(Manifest.permission.ACCESS_WIFI_STATE),
            "locationServices" to locationServices,
            // The state that reads as "permission missing" but is not: the
            // permission is held, the master switch is off, and the platform
            // answers DENIED for a granted location permission.
            "locationServicesBlocking" to
                WifiJoinDiagnosis.locationServicesLikelyBlocking(fine, locationServices),
            "wifiEnabled" to (wifiManager?.isWifiEnabled ?: false),
            // `false` here is the single most likely reason a join was refused, and
            // it is the one field a user can do nothing about — so it is reported
            // explicitly rather than left to be inferred from the exception text.
            "changeNetworkState" to hasPermission(Manifest.permission.CHANGE_NETWORK_STATE),
            // The suggestion fallback asks for approval through a *notification*.
            // Without this permission from API 33 the platform suppresses it, so
            // the rung reports success and then nothing happens — reported here so
            // the diagnostics panel can say why the fallback went quiet.
            "notifications" to hasPermission(Manifest.permission.POST_NOTIFICATIONS),
            "addNetworkResult" to lastAddNetworkResult,
        )
    }

    private fun hasPermission(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * Whether the device's location master switch is on.
     *
     * Note the deliberate default: on an unknown API level this answers `true`
     * (i.e. "not blocking"), because claiming the switch is off when it cannot be
     * read would produce exactly the false accusation this reporting exists to
     * prevent. `isLocationEnabled` is the correct call from API 28 up;
     * `isProviderEnabled` is the older equivalent.
     */
    private fun locationServicesEnabled(): Boolean {
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return true
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                lm.isLocationEnabled
            } else {
                lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
        } catch (_: Exception) {
            true
        }
    }

    // ------------------------------------------------------------------ join

    private fun openWifiSettings() {
        startActivity(
            Intent(Settings.ACTION_WIFI_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    /**
     * Ask the *system* to save the camera's network, with the passphrase filled in.
     *
     * This is the best fallback available and it beats both alternatives:
     *
     *  * unlike [suggestCameraAp] it needs no per-app approval gate and cannot
     *    strip this app's `CHANGE_WIFI_STATE` if the user declines, and
     *  * unlike a plain settings screen the user does **not** have to type the
     *    eight-digit passkey, because the app supplies it.
     *
     * The platform's own documentation is the reason it works this way:
     * *"For the Wi-Fi stack, these networks will look like the user manually added
     * them from the Settings UI"* — and it triggers a connection to one of the
     * newly saved networks on success. That is exactly the semantics the camera
     * needs, and it is why this is preferred over `WifiNetworkSuggestion`, which
     * is documented for provisioning *internet-capable* configurations and cannot
     * even express "this AP has no internet".
     *
     * Returns false when the surface could not be opened, so the caller can fall
     * back to plain Wi-Fi settings.
     */
    @Suppress("DEPRECATION")
    private fun addNetworkViaSystem(ssid: String?, passphrase: String?): Boolean {
        if (ssid.isNullOrEmpty()) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return try {
            val builder = WifiNetworkSuggestion.Builder().setSsid(ssid)
            if (!passphrase.isNullOrEmpty()) builder.setWpa2Passphrase(passphrase)
            val list = arrayListOf(builder.build())
            val bundle = android.os.Bundle().apply {
                // ParcelableArrayList, and the platform caps the list at five.
                putParcelableArrayList(
                    Settings.EXTRA_WIFI_NETWORK_LIST,
                    list,
                )
            }
            startActivityForResult(
                Intent(Settings.ACTION_WIFI_ADD_NETWORKS).putExtras(bundle),
                REQ_ADD_NETWORKS,
            )
            true
        } catch (e: Exception) {
            // Some OEM builds ship without the activity. Not an error worth
            // surfacing: the caller opens the settings screen instead.
            false
        }
    }

    /**
     * Result of the system "add network" sheet.
     *
     * Recorded rather than acted on: the durable outcome is whether the camera
     * answers over HTTP, which the Dart side is already polling for. What this is
     * for is *diagnosis* — "the user cancelled" and "the platform refused to save
     * it" look identical from the network side, and they need different advice.
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_ADD_NETWORKS) return
        val results = data?.getIntegerArrayListExtra(Settings.EXTRA_WIFI_NETWORK_RESULT_LIST)
        lastAddNetworkResult = when {
            resultCode != Activity.RESULT_OK -> "cancelled"
            results == null -> "no result list"
            results.contains(Settings.ADD_WIFI_RESULT_SUCCESS) -> "saved"
            results.contains(Settings.ADD_WIFI_RESULT_ALREADY_EXISTS) -> "already exists"
            else -> "refused by the system"
        }
    }

    /**
     * Open the system's own Wi-Fi sheet instead of the full Settings app.
     *
     * The panel (API 29+) is the honest fallback once the app has been refused:
     * it is a first-party surface, it always works, and the user only has to pick
     * the network — the passkey propagates from the tap because Android remembers
     * a network the app has requested. `ACTION_WIFI_SETTINGS` remains the fallback
     * for older releases.
     */
    private fun openWifiPanel(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startActivity(
                    Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                return true
            } catch (_: Exception) {
                // Some OEM builds ship without the panel activity.
            }
        }
        openWifiSettings()
        return false
    }

    /**
     * Ask Android to join the camera's AP.
     *
     * Answers a map rather than a bool:
     * `status` is `granted` / `dismissed` / `timeout` / `unsupported` /
     * `permissionDenied` / `failed`, `reason` names the cause as specifically as
     * the platform allowed, and `permissions` carries [permissionReport].
     *
     * There is deliberately **no platform-side timeout**. Android's consent
     * dialog can legitimately sit open for minutes while the user reads it, and a
     * premature `onUnavailable` would report a failure for a join that then
     * succeeds. The Dart side owns the deadline.
     */
    private fun joinCameraAp(
        ssid: String,
        passphrase: String?,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // No programmatic join exists before API 29. The settings screen is
            // the honest fallback, and the passkey is usually already saved.
            openWifiSettings()
            result.success(
                answer("unsupported", reason = "android_too_old")
            )
            return
        }
        if (pendingResult != null) {
            result.error("busy", "a join request is already in progress", null)
            return
        }
        val cm = connectivityManager
        if (cm == null) {
            result.error("no_service", "ConnectivityManager unavailable", null)
            return
        }

        // Release any previous request before starting a new one, so a retry does
        // not stack callbacks.
        releaseCallback()
        pendingSsid = ssid

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .apply { if (!passphrase.isNullOrEmpty()) setWpa2Passphrase(passphrase) }
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // Asking for internet would make the request fail: this AP has none.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        pendingResult = result

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cameraNetwork = network
                // Do not report success until the process is actually bound. Without
                // this ordering the Dart side starts polling while HTTP still uses
                // cellular, and a failed bind is silently converted into a timeout.
                val bound = bindToCamera()
                if (bound) {
                    finish(answer("granted"))
                } else {
                    cameraNetwork = null
                    finish(answer("failed", reason = "bind_failed"))
                }
            }

            override fun onUnavailable() {
                // Fires when the user declines, when the network cannot be
                // brought up, AND when the platform rejects the request for a
                // missing permission — it is documented for the first two only.
                // A `SecurityException` raised inside the framework's own callback
                // never reaches this code, so "unavailable" is genuinely
                // ambiguous and the answer says so rather than guessing.
                cameraNetwork = null
                finish(answer("dismissed", reason = "unavailable"))
            }

            override fun onLost(network: Network) {
                if (network == cameraNetwork) {
                    // The AP went away. Drop the binding too, or the app keeps no
                    // internet while believing it is still attached to a camera.
                    unbindFromCamera()
                    cameraNetwork = null
                }
            }
        }

        networkCallback = callback
        try {
            cm.requestNetwork(request, callback)
        } catch (e: SecurityException) {
            // The useful case: the platform refused before it even tried. The
            // message is classified rather than pattern-matched for "permission",
            // because naming the wrong permission is worse than naming none —
            // it is what sent the user to a switch that was already on.
            networkCallback = null
            finish(
                answer(
                    status = "permissionDenied",
                    reason = WifiJoinDiagnosis.classify(e.message).name,
                    detail = e.message ?: e.javaClass.simpleName,
                )
            )
        } catch (e: Exception) {
            networkCallback = null
            finish(
                answer(
                    status = "failed",
                    reason = WifiJoinDiagnosis.classify(e.message).name,
                    detail = "${e.javaClass.simpleName}: ${e.message ?: "no detail"}",
                )
            )
        }
    }

    /** Build the answer map, always attaching the measured permission state. */
    private fun answer(
        status: String,
        reason: String? = null,
        detail: String? = null,
    ): Map<String, Any?> = mapOf(
        "status" to status,
        "reason" to reason,
        "detail" to detail,
        "permissions" to permissionReport(),
    )

    // ------------------------------------------------------------ suggestion

    /**
     * Ask Android to remember the camera's network.
     *
     * The second rung of the fallback ladder, for the case where
     * `WifiNetworkSpecifier` is refused outright. A suggestion takes a different
     * path through the platform — it needs no per-request foreground grant and
     * posts the association as a system notification the user can accept — and it
     * has the side benefit of making the network visible in the system Wi-Fi
     * list.
     *
     * It also has a real cost that the caller must be told about: the suggestion
     * **persists**. Left in place, the phone will auto-join the camera's AP in
     * future sessions on its own — and with no camera on, that means a phone
     * silently attached to a dead network. So this is opt-in, and
     * [forgetCameraAp] withdraws it.
     */
    private fun suggestCameraAp(ssid: String, passphrase: String?): Map<String, Any?> {
        val wm = wifiManager ?: return mapOf(
            "ok" to false,
            "reason" to "no_wifi_service",
            "permissions" to permissionReport(),
        )
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return mapOf(
                "ok" to false,
                "reason" to "android_too_old",
                "permissions" to permissionReport(),
            )
        }
        return try {
            val builder = WifiNetworkSuggestion.Builder()
                .setSsid(ssid)
                // Not metered and not roaming on purpose: this is a camera one
                // metre away, and telling the platform otherwise makes it treat
                // the only network available as a bad one.
                .setIsMetered(false)
            if (!passphrase.isNullOrEmpty()) builder.setWpa2Passphrase(passphrase)
            val suggestion = builder.build()

            @Suppress("DEPRECATION")
            val status = wm.addNetworkSuggestions(listOf(suggestion))
            val ok = status == WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS
            if (ok) {
                activeSuggestion = suggestion
                // A suggestion does not associate while our own process still has
                // a specifier request open, and it needs a moment to appear.
                // Watching for the association is what turns "we asked" into
                // "it connected".
                registerWifiStateReceiver()
            }
            mapOf(
                "ok" to ok,
                "status" to status,
                "reason" to when (status) {
                    WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS -> "added"
                    WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_ADD_DUPLICATE ->
                        "duplicate"
                    WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_ADD_EXCEEDS_MAX_PER_APP ->
                        "too_many"
                    WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_APP_DISALLOWED ->
                        "app_disallowed"
                    WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_INTERNAL -> "internal"
                    WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_REMOVE_INVALID ->
                        "remove_invalid"
                    else -> "status_$status"
                },
                "detail" to suggestionStatusHint(status),
                "permissions" to permissionReport(),
            )
        } catch (e: SecurityException) {
            mapOf(
                "ok" to false,
                "reason" to WifiJoinDiagnosis.classify(e.message).name,
                "detail" to (e.message ?: e.javaClass.simpleName),
                "permissions" to permissionReport(),
            )
        } catch (e: Exception) {
            mapOf(
                "ok" to false,
                "reason" to "exception",
                "detail" to "${e.javaClass.simpleName}: ${e.message ?: "no detail"}",
                "permissions" to permissionReport(),
            )
        }
    }

    /**
     * Whether the suggestion the user added on purpose is still in force.
     *
     * Part of the contract with the app layer: a withdrawn suggestion is the
     * difference between "the phone connects when I open the app" and "the phone
     * keeps attaching itself to a camera that is switched off".
     */
    private fun forgetCameraAp(ssid: String?): Map<String, Any?> {
        val wm = wifiManager
        val suggestion = activeSuggestion
        // Fall back to removing by SSID when the in-memory copy is gone, which
        // happens after the activity is recreated.
        //
        // The gate is **R, not Q**: `WifiManager.getNetworkSuggestions` and
        // `WifiNetworkSuggestion.getSsid` were added in API 30, so on Android 10
        // the Q-gated code below raised `NoSuchMethodError` — an `Error`, which
        // the `catch (_: Exception)` inside it does not catch, on the exact path
        // (activity recreated, suggestion no longer in memory) it exists for.
        val targets = when {
            suggestion != null -> listOf(suggestion)
            ssid.isNullOrEmpty() -> emptyList()
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                try {
                    @Suppress("DEPRECATION")
                    wm?.networkSuggestions
                        ?.filter { it.ssid == ssid }
                        ?: emptyList()
                } catch (_: Exception) {
                    emptyList()
                }
            }
            else -> emptyList()
        }
        if (targets.isEmpty() || wm == null) {
            return mapOf("ok" to false, "reason" to "nothing_to_remove")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Unreachable while `targets` is empty below Q, and stated anyway: the
            // call below is API 29+, and an unavailable method is an `Error` that
            // the catch would not convert into an answer.
            return mapOf("ok" to false, "reason" to "nothing_to_remove")
        }
        return try {
            @Suppress("DEPRECATION")
            val status = wm.removeNetworkSuggestions(targets)
            activeSuggestion = null
            unregisterWifiStateReceiver()
            mapOf(
                "ok" to (status == WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS),
                "removed" to targets.size,
            )
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to e.javaClass.simpleName)
        }
    }

    private fun suggestionStatusHint(status: Int): String = when (status) {
        WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS -> "suggestion accepted"
        WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_ADD_DUPLICATE ->
            "already suggested"
        WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_ADD_EXCEEDS_MAX_PER_APP ->
            "the app already has the maximum number of suggestions"
        WifiManager.STATUS_NETWORK_SUGGESTIONS_ERROR_APP_DISALLOWED ->
            "the system does not allow this app to make suggestions"
        else -> "suggestion status $status"
    }

    /**
     * Watch for the association a suggestion produces.
     *
     * The SSID is checked rather than merely "Wi-Fi connected", for the same
     * reason the official app checks it: the phone joining the home network is
     * not the phone joining the camera, and mistaking one for the other produces a
     * connection that reports success and then times out on every request.
     */
    private fun registerWifiStateReceiver() {
        if (wifiStateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != WifiManager.NETWORK_STATE_CHANGED_ACTION) return
                val wanted = pendingSsid ?: return
                if (!isOnNetwork(wanted)) return
                // Association happened — find the Network object so the process
                // can be bound to it, exactly as the onAvailable path does.
                connectToSuggestedNetwork()
            }
        }
        val filter = IntentFilter(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        try {
            registerReceiver(receiver, filter)
            wifiStateReceiver = receiver
        } catch (_: Exception) {
        }
    }

    private fun unregisterWifiStateReceiver() {
        val receiver = wifiStateReceiver ?: return
        try {
            unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        wifiStateReceiver = null
    }

    @Suppress("DEPRECATION")
    private fun isOnNetwork(ssid: String): Boolean {
        val info = try {
            wifiManager?.connectionInfo
        } catch (_: Exception) {
            null
        } ?: return false
        // `WifiInfo.ssid` is quoted and may be "<unknown ssid>" without the
        // location permission, hence the explicit comparison rather than a
        // non-null assumption.
        val current = info.ssid?.trim('"') ?: return false
        return current == ssid
    }

    /**
     * Bind to the network the suggestion produced.
     *
     * A suggested network has no `Network` handed to us by a callback, so it is
     * looked up from the list of all networks by matching the transport and the
     * link properties' SSID. `bindProcessToNetwork` is what makes the camera
     * reachable at all, so failing to find it is reported rather than ignored.
     */
    private fun connectToSuggestedNetwork() {
        if (adoptNetworkForSsid(pendingSsid)) {
            stopWaitingForSuggestion()
        }
    }

    /**
     * Find the network whose SSID is [ssid] and bind the process to it.
     *
     * Called repeatedly while a suggestion is pending, because the association
     * arrives asynchronously and the platform hands back no callback for it.
     * Answers `false` — rather than an error — until the network actually exists,
     * which is the normal state for the first few seconds.
     */
    private fun adoptNetworkForSsid(ssid: String?): Boolean {
        if (ssid.isNullOrEmpty()) return false
        val cm = connectivityManager ?: return false
        val networks = try {
            cm.allNetworks
        } catch (_: Exception) {
            emptyArray()
        }
        for (network in networks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            val linkSsid = ssidOf(caps) ?: continue
            if (linkSsid != ssid) continue
            cameraNetwork = network
            return bindToCamera()
        }
        return false
    }

    /**
     * The SSID behind a network's capabilities.
     *
     * `WifiInfo.ssid` is quoted, and answers `"<unknown ssid>"` when the caller
     * lacks the location permission — hence the explicit unwrapping and the null
     * for anything that is not a real name. Returning "<unknown ssid>" as if it
     * were an SSID is how a phone on the home network gets mistaken for a phone
     * on the camera.
     */
    private fun ssidOf(caps: NetworkCapabilities): String? {
        // `getTransportInfo` is API 29+. Below it there is no way to attribute a
        // network to an SSID, and this build supports API 24, so answer "unknown"
        // rather than raising `NoSuchMethodError` — which would be an `Error`,
        // escaping the `catch` at every call site and the channel's own handling.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val info = try {
            caps.transportInfo as? android.net.wifi.WifiInfo
        } catch (_: Exception) {
            null
        } ?: return null
        val name = info.ssid?.trim('"') ?: return null
        if (name.isEmpty() || name.startsWith("<")) return null
        return name
    }

    /**
     * Stop watching for the suggested association.
     *
     * Separate from [unregisterWifiStateReceiver] so that finishing the wait does
     * not withdraw the suggestion itself — the user asked for that to stay.
     */
    private fun stopWaitingForSuggestion() {
        unregisterWifiStateReceiver()
    }

    private fun finish(answer: Any) {
        val r = pendingResult
        pendingResult = null
        // A join can complete after the Dart side has moved on; the token is
        // informational then, so a late answer is dropped rather than crashing.
        try {
            r?.success(answer)
        } catch (_: IllegalStateException) {
        }
    }

    private fun releaseCallback() {
        val cm = connectivityManager ?: return
        val cb = networkCallback ?: return
        try {
            cm.unregisterNetworkCallback(cb)
        } catch (_: Exception) {
        }
        networkCallback = null
    }

    // ------------------------------------------------------------------ bind

    private fun bindToCamera(): Boolean {
        val cm = connectivityManager ?: return false
        val net = cameraNetwork ?: return false
        return try {
            bound = cm.bindProcessToNetwork(net)
            bound
        } catch (e: Exception) {
            bound = false
            false
        }
    }

    private fun unbindFromCamera() {
        if (!bound) return
        try {
            connectivityManager?.bindProcessToNetwork(null)
        } catch (_: Exception) {
        }
        bound = false
    }

    /**
     * Leave the camera's network — the association, not merely the binding.
     *
     * ## Why this exists as its own call
     *
     * [unbindFromCamera] changes routing and nothing else. A `WifiNetworkSpecifier`
     * network is brought up **for a request** and is torn down when that request
     * goes away; `bindProcessToNetwork(null)` does not withdraw it. So the old
     * disconnect dropped the pin, reported success, and left the phone associated
     * with no internet, holding the single client slot the camera's AP admits —
     * measured on the maintainer's phone after pressing Disconnect (`Wifi is
     * connected to "YI_M1_XXXXXX"`, `IP: 192.168.0.3`).
     *
     * ## Three releases, because the phone can be on that AP three ways
     *
     * 1. `unregisterNetworkCallback` — the app asked for it with a specifier. This
     *    is the one that was simply missing: the only other caller is
     *    `onDestroy`, which does not run on an ordinary disconnect.
     * 2. `removeNetworkSuggestions` — the fallback rung registered the network as a
     *    suggestion, and a live suggestion will re-associate the phone by itself.
     * 3. `WifiManager.disconnect()` — the user joined by hand (the system's "add
     *    network" sheet, the Wi-Fi panel, Settings). No app request exists to
     *    release here, so this is the only thing that ends the association, and a
     *    fix handling only case 1 would have been this same defect in a new place.
     *    **Gated on the current SSID being a camera AP**, because disconnecting
     *    unconditionally would drop the user's home network — the one thing an app
     *    must not do while tidying up after itself.
     *
     * It answers what happened rather than assuming: `stillAssociated` is computed
     * from the network list *after* the releases, so a phone that stayed on the AP
     * is reported instead of being described as disconnected.
     */
    private fun releaseAssociation(): Map<String, Any?> {
        // 1. Drop the pin first: a bound process cannot observe the teardown
        //    honestly, and the request release below is what ends the network.
        unbindFromCamera()

        val hadRequest = networkCallback != null
        if (hadRequest) releaseCallback()

        // 2. Is the phone still on a camera AP, now that the app has given up its
        //    claim? If so the association is one no app request covers — the user
        //    joined by hand (the system's "add network" sheet, the Wi-Fi panel), or
        //    it is a suggestion the platform acted on. `WifiManager.disconnect()`
        //    is the only thing that ends those, and it is what a fix handling only
        //    case 1 would have missed.
        //
        //    Deliberately **not** withdrawing a suggestion here. `forgetCameraAp`
        //    exists for "forget this camera", and a suggestion keeps the camera's
        //    saved network usable so that reconnecting stays a one-tap affair —
        //    the outcome `disconnectBody` promises. Removing it would trade this
        //    defect for that one.
        val onCameraAp = isOnCameraApNow()
        var disconnected = false
        if (onCameraAp) {
            val wm = wifiManager
            if (wm == null) {
                return mapOf(
                    "released" to false,
                    "stillAssociated" to true,
                    "reason" to "no_wifi_service",
                )
            }
            disconnected = try {
                // Deprecated since API 29 and still the documented way to leave the
                // *current* network; there is no replacement, and the alternative —
                // forgetting the network — is the opposite of what the user asked
                // for ("the pairing is kept").
                @Suppress("DEPRECATION")
                val ok = wm.disconnect()
                // `disconnect()` reports the request being accepted, so the state
                // is re-read rather than trusted — the same "success is a platform
                // measurement" rule MediaStore's `IS_PENDING` is held to. The short
                // sleep is for the framework's own teardown, which is asynchronous;
                // this runs on a background thread (see `runOnUiThread`'s absence
                // here) and is entered once per disconnect, not per frame.
                if (ok) Thread.sleep(150)
                ok && !isOnCameraApNow()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                false
            } catch (_: Exception) {
                false
            }
        }

        val still = isOnCameraApNow()
        val reason = when {
            still -> "the phone is still on the camera's access point"
            hadRequest -> "the app released its network request"
            disconnected -> "disconnected from the camera AP"
            onCameraAp -> "the platform refused the disconnect"
            else -> "not on the camera network"
        }
        return mapOf(
            "released" to !still,
            "stillAssociated" to still,
            "reason" to reason,
            "hadRequest" to hadRequest,
        )
    }

    /**
     * Whether the phone is associated with a network that looks like the camera's.
     *
     * Read from `WifiInfo` — the association actually in force — rather than from
     * `allNetworks`, because what matters here is the station being on the AP,
     * which is also what occupies the camera's one client slot. A consequence
     * worth stating: an app-scoped specifier network that has already been torn
     * down does not appear here, which is exactly the case where `disconnect()`
     * must not be called.
     */
    private fun isOnCameraApNow(): Boolean =
        CameraAp.matches(currentSsid())

    @Suppress("DEPRECATION")
    private fun currentSsid(): String? {
        val info = try {
            wifiManager?.connectionInfo
        } catch (_: Exception) {
            null
        } ?: return null
        val name = info.ssid?.trim('"') ?: return null
        if (name.isEmpty() || name.startsWith("<")) return null
        return name
    }

    // ------------------------------------------------------------- lifecycle

    /**
     * Release the binding when the app is not in front.
     *
     * Without this the user switches away to find that the phone has no internet,
     * which reads as the phone being broken rather than as the app holding a
     * camera network.
     */
    override fun onPause() {
        super.onPause()
        unbindFromCamera()
    }

    override fun onDestroy() {
        unbindFromCamera()
        releaseCallback()
        // The receiver is registered on the activity, so it must go with it or the
        // process leaks a listener that keeps a dead SSID pending.
        stopWaitingForSuggestion()
        // An unanswered channel result makes the Dart side wait forever; answering
        // it as "no" lets the caller report a refusal instead of hanging.
        pendingStorageResult?.success(false)
        pendingStorageResult = null
        super.onDestroy()
    }

    /**
     * The user's answer to the pre-Android-10 storage prompt.
     *
     * Routed by request code because `onActivityResult` also serves the system
     * "add network" sheet; the two are unrelated and must not be confused.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_LEGACY_STORAGE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingStorageResult?.success(granted)
        pendingStorageResult = null
    }

    // ------------------------------------------------------------ screen

    /**
     * Screen behaviour while framing a shot.
     *
     * A controller is used at arm's length with both hands occupied, so the
     * screen timing out mid-composition is a real annoyance — and the official
     * app has this defect: it requests `WAKE_LOCK` in its manifest and then never
     * sets the flag anywhere, so the screen sleeps anyway.
     *
     * A separate channel from Wi-Fi on purpose: the two have nothing to do with
     * each other, and a failure in one should not be confused with the other.
     */
    private fun configureScreenChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, screenChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        // FLAG_KEEP_SCREEN_ON is preferred over a WakeLock: it is
                        // scoped to this window, needs no permission, and cannot
                        // leak — the system clears it when the window goes away.
                        runOnUiThread {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
