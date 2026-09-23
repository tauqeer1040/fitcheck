import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_animate/flutter_animate.dart';
import './wordmark_shadow.dart';
import '../models/outfit_sticker.dart';
import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../services/sticker_style_service.dart';
import 'genie_flight.dart';
import 'shaped_sticker.dart';

/// Homescreen sticker board: stickers sit in aligned rows (max [maxColumns]
/// per row, partial last row hugs the left), the board scrolls vertically.
///
/// Pinch on the board resizes stickers: pinch out = bigger (down to
/// [minColumns] per row), pinch in = smaller (up to [maxColumns] per row).
class StickerGrid extends StatefulWidget {
  final List<OutfitSticker> stickers;
  final void Function(OutfitSticker) onTap;

  /// Scroll controller owned by the parent (used to reveal row 0 landing).
  final ScrollController? controller;

  /// Id of the sticker flying home: its cell hosts the Hero destination.
  /// Null for everyone else.
  final String? justAddedId;

  /// Fired after landing so the parent can clear the tag.
  final VoidCallback? onLanded;

  /// Fired at touchdown with the landing cell's global center, so the
  /// parent can shower confetti from exactly that spot.
  final ValueChanged<Offset>? onTouchdown;

  /// Delete mode: every sticker shakes with a × badge top-left.
  final bool jiggling;

  /// Fired on long-press of any cell to enter delete mode.
  final VoidCallback? onEnterJiggle;

  /// Fired when a × badge is tapped.
  final ValueChanged<OutfitSticker>? onDelete;

  /// Fired when empty board space is tapped while jiggling.
  final VoidCallback? onExitJiggle;

  /// Space held clear above the floating bottom sheet so the last row
  /// never hides underneath it.
  final double bottomInset;

  /// Solid M3 shape backdrop behind cells. Off = bare cutout art.
  final bool shapeBg;

  /// Fired when the empty-state wordmark is tapped (same shape-bg
  /// toggle as the appbar wordmark).
  final VoidCallback? onToggleShapeBg;

  /// Max subscribers see the Max lockup in the empty state.
  final bool isMax;

  /// Debug card actions (everything that lived in the appbar).
  final VoidCallback? onSupportSheet;
  final VoidCallback? onShapeDemo;
  final VoidCallback? onPro;
  final VoidCallback? onPreviewSheets;
  final VoidCallback? onOnboarding;

  /// Per-type notification state + toggle (debug card).
  final ValueChanged<String>? onToggleNotif;

  /// Sheet thumbnail style (debug card): M3 expressive shapes vs
  /// plain rounded squares.
  final bool m3Thumbs;
  final ValueChanged<bool>? onToggleM3Thumbs;

  /// Index into kStyleShapes for the wordmark shadow indicator.
  final int indicatorShape;

  /// ARGB color for the wordmark shadow (user's sticker palette).
  final int indicatorColor;

  /// Wordmark shadow height multiplier (shape lab).
  final double markScale;

  /// Silhouette size relative to the art box (fixed 70%, user-tuned).
  final double shapeScale;

  static const int defaultColumns = 5;
  static const int minColumns = 3;
  static const int maxColumns = 6;

  const StickerGrid({
    super.key,
    required this.stickers,
    required this.onTap,
    this.controller,
    this.shapeBg = true,
    this.indicatorShape = 7,
    this.onToggleShapeBg,
    this.isMax = false,
    this.onSupportSheet,
    this.onShapeDemo,
    this.onPro,
    this.onPreviewSheets,
    this.onOnboarding,
    this.onToggleNotif,
    this.m3Thumbs = false,
    this.onToggleM3Thumbs,
    this.indicatorColor = 0xFFFFD60A,
    this.markScale = 1.0,
    this.shapeScale = 0.7,
    this.justAddedId,
    this.onLanded,
    this.onTouchdown,
    this.jiggling = false,
    this.onEnterJiggle,
    this.onDelete,
    this.onExitJiggle,
    this.bottomInset = 0,
  });

  @override
  State<StickerGrid> createState() => _StickerGridState();
}

class _StickerGridState extends State<StickerGrid>
    with TickerProviderStateMixin {
  int _columns = StickerGrid.defaultColumns;
  double _startSpan = StickerGrid.defaultColumns.toDouble();

  /// CTA fun lines: a fresh one every app load, rotating on each tap of
  /// the empty state.
  static const List<String> _pickLines = [
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
  ];

  /// Randomized per app launch so every load feels fresh.
  late int _lineIndex =
      DateTime.now().millisecondsSinceEpoch % _pickLines.length;

  void _rotatePickLine() {
    AppHaptics.tap();
    setState(() => _lineIndex = (_lineIndex + 1) % _pickLines.length);
  }

  /// Arrow: single art (arrow2) at a fixed 130deg. Tap plays the
  /// jelly wobble + haptic. No swapping, no slider.
  static const double _arrowDeg = 130;
  static const double _arrowHeight = 240;

  /// The arrow burns down as the board fills: every saved sticker takes
  /// one step off its height, gone at 31 (the 30-sticker free quota
  /// plus the 31st save). Urgency you can feel — never a banner.
  static const int _arrowGoneAt = 31;

  double get _arrowScale =>
      ((_arrowGoneAt - widget.stickers.length) / _arrowGoneAt)
          .clamp(0.0, 1.0);

  late final AnimationController _arrowWobble = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );

  void _bounceArrow() {
    AppHaptics.tap();
    _arrowWobble.forward(from: 0);
  }

  /// Live pinch preview: rubber-banded scale + focal anchor. Springs back
  /// to 1.0 on release while the snapped column count stays.
  double _liveScale = 1.0;
  Offset _liveFocal = Offset.zero;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    lowerBound: 0.5,
    upperBound: 2.0,
    value: 1.0,
  );

  /// Shared jiggle clock (~300ms period); cells desync via phase offsets.
  late final AnimationController _jiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  /// Raw active pointers by ID. Two-pointer tracking bypasses the gesture
  /// arena entirely, so scroll can never steal a pinch.
  final Map<int, Offset> _pointers = {};
  double _pinchStart = 0;
  bool _pinching = false;

  /// Timestamp of the last swallowed body-tap while jiggling. Lets the
  /// background tap detector tell cell taps apart from empty-space taps
  /// without depending on gesture-dispatch order.
  DateTime? _swallowStamp;

  /// Whether a zoom gesture (or its settle spring) is currently active.
  /// Epsilon-based: springs stop within tolerance, never exactly at 1.0.
  bool get _zooming => (_liveScale - 1.0).abs() > 0.003;

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      if (mounted) setState(() => _liveScale = _settle.value);
    });
    // Springs land within tolerance — snap exactly home so the
    // long-press gate below reopens and the transform goes identity.
    _settle.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _liveScale = 1.0);
      }
    });
    if (widget.jiggling) _jiggle.repeat();
  }

  @override
  void didUpdateWidget(StickerGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.jiggling == oldWidget.jiggling) return;
    if (widget.jiggling) {
      _jiggle.repeat();
    } else {
      _jiggle.stop();
      _swallowStamp = null;
    }
  }

  @override
  void dispose() {
    _arrowWobble.dispose();
    _jiggle.dispose();
    _settle.dispose();
    super.dispose();
  }

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.globalToLocal(global);
  }

  double _span() {
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  Offset _focal() {
    final pts = _pointers.values.toList();
    return (pts[0] + pts[1]) / 2;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && !_pinching) {
      // Pinch begins: anchor span, lock scroll, start live preview.
      _pinching = true;
      _startSpan = _columns.toDouble();
      _pinchStart = _span();
      _settle.stop();
      AppHaptics.mode();
      setState(() {
        _liveScale = 1.0;
        _liveFocal = _toLocal(_focal());
      });
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (!_pinching || _pointers.length != 2 || _pinchStart <= 0) return;
    // Live rubber-band preview from the first pixel of movement — no dead
    // zone — plus continuous quantization so steps tick as you pass them.
    // Pinch out (scale > 1) = bigger stickers = fewer columns.
    final scale = _span() / _pinchStart;
    final next = (_startSpan / scale)
        .round()
        .clamp(StickerGrid.minColumns, StickerGrid.maxColumns);
    setState(() {
      _liveScale = scale.clamp(0.6, 1.8);
      _liveFocal = _toLocal(_focal());
      if (next != _columns) {
        _columns = next;
        AppHaptics.launch();
      }
    });
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pinching && _pointers.length < 2) {
      _pinching = false;
      // Scroll lock releases via rebuild below.
      if (_liveScale == 1.0) {
        setState(() {});
        return;
      }
      // Zoom committed: heavy thunk as the grid snaps to its columns.
      AppHaptics.milestone();
      // M3 Expressive settle: spring home with a whisper of overshoot.
      _settle.animateWith(
        SpringSimulation(AppMotion.tapSpring, _liveScale, 1.0, 0),
      );
    }
  }

  void _onBackgroundTap() {
    if (!widget.jiggling) return;
    final stamp = _swallowStamp;
    _swallowStamp = null;
    // A fresh swallow stamp means this tap landed on a sticker body
    // (both detectors fire) — those are dead in delete mode.
    if (stamp != null &&
        DateTime.now().difference(stamp) < const Duration(milliseconds: 300)) {
      return;
    }
    widget.onExitJiggle?.call();
  }

  /// Body taps do nothing in delete mode, but still claim the gesture so
  /// the background detector doesn't mistake them for tap-away.
  void _swallowTap() {
    _swallowStamp = DateTime.now();
  }

  /// iOS-Photos double-tap: toggles default (5) and showcase (3) density
  /// with a springy pulse + tick. Pure tap-arena gesture: always fires.
  void _onDoubleTap() {
    setState(() {
      _columns = _columns == StickerGrid.defaultColumns
          ? StickerGrid.minColumns
          : StickerGrid.defaultColumns;
    });
    AppHaptics.step();
    _settle.animateWith(
      SpringSimulation(AppMotion.tapSpring, 0.94, 1.0, 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stickers.isEmpty) {
      // No stickers: brand block sits at the top of the board.
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 8),
            _buildEmptyState(),
          ],
        ),
      );
    }

    // With stickers: same brand block, but living INSIDE the grid as an
    // ever-present footer after the last row (scrolls with the content).
    return _buildGrid();
  }

  /// Logo + wordmark + rotating fun CTA + big arrow pointing at the
  /// sheet below. Any tap on the empty state spins a new line; picks
  /// happen straight from the sheet thumbnails (the arrow's own tap
  /// just bounces).
  Widget _buildEmptyState() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _rotatePickLine,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Max lockup stands alone — no logo above it.
        if (!widget.isMax) ...[
          Image.asset(
            'assets/logo3.png',
            width: 160,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 8),
        ],
        // Wordmark with the shape-toggle shadow indicator behind
        // it: square shadow the same height as the image,
        // centered. Hidden when the cell backdrops are off.
        // Taps toggle like the appbar wordmark.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            AppHaptics.tap();
            widget.onToggleShapeBg?.call();
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedOpacity(
                opacity: widget.shapeBg ? 1.0 : 0.0,
                duration: AppMotion.standard,
                  child: WordmarkShadow(
                    height: 90 * widget.markScale,
                    shape: kStyleShapes[widget.indicatorShape
                        .clamp(0, kStyleShapes.length - 1)],
                    color: widget.indicatorColor,
                    // Max lockup is wider: fixed 65% shadow width.
                    widthRatio: widget.isMax ? 0.65 : 1.0,
                  ),
              ),
                Image.asset(
                  widget.isMax
                      ? 'assets/stickerpantsmax.webp'
                      : 'assets/stickerpants.webp',
                  width: 180,
                  fit: BoxFit.contain,
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _pickLines[_lineIndex],
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.grey.shade600,
          ),
        ).animate(key: ValueKey(_lineIndex)).fadeIn(
              duration: AppMotion.standard,
              curve: AppMotion.appleEase,
            ),
        const SizedBox(height: 8),
        // Arrow: tap plays the jelly bounce + haptic. Fixed art/angle.
        // Shrinks one step per saved sticker; gone at 31.
        if (_arrowScale > 0)
          Transform.rotate(
            angle: _arrowDeg * math.pi / 180,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _bounceArrow,
              child: AnimatedBuilder(
                animation: _arrowWobble,
                builder: (context, child) {
                  // Decaying sine wobble = jelly.
                  final t = _arrowWobble.value;
                  final s =
                      1.0 + 0.18 * math.sin(t * 2 * math.pi) * (1 - t);
                  return Transform.scale(scale: s, child: child);
                },
                child: Opacity(
                  // Fade the last 15% of its life so it never clips
                  // ugly — it dissolves, not shrinks into a sliver.
                  opacity: (_arrowScale / 0.15).clamp(0.0, 1.0),
                  child: Image.asset(
                    'assets/arrow2.webp',
                    height: _arrowHeight * _arrowScale,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        // Debug card: everything that lived in the appbar (support,
        // shape demo, pro, sheet previews) plus per-type notification
        // toggles. Empty state only — the appbar keeps logo + wordmark.
        Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(
            color: const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'DEBUG',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 2,
                children: [
                  _DebugBtn(
                    icon: Icons.favorite_border_rounded,
                    label: 'Support',
                    onTap: widget.onSupportSheet,
                  ),
                  _DebugBtn(
                    icon: Icons.auto_awesome_outlined,
                    label: 'Shapes',
                    onTap: widget.onShapeDemo,
                  ),
                  _DebugBtn(
                    icon: Icons.workspace_premium_outlined,
                    label: 'Pro',
                    onTap: widget.onPro,
                  ),
                  _DebugBtn(
                    icon: Icons.card_giftcard_rounded,
                    label: 'Thanks',
                    onTap: widget.onPreviewSheets,
                  ),
                  _DebugBtn(
                    icon: Icons.waving_hand_rounded,
                    label: 'Onboard',
                    onTap: widget.onOnboarding,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Fire-now: post the real notification immediately —
              // proves display + permission + channel without waiting
              // for a wall-clock slot.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DebugBtn(
                    icon: Icons.play_arrow_rounded,
                    label: 'Fire AM',
                    onTap: () =>
                        widget.onToggleNotif?.call('fire_morning'),
                  ),
                  _DebugBtn(
                    icon: Icons.play_arrow_rounded,
                    label: 'Fire PM',
                    onTap: () =>
                        widget.onToggleNotif?.call('fire_night'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildGrid() {
    // One full grid-row height of breathing room between the last
    // sticker row and the brand footer. Mirrors the delegate's cell math
    // (12px side padding, 8px spacing, portrait 0.75 aspect) so it stays
    // exactly a row tall while pinch-zoom changes the column count.
    final screenW = MediaQuery.of(context).size.width;
    final cellW = (screenW - 24 - 8 * (_columns - 1)) / _columns;
    final rowHeight = cellW / 0.75;
    return Scrollbar(
      // Raw pointer tracking drives pinch (arena-proof); tap arena keeps
      // background-tap and double-tap toggle. Scroll locks while pinching.
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _onBackgroundTap,
          onDoubleTap: _onDoubleTap,
          // Live iOS-style zoom: the grid breathes under the fingers around
          // the pinch focal point, then springs home on release.
          child: Transform.scale(
            scale: _liveScale,
            origin: _liveFocal,
            child: CustomScrollView(
              physics: _pinching
                  ? const NeverScrollableScrollPhysics()
                  : null,
              controller: widget.controller,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _columns,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      // Portrait cells suit full-body cutouts.
                      childAspectRatio: 0.75,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
            final sticker = widget.stickers[index];
            Widget cell = _StickerCell(
              key: ValueKey(sticker.id),
              sticker: sticker,
              shapeBg: widget.shapeBg,
              shapeScale: widget.shapeScale,
              // Dead in delete mode (but still claims the tap); opens
              // fullscreen otherwise.
              onTap: widget.jiggling ? _swallowTap : () => widget.onTap(sticker),
              // No long-press mid-pinch: a second finger landing means
              // zoom, never delete mode.
              onLongPress: (widget.jiggling || _pinching || _zooming)
                  ? null
                  : () => widget.onEnterJiggle?.call(),
              jiggling: widget.jiggling,
              // Badge taps claim the gesture too, or the background
              // detector would read the delete as tap-away and exit.
              onDelete: () {
                _swallowTap();
                widget.onDelete?.call(sticker);
              },
            );
            // Delete mode: shake every sticker.
            if (widget.jiggling) {
              cell = _JiggleTick(
                clock: _jiggle,
                active: widget.jiggling,
                phase: index * 0.9,
                child: cell,
              );
            }
            // Fresh-save landing: tick + confetti, no extra bounce —
            // the sticker lands exactly as the flight delivers it.
            if (sticker.id == widget.justAddedId) {
              return _LandingPop(
                key: ValueKey('land-${sticker.id}'),
                onDone: widget.onLanded,
                onTouchdown: widget.onTouchdown,
                child: cell,
              );
            }
            // Fullscreen return: lands clean — no squash, no confetti.
            // (The soft touchdown tick fires from gallery onFlightHome.)
            return cell;
                      },
                      childCount: widget.stickers.length,
                    ),
                  ),
                ),
                // Ever-present brand footer INSIDE the grid: sits right
                // after the last row, scrolls with the content, and its
                // bottom padding keeps it clear of the gallery sheet.
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: rowHeight,
                      bottom: 8 + widget.bottomInset,
                    ),
                    child: _buildEmptyState(),
                  ),
                ),
              ],
            ),
        ),
      ),
      ),
    );
  }
}

class _StickerCell extends StatelessWidget {  final OutfitSticker sticker;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool jiggling;
  final VoidCallback? onDelete;

  /// Solid shape backdrop vs bare cutout art (appbar toggle).
  final bool shapeBg;

  /// Silhouette size relative to the art box (fixed 70%, user-tuned).
  final double shapeScale;

  const _StickerCell({
    super.key,
    required this.sticker,
    required this.onTap,
    this.onLongPress,
    this.jiggling = false,
    this.onDelete,
    this.shapeBg = true,
    this.shapeScale = 0.7,
  });

  @override
  Widget build(BuildContext context) {
    final art = Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      // Hold must NOT shrink the cell: the sticker stays at full size
      // while it starts shaking, minus-badge on top, iOS-style.
      scaleOnPress: false,
      // Every cell is a Hero so taps zoom up to fullscreen. With the
      // shape toggle on: solid dominant-color M3 silhouette with the
      // cutout overflowing it (Pixel "Shape" style). Off: bare cutout.
      child: Hero(
        tag: 'sticker-${sticker.id}',
        // Curved arc instead of the linear default — see
        // stickerFlightTween. Set on both ends of every flight.
        createRectTween: stickerFlightTween,
        child: shapeBg
            ? ShapedSticker(
                imagePath: sticker.imagePath,
                shapeIndex:
                    sticker.shapeIndex ?? fallbackShapeIndex(sticker.id),
                dominantColor:
                    sticker.dominantColor ?? kFallbackStickerColor,
                shapeScale: shapeScale,
              )
            : Image.file(
                File(sticker.imagePath),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
      ),
    );
    if (!jiggling) return art;
    // Delete mode: badge rides on the shaking art. The hit box is
    // anchored INSIDE the cell (hit testing never reaches outside a
    // grid item's box, no matter the clip behavior) — 54px total with
    // the dot tucked near the corner, iOS-style.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        art,
        Positioned(
          top: -11,
          left: -11,
          child: _DeleteBadge(onTap: onDelete),
        ),
      ],
    );
  }
}

/// iOS-style delete badge: 22px visual in a 54px invisible hit target,
/// anchored so the tappable area stays inside the cell bounds.
class _DeleteBadge extends StatelessWidget {
  final VoidCallback? onTap;

  const _DeleteBadge({this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Haptic on touch-DOWN, not on tap: the delete that follows does
      // file IO plus a widget refresh, and a buzz fired after that work
      // reaches the finger late. iOS snaps the badge feedback the
      // instant the finger lands.
      onTapDown: (_) => AppHaptics.tap(),
      onTap: () => onTap?.call(),
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: _BadgeDot(),
      ),
    );
  }
}

class _BadgeDot extends StatelessWidget {
  const _BadgeDot();

  @override
  Widget build(BuildContext context) {
    // iOS jiggle badge: frosted white-gray circle, black minus.
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.55),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.7),
              width: 1,
            ),
          ),
          child: const Icon(Icons.remove, size: 14, color: Colors.black),
        ),
      ),
    ).animate().scale(
          duration: AppMotion.micro,
          curve: AppMotion.appleEase,
          begin: const Offset(0.5, 0.5),
        );
  }
}

/// One shared repeating clock drives every shaking cell; [phase] desyncs
/// them. Transform-only rotation, static when idle or reduced motion.
class _JiggleTick extends StatelessWidget {
  final Animation<double> clock;
  final bool active;
  final double phase;
  final Widget child;

  const _JiggleTick({
    required this.clock,
    required this.active,
    required this.phase,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!active || AppMotion.reducedMotion(context)) return child;
    return AnimatedBuilder(
      animation: clock,
      builder: (context, child) {
        // ±1.6° sine wobble, matching iOS icon jiggle energy.
        final angle = 0.028 *
            math.sin(clock.value * 2 * math.pi + phase);
        return Transform.rotate(angle: angle, child: child);
      },
      child: child,
    );
  }
}

/// Landing tick: sits at scale 1 while the Hero flight is inbound, then
/// (timed to touchdown) plays the haptic tick and reports the landing
/// spot for confetti. No extra bounce — the sticker lands exactly as
/// the preview flight delivers it.
class _LandingPop extends StatefulWidget {
  final Widget child;
  final VoidCallback? onDone;
  final ValueChanged<Offset>? onTouchdown;

  const _LandingPop({
    super.key,
    required this.child,
    this.onDone,
    this.onTouchdown,
  });

  @override
  State<_LandingPop> createState() => _LandingPopState();
}

class _LandingPopState extends State<_LandingPop> {
  @override
  void initState() {
    super.initState();
    // The flight takes kGenieFlight; tick exactly as it lands.
    Future.delayed(kGenieFlight, () {
      if (!mounted) return;
      AppHaptics.land();
      // Report the landing spot so confetti showers from this sticker.
      final box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        widget.onTouchdown?.call(
          box.localToGlobal(box.size.center(Offset.zero)),
        );
      }
      widget.onDone?.call();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Compact debug-card button (empty state): yellow icon + white label.
class _DebugBtn extends StatelessWidget {  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _DebugBtn({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 16, color: const Color(0xFFFFD60A)),
      label: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}
