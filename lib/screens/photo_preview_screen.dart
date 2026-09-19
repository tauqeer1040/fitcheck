import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';

import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../services/sticker_style_service.dart';
import '../services/subject_cutout_service.dart';
import '../widgets/shaped_sticker.dart';

enum _CutoutState { processing, idle, lifted, dragging, floating }

class PhotoPreviewScreen extends StatefulWidget {
  final String imagePath;

  /// Hero tag shared with the sticker's destination cell in the homescreen
  /// grid, so the save flight lands in its real slot.
  final String heroTag;

  /// The sticker's shape, rolled from the photo's asset id — the same
  /// shape its gallery-sheet thumbnail showed.
  final int initialShapeIndex;

  /// Called with the saved cutout path + its analyzed style the moment a
  /// save starts (flick release or auto-add), while this route is still
  /// up, so the grid can insert the cell before the Hero flight begins.
  final void Function(String path, StickerStyle style)? onSaved;

  const PhotoPreviewScreen({
    super.key,
    required this.imagePath,
    required this.heroTag,
    required this.initialShapeIndex,
    this.onSaved,
  });

  @override
  State<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends State<PhotoPreviewScreen>
    with TickerProviderStateMixin {
  _CutoutState _state = _CutoutState.processing;
  String? _cutoutPath;
  Size _cutoutSize = Size.zero;
  Offset _dragOffset = Offset.zero;

  /// Where the subject lived inside the source photo, 0–1 normalized
  /// (from the cutout service's mask bbox). The cutout floats at this
  /// origin on first reveal instead of dead-center.
  Offset _subjectAnchor = const Offset(0.5, 0.5);

  /// Decoded source-photo dimensions, for cover-crop math.
  Size _photoSize = Size.zero;

  /// Image-derived backdrop color (M3 theming engine). Null until the
  /// analysis lands; until then the neutral fill is used.
  StickerStyle? _style;

  /// The shape rolled at pick time (matches the sheet thumbnail).
  late final int _shapeIndex = widget.initialShapeIndex;

  /// The collapse-into-shape morph: 0 = photo fully visible, 1 = photo
  /// fully absorbed into the solid color shape.
  double _collapse = 0.0;

  late AnimationController _liftController;
  late AnimationController _bobController;

  /// Drives the silver shimmer wave across the photo while the subject
  /// is being cut out. Ping-pongs so the light continuously glances
  /// back and forth — no dead gap between passes, so it never reads as
  /// restarting.
  late final AnimationController _shimmerController;

  /// Guards one-shot kick-off of the cutout pipeline.
  bool _processingStarted = false;
  Timer? _routeFallbackTimer;
  Animation<double>? _routeAnim;

  /// Drives the collapse-into-shape morph once the cutout is ready.
  late final AnimationController _collapseController;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _liftController = AnimationController(vsync: this);
    _bobController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _liftController.addListener(() => setState(() {}));
    _bobController.addListener(() => setState(() {}));
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    )..repeat(reverse: true);
    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _collapseController.addListener(() {
      if (mounted) setState(() => _collapse = _collapseController.value);
    });

    // Fallback: if the route never reports 'completed' (tests, embedders),
    // start anyway after a beat.
    _routeFallbackTimer =
        Timer(const Duration(milliseconds: 450), _beginProcessing);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Jank fix: the ML cutout used to start on the FIRST frame, stealing
    // the CPU/GPU from the entrance animation and making the pick-to-
    // fullscreen transition stutter. Defer it until the route transition
    // has fully landed — the shimmer covers the wait.
    if (_processingStarted) return;
    final anim = ModalRoute.of(context)?.animation;
    _routeAnim = anim;
    if (anim == null || anim.status == AnimationStatus.completed) {
      _beginProcessing();
    } else {
      anim.addStatusListener(_onRouteShown);
    }
  }

  void _onRouteShown(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    ModalRoute.of(context)?.animation?.removeStatusListener(_onRouteShown);
    _beginProcessing();
  }

  void _beginProcessing() {
    if (_processingStarted || !mounted) return;
    _processingStarted = true;
    _routeFallbackTimer?.cancel();
    _startProcessing();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _routeFallbackTimer?.cancel();
    _routeAnim?.removeStatusListener(_onRouteShown);
    _liftController.dispose();
    _bobController.dispose();
    _shimmerController.dispose();
    _collapseController.dispose();
    super.dispose();
  }

  Future<void> _startProcessing() async {
    try {
      final service = SubjectCutoutService();
      final result = await service.cutoutAndSave(widget.imagePath);
      final savedPath = result.path;
      // Header-only dimension reads: parses the PNG/photo headers
      // WITHOUT decoding pixels — two full image decodes used to run on
      // the critical path here and stalled the reveal.
      final bytes = await File(savedPath).readAsBytes();
      final cutBuffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final cutDesc = await ui.ImageDescriptor.encoded(cutBuffer);
      final cutW = cutDesc.width.toDouble();
      final cutH = cutDesc.height.toDouble();
      cutDesc.dispose();
      cutBuffer.dispose();

      final srcBytes = await File(widget.imagePath).readAsBytes();
      final srcBuffer = await ui.ImmutableBuffer.fromUint8List(srcBytes);
      final srcDesc = await ui.ImageDescriptor.encoded(srcBuffer);
      final photoW = srcDesc.width.toDouble();
      final photoH = srcDesc.height.toDouble();
      srcDesc.dispose();
      srcBuffer.dispose();

      if (mounted) {
        // M3 theming engine on the source image: dominant color for the
        // silhouette. Falls back to neutral on any failure, so this never
        // blocks the reveal.
        final style = await StickerStyleService.analyze(widget.imagePath);
        // The reveal, in ONE beat under 300ms: cutout pops in and the
        // photo melt-morphs into the silhouette simultaneously — no
        // staged delays. Shimmer stops the instant it starts.
        _shimmerController.stop();
        setState(() {
          _style = style;
          _cutoutPath = savedPath;
          _cutoutSize = Size(cutW, cutH);
          _subjectAnchor = result.anchor;
          _photoSize = Size(photoW, photoH);
          _state = _CutoutState.idle;
        });
        _collapseController.forward().orCancel.catchError((_) {});
        // Auto-lift NOW: the cutout pops up while the photo is still
        // melting into the silhouette — one simultaneous beat.
        _startLift();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to cut out subject: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  void _onLongPress() {
    if (_state != _CutoutState.idle || _cutoutPath == null) return;
    AppHaptics.tap();
    _startLift();
  }

  void _startLift() {
    if (_state == _CutoutState.floating) return;
    setState(() => _state = _CutoutState.lifted);
    _liftController.reset();
    _liftController.animateWith(
      SpringSimulation(
        SpringDescription(mass: 1, stiffness: 200, damping: 14),
        0,
        1,
        0,
      ),
    ).then((_) {
      if (mounted) {
        _bobController.repeat();
        // Auto-add after 4s untouched. Any grab cancels this; every
        // release counts as a flick and saves immediately.
        _idleTimer?.cancel();
        _idleTimer = Timer(const Duration(seconds: 4), () {
          if (mounted && _state == _CutoutState.lifted) _startFloat();
        });
      }
    });
  }

  /// Every release is a flick: insert the cell at home and pop so the
  /// sticker flies straight into its grid slot.
  void _startFloat() {
    if (_state == _CutoutState.floating) return;
    _idleTimer?.cancel();
    final path = _cutoutPath;
    setState(() => _state = _CutoutState.floating);
    _bobController.stop();
    if (path != null) {
      final style = _style ??
          StickerStyle(
            dominantColor: kFallbackStickerColor,
            shapeIndex: fallbackShapeIndex(path),
          );
      widget.onSaved?.call(path, style);
    }
    _finishAndPop();
  }

  void _finishAndPop() {
    Navigator.pop(
      context,
      (
        _cutoutPath,
        _style ??
            StickerStyle(
              dominantColor: kFallbackStickerColor,
              shapeIndex: fallbackShapeIndex(widget.imagePath),
            ),
      ),
    );
  }

  void _onDragStart(DragStartDetails details) {
    _idleTimer?.cancel();
    setState(() => _state = _CutoutState.dragging);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() => _dragOffset += details.delta);
  }

  void _onDragEnd(DragEndDetails details) {
    AppHaptics.launch();
    // Any release counts as a flick.
    _startFloat();
  }

  bool get _isCutoutVisible =>
      _cutoutPath != null &&
      (_state == _CutoutState.lifted ||
       _state == _CutoutState.dragging ||
       _state == _CutoutState.floating);

  /// 1 while the shaped backdrop is up (lifted/dragging), 0 otherwise.
  double get _shapeCardScale =>
      (_state == _CutoutState.lifted || _state == _CutoutState.dragging)
          ? 1.0
          : 0.0;

  double _getScale() {
    switch (_state) {
      case _CutoutState.floating:
        return 1.0;
      case _CutoutState.lifted:
      case _CutoutState.dragging:
        return 0.8 + 0.23 * _liftController.value;
      default:
        return 1.0;
    }
  }

  double _getOpacity() {
    switch (_state) {
      case _CutoutState.floating:
        return 1.0;
      case _CutoutState.lifted:
      case _CutoutState.dragging:
        return (_liftController.value).clamp(0.0, 1.0);
      default:
        return 0.0;
    }
  }

  double _getBobY() {
    if (_state != _CutoutState.lifted && _state != _CutoutState.dragging) {
      return 0;
    }
    return math.sin(_bobController.value * 2 * math.pi) * 3.0;
  }

  Offset _getStickerOffset() => _dragOffset;

  /// Screen-space origin for the floating cutout: its TRUE position in
  /// the photo (subject anchor mapped through the cover-crop rect of
  /// the background card), minus half the display size so the Position
  /// stays top-left based. Falls back to center (0.5, 0.5) while the
  /// analysis hasn't landed.
  /// Subject's center within the RESTING background card's coordinates
  /// (photo anchor mapped through the card's BoxFit.cover crop).
  Offset _subjectInCard(Size size) {
    final bgW = size.width * 0.72;
    final bgH = size.height * 0.5;
    if (_photoSize == Size.zero) return Offset(bgW / 2, bgH / 2);
    final coverScale =
        math.max(bgW / _photoSize.width, bgH / _photoSize.height);
    final shownW = _photoSize.width * coverScale;
    final shownH = _photoSize.height * coverScale;
    final cropX = (shownW - bgW) / 2;
    final cropY = (shownH - bgH) / 2;
    return Offset(
      _subjectAnchor.dx * shownW - cropX,
      _subjectAnchor.dy * shownH - cropY,
    );
  }

  Offset _floatOrigin(Size size, double displayW, double displayH) {
    final bgW = size.width * 0.72;
    final bgH = size.height * 0.5;
    final p = _subjectInCard(size);
    final left = (size.width - bgW) / 2 + p.dx - displayW / 2;
    final top = (size.height - bgH) / 2 + p.dy - displayH / 2;
    // Clamp fully on-screen with a small margin, per the edge-case spec.
    final clampedLeft = left
        .clamp(12.0, math.max(12.0, size.width - displayW - 12));
    final clampedTop = top.clamp(
        MediaQuery.of(context).padding.top + 12,
        math.max(MediaQuery.of(context).padding.top + 12,
            size.height - displayH - 12));
    return Offset(clampedLeft.toDouble(), clampedTop.toDouble());
  }

  /// The photo as a shaped card: silver shimmer while the subject is cut
  /// out, then the collapse morph. SUBJECT-ANCHORED melt: as the card
  /// shrinks into the silhouette box, it also glides so that the exact
  /// photo-point the subject was cut from flows onto the cutout's rest
  /// position — the subject appears to pull its home out of the photo at
  /// the spot it lived. Move overshoots (easeOutBack); crossfade smooth.
  Widget _buildBackgroundPhoto(Size size, double targetW, double targetH) {
    final bgW = size.width * 0.72;
    final bgH = size.height * 0.5;
    final c = _style?.dominantColor ?? kFallbackStickerColor;
    final tMove = Curves.easeOutBack.transform(_collapse.clamp(0.0, 1.0));
    final tFade = Curves.easeInOutCubic.transform(_collapse.clamp(0.0, 1.0));
    final w = ui.lerpDouble(bgW, targetW, tMove) ?? bgW;
    final h = ui.lerpDouble(bgH, targetH, tFade) ?? bgH;
    // The subject point inside the resting card, as a fraction of it.
    final restLeft = (size.width - bgW) / 2;
    final restTop = (size.height - bgH) / 2;
    final subjectInCard = _subjectInCard(size);
    final fx = (subjectInCard.dx / bgW).clamp(0.0, 1.0);
    final fy = (subjectInCard.dy / bgH).clamp(0.0, 1.0);
    // Final translation so that at t=1 the subject point — riding at
    // fraction (fx, fy) of the SHRUNKEN card — sits exactly on the
    // cutout's rest center. Because size and position both lerp with
    // the same tMove, the subject point flows in a straight line from
    // its origin to the cutout across every intermediate frame.
    final target = _floatOrigin(size, targetW, targetH);
    final targetCenter = Offset(
      target.dx + targetW / 2,
      target.dy + targetH / 2,
    );
    final dx = (targetCenter.dx - restLeft - targetW * fx) * tMove;
    final dy = (targetCenter.dy - restTop - targetH * fy) * tMove;
    final shaped = Stack(
      alignment: Alignment.center,
      children: [
        // Solid silhouette beneath, fading in as the photo absorbs.
        M3Container(
          kStyleShapes[_shapeIndex],
          width: w,
          height: h,
          color: Color(c).withValues(alpha: tFade.clamp(0.0, 1.0)),
          child: const SizedBox.expand(),
        ),
        Positioned.fill(
          child: M3Container(
            kStyleShapes[_shapeIndex],
            width: w,
            height: h,
            child: Opacity(
              opacity: (1.0 - tFade).clamp(0.0, 1.0),
              child: Image.file(
                File(widget.imagePath),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
      ],
    );
    Widget card = Transform.translate(offset: Offset(dx, dy), child: shaped);
    if (_state != _CutoutState.processing) {
      // Flick departure: the melted silhouette must NOT stay behind as a
      // static shape while the Hero flies home — it shrinks and fades
      // into the takeoff point in sync with the flight.
      final departing = _state == _CutoutState.floating;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: restLeft,
            top: restTop,
            child: AnimatedScale(
              scale: departing ? 0.3 : 1.0,
              duration: const Duration(milliseconds: 260),
              curve: departing ? Curves.easeInCubic : Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: departing ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 220),
                curve: departing ? Curves.easeIn : Curves.easeOut,
                child: card,
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: restLeft,
          top: restTop,
          child: AnimatedBuilder(
            animation: _shimmerController,
            builder: (context, child) {
              // Ease the sweep so the wave accelerates through the middle
              // and rests at the edges — reads as light glancing off glass
              // instead of a constant-speed scanner.
              final t =
                  Curves.easeInOutSine.transform(_shimmerController.value);
              // Tighter travel: the light spends most of the pass ON the
              // card instead of sweeping through off-screen dead air
              // (the old ±1.7 range put the core on-card only ~30% of
              // the time — the "restarts every second" feeling).
              final x = -1.0 + 2.0 * t;
              return ShaderMask(
                blendMode: BlendMode.srcATop,
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment(x, -0.45),
                  end: Alignment(x + 1.0, 0.45),
                  colors: [
                    Colors.transparent,
                    Color(0x40FFFFFF), // wide soft shoulder
                    Color(0x26FFFFFF), // pre-core breath
                    Color(0x8FC7CBD4), // silver core
                    Color(0x26FFFFFF),
                    Color(0x40FFFFFF),
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.24, 0.40, 0.5, 0.60, 0.76, 1.0],
                ).createShader(bounds),
                child: child,
              );
            },
            child: card,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final maxW = size.width * 0.55;
    final cutoutDisplayW = _cutoutSize.width.clamp(100.0, maxW);
    final aspect = _cutoutSize.width > 0 && _cutoutSize.height > 0
        ? _cutoutSize.height / _cutoutSize.width
        : 1.0;
    final cutoutDisplayH = cutoutDisplayW * aspect;

    return Scaffold(
      // Transparent: the route is non-opaque, so the live grid stays
      // composited underneath and this BackdropFilter blurs it — same
      // frost recipe as the bottom sheet and detail screen.
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Frosted glass backdrop over the live homescreen grid.
          Positioned.fill(
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.20),
                ),
              ),
            ),
          ),

          // Background photo — shimmer while processing, then the
          // collapse morph. The card fades ONLY on its own 300ms
          // crossfade curve (not the cutout's lift spring — that double
          // fade made the morph read near-instant). It rests as the pure
          // solid silhouette behind the lifted sticker, matching the
          // grid cell.
          GestureDetector(
            onLongPress: _state == _CutoutState.idle ? _onLongPress : null,
            child: _buildBackgroundPhoto(
              size,
              cutoutDisplayW * 0.7,
              cutoutDisplayH * 0.7,
            ),
          ),

          // Dark overlay when cutout is visible
          if (_isCutoutVisible)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _state == _CutoutState.floating ? 0.0 : 0.3,
                duration: const Duration(milliseconds: 280),
                child: Container(color: Colors.black),
              ),
            ),

          // Cutout image — the Hero source: on save it flies straight
          // into the matching grid cell. Floats at its TRUE origin in
          // the photo on first reveal (not auto-centered); drag offset
          // applies on top afterwards.
          if (_isCutoutVisible)
            Builder(builder: (context) {
              final origin =
                  _floatOrigin(size, cutoutDisplayW, cutoutDisplayH);
              return Positioned(
                left: origin.dx + _getStickerOffset().dx,
                top: origin.dy +
                    _getStickerOffset().dy +
                    _getBobY(),
              child: GestureDetector(
                onPanStart: _state == _CutoutState.lifted ? _onDragStart : null,
                onPanUpdate: _state == _CutoutState.lifted || _state == _CutoutState.dragging
                    ? _onDragUpdate : null,
                onPanEnd: _state == _CutoutState.dragging ? _onDragEnd : null,
                child: Hero(
                  tag: widget.heroTag,
                  child: Transform.scale(
                    scale: _getScale(),
                  child: Opacity(
                    opacity: _getOpacity(),
                    child: RepaintBoundary(
                      // Pixel "Shape" reveal: art lifts first, then the
                      // solid dominant-color silhouette springs in behind
                      // it. Identical structure to the grid cell, so the
                      // Hero flight is a true morph.
                      child: ShapedSticker(
                        imagePath: _cutoutPath!,
                        shapeIndex: _shapeIndex,
                        dominantColor:
                            _style?.dominantColor ?? kFallbackStickerColor,
                        width: cutoutDisplayW,
                        height: cutoutDisplayH,
                        cardScale: _shapeCardScale,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            );
            },
          ),

          // Close button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),

          // (No processing prompt: the silver shimmer wave over the
          // photo is the progress indicator.)

          // Hint once the sticker is ready (long-press still works,
          // but the sticker now lifts and saves on its own).
          if (_state == _CutoutState.idle)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 32,
              child: Center(
                child: AppMotion.entrance(
                  context,
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Making your sticker…',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),

          // Hint while hovering: flick anywhere to keep it, or just wait.
          if (_state == _CutoutState.lifted)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 32,
              child: Center(
                child: AppMotion.entrance(
                  context,
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Flick it anywhere to keep it',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
