import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitcheck/main.dart';
import 'package:fitcheck/models/outfit_sticker.dart';
import 'package:fitcheck/screens/splash_screen.dart';
import 'package:fitcheck/services/roast_service.dart';

void main() {
  testWidgets('App renders splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const FitCheckApp());
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(SplashScreen), findsOneWidget);
    // Flush the splash's nav timer so no Timer is pending at teardown.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  group('RoastService house rules', () {
    OutfitSticker sticker(String id) => OutfitSticker(
          id: id,
          imagePath: '/tmp/x.png',
          createdAt: DateTime(2026, 9, 21),
        );

    test('roast is deterministic per sticker and salt', () {
      expect(RoastService.roastFor(sticker('a')),
          RoastService.roastFor(sticker('a')));
      expect(RoastService.roastFor(sticker('a')),
          isNot(RoastService.roastFor(sticker('b'))));
    });

    test('refresh salt rotates the line', () {
      final lines = {
        for (var s = 0; s < RoastService.count; s++)
          RoastService.roastFor(sticker('a'), salt: s),
      };
      expect(lines.length, greaterThan(1));
    });

    test('no line mentions the body', () {
      const banned = [
        'weight', 'fat', 'ugly', 'body', 'skin', 'diet', 'flab',
        'thigh', 'belly', 'age', 'old', 'wrinkl',
      ];
      final patterns = {
        for (final word in banned) word: RegExp('\\b$word\\w*\\b'),
      };
      for (var s = 0; s < RoastService.count; s++) {
        final line =
            RoastService.roastFor(sticker('probe'), salt: s).toLowerCase();
        patterns.forEach((word, pattern) {
          expect(pattern.hasMatch(line), isFalse,
              reason: 'Roast line mentions the body ("$word"): "$line"');
        });
      }
    });
  });
}
