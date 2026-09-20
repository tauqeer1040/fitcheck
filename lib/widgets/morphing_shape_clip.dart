import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// M3 Expressive refresh look as a real image container: the child
/// (photo/logo) is clipped to a polygon that morphs through the exact
/// 8-shape M3E sequence while the outline continuously rotates —
/// image stays upright, only the shape turns. Timings mirror the
/// reference implementation: 650ms spring morphs (damping 0.6,
/// stiffness 200), full rotation every 4666ms.
class MorphingShapeClip extends StatefulWidget {
  final Widget child;

  /// When true, the whole clipped output rotates (image turns WITH
  /// the shape). When false (default), rotation goes into the
  /// outline's startAngle — the shape turns around a static image.
  final bool rotateImage;

  /// Scale the whole clip converges to while it runs (1.0 = endless,
  /// no shrink — demo mode). Preview passes ~0.55 so the morphing
  /// photo visibly shrinks toward the emerging cutout size.
  final double endScale;

  /// Time to travel from 1.0 to [endScale], then holds.
  final Duration shrinkDuration;

  const MorphingShapeClip({
    super.key,
    required this.child,
    this.rotateImage = false,
    this.endScale = 1.0,
    this.shrinkDuration = const Duration(seconds: 4),
  });

  @override
  State<MorphingShapeClip> createState() => _MorphingShapeClipState();
}

class _MorphingShapeClipState extends State<MorphingShapeClip>
    with TickerProviderStateMixin {
  // M3E timings, slowed 30% for readability.
  static const int _morphIntervalMs = 845;
  static const int _globalRotationMs = 6066;

  static final List<RoundedPolygon> _polygons = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.gem,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
    MaterialShapes.cookie12Sided,
  ];

  late final List<Morph> _morphSequence;
  late final AnimationController _morphController;
  late final AnimationController _rotationController;
  late final AnimationController _shrinkController;
  Timer? _morphTimer;
  int _morphIndex = 0;

  final _morphSpec = SpringSimulation(
    SpringDescription.withDampingRatio(
      ratio: 0.6,
      stiffness: 200.0,
      mass: 1.0,
    ),
    0.0,
    1.0,
    5.0,
    tolerance: const Tolerance(velocity: 0.1, distance: 0.1),
  );

  @override
  void initState() {
    super.initState();
    _morphSequence = [
      for (int i = 0; i < _polygons.length; i++)
        Morph(_polygons[i], _polygons[(i + 1) % _polygons.length]),
    ];
    _morphController = AnimationController.unbounded(vsync: this);
    _rotationController = AnimationController(
      duration: const Duration(milliseconds: _globalRotationMs),
      vsync: this,
    )..repeat();
    // Slow convergence toward the cutout size. easeOut so most of the
    // travel happens early, then it hovers while ML finishes.
    _shrinkController = AnimationController(
      duration: widget.shrinkDuration,
      vsync: this,
    )..forward();
    _morphTimer = Timer.periodic(
      const Duration(milliseconds: _morphIntervalMs),
      (_) => _nextMorph(),
    );
    _nextMorph();
  }

  void _nextMorph() {
    if (!mounted) return;
    _morphIndex = (_morphIndex + 1) % _morphSequence.length;
    _morphController.reset();
    _morphController.animateWith(_morphSpec).then((_) {
      if (mounted && _morphController.value != 1.0) {
        _morphController.value = 1.0;
      }
    });
  }

  @override
  void dispose() {
    _morphTimer?.cancel();
    _morphController.dispose();
    _rotationController.dispose();
    _shrinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [_morphController, _rotationController, _shrinkController]),
        builder: (context, child) {
          final shrink = 1.0 -
              (1.0 - widget.endScale) *
                  Curves.easeOut.transform(
                    _shrinkController.value.clamp(0.0, 1.0),
                  );
          // Image-rotate mode: whole clipped output turns together.
          // Default: only the outline phase-turns under a static image.
          final clip = ClipPath(
            clipper: _MorphClipper(
              _morphSequence[_morphIndex],
              _morphController.value.clamp(0.0, 1.0),
              outlineDeg: widget.rotateImage
                  ? 0.0
                  : _rotationController.value * 360.0,
            ),
            child: child,
          );
          if (!widget.rotateImage) {
            return Transform.scale(scale: shrink, child: clip);
          }
          return Transform.scale(
            scale: shrink,
            child: Transform.rotate(
              angle: _rotationController.value * math.pi * 2,
              child: clip,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _MorphClipper extends CustomClipper<Path> {
  final Morph morph;
  final double progress;
  final double outlineDeg;

  _MorphClipper(this.morph, this.progress, {this.outlineDeg = 0.0});

  @override
  Path getClip(Size size) {
    // Unit-space morph path (outline optionally phase-turned),
    // scaled to the widget box.
    final path = morph.toPath(
      progress: progress,
      startAngle: outlineDeg.round() % 360,
    );
    final scaled = path.transform(
      Matrix4.diagonal3Values(size.width, size.height, 1).storage,
    );
    // Center the unit shape (polygons are centered near 0.5,0.5;
    // rotation pivot handled inside toPath).
    final bounds = scaled.getBounds();
    final dx = (size.width - bounds.width) / 2 - bounds.left;
    final dy = (size.height - bounds.height) / 2 - bounds.top;
    return scaled.shift(Offset(dx, dy));
  }

  @override
  bool shouldReclip(_MorphClipper oldClipper) => true;
}
