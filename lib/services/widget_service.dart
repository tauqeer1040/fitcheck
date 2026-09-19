import 'dart:io';

import 'package:home_widget/home_widget.dart';

import '../models/outfit_sticker.dart';
import 'whatsapp_sticker_service.dart';

/// Keeps the homescreen widgets fed. Kotlin providers read saved paths
/// from HomeWidget's SharedPreferences and render the user's latest
/// stickers as bitmaps. 2x4 = three recent side by side; 2x2 = single
/// latest sticker.
class WidgetService {
  static const appGroup = 'stickerpants_widgets';

  /// Writes the latest sticker paths and refreshes both providers.
  static Future<void> updateAll() async {
    try {
      final List<OutfitSticker> stickers = await WhatsAppStickerService
          .loadStickers();
      final recent = stickers.length <= 3
          ? stickers.reversed.toList()
          : stickers.reversed.take(3).toList();
      for (int i = 0; i < 3; i++) {
        final path = i < recent.length ? recent[i].imagePath : '';
        await HomeWidget.saveWidgetData('sticker_$i', path);
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
