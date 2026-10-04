import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Photos this app has already handled (picked, shot, shared in),
/// copied into app storage so the sheet can show a recents grid with
/// zero media permission. Newest first, capped, pruned.
class RecentPicksService {
  RecentPicksService._();

  static const _prefsKey = 'recent_picks_v1';
  static const _maxCount = 24;

  static List<String> _cache = [];
  static bool _loaded = false;

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/recent_picks');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<List<String>> list() async {
    if (!_loaded) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _cache = prefs.getStringList(_prefsKey) ?? [];
      } catch (_) {
        _cache = [];
      }
      _loaded = true;
    }
    // Drop files that vanished (cache clears, uninstalls).
    final live = <String>[];
    for (final path in _cache) {
      try {
        if (await File(path).exists()) live.add(path);
      } catch (_) {}
    }
    if (live.length != _cache.length) {
      _cache = live;
      _persist();
    }
    return List.unmodifiable(_cache);
  }

  /// Files [sourcePath] into recents (newest first). Fire-and-forget
  /// safe: failures are swallowed, the pick flow never waits on this.
  static Future<void> remember(String sourcePath) async {
    try {
      await list();
      if (_cache.isNotEmpty && _cache.first == sourcePath) return;
      final src = File(sourcePath);
      if (!await src.exists()) return;
      final dir = await _dir();
      final name =
          'recent_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final copy = await src.copy('${dir.path}/$name');
      _cache.removeWhere((p) => p == sourcePath || p == copy.path);
      _cache.insert(0, copy.path);
      // Prune oldest files past the cap.
      while (_cache.length > _maxCount) {
        final dropped = _cache.removeLast();
        try {
          await File(dropped).delete();
        } catch (_) {}
      }
      await _persist();
    } catch (_) {}
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, _cache);
    } catch (_) {}
  }
}
