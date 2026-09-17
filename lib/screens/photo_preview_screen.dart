import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../services/subject_cutout_service.dart';

enum _CutoutState { processing, idle, lifted, dragging, floating }

class PhotoPreviewScreen extends StatefulWidget {
  final String imagePath;

  /// Hero tag shared with the sticker's destination cell in the homescreen
  /// grid, so the save flight lands in its real slot.
  final String heroTag;

  /// Called with the saved cutout path the moment a save starts (flick
  /// release or auto-add), while this route is still up, so the grid can
  /// insert the cell before the Hero flight begins.
  final ValueChanged<String>? onSaved;

  const PhotoPreviewScreen({
    super.key,
    required this.imagePath,
    required this.heroTag,
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

  late AnimationController _liftController;
  late AnimationController _bobController;
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

    WidgetsBinding.instance.addPostFrameCallback((_) => _startProcessing());
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _liftController.dispose();
    _bobController.dispose();
    super.dispose();
  }

  Future<void> _startProcessing() async {
    try {
      final service = SubjectCutoutService();
      final savedPath = await service.cutoutAndSave(widget.imagePath);
      final file = File(savedPath);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final decoded = frame.image;

      if (mounted) {
        setState(() {
          _cutoutPath = savedPath;
          _cutoutSize = Size(
            decoded.width.toDouble(),
            decoded.height.toDouble(),
          );
          _state = _CutoutState.idle;
        });
        // Long-press is optional now: auto-lift the sticker as soon as
        // the cutout is ready so picking a photo just makes the sticker.
        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted && _state == _CutoutState.idle) _startLift();
        });
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
    if (path != null) widget.onSaved?.call(path);
    _finishAndPop();
  }

  void _finishAndPop() {
    Navigator.pop(context, _cutoutPath);
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
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background photo — tap or long-press to reveal cutout
          GestureDetector(
            onLongPress: _state == _CutoutState.idle ? _onLongPress : null,
            child: Center(
              child: Image.file(
                File(widget.imagePath),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                width: size.width,
                height: size.height,
              ),
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
          // into the matching grid cell.
          if (_isCutoutVisible)
            Positioned(
              left: (size.width - cutoutDisplayW) / 2 + _getStickerOffset().dx,
              top: (size.height - cutoutDisplayH) / 2 + _getStickerOffset().dy + _getBobY(),
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
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: _state == _CutoutState.dragging ? 30 : 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: RepaintBoundary(
                          child: SizedBox(
                            width: cutoutDisplayW,
                            height: cutoutDisplayH,
                            child: Image.file(
                              File(_cutoutPath!),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
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

          // Processing indicator while ML Kit separates the person.
          if (_state == _CutoutState.processing)
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
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Cutting out person…',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

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
