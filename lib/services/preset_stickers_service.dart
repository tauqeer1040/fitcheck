import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/outfit_sticker.dart';
import 'pro_access_service.dart';
import 'sticker_style_service.dart';

/// The stickers the app ships with: 15 cutouts already sitting in the
/// grid on a fresh install, so the first thing a new user sees is a
/// wardrobe instead of the empty state.
///
/// In every other respect they are ordinary stickers — delete them, share
/// them to WhatsApp, pin them to a widget. Seeding runs once, and
/// deleting them sticks: the next launch never brings them back.
///
/// They do count against the free quota. Seeding moves the free counter
/// to 15, so 15 of the 30 free stickers are left for the user's own fits.
class PresetStickersService {
  PresetStickersService._();

  /// Bumped when the shipped set changes: a new key seeds the new set
  /// once, without resurrecting anything deleted from the old one.
  static const String _seededKey = 'preset_stickers_seeded_v1';

  /// A deliberate pick out of the shipped onboarding sheet — the first
  /// ten, then the last five.
  static const List<String> assets = [
    'assets/onboarding/fitcheck_1790191962563.webp',
    'assets/onboarding/fitcheck_1790191969091.webp',
    'assets/onboarding/fitcheck_1790191976439.webp',
    'assets/onboarding/fitcheck_1790191987013.webp',
    'assets/onboarding/fitcheck_1790191994862.webp',
    'assets/onboarding/fitcheck_1790192004017.webp',
    'assets/onboarding/fitcheck_1790192013053.webp',
    'assets/onboarding/fitcheck_1790192020518.webp',
    'assets/onboarding/fitcheck_1790192028291.webp',
    'assets/onboarding/fitcheck_1790192037501.webp',
    'assets/onboarding/fitcheck_1790192917726.webp',
    'assets/onboarding/fitcheck_1790192927514.webp',
    'assets/onboarding/fitcheck_1790192941729.webp',
    'assets/onboarding/fitcheck_1790192955405.webp',
    'assets/onboarding/fitcheck_1790193084453.webp',
  ];

  /// Copies that set into the sticker store. Safe to call on every
  /// launch: once seeded it is a no-op, and it never touches a library
  /// that already has anything in it (an upgrade, or anyone who got
  /// there first — 15 uninvited stickers in someone's wardrobe is worse
  /// than an empty grid).
  static Future<void> ensureSeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_seededKey) ?? false) return;

      final dir = await getApplicationDocumentsDirectory();
      final metaFile = File('${dir.path}/stickers.json');
      if (await metaFile.exists()) {
        final existing = jsonDecode(await metaFile.readAsString()) as List;
        if (existing.isNotEmpty) {
          // Nothing to do here — just never look again.
          await prefs.setBool(_seededKey, true);
          return;
        }
      }

      final seeded = <OutfitSticker>[];
      for (var i = 0; i < assets.length; i++) {
        // Deterministic id from the asset file: the onboarding unlock
        // batches grant from the same pool with the same scheme, so a
        // seeded sticker is never duplicated by an unlock.
        final id = 'fit_${assets[i].split('/').last.replaceAll('.webp', '')}';
        try {
          final bytes = await rootBundle.load(assets[i]);
          final file = File('${dir.path}/$id.webp');
          await file.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            flush: true,
          );
          // Same styling pass a captured sticker gets, so a preset fills
          // its M3 card in the grid like everything else.
          final style = await StickerStyleService.analyze(file.path);
          seeded.add(OutfitSticker(
            id: id,
            imagePath: file.path,
            // Staggered so the shipped order survives anywhere the store
            // gets re-sorted by time.
            createdAt:
                DateTime.now().subtract(Duration(minutes: assets.length - i)),
            // The cutouts ship with their white halo baked in.
            haloStripped: false,
            shapeIndex: style.shapeIndex,
            dominantColor: style.dominantColor,
          ));
        } catch (_) {
          // One unreadable asset never blocks the rest of the set.
        }
      }
      if (seeded.isEmpty) return;

      await metaFile.writeAsString(
        jsonEncode(seeded.map((s) => s.toJson()).toList()),
      );
      await ProAccessService.markFreeSlotsUsed(seeded.length);
      await prefs.setBool(_seededKey, true);
    } catch (_) {
      // A failed seed is a thin first impression, never a crash.
    }
  }

  /// Grants one unlock batch: five shipped cutouts, appended to the
  /// store. Called from onboarding — each answered question unlocks a
  /// batch, six batches cover all 30 shipped outfits. Each batch is a
  /// one-shot (tracked in prefs), and every write is read-modify-write
  /// against the live store so nothing clobbers a sticker saved in
  /// between.
  static Future<void> grantBatch(int batch) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'preset_batch_${batch.clamp(0, 5)}_granted';
    if (prefs.getBool(key) ?? false) return;

    final start = (batch.clamp(0, 5)) * 5;
    final slice = assets.skip(start).take(5).toList();
    final dir = await getApplicationDocumentsDirectory();
    final metaFile = File('${dir.path}/stickers.json');
    final list = metaFile.existsSync()
        ? (jsonDecode(await metaFile.readAsString()) as List)
            .cast<Map<String, dynamic>>()
            .map(OutfitSticker.fromJson)
            .toList()
        : <OutfitSticker>[];

    final granted = <OutfitSticker>[];
    for (var i = 0; i < slice.length; i++) {
      // Same id scheme as the splash seed: anything already in the store
      // (seeded or previously unlocked) is skipped, so the six batches
      // top the wardrobe up to exactly the shipped 30.
      final id = 'fit_${slice[i].split('/').last.replaceAll('.webp', '')}';
      if (list.any((s) => s.id == id)) continue;
      try {
        final bytes = await rootBundle.load(slice[i]);
        final file = File('${dir.path}/$id.webp');
        await file.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
        final style = await StickerStyleService.analyze(file.path);
        granted.add(OutfitSticker(
          id: id,
          imagePath: file.path,
          // Newest first on landing: each batch arrives on top of the
          // stack, in its own shipped order.
          createdAt: DateTime.now().add(Duration(seconds: i)),
          haloStripped: false,
          shapeIndex: style.shapeIndex,
          dominantColor: style.dominantColor,
        ));
      } catch (_) {
        // One unreadable asset never blocks the batch.
      }
    }
    if (granted.isEmpty) {
      await prefs.setBool(key, true);
      return;
    }
    list.addAll(granted);
    await metaFile.writeAsString(
      jsonEncode(list.map((s) => s.toJson()).toList()),
    );
    await ProAccessService.markFreeSlotsUsed(granted.length);
    await prefs.setBool(key, true);
  }
}
