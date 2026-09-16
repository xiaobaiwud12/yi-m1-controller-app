package com.cem1.yi_m1_controller

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guard rails for [MediaStorePublish].
 *
 * This is the check for the reported defect "the sync shows a tick but the photo
 * is not in the phone's gallery". Every layer above the platform saw success:
 * `insert` returned a URI, the bytes were written, and the Dart sink recorded an
 * original. The single thing that was wrong — the row still being `IS_PENDING`,
 * therefore invisible to every other app — is only observable here.
 */
class MediaStorePublishTest {

    @Test
    fun `clearing the pending flag publishes the photo`() {
        assertTrue(
            MediaStorePublish.verdictForPublish(1) is MediaStorePublish.Verdict.Published
        )
    }

    @Test
    fun `an update that matched no row is not a published photo`() {
        // `ContentResolver.update` answers a row count and throws nothing, which
        // is exactly why ignoring it produced a silent invisible file.
        val verdict = MediaStorePublish.verdictForPublish(0)
        assertTrue(verdict is MediaStorePublish.Verdict.NotPublished)
        assertTrue(
            (verdict as MediaStorePublish.Verdict.NotPublished)
                .reason.contains("IS_PENDING")
        )
    }

    @Test
    fun `a negative row count is also not published`() {
        assertTrue(
            MediaStorePublish.verdictForPublish(-1) is
                MediaStorePublish.Verdict.NotPublished
        )
    }

    @Test
    fun `many rows updated still counts as published`() {
        // Some providers report more than one row for a single URI. Any positive
        // count means the pending flag was cleared.
        assertTrue(
            MediaStorePublish.verdictForPublish(3) is MediaStorePublish.Verdict.Published
        )
    }

    @Test
    fun `the legacy path needs both a file and a scan`() {
        assertTrue(
            MediaStorePublish.verdictForLegacy(fileExists = true, scanned = true) is
                MediaStorePublish.Verdict.Published
        )
        assertTrue(
            MediaStorePublish.verdictForLegacy(fileExists = false, scanned = true) is
                MediaStorePublish.Verdict.NotPublished
        )
        // A file the scanner never indexed is on disk and absent from the gallery,
        // which is the pre-Android-10 form of the same reported symptom.
        assertTrue(
            MediaStorePublish.verdictForLegacy(fileExists = true, scanned = false) is
                MediaStorePublish.Verdict.NotPublished
        )
    }

    @Test
    fun `only a content uri is gallery visible`() {
        assertTrue(MediaStorePublish.isGalleryVisible("content://media/external/images/1"))
        // An app-private path is readable by this app alone, so it must never be
        // reported as a delivered photo.
        assertFalse(MediaStorePublish.isGalleryVisible("/data/user/0/app/files/YI1.JPG"))
        assertFalse(MediaStorePublish.isGalleryVisible(null))
        assertFalse(MediaStorePublish.isGalleryVisible(""))
    }
}
