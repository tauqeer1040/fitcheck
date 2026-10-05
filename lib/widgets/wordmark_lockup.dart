import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../services/sticker_style_service.dart';
import 'wordmark_shadow.dart';

/// Live tuning for the gallery appbar, driven by the debug card's
/// sliders. Plain heights in pt (the status inset is added on top by
/// the caller) — one channel shared by the bar and the lab.
class AppbarTuning {
  AppbarTuning._();

  /// Bar content height (logo row). The mark can be taller than this —
  /// it's painted outside the row, the bar itself stays short.
  static final ValueNotifier<double> height =
      ValueNotifier<double>(40.0);

  /// Mark box side. Just over one grid cell (71) so the lockup reads
  /// as a touch more prominent than the stickers below it.
  static final ValueNotifier<double> logo = ValueNotifier<double>(75.0);

  /// Horizontal side padding. Default matches the grid's gutters.
  static final ValueNotifier<double> padding =
      ValueNotifier<double>(12.0);

  static void reset() {
    height.value = 40.0;
    logo.value = 75.0;
    padding.value = 12.0;
  }
}

/// Live tuning for the lockup's backing shape, driven by the debug
/// card's sliders. Multipliers, so 1.0 is the shipped look and both
/// the appbar and the placeholder stay in lockstep — there is one
/// channel, not two independent settings.
class WordmarkTuning {
  WordmarkTuning._();

  /// Shadow width relative to its height (1.0 = square).
  static final ValueNotifier<double> widthRatio =
      ValueNotifier<double>(1.0);

  /// Shadow height relative to the wordmark art's height (1.0 = equal).
  static final ValueNotifier<double> heightScale =
      ValueNotifier<double>(1.0);

  static void reset() {
    widthRatio.value = 1.0;
    heightScale.value = 1.0;
  }
}

/// The StickerPants lockup: the wordmark image over its M3 shape
/// shadow, as ONE component. Both the appbar and the placeholder use
/// this — same construction, same shape and color, only the size
/// differs.
class WordmarkLockup extends StatelessWidget {
  /// Wordmark art: the Max lockup for subscribers, the standard one
  /// for everyone else.
  final bool isMax;

  /// Rendered height of the wordmark art.
  final double imageHeight;

  /// Rendered height of the shape shadow behind it.
  final double shadowHeight;

  /// Shadow width relative to its height (1.0 = square).
  final double shadowWidthRatio;

  /// Index into [kStyleShapes] for the shadow silhouette.
  final int shapeIndex;

  /// ARGB fill of the shadow (the user's own sticker palette).
  final int color;

  /// Shadow visibility. The shape/color toggle drives this: off hides
  /// the backing shape behind the wordmark, leaving the art alone.
  final bool shadowVisible;

  const WordmarkLockup({
    super.key,
    this.isMax = false,
    this.imageHeight = 57,
    this.shadowHeight = 57,
    this.shadowWidthRatio = 1.0,
    this.shapeIndex = 7,
    this.color = 0xFFFFD60A,
    this.shadowVisible = true,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedOpacity(
          opacity: shadowVisible ? 1.0 : 0.0,
          duration: AppMotion.standard,
          // Listens to the debug card's sliders so a drag reshapes the
          // backing shape live, in both the appbar and the placeholder.
          child: ValueListenableBuilder<double>(
            valueListenable: WordmarkTuning.heightScale,
            builder: (context, hScale, _) {
              return ValueListenableBuilder<double>(
                valueListenable: WordmarkTuning.widthRatio,
                builder: (context, wRatio, _) {
                  return WordmarkShadow(
                    height: shadowHeight * hScale,
                    shape: kStyleShapes[
                        shapeIndex.clamp(0, kStyleShapes.length - 1)],
                    color: color,
                    widthRatio: shadowWidthRatio * wRatio,
                  );
                },
              );
            },
          ),
        ),
        Image.asset(
          isMax ? 'assets/stickerpantsmax.webp' : 'assets/stickerpants.webp',
          height: imageHeight,
          fit: BoxFit.contain,
        ),
      ],
    );
  }
}
