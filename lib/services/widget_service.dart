import 'dart:io';

import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/outfit_sticker.dart';
import 'roast_service.dart';
import 'sticker_style_service.dart';
import 'whatsapp_sticker_service.dart';

/// Keeps the homescreen widgets fed. Kotlin providers read saved paths,
/// shapes, and colors from HomeWidget's SharedPreferences and render:
/// cutout art over a tinted silhouette on transparency — no container.
/// 2x4 = three recent side by side (static silhouettes); 2x2 = single
/// latest sticker over a flip-book silhouette rotating one frame/sec.
class WidgetService {
  static const appGroup = 'stickerpants_widgets';

  /// Writes the latest sticker paths and refreshes both providers.
  /// loadStickers() returns newest-first (gallery inserts at 0), so a
  /// plain take(3) is the three most recent — no reversing.
  ///
  /// [bgColor] is the live wordmark shadow color (0xAARRGGBB, same int
  /// layout Android uses): the cookie backdrop tints to match. Null
  /// leaves the last pushed color alone.
  ///
  /// Shapes (native clips in WidgetBitmaps): 2x4 cells cycle
  /// clamshell/semicircle, offset by save count so the widget visibly
  /// changes; the 2x2 latest sticker alternates arch/gem per save.
  static Future<void> updateAll({int? bgColor}) async {
    try {
      final List<OutfitSticker> stickers = await WhatsAppStickerService
          .loadStickers();
      final recent = stickers.take(3).toList();
      const quad = ['clamshell', 'semicircle'];
      for (int i = 0; i < 3; i++) {
        final path = i < recent.length ? recent[i].imagePath : '';
        await HomeWidget.saveWidgetData('sticker_$i', path);
        await HomeWidget.saveWidgetData(
          'sticker_${i}_shape',
          quad[(stickers.length + i) % quad.length],
        );
        await HomeWidget.saveWidgetData(
          'sticker_${i}_color',
          i < recent.length
              ? (recent[i].dominantColor ?? kFallbackStickerColor)
              : kFallbackStickerColor,
        );
        // The sticker's OWN homescreen shape index (kStyleShapes):
        // native resolves it to the matching silhouette so the widget
        // mirrors the grid cell. Null = legacy hash fallback, same as
        // the grid.
        final shapeIdx = i < recent.length
            ? (recent[i].shapeIndex ?? fallbackShapeIndex(recent[i].id))
            : -1;
        await HomeWidget.saveWidgetData('sticker_${i}_shapeIdx', shapeIdx);
      }
      await HomeWidget.saveWidgetData(
        'latest_shape',
        stickers.length.isEven ? 'arch' : 'gem',
      );
      // Funny line: the latest sticker's roast (deterministic salt, so
      // it only changes when a newer sticker lands). Empty = hidden.
      await HomeWidget.saveWidgetData(
        'funny_line',
        recent.isNotEmpty
            ? RoastService.roastFor(recent.first, salt: 0)
            : '',
      );
      // Caption size both widgets honor. Saved as a string: doubles
      // cross the method channel as raw Long bits, which native
      // toFloat() turns into garbage magnitudes (crashed widget
      // inflation) — the native side parses strings safely.
      try {
        final prefs = await SharedPreferences.getInstance();
        final sp = (prefs.getDouble('funny_text_sp') ?? 15.0)
            .clamp(8.0, 24.0);
        await HomeWidget.saveWidgetData(
          'funny_text_sp',
          sp.toStringAsFixed(1),
        );
      } catch (_) {}
      if (bgColor != null) {
        await HomeWidget.saveWidgetData('bg_color', bgColor);
      }
      await HomeWidget.updateWidget(
        androidName: 'RecentStickersWidgetProvider',
        name: 'RecentStickersWidgetProvider',
      );
      await HomeWidget.updateWidget(
        androidName: 'LatestStickerWidgetProvider',
        name: 'LatestStickerWidgetProvider',
      );
    } catch (_) {
      // Never let widget upkeep break the main flow.
    }
  }

  /// Bitmap decode happens natively; this exists for future Dart-side
  /// scaling if providers need pre-rendered tiles.
  static bool fileExists(String path) => File(path).existsSync();
}
