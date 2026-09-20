import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/outfit_sticker.dart';
import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../services/analytics_service.dart';
import '../services/growth_service.dart';
import '../services/moment_paywall_service.dart';
import '../services/notification_service.dart';
import '../services/pro_access_service.dart';
import '../services/revenuecat_service.dart';
import '../services/sticker_style_service.dart';
import '../services/subject_cutout_service.dart';
import '../services/widget_service.dart';
import '../widgets/gallery_bottom_sheet.dart';
import '../widgets/genie_flight.dart';
import '../widgets/sticker_grid.dart';
import '../widgets/wordmark_shadow.dart';
import 'photo_preview_screen.dart';
import 'growth_prompt_sheet.dart';
import 'shape_demo_sheet.dart';
import 'sticker_detail_screen.dart';

/// Apple Notes dark-mode palette.
class NotesColors {
  static const bg = Color(0xFF1C1C1E); // true system dark surface
  static const bar = Color(0xFF2C2C2E); // elevated surface
  static const text = Color(0xFFFFFFFF);
  static const sub = Color(0xFF98989E);
  static const yellow = Color(0xFFFFD60A); // notes accent
}

class GalleryScreen extends StatefulWidget {
  final void Function()? onReady;

  const GalleryScreen({super.key, this.onReady});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<OutfitSticker> _stickers = [];
  final _sheetKey = GlobalKey<GalleryBottomSheetState>();
  final _gridController = ScrollController();
  final _bodyKey = GlobalKey();
  late final ConfettiController _confettiPop;

  /// Center of the landing sticker (body-Stack-local). The single tiny
  /// confetti burst showers once from exactly this spot, in all directions.
  Offset? _burstCenter;

  /// True when the landing sticker is the first one ever (milestone tick).
  bool _pendingMilestone = false;

  /// Id of the sticker currently flying home (if any). Its grid cell hosts
  /// the Hero destination + landing pop; cleared once it settles.
  String? _justAddedId;

  /// Delete mode: stickers shake with × badges.
  bool _jiggling = false;

  /// Solid M3 shape backdrop behind small grid stickers. Toggleable
  /// from the appbar wordmark; persisted next to stickers.json.
  /// The shadow indicator cycles to the next M3 shape on every toggle.
  bool _shapeBgOn = true;
  int _indicatorShape = 7; // Shapes.arch

  /// File path of a trashed sticker awaiting the Undo window, if any.
  String? _trashPath;

  /// Model of the trashed sticker (style metadata survives Undo).
  OutfitSticker? _trashSticker;

  /// Former slot of the trashed sticker, for exact Undo restoration.
  int _trashIndex = 0;

  /// Set when the Undo button wins the race against snackbar dismissal.
  bool _undoConsumed = false;

  void _dismissSheet() {
    _sheetKey.currentState?.collapse();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _enterJiggle() {
    if (_jiggling || _stickers.isEmpty) return;
    AppHaptics.mode();
    setState(() => _jiggling = true);
  }

  void _exitJiggle() {
    if (!_jiggling) return;
    AppHaptics.mode();
    setState(() => _jiggling = false);
  }

  /// Deletes [sticker]: removes it now, parks its PNG in a temp trash file,
  /// and offers Undo until the snackbar goes away.
  Future<void> _deleteSticker(OutfitSticker sticker) async {
    final index = _stickers.indexWhere((s) => s.id == sticker.id);
    if (index < 0) return;
    // A newer delete flushes whatever the previous Undo window held.
    await _purgeTrash();
    AppHaptics.tap();
    final removed = _stickers[index];
    _trashIndex = index;
    _trashSticker = removed;
    _undoConsumed = false;
    setState(() {
      _stickers.removeAt(index);
      if (_stickers.isEmpty) _jiggling = false;
      if (_justAddedId == removed.id) _justAddedId = null;
    });
    await _saveStickers();
    // Park the PNG so Undo can bring it back byte-identical.
    try {
      final dir = await getTemporaryDirectory();
      final trash = File('${dir.path}/trash_${removed.id}.png');
      await File(removed.imagePath).rename(trash.path);
      _trashPath = trash.path;
    } catch (_) {
      _trashPath = null;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(
          SnackBar(
            // Transparent shell: the frosted content below is the toast.
            backgroundColor: Colors.transparent,
            elevation: 0,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            padding: EdgeInsets.zero,
            duration: const Duration(seconds: 4),
            content: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  color: const Color(0xFF3A3A3C).withValues(alpha: 0.72),
                  padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Sticker removed',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          // Flag first: the manual hide below does NOT
                          // complete with reason.action, so the purge gate
                          // below keys off this instead.
                          _undoConsumed = true;
                          messenger.hideCurrentSnackBar();
                          _undoDelete();
                        },
                        child: const Text(
                          'Undo',
                          style: TextStyle(
                            color: NotesColors.yellow,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        )
        .closed
        .then((_) {
      // Anything but an Undo tap purges the trash for good.
      if (!_undoConsumed) _purgeTrash();
    });
  }

  /// Restores the trashed sticker into its exact former slot, with its
  /// style metadata intact.
  Future<void> _undoDelete() async {
    final trashPath = _trashPath;
    final trashed = _trashSticker;
    _trashPath = null;
    _trashSticker = null;
    if (trashPath == null || trashed == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final restored = File(
        '${dir.path}/fitcheck_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(trashPath).rename(restored.path);
      final sticker = OutfitSticker(
        id: trashed.id,
        imagePath: restored.path,
        createdAt: trashed.createdAt,
        edgeColor: trashed.edgeColor,
        haloStripped: trashed.haloStripped,
      );
      if (!mounted) return;
      final slot = _trashIndex.clamp(0, _stickers.length);
      setState(() => _stickers.insert(slot, sticker));
      await _saveStickers();
    } catch (_) {
      // Trash already gone; nothing to restore.
    }
  }

  Future<void> _purgeTrash() async {
    final trashPath = _trashPath;
    _trashPath = null;
    _trashSticker = null;
    if (trashPath == null) return;
    try {
      await File(trashPath).delete();
    } catch (_) {
      // Already gone — fine.
    }
  }

  @override
  void dispose() {
    _gridController.dispose();
    _confettiPop.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _confettiPop =
        ConfettiController(duration: const Duration(milliseconds: 1050));
    _boot();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onReady?.call();
    });
  }

  Future<void> _boot() async {
    await _loadStickers();
    await _loadShapeBgFlag();
    if (mounted) setState(() {});
    await _migrateLegacy();
    // One-shot soft paywall on first gallery entry (post-onboarding).
    // Dismissable; the hard gate fires at the 30-sticker limit.
    if (await ProAccessService.consumeOnboardingPaywall()) {
      await RevenueCatService.instance.ensureInitialized();
      if (!RevenueCatService.instance.isPro && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        await MomentPaywallService.maybeShow(
          context,
          placement: 'onboarding',
          locked: false,
        );
      }
    }
  }

  Future<void> _loadShapeBgFlag() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final flag = File('${dir.path}/shape_bg.txt');
      if (await flag.exists()) {
        _shapeBgOn = (await flag.readAsString()).trim() != '0';
      }
    } catch (_) {
      // Missing or unreadable flag: keep the default (on).
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt('indicator_shape_index');
      if (idx != null) _indicatorShape = idx % kStyleShapes.length;
    } catch (_) {}
  }

  /// Appbar button: straight on/off toggle for the shape backdrop.
  /// Appbar heart button: every open advances a manual rotation through
  /// review → share → widgets (+ reminders while permission is missing).
  /// No count/throttle/snooze gates — the user asked for it.
  Future<void> _openSupportSheet() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    // Eligible actions in rotation order; reminders joins the front
    // until the notification permission is granted.
    final actions = <GrowthAction>[
      GrowthAction.review,
      GrowthAction.share,
      GrowthAction.widgets,
    ];
    try {
      if (!await NotificationService.areEnabled()) {
        actions.insert(0, GrowthAction.reminders);
      }
    } catch (_) {}

    final step = prefs.getInt('support_manual_rotation') ?? 0;
    await prefs.setInt('support_manual_rotation', step + 1);
    final action = actions[step % actions.length];

    if (!mounted) return;
    await showGrowthPromptSheet(context, action);
  }

  void _toggleShapeBg() {
    AppHaptics.tap();
    setState(() {
      _shapeBgOn = !_shapeBgOn;
      _indicatorShape = (_indicatorShape + 1) % kStyleShapes.length;
    });
    _persistShapeBg();
  }

  /// Appbar Pro button: launches the paywall on demand (manual
  /// placement, dismissable). Pro users land in Customer Center
  /// instead — manage, restore, or cancel from one place.
  Future<void> _openPro() async {
    AppHaptics.tap();
    await RevenueCatService.instance.ensureInitialized();
    if (!mounted) return;
    if (RevenueCatService.instance.isPro) {
      await RevenueCatService.instance.presentCustomerCenter();
      return;
    }
    await MomentPaywallService.maybeShow(
      context,
      placement: 'manual',
      locked: false,
      force: true,
    );
  }

  Future<void> _persistShapeBg() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/shape_bg.txt')
          .writeAsString(_shapeBgOn ? '1' : '0');
    } catch (_) {
      // Toggle still applies for this session if the write fails.
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('indicator_shape_index', _indicatorShape);
    } catch (_) {}
  }



  /// One-time backfill for stickers saved halo-free while live borders
  /// were in testing: stamps the even white ring in place, then marks
  /// them baked. Silent; single rebuild at the end if anything changed.
  Future<void> _migrateLegacy() async {
    bool changed = false;
    for (int i = 0; i < _stickers.length; i++) {
      final s = _stickers[i];
      if (!s.haloStripped) continue;
      try {
        await SubjectCutoutService.addWhiteRing(s.imagePath);
        _stickers[i] = s.copyWith(haloStripped: false);
        changed = true;
      } catch (_) {
        // Unreadable file: leave it alone this launch.
      }
    }
    if (changed) {
      await _saveStickers();
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadStickers() async {
    final dir = await getApplicationDocumentsDirectory();
    final metaFile = File('${dir.path}/stickers.json');
    if (await metaFile.exists()) {
      final json = await metaFile.readAsString();
      final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      setState(() => _stickers = list.map(OutfitSticker.fromJson).toList());
    }
  }

  Future<void> _saveStickers() async {
    final dir = await getApplicationDocumentsDirectory();
    final metaFile = File('${dir.path}/stickers.json');
    final json = jsonEncode(_stickers.map((s) => s.toJson()).toList());
    await metaFile.writeAsString(json);
  }

  Future<void> _onGalleryPick(AssetEntity asset) async {
    // Free-tier gate: 30 free stickers, then the locked paywall.
    // Pro users and users inside quota pass straight through.
    await RevenueCatService.instance.ensureInitialized();
    if (!await ProAccessService.canCreateFree()) {
      if (!mounted) return;
      final unlocked = await MomentPaywallService.maybeShow(
        context,
        placement: 'create_gate',
        locked: true,
      );
      if (!unlocked) return;
    }
    String? pickedPath;
    try {
      // Preferred: read the original bytes and write a fresh temp file.
      // asset.originFile can return stale/empty cache entries which fail
      // to decode downstream ("Invalid image data").
      final bytes = await asset.originBytes;
      if (bytes != null && bytes.isNotEmpty) {
        final dir = await getTemporaryDirectory();
        final f = File(
          '${dir.path}/pick_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await f.writeAsBytes(bytes);
        pickedPath = f.path;
      } else {
        final origin = await asset.originFile;
        pickedPath = origin?.path;
      }
    } catch (_) {
      final origin = await asset.originFile;
      pickedPath = origin?.path;
    }
    if (pickedPath == null || !mounted) return;
    final imagePath = pickedPath;

    // Id is minted upfront so the preview and the future grid cell share
    // one Hero tag for the genie flight home. The shape is rolled from
    // the photo's asset id — the same shape its sheet thumbnail shows.
    final stickerId = const Uuid().v4();
    final heroTag = 'sticker-$stickerId';
    final shapeIndex = randomShapeIndexForAsset(asset.id);

    final saved = await Navigator.push<(String?, StickerStyle)>(
      context,
      zoomPageRoute<(String?, StickerStyle)>(
        page: PhotoPreviewScreen(
          imagePath: imagePath,
          heroTag: heroTag,
          initialShapeIndex: shapeIndex,
          // Insert the cell while the preview is still up so the Hero
          // destination exists when the pop flight begins.
          onSaved: (path, style) => _insertSticker(stickerId, path, style),
        ),
      ),
    );
    // Normally already inserted via onSaved; this is just a safety net.
    final savedPath = saved?.$1;
    if (savedPath != null &&
        !_stickers.any((s) => s.imagePath == savedPath)) {
      await _insertSticker(
        const Uuid().v4(),
        savedPath,
        saved?.$2 ??
            StickerStyle(
              dominantColor: kFallbackStickerColor,
              shapeIndex: shapeIndex,
            ),
      );
    }
  }

  /// Inserts the sticker at the top and scrolls it into view for landing.
  /// The touchdown (confetti + milestone tick) is driven by the landing
  /// cell itself via [_onTouchdown], timed to the genie flight.
  Future<void> _insertSticker(
    String id,
    String path,
    StickerStyle style,
  ) async {
    if (_stickers.any((s) => s.id == id)) return;
    _pendingMilestone = _stickers.isEmpty;
    final sticker = OutfitSticker(
      id: id,
      imagePath: path,
      createdAt: DateTime.now(),
      // White halo is baked at cut time.
      haloStripped: false,
      // Image-derived M3 style: dominant color + hue-picked shape.
      shapeIndex: style.shapeIndex,
      dominantColor: style.dominantColor,
    );
    if (!mounted) return;
    setState(() {
      _stickers.insert(0, sticker);
      _justAddedId = id;
    });
    // Core-loop funnel: every save counts; the first one is activation.
    AnalyticsService.instance.logStickerSaved(totalStickers: _stickers.length);
    unawaited(ProAccessService.recordStickerSaved());
    await _saveStickers();
    if (_gridController.hasClients) {
      await _gridController.animateTo(
        0,
        duration: AppMotion.standard,
        curve: AppMotion.appleEase,
      );
    }
    // Growth loop: widgets refresh every save; the suggestion sheet
    // (review/share/widget prompt) fires on the 1st + every 5th save,
    // 5s after touchdown.
    unawaited(WidgetService.updateAll());
    if (mounted) {
      unawaited(GrowthService.onStickerAdded(context));
    }
  }

  /// The sticker just touched down in its grid slot: anchor one
  /// explosive confetti pop on its center (plus the milestone tick for
  /// the first sticker ever).
  void _onTouchdown(Offset globalCenter) {
    if (!mounted) return;
    if (_pendingMilestone) {
      _pendingMilestone = false;
      AppHaptics.milestone();
    }
    if (AppMotion.reducedMotion(context)) return;
    final stackBox =
        _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    setState(() => _burstCenter = stackBox.globalToLocal(globalCenter));
    // Post-frame: the overlay widget must be listening before play(),
    // otherwise a first-ever burst fires into the void and is lost.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _confettiPop.play();
    });
  }

  void _openDetail(OutfitSticker sticker) {
    Navigator.push(
      context,
      geniePageRoute(
        page: StickerDetailScreen(
          sticker: sticker,
          // Flight starts now (flick or system back): soft tick timed
          // exactly to touchdown. No squash — it lands clean.
          onFlightHome: () {
            Future.delayed(kGenieFlight, () {
              if (mounted) AppHaptics.step();
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // System back exits delete mode first instead of leaving the app.
    return PopScope(
      canPop: !_jiggling,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitJiggle();
      },
      child: Scaffold(
      backgroundColor: NotesColors.bg,
      appBar: AppBar(
        backgroundColor: NotesColors.bg,
        foregroundColor: NotesColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // Taller bar so the 2x logo (64px) and 2x wordmark fit cleanly.
        toolbarHeight: 80,
        title: Row(
          children: [
            // Transparent logo, no chip behind it.
            SizedBox(
              width: 64,
              height: 64,
              child: Image.asset(
                'assets/logo3.png',
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(width: 12),
            // StickerPants wordmark (2:1): tap toggles the M3 cell
            // backdrops. The shadow indicator behind it shows state —
            // same height, narrower, centered — cycling shape each tap.
            GestureDetector(
              onTap: _toggleShapeBg,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedOpacity(
                    opacity: _shapeBgOn ? 1.0 : 0.0,
                    duration: AppMotion.standard,
                    child: WordmarkShadow(
                      height: 57,
                      shape: kStyleShapes[_indicatorShape
                          .clamp(0, kStyleShapes.length - 1)],
                    ),
                  ),
                  Image.asset(
                    'assets/stickerpants.png',
                    height: 57,
                    fit: BoxFit.contain,
                  ),
                ],
              ),
            ),
          ],
        ),        actions: [
          // Support StickerPants: opens the growth sheet on demand —
          // review, share, widgets, or reminders (no throttle, so it's
          // always available from here; snooze does not apply either,
          // because the user asked for it themselves).
          IconButton(
            tooltip: 'Support StickerPants',
            onPressed: _openSupportSheet,
            icon: const Icon(
              Icons.favorite_border_rounded,
              color: NotesColors.text,
            ),
          ),
          // Shape demo: endless M3E morph + rotation overlay.
          IconButton(
            tooltip: 'Shape demo',
            onPressed: () => showShapeDemo(context),
            icon: const Icon(
              Icons.auto_awesome_outlined,
              color: NotesColors.text,
            ),
          ),
          // Pro: paywall on demand (Customer Center when subscribed).
          IconButton(
            tooltip: 'StickerPants Pro',
            onPressed: _openPro,
            icon: const Icon(
              Icons.workspace_premium_outlined,
              color: NotesColors.yellow,
            ),
          ),
          // iOS-style Done exits delete mode.
          if (_jiggling)
            TextButton(
              onPressed: _exitJiggle,
              child: const Text(
                'Done',
                style: TextStyle(
                  color: NotesColors.yellow,
                  fontWeight: FontWeight.w600,
                  fontSize: 17,
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        key: _bodyKey,
        children: [
          // Grid runs full-bleed underneath; the sheet floats above it so
          // stickers visibly frost through the glass.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissSheet,
              onPanDown: (_) => _dismissSheet(),
              child: StickerGrid(
                stickers: _stickers,
                onTap: _openDetail,
                controller: _gridController,
                shapeBg: _shapeBgOn,
                indicatorShape: _indicatorShape,
                shapeScale: 0.7,
                justAddedId: _justAddedId,
                onTouchdown: _onTouchdown,
                jiggling: _jiggling,
                onEnterJiggle: _enterJiggle,
                onDelete: _deleteSticker,
                onExitJiggle: _exitJiggle,
                onLanded: () {
                  if (mounted) setState(() => _justAddedId = null);
                },
                bottomInset: GalleryBottomSheet.peekHeight +
                    MediaQuery.of(context).padding.bottom,
              ),
            ),
          ),
          // Resizable one-row gallery sheet replaces the + button.
          // Tapping away (grid above) collapses it via _dismissSheet,
          // plus the sheet itself collapses on TapRegion outside-tap
          // and on focus loss. Sheet taps also exit delete mode.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_jiggling) _exitJiggle();
              },
              child: GalleryBottomSheet(key: _sheetKey, onPick: _onGalleryPick),
            ),
          ),
          // One big explosive pop from the landing sticker's own spot, in
          // all directions, on every save. Always mounted (parked offscreen
          // until needed) so play() never fires without a listener.
          // Pointer-transparent so it never eats gestures.
          Positioned(
            left: (_burstCenter?.dx ?? -1000) - 130,
            top: (_burstCenter?.dy ?? -1000) - 130,
              child: IgnorePointer(
                child: SizedBox(
                  width: 260,
                  height: 260,
                  child: ConfettiWidget(
                    confettiController: _confettiPop,
                    blastDirectionality: BlastDirectionality.explosive,
                    emissionFrequency: 0,
                    numberOfParticles: 50,
                    maxBlastForce: 24,
                    minBlastForce: 8,
                    gravity: 0.3,
                    particleDrag: 0.05,
                    createParticlePath: _drawStar,
                    colors: const [
                      NotesColors.yellow,
                      Colors.white,
                      Color(0xFFFF9F0A),
                      Color(0xFF0A84FF),
                      Color(0xFFFF375F),
                      Color(0xFF30D158),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Five-point star path for confetti pieces (drawn in a 10x10 box).
  Path _drawStar(Size size) {
    const spikes = 5;
    const outer = 5.0;
    const inner = 2.2;
    final path = Path();
    for (int i = 0; i < spikes * 2; i++) {
      final r = i.isEven ? outer : inner;
      final a = (i * math.pi / spikes) - math.pi / 2;
      final x = size.width / 2 + r * math.cos(a);
      final y = size.height / 2 + r * math.sin(a);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }
}
