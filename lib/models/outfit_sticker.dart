class OutfitSticker {
  final String id;
  final String imagePath;
  final DateTime createdAt;

  /// Mean boundary color (ARGB int) for adapt mode. Null = legacy sticker
  /// (predates edge sampling).
  final int? edgeColor;

  /// True once the baked white halo is stripped (or the sticker was saved
  /// halo-free). False = renders baked-white regardless of style.
  final bool haloStripped;

  /// Index into kStyleShapes: the sticker's M3 silhouette, picked from
  /// the image's dominant color hue. Null = legacy (derive from hash).
  final int? shapeIndex;

  /// Dominant image color (ARGB int) from the M3 theming engine — fills
  /// the shaped backdrop behind the sticker. Null = legacy (neutral).
  final int? dominantColor;

  OutfitSticker({
    required this.id,
    required this.imagePath,
    required this.createdAt,
    this.edgeColor,
    this.haloStripped = false,
    this.shapeIndex,
    this.dominantColor,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'imagePath': imagePath,
    'createdAt': createdAt.toIso8601String(),
    if (edgeColor != null) 'edgeColor': edgeColor,
    'haloStripped': haloStripped,
    if (shapeIndex != null) 'shapeIndex': shapeIndex,
    if (dominantColor != null) 'dominantColor': dominantColor,
  };

  factory OutfitSticker.fromJson(Map<String, dynamic> json) => OutfitSticker(
    id: json['id'] as String,
    imagePath: json['imagePath'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    edgeColor: (json['edgeColor'] as num?)?.toInt(),
    haloStripped: (json['haloStripped'] as bool?) ?? false,
    shapeIndex: (json['shapeIndex'] as num?)?.toInt(),
    dominantColor: (json['dominantColor'] as num?)?.toInt(),
  );

  OutfitSticker copyWith({
    int? edgeColor,
    bool? haloStripped,
    int? shapeIndex,
    int? dominantColor,
  }) => OutfitSticker(
    id: id,
    imagePath: imagePath,
    createdAt: createdAt,
    edgeColor: edgeColor ?? this.edgeColor,
    haloStripped: haloStripped ?? this.haloStripped,
    shapeIndex: shapeIndex ?? this.shapeIndex,
    dominantColor: dominantColor ?? this.dominantColor,
  );
}
