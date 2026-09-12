package com.meteor.kikoeruflutter

import android.content.Intent
import android.util.Log
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI

class MainActivity : AudioServiceActivity() {
    private var floatingLyricPlugin: FloatingLyricPlugin? = null
    private var audioHapticsBridge: AudioHapticsBridge? = null
    private var subtitleDirectoryPicker: SubtitleDirectoryPicker? = null
    private val screenAwakeChannelName = "com.meteor.kikoeruflutter/screen_awake"
    private val systemProxyChannelName = "com.meteor.kikoeruflutter/system_proxy"
    private val appLogsChannelName = "com.meteor.kikoeruflutter/app_logs"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 注册悬浮字幕插件
        floatingLyricPlugin = FloatingLyricPlugin.getInstance(this)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FloatingLyricPlugin.CHANNEL
        )
        floatingLyricPlugin?.attachChannel(channel)
        channel.setMethodCallHandler(floatingLyricPlugin)
        audioHapticsBridge = AudioHapticsBridge(
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger
        )
        subtitleDirectoryPicker = SubtitleDirectoryPicker(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger
        )

        // 应用日志通道：Dart 侧 LogService 转发日志到 Android logcat。
        // release 模式下 Flutter engine 不转发 Dart stdout/stderr，
        // 只能经原生 android.util.Log 输出，才能用 adb logcat 查看。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appLogsChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "writeLog" -> {
                    val level = call.argument<Int>("level") ?: Log.INFO
                    val tag = call.argument<String>("tag") ?: "Kikoeru"
                    val message = call.argument<String>("message") ?: ""
                    Log.println(level, tag, message)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            systemProxyChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSystemProxy" -> result.success(getSystemProxy())
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            screenAwakeChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    runOnUiThread {
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getSystemProxy(): String? {
        val proxySelector = ProxySelector.getDefault() ?: return null
        val urls = listOf(
            URI("https://api.asmr-200.com/"),
            URI("http://api.asmr-200.com/")
        )

        for (url in urls) {
            try {
                val proxy = proxySelector.select(url).firstOrNull {
                    it.type() == Proxy.Type.HTTP
                } ?: continue
                val address = proxy.address() as? InetSocketAddress ?: continue
                return "${address.hostString}:${address.port}"
            } catch (_: Exception) {
                // Try the next URL, then fall back to the legacy JVM properties.
            }
        }

        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if (!host.isNullOrBlank() && !port.isNullOrBlank()) {
            "$host:$port"
        } else {
            null
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (subtitleDirectoryPicker?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        // 不在 Activity 销毁时清理悬浮窗，以便在后台（如侧滑返回桌面）时保持显示
        // floatingLyricPlugin?.cleanup()
        audioHapticsBridge?.dispose()
        audioHapticsBridge = null
        subtitleDirectoryPicker?.dispose()
        subtitleDirectoryPicker = null
        super.onDestroy()
    }
}
