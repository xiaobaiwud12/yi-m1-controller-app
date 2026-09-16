package com.cem1.yi_m1_controller

/**
 * Turns the platform's opaque Wi-Fi join failures into something the user can act
 * on.
 *
 * ## Why this exists
 *
 * `ConnectivityManager.requestNetwork()` with a `WifiNetworkSpecifier` fails by
 * throwing a `SecurityException` whose message is written for a platform
 * engineer, not a camera owner: "Neither user 10789 nor current process has
 * android.permission.ACCESS_FINE_LOCATION". The app was reporting every one of
 * these as *"a required permission is missing — grant location or nearby Wi-Fi
 * devices"*, which is actively misleading when the user has already granted
 * both, because the real cause is then something else entirely: location
 * services switched off at the system level, an OEM app-permission list, or a
 * permission that is not the one named.
 *
 * So the classification lives here, as a **pure function over the message
 * string**, for two reasons:
 *
 *  * it can be unit-tested exhaustively against the real AOSP message texts
 *    (`WifiJoinDiagnosisTest`) without a device or an emulator, which matters
 *    because this is precisely the code that has been wrong twice; and
 *  * it is honest about not knowing. An unrecognised message is reported as
 *    [Kind.otherPermission] **with the raw text kept**, never silently mapped
 *    onto a guess.
 */
object WifiJoinDiagnosis {

    /** What the platform's message actually refers to. */
    enum class Kind {
        /** The app does not hold `ACCESS_FINE_LOCATION`. */
        fineLocation,

        /** The app does not hold `NEARBY_WIFI_DEVICES` (or the OEM's equivalent). */
        nearbyWifiDevices,

        /**
         * Location services are switched off for the whole device.
         *
         * Distinct from [fineLocation] because the fix is different and the
         * system reports it as a permission failure even when the permission is
         * granted — `PermissionChecker` answers DENIED for a granted location
         * permission while the location master switch is off.
         */
        locationServicesOff,

        /** The app does not hold `CHANGE_WIFI_STATE` / `CHANGE_NETWORK_STATE`. */
        changeWifiState,

        /**
         * `CHANGE_NETWORK_STATE` is not declared.
         *
         * **This is the one that actually happened.** `ConnectivityService`
         * checks it before the request is dispatched, and it is a *normal*
         * permission — declaring it is enough, nothing is granted at runtime. It
         * was simply absent from the manifest, and because `ACCESS_NETWORK_STATE`
         * *was* present, nothing about the permission list looked wrong.
         *
         * Kept separate from [changeWifiState] because the cause and the fix are
         * different: `CHANGE_WIFI_STATE` is granted at install and can only go
         * missing if the build is broken, while this one is a source-level
         * omission that no amount of user action can work around.
         */
        changeNetworkState,

        /**
         * The calling package does not belong to the calling UID.
         *
         * Raised by `AppOpsManager.checkPackage` at the end of the same check.
         * MIUI's 双开 / 第二空间 (Dual Apps / Second Space) clones an app under a
         * different UID, which is exactly the shape this detects — so the advice
         * is "run it outside the clone", not "grant a permission".
         */
        uidPackageMismatch,

        /** An OEM (MIUI/HyperOS, EMUI, ColorOS…) blocked the request itself. */
        oemRestriction,

        /** A permission is named, but not one this app knows how to fix. */
        otherPermission,

        /** Not a permission problem at all. */
        notPermission,
    }

    /**
     * Classify a caught exception's message.
     *
     * Matching is deliberately case-insensitive and substring-based: AOSP,
     * Google's `ConnectivityManager` wrappers and OEM forks all phrase these
     * differently, and the message is the only signal available.
     */
    fun classify(message: String?): Kind {
        if (message.isNullOrBlank()) return Kind.notPermission
        val text = message.lowercase()

        // Order matters. The most specific phrases come first, because several
        // AOSP messages mention more than one permission in a single sentence
        // ("...has android.permission.ACCESS_FINE_LOCATION" appears inside a
        // longer complaint that also names nearby-wifi-devices on some builds).
        return when {
            // The OEM's own gate, which no AOSP permission grant can satisfy.
            // Checked before the permission names because MIUI's message quotes
            // them while actually meaning "our privacy protection said no".
            containsAny(
                text,
                "securitycenter",
                "miui",
                "hyperos",
                "privacy protection",
                "not allowed by the system",
                "rejected by the system",
            ) -> Kind.oemRestriction

            // The system location master switch. Named explicitly by some builds.
            containsAny(
                text,
                "location services",
                "location service is disabled",
                "location is disabled",
                "location off",
                "gps is disabled",
                "settings.secure.location_mode",
            ) -> Kind.locationServicesOff

            // Both spellings: AOSP writes the permission as NEARBY_WIFI_DEVICES,
            // while every human-facing string — including Google's own failure
            // text and the permission dialog the user just tapped — writes it as
            // "nearby Wi-Fi devices". Missing the hyphenated form made this
            // classifier answer `otherPermission` for the single most likely
            // message on API 33+; the unit test caught it.
            containsAny(
                text,
                "nearby_wifi",
                "nearby wifi",
                "nearby wi-fi",
                "nearby devices",
            ) -> Kind.nearbyWifiDevices

            containsAny(
                text,
                "access_fine_location",
                "access_coarse_location",
                "fine_location",
                "coarse_location",
            ) -> Kind.fineLocation

            // The package/UID mismatch, which is a clone-detection failure rather
            // than a permission one — checked before the permission names because
            // the message contains neither.
            containsAny(
                text,
                "does not belong to uid",
                "does not belong to userId",
            ) -> Kind.uidPackageMismatch

            // The AOSP literal, in both its punctuations. API <= 30 writes
            // ": " and ", "; API 31+ writes neither space, so the quoted text
            // also reveals which code path ran.
            containsAny(
                text,
                "was not granted either of these permissions",
                "change_network_state",
            ) -> Kind.changeNetworkState

            containsAny(text, "change_wifi_state") -> Kind.changeWifiState

            // A permission is implicated but this code cannot name the fix.
            text.contains("permission") || text.contains("not allowed") ->
                Kind.otherPermission

            else -> Kind.notPermission
        }
    }

    /**
     * Whether the device's location master switch being off would explain a
     * [Kind.fineLocation] failure.
     *
     * Kept separate from [classify] because this is about the app's *state*, not
     * about a message, and the UI needs to warn about it **before** the join is
     * attempted — the platform's failure for this case does not mention the
     * master switch at all on most builds.
     */
    fun locationServicesLikelyBlocking(
        fineLocationGranted: Boolean,
        locationServicesEnabled: Boolean,
    ): Boolean = fineLocationGranted && !locationServicesEnabled

    private fun containsAny(text: String, vararg needles: String): Boolean =
        needles.any { text.contains(it) }
}
