import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:sliver_app_bar_builder/sliver_app_bar_builder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/outfit_sticker.dart';
import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../services/analytics_service.dart';
import '../services/growth_service.dart';
import '../services/moment_paywall_service.dart';
import '../services/pro_access_service.dart';
import '../services/revenuecat_service.dart';
import '../services/recent_picks_service.dart';
import '../services/sticker_style_service.dart';
import '../services/subject_cutout_service.dart';
import '../services/widget_service.dart';
import '../widgets/embedded_picker_sheet.dart';
import '../widgets/genie_flight.dart';
import '../widgets/bounce_chevron.dart';
import '../widgets/sticker_grid.dart';
import '../widgets/wordmark_lockup.dart';
import 'photo_preview_screen.dart';
import 'expired_upsell_sheet.dart';
import 'max_thankyou_sheet.dart';
import 'sticker_detail_screen.dart';

/// Apple Notes dark-mode palette.
class NotesColors {
  static const bg = Color(0xFF1C1C1E); // true system dark surface
  static const bar = Color(0xFF2C2C2E); // elevated surface
  static const text = Color(0xFFFFFFFF);
  static const sub = Color(0xFF98989E);
  static const yellow = Color(0xFFFFD60A); // notes accent
}

/// Pick data minted before the preview opens: the route builder needs
/// everything synchronously when the flight starts.
typedef PreviewSavedCallback = void Function(
    String path, StickerStyle style);

class GalleryPickData {
  final String assetId;
  final String imagePath;
  final String heroTag;
  final int shapeIndex;
  final PreviewSavedCallback onSaved;

  const GalleryPickData({
    required this.assetId,
    required this.imagePath,
    required this.heroTag,
    required this.shapeIndex,
    required this.onSaved,
  });
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

  /// Footer swipe haptics: one light tick per 28px of upward travel.
  static const double _footerTickStep = 14.0;
  double _footerHapticAccum = 0;

  /// Live upward pull of the footer strip while swiping (chevron rides
  /// it), capped at half the screen height. Springs home on release
  /// unless the swipe launched.
  double _footerDragDy = 0.0;

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

  /// First-grid-view tip, once ever: long-press deletes. Styled exactly
  /// like the 'Sticker removed' toast. Debug builds replay it from the
  /// appbar touch icon.
  static const _longTapTipKey = 'longtap_tip_shown_v1';

  Future<void> _maybeLongTapTip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_longTapTipKey) ?? false) return;
      await prefs.setBool(_longTapTipKey, true);
    } catch (_) {}
    if (!mounted) return;
    // Let the grid settle a beat so the tip lands on stickers, not a
    // spinner.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    _showLongTapTip();
  }

  void _showLongTapTip() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
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
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              child: const Text(
                'Long-press a sticker to remove it.',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
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
      unawaited(_maybeLongTapTip());
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
    // Publishes the widget pool the first time it runs after an upgrade
    // (or if stickers changed outside a save). The 4h/2h rotation itself
    // is native — nothing to roll forward here.
    unawaited(WidgetService.updateAll());
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
  void _onCustomerInfoForWordmark(CustomerInfo _) {
    // Entitlement flips (subscribe / restore / expiry / resume) swap
    // the wordmark between Max and standard art.
    if (mounted) setState(() {});
  }

    /// Max lockup stands alone — the pants logo hides wherever it shows.
  /// Sticky state (not strict entitlement): offline/cold starts keep
  /// painting Max until a definitive update says otherwise.
  bool get _isMax => RevenueCatService.instance.isProSticky;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume refresh: a purchase, restore, expiry or cancellation that
    // happened elsewhere reconciles the moment we're foregrounded.
    // Widget upkeep runs too, but it is a no-op signature check — the
    // rotation clock is native.
    if (state == AppLifecycleState.resumed) {
      unawaited(() async {
        await RevenueCatService.instance.refreshCustomerInfo();
        await WidgetService.updateAll();
        if (mounted) setState(() {});
        // Foreground ask for non-subscribers (guarded inside).
        if (mounted) await _launchPaywallAsk('app_foreground');
      }());
    }
  }

  /// Stretch overscroll light: end-to-end base wash plus a tight
  /// curved center dome. Pinned to the screen's bottom edge (it
  /// doesn't ride the finger) — opacity saturates with the pull while
  /// the height stretches unbounded, chasing the finger.
  Widget _buildFooterGlow() {
    final pull = (-_footerDragDy).clamp(0.0, double.infinity);
    final t = (pull / 200).clamp(0.0, 1.0);
    return IgnorePointer(
      child: Opacity(
        opacity: 0.55 * t,
        child: SizedBox(
          // No height limit: the light stretches from the edge up
          // toward the finger.
          height: 32 + pull,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // End-to-end base wash: full-width vertical falloff.
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.35),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
              // Curved center pooling: tight dome for a dramatic arc.
              Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, 1),
                    radius: 0.8,
                    colors: [
                      Colors.white.withValues(alpha: 0.65),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Transparent floating header sliver (sliver_app_bar_builder):
  /// hides on scroll-down, regrows on reverse. Content stacks UNDER
  /// the bar (contentBelowBar), so stickers genuinely flow beneath the
  /// transparency — no reflow, no cutoff.
  Widget _buildHeaderSliver() {
    final topPad = MediaQuery.of(context).padding.top;
    final bar = 80.0 + topPad;
    return SliverAppBarBuilder(
      barHeight: bar,
      initialBarHeight: bar,
      initialContentHeight: bar,
      floating: true,
      backgroundColorBar: Colors.transparent,
      backgroundColorAll: Colors.transparent,
      contentBelowBar: false,
      leadingActions: const [],
      contentBuilder:
          (context, expandRatio, contentHeight, centerPadding, overlapsContent) {
        return SizedBox(
          height: contentHeight,
          child: Padding(
            padding: EdgeInsets.only(top: topPad, left: 16, right: 8),
            child: Row(
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
                  child: WordmarkLockup(
                    isMax: _isMax,
                    // Art and backing shape scale together, so the shadow
                    // stays exactly 1:1 with the wordmark at any markScale
                    // (scaling only the shape skewed the proportions).
                    imageHeight: 57 * _markScale,
                    shadowHeight: 57 * _markScale,
                    shapeIndex: _indicatorShape,
                    color: _indicatorColor,
                    shadowVisible: _shapeBgOn,
                  ),
                ),
                const Spacer(),
                // Done exits delete mode.
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
          ),
        );
      },
    );
  }

  void _toggleShapeBg() {
    AppHaptics.tap();
    setState(() {
      // Shape advances on EVERY toggle (hidden taps included), so the
      // silhouette is always moving — otherwise the visible-on taps
      // looked like a color-only change.
      _shapeBgOn = !_shapeBgOn;
      _indicatorShape = (_indicatorShape + 1) % kStyleShapes.length;
      _indicatorColorIndex++;
    });
    _persistShapeBg();
    // Wordmark color drives the homescreen widget backdrop too — every
    // toggle re-tints the cookie behind the stickers.
    unawaited(WidgetService.updateAll(bgColor: _indicatorColor));
  }

  /// Sheet thumbnail style (persisted):
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

  Future<void> _onGalleryPick(String imagePath) async {
    if (!await _passesCreateGate()) return;
    if (!mounted) return;
    // File into the sheet's recents grid (fire-and-forget).
    unawaited(RecentPicksService.remember(imagePath));
    // Id minted upfront so the preview and the future grid cell share
    // one Hero tag for the genie flight home. Shape rolls from the id.
    final stickerId = const Uuid().v4();
    // Warm the image cache so the flight isn't swallowed by
    // first-frame decode.
    try {
      await precacheImage(FileImage(File(imagePath)), context);
    } catch (_) {}
    if (!mounted) return;
    _openPreview(
      GalleryPickData(
        assetId: stickerId,
        imagePath: imagePath,
        heroTag: 'sticker-$stickerId',
        shapeIndex: fallbackShapeIndex(stickerId),
        onSaved: (path, style) => _insertSticker(stickerId, path, style),
      ),
    );
  }

  /// Pushes the preview on the genie route (non-opaque: the preview
  /// frosts the live grid behind it).
  void _openPreview(GalleryPickData data) {
    if (!mounted) return;
    Navigator.of(context).push(
      geniePageRoute(
        open: const Duration(milliseconds: 380),
        page: PhotoPreviewScreen(
          imagePath: data.imagePath,
          heroTag: data.heroTag,
          initialShapeIndex: data.shapeIndex,
          onSaved: data.onSaved,
          pickHeroTag: 'pick-${data.assetId}',
          autoCutout: true,
        ),
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
    // Growth loop: the widget pool is republished on every save, so the
    // new sticker takes the 4h slot immediately and becomes the caption's
    // subject; the suggestion sheet
    // (review/share/widget prompt) fires on the 1st + every 5th save,
    // 5s after touchdown.
    unawaited(WidgetService.updateAll(bgColor: _indicatorColor));
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
              // Overlay header below floats over this full-bleed grid:
              // hiding it never re-lays-out the stickers, so nothing
              // can cut. Scroll direction drives it (see _onGridScroll).
              child: StickerGrid(
                controller: _gridController,
                headerSliver: _buildHeaderSliver(),
                stickers: _stickers,
                onTap: _openDetail,
                shapeBg: _shapeBgOn,
                indicatorShape: _indicatorShape,
                onToggleShapeBg: _toggleShapeBg,
                isMax: _isMax,
                m3Thumbs: _m3Thumbs,
                onToggleM3Thumbs: _toggleM3Thumbs,
                onGetMax: () => MomentPaywallService.maybeShow(
                  context,
                  placement: 'empty_state',
                  locked: true,
                ),
                onFooterTap: () {
                  if (_jiggling) {
                    _exitJiggle();
                  } else {
                    _onFabGallery();
                  }
                },
                debugFooterFill: false,
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
                bottomInset: MediaQuery.of(context).padding.bottom + 88,
              ),
            ),
          ),
          // Pinned footer: the chevron only, centered on the absolute
          // bottom. The placeholder block lives in the grid's scroll
          // content just above it.
          // Footer strip: pinned to the absolute bottom, owns the chevron and
          // the whole swipe/tap gesture. Drag the chevron up or tap it
          // (or the strip) to open the gallery picker; dragging the
          // strip itself past threshold does the same.
          // Stretch overscroll light: end-to-end base wash plus the
          // original curved center pooling. Pinned to the bottom edge
          // (it doesn't ride the finger) — opacity and height follow
          // the drag fraction, so it swells and fades with the pull.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildFooterGlow(),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onFabGallery,
              onVerticalDragUpdate: (d) {
                // Only upward travel; the whole strip (chevron
                // included) rides the finger, capped at half the screen
                // height.
                setState(() {
                  final cap = MediaQuery.of(context).size.height * 0.5;
                  _footerDragDy =
                      (_footerDragDy + d.delta.dy).clamp(-cap, 0.0);
                });
                if (d.delta.dy < 0) _footerHapticAccum -= d.delta.dy;
                while (_footerHapticAccum >= _footerTickStep) {
                  _footerHapticAccum -= _footerTickStep;
                  AppHaptics.tap();
                }
                if (_footerHapticAccum < 0) _footerHapticAccum = 0;
              },
              onVerticalDragEnd: (d) {
                final flung = (d.primaryVelocity ?? 0) < -300;
                final pulled = _footerDragDy < -30;
                setState(() => _footerDragDy = 0.0);
                _footerHapticAccum = 0;
                if (flung || pulled) {
                  AppHaptics.launch();
                  _onFabGallery();
                }
              },
              child: Transform.translate(
                offset: Offset(0, _footerDragDy),
                child: Container(
                  // Transparent: the board reads continuous to the
                  // screen edge, and only the chevron marks the footer.
                  // Tall grab area for the unbounded pull.
                  color: Colors.transparent,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom,
                    top: 48,
                  ),
                  child: Center(
                    child: BounceChevron(
                      onLaunch: _onFabGallery,
                      dragOffset: _footerDragDy,
                    ),
                  ),
                ),
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

  /// Footer trigger: system gallery picker, then the standard pick flow.
  Future<void> _onFabGallery() async {
    AppHaptics.launch();
    final path = await pickGalleryImage(context);
    if (path != null && mounted) _onGalleryPick(path);
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
