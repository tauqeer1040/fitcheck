import 'dart:convert';

import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/outfit_sticker.dart';
import 'revenuecat_service.dart';
import 'roast_service.dart';
import 'sticker_style_service.dart';
import 'whatsapp_sticker_service.dart';

/// Keeps the homescreen widgets fed. Kotlin providers read saved paths,
/// shapes, and colors from HomeWidget's SharedPreferences and render:
/// cutout art over a tinted silhouette on transparency — no container.
/// 2x5 = three recent side by side; 2x3 = single sticker, both floating
/// over a silhouette that spins on a flip-book.
///
/// **The clock is native, not Dart.** Dart publishes a *pool* — every
/// sticker, newest first, with every roast line this tier can serve —
/// plus an epoch; `WidgetRotation.kt` picks the slot from the wall clock
/// on every tick, so the widgets turn over with or without the app
/// running:
///
/// - image advances every 4h, so a fresh save lands the new sticker
///   immediately and holds it for four hours,
/// - caption advances every 2h, always a roast of the sticker
///   currently on screen, walking the whole line pool so nothing
///   repeats until it has cycled through,
/// - the epoch is re-stamped only when the pool itself changes, so a
///   wordmark colour toggle never reshuffles the rotation.
///
/// The pool is one JSON blob rather than five keys per sticker: Pro
/// accounts are uncapped, and 300 round trips per publish would show up
/// as a stall after every save. Ticks come from `updatePeriodMillis`
/// (30 min, Android's floor); the providers skip the re-render when the
/// slot they would draw is already on screen, so a day costs six real
/// updates.
class WidgetService {
  static const appGroup = 'stickerpants_widgets';

  /// Key of the pool blob. Native reads the same key.
  static const poolKey = 'widget_pool';

  /// Caption variants per pool entry: one per line this tier can
  /// serve, so the widget works through the entire library.
  ///
  /// The caption turns over every 2h while an image slot holds 4h, so a
  /// sticker shows two different lines per slot and comes back to the
  /// next two on its next turn — no line repeats until the whole pool
  /// has cycled. Shipping the full pool per sticker is what lets the
  /// rotation advance with the app closed; native just indexes this
  /// list (floorMod over the blob's `variants`). Text is composed here,
  /// never in Kotlin.
  static int captionVariants({required bool isMax}) =>
      RoastService.poolSize(isMax: isMax);

  /// Publishes the rotation pool for every sticker and refreshes both
  /// providers.
  ///
  /// The blob is rewritten only when its *signature* changes (sticker
  /// ids + Max membership), which is also what re-stamps the epoch —
  /// that is how a fresh save shows up instantly. A no-op pool
  /// (wordmark colour toggles, app resume) leaves the rotation exactly
  /// where it is; the 4h clock is native's job.
  ///
  /// [bgColor] is the live wordmark shadow color (0xAARRGGBB, same int
  /// layout Android uses). Null leaves the last pushed color alone.
  static Future<void> updateAll({int? bgColor}) async {
    try {
      final List<OutfitSticker> stickers =
          await WhatsAppStickerService.loadStickers();
      await _pushPool(stickers);
      await _pushTextPrefs();
      if (bgColor != null) {
        await HomeWidget.saveWidgetData('bg_color', bgColor);
      }
      await _pokeProviders();
    } catch (_) {
      // Never let widget upkeep break the main flow.
    }
  }

  /// Writes the whole pool as one blob, newest sticker first (the order
  /// [WhatsAppStickerService.loadStickers] returns, so slot 0 is the
  /// newest). Skipped when the published signature already matches —
  /// one read instead of a rewrite on every app resume.
  static Future<void> _pushPool(List<OutfitSticker> stickers) async {
    try {
      final isMax = RevenueCatService.instance.isPro;
      final signature = '$isMax:${stickers.map((s) => s.id).join('|')}';
      final published = await publishedSignature();
      if (published == signature) return;
      final variants = captionVariants(isMax: isMax);
      await HomeWidget.saveWidgetData(
        poolKey,
        jsonEncode({
          'v': 1,
          'sig': signature,
          'epochMs': DateTime.now().millisecondsSinceEpoch,
          'variants': variants,
          'cells': [
            for (final OutfitSticker s in stickers)
              {
                'p': s.imagePath,
                'c': s.dominantColor ?? kFallbackStickerColor,
                // The sticker's OWN homescreen shape index
                // (kStyleShapes): native resolves it to the matching
                // silhouette so the widget mirrors the grid cell.
                // -1 = legacy hash fallback.
                's': shapeIndexForTier(
                  s.shapeIndex ?? fallbackShapeIndex(s.id),
                ),
                't': [
                  for (int v = 0; v < variants; v++)
                    widgetCaptionForId(s.id, variant: v, isMax: isMax),
                ],
              },
          ],
        }),
      );
    } catch (_) {}
  }

  /// The signature of the pool currently on the homescreen, or null
  /// when none has been published. Read back from the blob itself so
  /// the two can't drift: home_widget's prefs are the only state the
  /// widgets actually see.
  static Future<String?> publishedSignature() async {
    try {
      final raw = await HomeWidget.getWidgetData<String>(poolKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final sig = decoded['sig'];
      return sig is String ? sig : null;
    } catch (_) {
      return null;
    }
  }

  /// The [variant]th widget caption for the sticker with [id] — one
  /// line per library entry, so the widget cycles through all of them.
  ///
  /// Starts at a per-sticker offset taken from the id hash (stable
  /// across opens, and different stickers start on different lines) and
  /// then walks the pool sequentially, which guarantees variant v and
  /// v+1 never repeat until the whole pool has cycled through.
  ///
  /// Deliberately not [RoastService.roastForId]'s salted XOR: two
  /// different salts land on the same line modulo the pool size often
  /// enough to put the same caption on screen twice in a row, which is
  /// exactly the repetition this replaced.
  static String widgetCaptionForId(
    String id, {
    required int variant,
    required bool isMax,
  }) {
    final total = RoastService.poolSize(isMax: isMax);
    final base = id.hashCode.abs() % total;
    return RoastService.lineAt(base + variant, isMax: isMax);
  }

  /// Caption text size, which both widgets honor. Saved as a string:
  /// doubles cross the method channel as raw Long bits, which native
  /// toFloat() turns into garbage magnitudes (crashed widget inflation)
  /// — the native side parses strings safely.
  ///
  /// The variant *count* does not live here: it ships inside the pool
  /// blob, so there is one source of truth for it.
  static Future<void> _pushTextPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Key bumped to _v2. The old key holds whatever the (now removed)
      // debug slider last wrote — this device had 12.0 in there — and that
      // stale value would pin the caption to the old size forever, making
      // the new default invisible.
      final sp = (prefs.getDouble('funny_text_sp_v2') ?? 17.0)
          .clamp(8.0, 24.0);
      await HomeWidget.saveWidgetData(
        'funny_text_sp',
        sp.toStringAsFixed(1),
      );
    } catch (_) {}
  }

  static Future<void> _pokeProviders() async {
    await HomeWidget.updateWidget(
      androidName: 'RecentStickersWidgetProvider',
      name: 'RecentStickersWidgetProvider',
    );
    await HomeWidget.updateWidget(
      androidName: 'LatestStickerWidgetProvider',
      name: 'LatestStickerWidgetProvider',
    );
  }
}