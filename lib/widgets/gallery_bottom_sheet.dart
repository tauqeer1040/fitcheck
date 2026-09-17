import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';

/// Persistent frosted-glass bottom sheet, resizable by dragging the handle:
/// collapsed = single row of the most recent photos (no scrolling needed),
/// expanded = multi-row grid of recent photos, scrolling vertically.
/// If media permission is missing, the content is a button that triggers
/// the OS permission popup. Tapping a photo picks exactly that one image.
class GalleryBottomSheet extends StatefulWidget {
  final ValueChanged<AssetEntity> onPick;

  /// Peek height of the collapsed sheet (content + handle, excl. safe
  /// area). The homescreen grid pads its bottom by this so the last row
  /// never hides underneath.
  static const double peekHeight = 150;

  const GalleryBottomSheet({super.key, required this.onPick});

  @override
  State<GalleryBottomSheet> createState() => GalleryBottomSheetState();
}

class GalleryBottomSheetState extends State<GalleryBottomSheet> {
  static const double _collapsedHeight =
      GalleryBottomSheet.peekHeight;
  static const int _collapsedCount = 4;

  bool _checked = false;
  bool _hasPermission = false;
  bool _askedOnce = false;
  bool _dragging = false;
  double _height = _collapsedHeight;
  List<AssetEntity> _recent = [];
  final _focusNode = FocusNode();

  /// Collapse back to the single-row peek height.
  /// Called on tap-away / focus loss from the sheet or its parent.
  void collapse() {
    if (!mounted) return;
    if (_height != _collapsedHeight) {
      setState(() => _height = _collapsedHeight);
    }
    if (_focusNode.hasFocus) _focusNode.unfocus();
  }

  /// Whether the sheet is currently expanded past its peek height.
  bool get isExpanded => _isExpanded;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _load();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    // Dismiss (collapse) when the sheet loses focus.
    if (!_focusNode.hasFocus && _isExpanded && mounted) {
      setState(() => _height = _collapsedHeight);
    }
  }

  Future<void> _load() async {
    final permission = await PhotoManager.requestPermissionExtend();
    final granted = permission.hasAccess;

    List<AssetEntity> recent = [];
    if (granted) {
      // Newest-first ordering, from the synthetic "All photos" album so we
      // cover every gallery folder — not one random directory.
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          // asc defaults to false → descending → newest first.
          orders: const [OrderOption(type: OrderOptionType.createDate)],
        ),
      );
      if (albums.isNotEmpty) {
        final all = albums.firstWhere(
          (a) => a.isAll,
          orElse: () => albums.first,
        );
        recent = await all.getAssetListRange(start: 0, end: 120);
      }
    }

    if (mounted) {
      setState(() {
        _checked = true;
        _hasPermission = granted;
        _recent = recent;
      });
    }
  }

  /// First tap triggers the OS permission popup. If access is still denied
  /// after a request attempt (OS can no longer show the popup), fall back
  /// to an explanatory dialog that offers the app settings page.
  Future<void> _requestAccess() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess && _askedOnce) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: const Text('Photo access needed'),
          content: const Text(
            'FitCheck needs access to your photos to create outfit '
            'stickers. Enable it in Settings to continue.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (go == true) await PhotoManager.openSetting();
    }
    _askedOnce = true;
    if (mounted) _load();
  }

  double get _maxHeight => MediaQuery.of(context).size.height * 0.6;

  bool get _isExpanded => _height > _collapsedHeight + 40;

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() {
      _height = (_height - d.delta.dy).clamp(_collapsedHeight, _maxHeight);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final wasExpanded = _isExpanded;
    final fling = details.velocity.pixelsPerSecond.dy;
    setState(() {
      _dragging = false;
      if (fling < -400) {
        // Flicked up (even slightly): extend fully to the limit.
        _height = _maxHeight;
      } else if (fling > 400) {
        // Flicked down: shut.
        _height = _collapsedHeight;
      } else {
        // Gentle release: biased threshold so small upward drags open.
        final range = _maxHeight - _collapsedHeight;
        _height = _height > _collapsedHeight + range / 3
            ? _maxHeight
            : _collapsedHeight;
      }
    });
    // Snap feedback for the resize detent.
    if (wasExpanded != _isExpanded) AppHaptics.step();
    // Grab focus when expanded so a later focus loss can dismiss us.
    if (_isExpanded && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
    } else if (!_isExpanded && _focusNode.hasFocus) {
      _focusNode.unfocus();
    }
  }

  Widget _thumb(AssetEntity asset) {
    return GestureDetector(
      onTap: () {
        AppHaptics.tap();
        widget.onPick(asset);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AssetEntityImage(
          asset,
          isOriginal: false,
          thumbnailSize: const ThumbnailSize(256, 256),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(color: Colors.grey.shade800),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (!_checked) {
      return SizedBox(
        height: _collapsedHeight,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!_hasPermission) {
      return Container(
        height: _collapsedHeight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        child: FilledButton.icon(
          onPressed: _requestAccess,
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Allow photo access'),
        ),
      );
    }
    if (_recent.isEmpty) {
      return SizedBox(
        height: _collapsedHeight,
        child: const Center(child: Text('No photos found')),
      );
    }

    if (_isExpanded) {
      return SizedBox(
        height: _height - 28,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 16, bottom: 6),
              child: Text(
                'Recents',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                itemCount: _recent.length,
                itemBuilder: (context, index) => _thumb(_recent[index]),
              ),
            ),
          ],
        ),
      );
    }

    // Collapsed: one fixed row of the newest photos, sized to fill the
    // width — no horizontal scrolling.
    final count = _recent.length < _collapsedCount
        ? _recent.length
        : _collapsedCount;
    return SizedBox(
      height: _collapsedHeight - 28,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gaps = count - 1;
          const sidePad = 8.0;
          const gap = 6.0;
          final itemSize =
              (constraints.maxWidth - sidePad * 2 - gap * gaps) /
                  _collapsedCount;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: sidePad),
            child: Row(
              children: [
                for (var i = 0; i < count; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  SizedBox(
                    width: itemSize,
                    height: itemSize,
                    child: _thumb(_recent[i]),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    // Frosted glass sheet with curved top corners. TapRegion collapses
    // (dismisses) the sheet when the user taps anywhere outside it, and
    // the Focus listener collapses it on focus loss.
    return TapRegion(
      onTapOutside: (_) {
        if (_isExpanded) collapse();
      },
      child: Focus(
        focusNode: _focusNode,
        onFocusChange: (hasFocus) {
          if (!hasFocus && _isExpanded) collapse();
        },
        child: ClipRRect(
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(30)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 56, sigmaY: 56),
            child: AnimatedContainer(
              duration:
                  _dragging ? Duration.zero : const Duration(milliseconds: 140),
              curve: AppMotion.appleEase,
              height: _checked && _hasPermission && _recent.isNotEmpty
                  ? _height + bottomPadding
                  : _collapsedHeight + bottomPadding,
              decoration: BoxDecoration(
                // Frosted glass x2: heavy blur, bright cut edge, deep lift.
                color: const Color(0xFF3A3A3C).withValues(alpha: 0.5),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(30),
                ),
                border: Border(
                  top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.4)),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 48,
                    offset: const Offset(0, -12),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Drag handle to resize: up = expand to grid, down = collapse.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      // Tapping the handle grabs focus so tap-away works.
                      if (!_focusNode.hasFocus) _focusNode.requestFocus();
                    },
                    onVerticalDragStart: (_) =>
                        setState(() => _dragging = true),
                    onVerticalDragUpdate: _onDragUpdate,
                    onVerticalDragEnd: _onDragEnd,
                    child: SizedBox(
                      height: 28,
                      width: double.infinity,
                      child: Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: _buildContent()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
