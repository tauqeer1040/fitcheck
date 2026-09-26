import '../models/outfit_sticker.dart';

/// Playful, CarrotWeather-style outfit roasts.
///
/// House rules (never break these):
/// - Roast the OUTFIT, never the body. No weight, shape, skin, age,
///   attractiveness, or identity talk. Ever.
/// - Punch at the clothes and the wearer's habits (rewearing favorites,
///   archiving everything), never down at the person.
/// - Keep every line short and quotable — sticker-caption energy.
class RoastService {
  static const List<String> _roasts = [
    'Wore it once. Photographed it twice. Iconic behavior.',
    'This fit has main-character Wi-Fi.',
    'The closet called. It wants royalties.',
    'Certified rewear. Sustainability looks good on you.',
    'POV: your wardrobe finally getting screen time.',
    'Bold of this jacket to carry the whole fit. Respect.',
    "Laundry day's worst enemy, camera roll's best friend.",
    'This outfit understood the assignment and did extra credit.',
    'Somewhere, a mannequin just took notes.',
    'The group chat is about to have Opinions.',
    'Wearing the favorite again? We call that a signature.',
    'This fit walked so your camera roll could run.',
    'Formally requesting this look run for office.',
    'Your closet calls this one "the reliable one."',
    'Low effort? No. Efficiently iconic.',
    'This is what "nothing to wear" looks like? Sure.',
    'The mirror filed no complaints.',
    'Outfit repeating is just sequel behavior. Critics approve.',
    'Straight into the sticker hall of fame.',
    'Dress code: unbothered.',
    'This look pays rent in compliments.',
    'Archived in the grid. History will remember.',
    'Screenshot this before it becomes vintage.',
    'Fit check: passed with honors.',
  ];

  /// Max-member exclusives: same house rules, premium flavor. Appended
  /// after [_roasts] so the free rotation never shifts — a free sticker's
  /// line is byte-stable whether or not the member pool exists.
  static const List<String> _maxRoasts = [
    'Max-member fit. The paywall was worth it for this one.',
    'Unlimited stickers, unlimited nerve. We approve.',
    'This is what the good side of the paywall looks like.',
    'Premium drip, premium sticker. The math works.',
    'Your subscription just struck a pose.',
    'Thirty stickers was merely the opening act.',
    'Max energy, meet maximum outfit.',
    'The algorithm bows to this fit. So do we.',
    'Rent-free in our heads, worth every cent in yours.',
    'This look bills monthly: iconic, recurring.',
    'Gatekept? Never. This fit is for the feed.',
    'Somewhere a free trial just expired from jealousy.',
    'Certified Max moment. Frame it twice.',
    'Your closet pays dividends. Collect in compliments.',
    'Beyond the gate, the fits hit different. Case in point.',
  ];

  /// Deterministic pick per sticker, so a sticker's roast is stable
  /// across opens. Bump [salt] (e.g. refresh button) for a new line.
  /// [isMax] opens the member-exclusive pool on top of the free one.
  static String roastFor(
    OutfitSticker sticker, {
    int salt = 0,
    bool isMax = false,
  }) =>
      roastForId(sticker.id, salt: salt, isMax: isMax);

  /// Same pick by raw id — for cutouts that aren't saved stickers yet
  /// (e.g. the onboarding Aura reveal).
  static String roastForId(String id, {int salt = 0, bool isMax = false}) {
    final h = id.hashCode ^ salt;
    final free = _roasts.length;
    final total = free + (isMax ? _maxRoasts.length : 0);
    final pick = h.abs() % total;
    return pick < free ? _roasts[pick] : _maxRoasts[pick - free];
  }

  /// Number of lines in the rotation (for tests/debug).
  static int get count => _roasts.length;
}
