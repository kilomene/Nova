package com.nova.app

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nova.app/voice_recorder"
    private var recorder: MediaRecorder? = null
    private var outputFile: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                        != PackageManager.PERMISSION_GRANTED) {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 1001)
                        result.error("PERMISSION_DENIED", "Microphone permission not granted", null)
                        return@setMethodCallHandler
                    }
                    startRecording(result)
                }
                "stopRecording" -> stopRecording(result)
                "isRecording" -> result.success(recorder != null)
                else -> result.notImplemented()
            }
        }
    }

    private fun startRecording(result: MethodChannel.Result) {
        try {
            val dir = File(cacheDir, "voice_messages")
            if (!dir.exists()) dir.mkdirs()
            outputFile = File(dir, "vm_${System.currentTimeMillis()}.m4a").absolutePath

            recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(44100)
                setAudioChannels(1)
                setOutputFile(outputFile)
                prepare()
                start()
            }
            result.success(outputFile)
        } catch (e: IOException) {
            result.error("RECORD_FAILED", e.message, null)
        } catch (e: IllegalStateException) {
            result.error("RECORD_FAILED", e.message, null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        try {
            recorder?.apply {
                stop()
                release()
            }
            recorder = null
            result.success(outputFile)
        } catch (e: Exception) {
            recorder = null
            result.error("STOP_FAILED", e.message, null)
        }
    }

    override fun onDestroy() {
        recorder?.release()
        recorder = null
        super.onDestroy()
    }
}
