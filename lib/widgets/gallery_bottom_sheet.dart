import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_m3shapes/flutter_m3shapes.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../screens/photo_preview_screen.dart';
import '../services/sticker_style_service.dart';
import 'genie_flight.dart';

/// Pick data minted by the gallery before the container opens: the
/// open builder needs everything synchronously when the flight starts.
typedef PreviewSavedCallback = void Function(
    String path, StickerStyle style);

class GalleryPickData {
  final String assetId;
  final String imagePath;
  final String heroTag;
  final int shapeIndex;
  final PreviewSavedCallback onSaved;

  const GalleryPickData({
    required this.assetId,
    required this.imagePath,
    required this.heroTag,
    required this.shapeIndex,
    required this.onSaved,
  });
}

/// Persistent frosted-glass bottom sheet, resizable by dragging the handle:
/// collapsed = single row of the most recent photos (no scrolling needed),
/// expanded = multi-row grid of recent photos, scrolling vertically.
/// If media permission is missing, the content is a button that triggers
/// the OS permission popup. Tapping a photo picks exactly that one image.
class GalleryBottomSheet extends StatefulWidget {
  final ValueChanged<AssetEntity> onPick;

  /// Thumbnail style: M3 expressive shapes (rolled per photo) vs plain
  /// rounded squares (debug toggle).
  final bool m3Thumbs;

  /// Peek height of the collapsed sheet (content + handle, excl. safe
  /// area). The homescreen grid pads its bottom by this so the last row
  /// never hides underneath.
  static const double peekHeight = 150;

  const GalleryBottomSheet({
    super.key,
    required this.onPick,
    this.m3Thumbs = false,
  });

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

  /// True once first frame has painted. The glass (backdrop filter) is
  /// gated on this so startup never blocks on the expensive blur — the
  /// same trick the meowstian journal sheet uses.
  bool _blurReady = false;
  double _height = _collapsedHeight;
  List<AssetEntity> _recent = [];
  final _focusNode = FocusNode();

  /// Called by the gallery with fully-prepped pick data: pushes the
  /// preview on [zoomPageRoute], the same non-opaque page route the
  /// fullscreen sticker view uses.
  ///
  /// It has to be non-opaque. The preview frosts the LIVE GRID behind it,
  /// and this used to open through the sheet's OpenContainer, whose route
  /// hard-codes `opaque => true` (animations 2.1.2, open_container.dart)
  /// — so the grid was never composited underneath, the BackdropFilter
  /// had nothing to blur, and the glass rendered as flat black.
  /// Dropping the container transform also removes the pixel hack that
  /// hid the closed thumbnail for the forward flight and restored it on a
  /// 400ms timer, which was a visible pop between the two.
  void openPreview(GalleryPickData data) {
    if (!mounted) return;
    Navigator.of(context).push(
      geniePageRoute(
        // Fade-only, exactly like the fullscreen sticker: the Hero does
        // all the moving, so a page-level zoom would fight it. The open
        // gets a longer run than the fullscreen's 160ms — that is the
        // app-launch beat, and 160ms read as a cut.
        open: const Duration(milliseconds: 380),
        page: PhotoPreviewScreen(
          imagePath: data.imagePath,
          heroTag: data.heroTag,
          initialShapeIndex: data.shapeIndex,
          onSaved: data.onSaved,
          // Hero tag shared with the tapped thumbnail: the thumbnail's
          // pixels fly into the preview's photo slot.
          pickHeroTag: pickHeroTagFor(data.assetId),
          // Full flow: subject cut out on open, cutout pops in and
          // auto-saves into the grid.
          autoCutout: true,
        ),
      ),
    );
  }

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
    // Flip to the real glass one frame after first paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _blurReady = true);
    });
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
    // Photo permission is asked back-to-back after notifications during
    // onboarding; here we just (re-)request. The OS shows its popup on
    // first ask; on later denials _requestAccess explains + deep-links
    // to Settings instead.
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      ),
    );
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

  /// First tap triggers the OS permission popup. Permission explanation
  /// dialog + settings fallback when access is still denied afterwards
  /// (OS can no longer show the popup): covers rationale-on-denial.
  Future<void> _requestAccess() async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      ),
    );
    if (!permission.hasAccess && _askedOnce) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: const Text('Photo access needed'),
          content: const Text(
            'StickerPants needs access to your photos to create outfit '
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

  /// Photo thumbnail: M3 expressive clip (the photo's stable random
  /// shape — the same shape the sticker gets) or a plain rounded
  /// square, per the debug toggle. Plain tap target: the gallery does
  /// async prep (gate, byte copy, cache warm) before pushing the
  /// preview, so there is no closed container to transform out of.
  /// Hero tag pairing a gallery thumbnail with the preview it opens.
  /// Derived from the asset id so the thumbnail can carry it before the
  /// tap — the shell the pick data arrives in is minted afterwards.
  static String pickHeroTagFor(String assetId) => 'pick-$assetId';

  Widget _thumb(AssetEntity asset, int index, {required double size}) {
    final art = AssetEntityImage(
      asset,
      isOriginal: false,
      thumbnailSize: const ThumbnailSize(256, 256),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(color: Colors.grey.shade800),
    );
    final Widget shaped = widget.m3Thumbs
        ? M3Container(
            kStyleShapes[randomShapeIndexForAsset(asset.id)],
            width: size,
            height: size,
            child: art,
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(width: size, height: size, child: art),
          );
    // Hero source: the thumbnail's rect flies into the preview's photo
    // slot while the route fades in, so the pick reads as an app opening
    // instead of a cut. Pressable adds the instant press-scale on top:
    // the gallery does async prep (permission gate, byte copy, cache
    // warm) before it can push, and without feedback the grid looked
    // frozen for that beat.
    return Pressable(
      onTap: () => widget.onPick(asset),
      child: Hero(
        tag: pickHeroTagFor(asset.id),
        createRectTween: stickerFlightTween,
        child: shaped,
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Cell size must match the grid delegate below:
                  // 8px padding per side, 3 gaps of 6px, 4 columns.
                  final tileSize =
                      (constraints.maxWidth - 16 - 6 * 3) / 4;
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                    ),
                    itemCount: _recent.length,
                    itemBuilder: (context, index) =>
                        _thumb(_recent[index], index, size: tileSize),
                  );
                },
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
                    child: _thumb(_recent[i], i, size: itemSize),
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

    // Frosted glass sheet (meowstian method): the blur does the work —
    // sigma 16 plus only a whisper of tint (8% black) and a top hairline.
    // TapRegion/Focus below dismiss on tap-away/focus loss.
    final sheetContent = AnimatedContainer(
      duration:
          _dragging ? Duration.zero : const Duration(milliseconds: 140),
      curve: AppMotion.appleEase,
      height: _checked && _hasPermission && _recent.isNotEmpty
          ? _height + bottomPadding
          : _collapsedHeight + bottomPadding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.08),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
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
    );

    // meowstian frost: solid card for the first frame, then ClipRRect >
    // ClipRect > BackdropFilter(blur 16). ClipRect keeps the filter from
    // bleeding outside the clip bounds.
    final Widget sheet = !_blurReady
        ? Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(30)),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
              ),
            ),
            child: sheetContent,
          )
        : ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(30)),
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: sheetContent,
              ),
            ),
          );

    return TapRegion(
      onTapOutside: (_) {
        if (_isExpanded) collapse();
      },
      child: Focus(
        focusNode: _focusNode,
        onFocusChange: (hasFocus) {
          if (!hasFocus && _isExpanded) collapse();
        },
        child: sheet,
      ),
    );
  }
}
