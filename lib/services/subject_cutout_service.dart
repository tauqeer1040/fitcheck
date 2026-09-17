import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'segmenters/cutout_backend.dart';
import 'segmenters/multiclass_backend.dart';
import 'segmenters/selfie_backend.dart';
import 'segmenters/subject_backend.dart';

/// Object-first cutout, tuned for SPEED:
///
/// pick -> downscale once (640px) -> backend confidence mask -> resample
/// to image dims -> binarize -> keep-largest-component (the one cheap
/// cleanup that kills stray background blobs) -> smoothstep alpha ramp ->
/// tight crop -> crisp white halo + soft inner melt -> lossless PNG.
///
/// Backend order for [CutoutSubject.auto] is subject-seg first (purpose
/// built masks), multiclass second (stable garments fallback). Backends
/// speak only in plain [MaskResult] data, never ML Kit types.
class SubjectCutoutService {
  /// Longest edge fed to the backend. The model thinks at ~256 internally,
  /// so this loses nothing and keeps ML Kit fast.
  static const int _segEdge = 640;

  /// Longest edge of the RGB working copy: real photo detail survives.
  static const int _rgbEdge = 2048;

  /// Export floor/ceiling (longest edge): small crops upscale for crisp
  /// stickers, huge ones stay bounded for file size and encode time.
  static const int _minExport = 1024;
  static const int _maxExport = 2048;

  /// Confidence ramp for feathered edges (wider = softer).
  static const double _lowThreshold = 0.35;
  static const double _highThreshold = 0.8;

  /// Subject-edge melt into the white halo, in final sticker pixels.
  static const double _personEdgeSoftness = 2.0;

  static final Map<CutoutSubject, CutoutBackend> _backends = {
    CutoutSubject.person: SelfieBackend(),
    CutoutSubject.object: MulticlassBackend(),
  };

  /// Debug override for the shoot-out (AppBar bug icon, debug builds):
  /// when set, every cut uses exactly this backend. Null = follow [subject].
  static CutoutBackend? debugBackend;

  /// Register a backend (e.g. a future object scanner) for a subject kind.
  static void registerBackend(CutoutSubject subject, CutoutBackend backend) {
    _backends[subject] = backend;
  }

  final CutoutSubject subject;

  SubjectCutoutService({this.subject = CutoutSubject.auto});

  CutoutBackend _resolve(CutoutSubject kind) =>
      _backends[kind] ??
      (throw UnsupportedError(
        'No CutoutBackend registered for $kind. '
        'Implement CutoutBackend (see segmenters/cutout_backend.dart) '
        'and call SubjectCutoutService.registerBackend().',
      ));

  Future<String> cutoutAndSave(String imagePath) async {
    final sw = Stopwatch()..start();
    final srcBytes = await File(imagePath).readAsBytes();

    // One decode; two GPU renders: small PNG for the backend, big RGBA
    // for a full-quality merge.
    final codec = await ui.instantiateImageCodec(srcBytes);
    final frame = await codec.getNextFrame();
    final full = frame.image;
    late final _Img seg;
    late final _Img rgb;
    try {
      seg = await _render(full, _segEdge, wantPng: true, wantRgba: false);
      rgb = await _render(full, _rgbEdge, wantPng: false, wantRgba: true);
    } finally {
      full.dispose();
    }
    final tDecode = sw.elapsedMilliseconds;

    final segPath = await _saveTemp(seg.png!, 'segment_input');

    // Subject-only by default (mask-only config, no bitmap path).
    // debugBackend (bug icon) can force multiclass/person for testing.
    // Any Dart failure surfaces as a clean error; a native crash would
    // kill the process and show in logcat instead.
    final chain = debugBackend != null
        ? [debugBackend!]
        : switch (subject) {
            CutoutSubject.auto => [SubjectBackend()],
            _ => [_resolve(subject)],
          };
    late final MaskResult mask;
    String backendName = 'none';
    Object? lastError;
    for (final backend in chain) {
      try {
        // Native mask dims (seg size or model grid); mapped to RGB below.
        mask = await backend.segmentMask(segPath);
        backendName = backend is SubjectBackend
            ? 'subject'
            : backend is MulticlassBackend
                ? 'multiclass'
                : 'selfie';
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) {
      throw Exception('No subject detected in the image');
    }
    final tSeg = sw.elapsedMilliseconds;

    final bin = _binarize(mask);
    late final Uint8List kept;
    try {
      kept = _keepLargest(bin, mask.width, mask.height);
    } on NoSubjectException {
      throw Exception('No subject detected in the image');
    }
    // Person bbox in mask coords -> RGB coords (+3% pad).
    final bb = _maskBbox(kept, mask.width, mask.height);
    final padX = (mask.width * 0.03).ceil();
    final padY = (mask.height * 0.03).ceil();
    final rx0 = ((bb[0] - padX) * rgb.w / mask.width)
        .floor()
        .clamp(0, rgb.w - 1);
    final ry0 = ((bb[1] - padY) * rgb.h / mask.height)
        .floor()
        .clamp(0, rgb.h - 1);
    final rx1 = ((bb[2] + padX + 1) * rgb.w / mask.width)
        .ceil()
        .clamp(1, rgb.w);
    final ry1 = ((bb[3] + padY + 1) * rgb.h / mask.height)
        .ceil()
        .clamp(1, rgb.h);
    final tClean = sw.elapsedMilliseconds;

    // Resample gate + confidences onto the RGB bbox only, then merge.
    final rw = rx1 - rx0;
    final rh = ry1 - ry0;
    final gate = _resampleRegion(
      mask.width,
      mask.height,
      (x, y) => kept[y * mask.width + x].toDouble(),
      rx0 * mask.width / rgb.w,
      ry0 * mask.height / rgb.h,
      rw * mask.width / rgb.w,
      rh * mask.height / rgb.h,
      rw,
      rh,
    );
    final conf = _resampleRegion(
      mask.width,
      mask.height,
      (x, y) => mask.confidences[y * mask.width + x],
      rx0 * mask.width / rgb.w,
      ry0 * mask.height / rgb.h,
      rw * mask.width / rgb.w,
      rh * mask.height / rgb.h,
      rw,
      rh,
    );
    final crop = _mergeRegion(rgb, gate, conf, rx0, ry0, rw, rh);
    final tComp = sw.elapsedMilliseconds;

    final sticker = await _outlineAndEncode(crop.pixels, crop.w, crop.h);
    final dir = await getApplicationDocumentsDirectory();
    final fileName =
        'fitcheck_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(sticker);
    final tTotal = sw.elapsedMilliseconds;
    debugPrint('[cutout] backend=$backendName decode=${tDecode}ms '
        'seg=${tSeg - tDecode}ms clean=${tClean - tSeg}ms '
        'merge=${tComp - tClean}ms export=${tTotal - tComp}ms '
        'total=${tTotal}ms');
    return file.path;
  }

  // ---------------------------------------------------------------- image IO

  /// GPU-renders [src] at capped size, returning whichever encodings are
  /// asked for (seg PNG for the backend file, RGBA for the merge).
  Future<_Img> _render(
    ui.Image src,
    int cap, {
    bool wantPng = false,
    bool wantRgba = false,
  }) async {
    final longest = math.max(src.width, src.height);
    final scale =
        longest <= cap ? 1.0 : cap / longest.toDouble();
    final outW = math.max(1, (src.width * scale).round());
    final outH = math.max(1, (src.height * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(
          0, 0, src.width.toDouble(), src.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final pic = recorder.endRecording();
    final out = await pic.toImage(outW, outH);
    try {
      Uint8List? png;
      Uint8List? rgba;
      if (wantPng) {
        final p = await out.toByteData(format: ui.ImageByteFormat.png);
        if (p == null) throw Exception('Could not encode image');
        png = p.buffer.asUint8List();
      }
      if (wantRgba) {
        final r =
            await out.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (r == null) throw Exception('Could not decode image');
        rgba = r.buffer.asUint8List();
      }
      return _Img(png: png, rgba: rgba, w: outW, h: outH);
    } finally {
      out.dispose();
    }
  }

  // ------------------------------------------------------------ mask + merge

  /// Bilinear resample of a source grid onto a destination REGION.
  /// ([sx],[sy]) is the region origin in source coords, ([sw],[sh]) its
  /// size, ([dw],[dh]) the destination size.
  Float32List _resampleRegion(
    int srcW,
    int srcH,
    double Function(int x, int y) sample,
    double sx,
    double sy,
    double sw,
    double sh,
    int dw,
    int dh,
  ) {
    final out = Float32List(dw * dh);
    for (int y = 0; y < dh; y++) {
      final gy = sy + (y + 0.5) * sh / dh - 0.5;
      final y0 = gy.floor().clamp(0, srcH - 1);
      final y1 = (y0 + 1).clamp(0, srcH - 1);
      final fy = (gy - y0).clamp(0.0, 1.0);
      for (int x = 0; x < dw; x++) {
        final gx = sx + (x + 0.5) * sw / dw - 0.5;
        final x0 = gx.floor().clamp(0, srcW - 1);
        final x1 = (x0 + 1).clamp(0, srcW - 1);
        final fx = (gx - x0).clamp(0.0, 1.0);
        final a = sample(x0, y0);
        final b = sample(x1, y0);
        final c = sample(x0, y1);
        final d = sample(x1, y1);
        out[y * dw + x] =
            a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
      }
    }
    return out;
  }

  /// Inclusive person bbox in mask coords: [x0, y0, x1, y1].
  List<int> _maskBbox(Uint8List kept, int w, int h) {
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (kept[y * w + x] == 1) {
          if (x < x0) x0 = x;
          if (y < y0) y0 = y;
          if (x > x1) x1 = x;
          if (y > y1) y1 = y;
        }
      }
    }
    return [x0, y0, x1, y1];
  }

  double _smooth01(double v) {
    final t = v.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// Copies the RGB bbox region and writes gate x feather alpha into it.
  _Rgba _mergeRegion(
    _Img rgb,
    Float32List gate,
    Float32List conf,
    int rx0,
    int ry0,
    int rw,
    int rh,
  ) {
    final src = rgb.rgba!;
    final out = Uint8List(rw * rh * 4);
    for (int y = 0; y < rh; y++) {
      for (int x = 0; x < rw; x++) {
        final s = ((ry0 + y) * rgb.w + rx0 + x) * 4;
        final d = (y * rw + x) * 4;
        out[d] = src[s];
        out[d + 1] = src[s + 1];
        out[d + 2] = src[s + 2];
        final i = y * rw + x;
        out[d + 3] = (gate[i] *
                _smooth01((conf[i] - _lowThreshold) /
                    (_highThreshold - _lowThreshold)) *
                255)
            .round()
            .clamp(0, 255);
      }
    }
    return _Rgba(out, rw, rh);
  }

  Uint8List _binarize(MaskResult mask) {
    final bin = Uint8List(mask.width * mask.height);
    for (int i = 0; i < bin.length; i++) {
      bin[i] = mask.confidences[i] >= 0.5 ? 1 : 0;
    }
    return bin;
  }

  /// Keeps only the largest 4-connected foreground component: kills stray
  /// background blobs in one cheap pass.
  Uint8List _keepLargest(Uint8List bin, int w, int h) {
    final labels = Int32List(w * h);
    final stack = Int32List(w * h);
    int cur = 0;
    int bestLabel = 0;
    int bestCount = 0;
    for (int i = 0; i < bin.length; i++) {
      if (bin[i] == 0 || labels[i] != 0) continue;
      cur++;
      int count = 0;
      int sp = 0;
      stack[sp++] = i;
      labels[i] = cur;
      while (sp > 0) {
        final p = stack[--sp];
        count++;
        final x = p % w;
        final y = p ~/ w;
        if (x > 0 && bin[p - 1] == 1 && labels[p - 1] == 0) {
          labels[p - 1] = cur;
          stack[sp++] = p - 1;
        }
        if (x + 1 < w && bin[p + 1] == 1 && labels[p + 1] == 0) {
          labels[p + 1] = cur;
          stack[sp++] = p + 1;
        }
        if (y > 0 && bin[p - w] == 1 && labels[p - w] == 0) {
          labels[p - w] = cur;
          stack[sp++] = p - w;
        }
        if (y + 1 < h && bin[p + w] == 1 && labels[p + w] == 0) {
          labels[p + w] = cur;
          stack[sp++] = p + w;
        }
      }
      if (count > bestCount) {
        bestCount = count;
        bestLabel = cur;
      }
    }
    if (bestCount < w * h * 0.01) {
      throw const NoSubjectException();
    }
    final out = Uint8List(w * h);
    for (int i = 0; i < out.length; i++) {
      out[i] = labels[i] == bestLabel ? 1 : 0;
    }
    return out;
  }

  // ------------------------------------------------------------------ export

  /// Tightens the crop, upscales small crops for crispness, encodes
  /// lossless PNG. NO baked border: rings render live (see StickerArt)
  /// so styles switch instantly. Edges keep their merge feather.
  Future<Uint8List> _outlineAndEncode(
      Uint8List pixels, int w, int h) async {
    int minX = w, minY = h, maxX = -1, maxY = -1;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (pixels[(y * w + x) * 4 + 3] > 8) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) throw Exception('Cutout is fully transparent');

    final cw = maxX - minX + 1;
    final ch = maxY - minY + 1;
    // Crispness guarantee: upscale small crops to the export floor.
    final longest = math.max(cw, ch);
    final upscale = (longest >= _minExport)
        ? 1.0
        : math.min(
            _minExport / longest.toDouble(),
            _maxExport / longest.toDouble(),
          );
    // Even ring geometry (final-px): fixed-width band + margin so the
    // halo is never clipped.
    final outCW = cw * upscale;
    final outCH = ch * upscale;
    final radius =
        (math.min(outCW, outCH) * 0.012).clamp(8.0, 24.0);
    final pad = (radius / upscale).ceil() + 10;
    final ex0 = (minX - pad).clamp(0, w - 1);
    final ey0 = (minY - pad).clamp(0, h - 1);
    final ex1 = (maxX + pad).clamp(0, w - 1);
    final ey1 = (maxY + pad).clamp(0, h - 1);
    final ew = ex1 - ex0 + 1;
    final eh = ey1 - ey0 + 1;
    final outW = math.max(1, (ew * upscale).round());
    final outH = math.max(1, (eh * upscale).round());

    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    try {
      final full = await descriptor
          .instantiateCodec()
          .then((c) => c.getNextFrame())
          .then((f) => f.image);
      try {
        final src = ui.Rect.fromLTWH(
            ex0.toDouble(), ey0.toDouble(), ew.toDouble(), eh.toDouble());
        final dst =
            ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);

        // 1. Even white halo: fixed-width ring of silhouette stamps (crisp
        // outside edge), 24 directions for smooth curves.
        final halo = ui.Paint()
          ..colorFilter = const ui.ColorFilter.mode(
            ui.Color(0xFFFFFFFF),
            ui.BlendMode.srcIn,
          )
          ..filterQuality = ui.FilterQuality.high
          ..isAntiAlias = true;
        const dirs = 24;
        for (int i = 0; i < dirs; i++) {
          final angle = i * 2 * math.pi / dirs;
          canvas.drawImageRect(
            full,
            src,
            dst.shift(ui.Offset(
              math.cos(angle) * radius,
              math.sin(angle) * radius,
            )),
            halo,
          );
        }

        // 2. Subject on top, edges melted softly into the white.
        final person = ui.Paint()
          ..filterQuality = ui.FilterQuality.high
          ..isAntiAlias = true
          ..maskFilter = const ui.MaskFilter.blur(
            ui.BlurStyle.normal,
            _personEdgeSoftness,
          );
        canvas.drawImageRect(full, src, dst, person);

        final pic = recorder.endRecording();
        final out = await pic.toImage(outW, outH);
        try {
          final png =
              await out.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) throw Exception('Could not encode sticker');
          return png.buffer.asUint8List();
        } finally {
          out.dispose();
        }
      } finally {
        full.dispose();
      }
    } finally {
      buffer.dispose();
      descriptor.dispose();
    }
  }

  Future<String> _saveTemp(Uint8List bytes, String prefix) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// One-time backfill: stamps the even white ring onto a halo-free PNG
  /// in place (for stickers saved while live borders were in testing).
  /// Same geometry as the cut-time halo so all stickers match.
  static Future<void> addWhiteRing(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    try {
      final raw =
          await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) return;
      final px = raw.buffer.asUint8List();
      final w = img.width;
      final h = img.height;
      int minX = w, minY = h, maxX = -1, maxY = -1;
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          if (px[(y * w + x) * 4 + 3] > 8) {
            if (x < minX) minX = x;
            if (y < minY) minY = y;
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (maxX < 0) return;
      final cw = maxX - minX + 1;
      final ch = maxY - minY + 1;
      final radius =
          (math.min(cw, ch) * 0.012).clamp(8.0, 24.0);
      final pad = radius.ceil() + 10;
      final ex0 = (minX - pad).clamp(0, w - 1);
      final ey0 = (minY - pad).clamp(0, h - 1);
      final ex1 = (maxX + pad).clamp(0, w - 1);
      final ey1 = (maxY + pad).clamp(0, h - 1);
      final ew = ex1 - ex0 + 1;
      final eh = ey1 - ey0 + 1;

      final buffer = await ui.ImmutableBuffer.fromUint8List(px);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      try {
        final full = await descriptor
            .instantiateCodec()
            .then((c) => c.getNextFrame())
            .then((f) => f.image);
        try {
          // Grow the canvas when the ring would clip at the file edge.
          final clipped = minX - pad < 0 ||
              minY - pad < 0 ||
              maxX + pad >= w ||
              maxY + pad >= h;
          final grow = clipped ? radius.ceil() + 12 : 0;
          final outW = ew + grow * 2;
          final outH = eh + grow * 2;
          final src = ui.Rect.fromLTWH(ex0.toDouble(), ey0.toDouble(),
              ew.toDouble(), eh.toDouble());
          final dst = ui.Rect.fromLTWH(grow.toDouble(), grow.toDouble(),
              ew.toDouble(), eh.toDouble());

          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          final halo = ui.Paint()
            ..colorFilter = const ui.ColorFilter.mode(
              ui.Color(0xFFFFFFFF),
              ui.BlendMode.srcIn,
            )
            ..filterQuality = ui.FilterQuality.high
            ..isAntiAlias = true;
          const dirs = 24;
          for (int i = 0; i < dirs; i++) {
            final angle = i * 2 * math.pi / dirs;
            canvas.drawImageRect(
              full,
              src,
              dst.shift(ui.Offset(
                math.cos(angle) * radius,
                math.sin(angle) * radius,
              )),
              halo,
            );
          }
          final person = ui.Paint()
            ..filterQuality = ui.FilterQuality.high
            ..isAntiAlias = true;
          canvas.drawImageRect(full, src, dst, person);

          final pic = recorder.endRecording();
          final out = await pic.toImage(outW, outH);
          try {
            final png =
                await out.toByteData(format: ui.ImageByteFormat.png);
            if (png == null) return;
            await File(path).writeAsBytes(png.buffer.asUint8List());
          } finally {
            out.dispose();
          }
        } finally {
          full.dispose();
        }
      } finally {
        buffer.dispose();
        descriptor.dispose();
      }
    } finally {
      img.dispose();
    }
  }
}

/// One GPU render: PNG bytes for the backend file and/or raw RGBA for
/// the merge, plus dimensions. Pixel buffers are Dart-side.
class _Img {
  final Uint8List? png;
  final Uint8List? rgba;
  final int w;
  final int h;

  _Img({this.png, this.rgba, required this.w, required this.h});
}

/// Merged crop with alpha, ready for outline + encode.
class _Rgba {
  final Uint8List pixels;
  final int w;
  final int h;

  _Rgba(this.pixels, this.w, this.h);
}
