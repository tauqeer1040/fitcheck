import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:tflite_flutter/tflite_flutter.dart';

import 'cutout_backend.dart';

/// Object/garment backend: MediaPipe Selfie-Multiclass (256x256, float32)
/// run in-process via TFLite. Understands hair / skin / CLOTHES /
/// accessories — so folded pants, hanger shots, and other person-free
/// subjects segment as foreground instead of erroring out.
///
/// Preprocessing mirrors the model card: aspect-fit RGB into 256x256
/// (pad right/bottom), float32 in [0, 1]. Postprocessing: argmax over the
/// 6 class probabilities (argmax is softmax-invariant, so no softmax
/// needed); subject confidence = best non-background probability.
/// Runs only as fallback / in object mode — the person path stays first.
class MulticlassBackend implements CutoutBackend {
  static const int _size = 256;

  /// 0 background, 1 hair, 2 body-skin, 3 face-skin, 4 clothes, 5 others.
  static const int _classes = 6;

  static Interpreter? _interpreter;

  static Future<Interpreter> _load() async {
    final existing = _interpreter;
    if (existing != null) return existing;
    final created = await Interpreter.fromAsset(
      'assets/models/selfie_multiclass_256x256.tflite',
    );
    _interpreter = created;
    return created;
  }

  @override
  Future<MaskResult> segmentMask(String pngPath) async {
    final interpreter = await _load();

    // Decode + aspect-fit letterbox into the 256 square (pad right/bottom
    // so the content origin stays (0,0) and mapping back stays trivial).
    final bytes = await File(pngPath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    MaskResult result;
    try {
      final longest =
          src.width > src.height ? src.width : src.height;
      final s = _size / longest.toDouble();
      final cw = (src.width * s).round().clamp(1, _size);
      final ch = (src.height * s).round().clamp(1, _size);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        src,
        ui.Rect.fromLTWH(
            0, 0, src.width.toDouble(), src.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final pic = recorder.endRecording();
      final img = await pic.toImage(_size, _size);
      try {
        final raw = await img.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (raw == null) throw Exception('Could not prepare model input');
        final px = raw.buffer.asUint8List();

        // [1,256,256,3] float RGB in [0,1].
        final input = List.generate(
          1,
          (_) => List.generate(
            _size,
            (y) => List.generate(
              _size,
              (x) {
                final o = (y * _size + x) * 4;
                return [
                  px[o] / 255.0,
                  px[o + 1] / 255.0,
                  px[o + 2] / 255.0,
                ];
              },
            ),
          ),
        );
        final output = List.generate(
          1,
          (_) => List.generate(
            _size,
            (_) => List.generate(
              _size,
              (_) => List.filled(_classes, 0.0),
            ),
          ),
        );

        interpreter.run(input, output);

        // Argmax over classes; subject = best of hair/skin/clothes/others.
        final grid = output[0];
        final conf = Float32List(cw * ch);
        for (int y = 0; y < ch; y++) {
          for (int x = 0; x < cw; x++) {
            final probs = grid[y][x];
            double best = 0;
            for (int c = 1; c < _classes; c++) {
              if (probs[c] > best) best = probs[c];
            }
            conf[y * cw + x] = best;
          }
        }
        result = MaskResult(confidences: conf, width: cw, height: ch);
      } finally {
        img.dispose();
      }
    } finally {
      src.dispose();
    }
    return result;
  }
}
