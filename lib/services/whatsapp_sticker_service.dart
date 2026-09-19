import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/outfit_sticker.dart';

/// Bridge to the native WhatsApp sticker-pack flow (official third-party
/// sticker API, github.com/WhatsApp/stickers).
///
/// There is deliberately no plain "share an image" fallback here: anything
/// sent through a share intent arrives in chat apps as a photo (JPEG, no
/// alpha). Stickers only travel as stickers via a whitelisted pack — so
/// share = build/update the user's pack and open WhatsApp's confirmation.
class WhatsAppStickerService {
  static const MethodChannel _channel =
      MethodChannel('stickerpants/whatsapp_stickers');

  /// Loads every saved sticker (newest last, as persisted by the gallery).
  static Future<List<OutfitSticker>> loadStickers() async {
    final dir = await getApplicationDocumentsDirectory();
    final metaFile = File('${dir.path}/stickers.json');
    if (!await metaFile.exists()) return [];
    final list =
        (jsonDecode(await metaFile.readAsString()) as List)
            .cast<Map<String, dynamic>>();
    return list.map(OutfitSticker.fromJson).toList();
  }

  /// Builds the 512x512 WebP pack from the newest [limit] stickers and
  /// launches WhatsApp's add-pack confirmation. Native side shows a toast
  /// if WhatsApp isn't installed. Throws on pack-build failure.
  static Future<void> addPack(
    List<OutfitSticker> stickers, {
    int limit = 30,
  }) async {
    final paths = stickers.take(limit).map((s) => s.imagePath).toList();
    await _channel.invokeMethod<bool>('addPackToWhatsApp', {'paths': paths});
  }
}
