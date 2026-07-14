// Replace the auto-generated
//   android/app/src/main/kotlin/<your/package/path>/MainActivity.kt
// (created by `flutter create .`) with this file, then fix the
// `package` line below to match your app's actual package name (the same
// one used in android/app/build.gradle -> applicationId / namespace).
//
// This implements the "lanshare/media_store" MethodChannel that
// lib/services/media_store_helper.dart calls into. It publishes a
// received file into the public Downloads/LANShare folder:
//
// - Android 10+ (API 29+): via MediaStore.Downloads. No storage permission
//   is required for this at all - inserting through MediaStore is exactly
//   what scoped storage wants apps to do, so there is nothing that can be
//   "denied".
// - Android 9 and below (API 28-): scoped storage doesn't exist yet, so a
//   plain file copy into the public Downloads directory works, as long as
//   WRITE_EXTERNAL_STORAGE is granted (requested from the Dart side).

package com.example.lanshare

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "lanshare/media_store"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val displayName = call.argument<String>("displayName")
                        if (sourcePath == null || displayName == null) {
                            result.error(
                                "ARGS",
                                "sourcePath and displayName are required",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            val publicPath = saveToDownloads(sourcePath, displayName)
                            result.success(publicPath)
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Copies [sourcePath] (an app-private file) into the public
     * Downloads/LANShare folder as [displayName], returning a
     * human-readable path/description of where it landed.
     */
    private fun saveToDownloads(sourcePath: String, displayName: String): String {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            throw IllegalStateException("Source file does not exist: $sourcePath")
        }

        val extension = displayName.substringAfterLast('.', "")
        val mimeType = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(extension.lowercase())
            ?: "application/octet-stream"

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveViaMediaStore(sourceFile, displayName, mimeType)
        } else {
            saveViaLegacyFileIo(sourceFile, displayName, mimeType)
        }
    }

    /** Android 10+ (API 29+): no runtime permission needed for this at all. */
    private fun saveViaMediaStore(
        sourceFile: File,
        displayName: String,
        mimeType: String
    ): String {
        val resolver = applicationContext.contentResolver

        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(
                MediaStore.Downloads.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + "/LANShare"
            )
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val itemUri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")

        try {
            resolver.openOutputStream(itemUri)?.use { out ->
                FileInputStream(sourceFile).use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("Could not open output stream for $itemUri")

            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(itemUri, values, null, null)
        } catch (e: Exception) {
            // Clean up the half-written MediaStore row so it doesn't show up
            // as a broken/empty entry in the Files app.
            resolver.delete(itemUri, null, null)
            throw e
        }

        sourceFile.delete()
        return "Download/LANShare/$displayName"
    }

    /** Android 9 and below (API 28-): pre-scoped-storage, plain file copy. */
    private fun saveViaLegacyFileIo(
        sourceFile: File,
        displayName: String,
        mimeType: String
    ): String {
        val downloadsDir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "LANShare"
        )
        if (!downloadsDir.exists()) {
            downloadsDir.mkdirs()
        }

        var destFile = File(downloadsDir, displayName)
        if (destFile.exists()) {
            val dotIndex = displayName.lastIndexOf('.')
            val base = if (dotIndex > 0) displayName.substring(0, dotIndex) else displayName
            val ext = if (dotIndex > 0) displayName.substring(dotIndex) else ""
            var counter = 1
            while (destFile.exists()) {
                destFile = File(downloadsDir, "$base($counter)$ext")
                counter++
            }
        }

        FileInputStream(sourceFile).use { input ->
            FileOutputStream(destFile).use { output -> input.copyTo(output) }
        }
        sourceFile.delete()

        // Let the media scanner know, so it shows up in the Gallery / other
        // apps immediately instead of after the next reboot/scan.
        android.media.MediaScannerConnection.scanFile(
            applicationContext,
            arrayOf(destFile.absolutePath),
            arrayOf(mimeType),
            null
        )

        return destFile.absolutePath
    }
}
