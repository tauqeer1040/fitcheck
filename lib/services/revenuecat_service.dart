import 'dart:async';

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

  // Production Google Play SDK key (public by design — safe to embed).
  // StickerPants project (proj44611bfa), StickerPants Android app.
  // Override with --dart-define=REVENUECAT_API_KEY=<test key> for
  // Test Store runs.
  static const String _defaultApiKey = 'goog_UcttPKNTtNqMWYzGpeNfMxjtxuw';

  final Set<CustomerInfoUpdateListener> _listeners = {};

  CustomerInfo? _cachedCustomerInfo;
  CustomerInfo? get cachedCustomerInfo => _cachedCustomerInfo;

  /// Last DEFINITIVE Pro state, persisted. CustomerInfo reads can come
  /// back empty (offline launch, slow network) even for subscribers —
  /// without this the Max wordmark flops back to standard every cold
  /// start and only recovers when a listener fires. Sticky bit paints
  /// instantly; every real update below overwrites it, so expiry and
  /// cancellation still converge (never the reverse).
  static const String _proCacheKey = 'max_cached_pro';
  bool _lastKnownPro = false;

  bool _initialized = false;
  bool get isInitialized => _initialized;
  bool _initializing = false;

  /// False when the backend rejects our SDK key (401 Invalid API Key).
  /// Native calls are skipped while invalid — paywalls fall back to the
  /// custom screen instead of erroring through the method channel.
  bool _authValid = true;

  /// Short human-readable reason for the last purchase failure,
  /// surfaced on the paywall so dead taps are diagnosable on-device.
  String? lastPurchaseError;

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
      // Sticky bit first: paints Max instantly on cold start, before
      // any network runs.
      try {
        final prefs = await SharedPreferences.getInstance();
        _lastKnownPro = prefs.getBool(_proCacheKey) ?? false;
      } catch (_) {}
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
        _onCustomerInfoUpdated(await Purchases.getCustomerInfo());
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
      // Warm the offering cache now so the first paywall open is
      // instant — otherwise it pays the full network fetch on tap.
      precacheOfferings();
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
    // Single choke point: every definitive update persists the sticky
    // bit (fire-and-forget) and fans out to listeners.
    _lastKnownPro =
        info.entitlements.all[entitlementId]?.isActive ?? false;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_proCacheKey, _lastKnownPro);
      } catch (_) {}
    }());
    for (final listener in _listeners) {
      listener(info);
    }
  }

  /// True when the user holds the Pro entitlement.
  bool get isPro =>
      _cachedCustomerInfo?.entitlements.all[entitlementId]?.isActive ?? false;

  /// UI-facing Max state: live entitlement OR last definitive state.
  /// Gates (quota, paywalls) keep using strict [isPro]; the wordmark
  /// uses this so offline/cold starts don't flop back to standard.
  bool get isProSticky => isPro || _lastKnownPro;

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
      _onCustomerInfoUpdated(result.customerInfo);
      // Eligibility (trials, promos) can change with the new
      // entitlement — refresh the package cache in the background.
      unawaited(currentPackages(forceRefresh: true));
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
    } catch (e) {
      debugPrint('[RevenueCat] purchase failed: $e');
      return false;
    }
  }

  /// Restore purchases (paywall footer).
  Future<bool> restore() async {
    try {
      final info = await Purchases.restorePurchases();
      _onCustomerInfoUpdated(info);
      unawaited(currentPackages(forceRefresh: true));
      return info.entitlements.all[entitlementId]?.isActive ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Current offering's packages (monthly/yearly) for the paywall.
  ///
  /// Cached after the first fetch (prefetched at startup): repeat opens
  /// serve memory instead of hitting the network, which is what made
  /// every paywall take seconds to show prices. Stale cache (up to
  /// [_packagesTtl]) still wins over an empty list when offline; a
  /// failed refresh never clears a good cache. Pass [forceRefresh] to
  /// skip the cache (purchase/restore paths do this in the background).
  static const _packagesTtl = Duration(hours: 12);

  List<Package>? _cachedPackages;
  DateTime? _cachedPackagesAt;
  Future<List<Package>>? _packagesInflight;

  Future<List<Package>> currentPackages({bool forceRefresh = false}) async {
    final cached = _cachedPackages;
    final fresh = cached != null &&
        _cachedPackagesAt != null &&
        DateTime.now().difference(_cachedPackagesAt!) < _packagesTtl;
    if (fresh && !forceRefresh) return cached;
    // One fetch at a time: concurrent paywall opens share the inflight
    // request instead of stampeding the network.
    final inflight = _packagesInflight;
    if (inflight != null) return inflight;
    final fut = _fetchPackages();
    _packagesInflight = fut;
    try {
      return await fut;
    } finally {
      _packagesInflight = null;
    }
  }

  Future<List<Package>> _fetchPackages() async {
    try {
      await ensureInitialized();
      final offerings = await Purchases.getOfferings();
      final pkgs = offerings.current?.availablePackages ?? const [];
      if (pkgs.isNotEmpty) {
        _cachedPackages = pkgs;
        _cachedPackagesAt = DateTime.now();
      }
      if (kDebugMode) {
        debugPrint('[RevenueCat] offering=${offerings.current?.identifier} '
            'packages=${pkgs.map((p) => '${p.identifier}:${p.storeProduct.priceString}').join(',')}');
      }
      if (pkgs.isNotEmpty) return pkgs;
      // Empty fetch (offline / not configured): fall back to the last
      // good cache instead of showing fallback prices.
      return _cachedPackages ?? const [];
    } catch (e) {
      debugPrint('[RevenueCat] getOfferings failed: $e');
      return _cachedPackages ?? const [];
    }
  }

  /// Warms the package cache (and the SDK's own offering cache, which
  /// is what the native sheet reads) so the first paywall open doesn't
  /// pay the network cost. Fire-and-forget after init.
  void precacheOfferings() {
    unawaited(currentPackages());
  }

  /// Pulls fresh CustomerInfo (belt-and-braces next to the update
  /// listener) so entitlement reads update instantly after purchase.
  Future<void> refreshCustomerInfo() async {
    try {
      await ensureInitialized();
      _onCustomerInfoUpdated(await Purchases.getCustomerInfo());
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
