import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../motion/app_haptics.dart';
import '../services/photo_pick_service.dart';

const _channel = MethodChannel('fitcheck/embedded_picker');
const _viewType = 'fitcheck/embedded_picker_view';

/// Routes a gallery pick through the debug Lab's selected implementation:
///
/// * [PickerMode.system] — classic fullscreen picker via image_picker.
/// * [PickerMode.native] — embedded system grid in a modal sheet
///   (Android 14+ only); anywhere else falls back to system.
///
/// Returns the picked file path, or null on cancel. Never throws.
Future<String?> pickGalleryImage(BuildContext context) async {
  final useNative =
      (await PhotoPickService.mode()) == PickerMode.native &&
      !kIsWeb &&
      Platform.isAndroid &&
      await PhotoPickService.isEmbeddedAvailable();
  if (useNative && context.mounted) {
    return showEmbeddedPickerSheet(context);
  }
  return PhotoPickService.pickFromGallery();
}

/// Hints the live embedded session that the host expanded or collapsed,
/// so it switches peak/expanded layout instead of stretching. No-op
/// without a live session. Never throws.
Future<void> notifyEmbeddedExpanded(bool expanded) async {
  try {
    await _channel.invokeMethod<void>(
      'notifyExpanded',
      {'expanded': expanded},
    );
  } catch (_) {}
}

/// Bottom sheet hosting the native embedded photo grid.
///
/// Fixed height (not draggable): the sheet must never compete with the
/// embedded grid for vertical drags, or the grid won't scroll. One tap
/// on a photo grants it instantly — the sheet pops with the cached file
/// path on the first grant, so there is no Done tap. Close / back means
/// cancel (null).
Future<String?> showEmbeddedPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Never draggable: the sheet's drag-to-dismiss recognizer would eat
    // the grid's vertical scrolls. X + back still close it.
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (sheetContext) => const _EmbeddedPickerBody(),
  );
}

/// The native embedded grid, reusable anywhere: modal sheet, docked
/// home sheet, onboarding. Hybrid composition (real touches, real
/// scroll), first grant completes with the cached file path.
class EmbeddedPickerGrid extends StatefulWidget {
  final ValueChanged<String> onPick;

  /// Shown when the session fails (old OS, missing SDK extension).
  final Widget fallback;

  const EmbeddedPickerGrid({
    super.key,
    required this.onPick,
    required this.fallback,
  });

  @override
  State<EmbeddedPickerGrid> createState() => EmbeddedPickerGridState();
}

class EmbeddedPickerGridState extends State<EmbeddedPickerGrid> {
  String? _error;
  bool _settled = false;

  /// Hybrid-composition controller: the `AndroidView` widget renders in
  /// a virtual display here, where the picker's remote SurfaceView can
  /// neither scroll nor take input. `initSurfaceAndroidView` composes
  /// at the view-hierarchy level instead — real touches, real scroll.
  AndroidViewController? _viewController;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onNativeEvent);
    _initView();
  }

  @override
  void dispose() {
    _viewController?.dispose();
    _viewController = null;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _initView() async {
    final controller = PlatformViewsService.initSurfaceAndroidView(
      id: platformViewsRegistry.getNextPlatformViewId(),
      viewType: _viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: const {
        'accentColor': 0xFFFFD60A,
      },
      creationParamsCodec: const StandardMessageCodec(),
    );
    try {
      await controller.create();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not create picker view.');
      }
      return;
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _viewController = controller);
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    if (!mounted || _settled) return;
    switch (call.method) {
      case 'onGranted':
        final path = call.arguments as String?;
        if (path != null && path.isNotEmpty) {
          _settled = true;
          AppHaptics.step();
          widget.onPick(path);
        }
      case 'onSelectionComplete':
        // Done with nothing granted (grants complete immediately above).
        _settled = true;
      case 'onSessionError':
        setState(() => _error = '${call.arguments ?? 'picker failed'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return widget.fallback;
    if (_viewController == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return AndroidViewSurface(
      controller: _viewController!,
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(
          () => EagerGestureRecognizer(),
        ),
      },
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    );
  }
}

class _EmbeddedPickerBody extends StatefulWidget {
  const _EmbeddedPickerBody();

  @override
  State<_EmbeddedPickerBody> createState() => _EmbeddedPickerBodyState();
}

class _EmbeddedPickerBodyState extends State<_EmbeddedPickerBody> {
  /// Sheet fraction: header-drag resizes between half and near-full.
  /// The drag lives on the header only, so the grid below keeps every
  /// touch for its own scrolling — no gesture-arena fight.
  double _frac = 0.85;
  bool _dragging = false;

  static const _minFrac = 0.5;
  static const _maxFrac = 0.95;
  static const _expandThreshold = 0.7;

  /// Session failed (old OS, missing SDK extension): offer the classic
  /// picker without losing the user's intent.
  Future<void> _useClassic(BuildContext context) async {
    final path = await PhotoPickService.pickFromGallery();
    if (context.mounted) Navigator.of(context).pop(path);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final screen = MediaQuery.of(context).size.height;
    setState(() {
      _frac = (_frac - d.delta.dy / screen).clamp(_minFrac, _maxFrac);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final wasExpanded = _frac > _expandThreshold;
    final fling = details.velocity.pixelsPerSecond.dy;
    setState(() {
      _dragging = false;
      if (fling < -400) {
        _frac = _maxFrac;
      } else if (fling > 400) {
        _frac = _minFrac;
      } else {
        _frac = _frac > (_minFrac + _maxFrac) / 2 ? _maxFrac : _minFrac;
      }
    });
    final nowExpanded = _frac > _expandThreshold;
    if (wasExpanded != nowExpanded) {
      AppHaptics.step();
      unawaited(notifyEmbeddedExpanded(nowExpanded));
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * _frac;
    return AnimatedContainer(
      duration:
          _dragging ? Duration.zero : const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      height: height,
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Column(
        children: [
          // Header-only drag zone: resizing from here never fights the
          // grid below for scroll gestures.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) =>
                setState(() => _dragging = true),
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Pick your outfit',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'One tap picks — no Done needed.',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon:
                            const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(30),
              ),
              child: EmbeddedPickerGrid(
                onPick: (path) => Navigator.of(context).pop(path),
                fallback: _FallbackView(
                  error: 'Embedded picker unavailable',
                  onClassic: () => _useClassic(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackView extends StatelessWidget {
  final String error;
  final VoidCallback onClassic;
  const _FallbackView({required this.error, required this.onClassic});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.photo_library_outlined,
            color: Colors.white38,
            size: 40,
          ),
          const SizedBox(height: 12),
          const Text(
            'Embedded picker unavailable',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 6),
          Text(
            error,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: onClassic,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'Open classic picker',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
