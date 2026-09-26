import 'package:shared_preferences/shared_preferences.dart';

/// Per-question sticker-shape unlocks from onboarding.
///
/// Each answered question unlocks one M3 shape (index into
/// [kStyleShapes]). The unlock is visual today (the flip chip + copy)
/// and persisted so kills/resumes never lose it; a future shape-picker
/// gate can read [unlockedShapes] to enforce it.
class ShapeUnlockService {
  ShapeUnlockService._();

  static String keyFor(int shapeIndex) => 'unlocked_shape_$shapeIndex';

  static Future<bool> isUnlocked(int shapeIndex) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(keyFor(shapeIndex)) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Idempotent: unlocking twice is a no-op.
  static Future<void> unlockShape(int shapeIndex) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyFor(shapeIndex), true);
    } catch (_) {}
  }

  static Future<Set<int>> unlockedShapes(List<int> candidates) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return {
        for (final i in candidates)
          if (prefs.getBool(keyFor(i)) ?? false) i,
      };
    } catch (_) {
      return {};
    }
  }
}
