import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'analytics_service.dart';

/// RevenueCat wrapper for StickerPants, ramadan_app RevenueCatService
/// pattern: singleton, idempotent init, cached CustomerInfo with
/// listener fan-out, entitlement check, RevenueCat Paywall sheet with
/// custom-screen fallback, Customer Center, and trial-aware purchase
/// logging.
///
/// Key precedence: --dart-define=REVENUECAT_API_KEY wins, otherwise the
/// bundled test key below. Swap to the production `goog_…` key at
/// release (or via dart-define in CI) — never ship the test key to
/// production: test-store transactions don't transfer to prod.
class RevenueCatService {
  static RevenueCatService? _instance;
  static RevenueCatService get instance => _instance ??= RevenueCatService._();
  RevenueCatService._();

  /// Entitlement created in the RevenueCat dashboard.
  static const String entitlementId = 'StickerPants Pro';

  // Test-store SDK key (public by design — safe to embed, but only
  // for dev builds; production uses the `goog_…` key via dart-define).
  static const String _defaultApiKey = 'test_MzSOYTAJigjHQzYSwxmUuXIgPmY';

  final Set<CustomerInfoUpdateListener> _listeners = {};

  CustomerInfo? _cachedCustomerInfo;
  CustomerInfo? get cachedCustomerInfo => _cachedCustomerInfo;

  bool _initialized = false;
  bool get isInitialized => _initialized;
  bool _initializing = false;

  /// False when the backend rejects our SDK key (401 Invalid API Key).
  /// Native calls are skipped while invalid — paywalls fall back to the
  /// custom screen instead of erroring through the method channel.
  bool _authValid = true;

  void addListener(CustomerInfoUpdateListener listener) {
    _listeners.add(listener);
    final info = _cachedCustomerInfo;
    if (info != null) listener(info);
  }

  void removeListener(CustomerInfoUpdateListener listener) =>
      _listeners.remove(listener);

  Future<void> initialize() async {
    if (_initialized || _initializing) return;
    _initializing = true;
    try {
      final apiKey = const String.fromEnvironment('REVENUECAT_API_KEY');
      final effectiveKey =
          apiKey.isNotEmpty ? apiKey : _defaultApiKey;
      if (effectiveKey.isEmpty) {
        throw StateError('RevenueCat API key missing.');
      }

      await Purchases.setLogLevel(kDebugMode ? LogLevel.debug : LogLevel.warn);
      await Purchases.configure(PurchasesConfiguration(effectiveKey));
      Purchases.addCustomerInfoUpdateListener(_onCustomerInfoUpdated);
      try {
        _cachedCustomerInfo = await Purchases.getCustomerInfo();
      } catch (e) {
        // Invalid key: backend 401s every call. Stay "initialized" so
        // cached/offline reads still work, but flag auth invalid so
        // paywalls skip the native sheet and use the custom fallback.
        if (e.toString().contains('InvalidCredentials')) {
          _authValid = false;
          debugPrint(
              '[RevenueCat] SDK key rejected (401). Check REVENUECAT_API_KEY.');
        }
      }
      _initialized = true;
      debugPrint('[RevenueCat] Initialized (entitlement: $entitlementId)');
    } catch (e) {
      debugPrint('[RevenueCat] Init failed: $e');
    } finally {
      _initializing = false;
    }
  }

  /// Concurrency-safe: waits for an in-flight init instead of skipping.
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    if (_initializing) {
      while (_initializing && !_initialized) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      return;
    }
    await initialize();
  }

  void _onCustomerInfoUpdated(CustomerInfo info) {
    _cachedCustomerInfo = info;
    for (final listener in _listeners) {
      listener(info);
    }
  }

  /// True when the user holds the Pro entitlement.
  bool get isPro =>
      _cachedCustomerInfo?.entitlements.all[entitlementId]?.isActive ?? false;

  /// Listen once: fires immediately with cached state, then on changes.
  Future<void> onProChanged(void Function(bool isPro) callback) async {
    await ensureInitialized();
    void listener(CustomerInfo info) =>
        callback(info.entitlements.all[entitlementId]?.isActive ?? false);
    addListener(listener);
  }

  /// Paywall-triggered purchase of the given package. Returns true on
  /// success/unlock. Logs trial vs paid: a 7-day free trial start logs
  /// `trial_started`, a direct paid activation logs `purchase_completed`.
  Future<bool> purchase(Package package) async {
    try {
      final result = await Purchases.purchase(
        PurchaseParams.package(package),
      );
      final ent =
          result.customerInfo.entitlements.all[entitlementId];
      final active = ent?.isActive ?? false;
      if (active) {
        final id = package.storeProduct.identifier;
        if (ent?.periodType == PeriodType.trial) {
          AnalyticsService.instance.logTrialStarted(productId: id);
        } else {
          AnalyticsService.instance.logPurchaseCompleted(productId: id);
        }
      }
      return active;
    } catch (_) {
      return false;
    }
  }

  /// Restore purchases (paywall footer).
  Future<bool> restore() async {
    try {
      final info = await Purchases.restorePurchases();
      return info.entitlements.all[entitlementId]?.isActive ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Current offering's packages (monthly/yearly) for the paywall.
  /// Empty when offerings aren't configured yet or offline.
  Future<List<Package>> currentPackages() async {
    try {
      await ensureInitialized();
      final offerings = await Purchases.getOfferings();
      return offerings.current?.availablePackages ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Pulls fresh CustomerInfo (belt-and-braces next to the update
  /// listener) so entitlement reads update instantly after purchase.
  Future<void> refreshCustomerInfo() async {
    try {
      await ensureInitialized();
      _cachedCustomerInfo = await Purchases.getCustomerInfo();
    } catch (_) {}
  }

  /// Presents the RevenueCat Paywall sheet for the current offering.
  /// Returns `PaywallResult.error` when the SDK isn't ready or no
  /// dashboard paywall is attached — callers fall back to the custom
  /// paywall screen in that case. `dismissable` controls the close
  /// button (soft placement) vs hard gate (no close button).
  Future<PaywallResult> presentPaywall({required bool dismissable}) async {
    try {
      await ensureInitialized();
      if (!_initialized || !_authValid) return PaywallResult.error;
      if (isPro) return PaywallResult.restored;
      final result = await RevenueCatUI.presentPaywallIfNeeded(
        entitlementId,
        displayCloseButton: dismissable,
      );
      if (result == PaywallResult.purchased ||
          result == PaywallResult.restored) {
        await refreshCustomerInfo();
      }
      return result;
    } catch (e) {
      debugPrint('[RevenueCat] presentPaywall failed: $e');
      return PaywallResult.error;
    }
  }

  static const _playSubsUrl =
      'https://play.google.com/store/account/subscriptions';

  /// Presents the RevenueCat Customer Center (manage subscription,
  /// restore, refund requests — configured on the dashboard). Falls
  /// back to the Play Store subscriptions page when Customer Center
  /// isn't available on this build/dashboard state.
  Future<void> presentCustomerCenter() async {
    try {
      await ensureInitialized();
      if (!_initialized) throw StateError('not initialized');
      await RevenueCatUI.presentCustomerCenter();
    } catch (e) {
      debugPrint('[RevenueCat] Customer Center unavailable: $e');
      final uri = Uri.parse(_playSubsUrl);
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    }
  }

  /// First-launch install stamp (free-sticker counter anchor).
  static Future<void> stampInstall() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey('install_date')) {
      await prefs.setString(
        'install_date',
        DateTime.now().toIso8601String(),
      );
    }
  }
}
