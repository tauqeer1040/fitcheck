import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;

/// Daily outfit reminders: 8:00 AM and 10:30 PM, every day. Heading is
/// the app name, subtext the simple ask. Tapping opens the app (default
/// launch behavior for a scheduled notification on the launcher icon).
///
/// Delivery is the native alarm chain (ramadan pattern): Dart schedules
/// once over the MainActivity method channel; AlarmManager owns
/// perpetual delivery (self-re-arming receiver) + boot re-seed, all
/// inexact allow-while-idle — no exact-alarm permission, reboot-safe.
/// flutter_local_notifications stays for permission checks only.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const MethodChannel _channel =
      MethodChannel('com.taucity.stickerpants/reminders');

  /// Mirror the native ids (StickerReminders.MORNING_ID/NIGHT_ID).
  static const morningId = 101;
  static const nightId = 102;

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

  /// Ids with a currently-scheduled chain (native flags; survives
  /// reboot by design). Debug toggles read this.
  static Future<Set<int>> pendingIds() async {
    try {
      final ids = await _channel.invokeMethod<List>('scheduledIds');
      return (ids ?? const []).map((e) => (e as num).toInt()).toSet();
    } on MissingPluginException {
      return {};
    } on PlatformException {
      return {};
    } catch (_) {
      return {};
    }
  }

  /// Fire a notification RIGHT NOW (debug card): proves display +
  /// permission + channel end-to-end without waiting for a wall-clock
  /// slot. Uses the morning/night copy by type.
  static Future<void> fireNow(String type) async {
    try {
      await _channel.invokeMethod<bool>('showNow', {
        'isMorning': type == 'morning',
        'dedupe': false,
      });
    } on MissingPluginException {
    } on PlatformException {
    } catch (_) {}
  }

  /// Debug proof sequence: immediate notification + 3 one-off native
  /// alarms at +10/20/30s. If the immediate one shows but the alarms
  /// don't, the OS/OEM is blocking alarms (battery optimization).
  static Future<void> fireTestSequence() async {
    try {
      await _channel.invokeMethod<bool>('fireTestSequence', {
        'title': 'Test 0/3 - immediate',
        'body': 'Native display works. 3 alarms follow at +10/20/30s.',
      });
    } on MissingPluginException {
    } on PlatformException {
    } catch (_) {}
  }

  /// Cancel one reminder by id (debug toggles).
  static Future<void> cancelOne(int id) async {
    try {
      await _channel.invokeMethod<bool>('cancelOne', {'id': id});
    } on MissingPluginException {
    } on PlatformException {
    } catch (_) {}
  }

  /// (Re)schedules both daily reminders. Safe to call repeatedly:
  /// alarms are FLAG_UPDATE_CURRENT, so this converges to exactly one
  /// pending chain per reminder.
  static Future<void> scheduleDaily() async {
    try {
      await _channel.invokeMethod<bool>('schedule');
    } on MissingPluginException {
    } on PlatformException {
    } catch (_) {}
  }

  /// Morning ping alone (8:00 daily). Safe to call repeatedly.
  static Future<void> scheduleMorning() async {
    try {
      await _channel.invokeMethod<bool>('scheduleOne', {'id': morningId});
    } on MissingPluginException {
    } on PlatformException {
    } catch (_) {}
  }

  /// Night ping alone (22:30 daily). Safe to call repeatedly.
  static Future<void> scheduleNight() async {
    try {
      await _channel.invokeMethod<bool>('scheduleOne', {'id': nightId});
    } on MissingPluginException {
    } on PlatformException {
    } catch (_) {}
  }
}
