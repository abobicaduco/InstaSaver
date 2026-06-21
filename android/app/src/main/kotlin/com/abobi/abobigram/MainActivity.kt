package com.abobi.abobigram

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.abobi.instasaver/files")
            .setMethodCallHandler { call, result ->
                if (call.method == "saveFile") {
                    val tempPath = call.argument<String>("tempPath")
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    val filename = call.argument<String>("filename") ?: "IG_${System.currentTimeMillis()}.${if (isVideo) "mp4" else "jpg"}"
                    if (tempPath == null) {
                        result.error("MISSING_ARG", "tempPath is required", null)
                    } else {
                        saveToDownloads(tempPath, filename, isVideo, result)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun saveToDownloads(
        tempPath: String,
        filename: String,
        isVideo: Boolean,
        result: MethodChannel.Result
    ) {
        try {
            val src = File(tempPath)
            if (!src.exists()) {
                result.error("NOT_FOUND", "Temp file not found: $tempPath", null)
                return
            }
            val subfolder = if (isVideo) "videos" else "fotos"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ (API 29+): MediaStore.Downloads — sem permissão extra
                val mime = if (isVideo) "video/mp4" else "image/jpeg"
                val cv = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, filename)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, "Download/AbobiGram/$subfolder")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv)
                if (uri != null) {
                    resolver.openOutputStream(uri)?.use { out ->
                        src.inputStream().use { inp -> inp.copyTo(out) }
                    }
                    cv.clear()
                    cv.put(MediaStore.Downloads.IS_PENDING, 0)
                    resolver.update(uri, cv, null, null)
                    src.delete()
                    result.success(uri.toString())
                } else {
                    result.error("INSERT_FAILED", "MediaStore.insert retornou null", null)
                }
            } else {
                // Android < 10: escrita direta em /storage/emulated/0/Download/
                @Suppress("DEPRECATION")
                val dl = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                val dir = File(dl, "AbobiGram/$subfolder")
                dir.mkdirs()
                val dst = File(dir, filename)
                src.copyTo(dst, overwrite = true)
                src.delete()
                // Notifica o MediaScanner para o arquivo aparecer nos gerenciadores
                @Suppress("DEPRECATION")
                sendBroadcast(Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE).apply {
                    data = Uri.fromFile(dst)
                })
                result.success(dst.absolutePath)
            }
        } catch (e: Exception) {
            result.error("SAVE_FAILED", e.message, e.stackTraceToString())
        }
    }
}
