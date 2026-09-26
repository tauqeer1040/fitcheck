import 'dart:ui';

import 'package:dismissible_page/dismissible_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../models/outfit_sticker.dart';
import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../services/analytics_service.dart';
import '../services/revenuecat_service.dart';
import '../services/roast_service.dart';
import '../services/sticker_share_service.dart';
import '../services/sticker_style_service.dart';
import '../services/whatsapp_sticker_service.dart';
import '../widgets/genie_flight.dart';
import '../widgets/shaped_sticker.dart';
import 'growth_prompt_sheet.dart' show playStoreUrl;

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
  /// Drives the collapse-into-shape entrance.
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
          // Tap anywhere (background layer, below the pills so their
          // buttons win the arena) also dismisses home.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                AppHaptics.tap();
                Navigator.pop(context);
              },
              child: const SizedBox.expand(),
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
        // Hair-trigger. The library compares this against
        //   max(|dx| / screenW, |dy| / screenH)
        // *after* scaling the drag by dragSensitivity (0.7), so the real
        // finger travel needed is threshold / 0.7 of the screen: 0.25 meant
        // dragging ~36% of the way to the edge. 0.08 lands at ~11%, i.e. a
        // slight swipe sends the sticker home.
        //
        // Threshold is the right lever rather than dragSensitivity: raising
        // sensitivity would make the sticker travel further than the finger
        // and break the 1:1 follow. Note end() ignores the fling velocity
        // entirely (no `createRecognizer` hook on DismissiblePage), so a
        // short fast flick still has to clear this distance.
        dismissThresholds: const {
          DismissiblePageDismissDirection.multi: 0.08,
        },
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
                      // Tap dismisses home (drag still flick-dismisses).
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          AppHaptics.tap();
                          Navigator.pop(context);
                        },
                        child: Hero(
                        tag: 'sticker-${widget.sticker.id}',
                        // Curved arc home, matching the grid cell.
                        createRectTween: stickerFlightTween,
                        child: AnimatedBuilder(
                          animation: _openController,
                          builder: (context, _) => ShapedSticker(
                            imagePath: widget.sticker.imagePath,
                            // Stored shape: identical to the grid cell.
                            shapeIndex: _shape,
                            // Locked: full-bleed silhouette, not tunable.
                            shapeScale: 1.0,
                            rotateSilhouette: true,
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
          // (Flick hint + share button live in the static outer layer
          // below so only the sticker rides the dismiss drag.)
          ],
        ),
        ),
        ),
          // Static layer: roast pill, share button. Painted above
          // the dismissible sticker so taps land here first, and none of
          // it translates/scales with the drag.
          Positioned(
            left: 0,
            right: 0,
            bottom: sidePad.bottom + 32,
            child: Center(
              child: AppMotion.entrance(
                context,
                _ToastPill(
                  // Permanent joke: fixed salt 0 makes the roast a pure
                  // function of the sticker — identical every open.
                  child: Text(
                    RoastService.roastFor(
                      widget.sticker,
                      isMax: RevenueCatService.instance.isPro,
                    ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontStyle: FontStyle.italic,
                    ),
                    textAlign: TextAlign.center,
                  ).animate().fadeIn(
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOut,
                      ),
                ),
              ),
            ),
          ),
          // Two routes, because they are genuinely different outcomes:
          // WhatsApp (the sticker tray) and everywhere else (the platform
          // share sheet).
          Positioned(
            top: sidePad.top + 16,
            right: 16,
            child: AppMotion.entrance(
              context,
              Row(
                children: [
                  _GlassAction(
                    icon: const FaIcon(
                      FontAwesomeIcons.whatsapp,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: 'Add to WhatsApp stickers',
                    onTap: () => _addToWhatsAppPack(context),
                  ),
                  const SizedBox(width: 8),
                  _GlassAction(
                    icon: const Icon(
                      Icons.share_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: 'Share',
                    onTap: () => _shareSticker(context),
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

  /// Adds the user's whole pack to WhatsApp's own sticker tray.
  ///
  /// This is the ONLY route that lands a real, transparent sticker in
  /// WhatsApp: [WhatsAppPackManager] centre-fits every sticker onto a
  /// transparent 512x512 WebP under 100 KB, which is exactly what
  /// WhatsApp's third-party sticker API validates — stickers are always
  /// 512x512 and the shape is carried by the alpha channel.
  ///
  /// Sharing a PNG through the share sheet instead hands the file to
  /// WhatsApp's PHOTO pipeline, which re-encodes to JPEG: the alpha is
  /// thrown away and the cutout ends up on a black rectangle. That is a
  /// WhatsApp-side rule, not something the share sheet can override, so
  /// the two buttons are not redundant.
  Future<void> _addToWhatsAppPack(BuildContext context) async {
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
      AnalyticsService.instance.logWhatsAppPackAdded(success: true);
    } catch (_) {
      AnalyticsService.instance.logWhatsAppPackAdded(success: false);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp')),
        );
      }
    }
  }

  /// Share = the phone's own share sheet, with THIS sticker attached, so
  /// it can go to any app rather than only WhatsApp.
  ///
  /// The old path built a WhatsApp sticker pack and called the official
  /// third-party sticker API instead. That is still the only way to
  /// arrive as a real sticker, but it is WhatsApp-only and it validates
  /// hard — every sticker must be exactly 512x512 and under 100 KB — so
  /// our tight-cropped, aspect-preserving exports (499x1067 at ~150 KB+
  /// for a single sticker) were rejected outright with "there was a
  /// problem with this sticker pack".
  ///
  /// [StickerShareService] hands over the cutout with its alpha intact
  /// and at its own size, so the sticker keeps the shape it was made in.
  Future<void> _shareSticker(BuildContext context) async {
    try {
      final opened = await StickerShareService.shareSticker(
        widget.sticker.imagePath,
        text: 'Made with StickerPants ✨\n$playStoreUrl',
        title: 'StickerPants',
      );
      if (!opened) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That sticker file is missing')),
          );
        }
        return;
      }
      AnalyticsService.instance.logShareInvoked();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the share sheet')),
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

/// Frosted action button for the fullscreen chrome (same recipe as the
/// share affordance it replaces).
class _GlassAction extends StatelessWidget {
  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  const _GlassAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () {
          AppHaptics.tap();
          onTap();
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
          child: icon,
        ),
      ),
    );
  }
}

/// Frosted-glass pill for the fullscreen hints — the undo-delete toast
/// recipe: σ20 blur, 0xFF3A3A3C at 72%, radius 20.
class _ToastPill extends StatelessWidget {
  final Widget child;
  const _ToastPill({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          color: const Color(0xFF3A3A3C).withValues(alpha: 0.72),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: child,
        ),
      ),
    );
  }
}
