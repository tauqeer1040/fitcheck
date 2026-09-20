import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// Ambient morphing photo container: clips [child] to an M3 polygon
/// that breathes between a circle and a square on a ping-pong loop —
/// the same morph math as M3 Expressive indicators, but as a real
/// container (the spinner package has no child slot, so this is
/// custom-built). Used only while the cutout is processing; the photo
/// crossfades to its fixed shape once done.
class MorphingShapeClip extends StatefulWidget {
  final Widget child;

  /// Loop period for one direction of the morph.
  final Duration period;

  const MorphingShapeClip({
    super.key,
    required this.child,
    this.period = const Duration(seconds: 3),
  });

  @override
  State<MorphingShapeClip> createState() => _MorphingShapeClipState();
}

class _MorphingShapeClipState extends State<MorphingShapeClip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Morph _morph;

  @override
  void initState() {
    super.initState();
    _morph = Morph(MaterialShapes.circle, MaterialShapes.square);
    _controller = AnimationController(vsync: this, duration: widget.period)
      ..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(MorphingShapeClip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) {
      _controller.duration = widget.period;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return ClipPath(
            clipper: _MorphClipper(_morph, _controller.value),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _MorphClipper extends CustomClipper<Path> {
  final Morph morph;
  final double progress;

  _MorphClipper(this.morph, this.progress);

  @override
  Path getClip(Size size) {
    // Unit-space morph path scaled to the widget box. RoundedPolygon
    // coordinates live in [0,1], so a diagonal scale maps them exactly.
    final path = morph.toPath(progress: progress);
    return path.transform(
      Matrix4.diagonal3Values(size.width, size.height, 1).storage,
    );
  }

  @override
  bool shouldReclip(_MorphClipper oldClipper) =>
      oldClipper.progress != progress || oldClipper.morph != morph;
}
