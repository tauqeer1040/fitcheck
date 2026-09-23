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
///
/// No outline is ever stroked: the shape is carried entirely by
/// [outsideColor] (the wash whose window IS the morphing shape) and by
/// the optional clip. A white hairline used to trace the path on top —
/// it read as a sticker stroke stuck on the photo rather than the shape
/// itself, so it is gone.
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

  /// When false, the child is NOT clipped — it shows full-bleed while
  /// the morphing outline traces on top as a border-only overlay
  /// (viewfinder look). True = classic clipped container.
  final bool clipChild;

  /// Width / height of [child]'s content when it isn't stretched
  /// (e.g. the source photo). When set, the outline square keys off the
  /// child's OWN shorter side — landscape art → its height, portrait
  /// art → its width — so the border hugs the image instead of
  /// overflowing the box's shorter edge. Null keeps the box-based
  /// sizing (min of the box dimensions).
  final double? childAspectRatio;

  /// Fill everything OUTSIDE the morphing outline with this color, so
  /// only the shape's interior shows the art beneath — the profile-hue
  /// mask around the rotating border. Null = no mask.
  final Color? outsideColor;

  /// Scales the outline square (width AND height) off its measured
  /// side. 1.0 rests on the measurement; 0.9 trims the window 10%
  /// inside it.
  final double outlineScale;

  const MorphingShapeClip({
    super.key,
    required this.child,
    this.rotateImage = false,
    this.endScale = 1.0,
    this.shrinkDuration = const Duration(seconds: 4),
    this.clipChild = true,
    this.childAspectRatio,
    this.outsideColor,
    this.outlineScale = 1.0,
  });

  @override
  State<MorphingShapeClip> createState() => _MorphingShapeClipState();
}

class _MorphingShapeClipState extends State<MorphingShapeClip>
    with TickerProviderStateMixin {
  // M3E timings, slowed twice for pre-cutout calm: readability first,
  // then another 30% off the rotation/morph pace (845→1100ms morphs,
  // ~6.1s→~7.9s full turns). The image holds static inside throughout.
  static const int _morphIntervalMs = 1100;
  static const int _globalRotationMs = 7886;

  /// Full M3E pool, reshuffled on every open so the rotation never
  /// repeats the same few shapes twice in a row. Morph() matches
  /// differing vertex counts itself, so any pairing animates cleanly.
  late final List<RoundedPolygon> _polygons;

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
    _polygons = List<RoundedPolygon>.of(MaterialShapes.all)..shuffle();
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

  /// Side length of the outline square traced over (and clipped to)
  /// the child. With [MorphingShapeClip.childAspectRatio] set, the
  /// child's box-fit rect is reconstructed inside [box] and the square
  /// takes its shorter edge: landscape art → the art's height, portrait
  /// art → the art's width. Without it, the box's shorter edge.
  double _outlineSide(Size box) {
    final boxSide = box.width < box.height ? box.width : box.height;
    final aspect = widget.childAspectRatio;
    if (aspect == null ||
        !aspect.isFinite ||
        aspect <= 0 ||
        !box.width.isFinite ||
        !box.height.isFinite ||
        box.width <= 0 ||
        box.height <= 0) {
      return boxSide;
    }
    // BoxFit.contain rect: whichever axis runs out first is the tight
    // one, the other follows the aspect.
    final double childW;
    final double childH;
    if (box.width / box.height <= aspect) {
      childW = box.width;
      childH = box.width / aspect;
    } else {
      childH = box.height;
      childW = box.height * aspect;
    }
    return childW < childH ? childW : childH;
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
          // The border (when set) strokes the identical path on top.
          final morph = _morphSequence[_morphIndex];
          final progress = _morphController.value.clamp(0.0, 1.0);
          final outlineDeg = widget.rotateImage
              ? 0.0
              : _rotationController.value * 360.0;
          Widget content = LayoutBuilder(
            builder: (context, constraints) {
              final box = Size(
                constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : 0.0,
                constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : 0.0,
              );
              // Square by the smaller dimension, centered: the border's
              // width keys off the image width (copied to height), or
              // off the height when it's smaller — symmetry either way.
              // Clip and border share the square so they trace as one.
              // When the child's aspect is known, the shorter side is
              // taken from the child's own box-fit rect instead of the
              // container, so the outline never overhangs the art.
              final side = _outlineSide(box) * widget.outlineScale;
              final square = Size(side, side);
              final offset = Offset(
                (box.width - side) / 2,
                (box.height - side) / 2,
              );
              final rawPath =
                  morphPathFor(morph, progress, outlineDeg, square);
              final path = rawPath.shift(offset);
              Widget content = child ?? const SizedBox.shrink();
              if (widget.clipChild) {
                content = ClipPath(
                  clipper: _FixedPathClipper(path),
                  child: content,
                );
              }
              final outside = widget.outsideColor;
              if (outside == null) return content;
              return Stack(
                // Center the .child in the box: the Stack default is
                // topStart, which pinned the preview photo to the top
                // edge instead of centering it vertically.
                alignment: Alignment.center,
                children: [
                  content,
                  // Profile-hue mask: painted OVER the art so only the
                  // shape's interior is left showing. Its alpha is the
                  // caller's business, so the wash can be faded in when
                  // the photo's profile color lands and faded back out
                  // when the cutout arrives.
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _OutsideFillPainter(
                        path: path,
                        color: outside,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
          if (!widget.rotateImage) {
            return Transform.scale(scale: shrink, child: content);
          }
          return Transform.scale(
            scale: shrink,
            child: Transform.rotate(
              angle: _rotationController.value * math.pi * 2,
              child: content,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Unit-space morph path scaled + centered to [size]. Shared by the
/// clipper and the border painter so both trace identically.
Path morphPathFor(
    Morph morph, double progress, double outlineDeg, Size size) {
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

/// Fixed-path clip: the path is computed once per frame upstream.
class _FixedPathClipper extends CustomClipper<Path> {
  final Path path;
  const _FixedPathClipper(this.path);

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_FixedPathClipper oldClipper) => true;
}

/// [path] forced to a non-zero fill. Mid-morph polygons self-overlap, and
/// the morph path carries an even-odd fill, which punched the shape into
/// separate petals — both as a mask (holes in the color) and as a fill
/// (holes in the shadow). Non-zero collapses the overlaps into one solid
/// silhouette.
Path solidPath(Path path) {
  final solid = Path()..addPath(path, Offset.zero);
  solid.fillType = PathFillType.nonZero;
  return solid;
}

/// Fills the whole box with [color] EXCEPT the interior of [path] —
/// the profile-hue mask that leaves only the shape's window showing
/// the art beneath.
class _OutsideFillPainter extends CustomPainter {
  final Path path;
  final Color color;

  const _OutsideFillPainter({required this.path, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        solidPath(path),
      ),
      Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = true
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_OutsideFillPainter oldDelegate) => true;
}

