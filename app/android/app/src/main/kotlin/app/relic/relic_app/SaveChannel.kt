package app.relic.relic_app

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Writes decrypted blobs into the user's real, public Downloads collection.
 *
 * Why this exists: the file_saver plugin's Android `saveFile` writes to
 * `getExternalFilesDir(null)` — app-private storage that Android 11+ hides from
 * every file manager and wipes on uninstall. Users tap "Save" and the file
 * effectively vanishes. MediaStore.Downloads is the scoped-storage-correct
 * public destination and needs no permission at all on API 29+.
 *
 * API 24-28 has no MediaStore.Downloads collection; writing to the public dir
 * there would need WRITE_EXTERNAL_STORAGE, which we deliberately do not ship.
 * [available] reports false on those devices and the Dart side falls back to the
 * system save sheet (ACTION_CREATE_DOCUMENT), which is permission-free.
 */
class SaveChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "relic/save"

        fun register(messenger: BinaryMessenger, context: Context): MethodChannel {
            val channel = MethodChannel(messenger, CHANNEL)
            channel.setMethodCallHandler(SaveChannel(context))
            return channel
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(available())
            "saveToDownloads" -> saveToDownloads(call, result)
            // Startup diagnostics: how long the process had been alive by the
            // time Dart asked. Everything before Dart's own clock starts —
            // zygote fork, native libs, engine init, plugin registration — is
            // invisible from Dart, and that blind spot is exactly where the
            // launch cost might be hiding. See data/boot_trace.dart.
            "millisSinceProcessStart" ->
                result.success(
                    (SystemClock.uptimeMillis() - Process.getStartUptimeMillis()).toInt()
                )
            else -> result.notImplemented()
        }
    }

    private fun available(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun saveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        if (!available()) {
            result.error("unsupported", "MediaStore.Downloads needs Android 10+", null)
            return
        }
        val name = call.argument<String>("name")
        val sourcePath = call.argument<String>("sourcePath")
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        if (name.isNullOrBlank() || sourcePath.isNullOrBlank()) {
            result.error("bad_args", "name and sourcePath are required", null)
            return
        }
        val source = File(sourcePath)
        if (!source.isFile) {
            result.error("bad_args", "the decrypted file is no longer on disk", null)
            return
        }

        val resolver = context.contentResolver
        var uri: Uri? = null
        try {
            // IS_PENDING hides the row from other apps until the bytes are all
            // written, so a half-written file is never visible or openable.
            val pending = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, pending)
                ?: throw IllegalStateException("Downloads is unavailable on this device")

            // Streamed, not handed over as one ByteArray: a relic can be up to
            // 100 MB, and buffering that whole payload across the platform
            // channel is how you OOM a mid-range phone.
            resolver.openOutputStream(uri)?.use { out ->
                source.inputStream().use { input -> input.copyTo(out, 64 * 1024) }
            } ?: throw IllegalStateException("Could not open Downloads for writing")

            val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)

            // MediaStore de-duplicates names itself ("report.pdf" -> "report (1).pdf"),
            // so read back what it actually called the file for the confirmation.
            result.success("Download/${displayName(uri) ?: name}")
        } catch (e: Exception) {
            // Roll the placeholder row back so a failed save leaves no 0-byte
            // entry sitting in the user's Downloads.
            if (uri != null) {
                try {
                    resolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
            }
            result.error("save_failed", e.message ?: "Could not save to Downloads", null)
        }
    }

    private fun displayName(uri: Uri): String? = try {
        resolverQueryName(uri)
    } catch (_: Exception) {
        null
    }

    private fun resolverQueryName(uri: Uri): String? {
        val projection = arrayOf(MediaStore.Downloads.DISPLAY_NAME)
        context.contentResolver.query(uri, projection, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val i = c.getColumnIndex(MediaStore.Downloads.DISPLAY_NAME)
                if (i >= 0) return c.getString(i)
            }
        }
        return null
    }
}
