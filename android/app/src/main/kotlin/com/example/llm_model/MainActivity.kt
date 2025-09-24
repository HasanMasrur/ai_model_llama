package com.example.llm_model

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "llama/native")
            .setMethodCallHandler { call, result ->
                if (call.method == "isAlive") {
                    try {
                        result.success(NativeBridge.isAlive())
                    } catch (e: Throwable) {
                        result.error("JNI_ERR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
