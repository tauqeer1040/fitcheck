import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Firebase Analytics for StickerPants: singleton with named funnel
/// methods so call sites stay readable.
///
/// Event naming rule: APP events are plain (`app_opened`,
/// `paywall_shown`, `sticker_saved`). WEB (landing page) events are
/// prefixed `web_` and live in the Astro site (`sites/stickerpants`),
/// so funnels split app vs web by name alone.
///
/// Requires the Firebase project + `android/app/google-services.json`.
/// Until those land, every call is a safe no-op (debug-logged).
class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._();
  static AnalyticsService get instance => _instance;
  AnalyticsService._();

  FirebaseAnalytics? _analytics;
  bool _unavailable = false;

  /// Call once at startup (fire-and-forget safe).
  Future<void> initialize() async {
    if (_analytics != null || _unavailable) return;
    try {
      await Firebase.initializeApp();
      _analytics = FirebaseAnalytics.instance;
      debugPrint('[Analytics] Firebase ready.');
    } catch (e) {
      _unavailable = true;
      debugPrint('[Analytics] Firebase missing — events logged only: $e');
    }
  }

  FirebaseAnalytics? get _a {
    if (_unavailable) return null;
    try {
      return _analytics ?? FirebaseAnalytics.instance;
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  void _safe(String name, [Map<String, Object>? params]) {
    if (kDebugMode) {
      debugPrint('[Analytics] $name ${params ?? ''}');
    }
    _a?.logEvent(name: name, parameters: params).catchError((_) {});
  }

  // ---- lifecycle ----
  void logAppOpen() => _safe('app_opened');

  // ---- onboarding funnel ----
  void logOnboardingStarted() => _safe('onboarding_started');
  void logOnboardingStep({required String page, required int index}) =>
      _safe('onboarding_step', {'page': page, 'index': index});
  void logOnboardingCompleted({int? timeToCompleteMs}) {
    final params = <String, Object>{};
    if (timeToCompleteMs != null) params['duration_ms'] = timeToCompleteMs;
    _safe('onboarding_completed', params);
  }
  void logNotificationPermission({required bool granted}) =>
      _safe('notification_permission_result', {'granted': granted});

  // ---- core loop funnel ----
  void logFirstCutStarted() => _safe('first_cut_started');
  void logFirstCutSucceeded({int? timeToFirstStickerMs}) {
    final params = <String, Object>{};
    if (timeToFirstStickerMs != null) {
      params['time_to_first_sticker_ms'] = timeToFirstStickerMs;
    }
    _safe('first_cut_succeeded', params);
  }
  void logFirstCutFailed() => _safe('first_cut_failed');

  /// Every save counts with the running total — average stickers per
  /// user falls out in the console (avg of `total_stickers`).
  void logStickerSaved({required int totalStickers}) =>
      _safe('sticker_saved', {'total_stickers': totalStickers});
  void logWhatsAppPackAdded({required bool success}) =>
      _safe('whatsapp_pack_added', {'success': success});
  void logWidgetPinned() => _safe('widget_pinned');
  void logShareInvoked() => _safe('share_invoked');

  // ---- monetization ----
  void logPaywallShown({required String placement}) =>
      _safe('paywall_shown', {'placement': placement});
  void logPaywallDismissed({required String placement}) =>
      _safe('paywall_dismissed', {'placement': placement});
  void logTrialStarted({String? productId}) {
    final params = <String, Object>{};
    if (productId != null) params['product_id'] = productId;
    _safe('trial_started', params);
  }
  void logPurchaseCompleted({String? productId}) {
    final params = <String, Object>{};
    if (productId != null) params['product_id'] = productId;
    _safe('purchase_completed', params);
  }
  void logMaxThankYouShown({required bool restored}) =>
      _safe('max_thankyou_shown', {'restored': restored});
}
