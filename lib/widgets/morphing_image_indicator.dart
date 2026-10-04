// Vendored fork of loading_indicator_m3e's ExpressiveLoadingIndicator
// (MIT, abraham/user — see pubspec), with two changes:
// - when [image] is provided, the morphing shapes are filled with the
//   photo (cover) instead of a solid [color];
// - the PHOTO stays stable while the shape spins: rotation goes into
//   the clip path, and the image is drawn unrotated inside it (cover
//   on the full box). Same morph/rotation engine, timings and
//   performance characteristics — only the paint fill differs.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// M3E morphing loader that can wear a photo.
///
/// [imageProvider] fills every morphing shape with the image (cover);
/// when null (or still resolving), shapes fall back to [color].
class MorphingImageIndicator extends StatefulWidget {
  final ImageProvider? imageProvider;
  final List<RoundedPolygon>? polygons;
  final BoxConstraints? constraints;
  final Color? color;
  final String? semanticsLabel;
  final String? semanticsValue;

  /// When true, the morphing shape fills the whole box (cover) instead
  /// of the loader convention (a 38px active shape swimming in padding).
  /// For the fullscreen preview square: the photo IS the shape.
  final bool fillBox;

  const MorphingImageIndicator({
    super.key,
    this.imageProvider,
    this.polygons,
    this.constraints,
    this.color,
    this.semanticsLabel,
    this.semanticsValue,
    this.fillBox = false,
  });

  @override
  State<MorphingImageIndicator> createState() =>
      _MorphingImageIndicatorState();
}

class _MorphingImageIndicatorState extends State<MorphingImageIndicator>
    with TickerProviderStateMixin {
  static final List<RoundedPolygon> _defaultPolygons = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.pill,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
  ];

  static const BoxConstraints _defaultConstraints = BoxConstraints(
    minWidth: 48.0,
    minHeight: 48.0,
    maxWidth: 48.0,
    maxHeight: 48.0,
  ); // default from kotlin source

  late final List<RoundedPolygon> _polygons;

  static const int _globalRotationDurationMs = 4666;
  static const int _morphIntervalMs = 650;
  static const double _fullRotation = 360.0;

  static const double _quarterRotation = _fullRotation / 4;
  static const double _activeSize = 38; // based on source spec

  late final List<Morph> _morphSequence;

  late final AnimationController _morphController;
  late final AnimationController _globalRotationController;
  int _currentMorphIndex = 0;
  double _morphRotationTargetAngle = _quarterRotation;

  Timer? _morphTimer;

  final _morphAnimationSpec = SpringSimulation(
    SpringDescription.withDampingRatio(ratio: 0.6, stiffness: 200.0, mass: 1.0),
    0.0,
    1.0,
    5.0,
    snapToEnd: true,
  );

  late BoxConstraints _constraints;
  late Color _color;

  ui.Image? _image;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  @override
  void initState() {
    super.initState();
    _polygons = widget.polygons ?? _defaultPolygons;
    _morphSequence = _createMorphSequence(_polygons, circularSequence: true);
    _morphController = AnimationController.unbounded(vsync: this);
    _globalRotationController = AnimationController(
      duration: const Duration(milliseconds: _globalRotationDurationMs),
      vsync: this,
    );
    // Image resolve lives in didChangeDependencies, not here:
    // createLocalImageConfiguration(context) in initState throws
    // (dependOnInheritedWidget before first build), which left the
    // medallion imageless and spammed the log on every mount.
    _startAnimations();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(MorphingImageIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageProvider != oldWidget.imageProvider) {
      _resolveImage();
    }
    if (widget.polygons != oldWidget.polygons) {
      _polygons = widget.polygons ?? _defaultPolygons;
      _morphSequence = _createMorphSequence(_polygons, circularSequence: true);
    }
  }

  void _resolveImage() {
    _unresolveImage();
    final provider = widget.imageProvider;
    if (provider == null) return;
    final config = createLocalImageConfiguration(context);
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _image = info.image);
      },
    );
    _imageListener = listener;
    _imageStream = provider.resolve(config)..addListener(listener);
  }

  void _unresolveImage() {
    _imageStream?.removeListener(_imageListener!);
    _imageStream = null;
    _imageListener = null;
    _image = null;
  }

  @override
  Widget build(BuildContext context) {
    final indicatorTheme = ProgressIndicatorTheme.of(context);
    _color =
        widget.color ??
        indicatorTheme.color ??
        Theme.of(context).colorScheme.primary;
    _constraints =
        widget.constraints ?? indicatorTheme.constraints ?? _defaultConstraints;

    final activeIndicatorScale = widget.fillBox
        ? 1.0
        : _activeSize / math.min(_constraints.maxWidth, _constraints.maxHeight);

    final shapesScaleFactor =
        _calculateScaleFactor(_polygons) * activeIndicatorScale;

    return Semantics.fromProperties(
      properties: SemanticsProperties(
        label: widget.semanticsLabel,
        value: widget.semanticsValue,
      ),
      child: RepaintBoundary(
        child: ConstrainedBox(
          constraints: _constraints,
          child: AspectRatio(
            aspectRatio: 1.0,
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _morphController,
                _globalRotationController,
              ]),
              builder: (context, child) {
                final morphProgress = _morphController.value.clamp(0.0, 1.0);
                final globalRotationDegrees =
                    _globalRotationController.value * _fullRotation;

                // calculate total rotation (clockwise, matching Kotlin implementation)
                final totalRotationDegrees =
                    morphProgress * _quarterRotation +
                    _morphRotationTargetAngle +
                    globalRotationDegrees;

                final totalRotationRadians =
                    totalRotationDegrees * (math.pi / 180.0);

                // The shape spins (rotation folds into the clip path
                // inside the painter); the photo inside it never turns.
                return CustomPaint(
                  painter: _MorphImagePainter(
                    morph: _morphSequence[_currentMorphIndex],
                    progress: morphProgress,
                    rotationRadians: totalRotationRadians,
                    color: _color,
                    image: _image,
                    scaleFactor: shapesScaleFactor,
                    repaint: Listenable.merge([
                      _morphController,
                      _globalRotationController,
                    ]),
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _unresolveImage();
    _morphTimer?.cancel();
    _morphController.dispose();
    _globalRotationController.dispose();
    super.dispose();
  }

  List<Morph> _createMorphSequence(
    List<RoundedPolygon> polygons, {
    required bool circularSequence,
  }) {
    final morphs = <Morph>[];

    for (int i = 0; i < polygons.length; i++) {
      if (i + 1 < polygons.length) {
        morphs.add(Morph(polygons[i], polygons[i + 1]));
      } else if (circularSequence) {
        // morph from last shape back to first shape
        morphs.add(Morph(polygons[i], polygons[0]));
      }
    }

    return morphs;
  }

  /// Calculates a scale factor that will be used when scaling the provided [RoundedPolygon]s into a
  /// specified sized container.
  ///
  /// Since the polygons may rotate, a simple [RoundedPolygon.calculateBounds] is not enough to
  /// determine the size the polygon will occupy as it rotates. Using the simple bounds calculation may
  /// result in clipped shape.
  ///
  /// This function calculates and returns a scale factor by utilizing the
  /// [RoundedPolygon.calculateMaxBounds] and comparing its result to the
  /// [RoundedPolygon.calculateBounds]. The scale factor can later be used when calling [processPath].
  ///
  /// Port of Kotlin implementation.
  double _calculateScaleFactor(List<RoundedPolygon> polygons) {
    var scaleFactor = 1.0;

    for (final polygon in polygons) {
      final bounds = polygon.calculateBounds();
      final maxBounds = polygon.calculateMaxBounds();

      final boundsWidth = bounds[2] - bounds[0];
      final boundsHeight = bounds[3] - bounds[1];

      final maxBoundsWidth = maxBounds[2] - maxBounds[0];
      final maxBoundsHeight = maxBounds[3] - maxBounds[1];

      final scaleX = boundsWidth / maxBoundsWidth;
      final scaleY = boundsHeight / maxBoundsHeight;

      // We use max(scaleX, scaleY) to handle cases like a pill-shape that can throw off the
      // entire calculation.
      scaleFactor = math.min(scaleFactor, math.max(scaleX, scaleY));
    }

    return scaleFactor;
  }

  void _startAnimations() {
    // infinite global rotation
    _globalRotationController.repeat();

    // periodic morph cycle
    _morphTimer = Timer.periodic(
      const Duration(milliseconds: _morphIntervalMs),
      (_) => _startMorphCycle(),
    );

    _startMorphCycle();
  }

  void _startMorphCycle() {
    if (!mounted) return;

    // move to next morph in sequence
    _currentMorphIndex = (_currentMorphIndex + 1) % _morphSequence.length;

    // accumulate rotation target
    _morphRotationTargetAngle =
        (_morphRotationTargetAngle + _quarterRotation) % _fullRotation;

    // Reset and start morph animation
    _morphController
      ..value = 0.0
      ..animateWith(_morphAnimationSpec);
  }
}

class _MorphImagePainter extends CustomPainter {
  final Morph morph;
  final double progress;

  /// Global spin of the shape window. The photo is drawn unrotated —
  /// only this window turns.
  final double rotationRadians;

  final Color color;
  final ui.Image? image;

  /// A scale factor that will be taken into account uniformly when the [path] is
  /// scaled (i.e. the scaleX would be the [size] width x the scale factor, and the scaleY would be
  /// the [size] height x the scale factor)
  final double scaleFactor;

  _MorphImagePainter({
    required this.morph,
    required this.progress,
    required this.rotationRadians,
    required this.color,
    this.image,
    this.scaleFactor = 1.0,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = morph.toPath(progress: progress);
    final processedPath = _processPath(path, size);
    // Spin the window around the box center. Non-zero fill collapses
    // mid-morph self-overlaps into one solid silhouette (even-odd would
    // punch the shape into separate petals).
    final spin = Matrix4.identity()
      ..translateByDouble(size.width / 2, size.height / 2, 0, 1)
      ..rotateZ(rotationRadians)
      ..translateByDouble(-size.width / 2, -size.height / 2, 0, 1);
    final spun = processedPath.transform(spin.storage);
    spun.fillType = PathFillType.nonZero;
    final img = image;
    if (img == null) {
      canvas.drawPath(
        spun,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color,
      );
      return;
    }
    // Stable photo: cover-fit onto the unrotated box, then reveal it
    // only through the spinning window.
    canvas.save();
    canvas.clipPath(spun);
    final s = math.max(size.width / img.width, size.height / img.height);
    final dw = img.width * s;
    final dh = img.height * s;
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      ui.Rect.fromLTWH(
        (size.width - dw) / 2,
        (size.height - dh) / 2,
        dw,
        dh,
      ),
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MorphImagePainter oldDelegate) {
    return oldDelegate.morph != morph ||
        oldDelegate.progress != progress ||
        oldDelegate.rotationRadians != rotationRadians ||
        oldDelegate.color != color ||
        oldDelegate.image != image ||
        oldDelegate.scaleFactor != scaleFactor;
  }

  /// Process a given path to scale it and center it inside the given size.
  ///
  /// [path] takes a [Path] that was generated by a _normalized_ [Morph] or [RoundedPolygon].
  /// [size] takes a [Size] that the provided [path] is going to be scaled and centered into.
  Path _processPath(Path path, Size size) {
    // a [Matrix] that would be used to apply the scaling. Note that any provided
    // matrix will be reset in this function.
    final Matrix4 scaleMatrix = Matrix4.diagonal3Values(
      size.width * scaleFactor,
      size.height * scaleFactor,
      1,
    );
    final Path scaledPath = path.transform(scaleMatrix.storage);

    // Translate the path so that its center aligns with the center of the container.
    final Rect bounds = scaledPath.getBounds();
    final Offset translation =
        Offset(size.width / 2, size.height / 2) - bounds.center;
    final Path finalPath = scaledPath.shift(translation);

    return finalPath;
  }
}
