import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/growth_prompt_sheet.dart';
import 'notification_service.dart';

/// Growth-prompt policy + helpers, ramadan GrowthPromptService pattern.
/// Prompts (never user-initiated taps) are throttled here; the sheet only
/// renders whatever single action this service picked.
///
/// Policy:
/// - First sticker ever always shows the sheet (unless high-rated/snoozed).
/// - Then at most once per 24h, on every 5th sticker.
/// - Review offered at most once per app version.
/// - Self-reported 4-5 stars stops review prompts permanently; 1-3 stars
///   suppresses them for 30 days.
/// - 7-day snooze silences everything; reminders action self-hides when
///   notifications are already granted.
class GrowthService {
  static final InAppReview _review = InAppReview.instance;

  static const _countKey = 'growth_sticker_count';
  static const _lastShownMs = 'growth_sheet_last_shown_ms';
  static const _nextAction = 'growth_next_action';
  static const _reviewOfferedVersion = 'growth_review_offered_version';
  static const _reviewHighRating = 'growth_review_high_rating';
  static const _reviewLowRatingUntilMs = 'growth_review_low_rating_until_ms';
  static const _snoozeUntilMs = 'growth_snooze_until_ms';
  static const _shareCount = 'growth_share_count';
  static const _shareWindowStartMs = 'growth_share_window_start_ms';

  static const throttle = Duration(hours: 24);
  static const lowRatingSuppress = Duration(days: 30);

  /// Call after every successful sticker insert. Waits 5s, then decides
  /// whether today's save earns a prompt sheet (first ever, or every 5th
  /// save past the throttle window). Persists the count.
  static Future<void> onStickerAdded(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(_countKey) ?? 0) + 1;
    await prefs.setInt(_countKey, count);

    final isFirst = count == 1;
    final isFifth = count % 5 == 0;
    if (!isFirst && !isFifth) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastShown = prefs.getInt(_lastShownMs) ?? 0;
    if (!isFirst && now - lastShown < throttle.inMilliseconds) return;

    // Stamp the throttle before the 5s soak so no async gap separates
    // the final mounted check from the sheet call.
    await prefs.setInt(_lastShownMs, now);

    // Let the user enjoy their new sticker for 5 seconds first.
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!context.mounted) return;
    final sheetContext = context;

    final action = await _pickAction(prefs, isFirst);
    if (action == null) return;
    if (!sheetContext.mounted) return;

    await showGrowthPromptSheet(sheetContext, action);
  }

  /// Rotation: reminders first (the app's core loop needs the permission),
  /// then share, then widgets; review only when this version hasn't been
  /// asked, the user hasn't self-reported 4-5 stars, and no 30-day
  /// low-rating suppression is active. Actions that render as no-ops are
  /// skipped.
  static Future<GrowthAction?> _pickAction(
    SharedPreferences prefs,
    bool isFirst,
  ) async {
    if (await isSnoozed(prefs)) return null;

    final lowUntil = prefs.getInt(_reviewLowRatingUntilMs) ?? 0;
    final reviewAllowed = DateTime.now().millisecondsSinceEpoch > lowUntil &&
        !(prefs.getBool(_reviewHighRating) ?? false);

    // Sticky pick: reuse the queued action across eligible saves so each
    // gets a fair turn before rotation advances.
    final next = prefs.getString(_nextAction);
    if (next != null) {
      final queued = GrowthAction.values
          .where((a) => a.name == next)
          .cast<GrowthAction?>()
          .firstOrNull;
      if (queued != null && !(queued == GrowthAction.review && !reviewAllowed)) {
        await prefs.remove(_nextAction);
        return queued;
      }
    }

    // Reminders first if not yet granted (self-hides if granted).
    if (isFirst) {
      try {
        if (!await NotificationService.areEnabled()) {
          return GrowthAction.reminders;
        }
      } catch (_) {}
    }

    // Review gate.
    if (reviewAllowed) {
      final version = await _currentVersion();
      final offered = prefs.getString(_reviewOfferedVersion);
      if (offered != version) {
        await prefs.setString(_reviewOfferedVersion, version);
        return GrowthAction.review;
      }
    }

    // Share / widgets rotate.
    final last = prefs.getString('growth_last_rotating');
    if (last == GrowthAction.share.name) {
      await prefs.setString('growth_last_rotating', GrowthAction.widgets.name);
      return GrowthAction.widgets;
    }
    await prefs.setString('growth_last_rotating', GrowthAction.share.name);
    return GrowthAction.share;
  }

  static Future<bool> isSnoozed([SharedPreferences? provided]) async {
    final prefs = provided ?? await SharedPreferences.getInstance();
    return DateTime.now().millisecondsSinceEpoch <
        (prefs.getInt(_snoozeUntilMs) ?? 0);
  }

  static Future<void> snooze({int days = 7}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _snoozeUntilMs,
      DateTime.now().millisecondsSinceEpoch +
          Duration(days: days).inMilliseconds,
    );
  }

  static Future<void> recordHighRating() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reviewHighRating, true);
  }

  static Future<void> recordLowRating() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _reviewLowRatingUntilMs,
      DateTime.now().millisecondsSinceEpoch +
          lowRatingSuppress.inMilliseconds,
    );
  }

  static Future<void> recordShare() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = prefs.getInt(_shareWindowStartMs) ?? 0;
    final count = (prefs.getInt(_shareCount) ?? 0) + 1;
    if (now - start > const Duration(days: 7).inMilliseconds) {
      await prefs.setInt(_shareWindowStartMs, now);
      await prefs.setInt(_shareCount, 1);
    } else {
      await prefs.setInt(_shareCount, count);
    }
  }

  static Future<String> _currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Native Play Store review dialog. No-op if unavailable (side-load).
  static Future<void> requestReview() async {
    try {
      if (await _review.isAvailable()) await _review.requestReview();
    } catch (_) {}
  }

  /// Guides the user to the widget picker (Android 8+ opens the widget
  /// list pre-filtered to this app's widgets).
  static Future<void> pinWidgets() async {
    try {
      await HomeWidget.requestPinWidget(
        androidName: 'RecentStickersWidgetProvider',
      );
    } catch (_) {}
  }
}
