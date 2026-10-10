import 'package:fitcheck/services/roast_service.dart';
import 'package:fitcheck/services/widget_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('widget rotation pool contract', () {
    test('every line in the library ships as a caption variant', () {
      // The caption turns over every 2h inside a 4h image slot. One
      // variant per line is what lets the widget reach every roast
      // without repeating before the pool wraps — the old contract was
      // a hardcoded 2, so a sticker showed the same pair forever.
      expect(
        WidgetService.captionVariants(isMax: false),
        RoastService.poolSize(isMax: false),
      );
      expect(
        WidgetService.captionVariants(isMax: true),
        RoastService.poolSize(isMax: true),
      );
      expect(RoastService.poolSize(isMax: false), greaterThan(2));
      expect(
        RoastService.poolSize(isMax: true),
        greaterThan(RoastService.poolSize(isMax: false)),
      );
    });

    test('the pool is one blob, keyed the way native reads it', () {
      // Every sticker ships in a single publish: Pro accounts are
      // uncapped, so per-sticker keys would mean hundreds of channel
      // round trips after each save.
      expect(WidgetService.poolKey, 'widget_pool');
    });
  });

  group('widgetCaptionForId (fixed per variant, rotated by native)', () {
    // Caption text is composed in Dart and shipped for every variant,
    // because the 2h turnover has to happen with the app closed.
    test('a sticker walks the whole pool, repeating nothing', () {
      for (int i = 0; i < 120; i++) {
        final id = 'sticker-$i';
        for (final isMax in [false, true]) {
          final total = RoastService.poolSize(isMax: isMax);
          final lines = <String>{
            for (int v = 0; v < total; v++)
              WidgetService.widgetCaptionForId(
                id,
                variant: v,
                isMax: isMax,
              ),
          };
          expect(lines.length, total, reason: '$id isMax=$isMax');
        }
      }
    });

    test('adjacent variants never repeat', () {
      // A same-line pair would show the same caption twice in a row.
      for (int i = 0; i < 300; i++) {
        final id = 'sticker-$i';
        for (final isMax in [false, true]) {
          final total = RoastService.poolSize(isMax: isMax);
          for (int v = 0; v + 1 < total; v++) {
            expect(
              WidgetService.widgetCaptionForId(
                id,
                variant: v,
                isMax: isMax,
              ),
              isNot(
                WidgetService.widgetCaptionForId(
                  id,
                  variant: v + 1,
                  isMax: isMax,
                ),
              ),
              reason: '$id variant $v',
            );
          }
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
          WidgetService.widgetCaptionForId(id, variant: 3, isMax: false),
          WidgetService.widgetCaptionForId(id, variant: 3, isMax: false),
        );
      }
    });

    test('different stickers start on different lines', () {
      // A shared start would put the same caption on every sticker
      // simultaneously.
      final starts = <String>{
        for (int i = 0; i < 200; i++)
          WidgetService.widgetCaptionForId(
            'member-$i',
            variant: 0,
            isMax: false,
          ),
      };
      expect(starts.length, RoastService.poolSize(isMax: false));
    });

    test('Max membership changes the pool of lines', () {
      // isMax rides the pool signature, so a purchase republishes the
      // captions even though the sticker ids did not change.
      int differing = 0;
      for (int i = 0; i < 200; i++) {
        final id = 'member-$i';
        if (WidgetService.widgetCaptionForId(id, variant: 0, isMax: false) !=
            WidgetService.widgetCaptionForId(id, variant: 0, isMax: true)) {
          differing++;
        }
      }
      expect(differing, greaterThan(100));
    });

    test('a variant past the pool wraps rather than returning empty', () {
      // Native clamps with floorMod, so this never happens at runtime —
      // but it must not blank the caption if it ever did.
      final id = 'clamp-me';
      final total = RoastService.poolSize(isMax: false);
      expect(
        WidgetService.widgetCaptionForId(id, variant: total, isMax: false),
        WidgetService.widgetCaptionForId(id, variant: 0, isMax: false),
      );
    });
  });

  group('roastForId stays byte-stable', () {
    test('the pick is still the salted hash, indexed into the tier pool', () {
      // lineAt() replaced the inline index maths inside roastForId. If
      // that shifted a single index, every saved sticker's in-app
      // caption would reshuffle on an unrelated edit.
      for (int i = 0; i < 200; i++) {
        final id = 'roast-$i';
        for (final isMax in [false, true]) {
          for (var salt = 0; salt < 5; salt++) {
            expect(
              RoastService.roastForId(id, salt: salt, isMax: isMax),
              RoastService.lineAt((id.hashCode ^ salt).abs(), isMax: isMax),
              reason: '$id salt=$salt',
            );
          }
        }
      }
    });

    test('lineAt is a stable ordering with free lines first', () {
      // Index 0..free-1 must not move when Max exists, or a free
      // sticker's line would change the moment someone subscribes.
      final free = RoastService.poolSize(isMax: false);
      for (int i = 0; i < free; i++) {
        expect(
          RoastService.lineAt(i, isMax: false),
          RoastService.lineAt(i, isMax: true),
          reason: 'free index $i',
        );
      }
      // Past the free pool the two tiers intentionally diverge: Max
      // keeps walking into the member lines instead of wrapping.
      expect(
        RoastService.lineAt(free, isMax: true),
        isNot(RoastService.lineAt(0, isMax: false)),
      );
    });

    test('no line is blank or duplicated in either tier', () {
      for (final isMax in [false, true]) {
        final total = RoastService.poolSize(isMax: isMax);
        final seen = <String>{};
        for (int i = 0; i < total; i++) {
          final line = RoastService.lineAt(i, isMax: isMax);
          expect(line.trim(), isNotEmpty, reason: 'index $i');
          expect(seen.add(line), isTrue, reason: 'duplicate at index $i');
        }
        expect(seen.length, total, reason: 'isMax=$isMax');
      }
    });
  });
}