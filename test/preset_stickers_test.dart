import 'dart:convert';
import 'dart:io';

import 'package:fitcheck/services/preset_stickers_service.dart';
import 'package:fitcheck/services/pro_access_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('preset_stickers');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return dir.path;
      return null;
    });
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  List<Map<String, dynamic>> store() {
    final file = File('${dir.path}/stickers.json');
    if (!file.existsSync()) return [];
    return (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
  }

  test('seeds the shipped set into an empty store', () async {
    await PresetStickersService.ensureSeeded();

    final seeded = store();
    expect(seeded, hasLength(15));
    expect(seeded, hasLength(PresetStickersService.assets.length));
    // Every record points at a file that is really on disk, which is what
    // the grid, the widgets and the WhatsApp pack builder all read.
    for (final entry in seeded) {
      expect(File(entry['imagePath'] as String).existsSync(), isTrue);
    }
    // Shipped order survives, old to new.
    expect(
      DateTime.parse(seeded.first['createdAt'] as String)
          .isBefore(DateTime.parse(seeded.last['createdAt'] as String)),
      isTrue,
    );
  });

  test('counts 15 of the 30 free stickers, but none as made', () async {
    await PresetStickersService.ensureSeeded();

    expect(await ProAccessService.freeUsed(), 15);
    expect(await ProAccessService.freeLeft(), 15);
    // The paywall stat is "stickers you made" — presets were not made.
    expect(await ProAccessService.totalMade(), 0);
  });

  test('seeds once: a deleted preset stays deleted', () async {
    await PresetStickersService.ensureSeeded();
    final file = File('${dir.path}/stickers.json');
    file.writeAsStringSync(jsonEncode(store().take(12).toList()));

    await PresetStickersService.ensureSeeded();

    expect(store(), hasLength(12));
    expect(await ProAccessService.freeUsed(), 15);
  });

  test('leaves an existing library untouched', () async {
    File('${dir.path}/stickers.json').writeAsStringSync(jsonEncode([
      {
        'id': 'mine',
        'imagePath': '${dir.path}/fitcheck_1.webp',
        'createdAt': DateTime.now().toIso8601String(),
        'haloStripped': true,
      },
    ]));

    await PresetStickersService.ensureSeeded();

    expect(store(), hasLength(1));
    expect(await ProAccessService.freeUsed(), 0);
  });
}
