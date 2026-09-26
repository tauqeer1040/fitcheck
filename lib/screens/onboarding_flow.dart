import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_confetti/flutter_confetti.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../motion/app_haptics.dart';
import '../models/outfit_sticker.dart';
import '../services/analytics_service.dart';
import '../services/growth_service.dart';
import '../services/moment_paywall_service.dart';
import '../services/notification_service.dart';
import '../services/revenuecat_service.dart';
import '../services/preset_stickers_service.dart';
import '../services/roast_service.dart';
import '../services/shape_unlock_service.dart';
import '../services/sticker_style_service.dart';
import '../services/sticker_title_service.dart';
import '../services/widget_service.dart';
import '../widgets/shaped_sticker.dart';
import '../widgets/sticker_frame.dart';
import 'gallery_screen.dart';
import 'photo_preview_screen.dart';

/// StickerPants first-run flow, ramadan onboarding layout (structure
/// only): top step bar, hero visual, title, body/cards, Back + Continue,
/// paywall finale. Steps:
/// how-to → confidence → mindful shopping → jokes → widgets (manual 2x3
/// add + 2x5 preview) → notifications → paywall → gallery.
class OnboardingFlow extends StatefulWidget {
  /// Debug relaunch from the gallery debug card: completing pops back
  /// instead of replacing the route, and analytics stay quiet.
  final bool debugPreview;

  /// Debug fast-forward: open the flow already sitting on this page — a
  /// name from the flow's own page list, e.g. `first_wish` or `aura` —
  /// instead of walking there. The real pages are used, so what you test
  /// is the shipping flow minus the walk.
  final String? debugStartAt;

  /// Persisted step. Shared with the splash's launch gate, which treats a
  /// saved non-zero step as "run in flight" and resumes it — otherwise a
  /// run quit halfway opens the gallery and is lost.
  static const stepKey = 'onboarding_step_v1';

  const OnboardingFlow({
    super.key,
    this.debugPreview = false,
    this.debugStartAt,
  });

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final PageController _pageController = PageController();
  final DateTime _startedAt = DateTime.now();
  int _index = 0;
  bool _finishing = false;

  /// Guards the Amen tap → advance beat.
  bool _advancing = false;

  /// Debug-only explosion tuner: hidden — the dial values were tuned on
  /// device and baked into [StickerFrameFieldState] (count 2x, size
  /// 1.2x) and the Get Started page (text 0.65x). Flip to true to bring
  /// the sliders back.
  ///
  /// Copy lives inside the measured frame: the burst reports its deepest
  /// intrusion per orientation ([StickerFrameField.onMetrics]) and every
  /// page pads off that, plus the tuner extras below. Defaults are the
  /// old hardcoded 75s so the first frame already respects the rails
  /// before the burst reports in.
  double _measuredSide = 75;
  double _measuredTop = 75;

  /// Tuner extras stacked on top of the measured intrusion — what the
  /// copy-box dials drag. [_ReadableAreaGuide] draws the same effective
  /// box, so what you drag is what the text lives in.
  static const _tunerEnabled = true;
  double _tunerCount = 2;
  double _tunerSize = 1.2;
  double _tunerText = 0.65;
  double _tunerCta = 15;
  double _copySide = 0;
  double _copyTop = 0;
  double _copyBottom = 0;
  bool _tunerOpen = false;

  double get _effSide => _measuredSide + _copySide;
  double get _effTop => _measuredTop + _copyTop;
  double get _effBottom => _measuredTop + _copyBottom;

  /// Set when the user backs out of the Aura reveal: the wish step should
  /// come up with the photo picker already open, because the only reason
  /// to go back is to choose a different photo.
  bool _reopenPicker = false;

  /// Aura → Back: the wish step, sheet up. The cutout already landed, so
  /// "back" means "another photo" rather than "tap the button again".
  void _backFromAura() {
    debugPrint('[nav] _backFromAura guard=${_navGuard()}');
    _reopenPicker = true;
    _goTo(_firstWishIndex);
  }

  void _onFrameMetrics(EdgeInsets insets) {
    if (!mounted) return;
    if ((insets.left - _measuredSide).abs() < 0.5 &&
        (insets.top - _measuredTop).abs() < 0.5) {
      return;
    }
    setState(() {
      _measuredSide = insets.left;
      _measuredTop = insets.top;
    });
  }

  /// Fullscreen sticker frame behind the whole flow. The Get Started tap
  /// detonates it; the cutouts fly out and lock into a border frame that
  /// stays behind the rest of onboarding.
  final GlobalKey<StickerFrameFieldState> _frameKey =
      GlobalKey<StickerFrameFieldState>();

  /// Amen: the prayer answered — into the flow. The explosion already
  /// fired on launch; this just turns the page.
  void _onAmen() {
    if (_advancing) return;
    _advancing = true;
    AppHaptics.milestone();
    _next();
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _advancing = false;
    });
  }

  static const _stepKey = OnboardingFlow.stepKey;
  static const _answersKey = 'onboarding_answers_v1';
  static const _completedKey = 'onboarding_completed_v1';

  /// Shape unlocked per question: same formula the chip draws, so the
  /// stored unlock always matches the visual.
  static int shapeIndexForQuestion(int q) => (q + 1) % kStyleShapes.length;

  /// One unlock answer: five preset cutouts join the wardrobe plus one
  /// sticker shape. Batch b claims assets [5b, 5b+5) of the shipped set.
  /// Idempotent — a batch is granted once, tracked so re-answering
  /// never double-grants.
  Future<void> _grantWardrobeBatch(int batch) async {
    final b = batch.clamp(0, 5);
    if (_grantedBatches.contains(b)) {
      // Outfits are durable; the shape unlock may still be missing
      // (granted before shapes existed) — top it up.
      unawaited(ShapeUnlockService.unlockShape(shapeIndexForQuestion(b)));
      return;
    }
    _grantedBatches.add(b);
    try {
      await PresetStickersService.grantBatch(b);
      await ShapeUnlockService.unlockShape(shapeIndexForQuestion(b));
    } catch (_) {
      // A failed grant must not wedge the unlock chip: drop it so a
      // re-answer can retry.
      _grantedBatches.remove(b);
    }
  }

  /// Claim tap on a bestow screen: five copies of the unlocked shape
  /// fly off to random border slots with the burst's own spring flight,
  /// then the flow moves on once the flight reads.
  Future<void> _onClaim(int q) async {
    AppHaptics.milestone();
    final frame = _frameKey.currentState;
    for (var i = 0; i < 5; i++) {
      // Unmeasured: the claim joins the border without moving the copy
      // box — text never shrinks for a landing sticker, it just overlaps
      // until dragged aside.
      frame?.flyShapeToBorder(
        shapeIndex: shapeIndexForQuestion(q),
        color: _bestowColors[q % _bestowColors.length],
        measure: false,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    _next();
  }

  /// Single-question answer entry: records the answer and persists
  /// progress. The outfit+shape grant happens on the bestow screen that
  /// follows ([_BestowPage] → [_grantWardrobeBatch]), never here.
  Future<void> _onQuestionAnswered(int q, String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    setState(() => _answers[q] = value);
    unawaited(_persistProgress());
    if (!mounted) return;
    // Name (Q0) reveals its funny title in place; every other answer
    // advances straight to its bestow screen.
    if (q != 0) _next();
  }

  /// "Joffery the Wise" — the stored name plus its funny honorific,
  /// or '' when Q0 is still unanswered.
  String _nameAndTitle() {
    final raw = _answers[0];
    if (raw == null || raw.trim().isEmpty) return '';
    return '${StickerTitleService.displayNameFor(raw)} ${StickerTitleService.titleFor(raw)}'
        .trim();
  }

  /// Just the display name ("Joffery") — sprinkled through every later
  /// page so the flow talks *to* the user. '' when Q0 is unanswered.
  String _displayName() {
    final raw = _answers[0];
    if (raw == null || raw.trim().isEmpty) return '';
    return StickerTitleService.displayNameFor(raw);
  }

  /// The living poem under the headline: one line per answered question,
  /// in question order. Grows a line with every answer.
  List<String> _poemLines() {
    final lines = <String>[];
    final keys = _answers.keys.toList()..sort();
    for (final q in keys) {
      final line = StickerTitleService.poemLineFor(q, _answers[q]!);
      if (line.isNotEmpty) lines.add(line);
    }
    return lines;
  }

  /// A photo was picked on the First Wish page: prep the file for the
  /// cutout pipeline, advance when ready.
  Future<void> _onWishPicked(AssetEntity asset) async {
    if (_wishSaving) return;
    _wishSaving = true;
    String? pickedPath;
    try {
      // Same preference order as the gallery: fresh bytes over possibly
      // stale cache entries.
      final bytes = await asset.originBytes;
      if (bytes != null && bytes.isNotEmpty) {
        final dir = await getTemporaryDirectory();
        final f = File(
          '${dir.path}/wish_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await f.writeAsBytes(bytes);
        pickedPath = f.path;
      } else {
        pickedPath = (await asset.originFile)?.path;
      }
    } catch (_) {
      pickedPath = (await asset.originFile)?.path;
    }
    if (!mounted) return;
    final photoPath = pickedPath;
    if (photoPath == null) {
      _wishSaving = false;
      return;
    }
    _wishImagePath = photoPath;
    // The id minted here is the one the finished cutout saves under, so
    // the sticker and the grid cell share it.
    _cutoutId = const Uuid().v4();
    _cutoutPath = null;
    _cutoutStyle = null;
    _wishSaving = false;
    // Hand the photo to the real preview screen: its own cutout animation,
    // its own reveal, its own save. It saves the moment the cutout lands and
    // pops — so this is one uninterrupted transition, not a
    // re-implementation of it. The screen wash deliberately starts AFTER
    // this returns: everything up to and including the photo step stays on
    // black, and the color begins at the cutout reveal.
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoPreviewScreen(
          imagePath: photoPath,
          heroTag: 'onboarding_first_wish',
          initialShapeIndex: fallbackShapeIndex(photoPath),
          autoCutout: true,
          autoAdvance: true,
          onSaved: (path, style) {
            debugPrint('[pick] onSaved path=$path');
            if (!mounted) return;
            setState(() {
              _cutoutPath = path;
              _cutoutStyle = style;
            });
          },
        ),
      ),
    );
    debugPrint('[pick] preview popped, cutoutPath=$_cutoutPath index=$_index');
    // Only ever step onto Aura with a sticker in hand. If the cutout
    // didn't land, stay on the photo step so it can be retried — a bare
    // Aura page (or a jump anywhere else) is the bug, not a fallback.
    if (!mounted) return;
    if (_cutoutPath == null) {
      debugPrint('[pick] no cutout, staying on photo step for a retry');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn\u2019t make that sticker — try another photo'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    // The preview already profiled this photo and handed the style back
    // through onSaved — reuse it instead of re-analyzing, so the wash is
    // already up the moment the preview pops and Aura's reveal can start
    // on the very next frame.
    final style = _cutoutStyle;
    if (style != null) {
      final tint = Color(style.dominantColor);
      setState(() {
        _screenTint = tint;
        _screenInk = Color(StickerStyleService.readableInkOn(tint.toARGB32()));
      });
    } else {
      await _paintScreenFromPhoto(photoPath);
    }
    debugPrint('[pick] painted screen, stepping to aura from $_index');
    if (!mounted) return;
    // Hand the cutout straight to its reveal: scroll to the Aura page
    // outright instead of turning one page, so the reveal always lands.
    _goTo(_auraIndex);
    debugPrint('[pick] after _goTo(aura), index=$_index');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _frameKey.currentState?.burst();
    });
  }

  /// Profiles [path] and fades the whole screen into its dominant color,
  /// then picks the ink that reads best on it. Painted under
  /// [StickerFrameField] — the border stickers are the frame, and they stay
  /// on top of the wash.
  Future<void> _paintScreenFromPhoto(String path) async {
    try {
      final style = await StickerStyleService.analyze(path);
      if (!mounted) return;
      final tint = Color(style.dominantColor);
      setState(() {
        _screenTint = tint;
        _screenInk = Color(StickerStyleService.readableInkOn(tint.toARGB32()));
      });
    } catch (_) {}
  }

  /// The sticker landed on the Aura page: splash it into the border in five
  /// different directions — the same lone-shape flight the reward screens
  /// fire, fanned so none share a line — and send the cutout itself along
  /// on its own reserved slot. Fires once, on the reveal.
  void _onAuraRevealed() {
    final path = _cutoutPath;
    if (path == null) return;
    AppHaptics.milestone();
    _frameKey.currentState?.explodeShapes(
      count: 5,
      shapeIndex: _cutoutStyle?.shapeIndex ?? fallbackShapeIndex(path),
      color: _cutoutStyle?.dominantColor ?? kFallbackStickerColor,
      cutoutPath: path,
      cutoutShapeIndex: _cutoutStyle?.shapeIndex ?? fallbackShapeIndex(path),
      cutoutColor: _cutoutStyle?.dominantColor ?? kFallbackStickerColor,
    );
  }

  /// Sauce: the widget is verified on the homescreen — toast the blessing
  /// and walk on by itself. The delayed step only fires if the user is
  /// still on the Sauce page (a manual Continue or Back in the meantime
  /// wins); the toast shows regardless, it confirms a real pin.
  void _onSauceWidgetAdded() {
    if (!mounted) return;
    AppHaptics.milestone();
    _frostedToast('Homescreen blessed with Sauce.');
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted || _index != _pages.indexOf('sauce')) return;
      _next();
    });
  }

  /// Frosted confirmation toast, styled exactly like the gallery's
  /// 'Sticker removed' toast: transparent shell, floating, blurred dark
  /// pill. Same builder serves the Sauce button's retry/unsupported
  /// notes so every widget toast reads as one voice.
  void _frostedToast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(_frostedSnack(message));
  }

  /// Aura: step to Sauce first, then file the cutout in the store. The
  /// disk write must never gate the page turn — if it stalls, the button
  /// would look dead while the sticker just sits there.
  Future<void> _onAuraContinue() async {
    _next();
    if (_cutoutPath != null && _cutoutId != null) {
      unawaited(_celebrateCutout());
    }
  }

  /// Files the cutout in the store and clears it off the Aura page. The
  /// border splash has already fired on the reveal.
  Future<void> _celebrateCutout() async {
    final path = _cutoutPath;
    if (path == null || _cutoutId == null) return;
    setState(() => _cutoutPath = null);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sticker = OutfitSticker(
        id: _cutoutId!,
        imagePath: path,
        createdAt: DateTime.now(),
        haloStripped: false,
        shapeIndex: _cutoutStyle?.shapeIndex,
        dominantColor: _cutoutStyle?.dominantColor,
      );
      final metaFile = File('${dir.path}/stickers.json');
      final list = metaFile.existsSync()
          ? (jsonDecode(await metaFile.readAsString()) as List)
                .cast<Map<String, dynamic>>()
                .map(OutfitSticker.fromJson)
                .toList()
          : <OutfitSticker>[];
      if (!list.any((s) => s.id == _cutoutId)) {
        list.insert(0, sticker);
        await metaFile.writeAsString(
          jsonEncode(list.map((s) => s.toJson()).toList()),
        );
      }
      unawaited(WidgetService.updateAll(resetRotation: true));
    } catch (_) {
      // The sticker file exists regardless; the gallery will show it on
      // a later save even if this write lost the race.
    }
  }

  /// Wish flow state, carried between steps: the picked photo's temp
  /// file, the id the finished cutout is filed under, and the cutout.
  String? _wishImagePath;
  String? _cutoutId;
  String? _cutoutPath;
  StickerStyle? _cutoutStyle;
  bool _wishSaving = false;

  /// Full-screen wash color, painted behind the sticker frame from the
  /// sticker-made moment onwards. Null before that — black is the app's
  /// ground.
  Color? _screenTint;

  /// Copy color for the pages that sit on [_screenTint], picked for
  /// contrast against it. White until a photo says otherwise.
  Color _screenInk = Colors.white;
  /// The photo's profile-color wash, painted under the sticker frame from
  /// the cutout reveal onwards. The cutout itself is laid out by the Aura
  /// page's own column, so heading / sticker / joke line up in one block.
  Widget _buildAuraWash() {
    final tint = _screenTint;
    if (tint == null) return const SizedBox.shrink();
    return ColoredBox(key: ValueKey(tint), color: tint);
  }

  /// Wardrobe batches already granted from answered questions (5
  /// stickers + 1 shape each, 6 batches).
  final Set<int> _grantedBatches = {};

  /// One answer per question, keyed by question index 0..5. Persisted
  /// so a kill resumes mid-flow instead of restarting.
  final Map<int, String> _answers = {};

  /// The very first launch: the frame detonates by itself — the aha
  /// moment, no tap required.
  @override
  void initState() {
    super.initState();
    // Decode the sticker art in the background; the auto-burst fires as
    // soon as it lands.
    StickerArt.warmUp();
    final start = widget.debugStartAt;
    final startIndex = start == null ? null : _pages.indexOf(start);
    if (startIndex != null && startIndex > 0) {
      _index = startIndex;
      _jumpToPageWhenReady(startIndex);
      if (start == 'aura') unawaited(_seedDebugCutout());
    }
    if (!widget.debugPreview) {
      AnalyticsService.instance.logOnboardingStarted();
      AnalyticsService.instance.logOnboardingStep(page: _pages[0], index: 0);
    }
    // Always resume. Answers and step come from the store, so a relaunch
    // — the debug preview included — continues the flow where it was
    // instead of restarting on Amen. A debug fast-forward keeps its own
    // page ([keepStep]).
    unawaited(_restoreProgress(keepStep: startIndex != null));
  }

  /// Debug fast-forward onto the Aura reveal: the cutout only ever lives
  /// in memory, so a cold start on that page would have nothing to show.
  /// Seed it from the newest outfit in the store — the same record the
  /// flow files when a wish completes — so the reveal has its real
  /// sticker to land.
  Future<void> _seedDebugCutout() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final metaFile = File('${dir.path}/stickers.json');
      if (!metaFile.existsSync()) return;
      final list = (jsonDecode(await metaFile.readAsString()) as List)
          .cast<Map<String, dynamic>>()
          .map(OutfitSticker.fromJson)
          .toList();
      if (list.isEmpty) return;
      final newest = list.first;
      final path = newest.imagePath;
      if (!File(path).existsSync() || !mounted) return;
      final style = StickerStyle(
        dominantColor: newest.dominantColor ?? kFallbackStickerColor,
        shapeIndex: newest.shapeIndex ?? fallbackShapeIndex(path),
      );
      final tint = Color(style.dominantColor);
      setState(() {
        _cutoutId = newest.id;
        _cutoutPath = path;
        _cutoutStyle = style;
        _wishImagePath = path;
        _screenTint = tint;
        _screenInk = Color(StickerStyleService.readableInkOn(tint.toARGB32()));
      });
    } catch (_) {}
  }

  /// Jumps the PageView once its controller is attached. The view does
  /// not exist on the very first frame, and a one-shot post-frame jump
  /// then silently does nothing — leaving [_index] and the view out of
  /// step, which is what made a restored step show page 0.
  void _jumpToPageWhenReady(int page, [int attempt = 0]) {
    if (!mounted) return;
    if (_pageController.hasClients) {
      _pageController.jumpToPage(page);
      return;
    }
    if (attempt > 20) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _jumpToPageWhenReady(page, attempt + 1),
    );
  }

  /// Reloads saved step + answers. Temp wish files may be gone after a
  /// kill — callers clamp back to the photo step when the path is dead.
  /// [keepStep] loads the answers but leaves the page alone (the debug
  /// fast-forward already chose one).
  Future<void> _restoreProgress({bool keepStep = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (var b = 0; b < 6; b++) {
        if (prefs.getBool('preset_batch_${b}_granted') ?? false) {
          _grantedBatches.add(b);
        }
      }
      final raw = prefs.getString(_answersKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          final q = int.tryParse(k);
          if (q != null && q >= 0 && q < 6 && v is String && v.isNotEmpty) {
            _answers[q] = v;
          }
        });
      }
      if (keepStep) return;
      final saved = prefs.getInt(_stepKey) ?? 0;
      var clamped = saved.clamp(0, _pages.length - 1);
      if (clamped >= _auraIndex) clamped = _firstWishIndex;
      if (!mounted) return;
      // The user outran the prefs read: leave their pages alone. Applying
      // the stale step now would yank them backwards (usually to Amen).
      if (_userNavigated) {
        debugPrint('[pick] restore skipped, user already on $_index');
        return;
      }
      setState(() => _index = clamped);
      _jumpToPageWhenReady(clamped);
    } catch (_) {}
  }

  Future<void> _persistProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_stepKey, _index);
      await prefs.setString(
        _answersKey,
        jsonEncode({for (final e in _answers.entries) '${e.key}': e.value}),
      );
    } catch (_) {}
  }

  /// The auto-burst fires once the frame's size is known and its art has
  /// decoded — the frame's own [didChangeDependencies] runs before this
  /// post-frame callback can see it mounted, so one first-frame hook
  /// covers both the launch and every later re-reveal.
  void _maybeAutoBurst() {
    if (_index != 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _index != 0) return;
      _frameKey.currentState?.burst();
    });
  }

  /// The six questions: who you are, how you dress, what you want.
  /// One-word answers — low effort, still felt. Shared by the six
  /// per-question step pages.
  static const _aboutQuestions = [
    ('What should I call you?', null),
    (
      'Where do you fall on the gender spectrum?',
      ['Woman', 'Man', 'Non-binary', 'Prefer not to say'],
    ),
    (
      'What\u2019s your style of clothing?',
      [
        'Casual',
        'Streetwear',
        'Goth',
        'Vintage',
        'Minimal',
        'Athleisure',
        'Formal',
        'Boho',
      ],
    ),
    (
      'How do you wanna improve your wardrobe?',
      [
        'Rewear more',
        'Buy less',
        'Organize it',
        'Try new styles',
        'Declutter',
        'Dress bolder',
      ],
    ),
    (
      'How do you want getting dressed to feel?',
      ['Effortless', 'Exciting', 'Calm', 'Confident', 'Playful'],
    ),
    ('Who do you dress for?', ['Myself', 'The world', 'Both']),
  ];

  /// One bestow color per question — the unlocked shape always shows
  /// in its question's color, so every grant feels like its own moment.
  static const _bestowColors = [
    0xFFFFD60A, // gold
    0xFFFF6B9D, // pink
    0xFF4DD0E1, // cyan
    0xFFAED581, // lime
    0xFFCE93D8, // purple
    0xFFFFAB40, // orange
  ];

  static const _pages = [
    'get_started',
    'about_q0',
    'bestow_q0',
    'about_q1',
    'bestow_q1',
    'about_q2',
    'bestow_q2',
    'about_q3',
    'bestow_q3',
    'about_q4',
    'bestow_q4',
    'about_q5',
    'bestow_q5',
    'first_wish',
    'aura',
    'rate',
    'sauce',
    'review',
    'notifications',
  ];

  /// The cutout only ever exists in memory (the picked photo is a temp
  /// file, the cutout is made by the preview screen on this run), so a
  /// cold start can never resume onto the Aura page — it resumes on the
  /// photo step and the preview does its work again.
  static const _firstWishIndex = 13;
  static const _auraIndex = 14;

  /// him / her / them, off the Q1 gender answer. From the rating screen
  /// on, the flow talks about the user in the third person with this —
  /// the same voice the later review ask will borrow.
  String _objectPronoun() {
    switch (_answers[1]) {
      case 'Woman':
        return 'her';
      case 'Man':
        return 'him';
      default:
        // Non-binary, Prefer not to say, or unanswered.
        return 'them';
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Collapses multiplied tap delivery (and real double-taps) into one
  /// page turn, so bestow screens can never be skipped over.
  DateTime _lastNav = DateTime.fromMillisecondsSinceEpoch(0);

  bool _navGuard() {
    final now = DateTime.now();
    if (now.difference(_lastNav).inMilliseconds < 400) return false;
    _lastNav = now;
    return true;
  }

  /// Set the moment the user turns a page themselves. A slow prefs read
  /// that resolves after that must not slam the flow back to the stale
  /// saved step — that is what kept dropping people onto Amen after the
  /// photo step had already washed the screen.
  bool _userNavigated = false;

  /// Moves the flow to [target] and drives the PageView there **by
  /// index**, not relative to wherever the view happens to sit.
  ///
  /// Addressing the page absolutely matters here: the view's own position
  /// can drift from [_index] (a restore jump that lands late, a subtree
  /// that got re-created), and a relative `nextPage` then turns exactly
  /// one page off — which is how the photo step used to come back on the
  /// Amen page instead of the Aura reveal.
  void _goTo(int target) {
    if (target < 0 || target > _pages.length - 1) return;
    AppHaptics.tap();
    _userNavigated = true;
    setState(() => _index = target);
    if (!widget.debugPreview) {
      AnalyticsService.instance.logOnboardingStep(
        page: _pages[target],
        index: target,
      );
    }
    unawaited(_persistProgress());
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  void _next() {
    if (!_navGuard()) {
      debugPrint('[pick] _next BLOCKED by navGuard');
      return;
    }
    if (_index < _pages.length - 1) {
      _goTo(_index + 1);
    } else {
      _finish();
    }
  }

  void _back() {
    debugPrint('[nav] _back index=$_index');
    if (!_navGuard()) return;
    if (_index > 0) {
      _goTo(_index - 1);
    } else if (widget.debugPreview && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Finale: soft paywall first, then into the product either way.
  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await MomentPaywallService.maybeShow(
        context,
        placement: 'onboarding',
        locked: false,
        force: true,
      );
    } catch (_) {}
    await _enterApp();
  }

  Future<void> _enterApp() async {
    // Photo permission fires here, back-to-back after notifications —
    // no custom pre-dialog. Denials are handled later at the gallery
    // sheet (rationale + Settings deep-link).
    try {
      await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_completedKey, true);
      await prefs.remove(_stepKey);
    } catch (_) {}
    if (!widget.debugPreview) {
      AnalyticsService.instance.logOnboardingCompleted(
        timeToCompleteMs: DateTime.now().difference(_startedAt).inMilliseconds,
      );
    }
    if (!mounted) return;
    // The wash lives as long as the flow does — the photo's color carries
    // through Aura, Sauce and Notifications instead of snapping back to
    // black between steps.
    setState(() => _screenTint = null);
    if (widget.debugPreview) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, _, _) => const GalleryScreen(),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _CtaOffset(
      value: _tunerEnabled ? _tunerCta : 0,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _back();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          // Sticker frame: empty until Get Started detonates it, then every
          // cutout (half of them on their M3 shape cards) flies to the
          // screen border and points at the middle.
          // The Aura stage goes UNDER the frame, never over it: the border
          // stickers are the frame, and they have to stay readable on top of
          // the photo and its profile-color wash.
          body: Stack(
            children: [
              Positioned.fill(child: _buildAuraWash()),
              StickerFrameField(
                key: _frameKey,
                // Draggable on every page: the grab layer hit-tests to
                // sticker bounds only, so a tap that misses a sticker still
                // reaches the Back / Continue buttons underneath.
                draggable: true,
                onMetrics: _onFrameMetrics,
                autoBurst: true,
                // The grab layer sits behind the page, so page taps always
                // reach their intended widgets regardless of sticker art.
                particlesOnTop: _index == _auraIndex,
                child: Stack(
                  children: [
                    SafeArea(
                      child: Column(
                        children: [
                          Expanded(
                            child: PageView(
                              controller: _pageController,
                              physics: const NeverScrollableScrollPhysics(),
                              onPageChanged: (i) {
                                setState(() => _index = i);
                                // Every re-reveal of the landing page replays the
                                // explosion; other pages leave the frame alone.
                                _maybeAutoBurst();
                              },
                              children: [
                                _GetStartedPage(
                                  onAmen: _onAmen,
                                  // The lockup owns the top of this page: the
                                  // measured frame inset belongs to the text
                                  // pages, not here.
                                  copyTop: 0,
                                ),
                                for (var q = 0; q < 6; q++) ...[
                                  _AboutYouStepPage(
                                    key: ValueKey('about_q$q'),
                                    questionIndex: q,
                                    question: _aboutQuestions[q].$1,
                                    options: _aboutQuestions[q].$2,
                                    initialValue: _answers[q],
                                    poemLines: _poemLines(),
                                    onAnswered: (v) =>
                                        _onQuestionAnswered(q, v),
                                    onNext: _next,
                                    onBack: _back,
                                    copySide: _effSide,
                                    copyTop: _effTop,
                                    ctaBottom: _effBottom,
                                  ),
                                  _BestowPage(
                                    key: ValueKey('bestow_q$q'),
                                    questionIndex: q,
                                    nameAndTitle: _nameAndTitle(),
                                    shapeIndex: shapeIndexForQuestion(q),
                                    shapeColor: Color(
                                      _bestowColors[q % _bestowColors.length],
                                    ),
                                    onGrant: () => _grantWardrobeBatch(q),
                                    onClaim: () => _onClaim(q),
                                    onBack: _back,
                                    active: _index == 2 + 2 * q,
                                    copySide: _effSide,
                                    copyTop: _effTop,
                                    ctaBottom: _effBottom,
                                  ),
                                ],
                                _FirstWishPage(
                                  onPicked: _onWishPicked,
                                  onBack: _back,
                                  displayName: _displayName(),
                                  autoOpen: _reopenPicker,
                                  onAutoOpenHandled: () {
                                    if (_reopenPicker) {
                                      setState(() => _reopenPicker = false);
                                    }
                                  },
                                  copySide: _effSide,
                                  copyTop: _effTop,
                                  ctaBottom: _effBottom,
                                ),
                                _AuraPage(
                                  cutoutPath: _cutoutPath,
                                  style: _cutoutStyle,
                                  processing: false,
                                  nameAndTitle: _nameAndTitle(),
                                  wishImagePath: _wishImagePath,
                                  cutoutId: _cutoutId,
                                  cardColor: Color(
                                    _screenTint == null
                                        ? kFallbackStickerColor
                                        : StickerStyleService.cardToneOn(
                                            _screenTint!.toARGB32(),
                                          ),
                                  ),
                                  ink: _screenInk,
                                  active: _index == _auraIndex,
                                  onRevealed: _onAuraRevealed,
                                  onNext: _onAuraContinue,
                                  onBack: _backFromAura,
                                  copySide: _effSide,
                                  copyTop: _effTop,
                                  ctaBottom: _effBottom,
                                ),
                                _RatePage(
                                  onNext: _next,
                                  // Back skips the spent Aura reveal (its
                                  // sticker is already filed, so it would
                                  // come up an empty dead end) and goes
                                  // straight to picking another photo.
                                  onBack: _backFromAura,
                                  nameAndTitle: _nameAndTitle(),
                                  pronoun: _objectPronoun(),
                                  copySide: _effSide,
                                  copyTop: _effTop,
                                  ctaBottom: _effBottom,
                                  ink: _screenInk,
                                ),
                                _SaucePage(
                                  onNext: _next,
                                  onBack: _back,
                                  onWidgetAdded: _onSauceWidgetAdded,
                                  nameAndTitle: _nameAndTitle(),
                                  copySide: _effSide,
                                  copyTop: _effTop,
                                  ctaBottom: _effBottom,
                                  ink: _screenInk,
                                ),
                                _ReviewPage(
                                  onNext: _next,
                                  onBack: _back,
                                  nameAndTitle: _nameAndTitle(),
                                  copySide: _effSide,
                                  copyTop: _effTop,
                                  ctaBottom: _effBottom,
                                  ink: _screenInk,
                                ),
                                _NotificationsPage(
                                  onNext: _next,
                                  onBack: _back,
                                  debugPreview: widget.debugPreview,
                                  displayName: _displayName(),
                                  copySide: _effSide,
                                  copyTop: _effTop,
                                  ctaBottom: _effBottom,
                                  ink: _screenInk,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Design guide: debug builds only, points-nothing. Shows the
                    // box onboarding copy has to live inside — the safe area,
                    // inset by the page padding, and stopping above the CTA row.
                    if (kDebugMode)
                      _ReadableAreaGuide(
                        side: _effSide,
                        top: _effTop,
                        bottomGutter: _effBottom,
                      ),
                    // Explosion tuner: debug builds only. Three dials — how many
                    // copies of the set fly, how big every sticker draws, how
                    // big the Get Started prayer reads. Count and size re-deal
                    // the frame live; text is a plain re-render.
                    if (kDebugMode && _tunerEnabled)
                      _ExplosionTuner(
                        count: _tunerCount,
                        size: _tunerSize,
                        text: _tunerText,
                        cta: _tunerCta,
                        side: _copySide,
                        top: _copyTop,
                        bottom: _copyBottom,
                        open: _tunerOpen,
                        onChanged: (count, size, text, cta, side, top, bottom) {
                          setState(() {
                            _tunerCount = count;
                            _tunerSize = size;
                            _tunerText = text;
                            _tunerCta = cta;
                            _copySide = side;
                            _copyTop = top;
                            _copyBottom = bottom;
                          });
                          _frameKey.currentState?.retune(
                            count: count,
                            size: size,
                          );
                        },
                        onToggle: () =>
                            setState(() => _tunerOpen = !_tunerOpen),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fills an M3 shape and strokes its outline in one even width.
///
/// [m3ShapePath] hands back a 100-unit path centred on the ORIGIN, so the
/// canvas is translated to the box centre and then scaled — the shape
/// lands dead-centre, the rotation pivots on its true middle, and the
/// stroke sits evenly all the way round. The stroke straddles the path,
/// so the box is inset by half the stroke to keep its outer edge on the
/// boundary.
class _RewardShapePainter extends CustomPainter {
  final Shapes shape;
  final Color fill;
  final Color stroke;
  final double strokeWidth;

  const _RewardShapePainter({
    required this.shape,
    required this.fill,
    required this.stroke,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide - strokeWidth;
    if (side <= 0) return;
    final k = side / 100;
    canvas.save();
    // To the box centre first, then scale: the path's own centre (0,0)
    // meets the box centre, so in-place rotation stays in place.
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(k);
    final path = m3ShapePath(shape);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        // The 100-unit path is scaled up to fill the box, so the stroke
        // width has to be divided back out to stay 7px on screen.
        ..strokeWidth = strokeWidth / k
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RewardShapePainter old) =>
      old.shape != shape ||
      old.fill != fill ||
      old.stroke != stroke ||
      old.strokeWidth != strokeWidth;
}

/// The Aura page: the sticker the player just made, revealed. The screen
/// behind it is already washed in the photo's colour, so this page is the
/// sticker on its own card with the blessing over it, framed by the border
/// stickers — which the flow paints in front here.
class _AuraPage extends StatefulWidget {
  final String? cutoutPath;
  final StickerStyle? style;

  /// The cutout is still being made (cold start, or the preview's pass is
  /// still running). Shows the picked photo in its place.
  final bool processing;

  /// "Tauqeer the Pattern Crasher" — the stored name plus its honorific.
  final String nameAndTitle;

  /// The picked photo, used as the placeholder until the cutout lands.
  final String? wishImagePath;

  /// Which sticker this is — the roast under it is salted off this id, so
  /// it reads the same here as it does in the grid cell.
  final String? cutoutId;

  /// Card tone behind the sticker, stepped off the wash so the sticker
  /// always has something to sit on.
  final Color cardColor;

  /// Copy color profiled from the photo, for contrast on that wash.
  final Color ink;

  /// Whether this is the page on screen. The PageView builds its
  /// neighbours offstage, and the reveal + the border splash must only run
  /// for the visible page — otherwise both finish before you arrive.
  final bool active;

  /// Fired once, as the sticker lands — the flow splashes it into the
  /// border from here.
  final VoidCallback onRevealed;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final double copySide;
  final double copyTop;
  final double ctaBottom;

  const _AuraPage({
    required this.cutoutPath,
    required this.style,
    required this.processing,
    required this.nameAndTitle,
    required this.wishImagePath,
    required this.cutoutId,
    required this.cardColor,
    required this.ink,
    required this.active,
    required this.onRevealed,
    required this.onNext,
    required this.onBack,
    required this.copySide,
    required this.copyTop,
    required this.ctaBottom,
  });

  @override
  State<_AuraPage> createState() => _AuraPageState();
}

class _AuraPageState extends State<_AuraPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    // Only the on-screen page reveals. An offstage pre-build that ran the
    // animation would land you on an already-static sticker with the
    // border splash long over.
    if (widget.active) _reveal.forward();
    // The splash goes off as the sticker lands, not when the page builds.
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.completed) _onLanded();
    });
  }

  @override
  void didUpdateWidget(_AuraPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Stepped onto this page: play the reveal from the top. Leaving it
    // disarms so coming back replays instead of sitting static.
    if (widget.active && !oldWidget.active) {
      _fired = false;
      _reveal.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  /// The sticker has landed: this is the moment the border goes off. Once
  /// only, so a rebuild mid-page never replays the splash.
  void _onLanded() {
    if (_fired) return;
    _fired = true;
    widget.onRevealed();
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.cutoutPath;
    final screen = MediaQuery.sizeOf(context);
    // Square, and never taller than the space the frame leaves us.
    final side = math.min(
      screen.width - widget.copySide * 2,
      screen.height * 0.40,
    );
    final shapeIndex =
        widget.style?.shapeIndex ?? fallbackShapeIndex(path ?? '');
    // The card tone, worn twice: it is the sticker's own M3 shape (there
    // is no square container any more) and the copy's color.
    final stickerTone = widget.cardColor;
    // No placeholder photo: the sticker appears only once it is made.
    final joke = path == null || widget.cutoutId == null
        ? ''
        : RoastService.roastForId(
            widget.cutoutId!,
            isMax: RevenueCatService.instance.isPro,
          );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.copySide),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(height: widget.copyTop),
                  if (widget.nameAndTitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${widget.nameAndTitle},',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: stickerTone.withValues(alpha: 0.75),
                          fontSize: 16,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Text(
                    'I now bless thee with AURA.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: stickerTone,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 22),
                  AnimatedBuilder(
                    animation: _reveal,
                    builder: (context, child) {
                      final t = Curves.easeOutBack.transform(
                        _reveal.value.clamp(0.0, 1.0),
                      );
                      return Opacity(
                        opacity: _reveal.value.clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: 0.6 + 0.4 * t,
                          // Overshoot settles back to 1, so the sticker
                          // lands flat on its card.
                          alignment: Alignment.center,
                          child: child,
                        ),
                      );
                    },
                    // No square card: the sticker's own M3 shape is the
                    // card, painted the tone the container used to hold,
                    // so the silhouette and the copy share one color.
                    child: path == null
                        ? SizedBox(width: side, height: side)
                        : ShapedSticker(
                            imagePath: path,
                            shapeIndex: shapeIndex,
                            dominantColor: stickerTone.toARGB32(),
                            width: side,
                            height: side,
                            shapeScale: 1.0,
                            rotateSilhouette: true,
                          ),
                  ),
                  if (widget.processing) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Still sharpening it…',
                      style: TextStyle(
                        color: stickerTone.withValues(alpha: 0.7),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (joke.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      joke,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: stickerTone.withValues(alpha: 0.78),
                        fontSize: 15,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
          _CtaRow(
            onNext: path == null ? null : widget.onNext,
            onBack: widget.onBack,
            nextLabel: 'continue',
          ),
          SizedBox(height: widget.ctaBottom),
        ],
      ),
    );
  }
}

/// The self-rating trap, one page after the Aura reveal: rate yourself
/// out of five stars. Anything under five gets the Dum Dum correction —
/// the only passing grade is 5/5, which is exactly the muscle memory the
/// post-homescreen Google review ask wants to borrow. The grade is saved
/// (`self_rating_v1`) so that ask can echo it back later.
class _RatePage extends StatefulWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;

  /// "Tauqeer the Hemperor" — the stored name plus its honorific.
  final String nameAndTitle;

  /// him / her / them, off the Q1 gender answer.
  final String pronoun;

  /// Copy color profiled from the photo — this page sits on the photo's
  /// wash, not on black.
  final Color ink;
  final double copySide;
  final double copyTop;
  final double ctaBottom;
  const _RatePage({
    required this.onNext,
    required this.onBack,
    this.nameAndTitle = '',
    this.pronoun = 'them',
    this.ink = Colors.white,
    this.copySide = 75,
    this.copyTop = 75,
    this.ctaBottom = 75,
  });

  @override
  State<_RatePage> createState() => _RatePageState();
}

class _RatePageState extends State<_RatePage>
    with SingleTickerProviderStateMixin {
  int _rating = 0;

  /// The "tap me" shimmer: loops while any star outline is on screen,
  /// breathing the unpicked outlines between dim and bright.
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  Future<void> _pick(int value) async {
    AppHaptics.step();
    setState(() => _rating = value);
    if (value == 5) AppHaptics.milestone();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('self_rating_v1', value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final five = _rating == 5;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.copySide),
      child: Column(
        children: [
          SizedBox(height: widget.copyTop),
          if (widget.nameAndTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${widget.nameAndTitle},',
                style: TextStyle(
                  color: widget.ink.withValues(alpha: 0.75),
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Text(
            'Rate yourself',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'There\u2019s only one right answer here, and you already know it.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: widget.ink.withValues(alpha: 0.7),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 28),
          // The frame crowds this page hard, so the copy box can go
          // narrow — the stars size themselves to whatever width is left
          // instead of overflowing it.
          AnimatedBuilder(
            animation: _shimmer,
            builder: (context, _) {
              return LayoutBuilder(
                builder: (context, constraints) {
                  final cell = math.min(constraints.maxWidth / 5, 58.0);
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 1; i <= 5; i++)
                        SizedBox(
                          width: cell,
                          height: cell,
                          child: IconButton(
                            onPressed: () => _pick(i),
                            iconSize: cell - 10,
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              i <= _rating
                                  ? Icons.star_rounded
                                  : Icons.star_outline_rounded,
                              color: i <= _rating
                                  ? const Color(0xFFFFD60A)
                                  // Unpicked outlines breathe between dim
                                  // and bright — the shimmer that says
                                  // "tap me". Filled stars stay solid.
                                  : widget.ink.withValues(
                                      alpha:
                                          0.30 + 0.35 * _shimmer.value,
                                    ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 80),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                _rating == 0
                    ? 'Tap the stars. Don\u2019t be shy \u2014 you\u2019re the main character of StickerPants.'
                    : five
                    ? 'Correct. Look at ${widget.pronoun} \u2014 a perfect 5/5, like it was ever in doubt.'
                    : 'No Dum Dum. Rate yourself 5/5 \u2014 that\u2019s a non-negotiable. You\u2019re the main character of StickerPants \u2014 look at ${widget.pronoun}, every inch a 5/5.',
                key: ValueKey(
                  _rating == 0 ? 'none' : five ? 'five' : 'scold',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: five
                      ? const Color(0xFFFFD60A)
                      : widget.ink.withValues(alpha: 0.85),
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
          ),
          const Spacer(flex: 1),
          _CtaRow(onNext: five ? widget.onNext : null, onBack: widget.onBack),
          SizedBox(height: widget.ctaBottom),
        ],
      ),
    );
  }
}

/// Debug-only outline of the area onboarding copy can occupy: the safe
/// area, inset by the live copy-box dials (side/top) and stopping above
/// the CTA row (56pt button + the bottom gutter). Same insets the pages
/// pad themselves with, so the border is the textbox.
/// Debug builds only, points-nothing.
class _ReadableAreaGuide extends StatelessWidget {
  final double side;
  final double top;
  final double bottomGutter;
  const _ReadableAreaGuide({
    required this.side,
    required this.top,
    required this.bottomGutter,
  });

  static const _ctaHeight = 56.0;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          padding.left + side,
          padding.top + top,
          padding.right + side,
          padding.bottom + _ctaHeight + bottomGutter,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x14FFD60A),
            border: Border.all(color: const Color(0xFFFFD60A), width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

/// Step 1: the placeholder lockup — the pants logo over the StickerPants
/// wordmark, then the pitch line beneath it. Flat on purpose: no glow, no
/// drop shadow, no idle motion. Tapping anything on the page (logo,
/// wordmark or the line) detonates the cutout field behind it.
class _GetStartedPage extends StatelessWidget {
  final VoidCallback onAmen;

  /// Top clearance measured off the frame's top band (parent passes the
  /// effective copy-box top).
  final double copyTop;
  const _GetStartedPage({required this.onAmen, this.copyTop = 24});

  @override
  Widget build(BuildContext context) {
    // Side rails: the deepest sticker reaches ~84px in from the bezel
    // (54px box at 1.2x, half its width plus margin) — 96px of padding
    // keeps every line clear of the frame on both edges.
    const sideGutter = 96.0;
    // The measured top band can be deeper than the art itself, so this
    // page scrolls rather than clips when the lockup + prayer + Amen
    // cannot fit the viewport under it.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            // The logo's 29px tuck below is pure paint — it hangs outside
            // its layout box, so the lockup would sit 29px low. Matching
            // bottom padding rebalances the centered column by half that,
            // putting the visible lockup on the true middle.
            padding: const EdgeInsets.only(bottom: 29),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Clear of the status bar; this page centers, so it needs
                // no more.
                SizedBox(height: copyTop),
                // Lockup. Both art files carry their own transparent padding, so
                // the logo is nudged down into the wordmark's space — 29px of
                // tuck, which leaves a hair of air between the two.
                Transform.translate(
                  offset: const Offset(0, 29),
                  child: Image.asset(
                    'assets/logo3.png',
                    width: 150,
                    fit: BoxFit.contain,
                  ),
                ),
                Image.asset(
                  'assets/stickerpants.webp',
                  width: 232,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 26),
                // The prayer: flat grey, no glow — the frame is the hero here.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: sideGutter),
                  child: Text(
                    'I\u2019d like to digitize my outfits oh sticker Gods!\n'
                    'Bless me with aura.\n'
                    'Bless my homescreen with sauce.\n'
                    'And call me out on my fashion sins.\n'
                    'I beg!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.62),
                      fontSize: 31 * 0.65,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                // Amen sits right under the prayer — same 26px gap as the
                // wordmark-to-text gap above.
                const SizedBox(height: 26),
                // Amen: white pill, black text — the prayer's answer.
                FilledButton(
                  onPressed: onAmen,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    side: const BorderSide(color: Colors.white),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 44,
                      vertical: 16,
                    ),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text(
                    'Amen',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Ramadan CTA row: arrow-only Back + Continue, pinned to the same
/// bottom offset on every onboarding screen. A null [onBack] collapses
/// the arrow entirely (no dead button) and lets Continue span full
/// width — same 56pt height either way.
class _CtaOffset extends InheritedWidget {
  final double value;
  const _CtaOffset({required this.value, required super.child});

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CtaOffset>()?.value ?? 0;

  @override
  bool updateShouldNotify(_CtaOffset oldWidget) => oldWidget.value != value;
}

class _CtaRow extends StatelessWidget {
  final VoidCallback? onNext;
  final VoidCallback? onBack;
  final String nextLabel;

  static const height = 56.0;
  const _CtaRow({this.onNext, this.onBack, this.nextLabel = 'Continue'});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: _CtaOffset.of(context)),
      child: Row(
        children: [
          if (onBack != null) ...[
            SizedBox(
              width: height,
              height: height,
              child: FilledButton(
                onPressed: onBack,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: EdgeInsets.zero,
                ),
                child: const Icon(Icons.arrow_back_rounded, size: 22),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: SizedBox(
              height: height,
              child: FilledButton(
                onPressed: onNext,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  side: const BorderSide(color: Colors.white),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        nextLabel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared page shell: hero visual, title, body, spacer, CTA row.
/// The Google review ask, one page after Sauce: the user already rated
/// themselves 5/5 on the rate screen, so echoing that back is just
/// asking them to say it louder. "Not now" walks on; the notifications
/// page after this one only shows when permission isn't already granted.
class _ReviewPage extends StatefulWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;

  /// "Tauqeer the Hemperor" — the stored name plus its funny honorific.
  final String nameAndTitle;

  /// Copy color profiled from the photo (M3 on-color rule) — this page
  /// sits on the photo's wash, not on black.
  final Color ink;
  final double copySide;
  final double copyTop;
  final double ctaBottom;
  const _ReviewPage({
    required this.onNext,
    required this.onBack,
    this.nameAndTitle = '',
    this.ink = Colors.white,
    this.copySide = 75,
    this.copyTop = 75,
    this.ctaBottom = 75,
  });

  @override
  State<_ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<_ReviewPage> {
  bool _busy = false;

  /// Opens the Play in-app review dialog (no-op on side-loaded builds),
  /// then walks on either way — the ask itself is the moment.
  Future<void> _rate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await GrowthService.requestReview();
    } catch (_) {}
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.copySide),
      child: Column(
        children: [
          SizedBox(height: widget.copyTop),
          if (widget.nameAndTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${widget.nameAndTitle},',
                style: TextStyle(
                  color: widget.ink.withValues(alpha: 0.75),
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const Text(
            'Enjoying StickerPants?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Take a moment to rate us.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: widget.ink.withValues(alpha: 0.7),
              fontSize: 15,
            ),
          ),
          const Spacer(flex: 3),
          _CtaRow(
            onNext: _busy ? null : _rate,
            onBack: _busy ? null : widget.onBack,
            nextLabel: 'Rate us',
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : widget.onNext,
            child: Text(
              'Not now',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
            ),
          ),
          // The link below the CTA would otherwise push Continue higher
          // than every other screen: shrink this gutter by exactly that
          // block (8px gap + ~48px link) so the button lands level.
          SizedBox(height: (widget.ctaBottom - 56).clamp(8.0, 400.0)),
        ],
      ),
    );
  }
}

class _NotificationsPage extends StatefulWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;
  final bool debugPreview;
  final String displayName;

  /// Copy color profiled from the photo (M3 on-color rule) — the last page
  /// still sits on the photo's wash.
  final Color ink;
  final double copySide;
  final double copyTop;
  final double ctaBottom;
  const _NotificationsPage({
    required this.onNext,
    required this.onBack,
    this.debugPreview = false,
    this.displayName = '',
    this.ink = Colors.white,
    this.copySide = 75,
    this.copyTop = 75,
    this.ctaBottom = 75,
  });

  @override
  State<_NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<_NotificationsPage> {
  bool _busy = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSkip());
  }

  /// Already enabled (system settings, a previous install)? Don't ask
  /// again — make sure the daily chain is scheduled and move on.
  Future<void> _maybeSkip() async {
    if (_checked || !mounted) return;
    _checked = true;
    bool enabled = false;
    try {
      enabled = await NotificationService.areEnabled();
    } catch (_) {}
    if (!mounted || !enabled) return;
    if (!widget.debugPreview) {
      AnalyticsService.instance.logNotificationPermission(granted: true);
      NotificationService.scheduleDaily();
    }
    widget.onNext();
  }

  Future<void> _grant() async {
    if (_busy) return;
    setState(() => _busy = true);
    bool granted = false;
    try {
      granted = await NotificationService.requestPermissions();
    } catch (_) {}
    if (!widget.debugPreview) {
      AnalyticsService.instance.logNotificationPermission(granted: granted);
      if (granted) {
        NotificationService.scheduleDaily();
      }
    }
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.copySide),
      child: Column(
        children: [
          SizedBox(height: widget.copyTop),
          const Text('🔔', style: TextStyle(fontSize: 72)),
          const SizedBox(height: 28),
          Text(
            'Enable notifications',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: widget.ink,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            widget.displayName.isNotEmpty
                ? '${widget.displayName}, one ping at 8am, one at 10:30pm —\n\u201CAdd your outfit today.\u201D\nThat\u2019s it. No marketing. Ever.'
                : 'One ping at 8am, one at 10:30pm —\n\u201CAdd your outfit today.\u201D\nThat\u2019s it. No marketing. Ever.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.5,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const Spacer(flex: 3),
          _CtaRow(
            onNext: _busy ? null : _grant,
            onBack: _busy ? null : widget.onBack,
            nextLabel: 'Sounds good',
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : widget.onNext,
            child: Text(
              'Not now',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
            ),
          ),
          // The link below the CTA would otherwise push Continue higher
          // than every other screen: shrink this gutter by exactly that
          // block (8px gap + ~48px link) so the button lands level.
          SizedBox(height: (widget.ctaBottom - 56).clamp(8.0, 400.0)),
        ],
      ),
    );
  }
}

/// One About-You step: a single question per page. Each answer unlocks
/// 5 outfits + 1 sticker shape (flip chip), granted on the bestow screen
/// that follows — where the funny honorific title is revealed.
class _AboutYouStepPage extends StatefulWidget {
  final int questionIndex;
  final String question;
  final List<String>? options;
  final String? initialValue;

  /// The living poem: one haiku-ish line per answered question, newest
  /// last. Grows under the headline as the user answers.
  final List<String> poemLines;
  final ValueChanged<String> onAnswered;
  final VoidCallback onNext;
  final VoidCallback onBack;

  /// Live copy-box insets from the tuner (see [_ReadableAreaGuide]).
  final double copySide;
  final double copyTop;
  final double ctaBottom;

  const _AboutYouStepPage({
    super.key,
    required this.questionIndex,
    required this.question,
    required this.options,
    required this.initialValue,
    this.poemLines = const [],
    required this.onAnswered,
    required this.onNext,
    required this.onBack,
    this.copySide = 75,
    this.copyTop = 75,
    this.ctaBottom = 75,
  }) : assert(questionIndex >= 0 && questionIndex < 6);

  @override
  State<_AboutYouStepPage> createState() => _AboutYouStepPageState();
}

class _AboutYouStepPageState extends State<_AboutYouStepPage>
    with SingleTickerProviderStateMixin {
  late String? _value = widget.initialValue;
  final TextEditingController _nameController = TextEditingController();
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  bool get _answered => _value != null && _value!.trim().isNotEmpty;

  Shapes get _shape =>
      kStyleShapes[_OnboardingFlowState.shapeIndexForQuestion(
            widget.questionIndex,
          ) %
          kStyleShapes.length];

  Color get _color => Color(
    _OnboardingFlowState._bestowColors[widget.questionIndex %
        _OnboardingFlowState._bestowColors.length],
  );

  @override
  void initState() {
    super.initState();
    if (widget.options == null && widget.initialValue != null) {
      _nameController.text = widget.initialValue!;
    }
    if (_answered) _flip.value = 1;
  }

  @override
  void dispose() {
    _flip.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _setValue(String? v) {
    final was = _answered;
    setState(() => _value = v);
    final isNow = _answered;
    if (!was && isNow) {
      AppHaptics.milestone();
      _flip.forward();
    } else if (was && !isNow) {
      _flip.reverse();
    }
  }

  /// The title is revealed on the bestow screen that follows, never here.
  void _answerName(String v) {
    _setValue(v);
    if (v.trim().length >= 2) widget.onAnswered(v);
  }

  void _answerOption(String v) {
    _setValue(v);
    widget.onAnswered(v);
  }

  @override
  Widget build(BuildContext context) {
    final answered = _answered;
    final isName = widget.options == null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.copySide),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // The whole page scrolls (header included) so the keyboard can
          // never overflow it — only the CTA row stays pinned.
          Expanded(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(height: widget.copyTop),
                  Text(
                    'Tell me about\nyourself',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (widget.poemLines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Column(
                        children: [
                          for (final line in widget.poemLines)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                line,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.75),
                                  fontSize: 14,
                                  fontStyle: FontStyle.italic,
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  // The unlock chip: flips on answer. Locked is the
                  // question color at half strength with a lock badge;
                  // unlocked is full color.
                  AnimatedBuilder(
                    animation: _flip,
                    builder: (context, child) {
                      final t = Curves.easeOutBack.transform(_flip.value);
                      final showBack = _flip.value >= 0.5;
                      return Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.001)
                          ..rotateY(math.pi * t),
                        child: showBack
                            ? Transform.flip(
                                flipX: true,
                                child: _UnlockChipFace(
                                  _shape,
                                  unlocked: true,
                                  color: _color,
                                ),
                              )
                            : _UnlockChipFace(
                                _shape,
                                unlocked: false,
                                color: _color,
                              ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Every answer unlocks 5 outfits + 1 shape.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (isName)
                    _NameRow(
                      controller: _nameController,
                      question: widget.question,
                      onAnswered: _answerName,
                    )
                  else
                    _QuestionRow(
                      key: ValueKey('q${widget.questionIndex}:$_value'),
                      question: widget.question,
                      options: widget.options,
                      initialValue: _value,
                      onAnswered: _answerOption,
                    ),
                  // Breathing room above the pinned CTA. The frame's
                  // measured top inset is generous, so on a short page the
                  // last control lands right on the button row and reads
                  // sliced; this is what lets it scroll clear instead.
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
          _CtaRow(
            onNext: answered ? widget.onNext : null,
            onBack: widget.onBack,
          ),
          SizedBox(height: widget.ctaBottom),
        ],
      ),
    );
  }
}

/// Bestow screen: the grant moment after each answered question.
/// "Joffery the Wise, I bestow upon you +5 outfits, and one shape."
/// The unlocked shape shows in its question color, slowly rotating; the
/// grant itself fires once, on reveal (idempotent, so rebuilds and
/// re-answers never double-grant). Claim flies the shape off to a random
/// border slot with the burst's spring flight, then advances.
class _BestowPage extends StatefulWidget {
  final int questionIndex;
  final String nameAndTitle;
  final int shapeIndex;
  final Color shapeColor;
  final VoidCallback onGrant;
  final VoidCallback onClaim;
  final VoidCallback onBack;

  /// Whether this page is the visible one. The 3s auto-claim only runs
  /// while active — PageView builds neighbours offstage, and those must
  /// never fire.
  final bool active;

  /// Live copy-box insets from the tuner (see [_ReadableAreaGuide]).
  final double copySide;
  final double copyTop;
  final double ctaBottom;

  const _BestowPage({
    super.key,
    required this.questionIndex,
    required this.nameAndTitle,
    required this.shapeIndex,
    required this.shapeColor,
    required this.onGrant,
    required this.onClaim,
    required this.onBack,
    this.active = false,
    this.copySide = 75,
    this.copyTop = 75,
    this.ctaBottom = 75,
  });

  @override
  State<_BestowPage> createState() => _BestowPageState();
}

class _BestowPageState extends State<_BestowPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );

  bool _revealed = false;
  Timer? _autoClaim;
  bool _claimed = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _onBecameActive();
  }

  @override
  void didUpdateWidget(_BestowPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _onBecameActive();
    } else if (!widget.active && old.active) {
      // Left the page (Back, or claimed and moved on): disarm so a
      // revisit starts a fresh 3s beat instead of firing stale.
      _autoClaim?.cancel();
      _autoClaim = null;
      _claimed = false;
      _spin.stop();
    }
  }

  void _onBecameActive() {
    _spin.repeat();
    _armAutoClaim();
    // Same confetti pop as the thank-you sheet, once the page is
    // actually on screen — never for an offstage pre-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      try {
        Confetti.launch(
          context,
          options: const ConfettiOptions(particleCount: 60, spread: 80, y: 0.4),
        );
      } catch (_) {}
    });
  }

  void _armAutoClaim() {
    _autoClaim?.cancel();
    _autoClaim = Timer(const Duration(seconds: 3), _claim);
  }

  void _claim() {
    if (_claimed) return;
    _claimed = true;
    _autoClaim?.cancel();
    widget.onClaim();
  }

  @override
  void dispose() {
    _autoClaim?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_revealed) {
      _revealed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        AppHaptics.milestone();
        widget.onGrant();
      });
    }
    final shape = kStyleShapes[widget.shapeIndex % kStyleShapes.length];
    final who = widget.nameAndTitle.isNotEmpty ? widget.nameAndTitle : 'Friend';
    // A different verb per question, so each grant reads as its own
    // moment instead of the same line six times.
    final verb = switch (widget.questionIndex % 3) {
      1 => 'I reward you with',
      2 => 'I bless you with',
      _ => 'I bestow upon you',
    };
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.copySide),
      child: Column(
        children: [
          SizedBox(height: widget.copyTop),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$who,',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        verb,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 16,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // The reward copy lives inside the spinning shape —
                      // the text itself stays put so it stays readable.
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          // One path, filled and stroked. The old treatment
                          // drew the shape twice — a white one a step larger
                          // behind the colour — which insets the inner shape
                          // in x and y, so a pointy or concave silhouette got
                          // a rim that ran thick in the notches and pinched
                          // at the points. A real stroke is one even width
                          // the whole way round, and it spins about the
                          // path's own centre.
                          SizedBox.square(
                            dimension: 244,
                            child: RotationTransition(
                              turns: _spin,
                              child: CustomPaint(
                                painter: _RewardShapePainter(
                                  shape: shape,
                                  fill: widget.shapeColor,
                                  stroke: Colors.white,
                                  strokeWidth: 7,
                                ),
                              ),
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Text(
                                '+5 outfits',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '+1 shape',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _CtaRow(onNext: _claim, onBack: widget.onBack, nextLabel: 'Claim'),
          SizedBox(height: widget.ctaBottom),
        ],
      ),
    );
  }
}

/// Name input row: label plus text field. The unlock chip lives at the
/// page level ([_AboutYouStepPageState]), above the copy — this row is
/// input only.
class _NameRow extends StatelessWidget {
  final TextEditingController controller;
  final String question;
  final ValueChanged<String> onAnswered;

  const _NameRow({
    required this.controller,
    required this.question,
    required this.onAnswered,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.transparent),
      ),
      child: Column(
        children: [
          Text(
            question,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            textCapitalization: TextCapitalization.words,
            textAlign: TextAlign.center,
            textInputAction: TextInputAction.done,
            autofocus: true,
            onChanged: (v) {
              if (v.trim().length >= 2) onAnswered(v);
            },
            onSubmitted: (v) {
              AppHaptics.tap();
              onAnswered(v);
            },
            style: const TextStyle(color: Colors.white, fontSize: 18),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Your name',
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 15,
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.12),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.white, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared unlock chip face (shape + "+5 outfits"), shown big above the
/// input. Locked is the question color at half strength with a lock
/// badge, like the expired sheet's teaser — never the grey silhouette.
class _UnlockChipFace extends StatelessWidget {
  final Shapes shape;
  final bool unlocked;
  final Color color;
  const _UnlockChipFace(
    this.shape, {
    required this.unlocked,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              M3Container(
                shape,
                color: unlocked ? color : color.withValues(alpha: 0.55),
                child: const SizedBox(width: 72, height: 72),
              ),
              if (!unlocked)
                const Positioned(right: 2, bottom: 2, child: _LockBadge()),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          unlocked ? '+5 outfits' : 'Locked',
          style: TextStyle(
            color: unlocked ? Colors.white : Colors.white38,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Dark circular lock badge pinned to a shape's corner — the expired
/// sheet's teaser treatment.
class _LockBadge extends StatelessWidget {
  const _LockBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.lock_rounded, color: Colors.white, size: 16),
    );
  }
}

/// One question of the About You page: centered label plus input. The
/// unlock chip lives at the page level ([_AboutYouStepPageState]), above
/// the copy — this row is input only.
class _QuestionRow extends StatelessWidget {
  final String question;

  /// Null for the free-text name row (unused — names use [_NameRow]).
  final List<String>? options;
  final String? initialValue;
  final ValueChanged<String> onAnswered;

  const _QuestionRow({
    super.key,
    required this.question,
    required this.options,
    this.initialValue,
    required this.onAnswered,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.transparent),
      ),
      child: Column(
        children: [
          Text(
            question,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 6),
          options == null
              ? TextField(
                  onSubmitted: onAnswered,
                  onChanged: onAnswered,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration('Your name'),
                )
              : DropdownButtonFormField<String>(
                  initialValue: options!.contains(initialValue)
                      ? initialValue
                      : null,
                  isExpanded: true,
                  alignment: AlignmentDirectional.center,
                  items: options!
                      .map(
                        (o) => DropdownMenuItem(
                          value: o,
                          alignment: AlignmentDirectional.center,
                          child: Text(
                            o,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      AppHaptics.tap();
                      onAnswered(v);
                    }
                  },
                  dropdownColor: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                  iconEnabledColor: Colors.white70,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: _inputDecoration('Pick one', emphasized: true),
                ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(
    String hint, {
    bool emphasized = false,
  }) => InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: TextStyle(
      color: Colors.white.withValues(alpha: 0.35),
      fontSize: 14,
    ),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.12),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    // The dropdown is the page's one real control, so it carries a
    // full-white edge at rest — the free-text field stays quiet.
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: emphasized ? Colors.white : Colors.white.withValues(alpha: 0.35),
        width: emphasized ? 1.5 : 1,
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Colors.white, width: 1.5),
    ),
  );
}

/// First Wish — same copy-box padding as the question screens. The pill
/// asks for photo access; on grant a photo sheet slides up from the
/// bottom ("Pick your first outfit") and the pick flows into the same
/// cutout pipeline the grid uses ([_OnboardingFlowState._onWishPicked]).
class _FirstWishPage extends StatefulWidget {
  final ValueChanged<AssetEntity> onPicked;
  final VoidCallback onBack;
  final String displayName;
  final double copySide;
  final double copyTop;
  final double ctaBottom;

  /// Open the picker sheet as soon as this page is up — set when the user
  /// backed out of the Aura reveal, so they land straight in the grid
  /// instead of tapping the button again.
  final bool autoOpen;
  final VoidCallback? onAutoOpenHandled;
  const _FirstWishPage({
    required this.onPicked,
    required this.onBack,
    this.displayName = '',
    this.copySide = 75,
    this.copyTop = 75,
    this.ctaBottom = 75,
    this.autoOpen = false,
    this.onAutoOpenHandled,
  });

  @override
  State<_FirstWishPage> createState() => _FirstWishPageState();
}

class _FirstWishPageState extends State<_FirstWishPage> {
  bool _busy = false;
  bool _askedOnce = false;

  /// Already granted (a previous run, or the user granted it earlier in
  /// Settings): there is nothing to ask for, so the button stops saying
  /// "Allow photo access" and becomes the plain action it is.
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    _checkPermission();
    if (widget.autoOpen) _autoOpen();
  }

  @override
  void didUpdateWidget(_FirstWishPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoOpen && !oldWidget.autoOpen) _autoOpen();
  }

  /// Open the sheet on the frame after the page turn lands, and tell the
  /// flow it was served so a later rebuild does not re-open it.
  void _autoOpen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.autoOpen) return;
      widget.onAutoOpenHandled?.call();
      unawaited(_allowAccess());
    });
  }

  Future<void> _checkPermission() async {
    try {
      final state = await PhotoManager.getPermissionState(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        _granted = state.hasAccess;
        _askedOnce = _askedOnce || _granted;
      });
    } catch (_) {}
  }

  Future<void> _allowAccess() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Already granted: straight to the picker, no OS prompt.
      if (_granted) {
        _askedOnce = true;
        AppHaptics.step();
        await _openSheet();
        return;
      }
      final permission = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
      if (!mounted) return;
      if (!permission.hasAccess) {
        // Second denial: the OS popup is gone for good — explain and
        // offer Settings instead of asking into the void.
        if (_askedOnce) {
          final go = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF2C2C2E),
              title: const Text('Photo access needed'),
              content: const Text(
                'StickerPants needs access to your photos to digitize '
                'your first fit. Enable it in Settings to continue.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Not now'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          );
          if (go == true) await PhotoManager.openSetting();
        }
        _askedOnce = true;
        return;
      }
      _askedOnce = true;
      _granted = true;
      await _openSheet();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The photo grid, newest first. Shared by the fresh-grant path and the
  /// already-granted path so both open the same sheet.
  Future<void> _openSheet() async {
    AppHaptics.step();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) => _FirstWishPhotoSheet(
          scrollController: scrollController,
          onPick: (asset) {
            Navigator.of(sheetContext).pop();
            widget.onPicked(asset);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = _busy ? 'Opening\u2026' : 'Allow photo access';
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.copySide),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Same skeleton as the question pages: the whole copy block
          // scrolls under the measured top clearance, only the CTA row
          // stays pinned.
          Expanded(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(height: widget.copyTop),
                  Text(
                    widget.displayName.isNotEmpty
                        ? '${widget.displayName}, for your First Wish\u2026'
                        : 'For your First Wish\u2026',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Pick the fit you want digitized first.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // The action wears the same card the answer rows use:
                  // full copy-box width, 18px radius, white 12% fill and
                  // 35% edge, 56pt tall.
                  Opacity(
                    opacity: _busy ? 0.5 : 1,
                    child: Material(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        onTap: _busy ? null : _allowAccess,
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          height: 56,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.photo_library_outlined,
                                size: 20,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          _CtaRow(onNext: null, onBack: widget.onBack),
          SizedBox(height: widget.ctaBottom),
        ],
      ),
    );
  }
}

/// The First Wish photo sheet: slides up from the bottom on grant,
/// newest photos in a grid under its title. A tap picks exactly one.
class _FirstWishPhotoSheet extends StatefulWidget {
  final ScrollController scrollController;
  final ValueChanged<AssetEntity> onPick;
  const _FirstWishPhotoSheet({
    required this.scrollController,
    required this.onPick,
  });

  @override
  State<_FirstWishPhotoSheet> createState() => _FirstWishPhotoSheetState();
}

class _FirstWishPhotoSheetState extends State<_FirstWishPhotoSheet> {
  bool _ready = false;
  List<AssetEntity> _recent = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Newest-first, from the synthetic "All photos" album so every
      // gallery folder is covered — same query as the homescreen sheet.
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: const [OrderOption(type: OrderOptionType.createDate)],
        ),
      );
      if (albums.isNotEmpty) {
        final all = albums.firstWhere(
          (a) => a.isAll,
          orElse: () => albums.first,
        );
        final recent = await all.getAssetListRange(start: 0, end: 120);
        if (!mounted) return;
        setState(() {
          _recent = recent;
          _ready = true;
        });
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Column(
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
          const Text(
            'Pick your first outfit',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: !_ready
                ? const Center(child: CircularProgressIndicator())
                : _recent.isEmpty
                ? const Center(
                    child: Text(
                      'No photos found',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                : GridView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: _recent.length,
                    itemBuilder: (context, i) {
                      final asset = _recent[i];
                      return GestureDetector(
                        onTap: () {
                          AppHaptics.tap();
                          widget.onPick(asset);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: AssetEntityImage(
                            asset,
                            isOriginal: false,
                            thumbnailSize: const ThumbnailSize(256, 256),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                Container(color: Colors.grey.shade800),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}


/// Step 4: "Third Wish" — the homescreen blessing, widget add.
class _SaucePage extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;

  /// Fired after the pin request goes out: the flow toasts the blessing
  /// and walks on by itself.
  final VoidCallback onWidgetAdded;

  /// "Tauqeer the Overdressed" — the stored name plus its funny honorific.
  final String nameAndTitle;

  /// Copy color profiled from the photo (M3 on-color rule) — this page
  /// sits on the photo's wash, not on black.
  final Color ink;
  final double copySide;
  final double copyTop;
  final double ctaBottom;
  const _SaucePage({
    required this.onNext,
    required this.onBack,
    required this.onWidgetAdded,
    this.nameAndTitle = '',
    this.ink = Colors.white,
    this.copySide = 75,
    this.copyTop = 75,
    this.ctaBottom = 75,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: copySide),
      child: Column(
        children: [
          SizedBox(height: copyTop),
          if (nameAndTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '$nameAndTitle,',
                style: TextStyle(
                  color: ink.withValues(alpha: 0.75),
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          RichText(
            textAlign: TextAlign.center,
            text: const TextSpan(
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
              children: [
                TextSpan(
                  text:
                      'For your last wish,\nI now bless thee '
                      'Homescreen\nwith ',
                ),
                TextSpan(
                  text: 'Sauce',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.center,
            child: Text(
              'Your newly blessed sticker moves straight onto your homescreen — greeting you at every unlock with a witty praise that\u2019ll make you smile.',
              textAlign: TextAlign.center,
              style: TextStyle(color: ink.withValues(alpha: 0.7), fontSize: 15),
            ),
          ),
          const Spacer(flex: 1),
          _WidgetAddButton(onAdded: onWidgetAdded),
          const Spacer(flex: 1),
          _CtaRow(onNext: onNext, onBack: onBack),
          SizedBox(height: ctaBottom),
        ],
      ),
    );
  }
}

/// Frosted toast shell shared by the Sauce widget confirmations — the
/// gallery's 'Sticker removed' recipe: transparent SnackBar, floating
/// blurred dark pill, white 14px copy.
SnackBar _frostedSnack(String message) {
  return SnackBar(
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            message,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ),
    ),
  );
}

/// The widget-add button on the Sauce page: pins the 2x3 latest-sticker
/// widget, same call the dedicated widgets page used.
class _WidgetAddButton extends StatefulWidget {
  final VoidCallback? onAdded;

  const _WidgetAddButton({this.onAdded});

  @override
  State<_WidgetAddButton> createState() => _WidgetAddButtonState();
}

class _WidgetAddButtonState extends State<_WidgetAddButton> {
  bool _busy = false;

  /// Pin requested, watching the homescreen for the new instance.
  bool _waiting = false;

  Future<Set<int>> _installedIds() async {
    try {
      final list = await HomeWidget.getInstalledWidgets();
      return {
        for (final w in list)
          if (w.androidWidgetId != null) w.androidWidgetId!,
      };
    } catch (_) {
      return const {};
    }
  }

  void _note(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(_frostedSnack(message));
  }

  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Some launchers can't pin at all — say so instead of opening a
      // dialog to nowhere.
      final supported = await HomeWidget.isRequestPinWidgetSupported();
      if (!mounted) return;
      if (supported != true) {
        setState(() => _busy = false);
        _note(
          'This launcher can\u2019t pin widgets — long-press the homescreen '
          'and pick StickerPants from the widget list.',
        );
        return;
      }
      final before = await _installedIds();
      await GrowthService.pinWidgets(
        androidName: 'LatestStickerWidgetProvider',
      );
      if (!mounted) return;
      // The pin call returns the moment the OS dialog shows, not when the
      // user answers it — so the confirm only fires once a new instance
      // actually appears on the homescreen.
      setState(() => _waiting = true);
      final pinned = await _waitForPin(before);
      if (!mounted) return;
      if (pinned) {
        widget.onAdded?.call();
      } else {
        setState(() {
          _busy = false;
          _waiting = false;
        });
        _note('No widget yet — tap below to try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _waiting = false;
        });
      }
    }
  }

  /// Polls the pinned instances until one appears that wasn't there
  /// before the request. Covers launchers that never pause us (no resume
  /// to listen for) as well as the normal dialog round-trip.
  Future<bool> _waitForPin(Set<int> before) async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return false;
      final after = await _installedIds();
      if (after.difference(before).isNotEmpty) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 64,
      child: FilledButton(
        onPressed: _busy ? null : _add,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          side: const BorderSide(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.widgets_rounded, size: 20),
            const SizedBox(width: 10),
            // The label is the only thing that can grow here — a long
            // translation used to push the row past the button and
            // overflow it by ~50px.
            Flexible(
              child: Text(
                _waiting
                    ? 'Check your homescreen…'
                    : _busy
                    ? 'Opening…'
                    : 'Add homescreen widgets',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Debug-only dials for the explosion and the copy box, pinned to the
/// top of the onboarding scaffold so they never fight the page layout.
/// Collapsed is a chip next to the step bar; expanded is a compact panel
/// of six sliders: copies of the set (1–6), sticker size (0.5–2.5x),
/// prayer text (0.5–2x), and extra padding stacked on top of the measured
/// frame intrusion (side/top/CTA) that all pages and [_ReadableAreaGuide]
/// draw from. Count and size re-deal the frame live through
/// [StickerFrameFieldState.retune]; the rest is a plain re-render.
class _ExplosionTuner extends StatelessWidget {
  final double count;
  final double size;
  final double text;
  final double cta;
  final double side;
  final double top;
  final double bottom;
  final bool open;
  final void Function(
    double count,
    double size,
    double text,
    double cta,
    double side,
    double top,
    double bottom,
  )
  onChanged;
  final VoidCallback onToggle;

  const _ExplosionTuner({
    required this.count,
    required this.size,
    required this.text,
    required this.cta,
    required this.side,
    required this.top,
    required this.bottom,
    required this.open,
    required this.onChanged,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        // The panel: under the chip, inert and invisible while collapsed.
        Positioned(
          top: topInset + 56,
          right: 8,
          left: 8,
          child: IgnorePointer(
            ignoring: !open,
            child: AnimatedOpacity(
              opacity: open ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: open
                    ? Container(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.82),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _TunerSlider(
                              label: 'Count',
                              value: count,
                              min: 1,
                              max: 6,
                              format: (v) => '${v.toStringAsFixed(1)}x set',
                              onChanged: (v) => onChanged(
                                v,
                                size,
                                text,
                                cta,
                                side,
                                top,
                                bottom,
                              ),
                            ),
                            _TunerSlider(
                              label: 'Sticker size',
                              value: size,
                              min: 0.5,
                              max: 2.5,
                              format: (v) => '${v.toStringAsFixed(2)}x',
                              onChanged: (v) => onChanged(
                                count,
                                v,
                                text,
                                cta,
                                side,
                                top,
                                bottom,
                              ),
                            ),
                            _TunerSlider(
                              label: 'Text size',
                              value: text,
                              min: 0.5,
                              max: 2,
                              format: (v) => '${v.toStringAsFixed(2)}x',
                              onChanged: (v) => onChanged(
                                count,
                                size,
                                v,
                                cta,
                                side,
                                top,
                                bottom,
                              ),
                            ),
                            _TunerSlider(
                              label: 'Buttons +',
                              value: cta,
                              min: 0,
                              max: 64,
                              format: (v) => '${v.toStringAsFixed(0)}px',
                              onChanged: (v) => onChanged(
                                count,
                                size,
                                text,
                                v,
                                side,
                                top,
                                bottom,
                              ),
                            ),
                            _TunerSlider(
                              label: 'Side +',
                              value: side,
                              min: 0,
                              max: 64,
                              format: (v) => '${v.toStringAsFixed(0)}px',
                              onChanged: (v) => onChanged(
                                count,
                                size,
                                text,
                                cta,
                                v,
                                top,
                                bottom,
                              ),
                            ),
                            _TunerSlider(
                              label: 'Top +',
                              value: top,
                              min: 0,
                              max: 96,
                              format: (v) => '${v.toStringAsFixed(0)}px',
                              onChanged: (v) => onChanged(
                                count,
                                size,
                                text,
                                cta,
                                side,
                                v,
                                bottom,
                              ),
                            ),
                            _TunerSlider(
                              label: 'CTA +',
                              value: bottom,
                              min: 0,
                              max: 64,
                              format: (v) => '${v.toStringAsFixed(0)}px',
                              onChanged: (v) => onChanged(
                                count,
                                size,
                                text,
                                cta,
                                side,
                                top,
                                v,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ),
          ),
        ),
        // The toggle chip: always tappable, sits over the step bar.
        Positioned(
          top: topInset + 12,
          right: 8,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  open ? 'Close tuner' : 'Explosion tuner',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One dial of [_ExplosionTuner]: label, live value, and a dense slider
/// sized for sitting over a live screen.
class _TunerSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  const _TunerSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            format(value),
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
