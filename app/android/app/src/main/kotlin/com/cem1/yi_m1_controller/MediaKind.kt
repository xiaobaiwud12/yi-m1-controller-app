package com.cem1.yi_m1_controller

/**
 * Chooses the MediaStore table a fetched file belongs in, and its MIME type.
 *
 * A pure function over the filename, with no Android dependency, so it can be
 * unit-tested in the plain JVM (`MediaKindTest`) — which matters because getting
 * it wrong is invisible from the app. A RAW file inserted as `image/jpeg` is
 * listed by the gallery and then refuses to open; a video inserted into the
 * images table is not listed at all.
 *
 * The camera's own naming is the only signal available at this point: the
 * protocol's `filetype` field is not passed down to the store, and the RAW
 * container is `.DNG` on the tested card but nothing in the protocol promises
 * that. So this classifies by extension and **admits when it does not know**
 * ([OTHER]) rather than guessing an image type that would be a lie.
 */
object MediaKind {

    /** Which collection a file is inserted into. */
    enum class Table {
        /** `MediaStore.Images` — still pictures, JPEG and RAW alike. */
        IMAGE,

        /** `MediaStore.Video` — recordings. */
        VIDEO,

        /** `MediaStore.Downloads` — anything not recognised as media. */
        OTHER,
    }

    /** The classification of one filename. */
    data class Classified(val table: Table, val mimeType: String)

    fun of(fileName: String): Classified {
        // `substringAfterLast` on a name with no dot yields the whole name, so the
        // stem is computed first and the extension is only taken when there is a
        // non-empty stem before the dot. A dotfile such as `.jpg` is a *name*, not
        // a JPEG, and classifying it as an image would put a file the camera never
        // produced into the gallery's photo list.
        val dot = fileName.lastIndexOf('.')
        val ext = if (dot > 0) fileName.substring(dot + 1).lowercase() else ""
        return when (ext) {
            "jpg", "jpeg" -> Classified(Table.IMAGE, "image/jpeg")
            "png" -> Classified(Table.IMAGE, "image/png")
            "heic", "heif" -> Classified(Table.IMAGE, "image/heic")
            "dng" -> Classified(Table.IMAGE, "image/x-adobe-dng")
            "tif", "tiff" -> Classified(Table.IMAGE, "image/tiff")
            "mp4" -> Classified(Table.VIDEO, "video/mp4")
            "mov" -> Classified(Table.VIDEO, "video/quicktime")
            "avi" -> Classified(Table.VIDEO, "video/x-msvideo")
            // A preview or thumbnail rendition is a JPEG written with a suffix, so
            // the extension still ends in `jpg` and it lands in the images table —
            // correct, because the gallery is meant to be able to show it.
            else -> Classified(Table.OTHER, "application/octet-stream")
        }
    }

    /**
     * Whether a stored file is a throwaway rendition rather than a real asset.
     *
     * The sink writes previews as `<name>.preview.jpg` and thumbnails as
     * `<name>.thumb.jpg`. They are inserted into MediaStore anyway — if the user
     * shares from the album before the full-resolution upgrade lands, the preview
     * has to be a real, readable asset — but the gallery listing them next to the
     * original is a known cosmetic cost, so callers can use this to explain it.
     */
    fun isRendition(fileName: String): Boolean =
        fileName.endsWith(".preview.jpg") || fileName.endsWith(".thumb.jpg")
}
