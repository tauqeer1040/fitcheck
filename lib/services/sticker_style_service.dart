import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_m3shapes/flutter_m3shapes.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'revenuecat_service.dart';

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

/// Free-tier shape cap: 15 of the M3 silhouettes. Max members wear the
/// whole set; everyone else draws from the first 15 — new stickers,
/// thumbs, and reveals alike. Stored stickers keep whatever they have.
const int kFreeShapeCount = 15;

/// Deterministic shape for stickers without a stored style.
int fallbackShapeIndex(String id) {
  final i = id.hashCode.abs() % kStyleShapes.length;
  if (RevenueCatService.instance.isPro) return i;
  return i % kFreeShapeCount;
}

/// Stable RANDOM shape for a gallery photo: seeded by the photo's
/// asset id, so it looks random but never flickers while scrolling —
/// and the sheet thumb matches the shape the sticker will get when
/// that photo is picked. The fullscreen view re-rolls fresh shapes.
int randomShapeIndexForAsset(String assetId) {
  final i = math.Random(assetId.hashCode).nextInt(kStyleShapes.length);
  if (RevenueCatService.instance.isPro) return i;
  return i % kFreeShapeCount;
}

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
        return StickerStyle(
          dominantColor: neutralColor,
          shapeIndex: shapeIndex,
        );
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
        return StickerStyle(
          dominantColor: neutralColor,
          shapeIndex: shapeIndex,
        );
      }

      final quantizer = await QuantizerCelebi().quantize(pixels, 64);
      final colorToCount = quantizer.colorToCount;
      if (colorToCount.isEmpty) {
        return StickerStyle(
          dominantColor: neutralColor,
          shapeIndex: shapeIndex,
        );
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

  /// Readable text color for copy sitting on [background], profiled from
  /// the IMAGE the same way the wash is: the M3 tonal palette for the
  /// photo's hue, then the most COLORFUL tone of that palette which still
  /// clears WCAG AA (4.5:1) against the color actually on screen.
  ///
  /// The M3 on-color rule on its own (tone 0 for a light key, tone 100 for
  /// a dark one) always lands on near-black or near-white, which is why the
  /// copy kept reading as plain black/white: those are the only tones the
  /// rule ever considers. Same palette, but searched for a tone with real
  /// chroma in it — so a photo's own teal, clay or plum carries the words,
  /// and legibility is a filter rather than the whole rule.
  ///
  /// If no tone in the palette clears AA (a palette that flat cannot happen
  /// — tone 0 and 100 always do), the best-contrast tone wins.
  static int readableInkOn(int background) {
    const aaBodyText = 4.5;
    try {
      final key = Hct.fromInt(background);
      final palette = TonalPalette.of(key.hue, 48.0);
      var best = 0;
      var bestScore = -1.0;
      var fallback = palette.get(key.tone > 50 ? 0 : 100);
      var fallbackRatio = _contrastRatio(fallback, background);
      for (var tone = 0; tone <= 100; tone += 2) {
        final argb = palette.get(tone);
        final ratio = _contrastRatio(argb, background);
        if (ratio > fallbackRatio) {
          fallbackRatio = ratio;
          fallback = argb;
        }
        if (ratio < aaBodyText) continue;
        // Among the readable tones, the most saturated one wins; contrast
        // breaks ties so two equally chromatic tones take the safer one.
        final chroma = Hct.fromInt(argb).chroma;
        final score = chroma * 100 + ratio;
        if (score > bestScore) {
          bestScore = score;
          best = argb;
        }
      }
      return best == 0 ? fallback : best;
    } catch (_) {
      return _contrastRatio(0xFFFFFFFF, background) >=
              _contrastRatio(0xFF0B0B0C, background)
          ? 0xFFFFFFFF
          : 0xFF0B0B0C;
    }
  }

  /// The backing-card tone for a sticker shown on [background]: the same
  /// M3 tonal palette as [readableInkOn], stepped AWAY from the
  /// background's tone so the silhouette behind a cutout actually reads.
  ///
  /// A card in the background's own color is invisible — which is what a
  /// fullscreen wash of the photo's dominant color used to produce. Same
  /// hue, same chroma family, just the far side of the ramp, so the card
  /// still belongs to the photo.
  static int cardToneOn(int background) {
    try {
      final key = Hct.fromInt(background);
      final palette = TonalPalette.of(key.hue, 36.0);
      // Walk away from the background's tone until the card separates
      // clearly (2.5:1 is plenty for a shape behind a cutout — the art on
      // top carries the read, the card only has to be seen).
      final step = key.tone > 50 ? -1 : 1;
      var tone = key.tone.round();
      for (var i = 0; i < 100; i++) {
        if (_contrastRatio(palette.get(tone), background) >= 2.5) {
          return palette.get(tone);
        }
        tone = (tone + step).clamp(0, 100);
      }
      return palette.get(step > 0 ? 100 : 0);
    } catch (_) {
      return 0xFF3A3A3C;
    }
  }

  /// WCAG relative-luminance contrast ratio between two opaque ARGB ints.
  static double _contrastRatio(int a, int b) {
    final la = _relativeLuminance(a);
    final lb = _relativeLuminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  static double _relativeLuminance(int argb) {
    double channel(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    final r = channel(((argb >> 16) & 0xFF) / 255);
    final g = channel(((argb >> 8) & 0xFF) / 255);
    final bl = channel((argb & 0xFF) / 255);
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  }
}
