import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../motion/app_haptics.dart';
import '../screens/onboarding_flow.dart';
import '../screens/photo_preview_screen.dart';
import '../services/photo_pick_service.dart';
import 'embedded_picker_sheet.dart';
import 'wordmark_lockup.dart';

/// Whether the debug tools (Picker Lab, "Test onboarding") are live.
///
/// On in debug builds, and in a release build launched with
/// `--dart-define=SP_DEBUG_TOOLS=true` — which is how the lab gets
/// driven on a release-signed APK without ever shipping it to users:
///
/// ```sh
/// flutter build apk --release --dart-define=SP_DEBUG_TOOLS=true
/// ```
///
/// Deliberately separate from [kDebugMode]: that one also opens up
/// logging and PayStore verbosity, which has no business being on in
/// a build you ship. A `--dart-define` is opt-in per build, so a
/// release assembled the normal way stays clean.
const bool kDebugTools =
    kDebugMode || bool.fromEnvironment('SP_DEBUG_TOOLS');

/// Debug-only Picker Lab: A/B the two gallery implementations.
///
/// * System — classic fullscreen picker (image_picker). Ships to prod.
/// * Native — embedded system grid, one tap, no Done (Android 14+).
///
/// Debug builds only: the gallery AppBar bug icon opens this. Never
/// referenced from release UI unless [kDebugTools] was forced on.
///
/// [onStickersChanged] fires after the test onboarding flow pops, so
/// the grid reloads stickers filed while the replay was up (the grid
/// otherwise only loads once at boot and the replay's stickers stay
/// invisible until restart — while the homescreen widgets, which read
/// straight from disk, already show them).
Future<void> showPickerLab(
  BuildContext context, {
  VoidCallback? onStickersChanged,
}) {
  assert(() {
    if (!kDebugTools) {
      throw StateError('Picker Lab needs kDebugTools.');
    }
    return true;
  }());
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => _PickerLabBody(
        scrollController: scrollController,
        onStickersChanged: onStickersChanged,
      ),
    ),
  );
}

class _PickerLabBody extends StatefulWidget {
  final ScrollController scrollController;

  /// See [showPickerLab].
  final VoidCallback? onStickersChanged;

  const _PickerLabBody({
    required this.scrollController,
    this.onStickersChanged,
  });

  @override
  State<_PickerLabBody> createState() => _PickerLabBodyState();
}

class _PickerLabBodyState extends State<_PickerLabBody> {
  PickerMode _mode = PickerMode.system;
  bool? _embeddedAvailable;
  bool _busy = false;
  String? _lastResult;

  /// Preview-screen lab state: the source photo, the two behavior
  /// toggles, and an epoch that forces a fresh screen on toggle change
  /// (its processing pipeline is one-shot per State).
  String? _previewPhoto;
  bool _previewAutoCutout = true;
  bool _previewAutoAdvance = false;
  int _previewEpoch = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mode = await PhotoPickService.mode();
    final available = await PhotoPickService.isEmbeddedAvailable();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _embeddedAvailable = available;
    });
  }

  Future<void> _setMode(PickerMode mode) async {
    AppHaptics.tap();
    await PhotoPickService.setMode(mode);
    if (!mounted) return;
    setState(() => _mode = mode);
  }

  Future<void> _testGallery() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _lastResult = null;
    });
    try {
      final path = await pickGalleryImage(context);
      if (!mounted) return;
      setState(() => _lastResult = path ?? 'cancelled');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks a photo for the inline preview screen. Reuses the Lab's
  /// routing so the same photo picker under test is exercised.
  Future<void> _pickPreviewPhoto() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await PhotoPickService.pickFromGallery();
      if (!mounted || path == null) return;
      setState(() {
        _previewPhoto = path;
        _previewEpoch++;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = kIsWeb
        ? 'web'
        : Platform.isAndroid
            ? 'android'
            : Platform.isIOS
                ? 'ios'
                : Platform.operatingSystem;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Onboarding test drive: relaunches the shipping flow above
          // the sheet; completing pops straight back here.
          SizedBox(
            height: 48,
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const OnboardingFlow(debugPreview: true),
                  ),
                );
                // The replay files stickers while the grid sits stale
                // underneath — reload so they show immediately.
                widget.onStickersChanged?.call();
              },
              icon: const Icon(Icons.rocket_launch_outlined, size: 18),
              label: const Text(
                'Test onboarding',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // The two reveal pages, jumped to directly. debugStartAt
          // lands on the page with its step kept, and 'aura' seeds a
          // real cutout from the newest sticker — so these two open
          // straight onto the screens without replaying the ten
          // questions in front of them.
          SizedBox(
            height: 48,
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const OnboardingFlow(
                      debugPreview: true,
                      debugStartAt: 'aura',
                    ),
                  ),
                );
                widget.onStickersChanged?.call();
              },
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text(
                'Aura reveal',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const OnboardingFlow(
                      debugPreview: true,
                      debugStartAt: 'sauce',
                    ),
                  ),
                );
                widget.onStickersChanged?.call();
              },
              icon: const Icon(Icons.icecream_outlined, size: 18),
              label: const Text(
                'Sauce page',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Picker Lab',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Debug only — which gallery implementation the app uses.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),
          // Implementation toggle.
          SegmentedButton<PickerMode>(
            segments: const [
              ButtonSegment(
                value: PickerMode.system,
                label: Text('System'),
                icon: Icon(Icons.photo_library_outlined, size: 18),
              ),
              ButtonSegment(
                value: PickerMode.native,
                label: Text('Native'),
                icon: Icon(Icons.grid_view_rounded, size: 18),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (set) => _setMode(set.first),
            style: SegmentedButton.styleFrom(
              foregroundColor: Colors.white70,
              selectedForegroundColor: Colors.black,
              selectedBackgroundColor: const Color(0xFFFFD60A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _mode == PickerMode.system
                ? 'Classic fullscreen picker: tap photo, then Add.'
                : 'Embedded grid (Android 14+): one tap picks, no Done. '
                    'Falls back to System where unsupported.',
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),
          // Availability readout.
          _FactRow(
            label: 'Platform',
            value: platform,
          ),
          _FactRow(
            label: 'Embedded available',
            value: _embeddedAvailable == null
                ? 'checking…'
                : _embeddedAvailable!
                    ? 'yes'
                    : 'no (System will be used)',
          ),
          const SizedBox(height: 16),
          // Test drive: gallery only (the product has no camera path).
          SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _testGallery,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                _busy ? 'Opening…' : 'Test gallery pick',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          if (_lastResult != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Last result: $_lastResult',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Both are system UI with no broad storage permission — '
            'either passes the Play photo policy. iOS always uses System.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 24),
          const Divider(color: Color(0x1FFFFFFF), height: 1),
          const SizedBox(height: 20),
          _buildWordmarkLab(),
          const SizedBox(height: 24),
          const Divider(color: Color(0x1FFFFFFF), height: 1),
          const SizedBox(height: 20),
          _buildAppbarLab(),
          const SizedBox(height: 24),
          const Divider(color: Color(0x1FFFFFFF), height: 1),
          const SizedBox(height: 20),
          _buildPreviewLab(context),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Wordmark lockup tuning
  // ---------------------------------------------------------------------------

  Widget _buildWordmarkLab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Wordmark backing shape',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Live sliders. The appbar and placeholder share these values.',
          style: TextStyle(color: Colors.white60, fontSize: 13),
        ),
        const SizedBox(height: 16),
        _LabSlider(
          label: 'Width ratio',
          help: 'Shape width relative to its height. 1.0 = square.',
          value: WordmarkTuning.widthRatio,
          min: 0.4,
          max: 2.4,
        ),
        _LabSlider(
          label: 'Height vs art',
          help: 'Shape height relative to the wordmark art. 1.0 = equal.',
          value: WordmarkTuning.heightScale,
          min: 0.4,
          max: 2.0,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: OutlinedButton(
            onPressed: WordmarkTuning.reset,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              'Reset to 1.0',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Appbar tuning
  // ---------------------------------------------------------------------------

  Widget _buildAppbarLab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Appbar',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Live sliders. Bar, logo and padding in pt.',
          style: TextStyle(color: Colors.white60, fontSize: 13),
        ),
        const SizedBox(height: 16),
        _LabSlider(
          label: 'Bar height',
          help: 'Logo row height. Status inset sits on top.',
          value: AppbarTuning.height,
          min: 40,
          max: 110,
        ),
        _LabSlider(
          label: 'Logo size',
          help: 'Pants logo box side. Grid cells are 71.',
          value: AppbarTuning.logo,
          min: 32,
          max: 110,
        ),
        _LabSlider(
          label: 'Side padding',
          help: 'Left/right inset. Grid gutters are 12.',
          value: AppbarTuning.padding,
          min: 0,
          max: 32,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: OutlinedButton(
            onPressed: AppbarTuning.reset,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              'Reset to 40 / 75 / 12',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Preview screen lab
  // ---------------------------------------------------------------------------

  Widget _buildPreviewLab(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Preview screen',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Renders the real cutout screen inline. Auto-cutout runs ML Kit '
          'and writes a cutout file to app storage.',
          style: TextStyle(color: Colors.white60, fontSize: 13),
        ),
        const SizedBox(height: 16),
        // Source photo: reuse whatever the last pick returned, or the
        // last camera shot, so the lab has something to render.
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pickPreviewPhoto,
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: Text(
                    _previewPhoto == null ? 'Pick photo' : 'Change photo',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Auto-cutout toggle: on = the full ML pipeline (what ships),
        // off = the inert preview state (rotating shape, no ML).
        _LabSwitch(
          label: 'Auto cutout (ML Kit)',
          value: _previewAutoCutout,
          onChanged: (v) => setState(() {
            _previewAutoCutout = v;
            // Force a fresh screen: its processing is one-shot per
            // instance, so toggling must rebuild it.
            _previewEpoch++;
          }),
        ),
        _LabSwitch(
          label: 'Onboarding mode (auto-advance)',
          value: _previewAutoAdvance,
          onChanged: (v) => setState(() {
            _previewAutoAdvance = v;
            _previewEpoch++;
          }),
        ),
        const SizedBox(height: 14),
        if (_previewPhoto == null)
          Container(
            height: 180,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: const Text(
              'Pick a photo to render the preview',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          )
        else
          _buildInlinePreview(_previewPhoto!),
      ],
    );
  }

  /// The real screen, clipped into a phone-shaped box. It's a Scaffold
  /// with Heroes and a ModalRoute read, so it needs a Navigator above
  /// it (the sheet provides one) — but the inline box must clip hard or
  /// the screen paints over the rest of the card.
  Widget _buildInlinePreview(String path) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 460,
        child: Stack(
          children: [
            PhotoPreviewScreen(
              // Epoch in the key rebuilds the state on toggle changes.
              key: ValueKey('preview_$_previewEpoch'),
              imagePath: path,
              heroTag: 'lab-hero-$_previewEpoch',
              initialShapeIndex: 7,
              autoCutout: _previewAutoCutout,
              autoAdvance: _previewAutoAdvance,
            ),
            // Swallow taps that would pop the sheet: the screen's own
            // close button and flick-save call Navigator.pop, which in
            // an inline embed would tear down the lab.
            const Positioned.fill(
              child: IgnorePointer(child: SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Debug slider bound to a live tuning channel.
class _LabSlider extends StatelessWidget {
  final String label;
  final String help;
  final ValueNotifier<double> value;
  final double min;
  final double max;

  const _LabSlider({
    required this.label,
    required this.help,
    required this.value,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: value,
            builder: (context, v, _) => Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const Spacer(),
                Text(
                  v.toStringAsFixed(2),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          Slider(
            value: value.value.clamp(min, max),
            min: min,
            max: max,
            onChanged: (v) => value.value = v,
          ),
          Text(
            help,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Debug toggle row matching the card's dark styling.
class _LabSwitch extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _LabSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  final String label;
  final String value;
  const _FactRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
