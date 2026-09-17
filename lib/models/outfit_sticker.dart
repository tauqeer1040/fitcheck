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

  OutfitSticker({
    required this.id,
    required this.imagePath,
    required this.createdAt,
    this.edgeColor,
    this.haloStripped = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'imagePath': imagePath,
    'createdAt': createdAt.toIso8601String(),
    if (edgeColor != null) 'edgeColor': edgeColor,
    'haloStripped': haloStripped,
  };

  factory OutfitSticker.fromJson(Map<String, dynamic> json) => OutfitSticker(
    id: json['id'] as String,
    imagePath: json['imagePath'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    edgeColor: (json['edgeColor'] as num?)?.toInt(),
    haloStripped: (json['haloStripped'] as bool?) ?? false,
  );

  OutfitSticker copyWith({int? edgeColor, bool? haloStripped}) =>
      OutfitSticker(
        id: id,
        imagePath: imagePath,
        createdAt: createdAt,
        edgeColor: edgeColor ?? this.edgeColor,
        haloStripped: haloStripped ?? this.haloStripped,
      );
}
