import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';
import '../services/analytics_service.dart';
import '../services/pro_access_service.dart';

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
      await showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _MaxThankYou(restored: restored),
      );
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
      if (!mounted) return;
      setState(() {
        _made = made;
        _free = free;
        _days = days;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
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
          const SizedBox(height: 20),
          Image.asset(
            'assets/stickerpantsmax.webp',
            width: 200,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 16),
          Text(
            widget.restored ? 'Welcome back to Max' : 'Thanks for getting Max',
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
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StatTile(value: '$_made', label: 'stickers made'),
              _StatTile(value: '$_free', label: 'free before Max'),
              _StatTile(value: '$_days', label: 'days sticking'),
            ],
          ),
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
    );
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;
  const _StatTile({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFFFD60A),
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}
