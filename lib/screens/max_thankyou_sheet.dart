import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_confetti/flutter_confetti.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';
import '../services/analytics_service.dart';
import '../services/growth_service.dart';
import '../services/moment_paywall_service.dart';
import '../services/pro_access_service.dart';
import '../services/sticker_title_service.dart';
import '../services/whatsapp_sticker_service.dart';
import '../widgets/shape_marquee.dart';
import '../widgets/sheet_stat_tile.dart';
import '../widgets/sticker_loop_header.dart';
import 'expired_upsell_sheet.dart';

/// Post-subscription thank-you (ramadan pattern): a dismissable
/// bottomsheet with the user's stats. Shown once per purchase/restore
/// event — never on plain app start, so it can't nag.
class MaxThankYouSheet {
  static bool _showing = false;

  static Future<void> show(
    BuildContext context, {
    required bool restored,
    bool markSeen = true,
  }) async {
    if (_showing) {
      debugPrint('[MaxThankYou] skipped: already showing');
      return;
    }
    _showing = true;
    try {
      AnalyticsService.instance.logMaxThankYouShown(restored: restored);
      if (!context.mounted) {
        debugPrint('[MaxThankYou] skipped: context unmounted');
        return;
      }
      debugPrint('[MaxThankYou] presenting (restored=$restored)');
      AppHaptics.milestone();
      final sheetFuture = showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _MaxThankYou(restored: restored),
      );
      // Purchase delight: confetti bursts as the sheet opens.
      // Fire-and-forget off the sheet future so a confetti failure can
      // never block the sheet.
      try {
        Confetti.launch(
          context,
          options:
              const ConfettiOptions(particleCount: 60, spread: 80, y: 0.4),
        );
      } catch (_) {}
      await sheetFuture;
      // Dismissed: mark seen so the boot welcome-back never repeats it.
      // Previews pass markSeen:false to stay out of the way.
      if (markSeen) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('max_thankyou_seen', true);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[MaxThankYou] failed: $e');
      // Thank-you must never break the purchase flow.
    } finally {
      _showing = false;
    }
  }

  /// On-demand preview picker (works in release builds — hidden behind
  /// the appbar sparkle long-press): view either thank-you variant
  /// without buying anything. Previews never mark the sheet seen.
  static Future<void> showPreviewPicker(BuildContext context) async {
    if (!context.mounted) return;
    AppHaptics.tap();
    await showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Sheet previews',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await MaxThankYouSheet.show(
                    context,
                    restored: false,
                    markSeen: false,
                  );
                },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD60A),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Thank-you (purchase)',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await MaxThankYouSheet.show(
                    context,
                    restored: true,
                    markSeen: false,
                  );
                },
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Thank-you (restore)',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await ExpiredUpsellSheet.showPreview(
                    context,
                    onGetMax: () => MomentPaywallService.maybeShow(
                      context,
                      placement: 'expired_upsell_preview',
                      locked: false,
                    ),
                  );
                },
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Expired upsell',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MaxThankYou extends StatefulWidget {
  final bool restored;
  const _MaxThankYou({required this.restored});

  @override
  State<_MaxThankYou> createState() => _MaxThankYouState();
}

class _MaxThankYouState extends State<_MaxThankYou> {
  int _made = 0;
  int _free = 0;
  int _days = 1;
  bool _widgetsBusy = false;

  /// Onboarding Q0 name, greeting the sheet. '' until loaded.
  String _name = '';

  /// Wardrobe palette: distinct dominant shades of the current
  /// stickers, brand yellow when the gallery is empty. Tints the
  /// unlocked-shapes marquee below.
  List<int> _palette = const [0xFFFFD60A];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final made = await ProAccessService.totalMade();
      final free = await ProAccessService.freeUsed();
      final prefs = await SharedPreferences.getInstance();
      var days = 1;
      final installStr = prefs.getString('install_date');
      final install =
          installStr == null ? null : DateTime.tryParse(installStr);
      if (install != null) {
        days = DateTime.now().difference(install).inDays + 1;
        if (days < 1) days = 1;
      }
      final stickers = await WhatsAppStickerService.loadStickers();
      final shades = <int>[];
      for (final s in stickers) {
        final c = s.dominantColor;
        if (c != null && !shades.contains(c)) shades.add(c);
      }
      final name = await StickerTitleService.storedDisplayName();
      if (!mounted) return;
      setState(() {
        _made = made;
        _free = free;
        _days = days;
        _name = name;
        if (shades.isNotEmpty) _palette = shades;
      });
    } catch (_) {}
  }

  Future<void> _addWidgets() async {
    if (_widgetsBusy) return;
    setState(() => _widgetsBusy = true);
    try {
      await GrowthService.pinWidgets();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pick StickerPants in the widget list!'),
        ),
      );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _widgetsBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const StickerLoopHeader(size: 200),
            const SizedBox(height: 16),
            Text(
              widget.restored
                  ? 'Welcome back to Max${_name.isNotEmpty ? ', $_name' : ''}'
                  : 'Thanks for getting Max${_name.isNotEmpty ? ', $_name' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Unlimited stickers. No gates. Just fits.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: SheetStatTile(
                      value: '$_made', label: 'stickers made'),
                ),
                const SheetStatDivider(),
                Expanded(
                  child: SheetStatTile(
                      value: '$_free', label: 'free before Max'),
                ),
                const SheetStatDivider(),
                Expanded(
                  child: SheetStatTile(
                      value: '$_days', label: 'days sticking'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 60,
              child: FilledButton(
                onPressed: _widgetsBusy ? null : _addWidgets,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  foregroundColor: Colors.white.withValues(alpha: 0.75),
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.widgets_rounded, size: 20),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Add homescreen widgets now',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _widgetsBusy
                                ? 'Opening…'
                                : '(free, forever yours)',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color:
                                  Colors.white.withValues(alpha: 0.5),
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            ShapeMarquee(colors: _palette),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: () {
                  AppHaptics.tap();
                  Navigator.of(context).pop();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD60A),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Start sticking',
                  style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
