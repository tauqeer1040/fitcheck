import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../motion/app_haptics.dart';
import '../services/analytics_service.dart';
import '../services/pro_access_service.dart';
import '../services/revenuecat_service.dart';

/// StickerPants paywall: 2 tiers (monthly / yearly), 7-day free trial
/// on both, annual pre-selected. Shown two ways:
/// - soft (`locked=false`): after onboarding, dismissable via X.
/// - hard (`locked=true`): when the 30 free stickers are used up —
///   no close button, no back swipe; buying or restoring is the way out.
class PaywallScreen extends StatefulWidget {
  final bool locked;
  final String placement;

  const PaywallScreen({
    super.key,
    required this.locked,
    required this.placement,
  });

  /// Presents the paywall. Returns true when the user unlocked Pro.
  ///
  /// Tries the RevenueCat Paywall sheet first (dashboard template,
  /// trial messaging included). Falls back to this custom screen when
  /// no dashboard paywall is attached or the sheet errors — so the
  /// gate works from day one, before dashboard setup is finished.
  static Future<bool> show(
    BuildContext context, {
    required bool locked,
    required String placement,
  }) async {
    AnalyticsService.instance.logPaywallShown(placement: placement);
    final navigator = Navigator.of(context);
    await RevenueCatService.instance.ensureInitialized();
    if (RevenueCatService.instance.isPro) return true;

    final rc = await RevenueCatService.instance.presentPaywall(
      dismissable: !locked,
    );
    if (rc == PaywallResult.purchased || rc == PaywallResult.restored) {
      return true;
    }
    if (rc == PaywallResult.cancelled) {
      AnalyticsService.instance.logPaywallDismissed(placement: placement);
      return false;
    }
    // Error / no dashboard paywall → custom screen fallback.
    final unlocked = await navigator.push<bool>(
      PageRouteBuilder(
        fullscreenDialog: true,
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, _, _) =>
            PaywallScreen(locked: locked, placement: placement),
        transitionsBuilder: (_, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
          child: child,
        ),
      ),
    );
    if (unlocked != true) {
      AnalyticsService.instance.logPaywallDismissed(placement: placement);
    }
    return unlocked == true;
  }

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  static const _fallbackMonthly = '\$14.99';
  static const _fallbackYearly = '\$99.99';
  static const _privacyUrl = 'https://stickerpants.taucity.xyz/privacy';
  static const _termsUrl = 'https://stickerpants.taucity.xyz/terms';

  List<Package> _packages = const [];
  bool _yearly = true;
  bool _busy = false;
  int _made = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pkgs = await RevenueCatService.instance.currentPackages();
    final made = await ProAccessService.totalMade();
    if (!mounted) return;
    setState(() {
      _packages = pkgs;
      _made = made;
    });
  }

  Package? get _monthly => _pick(PackageType.monthly);
  Package? get _yearlyPkg => _pick(PackageType.annual);

  Package? _pick(PackageType type) {
    for (final p in _packages) {
      if (p.packageType == type) return p;
    }
    return null;
  }

  String get _monthlyPrice =>
      _monthly?.storeProduct.priceString ?? _fallbackMonthly;
  String get _yearlyPrice =>
      _yearlyPkg?.storeProduct.priceString ?? _fallbackYearly;

  Future<void> _buy() async {
    if (_busy) return;
    final pkg = _yearly ? (_yearlyPkg ?? _monthly) : (_monthly ?? _yearlyPkg);
    if (pkg == null) return;
    setState(() => _busy = true);
    AppHaptics.tap();
    try {
      final ok = await RevenueCatService.instance.purchase(pkg);
      if (ok && mounted) {
        AppHaptics.milestone();
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await RevenueCatService.instance.restore();
      if (ok && mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _close() {
    if (!widget.locked) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.locked,
      child: Scaffold(
        backgroundColor: const Color(0xFF1C1C1E),
        body: SafeArea(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    const Text(
                      'Keep sticking.\nForever.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        height: 1.12,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _made > 0
                          ? "You've made $_made sticker${_made == 1 ? '' : 's'} — Pro keeps them unlimited."
                          : 'Your 30 free stickers are used up — Pro keeps them unlimited.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _perk('✂️', 'Unlimited stickers',
                        'No more free-tier counting. Cut as much as you want.'),
                    _perk('📦', 'Unlimited WhatsApp packs',
                        'Every fit, straight into the chat.'),
                    _perk('🧲', 'Widgets + priority cuts',
                        'Home-screen fits and first-in-line processing.'),
                    const SizedBox(height: 24),
                    _planCard(
                      selected: _yearly,
                      badge: 'SAVE 44%',
                      title: 'Yearly Pro',
                      subtitle: '$_yearlyPrice/year · just \$8.33/mo',
                      onTap: () => setState(() => _yearly = true),
                    ),
                    const SizedBox(height: 12),
                    _planCard(
                      selected: !_yearly,
                      badge: null,
                      title: 'Monthly Pro',
                      subtitle: '$_monthlyPrice/month, flexible',
                      onTap: () => setState(() => _yearly = false),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _buy,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD60A),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        textStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: Text(_busy
                          ? 'Working…'
                          : 'Start 7-day free trial'),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Free for 7 days, then ${_yearly ? '$_yearlyPrice/year' : '$_monthlyPrice/month'}. Cancel anytime in Google Play.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // privacy-policy + terms links: reachable in-app and
                    // mirrored as the Play listing privacy URL.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _link('Restore', _restore),
                        _sep(),
                        _link(
                          'Manage',
                          () => RevenueCatService.instance
                              .presentCustomerCenter(),
                        ),
                        _sep(),
                        _link('Privacy', () => _open(_privacyUrl)),
                        _sep(),
                        _link('Terms', () => _open(_termsUrl)),
                      ],
                    ),
                  ],
                ),
              ),
              if (!widget.locked)
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    onPressed: _close,
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _perk(String emoji, String title, String sub) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15.5,
                  ),
                ),
                Text(
                  sub,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _planCard({
    required bool selected,
    required String? badge,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFFFD60A).withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? const Color(0xFFFFD60A)
                : Colors.white.withValues(alpha: 0.12),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected
                  ? const Color(0xFFFFD60A)
                  : Colors.white.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD60A),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _link(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 13,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Widget _sep() {
    return Text(
      '  ·  ',
      style: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
    );
  }
}
