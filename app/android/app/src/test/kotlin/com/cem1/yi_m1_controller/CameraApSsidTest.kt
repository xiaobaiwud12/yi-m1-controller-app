package com.cem1.yi_m1_controller

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one rule that decides whether the app may end a Wi-Fi association.
 *
 * ## Why this is a test and not a comment
 *
 * `releaseAssociation()` ends by calling `WifiManager.disconnect()` when the phone
 * is still on the camera's access point — the case no app-side `NetworkRequest` can
 * release, because the user joined by hand. The gate on it is this predicate, and
 * **getting it wrong drops the user's home Wi-Fi**: the app would tidy up after the
 * camera by disconnecting whatever network the phone happens to be on.
 *
 * That is the kind of mistake that only shows up on a real phone, at home, after the
 * camera has already been put away — so the rule is pinned here instead, where it
 * costs milliseconds and can actually fail.
 */
class CameraApSsidTest {

    @Test
    fun `the camera's own access point is recognised`() {
        assertTrue(CameraAp.matches("YI_M1_XXXXXX"))
    }

    @Test
    fun `the prefix is matched case-insensitively`() {
        assertTrue(CameraAp.matches("yi_m1_cae5d2"))
        assertTrue(CameraAp.matches("Yi_M1_Cae5D2"))
    }

    @Test
    fun `a home network is not a camera, however similar the name`() {
        // The bare prefix is not a name the camera would use (its APs carry a
        // suffix), and every near-miss here is a network whose disconnection would
        // be a real user-visible fault.
        assertFalse(CameraAp.matches("YI_M1"))
        assertFalse(CameraAp.matches("YI-M1_cae5d2"))
        assertFalse(CameraAp.matches("MYI_M1_XXXXXX"))
        assertFalse(CameraAp.matches("YI"))
        assertFalse(CameraAp.matches("HomeWifi"))
        assertFalse(CameraAp.matches("ChinaNet-2.4G"))
    }

    @Test
    fun `nothing at all is not a camera`() {
        // The three shapes `WifiInfo.ssid` produces when there is no association or
        // no permission to read it. `null` is the one that would crash a naive
        // `startsWith`; `"<unknown ssid>"` is the one that would be mistaken for a
        // real name — the mistake this app's own `ssidOf` records from the join
        // path, where a phone on the home network was read as a phone on the camera.
        assertFalse(CameraAp.matches(null))
        assertFalse(CameraAp.matches(""))
        assertFalse(CameraAp.matches("<unknown ssid>"))
    }
}
