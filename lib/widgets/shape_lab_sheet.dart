import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../motion/app_haptics.dart';

/// Shape lab: wordmark-shadow height multiplier (0.5–1.5x).
/// Opened by long-pressing the appbar wordmark. Sticker backdrops
/// are hardcoded to 1.0 and not tunable.
Future<void> showShapeLab(
  BuildContext context, {
  required double initial,
  required ValueChanged<double> onChanged,
}) {
  AppHaptics.tap();
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ShapeLabSheet(
      initial: initial,
      onChanged: onChanged,
    ),
  );
}

class _ShapeLabSheet extends StatefulWidget {
  final double initial;
  final ValueChanged<double> onChanged;

  const _ShapeLabSheet({required this.initial, required this.onChanged});

  @override
  State<_ShapeLabSheet> createState() => _ShapeLabSheetState();
}

class _ShapeLabSheetState extends State<_ShapeLabSheet> {
  late double _v;
  bool _rotateImage = false;

  @override
  void initState() {
    super.initState();
    _v = widget.initial;
    _loadRotate();
  }

  Future<void> _loadRotate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _rotateImage = prefs.getBool('morph_rotate_image') ?? false;
      });
    } catch (_) {}
  }

  Future<void> _setRotate(bool v) async {
    setState(() => _rotateImage = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('morph_rotate_image', v);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(
            child: Text(
              'Wordmark shadow size',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Shadow height',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${(_v * 100).round()}%',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFFFFD60A),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
              thumbColor: const Color(0xFFFFD60A),
              overlayColor:
                  const Color(0xFFFFD60A).withValues(alpha: 0.2),
              trackHeight: 3,
            ),
            child: Slider(
              value: _v.clamp(0.5, 1.5),
              min: 0.5,
              max: 1.5,
              divisions: 20,
              onChanged: (v) {
                setState(() => _v = v);
                widget.onChanged(v);
              },
              onChangeEnd: (_) => AppHaptics.step(),
            ),
          ),
          const SizedBox(height: 8),
          // Rotate-image toggle: when on, the photo turns WITH the
          // morphing outline; when off, only the outline turns.
          // Applies to the next cutout.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Rotate image with shape',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              'Applies to next cutout',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
            activeColor: const Color(0xFFFFD60A),
            value: _rotateImage,
            onChanged: (v) {
              AppHaptics.step();
              _setRotate(v);
            },
          ),
        ],
      ),
    );
  }
}
