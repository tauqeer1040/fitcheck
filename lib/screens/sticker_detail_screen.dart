import 'dart:ui';

import 'package:dismissible_page/dismissible_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/outfit_sticker.dart';
import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../services/sticker_style_service.dart';
import '../services/whatsapp_sticker_service.dart';
import '../widgets/shaped_sticker.dart';

/// Fullscreen sticker view: pure floating sticker on dark, no chrome.
/// Flick it any direction to fly it home into its grid slot (quiet
/// landing); system back does the same as a fallback.
class StickerDetailScreen extends StatefulWidget {
  final OutfitSticker sticker;

  /// Fired the moment the home flight starts (flick or system back), so
  /// the grid can time its landing squash to touchdown.
  final VoidCallback? onFlightHome;

  const StickerDetailScreen({
    super.key,
    required this.sticker,
    this.onFlightHome,
  });

  @override
  State<StickerDetailScreen> createState() => _StickerDetailScreenState();
}

class _StickerDetailScreenState extends State<StickerDetailScreen>
    with TickerProviderStateMixin {
  /// Bottom-hint fun lines, same voice as the homescreen CTA. A fresh
  /// one rolls on every fullscreen open.
  static const List<String> _flickLines = [
    'Flick it home.',
    "Give it a flick. It knows the way.",
    "Flick it. Gently. It's emotional.",
    "Swipe it home before it gets comfortable.",
    "Flick to keep. Or don't. It'll adapt.",
    "One flick and this sticker is legally yours.",
    "Flick it home. It misses the grid already.",
    "Be honest: you're just flicking it to see it fly.",
    "Flick it. This is the fun part.",
    "That flick was mid. Try again after you keep it.",
    "Flick it home before your camera roll sees this.",
    "It's not clingy. It just wants to go home.",
    "Flick it like it owes you money.",
    "A gentle flick. This is a sticker, not a fly.",
    "Flick to keep. We don't do refunds.",
    "Home is where the grid is. Flick.",
    "Flick it. The grid believes in you.",
    "Don't overthink the flick. It never ends well.",
    "This sticker survived your wardrobe. It can survive a flick.",
    "Flick it home. The other stickers are watching.",
  ];

  /// Rolled once per state (i.e. per fullscreen open) so every visit
  /// feels fresh.
  late final int _flickIndex =
      (DateTime.now().millisecondsSinceEpoch ^ widget.sticker.id.hashCode) %
      _flickLines.length;

  /// Drives the collapse-into-shape entrance: the art starts oversized
  /// and shrinks into the sticker's solid silhouette, which springs in
  /// beneath it with an overshoot pop.
  late final AnimationController _openController;

  /// The sticker's stored shape — the single source of truth shared with
  /// the grid cell (and, for new stickers, the gallery-sheet thumbnail).
  late final int _shape = widget.sticker.shapeIndex ??
      fallbackShapeIndex(widget.sticker.id);

  @override
  void initState() {
    super.initState();
    _openController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..forward();
  }

  /// Animated mirror of the DismissiblePage drag (0.0–1.0). Fades the
  /// frosted-glass blur as the sticker is dragged so the grid sharpens
  /// underneath, and eases the blur back when a drag is cancelled.
  late final AnimationController _dragFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 200),
  );

  @override
  void dispose() {
    _openController.dispose();
    _dragFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final sidePad = MediaQuery.of(context).padding;

    return PopScope(
      // Either exit path plays the same linear flight home; report it so
      // the grid squash lands exactly on touchdown.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) widget.onFlightHome?.call();
        },
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Layer 1 — the frosted glass, OUTSIDE the DismissiblePage: a
          // static, full-bleed veil. It never translates, scales, or
          // clips with the drag, so the dismiss gesture can't expose raw
          // edges — the glass illusion holds to the last pixel.
          Positioned.fill(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _dragFade,
                builder: (context, child) {
                  // 1.0 fully frosted at rest → 0.0 clear at pop point.
                  final glass = 1.0 - _dragFade.value;
                  return BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 16 * glass,
                      sigmaY: 16 * glass,
                    ),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.20 * glass),
                    ),
                  );
                },
              ),
            ),
          ),
          // Layer 2 — the draggable sticker content, full-bleed.
          // DismissiblePage handles the gesture: 1:1 finger-follow in ANY
          // direction, scale-down + corner rounding while dragging,
          // release past threshold pops, spring-back below it.
          Positioned.fill(
            child: DismissiblePage(
        onDismissed: () {
          AppHaptics.launch();
          Navigator.pop(context);
        },
        direction: DismissiblePageDismissDirection.multi,
        // Respect device padding (bottom hint sits above the home pill).
        isFullScreen: false,
        // Library veil: full-bleed dark tint that fades with the drag.
        // Sits outside its Transform, so it also never clips.
        backgroundColor: Colors.black,
        startingOpacity: 0.20,
        minScale: 0.82,
        maxRadius: 24,
        maxTransformValue: 0.45,
        onDragStart: () => _dragFade.forward(),
        onDragUpdate: (d) => _dragFade.value = d.overallDragValue.clamp(0.0, 1.0),
        onDragEnd: () => _dragFade.reverse(),
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      // Pixel-unlock entrance: the shape-open morph runs
                      // as the route fades in; the Hero keeps the jelly
                      // flight home. Same ShapedSticker structure as the
                      // grid cell, so both ends of the flight match.
                      child: Hero(
                        tag: 'sticker-${widget.sticker.id}',
                        child: AnimatedBuilder(
                          animation: _openController,
                          builder: (context, _) => ShapedSticker(
                            imagePath: widget.sticker.imagePath,
                            // Stored shape: identical to the grid cell.
                            shapeIndex: _shape,
                            dominantColor: widget.sticker.dominantColor ??
                                kFallbackStickerColor,
                            // Explicit width AND height at the grid's
                            // portrait 0.75 aspect: without a height the
                            // unbounded box stretched the M3 shape tall.
                            width: size.width * 0.8,
                            height: (size.width * 0.8 * 4 / 3)
                                .clamp(0.0, size.height * 0.55),
                            // Overshoot curve: the shape card springs in
                            // past its rest size and settles — the pop.
                            collapseProgress:
                                Curves.easeOutBack.transform(
                              _openController.value,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Added ${_formatDate(widget.sticker.createdAt)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey.shade500,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: sidePad.bottom + 32,
              child: Center(
                child: AppMotion.entrance(
                  context,
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _flickLines[_flickIndex],
                      style: const TextStyle(color: Colors.white),
                    )
                        .animate(key: ValueKey(_flickIndex))
                        .fadeIn(
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOut,
                        ),
                  ),
                ),
              ),
            ),
            // Share button: frosted glass, white text, small icon, top-right corner
            Positioned(
              top: sidePad.top + 16,
              right: 16,
              child: AppMotion.entrance(
                context,
                GestureDetector(
                  onTap: () {
                    AppHaptics.tap();
                    _addToWhatsApp(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    child: const Icon(
                      Icons.add_circle_outline,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        ),
        ),
          ],
        ),
      ),
    );
  }

  /// Share = add the user's whole sticker pack to WhatsApp (official
  /// third-party sticker API). WhatsApp converts nothing on its side: the
  /// pack ships as 512x512 transparent WebP, and once confirmed the
  /// stickers live in WhatsApp's sticker tray — sent as real stickers,
  /// never flattened to a photo. Runs after the current frame so the
  /// navigator pop inside the native flow can't race the build.
  Future<void> _addToWhatsApp(BuildContext context) async {
    try {
      final stickers = await WhatsAppStickerService.loadStickers();
      if (stickers.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Create some stickers first')),
          );
        }
        return;
      }
      await WhatsAppStickerService.addPack(stickers);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not add stickers to WhatsApp')),
        );
      }
    }
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}
