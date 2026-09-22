import 'package:flutter/material.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';

/// Solid M3 silhouette behind the StickerPants wordmark: a square the
/// same height as the image, centered. The color cycles through the
/// user's own sticker shades (dominant colors) on every toggle —
/// personal palette, same construction as sticker backs.
class WordmarkShadow extends StatelessWidget {
  final double height;
  final Shapes shape;
  final int color;

  /// Width ratio relative to [height] (1.0 = square; the shadow reads
  /// as a solid M3 tile behind the ~2:1 wordmark).
  final double widthRatio;

  const WordmarkShadow({
    super.key,
    required this.height,
    required this.shape,
    required this.color,
    this.widthRatio = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return M3Container(
      shape,
      width: height * widthRatio,
      height: height,
      color: Color(color),
      child: const SizedBox.expand(),
    );
  }
}
