import 'game.dart';

class TagItem {
  final String name;
  final String source;
  final double weight;
  final bool isSpoiler;

  const TagItem({
    required this.name,
    required this.source,
    required this.weight,
    this.isSpoiler = false,
  });

  factory TagItem.fromJson(Map<String, dynamic> json) {
    return TagItem(
      name: json['name'] ?? '',
      source: json['source'] ?? '',
      weight: (json['weight'] as num?)?.toDouble() ?? 0.0,
      isSpoiler: json['is_spoiler'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'source': source,
      'weight': weight,
      'is_spoiler': isSpoiler,
    };
  }
}

class MetadataResult {
  final Game game;
  final List<TagItem> tags;

  const MetadataResult({
    required this.game,
    this.tags = const [],
  });

  bool get isValid => game.id.isNotEmpty && game.name.isNotEmpty;

  factory MetadataResult.fromJson(Map<String, dynamic> json) {
    return MetadataResult(
      game: Game.fromJson(json['game'] ?? {}),
      tags: (json['tags'] as List<dynamic>?)
              ?.map((e) => TagItem.fromJson(e))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'game': game.toJson(),
      'tags': tags.map((t) => t.toJson()).toList(),
    };
  }
}
