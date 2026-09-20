import 'package:flutter/material.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/paywall_screen.dart';
import 'analytics_service.dart';
import 'pro_access_service.dart';
import 'revenuecat_service.dart';

/// Ramadan-style moment gate for StickerPants: fires the RevenueCat
/// paywall sheet directly (no intermediate gate screen) at conversion
/// moments, with the custom paywall screen as fallback when no dashboard
/// template is attached yet.
///
/// Dismissability follows the free quota, not a clock:
/// - inside quota → no paywall at all (free sticker).
/// - onboarding placement → soft sheet (close button).
/// - create-gate (quota exhausted) → hard sheet (no close button).
/// Frequency-capped per placement so it never nags more than once
/// per window.
class MomentPaywallService {
  static const Duration _minGap = Duration(minutes: 30);
  static const String _lastShownKey = 'moment_paywall_last_';

  /// Returns true when the user unlocked Pro (or already had it).
  /// Returns false when dismissed / quota remains / purchase failed.
  ///
  /// [force] bypasses the quota and frequency-cap checks (explicit
  /// user taps like the appbar Pro button). Gated placements
  /// (create-gate) pass locked:true; soft placements locked:false.
  static Future<bool> maybeShow(
    BuildContext context, {
    required String placement,
    required bool locked,
    bool force = false,
  }) async {
    try {
      debugPrint('[Paywall] tap placement=$placement locked=$locked force=$force');
      await RevenueCatService.instance.ensureInitialized();
      final isPro = RevenueCatService.instance.isPro;
      debugPrint('[Paywall] isPro=$isPro');
      if (isPro) return true;

      // Inside free quota and not forced: nothing to show.
      if (!force) {
        final left = await ProAccessService.freeLeft();
        debugPrint('[Paywall] freeLeft=$left');
        if (!locked && left > 0) {
          debugPrint('[Paywall] suppressed: inside free quota');
          return false;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final key = '$_lastShownKey$placement';
      final last = prefs.getInt(key) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      // The hard create-gate and forced taps always fire; soft
      // placements respect the frequency cap.
      if (!locked && !force && now - last < _minGap.inMilliseconds) {
        debugPrint('[Paywall] suppressed: frequency cap');
        return false;
      }
      await prefs.setInt(key, now);

      AnalyticsService.instance.logPaywallShown(placement: placement);
      debugPrint('[Paywall] presenting native sheet...');
      final result = await RevenueCatService.instance.presentPaywall(
        dismissable: !locked,
      );
      debugPrint('[Paywall] native result=$result');
      if (result == PaywallResult.purchased ||
          result == PaywallResult.restored) {
        await RevenueCatService.instance.refreshCustomerInfo();
        return true;
      }
      if (result == PaywallResult.cancelled) {
        AnalyticsService.instance.logPaywallDismissed(placement: placement);
        return false;
      }
      // Error / no dashboard template → custom fallback screen.
      if (!context.mounted) return false;
      return await PaywallScreen.showCustom(
        context,
        locked: locked,
        placement: placement,
      );
    } catch (_) {
      return false;
    }
  }
}
