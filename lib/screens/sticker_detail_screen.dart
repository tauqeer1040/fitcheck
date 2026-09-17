import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/outfit_sticker.dart';
import '../motion/app_haptics.dart';
import '../motion/app_motion.dart';
import '../widgets/genie_flight.dart';

/// Fullscreen sticker view: pure floating sticker on dark, no chrome.
/// Flick it any direction to fly it home into its grid slot (quiet
/// landing); system back does the same as a fallback.
class StickerDetailScreen extends StatelessWidget {
  final OutfitSticker sticker;

  /// Fired the moment the home flight starts (flick or system back), so
  /// the grid can time its landing squash to touchdown.
  final VoidCallback? onFlightHome;

  const StickerDetailScreen({
    super.key,
    required this.sticker,
    this.onFlightHome,
  });

  void _onPanEnd(BuildContext context, DragEndDetails details) {
    if (details.velocity.pixelsPerSecond.distance < 400) return;
    AppHaptics.launch();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final sidePad = MediaQuery.of(context).padding;

    return PopScope(
      // Either exit path plays the same linear flight home; report it so
      // the grid squash lands exactly on touchdown.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) onFlightHome?.call();
      },
      child: Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanEnd: (details) => _onPanEnd(context, details),
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      // Subtle jelly zoom up; the trip home stays linear.
                      child: Hero(
                        tag: 'sticker-${sticker.id}',
                        flightShuttleBuilder: jellyShuttleBuilder,
                        child: Image.file(
                          File(sticker.imagePath),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                          width: size.width * 0.8,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                            width: 200,
                            height: 200,
                            color: Colors.grey.shade800,
                            child: const Icon(Icons.broken_image, size: 64),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Added ${_formatDate(sticker.createdAt)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey.shade500,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: sidePad.bottom + 32,
              child: Center(
                child: AppMotion.entrance(
                  context,
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Flick it home',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
            // Share button: frosted glass, white text, small icon, top-right corner
            Positioned(
              top: sidePad.top + 16,
              right: 16,
              child: AppMotion.entrance(
                context,
                GestureDetector(
                  onTap: () {
                    AppHaptics.tap();
                    Share.shareXFiles([
                      XFile(sticker.imagePath),
                    ], text: 'Check out my sticker from FitCheck!');
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    child: const Icon(
                      Icons.share,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}
