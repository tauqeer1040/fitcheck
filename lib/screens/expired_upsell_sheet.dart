import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';
import '../services/growth_service.dart';
import '../services/pro_access_service.dart';
import '../services/whatsapp_sticker_service.dart';
import '../widgets/shape_marquee.dart';
import '../widgets/sheet_stat_tile.dart';
import '../widgets/sticker_loop_header.dart';

/// Quota-exhausted upsell (ramadan expired-sheet pattern): shown at the
/// 30-sticker create gate instead of dropping straight into the paywall.
/// Sticker loop hero, stats, the homescreen-sauce pitch, Get Max (pops
/// true so the caller can open the locked paywall) + an add-widgets
/// button. Returns true only when the caller should treat Max as
/// unlocked — the paywall result, not the sheet dismissal.
class ExpiredUpsellSheet {
  static Future<bool> show(
    BuildContext context, {
    required Future<bool> Function() onGetMax,
  }) async {
    if (!context.mounted) return false;
    AppHaptics.step();
    final wantMax = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ExpiredUpsell(),
    );
    if (wantMax != true || !context.mounted) return false;
    try {
      return await onGetMax();
    } catch (_) {
      return false;
    }
  }

  /// On-demand preview (debug card, release-safe). Get Max runs
  /// [onGetMax] when provided (the picker passes the paywall), else it
  /// just closes.
  static Future<void> showPreview(
    BuildContext context, {
    Future<bool> Function()? onGetMax,
  }) async {
    if (!context.mounted) return;
    AppHaptics.tap();
    final wantMax = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ExpiredUpsell(),
    );
    if (wantMax != true || onGetMax == null || !context.mounted) return;
    try {
      await onGetMax();
    } catch (_) {}
  }
}

class _ExpiredUpsell extends StatefulWidget {
  const _ExpiredUpsell();

  @override
  State<_ExpiredUpsell> createState() => _ExpiredUpsellState();
}

class _ExpiredUpsellState extends State<_ExpiredUpsell> {
  int _made = 0;
  int _free = 0;
  int _days = 1;
  bool _widgetsBusy = false;

  /// Wardrobe palette for the locked shapes teaser (same source as the
  /// thank-you marquee).
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
      if (!mounted) return;
      setState(() {
        _made = made;
        _free = free;
        _days = days;
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
    final limit = ProAccessService.freeStickerLimit;
    return Container(
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
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  const StickerLoopHeader(size: 200),
                  const SizedBox(height: 16),
                  const Text(
                    'Thank you for trying StickerPants,',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "You've reached the $limit-photo limit.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                      children: [
                        const TextSpan(text: 'Get '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Image.asset(
                            'assets/stickerpantsmax.webp',
                            width: 150,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const TextSpan(text: ' to continue.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Checklist(limit: limit),
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
                            value: '$_free/$limit', label: 'free used'),
                      ),
                      const SheetStatDivider(),
                      Expanded(
                        child:
                            SheetStatTile(value: '$_days', label: 'days sticking'),
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
                        backgroundColor:
                            Colors.white.withValues(alpha: 0.08),
                        foregroundColor:
                            Colors.white.withValues(alpha: 0.75),
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
                                    color: Colors.white
                                        .withValues(alpha: 0.5),
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
                  ShapeMarquee(colors: _palette, locked: true),
                ],
              ),
            ),
          ),
          // Sticky footer: always visible, even when the sheet scrolls.
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              onPressed: () {
                AppHaptics.tap();
                Navigator.of(context).pop(true);
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                side: const BorderSide(color: Colors.black, width: 2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: const Text(
                'Get Max',
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Max value checklist: replaces the old limit paragraph.
class _Checklist extends StatelessWidget {
  final int limit;
  const _Checklist({required this.limit});

  @override
  Widget build(BuildContext context) {
    final items = [
      'Unlimited outfits ($limit is the free limit)',
      'More jokes + compliments on your homescreen',
      'Every shape to frame your pretty face',
      'WhatsApp packs for every fit',
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '✓  ',
                  style: TextStyle(
                    color: Color(0xFFFFD60A),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Expanded(
                  child: Text(
                    item,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
