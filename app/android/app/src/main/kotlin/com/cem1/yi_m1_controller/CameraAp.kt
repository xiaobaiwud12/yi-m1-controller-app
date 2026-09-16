package com.cem1.yi_m1_controller

/**
 * Whether an SSID is one of the camera's access points.
 *
 * ## Why this rule gets a file of its own
 *
 * `releaseAssociation()` asks the platform to leave the camera's network when the
 * phone is still associated with it. That call — `WifiManager.disconnect()` — has
 * **no argument**: it drops whatever network the phone is on, so the only thing
 * standing between "tidy up after the camera" and "disconnect the user's home
 * Wi-Fi" is this predicate.
 *
 * The mistake it prevents is not hypothetical. A phone left on a dead camera AP
 * while the app says "disconnected" is the defect this whole round is about, and
 * the tempting over-correction is to call `disconnect()` unconditionally — which
 * works perfectly in testing, because a camera with no network is exactly the
 * situation where nobody notices the home network being dropped.
 *
 * So the rule is a **pure function**, in the same shape as [WifiJoinDiagnosis]:
 * testable exhaustively on the JVM (`CameraApSsidTest`), with no device, no
 * emulator and no radio.
 *
 * ## What it is not
 *
 * It is not a security boundary — an SSID is a name anyone can choose. It is a
 * blast-radius limit: the app will only ever end an association it can recognise
 * as the camera's, and refuses to guess otherwise.
 *
 * The same rule exists in Dart as `looksLikeCameraAp` (`wifi_join_contract.dart`),
 * deliberately duplicated: the native side cannot wait for a platform-channel round
 * trip before deciding whether it may leave a network, and a Dart/native
 * disagreement would be a silent permission to do the wrong thing.
 */
object CameraAp {

    /**
     * Every camera AP is named `YI_M1_<suffix>` — `YI_M1_XXXXXX` on the unit this
     * was developed against.
     */
    const val PREFIX = "YI_M1_"

    /**
     * Whether [ssid] names a camera access point.
     *
     * Case-insensitive because the comparison is against what `WifiInfo.ssid`
     * reports, and SSIDs are case-preserving on the AP side and reported verbatim.
     *
     * Answers `false` for everything it cannot read as a name — `null`, the empty
     * string, and `WifiInfo`'s `"<unknown ssid>"` placeholder, which is what the
     * platform returns when the caller lacks the location permission. That last one
     * matters: it is a *string*, so a naive `startsWith` check on a truthy value
     * would treat "I cannot tell you" as a name, and this app has already once
     * mistaken one network for another exactly that way (see `ssidOf`, which drops
     * any name starting with `<`).
     */
    fun matches(ssid: String?): Boolean =
        ssid != null &&
            !ssid.startsWith("<") &&
            ssid.uppercase().startsWith(PREFIX)
}
