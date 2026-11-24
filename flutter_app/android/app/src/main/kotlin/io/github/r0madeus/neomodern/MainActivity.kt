package io.github.r0madeus.neomodern

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.github.r0madeus.neomodern.audio.AudioBridge

class MainActivity : FlutterActivity() {
    private var audioBridge: AudioBridge? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = AudioBridge(this).also { it.attach() }
        audioBridge = bridge

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        methodChannel = MethodChannel(messenger, AudioBridge.METHOD_CHANNEL).apply {
            setMethodCallHandler(bridge)
        }
        eventChannel = EventChannel(messenger, AudioBridge.EVENT_CHANNEL).apply {
            setStreamHandler(bridge)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        audioBridge?.detach()
        audioBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
