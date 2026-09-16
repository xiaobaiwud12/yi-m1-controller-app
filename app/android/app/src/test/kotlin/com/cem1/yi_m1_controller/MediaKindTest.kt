package com.cem1.yi_m1_controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guard rails for [MediaKind].
 *
 * The reason this exists rather than being trusted: a wrong table or MIME type is
 * **silent**. `ContentResolver.insert` succeeds, the photo never appears (video
 * into the images table) or appears and then refuses to open (a `.DNG` labelled
 * `image/jpeg`), and nothing in the app reports an error. The camera's real
 * filenames are pinned here so that stays checkable without a phone.
 */
class MediaKindTest {

    @Test
    fun `the camera's jpeg goes to the images table`() {
        val k = MediaKind.of("YI000123.JPG")
        assertEquals(MediaKind.Table.IMAGE, k.table)
        assertEquals("image/jpeg", k.mimeType)
    }

    @Test
    fun `extension case does not matter`() {
        // `GetFileList` returns upper-case names on the tested card, but nothing
        // promises that, and a lower-case name must not fall through to OTHER.
        assertEquals(MediaKind.Table.IMAGE, MediaKind.of("yi000123.jpg").table)
        assertEquals(MediaKind.Table.VIDEO, MediaKind.of("YI000123.MP4").table)
    }

    @Test
    fun `raw goes to the images table with a raw mime type`() {
        val k = MediaKind.of("YI000123.DNG")
        assertEquals(MediaKind.Table.IMAGE, k.table)
        // Not `image/jpeg`: the gallery would list it and then fail to decode.
        assertEquals("image/x-adobe-dng", k.mimeType)
    }

    @Test
    fun `video goes to the video table`() {
        assertEquals(MediaKind.Table.VIDEO, MediaKind.of("YI000123.MP4").table)
        assertEquals(MediaKind.Table.VIDEO, MediaKind.of("YI000123.MOV").table)
    }

    @Test
    fun `an unknown extension is not guessed into the images table`() {
        // The whole point of OTHER: a file the app cannot classify must not be
        // announced to the gallery as a picture.
        val k = MediaKind.of("YI000123.XYZ")
        assertEquals(MediaKind.Table.OTHER, k.table)
        assertEquals("application/octet-stream", k.mimeType)
    }

    @Test
    fun `a name with no extension is not treated as one`() {
        // `substringAfterLast('.', "")` returns the whole string when there is no
        // dot, so this also checks the extension really is extracted.
        val k = MediaKind.of("YI000123")
        assertEquals(MediaKind.Table.OTHER, k.table)
        assertFalse(k.mimeType.startsWith("image/"))
    }

    @Test
    fun `a dotfile is not mistaken for a media extension`() {
        // A leading dot makes the whole string a name, not an extension. An
        // earlier version of this test asserted nothing (it compared a value with
        // itself), which is how the bug below survived: `.jpg` classified as an
        // image and would have landed in the gallery's photo list.
        val k = MediaKind.of(".jpg")
        assertEquals(MediaKind.Table.OTHER, k.table)
        assertEquals("application/octet-stream", k.mimeType)
    }

    @Test
    fun `a hidden file with a media-looking suffix is still not an image`() {
        assertEquals(MediaKind.Table.OTHER, MediaKind.of(".mp4").table)
    }

    @Test
    fun `a normal name still classifies after the dotfile rule`() {
        // Guards the fix itself: `dot > 0` must not have broken the ordinary case.
        assertEquals(MediaKind.Table.IMAGE, MediaKind.of("a.jpg").table)
        assertEquals(MediaKind.Table.IMAGE, MediaKind.of("YI000123.JPG").table)
    }

    // ------------------------------------------------------------- renditions

    /**
     * Previews and thumbnails are JPEGs written with a suffix, so they stay in the
     * images table on purpose: if the user shares from the album before the
     * full-resolution upgrade lands, the preview has to be a genuinely readable
     * asset, not a `content://` URI that resolves to nothing.
     */
    @Test
    fun `a preview is still an image, and is flagged as a rendition`() {
        val k = MediaKind.of("YI000123.JPG.preview.jpg")
        assertEquals(MediaKind.Table.IMAGE, k.table)
        assertEquals("image/jpeg", k.mimeType)
        assertTrue(MediaKind.isRendition("YI000123.JPG.preview.jpg"))
        assertTrue(MediaKind.isRendition("YI000123.JPG.thumb.jpg"))
    }

    @Test
    fun `the original is not a rendition`() {
        assertFalse(MediaKind.isRendition("YI000123.JPG"))
        // A file merely containing the word must not be misread.
        assertFalse(MediaKind.isRendition("YI000123.preview.jpg.bak"))
    }
}
