# FitCheck — Full App Spec

## Concept

Apple Notes "sticker" feature + outfit diary. User takes/imports a photo of an outfit → Google ML Kit removes the background → the transparent cutout is saved to a grid gallery. Inspired by the iOS feature where you long-press on a photo subject to lift it from the background and paste it into Notes.

---

## Tech Stack

| Layer | Choice |
|---|---|
| Framework | Flutter 3.12+ (Dart SDK ^3.12.0) |
| BG removal | `google_mlkit_subject_segmentation: ^0.0.3` (Android only, Beta) |
| Image picker | `image_picker: ^1.2.2` |
| Local storage | `path_provider` + `dart:io` (filesystem — no DB) |
| Shimmer | `shimmer: ^3.0.0` |
| Unique IDs | `uuid: ^4.5.1` |
| State mgmt | `setState` (sufficient for prototype) |

---

## File Structure

```
lib/
  main.dart                         # Entry point + MaterialApp
  models/
    outfit_sticker.dart             # Sticker data model
  screens/
    gallery_screen.dart             # Main gallery (grid view)
    photo_preview_screen.dart       # Fullscreen photo + cutout animation
    sticker_detail_screen.dart      # View single sticker
  services/
    subject_cutout_service.dart     # ML Kit segmentation wrapper
  widgets/
    outfit_image_picker.dart        # Pick photo (gallery/camera)
    sticker_grid.dart               # Reusable grid component
```

---

## Native Config

### `android/app/build.gradle.kts`

```kotlin
defaultConfig {
    minSdk = 24          // ML Kit requires 24+
    targetSdk = 35
    // compileSdk is set by flutter.compileSdkVersion (35 in Flutter 3.12+)
}
```

### `android/app/src/main/AndroidManifest.xml`

Add inside `<application>`:

```xml
<meta-data
    android:name="com.google.mlkit.vision.DEPENDENCIES"
    android:value="subject_segment" />
```

---

## Data Model — `OutfitSticker`

```dart
class OutfitSticker {
  final String id;           // uuid v4
  final String imagePath;    // local file path to saved cutout PNG
  final DateTime createdAt;
  // Has toJson() / fromJson() for persistence
}
```

---

## Persistence

Saved as `stickers.json` in the app's documents directory. A JSON array of serialized `OutfitSticker` objects. The cutout PNG files are saved alongside as `fitcheck_<timestamp>.png`.

---

## Flow: Pick → Cutout → Animate → Save

```
GalleryScreen                    PhotoPreviewScreen
    │                                    │
    │  tap "+"                           │
    │  show picker (gallery/camera)      │
    │                                    │
    ├── Navigator.push<String> ───────→  │
    │   (imagePath)                      │
    │                                    │  auto-start ML Kit
    │                                    │  show shimmer overlay
    │                                    │
    │                                    │  ML done → spring lift
    │                                    │  (scale 0.8→1.03, fade in)
    │                                    │  user can drag
    │                                    │  2s idle → float away
    │                                    │
    │  ←─── Navigator.pop ───────────────┤
    │   (savedCutoutPath)                │
    │                                    │
    │  create OutfitSticker              │
    │  insert into grid                  │
    │  save stickers.json                │
```

---

## Screen Details

### 1. `GalleryScreen`

**Role:** Main screen. Shows sticker grid, FAB to add new sticker.

**Key behavior:**
- Loads `stickers.json` on init
- FAB → `OutfitImagePicker.pick()` → navigates to `PhotoPreviewScreen` → awaits result path
- New sticker inserted at top of grid, grid auto-scrolls

### 2. `PhotoPreviewScreen`

**Role:** Fullscreen photo with automatic processing and animation.

**State machine:**
```
INIT ──immediately──→ PROCESSING ──ML done──→ LIFTED
                        │                       │
                    shimmer overlay         spring lift
                    "Cutting out…"          scale 1.03x
                                            30% dim bg
                                            idle bob ±3px
                                            shadow
                                            │
                                       drag / 2s idle
                                            │
                                         FLOATING ──→ pop + save
                                        shrink + fade
                                        fly to bottom
```

**States:**

| State | What user sees |
|---|---|
| `processing` | Fullscreen photo + shimmer sweep overlay + "Cutting out subject…" text bottom-center + close button |
| `lifted` | Photo dimmed to 30% black, cutout centered at 1.03x scale with soft shadow, ±3px idle bob, draggable |
| `dragging` | Same as lifted but follows finger, stronger shadow |
| `floating` | Cutout shrinks (1.0→0.3) + fades (1.0→0.0) + flies toward bottom-center, white glow pulse, then `Navigator.pop(cutoutPath)` |

**3 Animation Controllers** (requires `TickerProviderStateMixin`, not `SingleTickerProviderStateMixin`):

| Controller | Role | Duration |
|---|---|---|
| `_liftController` | Spring lift (scale + opacity) | `SpringSimulation(mass:1, stiffness:200, damping:14)`, ~500ms |
| `_bobController` | Idle floating bob | Repeating, 2s period |
| `_floatController` | Float-to-home exit | `easeInCubic`, 700ms |

**Scale calculation:**
```dart
case lifted/dragging:  return 0.8 + 0.23 * _liftController.value;  // settles at 1.03
case floating:         return 1.0 - 0.7 * _floatController.value;  // 1.0 → 0.3
```

**Opacity calculation:**
```dart
case lifted/dragging:  return _liftController.value.clamp(0, 1);
case floating:         return 1.0 - _floatController.value;
```

**Positioning:**
- Cutout centered on screen at rest: `(screenSize - cutoutSize) / 2`
- Plus: `_dragOffset` (during drag) or `_floatOffset` (during float)
- Plus: `_getBobY()` = `sin(bob.value * 2π) * 3px` (idle bob)

**Dark overlay:**
- AnimatedOpacity, 30% black during lifted/dragging, 0% during floating
- `duration: 400ms` for smooth transitions

**Cutout sizing:**
```dart
cutoutDisplayW = _cutoutSize.width.clamp(100.0, screenWidth * 0.55);
cutoutDisplayH = cutoutDisplayW * (original aspect ratio);
```

**Close button:** Top-left, white `Icons.close`, pops without saving.

### 3. `StickerDetailScreen`

Simple fullscreen view of a saved cutout + date label. Receives an `OutfitSticker`.

---

## Widget Details

### `OutfitImagePicker`

Bottom sheet with two options:
- "Choose from Gallery" → `ImageSource.gallery`
- "Take a Photo" → `ImageSource.camera`

Returns the picked file path or `null`. Images capped at 1024×1024.

### `StickerGrid`

- 3-column `GridView.builder` with 8px spacing
- Each cell: `ClipRRect(borderRadius: 12)` wrapped `Image.file` with `BoxFit.cover`
- Empty state: `Icons.checkroom` icon + "No outfit stickers yet" text

---

## ML Kit Service — `SubjectCutoutService`

```dart
class SubjectCutoutService {
  /// Runs subject segmentation on [imagePath], saves the foreground
  /// as a transparent PNG, returns the saved file path.
  Future<String> cutoutAndSave(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    // Configure segmenter: foreground bitmap + per-subject bitmap
    final options = SubjectSegmenterOptions(
      enableForegroundBitmap: true,
      enableForegroundConfidenceMask: false,
      enableMultipleSubjects: SubjectResultOptions(
        enableConfidenceMask: false,
        enableSubjectBitmap: true,
      ),
    );
    final segmenter = SubjectSegmenter(options: options);
    try {
      final result = await segmenter.processImage(inputImage);
      // Try individual subject bitmap first, fall back to full foreground
      Uint8List? bitmap = result.subjects.isNotEmpty
          ? result.subjects.first.bitmap
          : null;
      bitmap ??= result.foregroundBitmap;
      if (bitmap == null) throw Exception('No subject detected');
      // Save to app documents dir
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/fitcheck_${timestamp}.png');
      await file.writeAsBytes(bitmap);
      return file.path;
    } finally {
      segmenter.close();
    }
  }
}
```

**Key points:**
- Android only (Google Beta — iOS not yet supported by Google)
- On-device, ~200ms latency on Pixel 7 Pro
- Model auto-downloaded via Play Services (configured in AndroidManifest)
- Returns transparent-background PNG of the subject only

---

## Animations (iOS-style)

### Lift (spring, ~500ms)
- Trigger: ML Kit completes
- Scale: 0.8 → 1.03 (spring overshoots to ~1.06 for bounce feel)
- Opacity: 0 → 1
- Background dim: fades to 30% black
- Shadow: appears (blur 20, offset 0,8)

### Idle bob (continuous)
- ±3px vertical oscillation at 0.5Hz
- Makes the cutout feel alive, floating above the photo

### Drag
- Cutout follows finger (accumulated offset)
- Shadow intensifies (blur 30)
- Auto-float timer cancels

### Auto-float (2s idle OR drag release, 700ms ease-in-cubic)
- Scale: 1.0 → 0.3
- Opacity: 1.0 → 0.0
- Position: current → bottom-center (offscreen)
- White radial glow pulse fades out
- On complete: `Navigator.pop(cutoutPath)`

---

## Known Issues / Caveats

1. **Android only** — ML Kit Subject Segmentation is in Beta and iOS isn't supported by Google yet
2. **minSdk 24** — devices older than Android 7.0 won't work
3. **Model download** — first run requires downloading the ML model via Play Services (auto-configured in manifest)
4. **Photo Picker** — on Android 12 and below, the system gallery picker may require a confirm step before returning the image. This is system behavior, not controllable from Flutter
