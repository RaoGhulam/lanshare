// Implements the "lanshare/hotspot" MethodChannel used by
// lib/services/hotspot_service.dart. Lets two devices talk without any Wi-Fi
// router:
//
// - The host starts an offline "local-only" hotspot (WifiManager
//   .startLocalOnlyHotspot, Android 8+). Android picks a random SSID and
//   password; no mobile data is shared and nothing has to be configured in
//   Settings.
// - Another Android device joins it with WifiNetworkSpecifier (Android 10+,
//   the user approves a one-tap system dialog) or the legacy WifiConfiguration
//   API (Android 8-9), and binds the whole process to that network so Dart's
//   sockets go through it.
// - Laptops (Windows/Linux) just join the hotspot like any other Wi-Fi.
//
// Once both sides share the hotspot network, the normal TCP transfer code is
// used unchanged.

package com.example.lanshare

import android.content.Context
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

class HotspotHandler(context: Context) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val wifiManager =
        appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val connectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var legacyNetworkId = -1

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "startHotspot" -> startHotspot(result)
            "stopHotspot" -> {
                stopHotspot()
                result.success(null)
            }
            "joinNetwork" -> {
                val ssid = call.argument<String>("ssid")
                val password = call.argument<String>("password")
                if (ssid.isNullOrEmpty()) {
                    result.error("ARGS", "ssid is required", null)
                } else {
                    joinNetwork(ssid, password, result)
                }
            }
            "leaveNetwork" -> {
                leaveNetwork()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        stopHotspot()
        leaveNetwork()
    }

    // ---------------------------------------------------------------------
    // Hosting.
    // ---------------------------------------------------------------------

    private fun startHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("UNSUPPORTED", "Offline hotspot needs Android 8.0 or newer.", null)
            return
        }
        // Before Android 13 the hotspot API is gated on location services
        // being switched on (not just the permission being granted).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !isLocationEnabled()) {
            result.error(
                "LOCATION_OFF",
                "Turn on Location - Android requires it to create a hotspot.",
                null
            )
            return
        }

        stopHotspot()
        val addressesBefore = ipv4Addresses().keys
        var replied = false

        try {
            wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = res
                    val (ssid, password) = credentials(res)
                    waitForHotspotIp(addressesBefore, 0) { ip ->
                        if (replied) return@waitForHotspotIp
                        replied = true
                        result.success(
                            mapOf("ssid" to ssid, "password" to password, "ip" to ip)
                        )
                    }
                }

                override fun onStopped() {
                    reservation = null
                }

                override fun onFailed(reason: Int) {
                    if (replied) return
                    replied = true
                    result.error("HOTSPOT_FAILED", failureMessage(reason), null)
                }
            }, mainHandler)
        } catch (e: SecurityException) {
            result.error("PERMISSION", "Permission denied: ${e.message}", null)
        } catch (e: IllegalStateException) {
            result.error("HOTSPOT_FAILED", e.message ?: "Hotspot already running", null)
        }
    }

    private fun stopHotspot() {
        reservation?.close()
        reservation = null
    }

    @Suppress("DEPRECATION")
    private fun credentials(res: WifiManager.LocalOnlyHotspotReservation): Pair<String?, String?> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = res.softApConfiguration
            Pair(config.ssid?.removeSurrounding("\""), config.passphrase)
        } else {
            val config = res.wifiConfiguration
            Pair(config?.SSID?.removeSurrounding("\""), config?.preSharedKey?.removeSurrounding("\""))
        }
    }

    /**
     * The hotspot's own IP (usually 192.168.x.1 or 10.x.x.1) shows up on a
     * new network interface shortly after onStarted. Poll for an address
     * that wasn't there before, preferring soft-AP style interface names.
     */
    private fun waitForHotspotIp(before: Set<String>, attempt: Int, done: (String?) -> Unit) {
        val now = ipv4Addresses()
        val fresh = now.filterKeys { it !in before }
        val pick = fresh.entries.firstOrNull { isApInterface(it.value) }?.key
            ?: fresh.keys.firstOrNull()

        if (pick != null) {
            done(pick)
        } else if (attempt >= 20) {
            // Nothing new appeared (some devices reuse an existing
            // interface); fall back to any soft-AP looking address.
            done(now.entries.firstOrNull { isApInterface(it.value) }?.key)
        } else {
            mainHandler.postDelayed({ waitForHotspotIp(before, attempt + 1, done) }, 250)
        }
    }

    private fun isApInterface(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("ap") || n.startsWith("swlan") || n.startsWith("softap") ||
            n.startsWith("wlan") || n.startsWith("wifi")
    }

    /** Map of IPv4 address -> interface name for every interface that is up. */
    private fun ipv4Addresses(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        try {
            for (nif in Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nif.isUp || nif.isLoopback) continue
                for (addr in Collections.list(nif.inetAddresses)) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        addr.hostAddress?.let { out[it] = nif.name }
                    }
                }
            }
        } catch (_: Exception) {
        }
        return out
    }

    private fun isLocationEnabled(): Boolean {
        val lm = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    private fun failureMessage(reason: Int): String = when (reason) {
        WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL ->
            "No free Wi-Fi channel to start the hotspot on."
        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE ->
            "Turn off your regular mobile hotspot / tethering and try again."
        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED ->
            "Hotspots are disabled on this device by its administrator."
        else ->
            "Could not start the hotspot. Turn off any mobile hotspot or tethering and try again."
    }

    // ---------------------------------------------------------------------
    // Joining.
    // ---------------------------------------------------------------------

    private fun joinNetwork(ssid: String, password: String?, result: MethodChannel.Result) {
        leaveNetwork()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            joinWithSpecifier(ssid, password, result)
        } else {
            joinLegacy(ssid, password, result)
        }
    }

    /** Android 10+: system shows a one-tap "Connect to device?" dialog. */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun joinWithSpecifier(ssid: String, password: String?, result: MethodChannel.Result) {
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .apply { if (!password.isNullOrEmpty()) setWpa2Passphrase(password) }
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        var replied = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Route all of this process's sockets (including Dart's)
                // through the hotspot, even though it has no internet.
                connectivityManager.bindProcessToNetwork(network)
                mainHandler.post {
                    if (!replied) {
                        replied = true
                        result.success(null)
                    }
                }
            }

            override fun onUnavailable() {
                mainHandler.post {
                    networkCallback = null
                    if (!replied) {
                        replied = true
                        result.error(
                            "JOIN_FAILED",
                            "Could not join \"$ssid\" (cancelled or out of range).",
                            null
                        )
                    }
                }
            }

            override fun onLost(network: Network) {
                connectivityManager.bindProcessToNetwork(null)
            }
        }

        networkCallback = callback
        try {
            connectivityManager.requestNetwork(request, callback, 30_000)
        } catch (e: Exception) {
            networkCallback = null
            result.error("JOIN_FAILED", e.message, null)
        }
    }

    /** Android 8-9: no specifier API yet, add a regular saved network. */
    @Suppress("DEPRECATION")
    private fun joinLegacy(ssid: String, password: String?, result: MethodChannel.Result) {
        if (!wifiManager.isWifiEnabled) {
            wifiManager.isWifiEnabled = true
        }
        val config = WifiConfiguration().apply {
            SSID = "\"$ssid\""
            if (password.isNullOrEmpty()) {
                allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            } else {
                preSharedKey = "\"$password\""
            }
        }
        val id = wifiManager.addNetwork(config)
        if (id == -1) {
            result.error("JOIN_FAILED", "Could not add Wi-Fi network \"$ssid\".", null)
            return
        }
        legacyNetworkId = id
        wifiManager.disconnect()
        wifiManager.enableNetwork(id, true)
        wifiManager.reconnect()
        pollLegacyConnection(ssid, 0, result)
    }

    @Suppress("DEPRECATION")
    private fun pollLegacyConnection(ssid: String, attempt: Int, result: MethodChannel.Result) {
        val info = wifiManager.connectionInfo
        if (info != null && info.ssid == "\"$ssid\"" && info.ipAddress != 0) {
            result.success(null)
            return
        }
        if (attempt >= 60) {
            result.error("JOIN_FAILED", "Timed out joining \"$ssid\".", null)
            return
        }
        mainHandler.postDelayed({ pollLegacyConnection(ssid, attempt + 1, result) }, 250)
    }

    private fun leaveNetwork() {
        networkCallback?.let {
            try {
                connectivityManager.unregisterNetworkCallback(it)
            } catch (_: Exception) {
                // Already released (e.g. after onUnavailable).
            }
        }
        networkCallback = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager.bindProcessToNetwork(null)
        }
        if (legacyNetworkId != -1) {
            @Suppress("DEPRECATION")
            wifiManager.removeNetwork(legacyNetworkId)
            legacyNetworkId = -1
        }
    }
}
