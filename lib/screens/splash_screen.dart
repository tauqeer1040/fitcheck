import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/analytics_service.dart';
import '../services/revenuecat_service.dart';
import 'gallery_screen.dart';

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
    // users go straight home.
    //
    // Onboarding SKIPPED for now: home loads directly on every launch.
    // (OnboardingFlow still writes `onboarding_completed_v1` when run.)
    await SharedPreferences.getInstance();

    if (!mounted) return;
    setState(() {
      _targetScreen = GalleryScreen(onReady: _onTargetReady);
      _isTargetReady = false;
    });

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
