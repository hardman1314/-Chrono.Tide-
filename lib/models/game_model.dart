import 'package:flutter/material.dart';
import '../core/pb_config.dart';

class GameModel {
  final String id;
  final String title;
  final String description;
  final String coverUrl;

  /// 横幅封面（PB `bannerUrl` file 字段，2026-10-05 与本地 banner_file 对齐）
  ///
  /// 横向高清封面图，供大图场景（下载后本地 BPM 背景/主页大图）使用；
  /// 探索页数据层先支持，缺失时全部场景回退竖版 [coverUrl]。
  final String bannerUrl;
  final List<String> tags;
  final String downloadUrl;
  final String status;
  final String developer;
  final List<String> screenshotUrls; // PB screenshots 字段（多文件）
  final String originalTitle; // PB originalTitle 字段（日语原标题）
  final String englishTitle; // PB englishTitle 字段（英语标题）
  final String version; // PB version 字段（版本名）
  final String versionNote; // PB versionNote 字段（版本详情信息）
  final int installCount; // PB installCount 字段（安装总人数，用于活跃度分析）

  // ===== 云端沉淀的元数据（v2.1.17）=====
  // 由客户端抓取成功后回写（机制同 screenshots：云端无 → 抓取 → 回传），
  // 供全部用户直接读取，避免每台机器重复跑元数据抓取流程。
  final double? rating; // PB rating 字段（0-10 分制；<=0 视为无）
  final int? voteCount; // PB voteCount 字段（评分/投票人数，热度代理；<=0 视为无）
  final String releaseDate; // PB releaseDate 字段（ISO YYYY-MM-DD）
  final String metaSource; // PB metaSource 字段（元数据来源平台，如 VNDB）
  final int? estimatedMinutes; // PB estimatedMinutes 字段（多用户平均游玩时长，分钟；<=0 视为无）

  /// 是否存在官方来源（PB `has_official` 冗余字段）
  ///
  /// 探索库卡片「可安装」角标的判据（方案 §2.3 / §6.1）。
  /// 由管理员补官方来源时置 true（§5.3 第 2 步）；用户投稿作品默认 false。
  /// ⚠️ **不能**用 `downloadUrl` 非空代替——该字段是必填项，
  /// 用户作品也必然非空，无法区分「有无官方来源」（§9.5 已实测排除）。
  final bool hasOfficial;

  // ===== 发布 / 归属（v4.4「发布」链路新增解析，均为纯新增字段）=====

  /// 投稿来源（PB `origin`）：`official` = 管理员上传，`user` = 用户【发布】
  ///
  /// ⚠️ 仅用于**展示与归属**，**不参与任何权限判断**（方案 §2.3「同级同权」）。
  final String origin;

  /// 发布者 id（PB `owner`，relation→users）。预设作品为空串。
  final String ownerId;

  /// 发布者昵称快照（PB `creator_name`，冗余字段，列表展示免 expand）
  final String creatorName;

  /// 审核状态（PB `review_status`）：`approved` / `pending` / `rejected`
  ///
  /// 🔴 与权限强相关：`review_status = approved` 后发布者**不能再编辑**该作品
  /// （`games.updateRule = owner=自己 && origin="user" && review_status != "approved"`，
  /// 改则返回 404）。
  final String reviewStatus;

  /// 用户分享来源数量（PB `community_count` 冗余字段）
  ///
  /// ⚠️ 该字段**当前未维护、全库恒 0**（方案 §9 风险 #8）；列表角标一律走
  /// `GameResourceService.communityCountBatch` 现算。此处仅保留解析，供将来启用。
  final int communityCount;

  /// 作品级点赞数（PB `like_count`，由 game-stats hook 路由累加；
  /// 主线补完 §14.2-P2，客户端直改被服务端 lock_fields 锁定）
  final int likeCount;

  /// 繁中标题（PB `traditionalChineseTitle`，「发布」第二步的别名之一）
  final String traditionalChineseTitle;

  final DateTime created;
  final DateTime updated;

  const GameModel({
    required this.id,
    required this.title,
    this.description = '',
    this.coverUrl = '',
    this.bannerUrl = '',
    this.tags = const [],
    this.downloadUrl = '',
    this.status = '',
    this.developer = '',
    this.screenshotUrls = const [],
    this.originalTitle = '',
    this.englishTitle = '',
    this.version = '',
    this.versionNote = '',
    this.installCount = 0,
    this.rating,
    this.voteCount,
    this.releaseDate = '',
    this.metaSource = '',
    this.estimatedMinutes,
    this.hasOfficial = false,
    this.origin = 'official',
    this.ownerId = '',
    this.creatorName = '',
    this.reviewStatus = 'approved',
    this.communityCount = 0,
    this.likeCount = 0,
    this.traditionalChineseTitle = '',
    required this.created,
    required this.updated,
  });

  factory GameModel.fromPBRecord(dynamic record) {
    debugPrint('   🔍 解析游戏记录: id=${record.id}');

    final title = _safeGetString(record, 'title');
    final description = _safeGetString(record, 'description');
    final coverUrl = _extractCoverUrl(record);
    final bannerUrl = _extractBannerUrl(record);
    final tags = _parseTags(record);
    final downloadUrl = _safeGetString(record, 'downloadUrl');
    final status = _safeGetString(record, 'status');
    final developer = _safeGetStringFallback(record, ['developer', 'Developer']);
    final screenshotUrls = _extractScreenshotUrls(record);
    final originalTitle = _safeGetString(record, 'originalTitle');
    final englishTitle = _safeGetString(record, 'englishTitle');
    final version = _safeGetString(record, 'version');
    final versionNote = _safeGetString(record, 'versionNote');
    final installCount = _safeGetInt(record, 'installCount');
    // 云端沉淀的元数据：<=0 / 空串一律归一化成 null，便于判定「云端有没有」
    final rating = _safeGetPositiveDouble(record, 'rating');
    final voteCount = _safeGetPositiveInt(record, 'voteCount');
    final releaseDate = _safeGetString(record, 'releaseDate');
    final metaSource = _safeGetString(record, 'metaSource');
    final estimatedMinutes = _safeGetPositiveInt(record, 'estimatedMinutes');
    final hasOfficial = _safeGetBool(record, 'has_official');
    // 发布 / 归属（v4.4）：缺字段时全部落到安全默认值，对既有调用点零破坏
    final originRaw = _safeGetString(record, 'origin');
    final origin = originRaw.isEmpty ? 'official' : originRaw;
    final ownerId = _safeGetString(record, 'owner');
    final creatorName = _safeGetString(record, 'creator_name');
    final reviewRaw = _safeGetString(record, 'review_status');
    final reviewStatus = reviewRaw.isEmpty ? 'approved' : reviewRaw;
    final communityCount = _safeGetInt(record, 'community_count');
    final likeCount = _safeGetInt(record, 'like_count');
    final traditionalChineseTitle =
        _safeGetString(record, 'traditionalChineseTitle');

    debugPrint('      → title: "$title"');
    debugPrint(
        '      → description: ${description.isNotEmpty ? '"${description.length > 30 ? "${description.substring(0, 30)}..." : description}"' : "(空)"}');
    debugPrint('      → coverUrl: ${coverUrl.isNotEmpty ? coverUrl : "(空)"}');
    debugPrint('      → tags: $tags');
    debugPrint(
        '      → downloadUrl: ${downloadUrl.isNotEmpty ? downloadUrl : "(空)"}');
    debugPrint(
        '      → developer: ${developer.isNotEmpty ? developer : "(空)"}');
    debugPrint(
        '      → screenshotUrls: ${screenshotUrls.isNotEmpty ? "${screenshotUrls.length}张" : "(空)"}');

    return GameModel(
      id: record.id,
      title: title,
      description: description,
      coverUrl: coverUrl,
      bannerUrl: bannerUrl,
      tags: tags,
      downloadUrl: downloadUrl,
      status: status,
      developer: developer,
      screenshotUrls: screenshotUrls,
      originalTitle: originalTitle,
      englishTitle: englishTitle,
      version: version,
      versionNote: versionNote,
      installCount: installCount,
      rating: rating,
      voteCount: voteCount,
      releaseDate: releaseDate,
      metaSource: metaSource,
      estimatedMinutes: estimatedMinutes,
      hasOfficial: hasOfficial,
      origin: origin,
      ownerId: ownerId,
      creatorName: creatorName,
      reviewStatus: reviewStatus,
      communityCount: communityCount,
      likeCount: likeCount,
      traditionalChineseTitle: traditionalChineseTitle,
      created: DateTime.tryParse(record.created) ?? DateTime.now(),
      updated: DateTime.tryParse(record.updated) ?? DateTime.now(),
    );
  }

  static String _safeGetString(dynamic record, String field) {
    try {
      return record.getStringValue(field);
    } catch (_) {
      return '';
    }
  }

  /// 安全读取 number 字段（字段缺失或类型不符时返回 0）
  static int _safeGetInt(dynamic record, String field) {
    try {
      final value = record.data[field];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// 安全读取 bool 字段（字段缺失 / 类型不符 / 字段不存在一律返回 false）
  ///
  /// 用于 `has_official`：该字段在旧库中可能缺失，PB 也允许返回 0/1 形态。
  static bool _safeGetBool(dynamic record, String field) {
    try {
      final value = record.data[field];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final v = value.trim().toLowerCase();
        return v == 'true' || v == '1';
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 安全读取 number 字段，<=0 一律视为「云端无数据」（PB number 默认 0）
  static double? _safeGetPositiveDouble(dynamic record, String field) {
    try {
      final value = record.data[field];
      final double? parsed;
      if (value is num) {
        parsed = value.toDouble();
      } else if (value is String) {
        parsed = double.tryParse(value);
      } else {
        parsed = null;
      }
      if (parsed == null || parsed <= 0) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  /// 安全读取整数 number 字段，<=0 视为「云端无数据」
  static int? _safeGetPositiveInt(dynamic record, String field) {
    try {
      final value = record.data[field];
      final int? parsed;
      if (value is int) {
        parsed = value;
      } else if (value is num) {
        parsed = value.toInt();
      } else if (value is String) {
        parsed = int.tryParse(value);
      } else {
        parsed = null;
      }
      if (parsed == null || parsed <= 0) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  /// 按优先级依次尝试多个字段名，返回第一个非空值
  /// 用于兼容 PB 字段命名变更（如 Developer → developer）
  static String _safeGetStringFallback(dynamic record, List<String> fields) {
    for (final field in fields) {
      final value = _safeGetString(record, field);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  /// 从 PB record 提取封面 URL
  /// 优先尝试 'cover'（标准命名），再回退 'coverUrl'（旧命名）
  static String _extractCoverUrl(dynamic record) {
    for (final field in ['cover', 'coverUrl']) {
      try {
        final value = record.getStringValue(field);
        if (value != null && value.isNotEmpty) {
          return '$_pbBaseUrl/api/files/games/${record.id}/$value';
        }
      } catch (_) {}
    }
    return '';
  }

  /// 从 PB record 提取横幅封面 URL（bannerUrl file 字段，2026-10-05 新增）
  ///
  /// ⚠️ 兼容：老记录无该字段时 getStringValue 抛错 → 安全返回空串
  /// （与 [_extractCoverUrl] 同一套防御）。
  static String _extractBannerUrl(dynamic record) {
    try {
      final value = record.getStringValue('bannerUrl');
      if (value != null && value.isNotEmpty) {
        return '$_pbBaseUrl/api/files/games/${record.id}/$value';
      }
    } catch (_) {}
    return '';
  }

  /// 从 PB record 的 screenshots 多文件字段提取完整 URL 列表
  static List<String> _extractScreenshotUrls(dynamic record) {
    final urls = <String>[];
    try {
      // PB 多文件字段：getListValue 返回文件名列表
      final files = record.getListValue('screenshots');
      if (files != null && files is List && files.isNotEmpty) {
        for (final file in files) {
          final fileName = file.toString();
          if (fileName.isNotEmpty) {
            urls.add('$_pbBaseUrl/api/files/games/${record.id}/$fileName');
          }
        }
      }
    } catch (e) {
      debugPrint('[MODEL] ⚠️ screenshots字段解析异常: $e');
    }

    if (urls.isNotEmpty) {
      debugPrint('[MODEL] ✅ 截图URL解析成功: ${urls.length}张');
    }
    return urls;
  }

  static List<String> _parseTags(dynamic record) {
    debugPrint('[MODEL]   解析tags字段...');

    try {
      final rawTags = record.getListValue('tags');
      debugPrint(
          '[MODEL]     getListValue结果: $rawTags (类型: ${rawTags.runtimeType})');

      if (rawTags != null && rawTags is List && rawTags.isNotEmpty) {
        final result = List<String>.from(rawTags.map((t) => t.toString()));
        debugPrint('[MODEL]   ✅ tags解析成功 (List<String>.from): $result');
        return result;
      }
    } catch (e, stackTrace) {
      debugPrint('[MODEL]     ⚠️ getListValue异常: $e');
      debugPrint('[MODEL]     堆栈: $stackTrace');
    }

    try {
      final tagsStr = record.getStringValue('tags');
      debugPrint('[MODEL]     getStringValue结果: "$tagsStr"');
      if (tagsStr != null && tagsStr.isNotEmpty) {
        final result = tagsStr
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        debugPrint('[MODEL]   ✅ tags(字符串)解析成功: $result');
        return result;
      }
    } catch (e) {
      debugPrint('[MODEL]     ⚠️ getStringValue失败: $e');
    }

    debugPrint('[MODEL]   ⚠️ tags字段为空或不存在，返回空数组');
    return [];
  }

  static String get _pbBaseUrl => PBConfig.baseUrl;

  bool get hasCover => coverUrl.isNotEmpty;
  bool get hasScreenshots => screenshotUrls.isNotEmpty;

  /// 云端是否已沉淀元数据（评分 / 评分人数 / 发售日 任一有效）
  ///
  /// true → 探索页/月历/推荐直接读云端，不再触发元数据抓取。
  bool get hasCloudMetadata =>
      rating != null ||
      voteCount != null ||
      estimatedMinutes != null ||
      releaseDate.isNotEmpty;

  // ---------- 发布 / 归属语义（v4.4）----------

  /// 是否为用户【发布】的作品（PB `origin = "user"`）
  bool get isUserWork => origin == 'user';

  /// 审核已通过（对全部用户可见）
  bool get isReviewApproved => reviewStatus == 'approved';

  /// 审核中（仅发布者本人与管理员可见）
  bool get isReviewPending => reviewStatus == 'pending';

  /// 已驳回（详情页 / 【我的】应展示驳回理由）
  bool get isReviewRejected => reviewStatus == 'rejected';

  /// 编辑中（统一审核机制：已进库作品下架暂存，仅作者可见）
  bool get isReviewEditing => reviewStatus == 'editing';

  /// 删除待审（统一审核机制：删除申请等管理员裁决，仅作者可见）
  bool get isReviewPendingDelete => reviewStatus == 'pending_delete';

  /// 当前用户能否**编辑**本作品
  ///
  /// 与 `games.updateRule` 同构（统一审核机制后）：
  /// 非 `approved`/`pending_delete` 记录可直接改字段；
  /// `approved` 记录需先经「发起编辑」转换（PATCH review_status=editing）。
  /// ⚠️ 规则不满足时 PB 返回 **404 而不是 403**，故必须在客户端预判，
  /// 否则用户点了「编辑」才失败。
  bool canEditAsOwner(String currentUserId) =>
      currentUserId.isNotEmpty &&
      ownerId == currentUserId &&
      isUserWork &&
      !isReviewPendingDelete;

  /// 当前用户能否**删除**本作品
  ///
  /// 与 `games.deleteRule` 同构（统一审核机制后）：
  /// `approved`/`pending_delete` 记录禁直接删（走申请删除流程）。
  bool canDeleteDirectly(String currentUserId) =>
      currentUserId.isNotEmpty &&
      ownerId == currentUserId &&
      isUserWork &&
      !isReviewApproved &&
      !isReviewPendingDelete;

  /// 当前用户是否为本作品的管理者（显示「删除」类入口用；实际行为按状态分流）
  bool canDeleteAsOwner(String currentUserId) =>
      currentUserId.isNotEmpty && ownerId == currentUserId && isUserWork;

  /// 全部别名（日语 / 英语 / 繁中）去重后的展示列表，空值自动剔除
  List<String> get aliasTitles => <String>{
        if (originalTitle.trim().isNotEmpty) originalTitle.trim(),
        if (englishTitle.trim().isNotEmpty) englishTitle.trim(),
        if (traditionalChineseTitle.trim().isNotEmpty)
          traditionalChineseTitle.trim(),
      }.toList();

  GameModel copyWith({
    String? id,
    String? title,
    String? description,
    String? coverUrl,
    List<String>? tags,
    String? downloadUrl,
    String? status,
    String? developer,
    List<String>? screenshotUrls,
    String? originalTitle,
    String? englishTitle,
    String? version,
    String? versionNote,
    int? installCount,
    double? rating,
    int? voteCount,
    String? releaseDate,
    String? metaSource,
    int? estimatedMinutes,
    bool? hasOfficial,
    String? origin,
    String? ownerId,
    String? creatorName,
    String? reviewStatus,
    int? communityCount,
    int? likeCount,
    String? traditionalChineseTitle,
    DateTime? created,
    DateTime? updated,
  }) {
    return GameModel(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      coverUrl: coverUrl ?? this.coverUrl,
      tags: tags ?? this.tags,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      status: status ?? this.status,
      developer: developer ?? this.developer,
      screenshotUrls: screenshotUrls ?? this.screenshotUrls,
      originalTitle: originalTitle ?? this.originalTitle,
      englishTitle: englishTitle ?? this.englishTitle,
      version: version ?? this.version,
      versionNote: versionNote ?? this.versionNote,
      installCount: installCount ?? this.installCount,
      rating: rating ?? this.rating,
      voteCount: voteCount ?? this.voteCount,
      releaseDate: releaseDate ?? this.releaseDate,
      metaSource: metaSource ?? this.metaSource,
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
      hasOfficial: hasOfficial ?? this.hasOfficial,
      origin: origin ?? this.origin,
      ownerId: ownerId ?? this.ownerId,
      creatorName: creatorName ?? this.creatorName,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      communityCount: communityCount ?? this.communityCount,
      likeCount: likeCount ?? this.likeCount,
      traditionalChineseTitle:
          traditionalChineseTitle ?? this.traditionalChineseTitle,
      created: created ?? this.created,
      updated: updated ?? this.updated,
    );
  }
}
