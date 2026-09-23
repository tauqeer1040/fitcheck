import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_m3shapes/flutter_m3shapes.dart';

import '../motion/app_motion.dart';
import '../services/sticker_style_service.dart';

/// A particle sprite: the decoded cutout plus the M3 silhouette it
/// carries and the dominant color that fills that silhouette — the same
/// card-behind-cutout composition the homescreen grid uses.
class Sprite {
  final ui.Image image;

  /// Index into [kStyleShapes].
  final int shapeIndex;

  /// ARGB fill of the silhouette card.
  final int dominantColor;

  const Sprite({
    required this.image,
    required this.shapeIndex,
    required this.dominantColor,
  });
}

/// The app's own cutout stickers as particle art — the exact 30
/// onboarding cutouts shipped in assets/onboarding/. A missing/renamed
/// file fails that image only; the rest of the set still flies.
abstract final class StickerArt {
  /// The shipped cutout particles. Generated from
  /// `ls assets/onboarding` — regenerate when the set changes.
  static const List<String> _assets = [
    'assets/onboarding/fitcheck_1790191962563.webp',
    'assets/onboarding/fitcheck_1790191969091.webp',
    'assets/onboarding/fitcheck_1790191976439.webp',
    'assets/onboarding/fitcheck_1790191987013.webp',
    'assets/onboarding/fitcheck_1790191994862.webp',
    'assets/onboarding/fitcheck_1790192004017.webp',
    'assets/onboarding/fitcheck_1790192013053.webp',
    'assets/onboarding/fitcheck_1790192020518.webp',
    'assets/onboarding/fitcheck_1790192028291.webp',
    'assets/onboarding/fitcheck_1790192037501.webp',
    'assets/onboarding/fitcheck_1790192050078.webp',
    'assets/onboarding/fitcheck_1790192065652.webp',
    'assets/onboarding/fitcheck_1790192075253.webp',
    'assets/onboarding/fitcheck_1790192084620.webp',
    'assets/onboarding/fitcheck_1790192094327.webp',
    'assets/onboarding/fitcheck_1790192103535.webp',
    'assets/onboarding/fitcheck_1790192122095.webp',
    'assets/onboarding/fitcheck_1790192133443.webp',
    'assets/onboarding/fitcheck_1790192156633.webp',
    'assets/onboarding/fitcheck_1790192185183.webp',
    'assets/onboarding/fitcheck_1790192870167.webp',
    'assets/onboarding/fitcheck_1790192877541.webp',
    'assets/onboarding/fitcheck_1790192883678.webp',
    'assets/onboarding/fitcheck_1790192902035.webp',
    'assets/onboarding/fitcheck_1790192910118.webp',
    'assets/onboarding/fitcheck_1790192917726.webp',
    'assets/onboarding/fitcheck_1790192927514.webp',
    'assets/onboarding/fitcheck_1790192941729.webp',
    'assets/onboarding/fitcheck_1790192955405.webp',
    'assets/onboarding/fitcheck_1790193084453.webp',
  ];

  static const _minImages = 4;

  /// Where the flight leaves from, as a fraction of the screen height.
  static const originY = 0.42;

  /// Decoded sprites, memoized.
  static Future<List<Sprite>?>? _spritesFuture;

  /// Warm the decode so the first burst fires with zero visible delay.
  static void warmUp() => loadSprites();

  /// The memoized sprite load. Internal; [StickerFrameField] awaits it.
  static Future<List<Sprite>?> loadSprites() {
    return _spritesFuture ??= () async {
      try {
        final sprites = <Sprite>[];
        for (final key in _assets) {
          try {
            final bytes = await rootBundle.load(key);
            final codec = await ui.instantiateImageCodec(
              bytes.buffer.asUint8List(),
              // Particle-size decode: cheap to store, free to draw.
              targetWidth: 110,
            );
            final frame = await codec.getNextFrame();
            final img = frame.image;
            sprites.add(Sprite(
              image: img,
              dominantColor: await StickerStyleService.dominantColorOf(img),
              shapeIndex: fallbackShapeIndex(key),
            ));
          } catch (_) {
            // One bad asset never kills the whole burst.
          }
        }
        return sprites.length >= _minImages ? sprites : null;
      } catch (_) {
        return null;
      }
    }();
  }
}

/// The sticker frame: wrap a page in it, then call
/// [StickerFrameFieldState.burst] and every cutout in the set flies out
/// from the middle of the screen to its own slot on the border and turns
/// to face inward — a frame of stickers around the page, dead still once
/// it lands. Every one carries its M3 shape card, exactly as it does on
/// the homescreen grid.
///
/// The frame paints behind [child], so the page stays readable. With
/// [draggable] on, a transparent grab layer above [child] lets any
/// sticker be picked up and parked anywhere on screen, and it stays
/// there — so only turn it on where nothing underneath needs the same
/// pixels: the grab layer takes the pointer anywhere a sticker covers.
class StickerFrameField extends StatefulWidget {
  /// The page the frame wraps.
  final Widget child;

  /// Whether stickers can be dragged (default off — see the class doc).
  final bool draggable;

  const StickerFrameField({
    super.key,
    required this.child,
    this.draggable = false,
  });

  @override
  State<StickerFrameField> createState() => StickerFrameFieldState();
}

class StickerFrameFieldState extends State<StickerFrameField>
    with SingleTickerProviderStateMixin {
  List<Sprite>? _sprites;
  bool _launched = false;

  final List<_FrameParticle> _particles = [];
  final ValueNotifier<int> _tick = ValueNotifier(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  Size _size = Size.zero;
  bool _reduced = false;
  bool _spawned = false;

  /// The sticker currently in hand.
  _FrameParticle? _dragging;

  /// Gap between a sticker and the edge it claims.
  static const _margin = 6.0;

  /// The spawn pop overshoots to ~1.1x on the way in, so every half
  /// extent is padded before it is measured against the screen —
  /// otherwise the frame shaves itself on the bezel at the peak.
  static const _overshoot = 1.1;

  /// The burst owns the first beat: the flight starts while the eye is
  /// still on the middle of the screen.
  static const _flightDelay = 0.2; // s

  /// Extra stickers laid over the set to thicken the frame: all of them on
  /// the tall edges, where a phone has the room, plus a few along the top
  /// and bottom to keep the frame from reading as two side rails.
  static const _sideExtras = 12;
  static const _capExtras = 6;

  /// Rough half extents of a shaped cutout, for reasoning about where an
  /// extra will land before its art has been picked.
  static const _nominalAlong = 22.0;
  static const _nominalPerp = 34.0;

  /// Extra slack around a sticker's art when picking it up.
  static const _grabSlop = 6.0;

  /// How far past its slot a sticker is allowed to swing, in px. The
  /// spring overshoots a *share* of the flight, so without this cap the
  /// stickers whose slot is halfway across the screen would sail clean
  /// off the bezel and come back from nowhere.
  static const _maxOvershoot = 52.0;

  /// The damping ratio of the spring whose first swing overshoots by
  /// [share] of the distance flown: a damped oscillator peaks at
  /// exp(-πζ/√(1-ζ²)), so this inverts that.
  static double _zetaFor(double share) {
    final k = -math.log(share.clamp(0.004, 0.99));
    return k / math.sqrt(math.pi * math.pi + k * k);
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    StickerArt.loadSprites().then((sprites) {
      if (!mounted) return;
      setState(() => _sprites = sprites);
      // Tapped before the art finished decoding: fly now.
      if (_launched) _spawn();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_spawned) return;
    _spawned = true;
    _size = MediaQuery.sizeOf(context);
    _reduced = AppMotion.reducedMotion(context);
  }

  /// Detonate. Idempotent while in flight.
  void burst() {
    if (_launched) return;
    _launched = true;
    setState(() {});
    _spawn();
  }

  /// The whole border, walked clockwise from the top-left corner, plus
  /// the set of stickers that fills it: one per shipped cutout, then the
  /// extras — a phone's tall sides are where a frame has room to spare,
  /// so the repeats go there rather than crowding the top and bottom.
  void _spawn() {
    if (!_spawned || _particles.isNotEmpty) return;
    final sprites = _sprites;
    final w = _size.width;
    final h = _size.height;
    if (sprites == null || w <= 0 || h <= 0) return;
    final rng = math.Random();
    final count = sprites.length;
    final frame = [
      (_Edge.top, w),
      (_Edge.right, h),
      (_Edge.bottom, w),
      (_Edge.left, h),
    ];
    // The tall edges on their own (down the right, up the left) and the
    // two short ones (left to right, right to left).
    final sides = [(_Edge.right, h), (_Edge.left, h)];
    final caps = [(_Edge.top, w), (_Edge.bottom, w)];

    // One sticker per cutout, one slot each around the border. The slots
    // are walked in index order, so each flight leaves the blast point in
    // its own direction — the fan never crosses itself — and every
    // sticker turns to face the middle.
    final frameStep = 2 * (w + h) / count;
    // Where each cutout's own sticker lands: the extras have to borrow art
    // below, and a duplicate is only allowed if its twin ends up on the
    // far side of the screen.
    final slots = <int, Offset>{};
    for (var i = 0; i < count; i++) {
      slots[i] = _add(
        rng,
        spriteIndex: i,
        s: (i + 0.5) * frameStep,
        walk: frame,
        shaped: true,
      );
    }
    // Extra stickers, reusing art from the set — the density comes from
    // repetition, not from more images — but never reusing art whose own
    // sticker is nearby.
    final borrowed = <int>{};
    void extras(List<(_Edge, double)> walk, int count) {
      final span = walk.fold<double>(0, (sum, edge) => sum + edge.$2);
      for (var j = 0; j < count; j++) {
        final s = (j + 0.5) * span / count;
        // Roughly where this one will sit: the art's own aspect nudges the
        // slot by a few pixels, never enough to change which edge it is on.
        final (edge, local) = _walkTo(walk, s);
        final spot = _place(edge, local, _nominalAlong, _nominalPerp, 0.22);
        final pick = _furthestArt(slots, spot, borrowed);
        borrowed.add(pick);
        _add(rng, spriteIndex: pick, s: s, walk: walk, shaped: true);
      }
    }

    extras(sides, _sideExtras);
    extras(caps, _capExtras);
    if (_reduced) {
      // Reduced motion: no flight, no ticker — the frame is just there.
      for (final p in _particles) {
        p.t = p.delay + p.travel;
      }
    } else {
      _ticker.start();
    }
  }

  /// The art whose own sticker sits furthest from [spot], skipping art
  /// already borrowed — this is what keeps duplicates apart, so a repeat
  /// reads as a rhythm around the frame instead of a stutter.
  int _furthestArt(Map<int, Offset> slots, Offset spot, Set<int> taken) {
    var best = 0;
    var bestDistance = -1.0;
    slots.forEach((index, target) {
      if (taken.contains(index)) return;
      final distance = (target - spot).distanceSquared;
      if (distance > bestDistance) {
        bestDistance = distance;
        best = index;
      }
    });
    return best;
  }

  /// Adds one sticker to the frame and returns the slot it claimed. [s] is
  /// how far along [walk] it sits.
  Offset _add(
    math.Random rng, {
    required int spriteIndex,
    required double s,
    required List<(_Edge, double)> walk,
    required bool shaped,
  }) {
    final sprites = _sprites!;
    final aspect =
        sprites[spriteIndex].image.height / sprites[spriteIndex].image.width;
    final (edge, local) = _walkTo(walk, s);
    // The art's long side is what reaches in from the edge, so this is also
    // the thickness of the band. The top and bottom run tall — they are
    // what gives the frame its height, and a taller band there is what
    // keeps the page from reading as one long empty corridor — while the
    // sides stay slim so the middle keeps its width.
    final horizontal = edge == _Edge.top || edge == _Edge.bottom;
    final box = horizontal
        ? (shaped ? 76.0 : 64.0) + rng.nextDouble() * 26
        : (shaped ? 54.0 : 44.0) + rng.nextDouble() * 16;
    final probe = _FrameParticle(
      start: Offset.zero,
      target: Offset.zero,
      angle: 0,
      size: box,
      imgIndex: spriteIndex,
      shaped: shaped,
      delay: 0,
      travel: 1,
      pop: 1,
    );
    // The rotation only ever swaps these, so the same halves place the
    // sticker against a horizontal or a vertical edge.
    final art = probe.artSize(aspect);
    final target = _place(
      edge,
      local,
      art.width / 2 * _overshoot,
      art.height / 2 * _overshoot,
      // Varied a little so the frame hugs the bezel without the edge
      // reading as a ruler line.
      0.16 + rng.nextDouble() * 0.14,
    );
    // The blast has a body, not a point: a sticker leaves from somewhere
    // in a small disc around the middle of the screen.
    final origin = Offset(
          _size.width / 2,
          _size.height * StickerArt.originY,
        ) +
        Offset.fromDirection(
          rng.nextDouble() * math.pi * 2,
          rng.nextDouble() * _size.width * 0.05,
        );
    // Three kinds of flight, so 42 stickers never read as one mechanical
    // sweep. Each one is a damped oscillator — 0 at launch, settling on 1
    // at its slot — but ζ (how hard it slams the brakes) and ω (how fast
    // it gets there) are drawn from a different pocket of the space, and
    // the slow fliers are lit later, so the burst has a shape: a hard
    // fast core, a wide-armed middle that sails past its slot and springs
    // back, and a soft tail still drifting in when the rest are still.
    final roll = rng.nextDouble();
    final double want;
    final double omega;
    final double delay;
    if (roll < 0.3) {
      // Snap: stiff and quick, barely past the slot.
      want = 0.03 + rng.nextDouble() * 0.07;
      omega = 23 + rng.nextDouble() * 7;
      delay = rng.nextDouble() * 0.1;
    } else if (roll < 0.66) {
      // Overshoot: the hard-hitting middle of the blast.
      want = 0.16 + rng.nextDouble() * 0.14;
      omega = 16 + rng.nextDouble() * 7;
      delay = 0.04 + rng.nextDouble() * 0.16;
    } else {
      // Drift: the tail of the explosion, slower and later.
      want = 0.02 + rng.nextDouble() * 0.08;
      omega = 9 + rng.nextDouble() * 5;
      delay = 0.12 + rng.nextDouble() * 0.22;
    }
    // Cap the swing in pixels, then take the damping that delivers it.
    // travel is where the spring is within a percent of its slot —
    // 4.6 / (ζω) — and the kick gives it the launch velocity that makes
    // the release read as a blast.
    final share =
        math.min(want, _maxOvershoot / math.max(1.0, (target - origin).distance));
    final zeta = _zetaFor(share);
    final travel = 4.6 / (zeta * omega);
    final kick = 0.2 + rng.nextDouble() * 0.55;
    // Point the sticker's own "up" at the middle of the screen.
    final dir = origin - target;
    _particles.add(_FrameParticle(
      start: origin,
      target: target,
      angle: math.atan2(dir.dx, -dir.dy),
      size: box,
      imgIndex: spriteIndex,
      shaped: shaped,
      delay: _flightDelay + delay,
      travel: travel,
      omega: omega,
      zeta: zeta,
      kick: kick,
      pop: 0.14 + rng.nextDouble() * 0.1,
    ));
    return target;
  }

  /// Walks [walk] to distance [s]: which edge that lands on, and how far
  /// along it in the walk direction.
  (_Edge, double) _walkTo(List<(_Edge, double)> walk, double s) {
    for (final (edge, len) in walk) {
      if (s < len) return (edge, s);
      s -= len;
    }
    final last = walk.last;
    return (last.$1, last.$2);
  }

  /// The slot on [edge] at [local] along the walk direction (left→right on
  /// the top, top→bottom on the right, and so on). [bleed] is the share of
  /// the sticker left hanging off the screen — the frame reads as pinned
  /// to the bezel rather than floating inside it, and the middle of the
  /// screen stays clear for the page.
  Offset _place(
    _Edge edge,
    double local,
    double alongHalf,
    double perpHalf,
    double bleed,
  ) {
    final w = _size.width;
    final h = _size.height;
    // Distance from the edge to the sticker's centre: half of it sits on
    // screen at bleed 0, and a third of it hangs off at bleed 0.3.
    final inset = perpHalf * (1 - 2 * bleed) + _margin;
    double along(double v, double len) => v.clamp(
          alongHalf + _margin,
          math.max(alongHalf + _margin, len - alongHalf - _margin),
        );
    switch (edge) {
      case _Edge.top:
        // Head down, toward the middle.
        return Offset(along(local, w), inset);
      case _Edge.right:
        // Head to the left.
        return Offset(w - inset, along(local, h));
      case _Edge.bottom:
        // Head up.
        return Offset(along(w - local, w), h - inset);
      case _Edge.left:
        // Head to the right.
        return Offset(inset, along(h - local, h));
    }
  }

  void _onTick(Duration elapsed) {
    if (_particles.isEmpty) return;
    final rawDt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // Skip clock glitches (first frame, resume from background).
    if (rawDt <= 0) return;
    final dt = math.min(rawDt, 0.1);
    var moving = false;
    for (final p in _particles) {
      p.t += dt;
      if (!p.landed) moving = true;
    }
    _tick.value++;
    // Everything is in place: the frame is now a still image, so stop
    // painting frames for it.
    if (!moving) _ticker.stop();
  }

  /// Aspect (h/w) of the art behind a particle.
  double _aspectOf(_FrameParticle p) {
    final img = _sprites![p.imgIndex].image;
    return img.height / img.width;
  }

  _FrameParticle? _grab(Offset local) {
    final sprites = _sprites;
    if (sprites == null) return null;
    return _particleAt(_particles, sprites, local, _grabSlop);
  }

  void _onPanStart(DragStartDetails details) {
    final p = _grab(details.localPosition);
    if (p == null) return;
    // The sticker in hand comes to the front of the pile.
    _particles.remove(p);
    _particles.add(p);
    p.lifted = true;
    _dragging = p;
    _tick.value++;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final p = _dragging;
    if (p == null) return;
    final size = p.boundsFor(_aspectOf(p)).size;
    final maxX = math.max(size.width / 2, _size.width - size.width / 2);
    final maxY = math.max(size.height / 2, _size.height - size.height / 2);
    // Dropped is dropped: the sticker keeps wherever it was let go, just
    // never somewhere it cannot be picked up again.
    p.target = Offset(
      (p.target.dx + details.delta.dx).clamp(size.width / 2, maxX),
      (p.target.dy + details.delta.dy).clamp(size.height / 2, maxY),
    );
    _tick.value++;
  }

  void _onPanEnd(DragEndDetails details) {
    _dragging?.lifted = false;
    _dragging = null;
    _tick.value++;
  }

  @override
  void dispose() {
    _tick.dispose();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sprites = _sprites;
    final framed = _launched && sprites != null && _particles.isNotEmpty;
    return Stack(
      children: [
        // Behind the page: the content stays readable, and a sticker
        // being dragged slides under the cards rather than over them.
        if (framed)
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                size: _size,
                painter: _FramePainter(
                  particles: _particles,
                  sprites: sprites,
                  repaint: _tick,
                ),
              ),
            ),
          ),
        widget.child,
        // Above the page, so a sticker can be picked up wherever it sits.
        // Claims the pointer only inside a sticker, so a tap anywhere
        // else still reaches the page underneath.
        if (framed && widget.draggable)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: CustomPaint(
                painter: _GrabPainter(
                  particles: _particles,
                  sprites: sprites,
                  slop: _grabSlop,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The four edges of the frame, in walk order (clockwise from the
/// top-left corner).
enum _Edge { top, right, bottom, left }

/// The topmost particle whose drawn art sits under [position] (plus
/// [slop] of slack), or null. Shared by the painter's hit test and the
/// drag handler so they can never disagree about what was touched.
_FrameParticle? _particleAt(
  List<_FrameParticle> particles,
  List<Sprite> sprites,
  Offset position,
  double slop,
) {
  for (var i = particles.length - 1; i >= 0; i--) {
    final p = particles[i];
    if (p.u <= 0 || p.scale <= 0) continue;
    final img = sprites[p.imgIndex].image;
    final aspect = img.height / img.width;
    if (p.boundsFor(aspect).inflate(slop).contains(position)) return p;
  }
  return null;
}

class _FrameParticle {
  /// Where it leaves from (the blast point) and the slot it claims.
  final Offset start;
  Offset target;

  /// Final rotation, radians — "up" aimed at the screen middle.
  final double angle;

  /// Art box side (plain) or square art box side (shaped), in px.
  final double size;
  final int imgIndex;

  /// Draws its M3 silhouette card behind the art (grid composition).
  /// Every frame sticker is shaped today; the plain cutout path is kept
  /// for sets that want it.
  final bool shaped;

  /// Lit this long after the detonation, seconds.
  final double delay;

  /// Seconds from lit to locked in.
  final double travel;

  /// Seconds the arrival pop takes (0→1 with a little overshoot).
  final double pop;

  /// The spring this flight is one solution of: [omega] is stiffness
  /// (rad/s), [zeta] the damping ratio, [kick] the launch velocity as a
  /// share of omega. Stiff light springs snap in and overshoot hard, soft
  /// heavy ones glide in flat — the spread between them is what keeps the
  /// burst from reading as one mechanical sweep.
  final double omega;
  final double zeta;
  final double kick;

  /// How much bigger a sticker gets while it is held.
  static const liftedScale = 1.08;

  /// In hand right now (grows a touch so it reads as picked up).
  bool lifted = false;

  /// A throwaway flight's defaults — probes measure art, they never fly.
  static const _still = 18.0; // ω

  double t = 0;

  _FrameParticle({
    required this.start,
    required this.target,
    required this.angle,
    required this.size,
    required this.imgIndex,
    required this.shaped,
    required this.delay,
    required this.travel,
    required this.pop,
    this.omega = _still,
    this.zeta = 0.6,
    this.kick = 0.3,
  });

  /// Flight progress, 0 while it is still in the pocket.
  double get u => ((t - delay) / travel).clamp(0.0, 1.0);

  bool get landed => t >= delay + travel;

  /// Spawn pop: right after this sticker lights up it scales 0→1 with a
  /// slight overshoot, so the whole frame reads as sprung, not placed.
  /// The duration varies per sticker so the pops land out of step too.
  double get scale =>
      Curves.easeOutBack.transform(((t - delay) / pop).clamp(0.0, 1.0)) *
      (lifted ? liftedScale : 1.0);

  /// The spring response: 0 at launch, settling on 1 — a damped
  /// oscillator, so every sticker rushes its slot, overshoots it and snaps
  /// back into the frame. Landing is pinned to 1 so a settled sticker sits
  /// exactly where it claimed its slot.
  double get flight {
    if (u <= 0) return 0;
    if (u >= 1) return 1;
    final time = t - delay;
    // Damped frequency: ω√(1 - ζ²).
    final damped = omega * math.sqrt(1 - zeta * zeta);
    return 1 -
        math.exp(-zeta * omega * time) *
            (math.cos(damped * time) +
                ((zeta - kick) * omega / damped) * math.sin(damped * time));
  }

  /// Where it is now — straight out from the blast point, so the springs
  /// read as one explosion instead of a set of separate flights.
  Offset get pos => Offset.lerp(start, target, flight)!;

  /// The turn finishes a beat before the flight does, so the sticker
  /// arrives already squared up to the middle — with a last few degrees
  /// of overshoot as it settles, rather than unwinding at a flat rate.
  double get rot =>
      angle * Curves.easeOutBack.transform(math.min(1.0, u / 0.72));

  /// Drawn art size for an image of [aspect] (h/w), before the pop scale.
  Size artSize(double aspect) {
    if (shaped) {
      return aspect >= 1
          ? Size(size / aspect, size)
          : Size(size, size * aspect);
    }
    return Size(size, size * aspect);
  }

  /// Axis-aligned box the drawn art covers right now — the grab area.
  Rect boundsFor(double aspect) {
    final art = artSize(aspect);
    final c = math.cos(rot).abs();
    final s = math.sin(rot).abs();
    return Rect.fromCenter(
      center: pos,
      width: art.width * c + art.height * s,
      height: art.width * s + art.height * c,
    );
  }
}

class _FramePainter extends CustomPainter {
  final List<_FrameParticle> particles;
  final List<Sprite> sprites;

  /// Silhouette-to-art ratio, same as the grid's [ShapedSticker]: the
  /// card is 0.7 of the art box, so the cutout overflows it on all sides.
  static const _cardScale = 0.7;

  /// Parsed silhouettes, centered on the origin and normalized to a
  /// 100×100 box. SVG parsing costs far too much to repeat per particle
  /// per frame, so each shape is parsed once and then only scaled.
  static final Map<Shapes, ui.Path> _paths = {};

  static ui.Path _pathFor(int shapeIndex) {
    final shape =
        kStyleShapes[shapeIndex.clamp(0, kStyleShapes.length - 1)];
    return _paths.putIfAbsent(shape, () {
      final path = M3Clipper(shape).getClip(const ui.Size(100, 100));
      final bounds = path.getBounds();
      // The enum ships placeholder shapes with no SVG data — a
      // degenerate path would draw nothing and scale by infinity.
      if (!(bounds.width > 1 && bounds.height > 1)) {
        return ui.Path()..addOval(const ui.Rect.fromLTWH(0, 0, 100, 100));
      }
      return path.shift(const ui.Offset(-50, -50));
    });
  }

  _FramePainter({
    required this.particles,
    required this.sprites,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    for (final p in particles) {
      final scale = p.scale;
      // easeOutBack dips below zero on the way in.
      if (scale <= 0) continue;
      final sprite = sprites[p.imgIndex];
      final img = sprite.image;
      final aspect = img.height / img.width;
      final pos = p.pos;
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.rot);
      if (p.shaped) {
        _paintShaped(canvas, p, sprite, aspect, scale);
      } else {
        final art = p.artSize(aspect);
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          ui.Rect.fromCenter(
            center: ui.Offset.zero,
            width: art.width * scale,
            height: art.height * scale,
          ),
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
      canvas.restore();
    }
  }

  /// The homescreen grid's composition: a solid dominant-color M3
  /// silhouette with the cutout overflowing it on every side. No drop
  /// shadow — the flat card is what makes it read as a sticker.
  void _paintShaped(
    ui.Canvas canvas,
    _FrameParticle p,
    Sprite sprite,
    double aspect,
    double scale,
  ) {
    final art = p.artSize(aspect);
    final side = p.size * _cardScale * scale;
    canvas.save();
    canvas.scale(side / 100);
    canvas.drawPath(
      _pathFor(sprite.shapeIndex),
      Paint()..color = Color(sprite.dominantColor),
    );
    canvas.restore();
    // Cutout on top, contained in the art box so it never stretches.
    canvas.drawImageRect(
      sprite.image,
      ui.Rect.fromLTWH(
        0,
        0,
        sprite.image.width.toDouble(),
        sprite.image.height.toDouble(),
      ),
      ui.Rect.fromCenter(
        center: ui.Offset.zero,
        width: art.width * scale,
        height: art.height * scale,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => false;
}

/// Invisible layer that exists only to answer "is there a sticker here?"
/// for the drag layer above the page. It paints nothing, so the frame
/// itself still renders behind the content.
class _GrabPainter extends CustomPainter {
  final List<_FrameParticle> particles;
  final List<Sprite> sprites;
  final double slop;

  const _GrabPainter({
    required this.particles,
    required this.sprites,
    required this.slop,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {}

  @override
  bool? hitTest(ui.Offset position) =>
      _particleAt(particles, sprites, position, slop) != null;

  @override
  bool shouldRepaint(_GrabPainter oldDelegate) => false;
}
