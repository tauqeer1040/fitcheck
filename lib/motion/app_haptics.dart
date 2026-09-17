import 'package:flutter/services.dart';

/// Haptic vocabulary: every moment speaks exactly once, never spams.
/// Call sites use these — never raw [HapticFeedback] — so intensity stays
/// consistent and double-fires are easy to spot in review.
abstract final class AppHaptics {
  /// Any button / thumbnail / row tap.
  static void tap() => HapticFeedback.lightImpact();

  /// Discrete steps: pinch zoom levels, sheet snap points.
  static void step() => HapticFeedback.selectionClick();

  /// Flick launch: sticker kicked off-screen.
  static void launch() => HapticFeedback.mediumImpact();

  /// Touchdown: sticker lands in its grid slot.
  static void land() => HapticFeedback.lightImpact();

  /// Mode changes: entering / exiting jiggle-delete.
  static void mode() => HapticFeedback.mediumImpact();

  /// Milestones only (first sticker ever). Heavy by design.
  static void milestone() => HapticFeedback.heavyImpact();
}
