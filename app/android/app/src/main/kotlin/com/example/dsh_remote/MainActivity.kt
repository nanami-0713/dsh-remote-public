package com.example.dsh_remote

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "dshremote/deeplink"
    }

    private fun linkChannel(engine: FlutterEngine): MethodChannel =
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)

    private fun broadcastLink(link: String?) {
        if (link == null) return
        flutterEngine?.let { engine ->
            linkChannel(engine).invokeMethod("onDeepLink", link)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        linkChannel(flutterEngine).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> result.success(intent?.dataString)
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        broadcastLink(intent.dataString)
    }
}
