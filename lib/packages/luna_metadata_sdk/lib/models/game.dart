class Game {
  final String id;
  final String name;
  final String? coverUrl;
  final String? company;
  final String? summary;
  final double rating;
  final int? voteCount;
  final String? releaseDate;
  final SourceType sourceType;
  final String? sourceId;
  final DateTime cachedAt;
  final List<String>? screenshotUrls;

  Game({
    required this.id,
    required this.name,
    this.coverUrl,
    this.company,
    this.summary,
    this.rating = 0.0,
    this.voteCount,
    this.releaseDate,
    this.sourceType = SourceType.local,
    this.sourceId,
    this.screenshotUrls,
    DateTime? cachedAt,
  }) : cachedAt = cachedAt ?? DateTime.now();

  factory Game.fromJson(Map<String, dynamic> json) {
    return Game(
      id: json['id']?.toString() ?? '',
      name: json['name'] ?? '',
      coverUrl: json['cover_url'],
      company: json['company'],
      summary: json['summary'],
      rating: (json['rating'] as num?)?.toDouble() ?? 0.0,
      voteCount: (json['vote_count'] as num?)?.toInt(),
      releaseDate: json['release_date'],
      sourceType: SourceType.values.firstWhere(
        (e) => e.name == (json['source_type'] ?? 'local'),
        orElse: () => SourceType.local,
      ),
      sourceId: json['source_id']?.toString(),
      screenshotUrls: (json['screenshot_urls'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      cachedAt: json['cached_at'] != null
          ? DateTime.parse(json['cached_at'])
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'cover_url': coverUrl,
      'company': company,
      'summary': summary,
      'rating': rating,
      'vote_count': voteCount,
      'release_date': releaseDate,
      'source_type': sourceType.name,
      'source_id': sourceId,
      'screenshot_urls': screenshotUrls,
      'cached_at': cachedAt.toIso8601String(),
    };
  }

  Game copyWith({
    String? id,
    String? name,
    String? coverUrl,
    String? company,
    String? summary,
    double? rating,
    int? voteCount,
    String? releaseDate,
    SourceType? sourceType,
    String? sourceId,
    List<String>? screenshotUrls,
    DateTime? cachedAt,
  }) {
    return Game(
      id: id ?? this.id,
      name: name ?? this.name,
      coverUrl: coverUrl ?? this.coverUrl,
      company: company ?? this.company,
      summary: summary ?? this.summary,
      rating: rating ?? this.rating,
      voteCount: voteCount ?? this.voteCount,
      releaseDate: releaseDate ?? this.releaseDate,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      screenshotUrls: screenshotUrls ?? this.screenshotUrls,
      cachedAt: cachedAt ?? this.cachedAt,
    );
  }
}

enum SourceType {
  local,
  bangumi,
  vndb,
  ymgal,
  steam,
  dlsite,
  erogamescape,
  touchgal,
  hikarinagi,
  kun;

  String get displayName {
    switch (this) {
      case SourceType.bangumi:
        return 'Bangumi';
      case SourceType.vndb:
        return 'VNDB';
      case SourceType.ymgal:
        return '月幕GAL';
      case SourceType.steam:
        return 'Steam';
      case SourceType.dlsite:
        return 'DLsite';
      case SourceType.erogamescape:
        return 'ErogameScape';
      case SourceType.touchgal:
        return 'TouchGal';
      case SourceType.hikarinagi:
        return 'Hikarinagi';
      case SourceType.kun:
        return 'KunGal';
      default:
        return '本地';
    }
  }
}
