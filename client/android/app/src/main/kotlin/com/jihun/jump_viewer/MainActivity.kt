package com.jihun.jump_viewer

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream

class MainActivity : FlutterActivity() {
    private var pickResult: MethodChannel.Result? = null
    /** Files handed to the app through the share sheet, until Flutter takes them. */
    private val shared = mutableListOf<Map<String, Any?>>()
    private val reads = mutableMapOf<Int, InputStream>()
    private val saves = mutableMapOf<Int, Pair<Uri, OutputStream>>()
    private var nextHandle = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Screen rotation for the viewer only. Flutter's SystemChrome maps "any orientation" to
        // the USER variants, which obey the phone's rotation lock; the viewer's 자동/가로 should
        // follow the sensor inside this app even when the phone is locked to portrait.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jump/orientation")
            .setMethodCallHandler { call, result ->
                requestedOrientation = when (call.arguments as? String) {
                    "auto" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR
                    "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                    "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED // back to the phone's setting
                }
                result.success(null)
            }

        // Files for the Mac (the picker, the share sheet) and from it (into Downloads). Content
        // URIs are read in order through a handle, so a big file never sits in memory at once.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jump/files")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "pick" -> {
                            pickResult?.success(emptyList<Any>())
                            pickResult = result
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            }
                            startActivityForResult(intent, PICK_FILES)
                        }
                        "shared" -> {
                            result.success(shared.toList())
                            shared.clear()
                        }
                        "readOpen" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            val stream = contentResolver.openInputStream(uri) ?: throw IllegalStateException("cannot open")
                            val id = nextHandle++
                            reads[id] = stream
                            result.success(id)
                        }
                        "readNext" -> {
                            val stream = reads[call.argument<Int>("id")!!] ?: throw IllegalStateException("not open")
                            val length = call.argument<Int>("length")!!
                            val buffer = ByteArray(length)
                            var filled = 0
                            while (filled < length) {
                                val got = stream.read(buffer, filled, length - filled)
                                if (got < 0) break
                                filled += got
                            }
                            result.success(buffer.copyOf(filled))
                        }
                        "readClose" -> {
                            reads.remove(call.argument<Int>("id")!!)?.close()
                            result.success(null)
                        }
                        "saveOpen" -> {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) throw IllegalStateException("Android 10 이상에서 받을 수 있습니다")
                            val name = call.argument<String>("name")!!
                            val values = ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, name)
                                put(MediaStore.Downloads.MIME_TYPE, mimeType(name))
                                put(MediaStore.Downloads.IS_PENDING, 1)
                            }
                            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                                ?: throw IllegalStateException("cannot create")
                            val stream = contentResolver.openOutputStream(uri) ?: throw IllegalStateException("cannot write")
                            val id = nextHandle++
                            saves[id] = Pair(uri, stream)
                            result.success(id)
                        }
                        "saveWrite" -> {
                            val save = saves[call.argument<Int>("id")!!] ?: throw IllegalStateException("not open")
                            save.second.write(call.argument<ByteArray>("bytes")!!)
                            result.success(null)
                        }
                        "saveClose" -> {
                            val id = call.argument<Int>("id")!!
                            val keep = call.argument<Boolean>("keep") ?: true
                            val save = saves.remove(id) ?: throw IllegalStateException("not open")
                            save.second.close()
                            if (keep && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                contentResolver.update(save.first, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                            } else if (!keep) {
                                contentResolver.delete(save.first, null, null)
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("files", e.message, null)
                }
            }
        takeShared(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeShared(intent)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILES) return
        val result = pickResult ?: return
        pickResult = null
        val uris = mutableListOf<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            else data.data?.let { uris.add(it) }
        }
        result.success(uris.mapNotNull { describe(it) })
    }

    /** Files from the share sheet ("Wherever로 보내기"), kept until Flutter asks for them. */
    @Suppress("DEPRECATION")
    private fun takeShared(intent: Intent?) {
        val uris: List<Uri> = when (intent?.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM) ?: emptyList()
            else -> emptyList()
        }
        if (uris.isEmpty()) return
        for (uri in uris) describe(uri)?.let { shared.add(it) }
        intent?.action = null // not again when the activity is recreated
    }

    private fun describe(uri: Uri): Map<String, Any?>? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            val name = cursor.getString(0) ?: "file"
            val size = if (cursor.isNull(1)) -1L else cursor.getLong(1)
            return mapOf("uri" to uri.toString(), "name" to name, "size" to size)
        }
        return null
    }

    private fun mimeType(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    companion object {
        private const val PICK_FILES = 41
    }
}
