import '../core/pb_config.dart';

/// 游戏资源获取方式（对应 PB `game_resources.kind`）
///
/// 🔴 **两套来源的边界（2026-10-01 澄清，勿再混淆）**：
/// - **官方/原生**：PB **`games`** 表自身携带的 `downloadUrl` + `version` +
///   `versionNote` + `installCount`。这是软件**从一开始就有**的下载方式，
///   数据从未迁移，安装链路走 `CloudInstallFlow`（OpenList 路径解析）。
///   `game_resources` 表里的 `kind=official` 是**同一套官方资源的另一条表达**，
///   用于承载"资源级"字段（`resource_type` / `platforms` / `download_count`）。
///   两者**不是竞争关系**：弹窗统一由 [OfficialResourceView] 呈现，
///   优先取 `games`（永远存在），`game_resources` 命中时**补充**其字段。
///   ⇒ 「获取」按钮**不该因为 `game_resources` 里没有 official 记录就判定无资源**。
/// - **用户分享**：`game_resources` 里 `kind=community & status=published` 的外链，
///   只能跳转，走「分享」弹窗。
enum ResourceKind {
  /// 官方来源：走 OpenList 网盘路径，客户端可直接下载安装
  official,

  /// 用户分享来源：外链，只能跳转
  community;

  static ResourceKind parse(String raw) =>
      raw == 'official' ? ResourceKind.official : ResourceKind.community;

  String get wire => name;
}

/// 资源审核状态（对应 PB `game_resources.status`）
enum ResourceStatus {
  /// 待审核
  pending,

  /// 已发布（对全部用户可见）
  published,

  /// 已驳回
  rejected,

  /// 已隐藏
  hidden,

  /// 编辑中（统一审核机制：已进库内容下架暂存，作者可改字段，
  /// 提交后回到 pending 重新审核；仅作者可见）
  editing,

  /// 删除待审（统一审核机制：删除申请已提交，管理员裁决前下架；
  /// 作者可撤回恢复 published。仅作者可见）
  pending_delete;

  static ResourceStatus parse(String raw) {
    switch (raw) {
      case 'published':
        return ResourceStatus.published;
      case 'rejected':
        return ResourceStatus.rejected;
      case 'hidden':
        return ResourceStatus.hidden;
      case 'editing':
        return ResourceStatus.editing;
      case 'pending_delete':
        return ResourceStatus.pending_delete;
      default:
        return ResourceStatus.pending;
    }
  }

  String get wire => name;

  String get label {
    switch (this) {
      case ResourceStatus.pending:
        return '审核中';
      case ResourceStatus.published:
        return '有效';
      case ResourceStatus.rejected:
        return '已驳回';
      case ResourceStatus.hidden:
        return '已隐藏';
      case ResourceStatus.editing:
        return '编辑中';
      case ResourceStatus.pending_delete:
        return '删除待审';
    }
  }

  /// 已进入探索库（删除需要管理员审核的状态）
  bool get isInLibrary => this == ResourceStatus.published;

  /// 未进库（可由作者直接删除，无需审核）
  bool get canDeleteDirectly =>
      this == ResourceStatus.pending ||
      this == ResourceStatus.rejected ||
      this == ResourceStatus.editing ||
      this == ResourceStatus.hidden;
}

/// 外链类型（对应 PB `game_resources.link_type`）
enum ResourceLinkType {
  netdisk,
  direct,
  other;

  static ResourceLinkType? parse(String raw) {
    for (final v in ResourceLinkType.values) {
      if (v.name == raw) return v;
    }
    return null;
  }

  String get wire => name;

  String get label {
    switch (this) {
      case ResourceLinkType.netdisk:
        return '网盘资源';
      case ResourceLinkType.direct:
        return '直链';
      case ResourceLinkType.other:
        return '其他';
    }
  }
}

/// 一部作品的一条「资源来源」。
///
/// 对应 PocketBase 集合 `game_resources`（`pbc_439050043`）。
/// official 记录走 `downloadPath`（OpenList 网盘路径，需经
/// `OpenListService.getGameDownloadUrl` 解析直链）；community 记录走 `url`（外链）。
class GameResourceModel {
  final String id;

  /// 关联作品 id（PB `game`，relation maxSelect:1）
  final String gameId;

  // ===== 基础 =====
  final ResourceKind kind;
  final String title;

  // ===== official 专用 =====
  /// OpenList 网盘路径（**不是**直链，会过期）
  final String downloadPath;
  final String version;
  final String versionNote;

  // ===== community 专用 =====
  final String url;
  final ResourceLinkType? linkType;
  final String netdiskProvider;
  final String extractCode;
  final String fileSize;

  // ===== 关联作品（expand 带出）=====
  /// 关联作品标题。**仅在查询时传了 `expand: 'game'` 才有值**
  /// （【我的】管理页需要显示「《作品名》」），否则为空串。
  final String gameTitle;

  // ===== 归属 / 展示 =====
  final String ownerId;
  final String ownerName;

  /// 分享者头像**文件名快照**（发布时从 users.avatar 定格）。
  ///
  /// 🔴 为什么是快照而不是 `expand=owner`：2026-10-01 线上实测，
  /// 普通用户视角 `expand=owner` 被 users 集合规则拦成空（跨用户不可读），
  /// 昵称/头像只能走发布时快照（owner_name / owner_avatar）。
  final String ownerAvatar;
  final String sourceNote;
  final String note;

  // ===== 审核 =====
  final ResourceStatus status;
  final String rejectReason;
  final int reportCount;

  // ===== 设计稿新增字段（2026-10-01 扩表）=====
  /// 资源类型（多选）：游戏本体 / 民间汉化 / 全年龄补丁 …
  final List<String> resourceTypes;

  /// 语言（多选）：简体中文 / 日本語 / English …
  final List<String> languages;

  /// 平台（多选）：Windows / Android / macOS …
  final List<String> platforms;

  /// 解压码（多个按解压顺序逗号分隔）
  final String unzipCode;

  /// 下载次数（系统累加，客户端只读）
  final int downloadCount;

  /// 点赞数（系统累加，客户端只读）
  final int likeCount;

  final DateTime created;
  final DateTime updated;

  const GameResourceModel({
    required this.id,
    this.gameId = '',
    this.kind = ResourceKind.community,
    this.title = '',
    this.downloadPath = '',
    this.version = '',
    this.versionNote = '',
    this.url = '',
    this.linkType,
    this.netdiskProvider = '',
    this.extractCode = '',
    this.fileSize = '',
    this.gameTitle = '',
    this.ownerId = '',
    this.ownerName = '',
    this.ownerAvatar = '',
    this.sourceNote = '',
    this.note = '',
    this.status = ResourceStatus.pending,
    this.rejectReason = '',
    this.reportCount = 0,
    this.resourceTypes = const [],
    this.languages = const [],
    this.platforms = const [],
    this.unzipCode = '',
    this.downloadCount = 0,
    this.likeCount = 0,
    required this.created,
    required this.updated,
  });

  factory GameResourceModel.fromPBRecord(dynamic record) {
    return GameResourceModel(
      id: record.id?.toString() ?? '',
      gameId: _safeGetString(record, 'game'),
      kind: ResourceKind.parse(_safeGetString(record, 'kind')),
      title: _safeGetString(record, 'title'),
      downloadPath: _safeGetString(record, 'download_path'),
      version: _safeGetString(record, 'version'),
      versionNote: _safeGetString(record, 'version_note'),
      url: _safeGetString(record, 'url'),
      linkType: ResourceLinkType.parse(_safeGetString(record, 'link_type')),
      netdiskProvider: _safeGetString(record, 'netdisk_provider'),
      extractCode: _safeGetString(record, 'extract_code'),
      fileSize: _safeGetString(record, 'file_size'),
      gameTitle: _extractExpandedGameTitle(record),
      ownerId: _safeGetString(record, 'owner'),
      ownerName: _safeGetString(record, 'owner_name'),
      ownerAvatar: _safeGetString(record, 'owner_avatar'),
      sourceNote: _safeGetString(record, 'source_note'),
      note: _safeGetString(record, 'note'),
      status: ResourceStatus.parse(_safeGetString(record, 'status')),
      rejectReason: _safeGetString(record, 'reject_reason'),
      reportCount: _safeGetInt(record, 'report_count'),
      resourceTypes: _safeGetList(record, 'resource_type'),
      languages: _safeGetList(record, 'languages'),
      platforms: _safeGetList(record, 'platforms'),
      unzipCode: _safeGetString(record, 'unzip_code'),
      downloadCount: _safeGetInt(record, 'download_count'),
      likeCount: _safeGetInt(record, 'like_count'),
      created: DateTime.tryParse(_safeGetString(record, 'created')) ??
          DateTime.now(),
      updated: DateTime.tryParse(_safeGetString(record, 'updated')) ??
          DateTime.now(),
    );
  }

  // ---------- 读取辅助 ----------

  static String _safeGetString(dynamic record, String field) {
    try {
      final v = record.getStringValue(field);
      return v ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 从 `expand['game']` 取关联作品标题。
  ///
  /// PB 的 expand 结果对 `maxSelect:1` 的 relation 是**单条 RecordModel**，
  /// 对多选才是 List ⇒ 两种形态都要兼容。
  /// 未 expand、或 `games` 的 View 规则未放行时取不到 ⇒ 返回空串，由 UI 回退。
  static String _extractExpandedGameTitle(dynamic record) {
    try {
      final expand = record.expand;
      if (expand is Map) {
        final g = expand['game'];
        if (g is List && g.isNotEmpty) return _safeGetString(g.first, 'title');
        if (g != null) return _safeGetString(g, 'title');
      }
    } catch (_) {}
    return '';
  }

  /// PB select 多选字段：优先 getListValue，回退按逗号切分
  ///
  /// ⚠️ 注意 `raw.toString()` 这一步不能省。`record.getStringValue()` 返回
  /// `dynamic`，若直接 `s.split(',').map(...).where(...)`，整条链都是
  /// `dynamic`，闭包会被推断成 `(dynamic) => dynamic`，而 `Iterable.where`
  /// 在运行时要求 `(dynamic) => bool` → 抛
  /// `type '(dynamic) => dynamic' is not a subtype of type '(dynamic) => bool'`。
  /// 这个异常会被下面的 catch 静默吞掉，表现为「多选字段永远解析为空」。
  /// 先 `toString()` 变成 `String`，`split` 即返回 `List<String>`，闭包类型随之确定。
  static List<String> _safeGetList(dynamic record, String field) {
    try {
      final v = record.getListValue(field);
      if (v is List && v.isNotEmpty) {
        return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      }
    } catch (_) {}
    try {
      final raw = record.getStringValue(field);
      if (raw != null) {
        final s = raw.toString();
        if (s.isNotEmpty) {
          return s
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}
    return const [];
  }

  static int _safeGetInt(dynamic record, String field) {
    try {
      final v = record.data[field];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // ---------- 语义 getter ----------

  /// 官方来源（可安装）
  bool get isOfficial => kind == ResourceKind.official;

  /// 用户分享来源（只能跳转）
  bool get isCommunity => kind == ResourceKind.community;

  /// 已发布（对全部用户可见）
  bool get isPublished => status == ResourceStatus.published;

  /// 是否有可解析的下载路径（official）
  bool get hasDownloadPath => downloadPath.trim().isNotEmpty;

  /// 是否有可跳转的外链（community）
  bool get hasUrl => url.trim().isNotEmpty;

  /// 展示用分享者名（official 的 owner 指向看板娘，owner_name 即为看板娘名）
  String get displayOwnerName => ownerName.trim();

  /// 分享者头像 URL（快照文件名 + owner 指向拼出；无头像/无 owner 返回 null）
  String? get ownerAvatarUrl {
    final f = ownerAvatar.trim();
    final oid = ownerId.trim();
    if (f.isEmpty || oid.isEmpty) return null;
    return '${PBConfig.baseUrl}/api/files/users/$oid/$f';
  }

  /// 网盘平台中文名
  String get netdiskProviderLabel => netdiskProviderLabelOf(netdiskProvider);

  /// 解压码列表（多个按逗号拆分，保持顺序）
  List<String> get unzipCodeList => unzipCode
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// 提取码是否有效（非空）
  bool get hasExtractCode => extractCode.trim().isNotEmpty;

  /// 版本展示文本：priority = versionNote > version
  String get versionLabel {
    if (versionNote.trim().isNotEmpty) return versionNote.trim();
    return version.trim();
  }

  /// 分享时间展示（yyyy-MM-dd）
  String get createdDateLabel {
    final y = created.year.toString().padLeft(4, '0');
    final m = created.month.toString().padLeft(2, '0');
    final d = created.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// 相对时间展示（设计稿「4 个月前」）
  ///
  /// 分享列表卡片上传者行下方用它，与设计一致。
  /// [now] 可注入，便于测试（生产环境不传，取 `DateTime.now()`）。
  String createdAgeLabel({DateTime? now}) {
    final ref = now ?? DateTime.now();
    final diff = ref.difference(created);
    if (diff.isNegative || diff.inHours < 1) return '刚刚';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    if (diff.inDays < 365) return '${diff.inDays ~/ 30} 个月前';
    return '${diff.inDays ~/ 365} 年前';
  }

  /// 网盘平台 wire → 中文名（静态，供未解析成模型的场景复用）
  static String netdiskProviderLabelOf(String wire) {
    switch (wire) {
      case 'baidu':
        return '百度网盘';
      case 'quark':
        return '夸克网盘';
      case 'aliyun':
        return '阿里云盘';
      case 'xunlei':
        return '迅雷云盘';
      case '115':
        return '115 网盘';
      case 'onedrive':
        return 'OneDrive';
      case 'mega':
        return 'MEGA';
      case 'google_drive':
        return 'Google Drive';
      case 'other':
        return '其他网盘';
      default:
        return '';
    }
  }

  /// 供 UI 展示的「构建 body」（新建/更新资源时用，只含用户可写字段）
  ///
  /// 刻意排除 `kind` / `status` / `owner` / `download_count` /
  /// `like_count` / `report_count` —— 这些由服务端规则与 Hook 管控，
  /// 客户端传入会被规则拦下或被 Hook 还原。
  Map<String, dynamic> toSubmitBody() {
    final body = <String, dynamic>{
      'title': title,
      'url': url,
      'extract_code': extractCode,
      'file_size': fileSize,
      'note': note,
      'unzip_code': unzipCode,
      'resource_type': resourceTypes,
      'languages': languages,
      'platforms': platforms,
    };
    if (linkType != null) body['link_type'] = linkType!.wire;
    if (netdiskProvider.isNotEmpty) body['netdisk_provider'] = netdiskProvider;
    if (version.isNotEmpty) body['version'] = version;
    return body;
  }

  GameResourceModel copyWith({
    String? id,
    String? gameId,
    ResourceKind? kind,
    String? title,
    String? downloadPath,
    String? version,
    String? versionNote,
    String? url,
    ResourceLinkType? linkType,
    String? netdiskProvider,
    String? extractCode,
    String? fileSize,
    String? gameTitle,
    String? ownerId,
    String? ownerName,
    String? ownerAvatar,
    String? sourceNote,
    String? note,
    ResourceStatus? status,
    String? rejectReason,
    int? reportCount,
    List<String>? resourceTypes,
    List<String>? languages,
    List<String>? platforms,
    String? unzipCode,
    int? downloadCount,
    int? likeCount,
    DateTime? created,
    DateTime? updated,
  }) {
    return GameResourceModel(
      id: id ?? this.id,
      gameId: gameId ?? this.gameId,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      downloadPath: downloadPath ?? this.downloadPath,
      version: version ?? this.version,
      versionNote: versionNote ?? this.versionNote,
      url: url ?? this.url,
      linkType: linkType ?? this.linkType,
      netdiskProvider: netdiskProvider ?? this.netdiskProvider,
      extractCode: extractCode ?? this.extractCode,
      fileSize: fileSize ?? this.fileSize,
      gameTitle: gameTitle ?? this.gameTitle,
      ownerId: ownerId ?? this.ownerId,
      ownerName: ownerName ?? this.ownerName,
      ownerAvatar: ownerAvatar ?? this.ownerAvatar,
      sourceNote: sourceNote ?? this.sourceNote,
      note: note ?? this.note,
      status: status ?? this.status,
      rejectReason: rejectReason ?? this.rejectReason,
      reportCount: reportCount ?? this.reportCount,
      resourceTypes: resourceTypes ?? this.resourceTypes,
      languages: languages ?? this.languages,
      platforms: platforms ?? this.platforms,
      unzipCode: unzipCode ?? this.unzipCode,
      downloadCount: downloadCount ?? this.downloadCount,
      likeCount: likeCount ?? this.likeCount,
      created: created ?? this.created,
      updated: updated ?? this.updated,
    );
  }

  static String get pbBaseUrl => PBConfig.baseUrl;
}

/// 「获取」弹窗的统一数据视图 —— 官方/原生资源。
///
/// ## 为什么需要这一层
///
/// 官方资源有**两个可能的来源**（见文件头 [ResourceKind] 的说明）：
/// 1. `games` 表自身（`downloadUrl` / `version` / `versionNote` / `installCount`）
///    —— 软件原生下载方式，**永远存在**，是安装链路的真正依据；
/// 2. `game_resources` 表 `kind=official` 的记录 —— 可选的"资源级"补充
///    （`resource_type` / `platforms` / `download_count` …）。
///
/// 🔴 改造前「获取」按钮**只看 (2)**，而该表 official 记录为 0 条 ⇒ 按钮
/// 被判为「无资源」而点不动，但其实 `games.downloadUrl` 一直在——
/// 这就是 2026-10-01 真机反馈「我明明有官方资源，却说没有」的根因。
///
/// 本视图的合并规则是**以 (1) 为准、由 (2) 补充**，缺哪边都不会导致"无资源"。
class OfficialResourceView {
  const OfficialResourceView({
    required this.downloadPath,
    required this.title,
    required this.version,
    required this.versionNote,
    required this.fileSize,
    required this.downloadCount,
    required this.ownerName,
    required this.resourceTypes,
    required this.platforms,
    required this.created,
    this.record,
  });

  /// OpenList 路径（原生：`games.downloadUrl`）—— 安装链路的真正依据
  final String downloadPath;

  /// 资源标题（默认「游戏本体」）
  final String title;

  /// 版本名
  final String version;

  /// 版本详情
  final String versionNote;

  /// 资源大小（原生来源无此字段时为空串，由调用方回退到本地预取）
  final String fileSize;

  /// 下载人数（来自 `game_resources.download_count`，无则 0）
  final int downloadCount;

  /// 分享者显示名（恒为看板娘）
  final String ownerName;

  /// 资源类型标签，默认「游戏本体」
  final List<String> resourceTypes;

  /// 平台标签，默认「Windows」
  final List<String> platforms;

  /// 归属时间（`games.created`）
  final DateTime created;

  /// 对应的 `game_resources` 记录（若有）；为 null 表示仅来自 `games`
  final GameResourceModel? record;

  /// 是否具备可安装的路径
  bool get canInstall => downloadPath.trim().isNotEmpty;

  /// 版本展示串（`versionNote` 优先，与 [GameResourceModel.versionLabel] 同规则）
  String get versionLabel =>
      versionNote.trim().isNotEmpty ? versionNote.trim() : version.trim();

  String get createdDateLabel {
    final m = created.month.toString().padLeft(2, '0');
    final d = created.day.toString().padLeft(2, '0');
    return '${created.year}-$m-$d';
  }

  /// 从原生 `games` 记录构造；[supplement] 为 `game_resources` 的 official 记录（可空）。
  ///
  /// [gameTitle] 用于兜底资源标题（无 `resource_type` 时显示「游戏本体」，
  /// 与设计稿一致，不用作品名）。
  factory OfficialResourceView.fromGame({
    required String downloadPath,
    required String version,
    required String versionNote,
    required int installCount,
    required DateTime created,
    GameResourceModel? supplement,
    String ownerName = '时之 汐乃',
  }) {
    final s = supplement;
    return OfficialResourceView(
      downloadPath: downloadPath,
      title: '游戏本体',
      // games 侧优先；仅在 games 为空时才用记录里的值，避免记录覆盖原生事实
      version: version.trim().isNotEmpty ? version.trim() : (s?.version ?? ''),
      versionNote: versionNote.trim().isNotEmpty
          ? versionNote.trim()
          : (s?.versionNote ?? ''),
      fileSize: s?.fileSize ?? '',
      downloadCount: s?.downloadCount ?? installCount,
      ownerName: ownerName,
      resourceTypes:
          (s != null && s.resourceTypes.isNotEmpty) ? s.resourceTypes : const [],
      platforms:
          (s != null && s.platforms.isNotEmpty) ? s.platforms : const [],
      created: created,
      record: s,
    );
  }
}
