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
    // Non-opaque so the homescreen grid stays composited underneath —
    // the detail screen's BackdropFilter needs real content to blur,
    // and an opaque route would drop the grid from the scene entirely.
    opaque: false,
    barrierDismissible: false,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.25),
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

/// Container-transform-style route for the photo preview: the picked
/// photo zooms up softly instead of popping in. Non-opaque so the
/// frosted-glass backdrop stays composited over the live grid.
PageRouteBuilder<T> zoomPageRoute<T>({required Widget page}) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    opaque: false,
    barrierDismissible: false,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.25),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
