import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_m3shapes/flutter_m3shapes.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// Per-sticker visual style derived from the source image with the M3
/// theming engine — the same quantizer + scorer that powers Material You.
/// The dominant color fills the shape card; the shape itself is derived
/// deterministically from the image path so it is identical from the
/// first frame of the preview through the grid cell and fullscreen —
/// the silhouette never switches mid-flow.
class StickerStyle {
  /// Dominant image color (ARGB).
  final int dominantColor;

  /// Index into [kStyleShapes].
  final int shapeIndex;

  const StickerStyle({required this.dominantColor, required this.shapeIndex});
}

/// Shape palette ordered around the HCT hue wheel (0 -> 360): warm hues
/// get spiky/playful silhouettes, cool hues round ones, greens the
/// botanicals. Index = floor(hue / 360 * length).
///
/// Append-only: shapeIndex is persisted per sticker, so existing entries
/// (0-9) must never shift. New M3E shapes go at the end.
final List<Shapes> kStyleShapes = [
  Shapes.gem, //            reds & warm oranges
  Shapes.c12_sided_cookie, // ambers
  Shapes.sunny, //          yellows
  Shapes.flower, //         limes & greens
  Shapes.pentagon, //       teals
  Shapes.oval, //           cyans
  Shapes.pill, //           blues
  Shapes.arch, //           indigos
  Shapes.diamond, //        purples
  Shapes.slanted, //        magentas & pinks
  // ---- full M3E set (appended; order = Shapes enum order) ----
  Shapes.circle,
  Shapes.square,
  Shapes.semicircle,
  Shapes.triangle,
  Shapes.arrow,
  Shapes.fan,
  Shapes.very_sunny,
  Shapes.c4_sided_cookie,
  Shapes.c6_sided_cookie,
  Shapes.c7_sided_cookie,
  Shapes.c9_sided_cookie,
  Shapes.l4_leaf_clover,
  Shapes.l8_leaf_clover,
  Shapes.burst,
  Shapes.soft_burst,
  Shapes.boom,
  Shapes.soft_boom,
  Shapes.puffy,
  Shapes.puffy_diamond,
  Shapes.ghostish,
  Shapes.pixel_circle,
  Shapes.pixel_triangle,
  Shapes.bun,
  Shapes.hearth,
];

/// Neutral fallback for images the scorer rejects (pure grayscale etc.).
const int kFallbackStickerColor = 0xFF606060;

/// Deterministic shape for stickers without a stored style.
int fallbackShapeIndex(String id) => id.hashCode.abs() % kStyleShapes.length;

/// Stable RANDOM shape for a gallery photo: seeded by the photo's
/// asset id, so it looks random but never flickers while scrolling —
/// and the sheet thumb matches the shape the sticker will get when
/// that photo is picked. The fullscreen view re-rolls fresh shapes.
int randomShapeIndexForAsset(String assetId) =>
    math.Random(assetId.hashCode).nextInt(kStyleShapes.length);

class StickerStyleService {
  StickerStyleService._();

  /// Extracts the dominant color (M3 quantizer + scorer) from a 64px
  /// thumbnail. The shape is NOT derived from the color — it stays the
  /// deterministic path-hash shape so nothing changes mid-view. Never
  /// throws: falls back to a neutral style on any decode/quantize failure.
  static Future<StickerStyle> analyze(String imagePath) async {
    final shapeIndex = fallbackShapeIndex(imagePath);
    const neutralColor = kFallbackStickerColor;
    try {
      final data = await ui.ImmutableBuffer.fromUint8List(
        await File(imagePath).readAsBytes(),
      );
      final codec = await ui.instantiateImageCodecFromBuffer(
        data,
        targetWidth: 64,
        targetHeight: 64,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (bytes == null) {
        return StickerStyle(dominantColor: neutralColor, shapeIndex: shapeIndex);
      }

      // rawRgba bytes -> ARGB ints for the quantizer (it expects
      // 0xAARRGGBB). Fully transparent pixels (cutout padding) are
      // skipped so they can't win as "dominant black".
      final rgba = bytes.buffer.asUint8List();
      final pixels = <int>[];
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        if (rgba[i + 3] < 16) continue;
        pixels.add(
          0xFF000000 | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2],
        );
      }
      if (pixels.isEmpty) {
        return StickerStyle(dominantColor: neutralColor, shapeIndex: shapeIndex);
      }

      final quantizer = await QuantizerCelebi().quantize(pixels, 64);
      final colorToCount = quantizer.colorToCount;
      if (colorToCount.isEmpty) {
        return StickerStyle(dominantColor: neutralColor, shapeIndex: shapeIndex);
      }

      // The scorer wants the population map directly; it always returns
      // at least one color (falls back to Google Blue internally).
      final dominant = Score.score(colorToCount).first;

      return StickerStyle(dominantColor: dominant, shapeIndex: shapeIndex);
    } catch (_) {
      return StickerStyle(
        dominantColor: kFallbackStickerColor,
        shapeIndex: fallbackShapeIndex(imagePath),
      );
    }
  }

  /// Dominant color (same quantizer + scorer as [analyze]) from an
  /// ALREADY-decoded image — for batches, where decoding a second time
  /// per image would cost more than the analysis. Only a sparse sample
  /// of pixels is fed to the quantizer; the palette it needs is the
  /// same. Never throws: falls back to the neutral color.
  static Future<int> dominantColorOf(ui.Image image) async {
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return kFallbackStickerColor;
      final rgba = bytes.buffer.asUint8List();
      // Every 4th pixel in each axis (~1/16 of them), skipping the fully
      // transparent cutout padding so it can't win as "dominant black".
      const step = 4;
      final pixels = <int>[];
      for (var y = 0; y < image.height; y += step) {
        for (var x = 0; x < image.width; x += step) {
          final i = (y * image.width + x) * 4;
          if (i + 3 >= rgba.length) break;
          if (rgba[i + 3] < 16) continue;
          pixels.add(
            0xFF000000 | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2],
          );
        }
      }
      if (pixels.isEmpty) return kFallbackStickerColor;
      final quantizer = await QuantizerCelebi().quantize(pixels, 64);
      final colorToCount = quantizer.colorToCount;
      if (colorToCount.isEmpty) return kFallbackStickerColor;
      return Score.score(colorToCount).first;
    } catch (_) {
      return kFallbackStickerColor;
    }
  }
}
