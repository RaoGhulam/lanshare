// Implements the "lanshare/share" MethodChannel used by
// lib/services/share_intent_service.dart, so LANShare appears in Android's
// share sheet (next to WhatsApp etc.).
//
// Shared content:// URIs are only readable for a short time and can't be
// opened with plain Dart File APIs, so every shared file is copied into the
// app's cache directory first and Dart receives ordinary file paths.

package com.example.lanshare

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class ShareHandler(
    context: Context,
    private val channel: MethodChannel
) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Set once Dart has asked for the initial shares and installed its handler. */
    private var dartReady = false
    private val pending = mutableListOf<Map<String, Any?>>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInitialShares" -> {
                dartReady = true
                result.success(ArrayList(pending))
                pending.clear()
            }
            else -> result.notImplemented()
        }
    }

    /** Handles ACTION_SEND / ACTION_SEND_MULTIPLE; ignores anything else. */
    fun handleIntent(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(HANDLED_EXTRA, false)) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        // Don't re-import the same share if the activity is recreated.
        intent.putExtra(HANDLED_EXTRA, true)

        val uris = streamUris(intent, action)
        // When files are shared, EXTRA_TEXT is usually just a caption.
        val text = if (uris.isEmpty()) intent.getStringExtra(Intent.EXTRA_TEXT) else null
        if (uris.isEmpty() && text.isNullOrEmpty()) return

        // Copying can take a while for big files - keep it off the UI thread.
        Thread {
            val paths = uris.mapNotNull { copyToCache(it) }
            mainHandler.post { deliver(mapOf("files" to paths, "text" to text)) }
        }.start()
    }

    private fun deliver(item: Map<String, Any?>) {
        if (dartReady) {
            channel.invokeMethod("onShare", item)
        } else {
            pending.add(item)
        }
    }

    @Suppress("DEPRECATION")
    private fun streamUris(intent: Intent, action: String): List<Uri> {
        return if (action == Intent.ACTION_SEND) {
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            listOfNotNull(uri)
        } else {
            val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            list?.filterNotNull() ?: emptyList()
        }
    }

    private fun copyToCache(uri: Uri): String? {
        return try {
            val name = sanitize(displayName(uri) ?: uri.lastPathSegment ?: "shared_file")
            // A fresh folder per file keeps the original name intact (it's
            // what the receiver sees) while avoiding collisions.
            val dir = File(appContext.cacheDir, "shared_in/${System.nanoTime()}")
            dir.mkdirs()
            val out = File(dir, name)
            appContext.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(out).use { output -> input.copyTo(output) }
            } ?: return null
            out.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme != "content") return null
        return try {
            appContext.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[/\\\\]"), "_").trim()
        return cleaned.ifEmpty { "shared_file" }
    }

    companion object {
        private const val HANDLED_EXTRA = "com.example.lanshare.SHARE_HANDLED"
    }
}
