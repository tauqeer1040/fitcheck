import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import 'wordmark_lockup.dart';

/// The placeholder block that sits above the footer: logo, wordmark,
/// rotating CTA line and the Get Max pill. Lives in the board's scroll
/// content (after the last row / filling an empty board) — the footer
/// itself holds only the chevron.
class StickerPlaceholder extends StatefulWidget {
  final bool isMax;
  final bool shapeBg;
  final double markScale;
  final int indicatorShape;
  final int indicatorColor;
  final VoidCallback? onToggleShapeBg;
  final VoidCallback? onGetMax;
  final VoidCallback? onTap;

  /// Tint the whole zone bright yellow (brand yellow) so the trigger
  /// area reads as a solid, deliberate block.
  final bool debugFill;

  const StickerPlaceholder({
    super.key,
    this.isMax = false,
    this.shapeBg = true,
    this.markScale = 1.0,
    this.indicatorShape = 7,
    this.indicatorColor = 0xFFFFD60A,
    this.onToggleShapeBg,
    this.onGetMax,
    this.onTap,
    this.debugFill = false,
  });

  @override
  State<StickerPlaceholder> createState() => _StickerPlaceholderState();
}

class _StickerPlaceholderState extends State<StickerPlaceholder> {
  /// Persisted stamp of the day the line last changed, so the copy
  /// rotates at most once a day no matter how often it's tapped.
  static const _lastChangeKey = 'placeholder_line_day';

  /// Rotating CTA lines, picked once per footer instance so the copy
  /// is fresh on every launch.
  static final _pickLines = <String>[
    'Pick your photo to add',
    "Oh, we're doing this again? Fine. Pick a photo.",
    'That fit is a crime. Document the evidence.',
    'Congrats on the outfit. Nobody asked, but congrats.',
    "I've seen better fits. Yours is... acceptable.",
    "A photo won't fix that wardrobe. Try anyway.",
    'Your outfit called. It wants to be a sticker. Desperate.',
    "Pick one. I'm not begging. Again.",
    'Absolutely devastating drip. Allegedly.',
    'That shirt is carrying your entire personality. Frame it.',
    'Another selfie? Bold. Wrong, but bold.',
    'The stickerboard will expose your laundry cycle. Proceed.',
    "Dress like that again and I'm calling someone.",
    'Certified fashion moment. I guess.',
    'The fit is mid. The sticker will be glorious.',
    "Stickers can't fix your outfit. They can immortalize it.",
    'The pants are watching. Choose wisely.',
    "This app has seen your outfits. It's not judging. It is.",
    'Warning: drip levels barely above acceptable.',
    'You survived the day in that. Reward yourself.',
    'Psst — long-press a sticker to delete it. Very therapeutic.',
  ];

  /// The CTA line. Seeded once per instance and only ever re-rolled by
  /// an explicit tap on the text (gated to once a day) — a rebuild,
  /// a scroll or a footer swipe must never swap it mid-read.
  late String _line = _pickLines[
      DateTime.now().millisecondsSinceEpoch % _pickLines.length];

  /// Today as a yyyymmdd stamp, for the once-a-day gate.
  static String _today() {
    final now = DateTime.now();
    return '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// Tap the line: advance the rotation, but at most once a day. The
  /// stamp is written immediately so a hot restart inside the same day
  /// can't hand back an old line.
  Future<void> _rollLine() async {
    AppHaptics.tap();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_lastChangeKey) == _today()) return;
      await prefs.setString(_lastChangeKey, _today());
    } catch (_) {
      // Prefs unavailable: still rotate once per tap, don't hard-fail.
    }
    if (!mounted) return;
    final next = (_pickLines.indexOf(_line) + 1) % _pickLines.length;
    setState(() => _line = _pickLines[next]);
  }

  // Field shorthands: this state's build reads the widget's config
  // often enough that the `widget.` prefix is noise.
  bool get isMax => widget.isMax;
  bool get shapeBg => widget.shapeBg;
  double get markScale => widget.markScale;
  int get indicatorShape => widget.indicatorShape;
  int get indicatorColor => widget.indicatorColor;
  bool get debugFill => widget.debugFill;
  VoidCallback? get onToggleShapeBg => widget.onToggleShapeBg;
  VoidCallback? get onGetMax => widget.onGetMax;
  VoidCallback? get onTap => widget.onTap;

  @override
  Widget build(BuildContext context) {
    final line = _line;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: debugFill ? const Color(0xFFFFD60A) : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Max lockup stands alone — no logo above it.
            if (!isMax) ...[
              Image.asset(
                'assets/logo3.png',
                width: 160,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 8),
            ],
            // Wordmark with the shape-toggle shadow behind it: square
            // shadow the same height as the image, centered. Taps cycle
            // the shape + color, exactly like the appbar wordmark.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                AppHaptics.tap();
                onToggleShapeBg?.call();
              },
              child: WordmarkLockup(
                isMax: isMax,
                // 2x the appbar lockup, and the backing shape keeps the
                // appbar's proportions (shadow == art size, 1:1) so the
                // two never drift apart.
                imageHeight: 114 * markScale,
                shadowHeight: 114 * markScale,
                shapeIndex: indicatorShape,
                color: indicatorColor,
                shadowVisible: shapeBg,
              ),
            ),
            const SizedBox(height: 8),
            // The only way this line ever changes: an explicit tap,
            // once a day. Swallow it so the block's own tap (picker)
            // doesn't also fire.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _rollLine,
              child: Text(
                line,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
              ).animate().fadeIn(
                    duration: AppMotion.standard,
                    curve: AppMotion.appleEase,
                  ),
            ),
            // Get Max pill: small white upsell where the arrow pointed.
            // Hidden for Max members (nothing to sell them).
            if (!isMax) ...[
              const SizedBox(height: 12),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  AppHaptics.tap();
                  onGetMax?.call();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Get Max',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}