package com.taucity.stickerpants

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import java.util.Calendar

/**
 * StickerPants daily-reminder chain (ramadan pattern, inline):
 *
 *  1. Dart calls schedule/scheduleOne once (app foreground) via the
 *     MainActivity method channel.
 *  2. AlarmManager fires [ReminderReceiver] at the wall-clock time —
 *     inexact allow-while-idle (no SCHEDULE_EXACT_ALARM needed; fires
 *     within seconds-to-minutes even in Doze).
 *  3. The receiver shows the notification and RE-ARMS ITSELF for the
 *     next day. The chain never depends on the Flutter engine or the
 *     app process.
 *  4. [ReminderBootReceiver] re-seeds flagged reminders after reboot /
 *     app update.
 *
 * Consent-safe: per-reminder scheduled flags (default false) live in
 * native prefs. Boot only reseeds flagged ones, so a user who never
 * opted in (or toggled one off) stays silent.
 *
 * Notifications are text-only. Tap launches the app via its launcher
 * intent. Channel is HIGH importance (heads-up while unlocked).
 */
object StickerReminders {
    const val ACTION_FIRE = "com.taucity.stickerpants.FIRE"
    const val EXTRA_ID = "id"
    const val EXTRA_TITLE = "title"
    const val EXTRA_BODY = "body"

    const val PREFS = "stickerpants_reminders"
    const val MORNING_ID = 101
    const val NIGHT_ID = 102
    private const val TEST_BASE_ID = 9000

    private const val KEY_SCHED_MORNING = "sched_morning"
    private const val KEY_SCHED_NIGHT = "sched_night"
    private const val KEY_LAST_MORNING = "lastShownMorning"
    private const val KEY_LAST_NIGHT = "lastShownNight"

    const val FALLBACK_TITLE = "StickerPants"
    const val FALLBACK_BODY = "Add your outfit today"

    private const val MORNING_HOUR = 8
    private const val MORNING_MINUTE = 0
    private const val NIGHT_HOUR = 22
    private const val NIGHT_MINUTE = 30

    private const val CHANNEL_ID = "stickerpants_reminders"
    private val LEGACY_CHANNEL_IDS = arrayOf("outfit_reminders")

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ── API (called from the MainActivity method channel) ──

    fun schedule(context: Context) {
        prefs(context).edit()
            .putBoolean(KEY_SCHED_MORNING, true)
            .putBoolean(KEY_SCHED_NIGHT, true)
            .apply()
        scheduleAll(context)
    }

    fun scheduleOne(context: Context, id: Int) {
        val p = prefs(context)
        if (id == MORNING_ID) {
            p.edit().putBoolean(KEY_SCHED_MORNING, true).apply()
            schedule(context, MORNING_ID, MORNING_HOUR, MORNING_MINUTE)
        } else if (id == NIGHT_ID) {
            p.edit().putBoolean(KEY_SCHED_NIGHT, true).apply()
            schedule(context, NIGHT_ID, NIGHT_HOUR, NIGHT_MINUTE)
        }
    }

    fun cancelOne(context: Context, id: Int) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(firePendingIntent(context, id, null))
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(id)
        val p = prefs(context)
        if (id == MORNING_ID) {
            p.edit().putBoolean(KEY_SCHED_MORNING, false).apply()
        } else if (id == NIGHT_ID) {
            p.edit().putBoolean(KEY_SCHED_NIGHT, false).apply()
        }
    }

    fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (id in intArrayOf(MORNING_ID, NIGHT_ID)) {
            am.cancel(firePendingIntent(context, id, null))
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(MORNING_ID)
        nm.cancel(NIGHT_ID)
        prefs(context).edit()
            .putBoolean(KEY_SCHED_MORNING, false)
            .putBoolean(KEY_SCHED_NIGHT, false)
            .apply()
    }

    fun scheduledIds(context: Context): List<Int> {
        val p = prefs(context)
        val out = ArrayList<Int>(2)
        if (p.getBoolean(KEY_SCHED_MORNING, false)) out.add(MORNING_ID)
        if (p.getBoolean(KEY_SCHED_NIGHT, false)) out.add(NIGHT_ID)
        return out
    }

    /// Debug proof sequence: immediate notification + 3 one-off alarms
    /// at +10/20/30s. If the immediate one shows but the alarms don't,
    /// the OS/OEM is blocking alarms (battery optimization), not code.
    fun scheduleTests(context: Context, title: String, body: String) {
        show(context, TEST_BASE_ID, title, body)
        for (i in 1..3) {
            val pi = firePendingIntent(
                context, TEST_BASE_ID + i,
                mapOf(
                    EXTRA_TITLE to "Test $i/3",
                    EXTRA_BODY to "Native alarm fired at +${10 * i}s.",
                ),
            )
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            scheduleWithPolicy(am, System.currentTimeMillis() + 10_000L * i, pi)
        }
    }

    // ── Internals ──

    fun scheduleAll(context: Context) {
        val p = prefs(context)
        if (p.getBoolean(KEY_SCHED_MORNING, false)) {
            schedule(context, MORNING_ID, MORNING_HOUR, MORNING_MINUTE)
        }
        if (p.getBoolean(KEY_SCHED_NIGHT, false)) {
            schedule(context, NIGHT_ID, NIGHT_HOUR, NIGHT_MINUTE)
        }
    }

    private fun schedule(context: Context, id: Int, hour: Int, minute: Int) {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (cal.timeInMillis <= System.currentTimeMillis()) cal.add(Calendar.DAY_OF_YEAR, 1)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        scheduleWithPolicy(am, cal.timeInMillis, firePendingIntent(context, id, null))
    }

    private fun firePendingIntent(context: Context, id: Int, extras: Map<String, String>?): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java)
            .setAction(ACTION_FIRE)
            .putExtra(EXTRA_ID, id)
        extras?.forEach { (k, v) -> intent.putExtra(k, v) }
        return PendingIntent.getBroadcast(
            context, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// Inexact allow-while-idle: needs NO special permission, fires
    /// within the OS idle window even in Doze. A few minutes of drift
    /// is fine for daily reminders.
    fun scheduleWithPolicy(am: AlarmManager, atMs: Long, pi: PendingIntent) {
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pi)
    }

    fun show(context: Context, id: Int, title: String, body: String, dedupe: Boolean = false): Boolean {
        val isReminder = id == MORNING_ID || id == NIGHT_ID
        val isMorning = id == MORNING_ID
        if (dedupe && isReminder && wasAlreadyShownToday(context, isMorning)) return false

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ensureChannel(nm)
        }
        // White pants silhouette (alpha-only, like ramadan's cat):
        // the status bar renders it perfectly, unlike full-color art.
        // Direct reference (NOT getIdentifier): string lookups are
        // invisible to the resource shrinker, which stripped the icon
        // from release builds and silently fell back to the launcher
        // icon the OS masks into a circle.
        val smallIconId = R.drawable.ic_notification

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(smallIconId)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(launchAppIntent(context, id))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(NotificationCompat.PRIORITY_HIGH)
        }
        nm.notify(id, builder.build())
        if (dedupe && isReminder) markShownToday(context, isMorning)
        return true
    }

    private fun wasAlreadyShownToday(context: Context, isMorning: Boolean): Boolean {
        val key = if (isMorning) KEY_LAST_MORNING else KEY_LAST_NIGHT
        return prefs(context).getString(key, null) == todayKey()
    }

    private fun markShownToday(context: Context, isMorning: Boolean) {
        val key = if (isMorning) KEY_LAST_MORNING else KEY_LAST_NIGHT
        prefs(context).edit().putString(key, todayKey()).apply()
    }

    private fun todayKey(c: Calendar = Calendar.getInstance()): String {
        val m = c.get(Calendar.MONTH) + 1
        val d = c.get(Calendar.DAY_OF_MONTH)
        return "${c.get(Calendar.YEAR)}-${if (m < 10) "0$m" else m}-${if (d < 10) "0$d" else d}"
    }

    private fun ensureChannel(nm: NotificationManager) {
        for (legacy in LEGACY_CHANNEL_IDS) {
            nm.deleteNotificationChannel(legacy)
        }
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Outfit reminders", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Daily nudges to add your outfit"
            },
        )
    }

    private fun launchAppIntent(context: Context, id: Int): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context, id, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// Self-re-arm: tomorrow at the given wall-clock time.
    fun rearmNext(context: Context, id: Int, hour: Int, minute: Int) {
        val cal = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        scheduleWithPolicy(am, cal.timeInMillis, firePendingIntent(context, id, null))
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            val id = intent.getIntExtra(StickerReminders.EXTRA_ID, StickerReminders.MORNING_ID)
            val testTitle = intent.getStringExtra(StickerReminders.EXTRA_TITLE)

            if (testTitle != null) {
                // Debug one-off: show and stop (no re-arm, no dedupe).
                StickerReminders.show(
                    context, id, testTitle,
                    intent.getStringExtra(StickerReminders.EXTRA_BODY) ?: "",
                )
                return
            }

            if (id == StickerReminders.MORNING_ID) {
                StickerReminders.show(
                    context, id,
                    StickerReminders.FALLBACK_TITLE,
                    StickerReminders.FALLBACK_BODY,
                    dedupe = true,
                )
                StickerReminders.rearmNext(context, id, 8, 0)
            } else {
                StickerReminders.show(
                    context, id,
                    StickerReminders.FALLBACK_TITLE,
                    StickerReminders.FALLBACK_BODY,
                    dedupe = true,
                )
                StickerReminders.rearmNext(context, id, 22, 30)
            }
        } catch (e: Exception) {
            android.util.Log.w("StickerReminders", "reminder failed: ${e.message}")
        }
    }
}

class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            StickerReminders.scheduleAll(context)
        }
    }
}
