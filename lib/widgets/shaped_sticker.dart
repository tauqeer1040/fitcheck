import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';

import '../services/sticker_style_service.dart';

/// The Pixel-"Shape"-style sticker composition: a solid, dominant-color M3
/// shape card with the cutout art centered on top, overflowing the
/// silhouette on every side. One widget used by the preview, the grid
/// cell and fullscreen so Hero flights morph between identical structures.
class ShapedSticker extends StatelessWidget {
  final String imagePath;
  final int shapeIndex;
  final int dominantColor;

  final double? width;
  final double? height;

  /// Silhouette size relative to the art box — smaller = the art
  /// overflows the shape more. 0.7 leaves ~15% of the art box sticking
  /// out on each side (~30% total).
  final double shapeScale;

  /// Live scale of the silhouette card only (art unaffected). Animate it
  /// 0 -> 1 for the spring-in "morph" when the sticker lifts.
  final double cardScale;

  /// Pixel-unlock progress: at 0 the silhouette is bloomed wide (1.5x)
  /// and the art is small and invisible; at 1 both rest. Values past 1
  /// (easeOutBack overshoot) push the card slightly smaller then settle —
  /// that's the pop. Driven by the fullscreen detail entrance.
  final double openProgress;

  /// Collapse-into-shape entrance: at 0 the art is oversized (1.35x) and
  /// the silhouette is absent; as it rises the art shrinks into the
  /// solid shape which springs in beneath it. Overshoot (>1) lands the
  /// pop. Driven by the fullscreen detail entrance.
  final double? collapseProgress;

  final BoxFit fit;

  const ShapedSticker({
    super.key,
    required this.imagePath,
    required this.shapeIndex,
    required this.dominantColor,
    this.width,
    this.height,
    this.shapeScale = 0.7,
    this.cardScale = 1.0,
    this.openProgress = 1.0,
    this.collapseProgress,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    final shape =
        kStyleShapes[shapeIndex.clamp(0, kStyleShapes.length - 1)];
    final open = openProgress;
    final collapse = collapseProgress;
    // Collapse mode (fullscreen open): art shrinks into the shape.
    final double effectiveCardScale;
    final double artScale;
    final double artOpacity;
    if (collapse != null) {
      effectiveCardScale = cardScale * collapse.clamp(0.0, 1.4);
      artScale = 1.35 - 0.35 * collapse.clamp(0.0, 1.0);
      artOpacity = 1.0;
    } else {
      // Bloomed-open card + small hidden art at 0; settled at 1.
      effectiveCardScale = cardScale * (1.5 - 0.5 * open);
      artScale = 0.72 + 0.28 * open;
      artOpacity = open.clamp(0.0, 1.0);
    }
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Solid colored silhouette behind — the art overflows it.
          // Always square (side = tighter dimension × shapeScale),
          // whatever the outer box aspect is. Direct transform (not
          // AnimatedScale): the scale driver already animates per-frame,
          // so a nested implicit animation would chase its target with
          // a springy lag — reading as a jiggle. This tracks the
          // driver exactly, no overshoot of its own.
          Transform.scale(
            scale: effectiveCardScale,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bounded = constraints.hasBoundedWidth &&
                    constraints.hasBoundedHeight;
                final side = bounded
                    ? (constraints.maxWidth < constraints.maxHeight
                            ? constraints.maxWidth
                            : constraints.maxHeight) *
                        shapeScale
                    : 0.0;
                final card = M3Container(
                  shape,
                  color: Color(dominantColor),
                  child: const SizedBox.expand(),
                );
                if (side <= 0) {
                  return FractionallySizedBox(
                    widthFactor: shapeScale,
                    heightFactor: shapeScale,
                    child: card,
                  );
                }
                return Center(
                  child: SizedBox(width: side, height: side, child: card),
                );
              },
            ),
          ),
          Positioned.fill(
            child: Transform.scale(
              scale: artScale,
              child: Opacity(
                opacity: artOpacity,
                child: Image.file(
                  File(imagePath),
                  fit: fit,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
