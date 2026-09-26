import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/analytics_service.dart';
import '../services/moment_paywall_service.dart';
import '../services/preset_stickers_service.dart';
import '../services/revenuecat_service.dart';
import 'gallery_screen.dart';
import 'onboarding_flow.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  Widget? _targetScreen;
  bool _isTargetReady = false;
  bool _isTimerDone = false;
  bool _splashFadedOut = false;
  bool _onboardingDone = false;
  bool _paywallRequested = false;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 265),
    );
    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _fadeController,
        curve: Curves.fastOutSlowIn,
      ),
    );

    _fadeController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _splashFadedOut = true;
        });
        // Splash is out of the way, so the launch paywall can go up over
        // the gallery instead of behind the splash fade.
        unawaited(_showLaunchPaywall());
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(const AssetImage('assets/splash/splash.gif'), context);
    });

    _init();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final timer = Future<void>.delayed(const Duration(milliseconds: 800));

    // Bootstrap: analytics logs the launch. RevenueCat loads
    // passively on first actual use (gate/paywall/purchase) via
    // ensureInitialized — never warmed up here, never blocks launch.
    RevenueCatService.stampInstall();
    AnalyticsService.instance.logAppOpen();

    // First-run gate: onboarding owns the first session; returning
    // users go straight home. Progress (step + answers) persists so a
    // kill resumes mid-flow instead of restarting.
    final prefs = await SharedPreferences.getInstance();
    final completed = prefs.getBool('onboarding_completed_v1') ?? false;
    // A saved non-zero step means the flow is mid-flight, and that beats
    // the completion flag: otherwise a run started after an earlier one
    // finished would quit to the gallery and restart at Amen instead of
    // picking up where it was left.
    final resumeStep = prefs.getInt(OnboardingFlow.stepKey) ?? 0;
    final onboardingDone = completed && resumeStep <= 0;
    _onboardingDone = onboardingDone;
    // Ship with a wardrobe: the preset set lands in the store before the
    // gallery reads it, so a fresh install never opens on the empty
    // state. One-shot, and a no-op on any store that already has
    // stickers in it.
    await PresetStickersService.ensureSeeded();

    if (!mounted) return;
    if (onboardingDone) {
      setState(() {
        _targetScreen = GalleryScreen(onReady: _onTargetReady);
        _isTargetReady = false;
      });
    } else {
      // Onboarding has no onReady signal — mark ready so the splash
      // fades on the timer alone.
      setState(() {
        _targetScreen = const OnboardingFlow();
        _isTargetReady = true;
      });
    }

    await timer;
    if (mounted) {
      setState(() {
        _isTimerDone = true;
        _checkTransition();
      });
    }
  }

  void _onTargetReady() {
    if (mounted) {
      setState(() {
        _isTargetReady = true;
        _checkTransition();
      });
    }
  }

  /// Every launch after onboarding is finished opens on the RevenueCat
  /// paywall. Dismissible ([locked] false), forced past the frequency
  /// caps, and Pro users never see it.
  Future<void> _showLaunchPaywall() async {
    if (_paywallRequested || !_onboardingDone) return;
    _paywallRequested = true;
    try {
      await RevenueCatService.instance.ensureInitialized();
      if (!mounted || RevenueCatService.instance.isPro) return;
      await MomentPaywallService.maybeShow(
        context,
        placement: 'app_launch',
        locked: false,
        force: true,
      );
    } catch (_) {}
  }

  void _checkTransition() {
    if (_isTimerDone && _isTargetReady) {
      _fadeController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_targetScreen != null) ...[
            _targetScreen!,
          ],
          if (!_splashFadedOut) ...[
            FadeTransition(
              opacity: _fadeAnimation,
              child: Container(
                color: Colors.black,
                child: Center(
                  child: Image.asset(
                    'assets/splash/splash.gif',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
