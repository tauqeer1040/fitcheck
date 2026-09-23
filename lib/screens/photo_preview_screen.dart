import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../widgets/genie_flight.dart';
import '../services/sticker_style_service.dart';
import '../services/subject_cutout_service.dart';
import '../widgets/morphing_shape_clip.dart';
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

  /// When false (default), opening stays a pure fullscreen preview:
  /// rotating hairline shape, static image, size sliders — no ML, no
  /// cutout, no save. True restores the full cutout flow.
  final bool autoCutout;

  /// Hero tag shared with the gallery thumbnail that opened this screen,
  /// so the pick flies open like an app launch. Null when there is no
  /// thumbnail behind it (previews opened from elsewhere).
  final String? pickHeroTag;

  /// Called with the saved cutout path + its analyzed style the moment a
  /// save starts (flick release or auto-add), while this route is still
  /// up, so the grid can insert the cell before the Hero flight begins.
  final void Function(String path, StickerStyle style)? onSaved;

  const PhotoPreviewScreen({
    super.key,
    required this.imagePath,
    required this.heroTag,
    required this.initialShapeIndex,
    this.pickHeroTag,
    this.onSaved,
    this.autoCutout = false,
  });

  @override
  State<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends State<PhotoPreviewScreen>
    with TickerProviderStateMixin {
  _CutoutState _state = _CutoutState.processing;
  String? _cutoutPath;
  Offset _dragOffset = Offset.zero;

  /// Image-derived backdrop color (M3 theming engine). Null until the
  /// analysis lands; until then the neutral fill is used.
  StickerStyle? _style;

  /// Backdrop tint wash: the photo's dominant color from the same
  /// analysis that picks the sticker shadow color, laid translucent
  /// behind the rotating bordered shape. Loads on open (64px thumb,
  /// milliseconds) — never blocks the entrance.
  Color? _bgTint;

  /// Source photo aspect (width / height) from a header-only read, so
  /// the morphing outline can key off the image's own shorter side —
  /// landscape → its height, portrait → its width. Null until loaded
  /// (and for unreadable files), falling back to the box-sized square.
  double? _imageAspect;

  /// Opacity of the photo-profile wash: 0 = none, 1 = the color spans the
  /// screen. Driven both ways so the color is never applied instantly —
  /// it eases in once the color profile lands (applying it in one frame
  /// read as a hiccup right as the preview opened), and eases back out
  /// when the cutout arrives.
  late final AnimationController _bgFadeController;
  double _bgAlpha = 0.0;

  /// Preview fit modes (persisted pick from the fit cycler that used to
  /// sit at the bottom of the screen).
  static const List<BoxFit> _fits = [
    BoxFit.cover,
    BoxFit.contain,
    BoxFit.fill,
    BoxFit.fitWidth,
    BoxFit.fitHeight,
  ];
  int _fitIndex = 0;

  /// The shape rolled at pick time (matches the sheet thumbnail).
  late final int _shapeIndex = widget.initialShapeIndex;

  /// The collapse-into-shape morph: 0 = photo fully visible, 1 = photo
  /// fully absorbed into the solid color shape.
  double _collapse = 0.0;

  /// Photo ↔ silhouette crossfade: 0 = the photo, 1 = the shape.
  ///
  /// Runs on its OWN ramp, looser than the collapse on purpose. It used
  /// to ride [_collapse] directly, and since that follows the pop spring
  /// — which is all but settled inside ~250ms — the picture was already
  /// gone by the time the shape landed, so the swap read as a cut rather
  /// than a dissolve.
  double _photoFade = 0.0;

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

  /// Drives the photo ↔ silhouette crossfade, slower than the collapse.
  late final AnimationController _photoFadeController;
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
    _photoFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _photoFadeController.addListener(() {
      if (mounted) setState(() => _photoFade = _photoFadeController.value);
    });
    _bgFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 340),
    );
    _bgFadeController.addListener(() {
      if (mounted) setState(() => _bgAlpha = _bgFadeController.value);
    });

    // Seed fit before any async analysis so a later _cycleFit is never
    // clobbered by a late restore from _loadBgTint.
    try {
      SharedPreferences.getInstance().then((prefs) {
        if (!mounted) return;
        final idx = prefs.getInt('preview_fit_index');
        if (idx != null && idx != _fitIndex) {
          setState(() => _fitIndex = idx % _fits.length);
        }
      });
    } catch (_) {}

    // Fallback: if the route never reports 'completed' (tests, embedders),
    // start anyway after a beat.
    _routeFallbackTimer =
        Timer(const Duration(milliseconds: 450), _beginProcessing);
    _loadBgTint();
    _loadImageAspect();
  }

  /// Header-only dimension read (no pixel decode): the source photo's
  /// aspect, so the outline square can hug the art's shorter edge.
  Future<void> _loadImageAspect() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(
        widget.imagePath,
      );
      final desc = await ui.ImageDescriptor.encoded(buffer);
      final w = desc.width.toDouble();
      final h = desc.height.toDouble();
      desc.dispose();
      buffer.dispose();
      if (!mounted || w <= 0 || h <= 0) return;
      setState(() => _imageAspect = w / h);
    } catch (_) {}
  }

  /// Photo-profile tint for the backdrop: same M3 analysis as the
  /// sticker shadow color. Fire-and-forget on open.
  Future<void> _loadBgTint() async {
    try {
      final style = await StickerStyleService.analyze(widget.imagePath);
      if (!mounted) return;
      setState(() {
        _bgTint = Color(style.dominantColor);
        // Seed the style too so a later cutout skips re-analyzing.
        _style ??= style;
      });
      // Ease the wash in — the analysis lands a beat after the route
      // does, and snapping the color on in a single frame was the
      // hiccup felt on the way into the preview.
      _bgFadeController.forward();
    } catch (_) {}
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
    // Preview-only opens never start the ML pipeline.
    if (!widget.autoCutout || _processingStarted || !mounted) return;
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
    _photoFadeController.dispose();
    _bgFadeController.dispose();
    super.dispose();
  }

  Future<void> _startProcessing() async {
    try {
      final service = SubjectCutoutService();
      final result = await service.cutoutAndSave(widget.imagePath);
      final savedPath = result.path;

      if (mounted) {
        // M3 theming engine on the source image (already seeded at
        // open for the tint wash — reuse, don't re-analyze).
        final style =
            _style ?? await StickerStyleService.analyze(widget.imagePath);
        // The reveal, in ONE beat under 300ms: cutout pops in and the
        // photo melt-morphs into the silhouette simultaneously — no
        // staged delays. Shimmer stops the instant it starts.
        _shimmerController.stop();
        setState(() {
          _style = style;
          _cutoutPath = savedPath;
          _state = _CutoutState.idle;
        });
        // Auto-lift NOW: the cutout pops up first, while the photo is
        // still full-size behind it...
        _startLift();
        // ...and the wash fades out on the same beat, handing the whole
        // backdrop back to the frosted glass. This replaced a circle that
        // contracted into the shape — the inward warp read as abrupt.
        _bgFadeController.reverse();
        // ...then the photo squeezes in behind the cutout, on the SAME
        // spring and starting on the SAME frame — one continuous motion.
        // This used to be staged 120ms behind on a softer spring, and
        // the two staggered springs read as a hitch rather than a
        // gesture. _collapse is clamped 0..1 at every use site, so the
        // overshoot only softens the landing, never the layout.
        _collapseController
            .animateWith(SpringSimulation(_popSpring, 0, 1, 0))
            .orCancel
            .catchError((_) {});
        // ...and the photo dissolves on a looser ramp of its own, started
        // on that same frame. The shape arrives at pop speed; the picture
        // takes its time leaving underneath it.
        _photoFadeController.forward(from: 0);
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
    // Haptic lives in _startLift — one voice per moment.
    _startLift();
  }

  /// M3-expressive pop: a light, stiff spring that overshoots ~16% and
  /// settles in ~0.4s (damping ratio 0.5, the expressive-button land).
  /// The old 200/14 spring was slow and flat — the cutout slid into
  /// place instead of bopping in.
  static final SpringDescription _popSpring =
      SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 300,
    ratio: 0.62,
  );

  void _startLift() {
    if (_state == _CutoutState.floating) return;
    // The cutout lands here: tap the haptic once as it leaves its mark.
    AppHaptics.tap();
    setState(() => _state = _CutoutState.lifted);
    _liftController.reset();
    _liftController.animateWith(
      SpringSimulation(_popSpring, 0, 1, 0),
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

  /// Close the preview. The saved cutout reaches the grid through
  /// [PhotoPreviewScreen.onSaved] (fired the moment the save starts), so
  /// nothing consumes a route result — and the route is the gallery
  /// sheet's OpenContainer, typed `Null`. Popping a record here threw,
  /// aborting the pop and leaving the navigator locked (the preview
  /// hung in `floating`).
  void _finishAndPop() {
    Navigator.pop(context);
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

  /// Tap-to-accept: the sticker's other way home. A tap isn't a throw,
  /// so it gets the light tick rather than [AppHaptics.launch], and it
  /// only applies once the cutout is lifted and waiting — during the
  /// reveal a tap has nothing to send yet.
  void _onTapAccept() {
    if (_state != _CutoutState.lifted) return;
    AppHaptics.tap();
    _startFloat();
  }

  bool get _isCutoutVisible =>
      _cutoutPath != null &&
      (_state == _CutoutState.lifted ||
       _state == _CutoutState.dragging ||
       _state == _CutoutState.floating);

  /// Silhouette card scale for the cutout. While lifted/dragging it
  /// rides the pop spring (0 → 1, overshoot included) so the shape
  /// blooms in behind the art on the same bounce as the sticker instead
  /// of blinking on at full size; 0 otherwise (the card only exists
  /// once the cutout does).
  double get _shapeCardScale =>
      (_state == _CutoutState.lifted || _state == _CutoutState.dragging)
          ? _liftController.value.clamp(0.0, 1.4)
          : 0.0;

  double _getScale() {
    switch (_state) {
      case _CutoutState.floating:
        return 1.0;
      case _CutoutState.lifted:
      case _CutoutState.dragging:
        // Bigger travel than the old 0.8→1.03: the pop reads as a pop,
        // and the spring's overshoot lands at rest size (1.0), matching
        // the grid cell the Hero flies into.
        return 0.7 + 0.3 * _liftController.value;
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
        // Snap visible early (2.2×): the sticker is already opaque
        // while the spring is still bouncing it into place — the M3
        // expressive "it's here" read, not a slow fade-up.
        return (_liftController.value * 2.2).clamp(0.0, 1.0);
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

  /// Screen-space origin for the floating cutout: dead center of the
  /// viewport (minus half the display size for top-left positioning).
  /// The cutout no longer preserves its photo-relative position —
  /// as soon as it's made it sits centered, ready to drag.
  Offset _floatOrigin(Size size, double displayW, double displayH) {
    final left = (size.width - displayW) / 2;
    final top = (size.height - displayH) / 2;
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
  /// out, then the collapse morph. The card morphs IN PLACE — it shrinks
  /// into the solid silhouette where it sits, never gliding toward the
  /// cutout (the dip-and-settle read as the photo sliding away). Size
  /// overshoots (easeOutBack); crossfade smooth; the photo ends fully
  /// invisible with the silhouette holding until the cutout's own card
  /// lands on top of it.
  Widget _buildBackgroundPhoto(Size size, double targetW, double targetH) {
    // Edge-to-edge width; the rotating border keeps its own (smaller,
    // square) size centered on top as a border-only overlay.
    final bgW = size.width;
    final bgH = size.height * 0.80;
    final c = _style?.dominantColor ?? kFallbackStickerColor;
    final tMove = Curves.easeOutBack.transform(_collapse.clamp(0.0, 1.0));
    final tFade = Curves.easeInOutCubic.transform(_collapse.clamp(0.0, 1.0));
    // Crossfade only: the box still collapses on the pop spring's own
    // timing above. This is the slow half of the swap.
    final tPhoto = Curves.easeInOutCubic.transform(
      _photoFade.clamp(0.0, 1.0),
    );
    final w = ui.lerpDouble(bgW, targetW, tMove) ?? bgW;
    final h = ui.lerpDouble(bgH, targetH, tFade) ?? bgH;
    // The morphing shape has to outlive the cutout's arrival: it is the
    // color's landing pad, so it stays mounted until the shrink lands.
    final morphing =
        _state == _CutoutState.processing || _bgAlpha > 0.0;
    final shaped = Stack(
      alignment: Alignment.center,
      children: [
        // Solid silhouette beneath, fading in as the photo absorbs —
        // then melting away the moment the cutout exists, so only ONE
        // shape remains: the cutout's own, which moves with the drag.
        AnimatedOpacity(
          opacity: _isCutoutVisible ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 250),
          child: M3Container(
            kStyleShapes[_shapeIndex],
            width: w,
            height: h,
            color: Color(c).withValues(alpha: tPhoto.clamp(0.0, 1.0)),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned.fill(
          // While processing, the photo breathes inside a morphing M3
          // clip (ambient loop) instead of its fixed shape — the image
          // itself signals work. Settles to the static shape on done.
          child: morphing
              ? SizedBox(
                  width: w,
                  height: h,
                  child: MorphingShapeClip(
                    // Static full-bleed image (no clip) with the morphing
                    // outline tracing on top at its own square size.
                    // The shrink comes later, as a spring behind the
                    // emerging cutout.
                    endScale: 1.0,
                    shrinkDuration: const Duration(seconds: 4),
                    clipChild: false,
                    // The mask is held off until the pick flight lands
                    // (see [_landed]): while the photo is still expanding
                    // the card is pure full-bleed art, so the pick reads
                    // as the tapped thumbnail growing into the picture.
                    // The shape then closes in over the last stretch of
                    // the route.
                    //
                    // Profile hue outside the shape: the photo only
                    // shows through the shape's own window, and the wash
                    // fades rather than snapping.
                    outsideColor:
                        _bgTint?.withValues(alpha: _bgAlpha * _landed),
                    // Hug the photo: landscape → its height, portrait
                    // → its width (null until the header read lands).
                    childAspectRatio: _imageAspect,
                    // Sits 1% inside the measurement — the window grew
                    // 10% off the old 0.9 trim, both axes.
                    outlineScale: 0.99,
                    // Shimmer rides the PHOTO, not the card: the mask
                    // above it limits the sweep to the shape's window,
                    // so no light leaks past the floating border.
                    child: _shimmer(
                      Opacity(
                        opacity: (1.0 - tPhoto).clamp(0.0, 1.0),
                        child: Image.file(
                          File(widget.imagePath),
                          fit: _fits[_fitIndex],
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ),
                )
              : M3Container(
                  kStyleShapes[_shapeIndex],
                  width: w,
                  height: h,
                  child: Opacity(
                    opacity: (1.0 - tPhoto).clamp(0.0, 1.0),
                    child: Image.file(
                      File(widget.imagePath),
                      fit: _fits[_fitIndex],
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
        ),
      ],
    );
    // No glide: the card morphs where it sits (see above). A Center does
    // the per-frame centering — no manual origin math — so as w/h shrink
    // through the collapse the card stays dead-center and the rotating
    // border keeps riding on top of the image.
    // Hero destination wraps the CARD BOX, never the surrounding
    // Center: a Hero measures its child's rect, and a full-screen
    // Center made the flight land on the whole screen — the tapped
    // thumbnail blew up edge-to-edge and swallowed the picture.
    Widget card = shaped;
    if (_state != _CutoutState.processing) {
      // Flick departure: the melted silhouette must NOT stay behind as a
      // static shape while the Hero flies home — it shrinks and fades
      // into the takeoff point in sync with the flight.
      final departing = _state == _CutoutState.floating;
      return Center(
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
      );
    }

    return Center(child: card);
  }

  /// Landing slot for the incoming pick flight: while the subject is
  /// still being cut out, the photo card is the Hero destination, so the
  /// tapped thumbnail's rect grows into it. Once the cutout arrives the
  /// same tag moves to the cutout (which then flies home to the grid),
  /// and only one of the two ever exists at a time.
  Widget _pickHero(Widget child) {
    final tag = widget.pickHeroTag;
    if (tag == null) return child;
    return Hero(
      tag: tag,
      createRectTween: stickerFlightTween,
      child: child,
    );
  }

  /// How far the pick flight has landed: 0 while the tapped thumbnail is
  /// still expanding into the photo, 1 once it is home.
  ///
  /// The whole finished preview card used to fly as one widget, so what
  /// the user saw was a postage-stamp-sized copy of the outline + shape
  /// window + picture blowing up to full size — abrupt, and the opposite
  /// of a Material app launch. Now only the full-bleed photo expands,
  /// and the outline, the mask and the profile wash close in over the
  /// last stretch of the route.
  double get _landed {
    final t = _routeAnim?.value ?? 1.0;
    // Hold the chrome off for the first ~60% of the flight: the photo
    // must still be visibly expanding when the outline starts to draw.
    return Curves.easeOut.transform(((t - 0.6) / 0.4).clamp(0.0, 1.0));
  }

  /// Rebuilds on every frame of the pick route's own animation, which is
  /// what [_landed] reads — the route drives the reveal, so there is no
  /// magic timer to drift out of sync with the transition.
  Widget _routeRevealed(Widget Function() build) {
    final anim = _routeAnim;
    if (anim == null) return build();
    return AnimatedBuilder(animation: anim, builder: (_, _) => build());
  }

  /// Silver shimmer wave — the progress indicator while the subject is
  /// cut out. Wraps the PHOTO itself rather than the whole card, so the
  /// sweep is bounded by the picture: the profile-color mask covers
  /// everything outside the floating border, taking the highlight with
  /// it, and the light never leaks onto the color around the shape.
  Widget _shimmer(Widget child) {
    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, child) {
        // Ease the sweep so the wave accelerates through the middle
        // and rests at the edges — reads as light glancing off glass
        // instead of a constant-speed scanner.
        final t = Curves.easeInOutSine.transform(_shimmerController.value);
        // Tighter travel: the light spends most of the pass ON the
        // picture instead of sweeping through off-screen dead air
        // (the old ±1.7 range put the core on-picture only ~30% of
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
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Exactly the fullscreen sticker's box (see StickerDetailScreen), so
    // the cutout that pops in here — its M3 shadow included — is already
    // the size it will be when the sticker is opened full screen.
    final cutoutDisplayW = size.width * 0.8;
    final cutoutDisplayH =
        (size.width * 0.8 * 4 / 3).clamp(0.0, size.height * 0.55);

    return Scaffold(
      // Transparent route, but the screen itself is filled edge to edge
      // with the photo-profile hue below — the grid behind never shows.
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Frosted glass — the same recipe the fullscreen sticker view
          // uses (StickerDetailScreen): σ16 blur of the live grid behind,
          // plus a 20% black wash. The route must be non-opaque for this
          // to have anything to blur; on an opaque route it reads black.
          //
          // Pre-cutout the profile color sits ON TOP of the glass (the
          // morphing element's outside fill), so the frost only becomes
          // the backdrop once that color has collapsed into the sticker.
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
            child: _pickHero(
              _routeRevealed(
                () => _buildBackgroundPhoto(
                  size,
                  cutoutDisplayW,
                  cutoutDisplayH,
                ),
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
          // into the matching grid cell. Sits dead-center from the
          // moment it's made; drag offset applies on top afterwards.
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
                // Tap the sticker to accept it: same path home as a flick,
                // just without the throw.
                onTap: _onTapAccept,
                onPanStart: _state == _CutoutState.lifted ? _onDragStart : null,
                onPanUpdate: _state == _CutoutState.lifted || _state == _CutoutState.dragging
                    ? _onDragUpdate : null,
                onPanEnd: _state == _CutoutState.dragging ? _onDragEnd : null,
                child: Hero(
                  tag: widget.heroTag,
                  // Curved arc home, matching the grid cell.
                  createRectTween: stickerFlightTween,
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
                        // Full-bleed silhouette (same as fullscreen): the
                        // shadow is the box, not 70% of it.
                        shapeScale: 1.0,
                        // The shadow the color collapsed into keeps
                        // turning — the outline became a solid M3 shape
                        // rather than stopping dead.
                        rotateSilhouette: true,
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
