package com.example.audio_visualizer_player

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.audiofx.Visualizer
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.math.sqrt

/** AudioVisualizerPlayerPlugin */
class AudioVisualizerPlayerPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware {
    private val methodChannelName = "audio_visualizer_player/player"
    private val fftEventChannelName = "audio_visualizer_player/fft_bands"

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null
    private var activity: Activity? = null

    private var mediaPlayer: MediaPlayer? = null
    private var visualizer: Visualizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private val tag = "AVP_Plugin"

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, methodChannelName)
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, fftEventChannelName)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "loadAudio" -> {
                val path = call.argument<String>("path")
                val fftSize = call.argument<Int>("fftSize") ?: 1024
                val analysisHz = call.argument<Double>("analysisHz") ?: 30.0
                if (path.isNullOrBlank()) {
                    result.success(-1)
                    return
                }
                result.success(loadAudio(path, fftSize, analysisHz))
            }
            "play" -> {
                mediaPlayer?.start()
                result.success(0)
            }
            "pause" -> {
                mediaPlayer?.pause()
                result.success(0)
            }
            "seekMs" -> {
                val position = call.argument<Int>("positionMs") ?: 0
                mediaPlayer?.seekTo(position)
                result.success(0)
            }
            "getPositionMs" -> result.success(mediaPlayer?.currentPosition ?: 0)
            "getDurationMs" -> result.success(mediaPlayer?.duration ?: 0)
            "isPlaying" -> result.success(if (mediaPlayer?.isPlaying == true) 1 else 0)
            "setVolume" -> {
                val volume = call.argument<Double>("volume")?.toFloat() ?: 1.0f
                mediaPlayer?.setVolume(volume, volume)
                result.success(0)
            }
            "dispose" -> {
                releasePlayer()
                result.success(0)
            }
            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            else -> result.notImplemented()
        }
    }

    private fun loadAudio(path: String, fftSize: Int, analysisHz: Double): Int {
        val currentContext = context ?: return -1
        val micGranted = ContextCompat.checkSelfPermission(
            currentContext,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!micGranted) {
            Log.e(tag, "RECORD_AUDIO permission not granted")
            return -3
        }

        return try {
            releasePlayer()
            mediaPlayer = MediaPlayer().apply {
                setDataSource(path)
                prepare()
                setOnCompletionListener {
                    it.seekTo(0)
                }
            }
            val sessionId = mediaPlayer?.audioSessionId ?: 0
            if (sessionId == 0) {
                Log.e(tag, "Invalid audio session id")
                return -4
            }
            val visRc = setupVisualizer(sessionId, fftSize, analysisHz)
            if (visRc != 0) {
                return visRc
            }
            0
        } catch (e: Exception) {
            Log.e(tag, "Exception in loadAudio path=$path", e)
            releasePlayer()
            -2
        }
    }

    private fun setupVisualizer(audioSessionId: Int, fftSize: Int, analysisHz: Double): Int {
        visualizer?.release()
        return try {
            val v = Visualizer(audioSessionId)
            val range = Visualizer.getCaptureSizeRange()
            val captureSize = chooseCaptureSize(range[0], range[1], fftSize)
            v.captureSize = captureSize
            val targetMilliHz = (analysisHz * 1000.0).toInt()
            val rate = targetMilliHz.coerceIn(1, Visualizer.getMaxCaptureRate())
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(
                    visualizer: Visualizer?,
                    waveform: ByteArray?,
                    samplingRate: Int
                ) = Unit

                override fun onFftDataCapture(
                    visualizer: Visualizer?,
                    fft: ByteArray?,
                    samplingRate: Int
                ) {
                    if (fft == null || fft.isEmpty()) {
                        return
                    }
                    val bins = fftBytesToMagnitudes(fft)
                    activity?.runOnUiThread {
                        eventSink?.success(bins.toList())
                    }
                }
            }, rate, false, true)
            v.enabled = true
            visualizer = v
            0
        } catch (e: Exception) {
            Log.e(tag, "Exception in setupVisualizer session=$audioSessionId", e)
            visualizer?.release()
            visualizer = null
            -6
        }
    }

    private fun chooseCaptureSize(minSize: Int, maxSize: Int, requested: Int): Int {
        var size = minSize
        while (size < requested && size < maxSize) {
            size *= 2
        }
        return size.coerceIn(minSize, maxSize)
    }

    private fun fftBytesToMagnitudes(fft: ByteArray): FloatArray {
        val pairCount = fft.size / 2
        val bins = (pairCount - 1).coerceAtLeast(1)
        val out = FloatArray(bins)
        for (i in 1..bins) {
            val re = fft[2 * i].toFloat()
            val im = fft[(2 * i) + 1].toFloat()
            out[i - 1] = sqrt(re * re + im * im)
        }
        return out
    }

    private fun releasePlayer() {
        try {
            visualizer?.enabled = false
        } catch (_: Exception) {
        }
        visualizer?.release()
        visualizer = null

        mediaPlayer?.release()
        mediaPlayer = null
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        context = null
        releasePlayer()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
