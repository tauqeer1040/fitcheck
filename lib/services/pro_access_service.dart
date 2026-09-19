import 'package:shared_preferences/shared_preferences.dart';

import 'revenuecat_service.dart';

/// Free-tier gate for StickerPants: 30 free stickers, then the paywall.
/// Counts every saved sticker (free or Pro) for the paywall stats line.
/// Pro status always comes from RevenueCat — this service never caches it.
class ProAccessService {
  static const int freeStickerLimit = 30;

  static const String _freeCountKey = 'free_sticker_count';
  static const String _totalMadeKey = 'total_stickers_made';
  static const String _onboardingPaywallKey = 'paywall_shown_onboarding_v1';

  /// Stickers saved while NOT Pro. Frozen once the user subscribes.
  static Future<int> freeUsed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_freeCountKey) ?? 0;
  }

  /// Every sticker ever saved (free + Pro) — the paywall stats line.
  static Future<int> totalMade() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_totalMadeKey) ?? 0;
  }

  static Future<int> freeLeft() async =>
      (freeStickerLimit - await freeUsed()).clamp(0, freeStickerLimit);

  /// True when the user may create another sticker without paying.
  static Future<bool> canCreateFree() async {
    if (RevenueCatService.instance.isPro) return true;
    return (await freeUsed()) < freeStickerLimit;
  }

  /// Record a saved sticker. Call on every save; free quota only
  /// advances for non-Pro users.
  static Future<void> recordStickerSaved() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_totalMadeKey, (prefs.getInt(_totalMadeKey) ?? 0) + 1);
    if (!RevenueCatService.instance.isPro) {
      await prefs.setInt(
          _freeCountKey, (prefs.getInt(_freeCountKey) ?? 0) + 1);
    }
  }

  /// One-shot soft paywall after onboarding (postponed until first
  /// gallery entry). Returns true if it still needs showing.
  static Future<bool> consumeOnboardingPaywall() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_onboardingPaywallKey) ?? false) return false;
    await prefs.setBool(_onboardingPaywallKey, true);
    return true;
  }
}
