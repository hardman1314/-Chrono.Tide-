class GameMetadata {
  final String id;
  final String source;
  final String title;
  final String titleCn;
  final String description;
  final String imageUrl;
  final List<String> tags;
  final double rating;
  final int voteCount;
  final List<String> developers;

  GameMetadata({
    required this.id,
    required this.source,
    required this.title,
    required this.titleCn,
    required this.description,
    required this.imageUrl,
    required this.tags,
    required this.rating,
    required this.voteCount,
    this.developers = const [],
  });

  factory GameMetadata.fromJson(Map<String, dynamic> json) {
    List<String> devs = [];
    if (json['developers'] != null) {
      if (json['developers'] is List) {
        devs = (json['developers'] as List)
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
      } else if (json['developers'] is String &&
          json['developers'].toString().isNotEmpty) {
        devs = [json['developers'].toString()];
      }
    }

    return GameMetadata(
      id: json['id'] ?? '',
      source: json['source'] ?? '',
      title: json['title'] ?? json['name'] ?? '',
      titleCn: json['title_cn'] ?? json['name_cn'] ?? '',
      description: json['description'] ?? json['summary'] ?? '',
      imageUrl: json['image_url'] ?? '',
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
      rating: (json['rating'] ?? json['score'] ?? 0).toDouble(),
      voteCount: json['vote_count'] ?? 0,
      developers: devs,
    );
  }

  String get displayName => titleCn.isNotEmpty ? titleCn : title;

  bool get hasImage => imageUrl.isNotEmpty && imageUrl.startsWith('http');

  bool get hasDescription => description.length > 10;

  Map<String, dynamic> toMap() {
    String developerStr = developers.isNotEmpty ? developers.join(', ') : '';

    return {
      'game_name': displayName,
      'platform': source,
      'platform_id': id,
      'tags': tags,
      'summary': description,
      'cover_url': imageUrl,
      'release_date': '',
      'developer': developerStr,
    };
  }

  @override
  String toString() {
    return 'GameMetadata(id: $id, source: $source, title: $displayName, '
        'tags: ${tags.length}个, hasImage: $hasImage)';
  }
}

class SearchResult {
  final bool success;
  final String query;
  final String queryType;
  final String? platform;
  final List<GameMetadata> vndbResults;
  final List<GameMetadata> bangumiResults;
  final int totalCount;
  final double elapsedSeconds;

  SearchResult({
    required this.success,
    required this.query,
    required this.queryType,
    this.platform,
    required this.vndbResults,
    required this.bangumiResults,
    required this.totalCount,
    required this.elapsedSeconds,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    var results = json['results'] ?? {};

    var vndbList = (results['vndb'] as List?)
            ?.map((e) => GameMetadata.fromJson(e))
            .toList() ??
        [];

    var bangumiList = (results['bangumi'] as List?)
            ?.map((e) => GameMetadata.fromJson(e))
            .toList() ??
        [];

    var stats = json['statistics'] ?? {};

    return SearchResult(
      success: json['success'] ?? false,
      query: json['query'] ?? '',
      queryType: json['query_type'] ?? 'name',
      platform: json['platform'],
      vndbResults: vndbList,
      bangumiResults: bangumiList,
      totalCount: stats['total'] ?? 0,
      elapsedSeconds: (stats['elapsed'] ?? 0).toDouble(),
    );
  }

  List<GameMetadata> get allResults => [...vndbResults, ...bangumiResults];

  bool get hasResults => allResults.isNotEmpty;

  GameMetadata? get bestMatch => vndbResults.isNotEmpty
      ? vndbResults.first
      : bangumiResults.isNotEmpty
          ? bangumiResults.first
          : null;

  List<Map<String, dynamic>> toUiFormat() {
    return allResults.map((game) => game.toMap()).toList();
  }
}
