/// Seam for current + future segmentation backends.
///
/// Today only people are supported (see [SelfieBackend]). Scanning generic
/// OBJECTS later means adding one class that implements [CutoutBackend] and
/// registering it for [CutoutSubject.object] — [SubjectCutoutService] and
/// every screen stay untouched, because they only ever speak in plain
/// [MaskResult] data, never in ML Kit types.
///
/// A future object backend can be anything that yields a foreground
/// confidence mask: a stabilized subject-segmentation build, a MediaPipe
/// selfie/multiclass model, or even a server call. Contract:
/// * [segmentMask] receives the pre-scaled input PNG bytes + dimensions.
/// * Returns confidences in 0..1, row-major, length == width * height.
/// * Higher = more likely subject. The service thresholds, cleans,
///   composites, and outlines from there.
library;

enum CutoutSubject { person, object, auto }

/// Thrown when a backend finds no usable subject. The service catches this
/// for fallback ([CutoutSubject.auto]) and converts it to a user-facing
/// message only when every backend fails.
class NoSubjectException implements Exception {
  const NoSubjectException();
}

class MaskResult {
  final List<double> confidences;
  final int width;
  final int height;

  const MaskResult({
    required this.confidences,
    required this.width,
    required this.height,
  });
}

abstract class CutoutBackend {
  Future<MaskResult> segmentMask(String pngPath);
}
