import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';

/// Soft M3 shadow that lives behind the StickerPants wordmark while the
/// cell backdrops are toggled on: same height as the image, narrower,
/// centered, slightly dropped. A blurred black silhouette (not a flat
/// chip) so it reads as a shadow, not a badge.
class WordmarkShadow extends StatelessWidget {
  final double height;
  final Shapes shape;

  /// Width ratio relative to [height] (wordmark is ~2:1, shadow stays
  /// slimmer than the image).
  final double widthRatio;

  const WordmarkShadow({
    super.key,
    required this.height,
    required this.shape,
    this.widthRatio = 0.62,
  });

  @override
  Widget build(BuildContext context) {
    final w = height * widthRatio;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Transform.translate(
        offset: const Offset(2, 5),
        child: M3Container(
          shape,
          width: w,
          height: height,
          color: Colors.black.withValues(alpha: 0.55),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
