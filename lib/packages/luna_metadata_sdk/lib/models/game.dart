class Game {
  final String id;
  final String name;

  /// 原版标题（优先日文，来自数据源的多语言标题字段）
  /// 供上游作为"副标题"使用；无日文标题的数据源为 null
  final String? originalTitle;
  final String? coverUrl;

  /// ★ 2026-10-04 横幅封面 URL（横向大图，BPM 背景 / 主页大图优先用）。
  ///
  /// 数据来源：NextMoe `covers[]` 里选出的横版图（宽>高）、KunGal
  /// `effective_banner_url`/`banner_url`。VNDB kana API 无横幅字段（null）。
  /// null = 该源未提供横幅。
  final String? bannerUrl;
  final String? company;
  final String? summary;
  final double rating;
  final int? voteCount;
  final String? releaseDate;

  /// 预计游玩时长：VNDB 多用户平均游玩时长（分钟，length_minutes）。
  /// 由 VNDB 用户自报时长聚合而来（length_votes 为参与统计的人数），
  /// 其他数据源暂无对应字段（null = 未提供）。
  final int? lengthMinutes;
  final int? lengthVotes;
  final SourceType sourceType;
  final String? sourceId;
  final DateTime cachedAt;
  final List<String>? screenshotUrls;

  Game({
    required this.id,
    required this.name,
    this.originalTitle,
    this.coverUrl,
    this.bannerUrl,
    this.company,
    this.summary,
    this.rating = 0.0,
    this.voteCount,
    this.releaseDate,
    this.lengthMinutes,
    this.lengthVotes,
    this.sourceType = SourceType.local,
    this.sourceId,
    this.screenshotUrls,
    DateTime? cachedAt,
  }) : cachedAt = cachedAt ?? DateTime.now();

  factory Game.fromJson(Map<String, dynamic> json) {
    return Game(
      id: json['id']?.toString() ?? '',
      name: json['name'] ?? '',
      originalTitle: json['original_title'],
      coverUrl: json['cover_url'],
      bannerUrl: json['banner_url'],
      company: json['company'],
      summary: json['summary'],
      rating: (json['rating'] as num?)?.toDouble() ?? 0.0,
      voteCount: (json['vote_count'] as num?)?.toInt(),
      releaseDate: json['release_date'],
      lengthMinutes: (json['length_minutes'] as num?)?.toInt(),
      lengthVotes: (json['length_votes'] as num?)?.toInt(),
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
      'original_title': originalTitle,
      'cover_url': coverUrl,
      'banner_url': bannerUrl,
      'company': company,
      'summary': summary,
      'rating': rating,
      'vote_count': voteCount,
      'release_date': releaseDate,
      'length_minutes': lengthMinutes,
      'length_votes': lengthVotes,
      'source_type': sourceType.name,
      'source_id': sourceId,
      'screenshot_urls': screenshotUrls,
      'cached_at': cachedAt.toIso8601String(),
    };
  }

  Game copyWith({
    String? id,
    String? name,
    String? originalTitle,
    String? coverUrl,
    String? bannerUrl,
    String? company,
    String? summary,
    double? rating,
    int? voteCount,
    String? releaseDate,
    int? lengthMinutes,
    int? lengthVotes,
    SourceType? sourceType,
    String? sourceId,
    List<String>? screenshotUrls,
    DateTime? cachedAt,
  }) {
    return Game(
      id: id ?? this.id,
      name: name ?? this.name,
      originalTitle: originalTitle ?? this.originalTitle,
      coverUrl: coverUrl ?? this.coverUrl,
      bannerUrl: bannerUrl ?? this.bannerUrl,
      company: company ?? this.company,
      summary: summary ?? this.summary,
      rating: rating ?? this.rating,
      voteCount: voteCount ?? this.voteCount,
      releaseDate: releaseDate ?? this.releaseDate,
      lengthMinutes: lengthMinutes ?? this.lengthMinutes,
      lengthVotes: lengthVotes ?? this.lengthVotes,
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
  kun,
  nextmoe,
  ct,
  mix;

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
      case SourceType.nextmoe:
        // NextMoe·未萌 开放 API（六源对齐目录：VNDB/Bangumi/DLsite/
        // ErogameScape/Ci-en/Getchu，数据经由鲲 Galgame 论坛生态对齐）
        return 'NextMoe';
      case SourceType.ct:
        // CT 探索库（Chrono Tide 自建 PocketBase 平台，社区共建中文元数据）
        return 'CT';
      case SourceType.mix:
        // 整合源（非真实平台）：由 NextMoe/VNDB/KunGal/Hikarinagi/Steam/
        // 月幕GAL 按字段优先级整合而来，展示时统一标识为"MIX源"
        return 'MIX源';
      default:
        return '本地';
    }
  }

  /// 是否为整合源（MIX）：无独立抓取服务，由 MetadataFetcher 编排多源整合
  bool get isMix => this == SourceType.mix;
}
