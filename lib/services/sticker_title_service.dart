/// Funny honorific titles granted after the user shares their name in
/// onboarding ("Joffery" -> "the Wise"). Deterministic: the same name
/// always yields the same title, so resume/kill never re-rolls it.
class StickerTitleService {
  StickerTitleService._();

  static const List<String> titles = [
    'the Wise',
    'the Unbothered',
    'the Overdressed',
    'the Last-Minute Legend',
    'the Sauce Keeper',
    'of the Group Chat',
    'the Fit Checker',
    'the Ironed',
    'the Unironed',
    'the Vintage Villain',
    'the Denim Prophet',
    'the Sockless Wonder',
    'of Thrift',
    'the Hem Reaper',
    'the Croc Apostate',
    'the Lint Roller',
    "the Mirror's Favorite",
    'the Wardrobe Menace',
    'the Steamed',
    'the Unsteamed',
    'the Belted',
    'the Pattern Crasher',
    'the Hemperor',
    'the Freshly Taped',
  ];

  /// Display form of the raw input: trimmed, single-spaced, first letter
  /// up, capped so it fits the reveal card.
  static String displayNameFor(String raw) {
    var name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) return '';
    if (name.length > 20) name = '${name.substring(0, 19).trim()}…';
    return name[0].toUpperCase() + name.substring(1);
  }

  /// Deterministic title for [raw]; empty input yields ''.
  static String titleFor(String raw) {
    final key = raw.trim().toLowerCase();
    if (key.length < 2) return '';
    return titles[key.hashCode.abs() % titles.length];
  }

  /// One haiku-ish line per answered question, in the voice of the
  /// sticker gods. The question pages stack these under the headline,
  /// so every answer grows the poem. Unknown values yield ''.
  static String poemLineFor(int question, String answer) {
    final v = answer.trim();
    if (v.isEmpty) return '';
    switch (question) {
      case 0:
        final title = titleFor(v);
        final name = displayNameFor(v);
        if (name.isEmpty) return '';
        return title.isNotEmpty ? '$name $title,' : '$name,';
      case 1:
        return switch (v) {
          'Woman' => 'draped in her own weather,',
          'Man' => 'cut from a cleaner cloth,',
          'Non-binary' => 'tailored outside the lines,',
          _ => 'a beautiful unknown,',
        };
      case 2:
        return switch (v) {
          'Casual' => 'denim days and easy light,',
          'Streetwear' => 'concrete runway ready,',
          'Goth' => 'beauty in the beautiful dark,',
          'Vintage' => 'a thrifted time traveler,',
          'Minimal' => 'simplicity, tailored,',
          'Athleisure' => 'always in motion,',
          'Formal' => 'pressed and purposeful,',
          'Boho' => 'a wildflower in the wind,',
          _ => 'dressed like a rumour,',
        };
      case 3:
        return switch (v) {
          'Rewear more' => 'rewearing beloved ghosts,',
          'Buy less' => 'hunger, tamed,',
          'Organize it' => 'every hanger a home,',
          'Try new styles' => 'a new silhouette blooms,',
          'Declutter' => 'shedding the old skin,',
          'Dress bolder' => 'louder hems ahead,',
          _ => 'plotting a wardrobe coup,',
        };
      case 4:
        return switch (v) {
          'Effortless' => 'effortless as breath,',
          'Exciting' => 'sparks at the seams,',
          'Calm' => 'still water, sharp cut,',
          'Confident' => 'shoulders back, chin high,',
          'Playful' => 'pockets full of mischief,',
          _ => 'feeling some kind of way,',
        };
      case 5:
        return switch (v) {
          'Myself' => 'dressed for the mirror\u2019s favorite.',
          'The world' => 'dressed for the whole wide world.',
          _ => 'for herself and the world alike.',
        };
      default:
        return '';
    }
  }
}
