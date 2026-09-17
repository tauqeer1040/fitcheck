import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import 'cutout_backend.dart';

/// Person backend: ML Kit Selfie Segmentation (stable, mask-based).
/// Chosen over subject-segmentation after the latter SIGSEGV'd natively
/// inside Play Services on real devices.
class SelfieBackend implements CutoutBackend {
  @override
  Future<MaskResult> segmentMask(String pngPath) async {
    final inputImage = InputImage.fromFilePath(pngPath);
    final segmenter = SelfieSegmenter(
      mode: SegmenterMode.single,
      enableRawSizeMask: false,
    );
    try {
      final mask = await segmenter.processImage(inputImage);
      if (mask == null) throw Exception('Segmenter returned no mask');
      if (mask.confidences.length < mask.width * mask.height) {
        throw Exception('Segmentation mask is incomplete');
      }
      return MaskResult(
        confidences: mask.confidences,
        width: mask.width,
        height: mask.height,
      );
    } finally {
      await segmenter.close();
    }
  }
}
