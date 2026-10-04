import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';

/// The footer control: a chevron that idles in a playful hop, morphs
/// to a `+` every 3s, and launches the system gallery picker on tap or
/// upward drag. Static under reduced motion.
///
/// [dragOffset] lets the owning footer drive the drag (the strip rides
/// the finger); left at 0 the chevron tracks its own vertical drag.
class BounceChevron extends StatefulWidget {
  final VoidCallback onLaunch;

  /// Chevron edge length. The footer passes a large one.
  final double size;

  /// Upward travel applied by the footer's swipe.
  final double dragOffset;

  const BounceChevron({
    super.key,
    required this.onLaunch,
    this.size = 44,
    this.dragOffset = 0,
  });

  @override
  State<BounceChevron> createState() => _BounceChevronState();
}

class _BounceChevronState extends State<BounceChevron>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  /// Alternates ^ / + every 3s so the affordance reads both "pull up"
  /// and "add".
  bool _plus = false;
  Timer? _morph;

  /// Own vertical drag (only used when the footer isn't driving).
  double _dragDy = 0.0;
  bool _dragging = false;

  /// Accumulated upward travel since the last scroll tick. A tick
  /// fires every [_tickStep] px for a ratchet feel while dragging.
  double _hapticAccum = 0.0;
  static const double _tickStep = 28.0;

  bool get _footerDriven => widget.dragOffset != 0.0;

  /// The offset actually applied: footer's when it drives, else ours.
  double get _drag => _footerDriven ? widget.dragOffset : _dragDy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || AppMotion.reducedMotion(context)) return;
      _morph = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) setState(() => _plus = !_plus);
      });
    });
  }

  @override
  void dispose() {
    _morph?.cancel();
    _hop.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_footerDriven) return;
    setState(() {
      _dragging = true;
      // Only upward travel; clamped so it can't be yanked off-screen.
      _dragDy = (_dragDy + d.delta.dy).clamp(-140.0, 0.0);
    });
    // Scroll ticks: one per step of upward travel (light impact — a
    // clear step up from the selection tick).
    _hapticAccum += -d.delta.dy;
    while (_hapticAccum >= _tickStep) {
      _hapticAccum -= _tickStep;
      AppHaptics.tap();
    }
    if (_hapticAccum < 0) _hapticAccum = 0;
  }

  void _onDragEnd(DragEndDetails d) {
    if (_footerDriven) return;
    final fling = d.velocity.pixelsPerSecond.dy;
    final launched = _dragDy < -60 || fling < -300;
    setState(() {
      _dragging = false;
      _dragDy = 0.0;
    });
    _hapticAccum = 0;
    if (launched) {
      AppHaptics.launch();
      widget.onLaunch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chevron = AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: Icon(
        _plus ? Icons.add_rounded : Icons.keyboard_arrow_up_rounded,
        key: ValueKey(_plus),
        size: widget.size,
        color: Colors.white.withValues(alpha: 0.85),
        shadows: const [
          Shadow(color: Colors.black54, blurRadius: 8),
        ],
      ),
    );
    final gesture = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        AppHaptics.launch();
        widget.onLaunch();
      },
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: Transform.translate(
        offset: Offset(0, _drag),
        child: Opacity(
          // Dissolves as it nears the launch threshold — the pull
          // visibly commits before the picker takes over.
          opacity: (1.0 + _drag / 140).clamp(0.35, 1.0),
          child: chevron,
        ),
      ),
    );
    if (_dragging || AppMotion.reducedMotion(context)) return gesture;
    return AnimatedBuilder(
      animation: _hop,
      builder: (context, _) {
        // Hop, squash, rest: airborne for the first ~40% of the loop,
        // lounging the rest so it reads playful, not urgent.
        final t = (_hop.value / 0.4).clamp(0.0, 1.0);
        final lift = -12.0 * math.sin(t * math.pi);
        final squash = 1.0 - 0.10 * math.sin(t * math.pi);
        return Transform.translate(
          offset: Offset(0, lift),
          child: Transform.scale(
            scaleX: 2.0 - squash,
            scaleY: squash,
            child: gesture,
          ),
        );
      },
    );
  }
}