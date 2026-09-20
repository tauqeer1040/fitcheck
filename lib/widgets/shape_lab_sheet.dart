import 'package:flutter/material.dart';

import '../motion/app_haptics.dart';

/// Shape lab: three sliders tuning sticker background-shape sizes.
/// Opened by long-pressing the appbar wordmark. Values persist via
/// the callbacks (host owns storage); changes apply live.
class ShapeLabValues {
  double grid;
  double full;
  double mark;

  ShapeLabValues({
    this.grid = 0.7,
    this.full = 0.7,
    this.mark = 1.0,
  });
}

Future<void> showShapeLab(
  BuildContext context, {
  required ShapeLabValues initial,
  required ValueChanged<ShapeLabValues> onChanged,
}) {
  AppHaptics.tap();
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ShapeLabSheet(initial: initial, onChanged: onChanged),
  );
}

class _ShapeLabSheet extends StatefulWidget {
  final ShapeLabValues initial;
  final ValueChanged<ShapeLabValues> onChanged;

  const _ShapeLabSheet({required this.initial, required this.onChanged});

  @override
  State<_ShapeLabSheet> createState() => _ShapeLabSheetState();
}

class _ShapeLabSheetState extends State<_ShapeLabSheet> {
  late ShapeLabValues _v;

  @override
  void initState() {
    super.initState();
    _v = ShapeLabValues(
      grid: widget.initial.grid,
      full: widget.initial.full,
      mark: widget.initial.mark,
    );
  }

  void _apply(void Function() apply) {
    setState(apply);
    widget.onChanged(_v);
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
              'Shape sizes',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _row('Homescreen stickers', _v.grid, 0.3, 1.2,
              (v) => _apply(() => _v.grid = v)),
          _row('Fullscreen sticker', _v.full, 0.3, 1.2,
              (v) => _apply(() => _v.full = v)),
          _row('Wordmark shadow', _v.mark, 0.5, 1.5,
              (v) => _apply(() => _v.mark = v)),
        ],
      ),
    );
  }

  Widget _row(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${(value * 100).round()}%',
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
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: 18,
              onChanged: onChanged,
              onChangeEnd: (_) => AppHaptics.step(),
            ),
          ),
        ],
      ),
    );
  }
}
