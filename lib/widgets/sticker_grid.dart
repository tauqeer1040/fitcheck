import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/outfit_sticker.dart';
import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import 'genie_flight.dart';

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

  /// Id of the sticker flying home: its cell hosts the Hero destination
  /// and plays the landing pop. Null for everyone else.
  final String? justAddedId;

  /// Fired after the landing pop finishes so the parent can clear the tag.
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

  static const int defaultColumns = 5;
  static const int minColumns = 3;
  static const int maxColumns = 6;

  const StickerGrid({
    super.key,
    required this.stickers,
    required this.onTap,
    this.controller,
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
        AppHaptics.step();
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
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.checkroom, size: 80, color: Colors.grey.shade700),
            const SizedBox(height: 16),
            Text(
              'No outfit stickers yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Pick a photo below to add your first outfit',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      );
    }

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
            child: GridView.builder(
              physics: _pinching
                  ? const NeverScrollableScrollPhysics()
                  : null,
          controller: widget.controller,
          padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + widget.bottomInset),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            // Portrait cells suit full-body cutouts; partial last rows
            // stay left-aligned by the grid.
            childAspectRatio: 0.75,
          ),
          itemCount: widget.stickers.length,
          itemBuilder: (context, index) {
            final sticker = widget.stickers[index];
            Widget cell = _StickerCell(
              key: ValueKey(sticker.id),
              sticker: sticker,
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
            // Fresh-save landing: full celebration (pop + tick + confetti).
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

  const _StickerCell({
    super.key,
    required this.sticker,
    required this.onTap,
    this.onLongPress,
    this.jiggling = false,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final art = Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      // No decoration, no border, no bg — baked white ring included.
      // Every cell is a Hero so taps zoom up to fullscreen.
      child: Hero(
        tag: 'sticker-${sticker.id}',
        child: Image.file(
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
      onTap: () {
        AppHaptics.tap();
        onTap?.call();
      },
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

/// Landing impact: sits at scale 1 while the Hero flight is inbound, then
/// (timed to touchdown) plays a squash-and-spring pop with a haptic tick.
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

class _LandingPopState extends State<_LandingPop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 315),
  );

  @override
  void initState() {
    super.initState();
    _pop.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone?.call();
    });
    // The flight takes kGenieFlight; pop exactly as it lands.
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
      _pop.forward(from: 0.0);
    });
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pop,
      builder: (context, child) {
        // 1.0 while waiting, squash to 0.55 on impact, elastic back to 1.
        final scale = _pop.isDismissed
            ? 1.0
            : 0.55 + 0.45 * Curves.elasticOut.transform(_pop.value);
        return Transform.scale(scale: scale, child: child);
      },
      child: widget.child,
    );
  }
}
