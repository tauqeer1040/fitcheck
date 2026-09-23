import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';
import '../services/analytics_service.dart';
import '../services/growth_service.dart';
import '../services/moment_paywall_service.dart';
import '../services/notification_service.dart';
import '../services/sticker_style_service.dart';
import '../widgets/sticker_frame.dart';
import 'gallery_screen.dart';

/// StickerPants first-run flow, ramadan onboarding layout (structure
/// only): top step bar, hero visual, title, body/cards, Back + Continue,
/// paywall finale. Steps:
/// how-to → confidence → mindful shopping → jokes → widgets (manual 2x3
/// add + 2x5 preview) → notifications → paywall → gallery.
class OnboardingFlow extends StatefulWidget {
  /// Debug relaunch from the gallery debug card: completing pops back
  /// instead of replacing the route, and analytics stay quiet.
  final bool debugPreview;
  const OnboardingFlow({super.key, this.debugPreview = false});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final PageController _pageController = PageController();
  final DateTime _startedAt = DateTime.now();
  int _index = 0;
  bool _finishing = false;

  /// Fullscreen sticker frame behind the whole flow. The Get Started tap
  /// detonates it; the cutouts fly out and lock into a border frame that
  /// stays behind the rest of onboarding.
  final GlobalKey<StickerFrameFieldState> _frameKey =
      GlobalKey<StickerFrameFieldState>();

  /// Guards the Get Started tap → burst → advance beat.
  bool _advancing = false;

  /// The very first tap: the app detonates its own cutouts across the
  /// screen. This is the aha moment — show, don't tell.
  Future<void> _onGetStarted() async {
    if (_advancing) return;
    _advancing = true;
    AppHaptics.milestone();
    _frameKey.currentState?.burst();
    // Let the burst play before the first page slides in.
    await Future<void>.delayed(const Duration(milliseconds: 1150));
    if (!mounted) return;
    _next();
  }

  static const _pages = [
    'get_started',
    'how_to',
    'confidence',
    'mindful',
    'jokes',
    'widgets',
    'notifications',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.debugPreview) return;
    AnalyticsService.instance.logOnboardingStarted();
    AnalyticsService.instance.logOnboardingStep(page: _pages[0], index: 0);
    // Decode the sticker art in the background so the first tap pops
    // instantly.
    StickerArt.warmUp();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    AppHaptics.tap();
    if (_index < _pages.length - 1) {
      setState(() => _index += 1);
      if (!widget.debugPreview) {
        AnalyticsService.instance.logOnboardingStep(
          page: _pages[_index],
          index: _index,
        );
      }
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      _finish();
    }
  }

  void _back() {
    AppHaptics.tap();
    if (_index > 0) {
      setState(() => _index -= 1);
      _pageController.previousPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
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
      await prefs.setBool('onboarding_completed_v1', true);
    } catch (_) {}
    if (!widget.debugPreview) {
      AnalyticsService.instance.logOnboardingCompleted(
        timeToCompleteMs:
            DateTime.now().difference(_startedAt).inMilliseconds,
      );
    }
    if (!mounted) return;
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
    return PopScope(
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
        body: StickerFrameField(
          key: _frameKey,
          // Draggable on the Get Started page only: the grab layer sits
          // above the page, so on the later steps it would swallow taps
          // meant for Back / Continue wherever a sticker covers them.
          draggable: _index == 0,
          child: Stack(
            children: [
              SafeArea(
                child: Column(
              children: [
                _TopBar(
                  index: _index,
                  total: _pages.length,
                ),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _index = i),
                    children: [
                      _GetStartedPage(onTap: _onGetStarted),
                      _HowToPage(onNext: _next, onBack: _back),
                      _MessagePage(
                        hero: '💪',
                        title: 'Wear it like\n you mean it',
                        body:
                            'Logging your fits makes getting dressed a ritual, '
                            'not a rush. People who see themselves styled show '
                            'up more confident — all day, every day.',
                        onNext: _next,
                        onBack: _back,
                      ),
                      _MessagePage(
                        hero: '🌱',
                        title: 'Shop what\nyou wear',
                        body:
                            'Your wardrobe becomes a visual archive. Rewear your '
                            'favorites on purpose, spot what never leaves the '
                            'hanger — and stop buying it. Mindful shopping, '
                            'powered by your own camera roll.',
                        onNext: _next,
                        onBack: _back,
                      ),
                      _JokesPage(onNext: _next, onBack: _back),
                      _WidgetsPage(onNext: _next, onBack: _back),
                      _NotificationsPage(
                        onNext: _next,
                        onBack: _back,
                        debugPreview: widget.debugPreview,
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
              if (kDebugMode) const _ReadableAreaGuide(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Debug-only outline of the area onboarding copy can occupy: the safe
/// area, inset by the page's horizontal padding, ending above the CTA row
/// (56pt button + the 48pt gutter beneath the pages).
class _ReadableAreaGuide extends StatelessWidget {
  const _ReadableAreaGuide();

  static const _pagePadding = 32.0;
  static const _ctaBlock = 56.0 + 48.0;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          padding.left + _pagePadding,
          padding.top,
          padding.right + _pagePadding,
          padding.bottom + _ctaBlock,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0x55FFD60A)),
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
  final VoidCallback onTap;
  const _GetStartedPage({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Lockup: both art files carry their own transparent padding,
            // so the logo is nudged down into the wordmark's space — 29px
            // of tuck, which leaves a hair of air between the two.
            // Translate, not a gap: the column still measures the boxes.
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
            // The prayer. Tapping it (or the lockup above) fires the
            // explosion — the whole page is the button.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'I\u2019d like to digitize my outfits oh sticker Gods!\n'
                'Bless me with aura.\n'
                'Bless my homescreen with sauce.\n'
                'And call me out on my fashion sins.\n'
                'I beg!',
                textAlign: TextAlign.left,
                // Pure white core with a white halo — the glow is light
                // bleeding off the type, never a grey wash — so the
                // line reads as the button it is.
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 31,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  shadows: [
                    Shadow(color: Colors.white, blurRadius: 10),
                    Shadow(
                      color: Colors.white.withValues(alpha: 0.6),
                      blurRadius: 26,
                    ),
                    Shadow(
                      color: Colors.white.withValues(alpha: 0.35),
                      blurRadius: 60,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top bar: "X of N" plus progress dots — black with white borders.
class _TopBar extends StatelessWidget {
  final int index;
  final int total;
  const _TopBar({required this.index, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          Text(
            '${index + 1} / $total',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 12,
              child: CustomPaint(
                painter: _SquigglePainter(
                  progress: (index + 1) / total,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// M3-expressive squiggly progress line: sine-wave track with the
/// completed portion filled. Replaces the dot indicators.
class _SquigglePainter extends CustomPainter {
  final double progress;
  const _SquigglePainter({required this.progress});

  static const _amplitude = 3.5;
  static const _wavelength = 26.0;

  Path _wave(Size size, double upToX) {
    final path = Path();
    final midY = size.height / 2;
    path.moveTo(0, midY);
    for (double x = 0; x <= upToX; x += 2) {
      final y =
          midY + _amplitude * math.sin((x / _wavelength) * 2 * math.pi);
      path.lineTo(x, y);
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(_wave(size, size.width), track);
    final fill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      canvas.drawPath(_wave(size, size.width * p), fill);
    }
  }

  @override
  bool shouldRepaint(_SquigglePainter old) => old.progress != progress;
}

/// Ramadan CTA row: Back (1 flex) + Continue (2 flex).
class _CtaRow extends StatelessWidget {
  final VoidCallback? onNext;
  final VoidCallback? onBack;
  final String nextLabel;
  const _CtaRow({this.onNext, this.onBack, this.nextLabel = 'Continue'});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 56,
            child: FilledButton(
              onPressed: onBack,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'Back',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 56,
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
                children: [
                  Text(
                    nextLabel,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
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
    );
  }
}

/// Shared page shell: hero visual, title, body, spacer, CTA row.
class _PageShell extends StatelessWidget {
  final Widget hero;
  final String title;
  final String body;
  final VoidCallback? onNext;
  final VoidCallback? onBack;
  final List<Widget> extras;
  const _PageShell({
    required this.hero,
    required this.title,
    required this.body,
    this.onNext,
    this.onBack,
    this.extras = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),
          hero,
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 15,
              height: 1.5,
            ),
          ),
          ...extras,
          const Spacer(flex: 2),
          _CtaRow(onNext: onNext, onBack: onBack),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

/// Step 1: how the first outfit sticker gets made.
class _HowToPage extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;
  const _HowToPage({required this.onNext, required this.onBack});

  static const _cards = [
    (' 📸 ', 'Pick any photo', 'Your fit, mirror pic, full outfit.'),
    (' ✂️ ', 'We cut you out', 'On-device. No cropping lessons.'),
    (' 🏠 ', 'Flick it home', 'Into the grid, WhatsApp, widgets.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 32),
          const Text(
            'Ah, fresh meat.\nShow me the fit.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 24),
          ..._cards.map((c) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(c.$1, style: const TextStyle(fontSize: 28)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.$2,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              c.$3,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )),
          const Spacer(flex: 1),
          _CtaRow(onNext: onNext, onBack: onBack),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

/// Steps 2–3: single-message pages (confidence, mindful shopping).
class _MessagePage extends StatelessWidget {
  final String hero;
  final String title;
  final String body;
  final VoidCallback onNext;
  final VoidCallback onBack;
  const _MessagePage({
    required this.hero,
    required this.title,
    required this.body,
    required this.onNext,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      hero: Text(hero, style: const TextStyle(fontSize: 88)),
      title: title,
      body: body,
      onNext: onNext,
      onBack: onBack,
    );
  }
}

/// Step 4: witty comebacks + dopamine.
class _JokesPage extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;
  const _JokesPage({required this.onNext, required this.onBack});

  static const _lines = [
    'This fit has main-character Wi-Fi.',
    'Laundry day\u2019s worst enemy, camera roll\u2019s best friend.',
    'Dress code: unbothered.',
  ];

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      hero: const Text('🤭', style: TextStyle(fontSize: 88)),
      title: 'Witty comebacks\nincluded',
      body: 'Every sticker lands with a roast-worthy one-liner. '
          'Tiny dopamine hits, all day — your camera roll has never '
          'been this funny.',
      onNext: onNext,
      onBack: onBack,
      extras: [
        const SizedBox(height: 20),
        for (final line in _lines)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Text(
              line,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontStyle: FontStyle.italic,
                fontSize: 13.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// Step 5: manual 2x3 widget add + 2x5 preview below.
class _WidgetsPage extends StatefulWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;
  const _WidgetsPage({required this.onNext, required this.onBack});

  @override
  State<_WidgetsPage> createState() => _WidgetsPageState();
}

class _WidgetsPageState extends State<_WidgetsPage> {
  bool _busy = false;

  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // The 2x3 latest-sticker widget. The recents (2x5) card stays
      // eligible in the growth rotation.
      await GrowthService.pinWidgets(
        androidName: 'LatestStickerWidgetProvider',
      );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const SizedBox(height: 32),
          const Text(
            'Fits on your\nhomescreen',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Pin your latest cutout where you\u2019ll see it most.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 20),
          // 2x3: the one they add right here, right now.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              children: [
                M3Container(
                  kStyleShapes[7],
                  color: Colors.white,
                  child: const SizedBox(width: 56, height: 56),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '2 × 3 · Latest sticker',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Your newest fit, always up.',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 52,
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
                  Text(
                    _busy ? 'Opening…' : 'Add the 2 × 3 widget',
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 2x5: decorative preview of what's next.
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '2 × 5 · Recent stickers',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                M3Container(
                  kStyleShapes[0],
                  color: Colors.white.withValues(alpha: 0.16),
                  child: const SizedBox(width: 48, height: 48),
                ),
                M3Container(
                  kStyleShapes[3],
                  color: Colors.white.withValues(alpha: 0.12),
                  child: const SizedBox(width: 48, height: 48),
                ),
                M3Container(
                  kStyleShapes[6],
                  color: Colors.white.withValues(alpha: 0.16),
                  child: const SizedBox(width: 48, height: 48),
                ),
              ],
            ),
          ),
          const Spacer(flex: 1),
          _CtaRow(onNext: widget.onNext, onBack: widget.onBack),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

class _NotificationsPage extends StatefulWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;
  final bool debugPreview;
  const _NotificationsPage({
    required this.onNext,
    required this.onBack,
    this.debugPreview = false,
  });

  @override
  State<_NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<_NotificationsPage> {
  bool _busy = false;

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
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 3),
          const Text('🔔', style: TextStyle(fontSize: 72)),
          const SizedBox(height: 28),
          const Text(
            'Nudges that don\u2019t nag',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'One ping at 8am, one at 10:30pm —\n\u201CAdd your outfit today.\u201D\nThat\u2019s it. No marketing. Ever.',
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
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
