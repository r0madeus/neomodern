package io.github.r0madeus.neomodern

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.zxing.integration.android.IntentIntegrator
import com.journeyapps.barcodescanner.CaptureActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.r0madeus.neomodern.audio.AudioBridge

class MainActivity : FlutterActivity() {
    private var audioBridge: AudioBridge? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var platformChannel: MethodChannel? = null

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingQrResult: MethodChannel.Result? = null

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
        platformChannel = MethodChannel(messenger, PLATFORM_CHANNEL).apply {
            setMethodCallHandler(::onPlatformMethodCall)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        platformChannel?.setMethodCallHandler(null)
        platformChannel = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        audioBridge?.detach()
        audioBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun onPlatformMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkAudioPermission" -> result.success(hasAudioPermission())

            "requestAudioPermission" -> {
                if (hasAudioPermission()) {
                    result.success(true)
                    return
                }
                if (pendingPermissionResult != null) {
                    result.error(
                        "PERMISSION_IN_PROGRESS",
                        "Audio permission request already in progress",
                        null,
                    )
                    return
                }
                pendingPermissionResult = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(audioPermissionName()),
                    REQUEST_AUDIO_PERMISSION,
                )
            }

            "scanQrCode" -> {
                if (pendingQrResult != null) {
                    result.error(
                        "SCAN_IN_PROGRESS",
                        "QR code scan already in progress",
                        null,
                    )
                    return
                }
                pendingQrResult = result
                try {
                    @Suppress("DEPRECATION")
                    IntentIntegrator(this).apply {
                        setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
                        setPrompt("Scan pairing or party QR code")
                        setBeepEnabled(false)
                        setOrientationLocked(false)
                        setCaptureActivity(CaptureActivity::class.java)
                    }.initiateScan()
                } catch (e: Exception) {
                    pendingQrResult = null
                    result.error(
                        "SCAN_FAILED",
                        e.message ?: "Failed to launch QR scanner",
                        null,
                    )
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun audioPermissionName(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun hasAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            audioPermissionName(),
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_AUDIO_PERMISSION) {
            val pending = pendingPermissionResult
            pendingPermissionResult = null
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pending?.success(granted || hasAudioPermission())
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val scanResult = IntentIntegrator.parseActivityResult(requestCode, resultCode, data)
        if (scanResult != null) {
            val pending = pendingQrResult
            pendingQrResult = null
            pending?.success(scanResult.contents)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        const val PLATFORM_CHANNEL = "io.github.r0madeus.neomodern/platform"
        private const val REQUEST_AUDIO_PERMISSION = 4101
    }
}
