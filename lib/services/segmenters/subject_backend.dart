import 'dart:io';
import 'dart:ui' as ui;

import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';

import 'cutout_backend.dart';

/// General-subject backend: ML Kit Subject Segmentation (^0.2.1),
/// mask-ONLY configuration.
///
/// History: 0.0.3 SIGSEGV'd natively inside Play Services on this device.
/// The crash lived in the bitmap-handling path, so every bitmap option
/// stays OFF here — we take only the foreground confidence mask, which is
/// plain Dart data. If logcat ever shows another native crash from this
/// backend, it is disqualified and the multiclass path takes over.
class SubjectBackend implements CutoutBackend {
  @override
  Future<MaskResult> segmentMask(String pngPath) async {
    final inputImage = InputImage.fromFilePath(pngPath);
    final segmenter = SubjectSegmenter(
      options: SubjectSegmenterOptions(
        enableForegroundBitmap: false,
        enableForegroundConfidenceMask: true,
        enableMultipleSubjects: SubjectResultOptions(
          enableConfidenceMask: false,
          enableSubjectBitmap: false,
        ),
      ),
    );
    try {
      final result = await segmenter.processImage(inputImage);
      final m = result.foregroundConfidenceMask;
      if (m == null || m.isEmpty) {
        throw Exception('Subject segmenter returned no mask');
      }
      // The flat mask carries no dimensions; read them off the input.
      final bytes = await File(pngPath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      if (m.length < w * h) {
        throw Exception('Subject mask is incomplete');
      }
      return MaskResult(confidences: m, width: w, height: h);
    } finally {
      await segmenter.close();
    }
  }
}
