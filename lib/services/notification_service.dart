import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Daily outfit reminders: 8:00 AM and 10:30 PM, every day. Heading is
/// the app name, subtext the simple ask. Tapping opens the app (default
/// launch behavior for a scheduled notification on the launcher icon).
/// Meowstian's zonedSchedule pattern: cancel + reschedule with
/// matchDateTimeComponents.time for daily recurrence.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _morningId = 1;
  static const _nightId = 2;
  static const _channelId = 'outfit_reminders';

  static Future<void> init() async {
    tz.initializeTimeZones();
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings: initSettings);
  }

  /// Returns true when notifications are allowed (or granted just now).
  static Future<bool> requestPermissions() async {
    final android =
        _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? false;
  }

  /// True when notifications are currently enabled for the app.
  static Future<bool> areEnabled() async {
    final android =
        _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.areNotificationsEnabled() ?? false;
  }

  /// Opens the system settings page for this app (reminders fallback).
  static Future<void> openSettings() async {
    final android =
        _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
  }

  /// (Re)schedules both daily reminders. Safe to call repeatedly.
  static Future<void> scheduleDaily() async {
    await _plugin.cancelAll();
    await _scheduleAt(
      id: _morningId,
      hour: 8,
      minute: 0,
      title: 'StickerPants',
      body: 'add your outfit today',
    );
    await _scheduleAt(
      id: _nightId,
      hour: 22,
      minute: 30,
      title: 'StickerPants',
      body: 'add your outfit today',
    );
  }

  static Future<void> _scheduleAt({
    required int id,
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    final now = tz.TZDateTime.now(tz.local);
    var when = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!when.isAfter(now)) {
      when = when.add(const Duration(days: 1));
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Outfit reminders',
        channelDescription: 'Daily nudges to add your outfit',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: when,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}
