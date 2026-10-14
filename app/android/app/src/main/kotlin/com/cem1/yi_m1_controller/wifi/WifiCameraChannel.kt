package com.cem1.yi_m1_controller.wifi


import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
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
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

import io.flutter.plugin.common.BinaryMessenger

/** One network request/suggestion lifecycle per host Activity. */
class WifiCameraChannel(private val activity: Activity) {
    private companion object {
        const val REQ_ADD_NETWORKS = 7001
    }
    private val channelName = "com.cem1.yi_m1_controller/wifi"

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


    init {
        connectivityManager =
            activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        wifiManager =
            activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, channelName)
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
            "targetSdk" to activity.applicationInfo.targetSdkVersion,
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
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

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
        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
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
        activity.startActivity(
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
            activity.startActivityForResult(
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
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
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
                activity.startActivity(
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
            activity.registerReceiver(receiver, filter)
            wifiStateReceiver = receiver
        } catch (_: Exception) {
        }
    }

    private fun unregisterWifiStateReceiver() {
        val receiver = wifiStateReceiver ?: return
        try {
            activity.unregisterReceiver(receiver)
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


    fun pause() {
        unbindFromCamera()
    }

    fun dispose() {
        unbindFromCamera()
        releaseCallback()
        stopWaitingForSuggestion()
    }
}
