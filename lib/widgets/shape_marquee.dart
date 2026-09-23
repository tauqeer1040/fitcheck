import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';

import '../motion/app_motion.dart';
import '../services/sticker_style_service.dart';

/// Ambient marquee of every M3 shape, tinted in the given palette.
/// A seamless loop (tripled content, invisible wrap) at ~60fps steps;
/// static under reduced motion, never intercepts gestures.
///
/// [locked] overlays a small lock badge on every tile — the expired
/// upsell teaser. Unlocked (thank-you) shows bare shapes.
class ShapeMarquee extends StatefulWidget {
  final List<int> colors;
  final bool locked;
  const ShapeMarquee({super.key, required this.colors, this.locked = false});

  @override
  State<ShapeMarquee> createState() => _ShapeMarqueeState();
}

class _ShapeMarqueeState extends State<ShapeMarquee> {
  late final ScrollController _ctrl;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  void _maybeStart() {
    if (!mounted || !_ctrl.hasClients) return;
    if (AppMotion.reducedMotion(context)) return;
    // Start in the middle set: wrapping subtracts one set width, which
    // is invisible because every set is identical — a true loop.
    _ctrl.jumpTo(_setWidth);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || !_ctrl.hasClients) return;
      var next = _ctrl.offset + 1;
      if (next >= _setWidth * 2) next -= _setWidth;
      _ctrl.jumpTo(next);
    });
  }

  /// One full shape set in px: 44px tile + 10px gap each.
  double get _setWidth => 54.0 * kStyleShapes.length;

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors =
        widget.colors.isEmpty ? const [0xFFFFD60A] : widget.colors;
    // Tripled identical sets so the wrap-around reads as a loop.
    final shapes = [...kStyleShapes, ...kStyleShapes, ...kStyleShapes];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.locked
              ? 'Every shape, unlocked with Max'
              : 'Every shape unlocked, in your colors',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 54,
          child: ListView.builder(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: shapes.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  M3Container(
                    shapes[i],
                    color: Color(colors[i % colors.length]).withValues(
                      alpha: widget.locked ? 0.55 : 1.0,
                    ),
                    child: const SizedBox(width: 44, height: 44),
                  ),
                  if (widget.locked)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          color: Color(0xFF1C1C1E),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.lock_rounded,
                          color: Colors.white,
                          size: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
