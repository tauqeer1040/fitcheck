import 'dart:io';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Shares a sticker through the phone's own share sheet, so it can go to
/// any app — not just WhatsApp.
///
/// The sticker must arrive as the user made it: its own cutout outline on
/// a transparent canvas. The failure mode this guards against is a
/// squared-off image sitting on a black background, which has two
/// separate causes and therefore two separate guards:
///
/// - **Alpha.** The art is decoded and re-encoded through `dart:ui`,
///   which carries the alpha channel through untouched, and it leaves as
///   PNG. PNG alpha is honoured by every share target; WebP's is dropped
///   or mishandled by some, and an app that cannot see the alpha channel
///   is exactly what paints the black box. Nothing is ever drawn onto a
///   fresh canvas, so no fill can get in behind the cutout.
/// - **Shape.** The image is never laid out, fitted or padded. The PNG
///   keeps the cutout's own dimensions, so a tall sticker stays tall
///   instead of being squared off to a cell.
///
/// Note this trades away sticker-ness for reach: chat apps receive the
/// PNG as an image, not as a sticker. Only the WhatsApp third-party
/// sticker API (see [WhatsAppStickerService]) can deliver a real
/// sticker, and it is WhatsApp-only.
class StickerShareService {
  /// Opens the platform share sheet with [imagePath] attached.
  ///
  /// Returns false when there is no file to share (rather than opening an
  /// empty sheet), and throws if the image cannot be re-encoded.
  static Future<bool> shareSticker(
    String imagePath, {
    String? text,
    String? title,
  }) async {
    final source = File(imagePath);
    if (!await source.exists()) return false;

    final png = await _asAlphaPng(source);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(png.path, mimeType: 'image/png')],
        text: text,
        title: title,
      ),
    );
    return true;
  }

  /// An alpha-preserving PNG copy of [source], cached next to the app's
  /// temp files.
  ///
  /// PNG rather than the stored WebP purely for reach: it is the one
  /// alpha-carrying format every share target renders correctly.
  static Future<File> _asAlphaPng(File source) async {
    final bytes = await source.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw StateError('Could not encode the sticker as PNG');
        }
        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}/share_sticker_'
          '${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await file.writeAsBytes(data.buffer.asUint8List());
        return file;
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
