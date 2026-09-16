package com.cem1.yi_m1_controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guard rails for [WifiJoinDiagnosis].
 *
 * This is the third attempt at reporting *why* the camera's Wi-Fi could not be
 * joined, and the first two failed the same way: they guessed the cause from the
 * Android version and told the user to grant a permission they already had. A
 * guess that cannot fail is not a check, so the message strings the platform
 * actually produces are pinned here as test data.
 *
 * Every case below is either an AOSP literal or a message observed from this app
 * on the device.
 */
class WifiJoinDiagnosisTest {

    // ------------------------------------------------------- location, the app

    @Test
    fun `aosp fine location message is attributed to the app permission`() {
        // Verbatim AOSP: ConnectivityService / WifiNetworkFactory reject path.
        assertEquals(
            WifiJoinDiagnosis.Kind.fineLocation,
            WifiJoinDiagnosis.classify(
                "Neither user 10789 nor current process has " +
                    "android.permission.ACCESS_FINE_LOCATION.",
            ),
        )
    }

    @Test
    fun `coarse location is treated as location`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.fineLocation,
            WifiJoinDiagnosis.classify(
                "Neither user 10789 nor current process has " +
                    "android.permission.ACCESS_COARSE_LOCATION."
            ),
        )
    }

    @Test
    fun `newer aosp wording is also attributed to the app permission`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.fineLocation,
            WifiJoinDiagnosis.classify(
                "App does not have ACCESS_FINE_LOCATION permission to scan for " +
                    "Wi-Fi networks",
            ),
        )
    }

    @Test
    fun `case does not matter`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.fineLocation,
            WifiJoinDiagnosis.classify("MISSING Access_Fine_Location permission"),
        )
    }

    // ---------------------------------------------- location, the master switch

    /**
     * The case that produced a false diagnosis in the field: the *permission* is
     * granted, the system's location master switch is off, and the platform
     * reports a permission failure anyway. Sending the user to the permission
     * screen is a dead end there — the fix is the quick-settings tile.
     */
    @Test
    fun `location master switch off is its own diagnosis`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.locationServicesOff,
            WifiJoinDiagnosis.classify(
                "Wi-Fi scan requires location services to be enabled",
            ),
        )
    }

    @Test
    fun `master switch off is not reported as an app permission problem`() {
        val kind = WifiJoinDiagnosis.classify("Location services are disabled")
        assertTrue(kind != WifiJoinDiagnosis.Kind.fineLocation)
    }

    /**
     * The predicate the UI uses to warn *before* attempting a join. The platform
     * usually does not name the master switch at all, so this state has to be
     * detected from the app's own measurements instead of from a message.
     */
    @Test
    fun `granted permission with the switch off is flagged as blocking`() {
        assertTrue(
            WifiJoinDiagnosis.locationServicesLikelyBlocking(
                fineLocationGranted = true,
                locationServicesEnabled = false,
            ),
        )
    }

    @Test
    fun `granted permission with the switch on is not flagged`() {
        assertFalse(
            WifiJoinDiagnosis.locationServicesLikelyBlocking(
                fineLocationGranted = true,
                locationServicesEnabled = true,
            ),
        )
    }

    @Test
    fun `a permission that is simply not granted is not flagged as the switch`() {
        // The distinction the app got wrong before: a refused permission is not a
        // disabled master switch, and they need different instructions.
        assertFalse(
            WifiJoinDiagnosis.locationServicesLikelyBlocking(
                fineLocationGranted = false,
                locationServicesEnabled = false,
            ),
        )
    }

    // ------------------------------------------------------------ nearby Wi-Fi

    @Test
    fun `nearby wifi devices is recognised under both spellings`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.nearbyWifiDevices,
            WifiJoinDiagnosis.classify(
                "Neither user 10789 nor current process has " +
                    "android.permission.NEARBY_WIFI_DEVICES.",
            ),
        )
        assertEquals(
            WifiJoinDiagnosis.Kind.nearbyWifiDevices,
            WifiJoinDiagnosis.classify("nearby Wi-Fi devices permission required"),
        )
    }

    /**
     * AOSP on some releases complains about both in one sentence. Nearby-Wi-Fi is
     * checked first on purpose: on API 33+ it is the permission that actually
     * governs the request, and it is the one the user can still act on.
     */
    @Test
    fun `a message naming both permissions prefers nearby wifi`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.nearbyWifiDevices,
            WifiJoinDiagnosis.classify(
                "Requires ACCESS_FINE_LOCATION or NEARBY_WIFI_DEVICES permission",
            ),
        )
    }

    // ----------------------------------------------------------- wifi state

    @Test
    fun `change wifi state is recognised`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.changeWifiState,
            WifiJoinDiagnosis.classify(
                "Neither user 10789 nor current process has " +
                    "android.permission.CHANGE_WIFI_STATE.",
            ),
        )
    }

    /**
     * **The failure that actually shipped.**
     *
     * `ConnectivityService.enforceChangePermission()` is the only place on the
     * `requestNetwork` path that throws synchronously, and it does so when
     * `CHANGE_NETWORK_STATE` is not declared. The real APK was missing that
     * declaration, so this exact message is what the user's phone produced for
     * three rounds of testing while the app blamed location and nearby-Wi-Fi
     * permissions — neither of which this code path consults at all.
     *
     * Pinned verbatim, both punctuations: API <= 30 writes ": " and ", ", API 31+
     * writes neither space, so the text also identifies which code path ran.
     */
    @Test
    fun `the aosp change network state message is recognised`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.changeNetworkState,
            WifiJoinDiagnosis.classify(
                "com.cem1.yi_m1_controller was not granted either of these " +
                    "permissions:android.permission.CHANGE_NETWORK_STATE," +
                    "android.permission.WRITE_SETTINGS.",
            ),
        )
        assertEquals(
            WifiJoinDiagnosis.Kind.changeNetworkState,
            WifiJoinDiagnosis.classify(
                "com.cem1.yi_m1_controller was not granted either of these " +
                    "permissions: android.permission.CHANGE_NETWORK_STATE, " +
                    "android.permission.WRITE_SETTINGS.",
            ),
        )
    }

    /**
     * The regression guard that matters: if this ever again reports a *location*
     * problem for the change-network-state message, the app is back to sending
     * the user to a switch that has nothing to do with the failure.
     */
    @Test
    fun `the change network state message is never blamed on location`() {
        val kind = WifiJoinDiagnosis.classify(
            "com.cem1.yi_m1_controller was not granted either of these " +
                "permissions:android.permission.CHANGE_NETWORK_STATE," +
                "android.permission.WRITE_SETTINGS.",
        )
        assertTrue(kind != WifiJoinDiagnosis.Kind.fineLocation)
        assertTrue(kind != WifiJoinDiagnosis.Kind.nearbyWifiDevices)
        assertTrue(kind != WifiJoinDiagnosis.Kind.locationServicesOff)
    }

    @Test
    fun `a uid mismatch is recognised before any permission name`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.uidPackageMismatch,
            WifiJoinDiagnosis.classify(
                "Package com.cem1.yi_m1_controller does not belong to uid 10123",
            ),
        )
    }

    /**
     * MIUI 双开 / 第二空间 runs a clone under a different UID, which is the shape
     * this detects. The advice must not be "grant a permission", because no
     * permission grant can change the calling UID.
     */
    @Test
    fun `the uid mismatch is never mistaken for a missing permission`() {
        val kind = WifiJoinDiagnosis.classify(
            "Package com.cem1.yi_m1_controller does not belong to uid 10123",
        )
        assertTrue(kind == WifiJoinDiagnosis.Kind.uidPackageMismatch)
        assertTrue(kind != WifiJoinDiagnosis.Kind.otherPermission)
    }

    // ------------------------------------------------------------ OEM gates

    @Test
    fun `miui specific rejection is its own diagnosis`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.oemRestriction,
            WifiJoinDiagnosis.classify(
                "com.miui.securitycenter refused the request: not allowed by the system",
            ),
        )
    }

    /**
     * MIUI quotes an AOSP permission name while actually refusing on its own
     * account. Reporting that as "grant ACCESS_FINE_LOCATION" would send the user
     * to a switch that is already on, so the OEM marker wins.
     */
    @Test
    fun `an oem refusal that quotes a permission name is still an oem refusal`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.oemRestriction,
            WifiJoinDiagnosis.classify(
                "miui: NEARBY_WIFI_DEVICES permission denied by privacy protection",
            ),
        )
    }

    // --------------------------------------------------------- honesty cases

    @Test
    fun `an unknown permission message keeps itself distinguishable`() {
        // The rule that matters: never collapse "I do not know" into a named
        // permission. The message text is what the UI falls back to showing.
        assertEquals(
            WifiJoinDiagnosis.Kind.otherPermission,
            WifiJoinDiagnosis.classify(
                "Neither user 10789 nor current process has " +
                    "android.permission.INTERACT_ACROSS_USERS.",
            ),
        )
    }

    @Test
    fun `a non permission failure is not called a permission failure`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.notPermission,
            WifiJoinDiagnosis.classify(
                "IllegalArgumentException: Invalid SSID: ",
            ),
        )
    }

    @Test
    fun `a null or blank message is not called a permission failure`() {
        assertEquals(
            WifiJoinDiagnosis.Kind.notPermission,
            WifiJoinDiagnosis.classify(null),
        )
        assertEquals(
            WifiJoinDiagnosis.Kind.notPermission,
            WifiJoinDiagnosis.classify("   "),
        )
    }
}
