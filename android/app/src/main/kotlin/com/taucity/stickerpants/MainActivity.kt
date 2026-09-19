package com.taucity.stickerpants

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "stickerpants/whatsapp_stickers"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "addPackToWhatsApp" -> {
                        val paths = call.argument<List<String>>("paths")
                        if (paths.isNullOrEmpty()) {
                            result.error("NO_STICKERS", "No sticker paths given", null)
                            return@setMethodCallHandler
                        }
                        // Result is delivered before launching the intent so
                        // Dart can dismiss any spinner; WhatsApp takes over UI.
                        WhatsAppPackManager.addToWhatsApp(this, paths)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
