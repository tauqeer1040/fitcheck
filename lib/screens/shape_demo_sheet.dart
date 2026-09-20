import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';

import '../motion/app_haptics.dart';
import '../services/sticker_style_service.dart';
import '../services/whatsapp_sticker_service.dart';

/// Homescreen widget samples: live miniature previews of the 2x4
/// recents widget and the 2x2 latest widget — 12-cookie M3E container
/// with the user's actual latest stickers (logo fallback when empty).
/// Opened from the appbar sparkle button.
Future<void> showShapeDemo(BuildContext context) {
  AppHaptics.tap();
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _WidgetSamplesSheet(),
  );
}

class _WidgetSamplesSheet extends StatefulWidget {
  const _WidgetSamplesSheet();

  @override
  State<_WidgetSamplesSheet> createState() => _WidgetSamplesSheetState();
}

class _WidgetSamplesSheetState extends State<_WidgetSamplesSheet> {
  List<String> _recent = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stickers =
          await WhatsAppStickerService.loadStickers();
      if (!mounted) return;
      setState(() {
        _recent = stickers.take(3).map((s) => s.imagePath).toList();
      });
    } catch (_) {}
  }

  Widget _sampleImage(String? path, {required double size}) {
    final Widget img = (path != null && path.isNotEmpty && File(path).existsSync())
        ? Image.file(File(path), fit: BoxFit.cover)
        : Image.asset('assets/logo3.png', fit: BoxFit.cover);
    return SizedBox(width: size, height: size, child: img);
  }

  @override
  Widget build(BuildContext context) {
    final cookie = kStyleShapes[1]; // c12_sided_cookie
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Homescreen widgets',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'How they look on your home screen',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 20),
          // 2x4 recents sample: cookie container, three latest leaking
          // over the edge like the real widget.
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '2 × 4 · Recent stickers',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: M3Container(
              cookie,
              width: 300,
              height: 132,
              color: const Color(0xE61C1C1E),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (int i = 0; i < 3; i++)
                      _sampleImage(
                        i < _recent.length ? _recent[i] : null,
                        size: 88,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 2x2 latest sample.
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '2 × 2 · Latest sticker',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: M3Container(
              cookie,
              width: 150,
              height: 150,
              color: const Color(0xE61C1C1E),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _sampleImage(
                  _recent.isNotEmpty ? _recent.first : null,
                  size: 118,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFFD60A),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(
                horizontal: 32,
                vertical: 14,
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w800),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
