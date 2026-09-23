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
/// - Then at most once per 24h, on every [cadence]-th sticker.
/// - Deferrals never consume a turn. A save that lands inside the
///   throttle window, during a bad moment, or with nothing eligible to
///   ask for leaves the due marker where it is, so the sheet fires on
///   the next happy save instead of being skipped until the next exact
///   multiple.
/// - Review offered at most once per app version.
/// - Self-reported 4-5 stars stops review prompts permanently; 1-3 stars
///   suppresses them for 30 days.
/// - 7-day snooze silences everything; reminders action self-hides when
///   notifications are already granted.
class GrowthService {
  static final InAppReview _review = InAppReview.instance;

  static const _countKey = 'growth_sticker_count';
  static const _nextDueKey = 'growth_next_due_count';
  static const _badMomentUntilMs = 'growth_bad_moment_until_ms';
  static const _lastShownMs = 'growth_sheet_last_shown_ms';
  static const _lastShownAction = 'growth_last_shown_action';
  static const _reviewOfferedVersion = 'growth_review_offered_version';
  static const _reviewHighRating = 'growth_review_high_rating';
  static const _reviewLowRatingUntilMs = 'growth_review_low_rating_until_ms';
  static const _snoozeUntilMs = 'growth_snooze_until_ms';
  static const _shareCount = 'growth_share_count';
  static const _shareWindowStartMs = 'growth_share_window_start_ms';
  static const _widgetsAdded = 'growth_widgets_added';

  static const throttle = Duration(hours: 24);
  static const lowRatingSuppress = Duration(days: 30);

  /// Saves between prompts, after the first-ever one.
  static const cadence = 5;

  /// How long the user gets to enjoy the sticker before we ask for
  /// anything. The landing confetti is the happy beat; this is the pause
  /// that lets it land before the ask.
  static const soak = Duration(seconds: 5);

  /// How long a bad moment keeps the ask away.
  static const badMomentWindow = Duration(minutes: 15);

  /// Marks a moment where an ask would land badly — a paywall just
  /// appeared, or the user is busy deleting. The prompt is deferred, not
  /// consumed: the whole point is that it fires when they are happy
  /// instead.
  static Future<void> noteBadMoment([
    Duration window = badMomentWindow,
  ]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _badMomentUntilMs,
        DateTime.now().millisecondsSinceEpoch + window.inMilliseconds,
      );
    } catch (_) {}
  }

  /// Call after every successful sticker insert.
  ///
  /// Every exit below except the final one is a DEFERRAL, not a skip: the
  /// due marker only moves once the sheet has actually been shown, so a
  /// save that arrives too early is picked up by the next save rather
  /// than silently burning its turn.
  static Future<void> onStickerAdded(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(_countKey) ?? 0) + 1;
    await prefs.setInt(_countKey, count);

    // High-water mark, not a modulo: the moment the 5th save is due it
    // STAYS due until a prompt actually fires.
    final isFirst = count == 1;
    if (!isFirst && count < (prefs.getInt(_nextDueKey) ?? cadence)) {
      debugPrint('[Growth] deferred: not due (count=$count)');
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastShown = prefs.getInt(_lastShownMs) ?? 0;
    // The first sticker ever is never throttled.
    if (!isFirst && now - lastShown < throttle.inMilliseconds) {
      debugPrint('[Growth] deferred: throttle');
      return;
    }
    // A paywall just landed, or they are mid-delete. Wrong moment — stay
    // due and try again on the next save.
    if (now < (prefs.getInt(_badMomentUntilMs) ?? 0)) {
      debugPrint('[Growth] deferred: bad moment');
      return;
    }

    debugPrint('[Growth] due at count=$count, soaking ${soak.inSeconds}s');
    // Let them enjoy what they just made.
    await Future<void>.delayed(soak);
    if (!context.mounted) {
      debugPrint('[Growth] deferred: gallery unmounted');
      return;
    }

    // Only ask on the home screen. The gallery state stays mounted while
    // the preview or any other route is on top of it, so without this
    // the sheet could open over whatever the user is actually looking at.
    final route = ModalRoute.of(context);
    if (!(route?.isCurrent ?? false)) {
      debugPrint(
          '[Growth] deferred: gallery not current (route=${route.runtimeType}, '
          'isCurrent=${route?.isCurrent})');
      return;
    }

    // Nothing left to ask for (snoozed, or every action already
    // satisfied) is not a shown prompt — stay due.
    final eligible = await eligibleActions();
    if (eligible.isEmpty) {
      debugPrint('[Growth] deferred: nothing eligible');
      return;
    }
    final action = await pickNext(eligible);
    if (action == null || !context.mounted) {
      debugPrint('[Growth] deferred: no action picked');
      return;
    }
    debugPrint('[Growth] presenting action=${action.name}');

    final shown =
        await showGrowthPromptSheet(context, action, actions: eligible);
    debugPrint('[Growth] sheet closed, shown=$shown');
    if (!shown) return;

    // Commit only now: throttle from the moment it was really seen, and
    // move the due marker past this save.
    await prefs.setInt(_lastShownMs, DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_nextDueKey, count + cadence);
  }

  /// Eligible carousel pages right now, in display order:
  /// - review: unless self-reported 4-5 stars (store flow shown),
  ///   30-day low-rating suppression, or already offered this version.
  ///   (The API can't confirm an actual Play rating — tapping through
  ///   the store flow counts as rated.)
  /// - reminders: unless notifications already granted.
  /// - widgets: unless the user already pinned them.
  /// - share: always (the sink — something is always eligible).
  static Future<List<GrowthAction>> eligibleActions() async {
    final prefs = await SharedPreferences.getInstance();
    if (await isSnoozed(prefs)) return [];

    final out = <GrowthAction>[];

    final lowUntil = prefs.getInt(_reviewLowRatingUntilMs) ?? 0;
    final reviewAllowed = DateTime.now().millisecondsSinceEpoch > lowUntil &&
        !(prefs.getBool(_reviewHighRating) ?? false);
    if (reviewAllowed) {
      final version = await _currentVersion();
      if (prefs.getString(_reviewOfferedVersion) != version) {
        out.add(GrowthAction.review);
      }
    }

    try {
      if (!await NotificationService.areEnabled()) {
        out.add(GrowthAction.reminders);
      }
    } catch (_) {}

    if (!(prefs.getBool(_widgetsAdded) ?? false)) {
      out.add(GrowthAction.widgets);
    }

    out.add(GrowthAction.share);

    // Carousel display order matches the sheet's canonical order.
    const order = [
      GrowthAction.review,
      GrowthAction.share,
      GrowthAction.widgets,
      GrowthAction.reminders,
    ];
    out.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    return out;
  }

  /// Picks the landing page from [eligible] and advances the cursor:
  /// never repeats the last-shown page while alternatives exist (a
  /// seen-but-dismissed review counts as shown — next time lands on
  /// share). Single eligible page repeats by necessity. Also stamps
  /// the review as offered for this version when picked.
  static Future<GrowthAction?> pickNext(
    List<GrowthAction> eligible,
  ) async {
    if (eligible.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_lastShownAction);
    final pick = eligible.firstWhere(
      (a) => a.name != last,
      orElse: () => eligible.first,
    );
    if (pick == GrowthAction.review) {
      await prefs.setString(
        _reviewOfferedVersion,
        await _currentVersion(),
      );
    }
    await prefs.setString(_lastShownAction, pick.name);
    return pick;
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
  /// list pre-filtered to this app's widgets). Records the prompt so
  /// the widgets card leaves the rotation once asked — but only when
  /// pinning the recents (2x5) widget. Pinning the latest (2x3) widget
  /// from onboarding leaves the card eligible.
  static Future<void> pinWidgets({
    String androidName = 'RecentStickersWidgetProvider',
  }) async {
    try {
      await HomeWidget.requestPinWidget(androidName: androidName);
    } catch (_) {}
    if (androidName != 'RecentStickersWidgetProvider') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_widgetsAdded, true);
    } catch (_) {}
  }
}
