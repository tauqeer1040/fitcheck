package com.taucity.stickerpants

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity): required by the
// RevenueCat native paywall sheet, which presents as a Fragment.
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "stickerpants/whatsapp_stickers"
    private val remindersChannel = "com.taucity.stickerpants/reminders"

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
        // Daily-reminder chain (ramadan pattern): Dart schedules once,
        // native AlarmManager owns perpetual delivery + boot re-seed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, remindersChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "schedule" -> {
                            StickerReminders.schedule(this)
                            result.success(true)
                        }
                        "scheduleOne" -> {
                            val id = (call.argument<Any>("id") as? Number)?.toInt()
                                ?: run {
                                    result.error("BAD_ID", "Missing id", null)
                                    return@setMethodCallHandler
                                }
                            StickerReminders.scheduleOne(this, id)
                            result.success(true)
                        }
                        "cancelOne" -> {
                            val id = (call.argument<Any>("id") as? Number)?.toInt()
                                ?: run {
                                    result.error("BAD_ID", "Missing id", null)
                                    return@setMethodCallHandler
                                }
                            StickerReminders.cancelOne(this, id)
                            result.success(true)
                        }
                        "cancelAll" -> {
                            StickerReminders.cancelAll(this)
                            result.success(true)
                        }
                        "scheduledIds" -> {
                            result.success(StickerReminders.scheduledIds(this))
                        }
                        "fireTestSequence" -> {
                            StickerReminders.scheduleTests(
                                this,
                                call.argument<String>("title")
                                    ?: "Test 0/3 - immediate",
                                call.argument<String>("body")
                                    ?: "Native display works. 3 alarms follow at +10/20/30s.",
                            )
                            result.success(true)
                        }
                        "showNow" -> {
                            val isMorning = call.argument<Boolean>("isMorning") == true
                            val dedupe = call.argument<Boolean>("dedupe") == true
                            result.success(
                                StickerReminders.show(
                                    this,
                                    if (isMorning) StickerReminders.MORNING_ID
                                    else StickerReminders.NIGHT_ID,
                                    StickerReminders.FALLBACK_TITLE,
                                    StickerReminders.FALLBACK_BODY,
                                    dedupe,
                                ),
                            )
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("REMINDERS_FAILED", e.message, null)
                }
            }
    }
}
