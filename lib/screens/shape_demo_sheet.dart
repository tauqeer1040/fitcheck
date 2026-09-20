import 'package:flutter/material.dart';

import '../motion/app_haptics.dart';
import '../widgets/morphing_shape_clip.dart';

/// Demo overlay: the app logo endlessly morphing through the M3E
/// refresh shape sequence with global rotation. Controllers live and
/// die with this sheet — closing it stops all motion.
Future<void> showShapeDemo(BuildContext context) {
  AppHaptics.tap();
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _ShapeDemoSheet(),
  );
}

class _ShapeDemoSheet extends StatelessWidget {
  const _ShapeDemoSheet();

  static const _names = [
    'softBurst',
    'cookie9',
    'gem',
    'sunny',
    'cookie4',
    'oval',
    'cookie12',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'M3E Shape Demo',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _names.join(' → '),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 24),
          const SizedBox(
            width: 260,
            height: 260,
            child: MorphingShapeClip(
              child: Image(
                image: AssetImage('assets/logo3.png'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '845ms morphs · full rotation every 6.1s',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFFD60A),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(
                horizontal: 32,
                vertical: 14,
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w800),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
