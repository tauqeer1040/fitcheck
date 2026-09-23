import 'dart:io';

import 'package:flutter/material.dart';

import '../motion/app_haptics.dart';
import '../services/whatsapp_sticker_service.dart';

/// Homescreen widget samples: transparent rounded-square silhouette
/// holding the sticker + its tinted logo silhouette - 2x3 latest, 2x5
/// recents - with the user's actual latest stickers (logo fallback
/// when empty). Each sample's slider scrubs the logo angle while the
/// art stays static: the fullscreen silhouette rotation, one frozen
/// frame at a time. Opened from the appbar sparkle button.
Future<void> showShapeDemo(BuildContext context, {required int bgColor}) {
  AppHaptics.tap();
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _WidgetSamplesSheet(bgColor: bgColor),
  );
}

class _WidgetSamplesSheet extends StatefulWidget {
  final int bgColor;
  const _WidgetSamplesSheet({required this.bgColor});

  @override
  State<_WidgetSamplesSheet> createState() => _WidgetSamplesSheetState();
}

class _WidgetSamplesSheetState extends State<_WidgetSamplesSheet> {
  List<String> _recent = [];

  /// Per-sample logo-silhouette angles (radians): 0 = 2x3 latest,
  /// 1 = 2x5 recents. Preview-only — nothing persists.
  final List<double> _angles = [0.0, 0.0];

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

  /// Sticker art (logo fallback when empty), shown plain inside the
  /// shaped sample containers below.
  Widget _sampleImage(String? path, {required double size}) {
    final Widget img = (path != null && path.isNotEmpty && File(path).existsSync())
        ? Image.file(File(path), fit: BoxFit.cover)
        : Image.asset('assets/logo3.png', fit: BoxFit.cover);
    return SizedBox(width: size, height: size, child: img);
  }

  /// One sticker + its logo silhouette: tinted logo rotating
  /// underneath, art static on top. The slider scrubs the angle.
  Widget _spinningSticker({
    required String? imagePath,
    required double artSize,
    required int index,
  }) {
    final bgSize = artSize * 0.7;
    return SizedBox(
      width: artSize,
      height: artSize,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Transform.rotate(
            angle: _angles[index],
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(
                Color(widget.bgColor),
                BlendMode.srcIn,
              ),
              child: Image.asset(
                'assets/logo3.png',
                width: bgSize,
                fit: BoxFit.contain,
              ),
            ),
          ),
          _sampleImage(imagePath, size: artSize),
        ],
      ),
    );
  }

  /// Rotation slider per sample: 0–360° on the bg shape, art static.
  Widget _angleSlider(int index) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.rotate_left_rounded,
          color: Colors.white54,
          size: 16,
        ),
        SizedBox(
          width: 160,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFFFFD60A),
              inactiveTrackColor: Colors.white24,
              thumbColor: const Color(0xFFFFD60A),
              overlayShape: SliderComponentShape.noOverlay,
              trackHeight: 3,
            ),
            child: Slider(
              value: _angles[index],
              min: 0,
              max: 6.2832,
              divisions: 72,
              label: '${(_angles[index] * 57.2958).round()}°',
              onChanged: (v) => setState(() => _angles[index] = v),
            ),
          ),
        ),
        const Icon(
          Icons.rotate_right_rounded,
          color: Colors.white54,
          size: 16,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
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
          // 2x3 latest samples: gem + arch containers, mirroring the
          // real widget's alternating shapes.
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '2 × 3 · Latest sticker',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Transparent rounded-square silhouette holding the sticker
          // + its rotating bg shape (slider scrubs the angle).
          Container(
            width: 150,
            height: 150,
            decoration:
                BoxDecoration(borderRadius: BorderRadius.circular(28)),
            child: Center(
              child: _spinningSticker(
                imagePath: _recent.isNotEmpty ? _recent.first : null,
                artSize: 118,
                index: 0,
              ),
            ),
          ),
          _angleSlider(0),
          const SizedBox(height: 20),
          // 2x5 recents sample: logo silhouette + stickers.
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
            width: 300,
            height: 132,
            decoration:
                BoxDecoration(borderRadius: BorderRadius.circular(28)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (int i = 0; i < 3; i++)
                  _spinningSticker(
                    imagePath: i < _recent.length ? _recent[i] : null,
                    artSize: 88,
                    index: 1,
                  ),
              ],
            ),
          ),
          _angleSlider(1),
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
      ),
    );
  }
}
