import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'app_haptics.dart';

/// Single source of truth for FitCheck motion, per Apple HIG spring
/// physics: springs over fixed easing, transform/opacity only, every
/// action answered with visual + haptic feedback.
abstract final class AppMotion {
  /// Apple interactive spring (tap feedback, micro-interactions).
  static const tapSpring = SpringDescription(
    mass: 1,
    stiffness: 350,
    damping: 35,
  );

  /// Sheet / modal spring (bottom-sheet snaps).
  static const sheetSpring = SpringDescription(
    mass: 1.2,
    stiffness: 280,
    damping: 28,
  );

  /// Sticker lift spring (springy hover rise).
  static const liftSpring = SpringDescription(
    mass: 1,
    stiffness: 200,
    damping: 14,
  );

  /// Apple ease for fixed-duration tweens: cubic-bezier(0.25, 1, 0.5, 1).
  static const appleEase = Cubic(0.25, 1, 0.5, 1);

  /// Pressed-state scale for every tappable (HIG active feedback).
  static const double pressScale = 0.97;

  /// Duration tiers.
  static const micro = Duration(milliseconds: 105);
  static const standard = Duration(milliseconds: 210);

  /// True when the OS asks us to reduce motion: springs degrade to fades.
  static bool reducedMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// Standard entrance: fade + gentle rise. Instant when reduced motion.
  static Widget entrance(BuildContext context, Widget child) {
    if (reducedMotion(context)) return child;
    return child
        .animate()
        .fadeIn(duration: standard, curve: appleEase)
        .slideY(begin: 0.3, end: 0, duration: standard, curve: appleEase);
  }
}

/// Every tappable in the app. Press-down shrinks to [AppMotion.pressScale]
/// (transform-only, HIG active feedback); release fires one haptic + onTap.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const Pressable({super.key, required this.child, this.onTap, this.onLongPress});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap == null
          ? null
          : () {
              AppHaptics.tap();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? AppMotion.pressScale : 1.0,
        duration: AppMotion.micro,
        curve: AppMotion.appleEase,
        child: widget.child,
      ),
    );
  }
}
