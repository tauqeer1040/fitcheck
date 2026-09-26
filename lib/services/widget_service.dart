import 'dart:io';

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
/// 2x5 = three recent side by side (static silhouettes); 2x3 = single
/// latest sticker over a flip-book silhouette rotating one frame/sec.
///
/// Rotation (no new sticker needed):
/// - stickers rotate once per calendar day: the shown window advances by
///   one slot each day, wrapping around. A fresh save resets to
///   newest-first.
/// - the funny line rotates twice a day on 02:00/14:00 boundaries
///   (02:00–14:00, then 14:00–02:00) via the roast salt.
///
/// Rotation applies whenever Dart runs (boot, resume, save) — see
/// [maybeRotate]. There is no background worker, so a day the app is
/// never opened keeps yesterday's widgets.
class WidgetService {
  static const appGroup = 'stickerpants_widgets';

  static const _rotDayKey = 'widget_rotation_day';
  static const _rotOffsetKey = 'widget_rotation_offset';
  static const _saveDayKey = 'widget_last_save_day';
  static const _funnyHalfKey = 'widget_funny_half_index';

  /// Local calendar day as yyyyMMdd (monotonic, for rotation math).
  static int dayIndexOf(DateTime t) => t.year * 10000 + t.month * 100 + t.day;

  /// Twice-daily periods anchored at 02:00 local: 02:00–14:00 is the
  /// even period, 14:00–02:00 the odd one. Monotonic
  /// (dayIndex * 2 + period), so it doubles as the roast salt.
  static int halfPeriodIndexOf(DateTime now) {
    final twoAm = DateTime(now.year, now.month, now.day, 2);
    final ref = now.isBefore(twoAm)
        ? twoAm.subtract(const Duration(days: 1))
        : twoAm;
    final period = (now.difference(ref).inHours ~/ 12).clamp(0, 1);
    return dayIndexOf(ref) * 2 + period;
  }

  /// Writes the latest sticker paths and refreshes both providers.
  /// loadStickers() returns newest-first (gallery inserts at 0), so a
  /// plain take(3) is the three most recent — no reversing.
  ///
  /// [bgColor] is the live wordmark shadow color (0xAARRGGBB, same int
  /// layout Android uses): the cookie backdrop tints to match. Null
  /// leaves the last pushed color alone.
  ///
  /// [resetRotation] re-anchors the daily window on the newest stickers
  /// (pass true on every save). Otherwise the stored rotation offset is
  /// kept — a wordmark toggle must not reshuffle the widgets.
  ///
  /// Shapes (native clips in WidgetBitmaps): 2x5 cells cycle
  /// clamshell/semicircle, offset by save count so the widget visibly
  /// changes; the 2x3 latest sticker alternates arch/gem per save.
  static Future<void> updateAll({int? bgColor, bool resetRotation = false}) async {
    try {
      final List<OutfitSticker> stickers = await WhatsAppStickerService
          .loadStickers();
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final today = dayIndexOf(now);
      final half = halfPeriodIndexOf(now);
      int offset = 0;
      if (!resetRotation && stickers.isNotEmpty) {
        offset = (prefs.getInt(_rotOffsetKey) ?? 0) % stickers.length;
      }
      if (resetRotation) {
        await prefs.setInt(_rotOffsetKey, 0);
        await prefs.setInt(_rotDayKey, today);
        await prefs.setInt(_saveDayKey, today);
      } else if (!prefs.containsKey(_rotDayKey)) {
        await prefs.setInt(_rotDayKey, today);
      }
      await prefs.setInt(_funnyHalfKey, half);
      await _push(stickers, offset: offset, funnySalt: half, bgColor: bgColor);
    } catch (_) {
      // Never let widget upkeep break the main flow.
    }
  }

  /// Daily/12-hour rotation pass. Call on boot and on resume: advances
  /// the sticker window by one slot when a new calendar day started
  /// without a fresh save, and refreshes the funny line whenever the
  /// 02:00/14:00 period flipped. No-ops when everything is current.
  static Future<void> maybeRotate() async {
    try {
      final List<OutfitSticker> stickers = await WhatsAppStickerService
          .loadStickers();
      if (stickers.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final today = dayIndexOf(now);
      final half = halfPeriodIndexOf(now);
      var offset = (prefs.getInt(_rotOffsetKey) ?? 0) % stickers.length;
      var dirty = false;
      final lastDay = prefs.getInt(_rotDayKey);
      if (lastDay == null) {
        // First run since this shipped: anchor without advancing, so
        // boot never reshuffles what the last save put up.
        await prefs.setInt(_rotDayKey, today);
        await prefs.setInt(_rotOffsetKey, offset);
      } else if (today != lastDay &&
          (prefs.getInt(_saveDayKey) ?? -1) != today) {
        // New day and no fresh save today: rotate the window.
        offset = (offset + 1) % stickers.length;
        await prefs.setInt(_rotOffsetKey, offset);
        await prefs.setInt(_rotDayKey, today);
        dirty = true;
      }
      if (half != (prefs.getInt(_funnyHalfKey) ?? -1)) {
        await prefs.setInt(_funnyHalfKey, half);
        dirty = true;
      }
      if (dirty) {
        await _push(stickers, offset: offset, funnySalt: half);
      }
    } catch (_) {
      // Never let widget upkeep break the main flow.
    }
  }

  /// Writes one rotated window ([offset] into newest-first [stickers],
  /// wrapping) plus the period-salted funny line, then pokes both
  /// providers. sticker_0 is the window head, so the 2x3 latest widget
  /// rotates together with the 2x5 recents.
  static Future<void> _push(
    List<OutfitSticker> stickers, {
    required int offset,
    required int funnySalt,
    int? bgColor,
  }) async {
    final n = stickers.length;
    final recent = <OutfitSticker>[
      for (int i = 0; i < 3 && n > 0; i++) stickers[(offset + i) % n],
    ];
    const quad = ['clamshell', 'semicircle'];
    for (int i = 0; i < 3; i++) {
      final path = i < recent.length ? recent[i].imagePath : '';
      await HomeWidget.saveWidgetData('sticker_$i', path);
      await HomeWidget.saveWidgetData(
        'sticker_${i}_shape',
        quad[(n + i) % quad.length],
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
      n.isEven ? 'arch' : 'gem',
    );
    // Funny line: the window head's roast, salted by the 02:00/14:00
    // period so it turns over twice a day. Empty = hidden.
    await HomeWidget.saveWidgetData(
      'funny_line',
      recent.isNotEmpty
          ? RoastService.roastFor(
              recent.first,
              salt: funnySalt,
              isMax: RevenueCatService.instance.isPro,
            )
          : '',
    );
    // Caption size both widgets honor. Saved as a string: doubles
    // cross the method channel as raw Long bits, which native
    // toFloat() turns into garbage magnitudes (crashed widget
    // inflation) — the native side parses strings safely.
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
  }

  /// Bitmap decode happens natively; this exists for future Dart-side
  /// scaling if providers need pre-rendered tiles.
  static bool fileExists(String path) => File(path).existsSync();
}
