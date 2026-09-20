import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:share_plus/share_plus.dart';

import '../motion/app_haptics.dart';
import '../services/growth_service.dart';
import '../services/notification_service.dart';

/// One rotating post-save action, ramadan delight-sheet style: a store
/// review ask, an app share, a widget nudge, or a reminders opt-in.
/// Prompt policy (throttle, rotation, snooze, review stop) lives in
/// [GrowthService]; this sheet only renders one action.
enum GrowthAction { review, share, widgets, reminders }

const playStoreUrl =
    'https://play.google.com/store/apps/details?id=com.taucity.stickerpants';

Future<void> showGrowthPromptSheet(
  BuildContext context,
  GrowthAction action,
) async {
  // Reminders action never renders when already granted — no mute UI.
  if (action == GrowthAction.reminders) {
    try {
      if (await NotificationService.areEnabled()) return;
    } catch (_) {}
  }
  if (!context.mounted) return;
  HapticFeedback.lightImpact();
  await showModalBottomSheet(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _GrowthGlass(
      child: _GrowthSheet(action: action),
    ),
  );
}

/// Frosted-glass sheet body — the app's glass language (same recipe as
/// the bottom sheet/detail screen): σ20 blur, 5% white tint, hairline.
class _GrowthGlass extends StatelessWidget {
  final Widget child;
  const _GrowthGlass({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.09),
            ),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _GrowthSheet extends StatefulWidget {
  final GrowthAction action;
  const _GrowthSheet({required this.action});

  @override
  State<_GrowthSheet> createState() => _GrowthSheetState();
}

/// Carousel order: review first (the sheet's headline act), then
/// share, widgets, reminders. The triggering action is the landing
/// page; users can swipe through every suggestion from one sheet.
const _carouselOrder = [
  GrowthAction.review,
  GrowthAction.share,
  GrowthAction.widgets,
  GrowthAction.reminders,
];

class _GrowthSheetState extends State<_GrowthSheet> {
  late final PageController _pages;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = _carouselOrder
        .indexOf(widget.action)
        .clamp(0, _carouselOrder.length - 1);
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 380,
              child: PageView.builder(
                controller: _pages,
                itemCount: _carouselOrder.length,
                onPageChanged: (i) {
                  AppHaptics.step();
                  setState(() => _index = i);
                },
                itemBuilder: (context, i) =>
                    _GrowthCard(action: _carouselOrder[i]),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < _carouselOrder.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _index
                          ? const Color(0xFFFFD60A)
                          : Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: const Text(
                'Maybe later',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await GrowthService.snooze(days: 7);
                if (context.mounted) Navigator.of(context).pop();
              },
              child: Text(
                "Don't remind me for 7 days",
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One suggestion card in the carousel. Owns its review-gate state so
/// each card behaves identically whether landed on or swiped to.
class _GrowthCard extends StatefulWidget {
  final GrowthAction action;
  const _GrowthCard({required this.action});

  @override
  State<_GrowthCard> createState() => _GrowthCardState();
}

class _GrowthCardState extends State<_GrowthCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// Review flow: "Enjoying StickerPants?" gate first — Play never
  /// reports the rating back, so the inline star picker is the only way
  /// to learn it. 4-5 stars fires the store flow + stops prompts for
  /// good; 1-3 suppresses for 30 days; No dismisses.
  bool _askingEnjoy = false;
  bool _askingStars = false;
  bool _busy = false;

  bool get _isReview => widget.action == GrowthAction.review;
  bool get _isReminders => widget.action == GrowthAction.reminders;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
            Text(
              _isReview
                  ? 'Loving StickerPants?'
                  : _isReminders
                      ? 'Never miss a fit?'
                      : widget.action == GrowthAction.widgets
                          ? 'Stickers on your homescreen'
                          : 'Share the fits',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _isReview
                  ? (_askingStars
                      ? 'Tap the stars to rate your experience.'
                      : _askingEnjoy
                          ? 'Are you enjoying StickerPants?'
                          : 'A quick rating helps more fits find their pants.')
                  : _isReminders
                      ? 'Daily nudges so the fit log never skips a day.'
                      : widget.action == GrowthAction.widgets
                          ? 'Pin your latest stickers right to your home.'
                          : 'Friends with fits need this app.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.65),
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (_isReview && _askingStars)
              _StarPicker(enabled: !_busy, onRated: _onStarsRated)
            else if (_isReview && _askingEnjoy) ...[
              _PrimaryButton(
                label: 'Yes, I love it! 😍',
                color: const Color(0xFFFFD60A),
                foreground: Colors.black,
                onPressed: _busy
                    ? null
                    : () {
                        AppHaptics.tap();
                        setState(() {
                          _askingEnjoy = false;
                          _askingStars = true;
                        });
                      },
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        await GrowthService.recordLowRating();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                child: Text(
                  'Not really',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ] else
              _PrimaryButton(
                label: _isReview
                    ? 'Leave a Review'
                    : _isReminders
                        ? 'Enable reminders'
                        : widget.action == GrowthAction.widgets
                            ? 'Add widgets'
                            : 'Share with a friend',
                color: _isReview
                    ? const Color(0xFFFFD60A)
                    : _isReminders
                        ? const Color(0xFFFFC107)
                        : widget.action == GrowthAction.widgets
                            ? const Color(0xFF30D158)
                            : const Color(0xFF0A84FF),
                foreground:
                    widget.action == GrowthAction.review ? Colors.black : null,
                icon: _isReview
                    ? Icons.star_rounded
                    : _isReminders
                        ? Icons.notifications_active_rounded
                        : widget.action == GrowthAction.widgets
                            ? Icons.widgets_rounded
                            : Icons.share_rounded,
                onPressed:
                    _busy ? null : () async {
                      AppHaptics.tap();
                      if (_isReview) {
                        setState(() => _askingEnjoy = true);
                      } else if (_isReminders) {
                        await _doReminders(context);
                      } else if (widget.action == GrowthAction.widgets) {
                        await _doWidgets(context);
                      } else {
                        await _doShare(context);
                      }
                    },
              ),
            const SizedBox(height: 8),
            // Dismiss + snooze live once at sheet level, below the dots.
            Text(
              'Swipe for more ways to support StickerPants',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ],
        );
  }

  Future<void> _onStarsRated(int stars) async {
    if (_busy) return;
    setState(() => _busy = true);
    if (stars >= 4) {
      await GrowthService.recordHighRating();
      try {
        final review = InAppReview.instance;
        if (await review.isAvailable()) await review.requestReview();
      } catch (_) {}
    } else {
      // 1-3 stars: keep it in-house, suppress review prompts 30 days.
      await GrowthService.recordLowRating();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Thanks for the honesty — we'll keep improving."),
          ),
        );
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _doReminders(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final granted = await NotificationService.requestPermissions();
      if (!context.mounted) return;
      if (granted) {
        await NotificationService.scheduleDaily();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reminders on!')),
        );
        Navigator.of(context).pop();
      } else {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Turn on reminders in Settings'),
            action: SnackBarAction(
              label: 'SETTINGS',
              onPressed: () => NotificationService.openSettings(),
            ),
          ),
        );
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doWidgets(BuildContext context) async {
    try {
      await GrowthService.pinWidgets();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(this.context).pop();
  }

  Future<void> _doShare(BuildContext context) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: 'StickerPants — turn your outfits into WhatsApp stickers! '
              'Cut, flick, stick. \u{1F9F3}\u{2728}\n$playStoreUrl',
          title: 'StickerPants',
        ),
      );
      await GrowthService.recordShare();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(this.context).pop();
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color? foreground;
  final IconData? icon;
  final VoidCallback? onPressed;

  const _PrimaryButton({
    required this.label,
    required this.color,
    required this.onPressed,
    this.foreground,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? Colors.white;
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) Icon(icon, color: fg, size: 22),
            if (icon != null) const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StarPicker extends StatelessWidget {
  final bool enabled;
  final ValueChanged<int> onRated;
  const _StarPicker({required this.enabled, required this.onRated});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 1; i <= 5; i++)
          IconButton(
            onPressed: enabled ? () => onRated(i) : null,
            icon: const Icon(Icons.star_rounded),
            color: const Color(0xFFFFD60A),
            iconSize: 44,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            constraints: const BoxConstraints(),
          ),
      ],
    );
  }
}
