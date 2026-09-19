import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/analytics_service.dart';
import 'services/notification_service.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.black,
  ));
  // Daily outfit reminders (8:00 / 22:30). Init at every launch — the
  // OS permission dialog only ever shows once; scheduling is idempotent.
  // Fire-and-forget so startup is never blocked.
  // PostHog analytics warms up in parallel; a missing key only means
  // events stay local debug logs. Never blocks startup.
  unawaited(AnalyticsService.instance.initialize());
  unawaited(_bootNotifications());
  // Portrait only, always.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const FitCheckApp());
}

Future<void> _bootNotifications() async {
  try {
    await NotificationService.init();
    final granted = await NotificationService.requestPermissions();
    if (granted) await NotificationService.scheduleDaily();
  } catch (_) {
    // Reminders are a nicety — never block startup on them.
  }
}

class FitCheckApp extends StatelessWidget {
  const FitCheckApp({super.key});

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF1C1C1E);
    const yellow = Color(0xFFFFD60A);

    return MaterialApp(        title: 'StickerPants',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: yellow,
          brightness: Brightness.dark,
          surface: bg,
        ),
        scaffoldBackgroundColor: bg,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: yellow,
            foregroundColor: Colors.black,
          ),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}
