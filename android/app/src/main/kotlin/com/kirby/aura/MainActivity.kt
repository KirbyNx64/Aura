package com.kirby.aura

import android.os.Environment
import android.os.StatFs
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kirby.aura/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getFreeSpace" -> {
                    try {
                        val pathArg: String? = call.argument("path")
                        val target = tryResolvePath(pathArg)
                        val statFs = StatFs(target)
                        val availableBytes = statFs.availableBytes
                        result.success(availableBytes)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "getStorageStats" -> {
                    try {
                        val pathArg: String? = call.argument("path")
                        val target = tryResolvePath(pathArg)
                        val statFs = StatFs(target)
                        val availableBytes = statFs.availableBytes
                        val freeBytes = statFs.freeBytes
                        val totalBytes = statFs.totalBytes
                        val map = HashMap<String, Long>()
                        map["availableBytes"] = availableBytes
                        map["freeBytes"] = freeBytes
                        map["totalBytes"] = totalBytes
                        result.success(map)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun tryResolvePath(pathArg: String?): String {
        // Prefer provided path; if invalid, fall back to its parent; finally to external/data dir
        fun usable(path: String?): String? {
            if (path.isNullOrBlank()) return null
            return try {
                val f = File(path)
                val candidate = if (f.exists()) f else f.parentFile
                candidate?.path
            } catch (_: Exception) {
                null
            }
        }

        return usable(pathArg)
            ?: usable(Environment.getExternalStorageDirectory()?.path)
            ?: Environment.getDataDirectory().path
    }
}
