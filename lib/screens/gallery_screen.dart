import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
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
import 'growth_prompt_sheet.dart';
import 'expired_upsell_sheet.dart';
import 'max_thankyou_sheet.dart';
import 'onboarding_flow.dart';
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

class _GalleryScreenState extends State<GalleryScreen>
    with WidgetsBindingObserver {
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

  /// Wordmark shadow color index into the personal palette (the
  /// stickers' own dominant shades). Persisted; advanced per toggle.
  int _indicatorColorIndex = 0;

  /// Personal palette: distinct dominant shades of the current
  /// stickers, brand yellow when the gallery is empty.
  List<int> get _indicatorPalette {
    final shades = <int>[];
    for (final s in _stickers) {
      final c = s.dominantColor;
      if (c != null && !shades.contains(c)) shades.add(c);
    }
    if (shades.isEmpty) shades.add(0xFFFFD60A);
    return shades;
  }

  int get _indicatorColor {
    final palette = _indicatorPalette;
    return palette[_indicatorColorIndex % palette.length];
  }

  /// Wordmark shadow height multiplier (shape lab). Sticker backdrops
  /// are hardcoded to 1.0 — not user-tunable.
  double _markScale = 1.0;

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
    // (The '-' badge fires the haptic on touch-down; do not fire a second
    // one here — it lands after this await and reads as a late buzz.)
    await _purgeTrash();
    // Deleting is a churn moment: keep growth asks away from it.
    unawaited(GrowthService.noteBadMoment());
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
    unawaited(WidgetService.updateAll(bgColor: _indicatorColor));
    // Park the file so Undo can bring it back byte-identical. The trash
    // keeps the sticker's own extension so .webp and legacy .png
    // stickers stay distinguishable through delete/undo.
    try {
      final dir = await getTemporaryDirectory();
      final ext = removed.imagePath.endsWith('.webp') ? '.webp' : '.png';
      final trash = File('${dir.path}/trash_${removed.id}$ext');
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
      final ext = trashPath.endsWith('.webp') ? '.webp' : '.png';
      final restored = File(
        '${dir.path}/fitcheck_${DateTime.now().millisecondsSinceEpoch}$ext',
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
      unawaited(WidgetService.updateAll(bgColor: _indicatorColor));
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
    WidgetsBinding.instance.removeObserver(this);
    RevenueCatService.instance
        .removeListener(_onCustomerInfoForWordmark);
    _gridController.dispose();
    _confettiPop.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _confettiPop =
        ConfettiController(duration: const Duration(milliseconds: 1050));
    // Max wordmark reactivity: boot-as-Pro, post-purchase, expiry and
    // resume refresh all flow through CustomerInfo updates.
    RevenueCatService.instance.addListener(_onCustomerInfoForWordmark);
    _boot();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onReady?.call();
    });
  }

  /// Last launch/foreground paywall ask (ms). Keeps boot and the first
  /// resume from stacking two sheets back-to-back.
  int _lastLaunchAskMs = 0;

  Future<void> _boot() async {
    await _loadStickers();
    await _loadShapeBgFlag();
    try {
      final prefs = await SharedPreferences.getInstance();
      _m3Thumbs = prefs.getBool('m3_thumbs') ?? false;
    } catch (_) {}
    if (mounted) setState(() {});
    await _migrateLegacy();
    // Widget rotation rolls forward on every boot (daily stickers,
    // 2x-daily funny line) when its day/period turned overnight.
    unawaited(WidgetService.maybeRotate());
    // The one-shot post-onboarding soft paywall is gone: the splash now
    // opens the paywall on every launch instead. Pro users still get
    // their one-time welcome-back sheet.
    try {
      await RevenueCatService.instance.ensureInitialized();
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool('max_thankyou_seen') ?? false;
      if (!seen && RevenueCatService.instance.isPro && mounted) {
        await MaxThankYouSheet.show(context, restored: true);
      }
    } catch (_) {}
    // The launch paywall belongs to the splash now (every launch, once
    // onboarding is finished) — showing it here too would stack two.
    // This screen only owns the foreground ask.
  }

  /// Launch/foreground ask for non-subscribers: soft paywall, forced
  /// past quota + frequency caps. Guarded: Pro passes silently, never
  /// within 60s of the last ask, and only when the gallery is the
  /// current route (never over preview/detail/sheets).
  Future<void> _launchPaywallAsk(String placement) async {
    try {
      await RevenueCatService.instance.ensureInitialized();
      if (RevenueCatService.instance.isPro || !mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastLaunchAskMs < const Duration(seconds: 60).inMilliseconds) {
        return;
      }
      final route = ModalRoute.of(context);
      if (!(route?.isCurrent ?? false)) return;
      _lastLaunchAskMs = now;
      await MomentPaywallService.maybeShow(
        context,
        placement: placement,
        locked: false,
        force: true,
      );
    } catch (_) {}
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
      final cidx = prefs.getInt('indicator_color_index');
      if (cidx != null) _indicatorColorIndex = cidx;
      final mark = prefs.getDouble('wordmark_shadow_scale');
      if (mark != null) _markScale = mark.clamp(0.5, 1.5);
    } catch (_) {}
  }

  /// Appbar button: straight on/off toggle for the shape backdrop.
  /// Appbar heart button: every open advances a manual rotation through
  /// review → share → widgets (+ reminders while permission is missing).
  /// No count/throttle/snooze gates — the user asked for it.
  Future<void> _openSupportSheet() async {
    if (!mounted) return;
    // Same rotation cursor as the automatic triggers (no throttle
    // here): every manual open advances to the next eligible page,
    // so debug launches alternate too.
    final eligible = await GrowthService.eligibleActions();
    final action = await GrowthService.pickNext(eligible);
    if (action == null || !mounted) return;
    await showGrowthPromptSheet(context, action, actions: eligible);
  }

  void _onCustomerInfoForWordmark(CustomerInfo _) {
    // Entitlement flips (subscribe / restore / expiry / resume) swap
    // the wordmark between Max and standard art.
    if (mounted) setState(() {});
  }

  /// Max subscribers get the Max lockup everywhere the wordmark shows.
  String get _wordmarkAsset =>
      RevenueCatService.instance.isPro
          ? 'assets/stickerpantsmax.webp'
          : 'assets/stickerpants.webp';

  /// Max lockup stands alone — the pants logo hides wherever it shows.
  /// Sticky state (not strict entitlement): offline/cold starts keep
  /// painting Max until a definitive update says otherwise.
  bool get _isMax => RevenueCatService.instance.isProSticky;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume refresh: a purchase, restore, expiry or cancellation that
    // happened elsewhere reconciles the moment we're foregrounded.
    // Widget rotation also rolls forward here (daily stickers, 2x-daily
    // funny line) when its day/period turned while we were away.
    if (state == AppLifecycleState.resumed) {
      unawaited(() async {
        await RevenueCatService.instance.refreshCustomerInfo();
        await WidgetService.maybeRotate();
        if (mounted) setState(() {});
        // Foreground ask for non-subscribers (guarded inside).
        if (mounted) await _launchPaywallAsk('app_foreground');
      }());
    }
  }

  void _toggleShapeBg() {
    AppHaptics.tap();
    setState(() {
      _shapeBgOn = !_shapeBgOn;
      _indicatorShape = (_indicatorShape + 1) % kStyleShapes.length;
      _indicatorColorIndex++;
    });
    _persistShapeBg();
    // Wordmark color drives the homescreen widget backdrop too — every
    // toggle re-tints the cookie behind the stickers.
    unawaited(WidgetService.updateAll(bgColor: _indicatorColor));
  }

  /// Fire-now (debug card): post the morning/night copy immediately —
  /// proves display + permission + channel without waiting for a slot.
  Future<void> _toggleNotif(String type) async {
    AppHaptics.tap();
    final which = type == 'fire_night' ? 'night' : 'morning';
    final enabled = await NotificationService.areEnabled();
    final granted =
        enabled || await NotificationService.requestPermissions();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enable notifications in Settings first'),
        ),
      );
      return;
    }
    await NotificationService.fireNow(which);
  }

  /// Sheet thumbnail style (debug card toggle, persisted):
  /// M3 expressive shapes vs plain rounded squares.
  bool _m3Thumbs = false;

  Future<void> _toggleM3Thumbs(bool on) async {
    AppHaptics.tap();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('m3_thumbs', on);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _m3Thumbs = on);
  }

  /// Debug card: relaunch onboarding on demand (preview mode — pops
  /// back here, analytics stay quiet).
  Future<void> _openOnboardingPreview() async {
    if (!mounted) return;
    AppHaptics.tap();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const OnboardingFlow(debugPreview: true),
      ),
    );
  }

  /// Debug card: fast-forward into onboarding on one of its own pages —
  /// `first_wish` (the photo picker) or `aura` (the cutout reveal). The
  /// real pages are used, so the picker → preview → reveal handoff can be
  /// worked on without walking the six questions first.
  Future<void> _openOnboardingAt(String page) async {
    if (!mounted) return;
    AppHaptics.tap();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            OnboardingFlow(debugPreview: true, debugStartAt: page),
      ),
    );
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
      await prefs.setInt('indicator_color_index', _indicatorColorIndex);
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

  /// Free-tier gate: 30 free stickers, then the expired upsell sheet.
  /// Pro users and users inside quota pass straight through. The sheet
  /// pitches Max first; Get Max opens the locked paywall from there.
  Future<bool> _passesCreateGate() async {
    await RevenueCatService.instance.ensureInitialized();
    if (!await ProAccessService.canCreateFree()) {
      if (!mounted) return false;
      return ExpiredUpsellSheet.show(
        context,
        onGetMax: () => MomentPaywallService.maybeShow(
          context,
          placement: 'expired_upsell',
          locked: true,
        ),
      );
    }
    return true;
  }

  Future<void> _onGalleryPick(AssetEntity asset) async {
    if (!await _passesCreateGate()) return;
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
    // Id minted upfront so the preview and the future grid cell share
    // one Hero tag for the genie flight home. Shape rolls from the
    // asset id — the same seed its sheet thumbnail shows.
    final stickerId = const Uuid().v4();
    // Warm the image cache so the container-transform flight isn't
    // swallowed by first-frame decode.
    try {
      await precacheImage(FileImage(File(imagePath)), context);
    } catch (_) {}
    if (!mounted) return;
    // The sheet's OpenContainer performs the app-launch-style open:
    // thumbnail blob expands into the fullscreen (closed→open morph).
    _sheetKey.currentState?.openPreview(
      GalleryPickData(
        assetId: asset.id,
        imagePath: imagePath,
        heroTag: 'sticker-$stickerId',
        shapeIndex: randomShapeIndexForAsset(asset.id),
        onSaved: (path, style) => _insertSticker(stickerId, path, style),
      ),
    );
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
    // Growth loop: widgets refresh every save (newest-first window);
    // the suggestion sheet
    // (review/share/widget prompt) fires on the 1st + every 5th save,
    // 5s after touchdown.
    unawaited(
      WidgetService.updateAll(bgColor: _indicatorColor, resetRotation: true),
    );
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
            // Transparent logo, no chip behind it. Hidden for Max —
            // the lockup stands alone.
            if (!_isMax) ...[
              SizedBox(
                width: 64,
                height: 64,
                child: Image.asset(
                  'assets/logo3.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
            ],
            // Wordmark (Max lockup for subscribers): tap toggles the
            // M3 cell backdrops. The shadow indicator behind it shows
            // state — cycling shape each tap.
            GestureDetector(
              onTap: _toggleShapeBg,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedOpacity(
                    opacity: _shapeBgOn ? 1.0 : 0.0,
                    duration: AppMotion.standard,
                    child: WordmarkShadow(
                      height: 57 * _markScale,
                      shape: kStyleShapes[_indicatorShape
                          .clamp(0, kStyleShapes.length - 1)],
                      color: _indicatorColor,
                      // Max lockup is wider: fixed 65% shadow width.
                      widthRatio: _isMax ? 0.65 : 1.0,
                    ),
                  ),
                  Image.asset(
                    _wordmarkAsset,
                    height: 57,
                    fit: BoxFit.contain,
                  ),
                ],
              ),
            ),
          ],
        ),        actions: [
          // Everything else lives in the empty-state debug card
          // (logo + wordmark stay here). Done exits delete mode.
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
                onToggleShapeBg: _toggleShapeBg,
                isMax: _isMax,
                onSupportSheet: _openSupportSheet,
                onShapeDemo: () =>
                    showShapeDemo(context, bgColor: _indicatorColor),
                onPro: _openPro,
                onPreviewSheets: () =>
                    MaxThankYouSheet.showPreviewPicker(context),
                onOnboarding: _openOnboardingPreview,
                onOnboardingAt: _openOnboardingAt,
                onToggleNotif: _toggleNotif,
                m3Thumbs: _m3Thumbs,
                onToggleM3Thumbs: _toggleM3Thumbs,
                indicatorColor: _indicatorColor,
                shapeScale: 1.0,
                markScale: _markScale,
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
              child: GalleryBottomSheet(
                key: _sheetKey,
                onPick: _onGalleryPick,
                m3Thumbs: _m3Thumbs,
              ),
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
