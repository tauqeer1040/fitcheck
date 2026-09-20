import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';
import '../services/analytics_service.dart';
import '../services/notification_service.dart';
import 'gallery_screen.dart';

/// StickerPants first-run flow (see ONBOARDING.md). Six beats, ~60s:
/// welcome → see-it-work → notifications → do-the-thing (hands off to
/// the real app) → celebration (shown by the app itself) → paywall.
/// Steps 0–2 are full-screen pages; step 3 IS the gallery screen, so the
/// onboarding ends by *using the product*.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final PageController _pageController = PageController();
  final DateTime _startedAt = DateTime.now();
  int _index = 0;

  static const _pages = ['welcome', 'see_it_work', 'notifications'];

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.logOnboardingStarted();
    AnalyticsService.instance.logOnboardingStep(page: _pages[0], index: 0);
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
      AnalyticsService.instance.logOnboardingStep(
        page: _pages[_index],
        index: _index,
      );
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      _enterApp();
    }
  }

  Future<void> _enterApp() async {
    // The onboarding's last act is the product itself: the gallery's
    // empty state is the "first flick" stage (ghost card + coach mark).
    // Celebration + paywall hang off the first sticker save.
    //
    // Photo permission fires here, back-to-back after notifications —
    // no custom pre-dialog. Denials are handled later at the gallery
    // sheet (rationale + Settings deep-link).
    try {
      await PhotoManager.requestPermissionExtend();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed_v1', true);
    AnalyticsService.instance.logOnboardingCompleted(
      timeToCompleteMs: DateTime.now().difference(_startedAt).inMilliseconds,
    );
    if (!mounted) return;
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
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      body: SafeArea(
        child: Stack(
          children: [
            PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _WelcomePage(onNext: _next),
                _SeeItWorkPage(onNext: _next),
                _NotificationsPage(
                  onNext: _next,
                  onResult: (granted) {
                    AnalyticsService.instance.logNotificationPermission(
                      granted: granted,
                    );
                    if (granted) {
                      NotificationService.scheduleDaily();
                    }
                    _enterApp();
                  },
                ),
              ],
            ),
            // Progress dots.
            Positioned(
              left: 0,
              right: 0,
              top: 12,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < _pages.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _index ? 20 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _index
                            ? const Color(0xFFFFD60A)
                            : Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  final VoidCallback onNext;
  const _WelcomePage({required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 3),
          Image.asset('assets/logo3.png', height: 160, fit: BoxFit.contain),
          const SizedBox(height: 40),
          const Text(
            'Your outfit.\nNow a sticker.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w800,
              height: 1.15,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Cut yourself out of any photo.\nFlick. Stick. That's the whole app.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.4,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const Spacer(flex: 3),
          _PrimaryButton(label: 'Make my first sticker', onTap: onNext),
          const SizedBox(height: 8),
          Text(
            'Takes about 30 seconds. No account.',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SeeItWorkPage extends StatelessWidget {
  final VoidCallback onNext;
  const _SeeItWorkPage({required this.onNext});

  static const _cards = [
    (' 📸 ', 'Pick any photo', 'Your fit, your pet, your menace of a friend.'),
    (' ✂️ ', 'We cut you out', 'On-device. Magically. No cropping lessons.'),
    (' 💬 ', 'You\u2019re in the chat', 'A real WhatsApp sticker, sent as stickers.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),
          ..._cards.map((c) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(c.$1, style: const TextStyle(fontSize: 30)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.$2,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16.5,
                              ),
                            ),
                            const SizedBox(height: 3),
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
          const Spacer(flex: 3),
          _PrimaryButton(label: 'Show me', onTap: onNext),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _NotificationsPage extends StatefulWidget {
  final VoidCallback onNext;
  final ValueChanged<bool> onResult;
  const _NotificationsPage({required this.onNext, required this.onResult});

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
    widget.onResult(granted);
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
            'One ping at 8am, one at 10:30pm —\n\u201Cadd your outfit today.\u201D\nThat\u2019s it. No marketing. Ever.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.5,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const Spacer(flex: 3),
          _PrimaryButton(
            label: 'Sounds good',
            onTap: _busy ? null : _grant,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => widget.onResult(false),
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

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _PrimaryButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFFFD60A),
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
