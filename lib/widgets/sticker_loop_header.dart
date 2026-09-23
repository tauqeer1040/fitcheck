import 'dart:async';

import 'package:flutter/material.dart';

import '../models/outfit_sticker.dart';
import '../motion/app_motion.dart';
import '../services/sticker_style_service.dart';
import '../services/whatsapp_sticker_service.dart';
import 'shaped_sticker.dart';

/// Auto-advancing sticker hero for bottom sheets: one big centered
/// sticker with its bg shape, rendered exactly like fullscreen
/// (shapeScale 1.0) but static — no rotation, no entrance animation.
/// Cycles through every sticker on a timer; swipeable too. Empty
/// gallery renders nothing.
class StickerLoopHeader extends StatefulWidget {
  final double size;
  final Duration interval;
  const StickerLoopHeader({
    super.key,
    this.size = 200,
    this.interval = const Duration(milliseconds: 750),
  });

  @override
  State<StickerLoopHeader> createState() => _StickerLoopHeaderState();
}

class _StickerLoopHeaderState extends State<StickerLoopHeader> {
  List<OutfitSticker> _stickers = [];
  late final PageController _pages;
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _pages = PageController();
    _load();
  }

  Future<void> _load() async {
    try {
      final stickers = await WhatsAppStickerService.loadStickers();
      if (!mounted) return;
      setState(() => _stickers = stickers);
      _maybeStart();
    } catch (_) {}
  }

  @override
  void didUpdateWidget(StickerLoopHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interval != widget.interval) _maybeStart();
  }

  void _maybeStart() {
    if (_stickers.length < 2) return;
    if (AppMotion.reducedMotion(context)) return;
    _timer?.cancel();
    _timer = Timer.periodic(widget.interval, (_) {
      if (!mounted || !_pages.hasClients) return;
      final next = (_index + 1) % _stickers.length;
      // Hard cut, no slide animation.
      _pages.jumpToPage(next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_stickers.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.size,
          child: PageView.builder(
            controller: _pages,
            itemCount: _stickers.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) {
              final s = _stickers[i];
              return Center(
                child: ShapedSticker(
                  imagePath: s.imagePath,
                  shapeIndex: s.shapeIndex ?? fallbackShapeIndex(s.id),
                  dominantColor:
                      s.dominantColor ?? kFallbackStickerColor,
                  width: widget.size,
                  height: widget.size,
                  // Full-bleed silhouette, like fullscreen. Static:
                  // no rotation, no open/collapse progress.
                  shapeScale: 1.0,
                ),
              );
            },
          ),
        ),
        // Dots for small sets; nothing for big ones (no numbers).
        if (_stickers.length > 1 && _stickers.length <= 12) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 0; i < _stickers.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _index ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _index
                        ? const Color(0xFFFFD60A)
                        : Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
