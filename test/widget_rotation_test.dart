import 'package:fitcheck/services/widget_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('widget rotation pool contract', () {
    test('caption turns over twice per image slot', () {
      // 2h captions inside 4h image slots: the line changes mid-slot
      // while the sticker stays put.
      expect(WidgetService.captionVariants, 2);
      expect(WidgetService.captionVariants * 2, 4);
    });

    test('the pool is one blob, keyed the way native reads it', () {
      // Every sticker ships in a single publish: Pro accounts are
      // uncapped, so per-sticker keys would mean hundreds of channel
      // round trips after each save.
      expect(WidgetService.poolKey, 'widget_pool');
    });
  });

  group('captionForId (fixed per variant, rotated by native)', () {
    // Caption text is composed in Dart and shipped for both variants,
    // because the 2h turnover has to happen with the app closed. So the
    // two variants must differ — a same-line pair would show the same
    // line twice in a row, which is what the salt nudge guards.
    test('variants never collide across a spread of sticker ids', () {
      for (int i = 0; i < 400; i++) {
        final id = 'sticker-$i';
        for (final isMax in [false, true]) {
          final a = WidgetService.captionForId(
            id,
            variant: 0,
            isMax: isMax,
          );
          final b = WidgetService.captionForId(
            id,
            variant: 1,
            isMax: isMax,
          );
          expect(a, isNotEmpty, reason: id);
          expect(b, isNotEmpty, reason: id);
          expect(a, isNot(b), reason: '$id variant collision');
        }
      }
    });

    test('a variant is stable across repeated pushes', () {
      // Dart only rewrites the pool when its signature changes; the
      // stored line must therefore be byte-identical next time, or the
      // caption would shuffle on an unrelated save.
      for (int i = 0; i < 50; i++) {
        final id = 'stable-$i';
        expect(
          WidgetService.captionForId(id, variant: 1, isMax: false),
          WidgetService.captionForId(id, variant: 1, isMax: false),
        );
      }
    });

    test('any positive variant is the same alternate line', () {
      // Native clamps to 0..count-1 (floorMod over caption_variants), so
      // a larger index never reaches Dart at runtime — but if it ever
      // did, it must not silently become a third line nothing maps to.
      final id = 'clamp-me';
      final alt = WidgetService.captionForId(id, variant: 1, isMax: false);
      for (final v in [2, 7, 99]) {
        expect(
          WidgetService.captionForId(id, variant: v, isMax: false),
          alt,
          reason: 'variant $v',
        );
      }
    });

    test('Max membership changes the pool of lines', () {
      // isMax rides the pool signature, so a purchase republishes the
      // captions even though the sticker ids did not change.
      int differing = 0;
      for (int i = 0; i < 200; i++) {
        final id = 'member-$i';
        if (WidgetService.captionForId(id, variant: 0, isMax: false) !=
            WidgetService.captionForId(id, variant: 0, isMax: true)) {
          differing++;
        }
      }
      expect(differing, greaterThan(100));
    });
  });
}