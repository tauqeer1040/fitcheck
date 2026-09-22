import 'dart:io';
import 'dart:math' as math;

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

  /// When true, the silhouette slowly rotates in place (fullscreen
  /// viewing delight). Art, drag, and flights are untouched — only the
  /// shadow turns beneath static art.
  final bool rotateSilhouette;

  /// Full turn duration for the rotating silhouette.
  final Duration rotationPeriod;

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
    this.rotateSilhouette = false,
    this.rotationPeriod = const Duration(seconds: 12),
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
      // Never clip: the silhouette is sized to (or past) the box edge
      // and must overflow visibly instead of shearing.
      child: Stack(
        clipBehavior: Clip.none,
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
            child: _SilhouetteBox(
              shapeScale: shapeScale,
              rotate: rotateSilhouette,
              rotationPeriod: rotationPeriod,
              card: M3Container(
                shape,
                color: Color(dominantColor),
                child: const SizedBox.expand(),
              ),
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

/// Square silhouette box: side = full width × [shapeScale].
/// Height is copied from width so the box is always 1:1 — sizing off
/// the tighter dimension shrank portrait boxes and the rotation read
/// as cropped top/bottom.
/// Optionally rotates the card in place (fullscreen delight) — the
/// rotation wraps the whole card including its centering, so layout
/// never shifts while it turns.
class _SilhouetteBox extends StatefulWidget {
  final double shapeScale;
  final bool rotate;
  final Duration rotationPeriod;
  final Widget card;

  const _SilhouetteBox({
    required this.shapeScale,
    required this.rotate,
    required this.rotationPeriod,
    required this.card,
  });

  @override
  State<_SilhouetteBox> createState() => _SilhouetteBoxState();
}

class _SilhouetteBoxState extends State<_SilhouetteBox>
    with SingleTickerProviderStateMixin {
  AnimationController? _rotation;

  @override
  void initState() {
    super.initState();
    if (widget.rotate) {
      _rotation = AnimationController(
        duration: widget.rotationPeriod,
        vsync: this,
      )..repeat();
    }
  }

  @override
  void dispose() {
    _rotation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.hasBoundedWidth &&
            constraints.hasBoundedHeight;
        final side = bounded
            ? constraints.maxWidth * widget.shapeScale
            : 0.0;
        final box = side <= 0
            ? FractionallySizedBox(
                widthFactor: widget.shapeScale,
                heightFactor: widget.shapeScale,
                child: widget.card,
              )
            : Center(
                child:
                    SizedBox(width: side, height: side, child: widget.card),
              );
        final rotation = _rotation;
        if (rotation == null) return box;
        return AnimatedBuilder(
          animation: rotation,
          builder: (context, child) => Transform.rotate(
            angle: rotation.value * math.pi * 2,
            child: child,
          ),
          child: box,
        );
      },
    );
  }
}
