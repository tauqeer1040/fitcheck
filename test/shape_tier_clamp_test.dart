import 'package:fitcheck/services/sticker_style_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shape cap was enforced in exactly one function
/// ([fallbackShapeIndex]), so every path that assigned an index
/// directly — the gallery cycler, the onboarding reveals, and any
/// shape stored while Max — could render above the free cap. These
/// lock the render-time clamp that replaced it.
void main() {
  final palette = kStyleShapes.length;

  group('shapeCountForTier', () {
    test('free accounts get the capped count, Max the whole palette', () {
      expect(shapeCountForTier(isMax: false), kFreeShapeCount);
      expect(shapeCountForTier(isMax: true), palette);
    });

    test('the cap is a real subset', () {
      expect(kFreeShapeCount, lessThan(palette));
    });
  });

  group('shapeIndexForTier', () {
    test('free accounts can never be handed a shape past the cap', () {
      for (int i = 0; i < palette * 3; i++) {
        expect(
          shapeIndexForTier(i, isMax: false),
          inInclusiveRange(0, kFreeShapeCount - 1),
          reason: 'index $i',
        );
      }
    });

    test('Max accounts reach the whole palette', () {
      final seen = <int>{
        for (int i = 0; i < palette; i++) shapeIndexForTier(i, isMax: true),
      };
      expect(seen.length, palette, reason: 'every shape must be reachable');
    });

    test('an index stored while Max rolls into the free set on downgrade', () {
      // 20 is only reachable as Max. A cancelled account must not keep
      // rendering it.
      const storedWhileMax = 20;
      expect(storedWhileMax, greaterThanOrEqualTo(kFreeShapeCount));
      expect(shapeIndexForTier(storedWhileMax, isMax: true), storedWhileMax);
      expect(
        shapeIndexForTier(storedWhileMax, isMax: false),
        storedWhileMax % kFreeShapeCount,
      );
    });

    test('it wraps rather than pinning to the last shape', () {
      // Truncating would pile every over-cap index onto kFreeShapeCount-1
      // and flatten the bottom half of the palette out of use.
      final freeSeen = <int>{
        for (int i = 0; i < palette; i++)
          shapeIndexForTier(i, isMax: false),
      };
      expect(freeSeen.length, kFreeShapeCount);
    });

    test('out-of-range input cannot throw or index past the array', () {
      for (final i in [-1, -palette, palette, palette * 7, 9999]) {
        for (final isMax in [false, true]) {
          final got = shapeIndexForTier(i, isMax: isMax);
          expect(got, inInclusiveRange(0, palette - 1), reason: '$i');
        }
      }
    });

    test('the free branch keeps its first 15 identities', () {
      // A clamp must not reshuffle what free accounts already see.
      for (int i = 0; i < kFreeShapeCount; i++) {
        expect(shapeIndexForTier(i, isMax: false), i, reason: 'index $i');
      }
    });
  });

  group('native silhouette contract', () {
    test('every index the clamp can emit is one native can draw', () {
      // WidgetShapes.shapeNameForIndex (Kotlin) handles 0..33 and falls
      // back to "cookie" for anything else. If kStyleShapes ever grows
      // past 34, the widget would silently render a plain cookie for the
      // new shapes while the grid drew them correctly — the two surfaces
      // the clamp exists to keep in sync.
      expect(palette, 34, reason: 'native shapeNameForIndex handles 0..33');
      for (final isMax in [false, true]) {
        for (int i = 0; i < palette * 2; i++) {
          expect(
            shapeIndexForTier(i, isMax: isMax),
            inInclusiveRange(0, palette - 1),
            reason: 'index $i isMax=$isMax',
          );
        }
      }
    });

    test('a sticker with no stored shape still lands in the free set', () {
      // Legacy stickers carry shapeIndex == null, so the grid and the
      // widget both fall through to the hash. That path must clamp too.
      for (int i = 0; i < 60; i++) {
        expect(
          shapeIndexForTier(fallbackShapeIndex('nostyle-$i')),
          inInclusiveRange(0, kFreeShapeCount - 1),
          reason: 'nostyle-$i',
        );
      }
    });

    test('the hash fallback stays deterministic per id', () {
      for (int i = 0; i < 40; i++) {
        final id = 'stable-$i';
        expect(fallbackShapeIndex(id), fallbackShapeIndex(id));
      }
    });
  });
}