package com.cem1.yi_m1_controller

/**
 * Decides whether a MediaStore insert actually became a *visible* photo.
 *
 * ## Why this is a separate, pure object
 *
 * A row inserted with `IS_PENDING = 1` is visible to this app and to **nobody
 * else** — not the system gallery, not any other photo app. It only becomes a
 * real photo when the pending flag is cleared, and that clear is a second
 * operation that can fail on its own.
 *
 * The first version of `storeMedia` ignored that second operation's return
 * value. `update` answers the number of rows it changed, so an update that
 * matched nothing returns `0` and throws nothing: the row stayed pending, the
 * app still reported the `content://` URI, the sync ledger recorded the
 * original, and the album drew a tick — while the system gallery showed
 * nothing at all. That is the reported symptom, and it is invisible from every
 * layer above this one, which is why the verdict is computed here and asserted
 * in the plain JVM.
 *
 * No Android dependency, so `MediaStorePublishTest` runs without a device.
 */
object MediaStorePublish {

    /** What one store attempt actually achieved. */
    sealed class Verdict {

        /** The row exists and is no longer pending: other apps can see it. */
        object Published : Verdict()

        /**
         * The bytes may be on disk, but the row is not visible to other apps.
         * Carries a message fit for the sync engine's per-item error.
         */
        data class NotPublished(val reason: String) : Verdict()
    }

    /**
     * Judge the `IS_PENDING = 0` update.
     *
     * @param rowsUpdated what `ContentResolver.update` returned.
     */
    fun verdictForPublish(rowsUpdated: Int): Verdict =
        if (rowsUpdated > 0) {
            Verdict.Published
        } else {
            // Zero rows means the row this app just inserted could not be
            // updated — it was removed underneath us, or the update was
            // rejected. Either way the file is not in the gallery, so claiming
            // success is a lie the user sees as a missing photo.
            Verdict.NotPublished(
                "MediaStore did not clear IS_PENDING, so the photo stayed " +
                    "invisible to the gallery"
            )
        }

    /**
     * Judge the Android 7-9 path, where the gallery learns about a file only
     * when the media scanner indexes it.
     *
     * @param fileExists whether the bytes were written to the public directory.
     * @param scanned whether `MediaScannerConnection.scanFile` reported success.
     */
    fun verdictForLegacy(fileExists: Boolean, scanned: Boolean): Verdict = when {
        !fileExists -> Verdict.NotPublished("the file could not be written to DCIM")
        !scanned -> Verdict.NotPublished(
            "the media scanner did not index the file, so the gallery cannot see it"
        )
        else -> Verdict.Published
    }

    /**
     * Whether a URI is one the gallery can be shown.
     *
     * The sink refuses anything else, because an app-private path is exactly the
     * invisible-file defect this contract exists to prevent — it is readable by
     * this app and by nothing else, so a share or an open would fail later,
     * after the user had been told the photo had arrived.
     */
    fun isGalleryVisible(uri: String?): Boolean =
        uri != null && uri.startsWith("content://")
}
