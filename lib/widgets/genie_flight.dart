import 'dart:math' as math;

import 'package:flutter/material.dart';

/// How long a sticker flight lasts. Kept in one place so the route's
/// reverse duration and the landing pop stay in sync.
///
/// Flights are intentionally linear: the default Hero rect tween carries
/// the sticker straight from A to B with no kicks, arcs, or wobbles.
const kGenieFlight = Duration(milliseconds: 450);

/// Shared page route for sticker flights: fast fade in, slow melt away on
/// the way back so the Hero has room to fly home. Fade-only by design —
/// the Hero does all the moving, so nothing fights it.
PageRouteBuilder<T> geniePageRoute<T>({required Widget page}) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 160),
    reverseTransitionDuration: kGenieFlight,
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (context, animation, _, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
        ),
        child: child,
      );
    },
  );
}

/// Subtle iOS jelly for fullscreen trips: straight path (linear direction
/// intact), gentle scale overshoot peaking near touchdown and settling
/// exactly to 1.0 at arrival. Transform-only.
Widget jellyShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final Hero toHero = toHeroContext.widget as Hero;
  return AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final t = animation.value;
      // Overshoot swells to ~1.04 around 85% of the flight, then relaxes
      // to exactly 1.0 at touchdown.
      final wobble = math.sin(t * math.pi) * (1 - t);
      final scale = 1.0 + 0.04 * wobble + 0.02 * math.sin(t * 2 * math.pi) * (1 - t);
      return Transform.scale(scale: scale, child: child);
    },
    child: toHero.child,
  );
}
