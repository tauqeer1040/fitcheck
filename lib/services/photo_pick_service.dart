import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gallery picker implementation under test in the debug Picker Lab.
enum PickerMode {
  /// Classic fullscreen system picker via image_picker
  /// (Photo Picker / PHPicker). Always available.
  system,

  /// Native embedded photo picker (Android 14+ only): the system grid
  /// rendered inline, single tap grants instantly with no Done tap.
  /// Falls back to [system] where unsupported.
  native,
}

/// System pickers only — no broad storage permission.
///
/// Gallery goes through the Android photo picker / iOS PHPicker
/// (both bundled inside image_picker), camera through the system
/// camera intent. Returns the picked file path, or null on cancel.
class PhotoPickService {
  PhotoPickService._();

  static final ImagePicker _picker = ImagePicker();
  static const _channel = MethodChannel('fitcheck/embedded_picker');
  static const _modeKey = 'picker_mode_v1';

  static PickerMode _mode = PickerMode.system;
  static bool _modeLoaded = false;

  /// Debug Lab selection, persisted. Defaults to [PickerMode.system].
  static Future<PickerMode> mode() async {
    if (_modeLoaded) return _mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_modeKey);
      _mode = PickerMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => PickerMode.system,
      );
    } catch (_) {}
    _modeLoaded = true;
    return _mode;
  }

  static Future<void> setMode(PickerMode value) async {
    _mode = value;
    _modeLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, value.name);
    } catch (_) {}
  }

  /// True only on Android 14+ where the Jetpack embedded picker can run.
  /// Never throws: false on iOS, old Android, or channel failure.
  static Future<bool> isEmbeddedAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> pickFromGallery() async {
    try {
      final file = await _picker.pickImage(source: ImageSource.gallery);
      return file?.path;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
