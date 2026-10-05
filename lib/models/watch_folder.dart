import '../utils/import_completeness.dart';

/// 监控文件夹数据模型
class WatchFolder {
  final String path;
  final bool enabled;
  final DateTime addedAt;
  final int gameCount;
  final List<String> excludePatterns;
  final DateTime? lastScanAt;

  WatchFolder({
    required this.path,
    this.enabled = true,
    required this.addedAt,
    this.gameCount = 0,
    List<String>? excludePatterns,
    this.lastScanAt,
  }) : excludePatterns = excludePatterns ?? defaultExcludePatterns;

  /// 默认排除目录关键词
  static const List<String> defaultExcludePatterns = [
    'patch',
    'save',
    'config',
    'sound',
    'cg',
    'bg',
    'voice',
    'movie',
    'bgm',
    'system',
    'update',
    'doc',
    'manual',
    'support',
    '_temp_',
    'crash',
    'log',
    'cache',
    'temp',
  ];

  Map<String, dynamic> toJson() => {
        'path': path,
        'enabled': enabled,
        'added_at': addedAt.toIso8601String(),
        'game_count': gameCount,
        'exclude_patterns': excludePatterns,
        'last_scan_at': lastScanAt?.toIso8601String(),
      };

  factory WatchFolder.fromJson(Map<String, dynamic> json) {
    return WatchFolder(
      path: json['path'] as String,
      enabled: json['enabled'] as bool? ?? true,
      addedAt: DateTime.tryParse(json['added_at'] as String? ?? '') ??
          DateTime.now(),
      gameCount: json['game_count'] as int? ?? 0,
      excludePatterns: (json['exclude_patterns'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          defaultExcludePatterns,
      lastScanAt: json['last_scan_at'] == null
          ? null
          : DateTime.tryParse(json['last_scan_at'] as String),
    );
  }

  WatchFolder copyWith({
    String? path,
    bool? enabled,
    DateTime? addedAt,
    int? gameCount,
    List<String>? excludePatterns,
    DateTime? lastScanAt,
  }) {
    return WatchFolder(
      path: path ?? this.path,
      enabled: enabled ?? this.enabled,
      addedAt: addedAt ?? this.addedAt,
      gameCount: gameCount ?? this.gameCount,
      excludePatterns: excludePatterns ?? this.excludePatterns,
      lastScanAt: lastScanAt ?? this.lastScanAt,
    );
  }
}

/// 自动导入模式
enum AutoImportMode {
  /// 自动入库：发现新游戏后直接入库
  silent,

  /// 通知确认：发现新游戏后加入候选队列，等待用户确认
  confirm,
}

/// 候选游戏处理状态机（对齐批量导入 GameTaskStatus）
enum CandidateTaskStatus {
  /// 已发现，等待元数据富化
  pending,

  /// 正在抓取元数据
  processing,

  /// 元数据就绪，可入库
  ready,

  /// 元数据抓取失败（可重试或手动入库）
  failed,
}

/// 发现的候选游戏
///
/// 字段结构与批量导入的 BatchGameItem 对齐：
/// - originalTitle：从文件夹名清洗得到（不可变）
/// - title：当前标题（可被用户编辑）
/// - metadata：MIX 元数据抓取结果（fetchGameMixed）
/// - 可编辑字段：tags / description / developer / subtitle
/// - 状态机：pending → processing → ready / failed
class ImportCandidate {
  final String dirPath;

  /// 原始标题（从文件夹名清洗，不可变）
  final String originalTitle;

  /// 当前标题（用户可编辑，初始 = originalTitle）
  String title;

  /// 元数据抓取到的标准标题（用于双标题切换）
  String? metadataTitle;

  /// MIX 元数据抓取结果
  Map<String, dynamic>? metadata;

  /// 处理状态
  CandidateTaskStatus taskStatus;

  /// 失败原因（taskStatus == failed 时非空）
  String? errorMessage;

  /// 元数据源 ID 硬冲突（入库时自动跳过）
  bool isHardDuplicate;

  /// 临时下载的封面文件路径
  String? coverFilePath;

  /// 检测到的启动程序（相对路径）
  String? launchExe;

  // ===== 用户可编辑字段 =====
  List<String> tags;
  String description;
  String developer;
  String subtitle;

  // ===== 识别信息 =====
  final double confidence;
  final DateTime discoveredAt;
  final String engineType;
  final String? mainExeName;
  final String reasonSummary;

  /// 排重软警告（如同名游戏可能重复）。非空时 UI 可提示用户，但不阻止导入。
  String? duplicateWarning;

  bool imported;
  bool ignored;

  ImportCandidate({
    required this.dirPath,
    required String inferredTitle,
    required this.confidence,
    required this.discoveredAt,
    this.metadataTitle,
    this.metadata,
    this.taskStatus = CandidateTaskStatus.pending,
    this.errorMessage,
    this.isHardDuplicate = false,
    this.coverFilePath,
    this.launchExe,
    this.tags = const [],
    this.description = '',
    this.developer = '',
    this.subtitle = '',
    this.engineType = 'unknown',
    this.mainExeName,
    this.reasonSummary = '',
    this.duplicateWarning,
    this.imported = false,
    this.ignored = false,
  })  : originalTitle = inferredTitle,
        title = inferredTitle;

  // ===== 便捷访问器（从 metadata 提取，对齐批量导入用法）=====

  /// 元数据中的封面 URL
  String? get coverUrl {
    final url = metadata?['cover_url']?.toString();
    return (url != null && url.startsWith('http')) ? url : null;
  }

  /// 元数据源平台（VNDB / Bangumi / MIX 等）
  String get metadataSource => metadata?['platform']?.toString() ?? '';

  /// 元数据源 ID
  String get metadataSourceId => metadata?['platform_id']?.toString() ?? '';

  /// 截图 URL 列表
  List<String> get screenshotUrls {
    final urls = metadata?['screenshot_urls'];
    if (urls is List) {
      return urls.map((e) => e.toString()).toList();
    }
    return const [];
  }

  /// 是否可在原标题与元数据标题间切换
  bool get canToggleTitle =>
      metadataTitle != null &&
      metadataTitle!.isNotEmpty &&
      metadataTitle != originalTitle;

  /// 入库时实际使用的标题（title 已被用户编辑时优先）
  String get effectiveTitle => title.isNotEmpty ? title : originalTitle;

  /// 数据完整性判定（2026-10-03）：封面/简介任一缺失 = 数据不全。
  /// 返回缺失字段名列表（如 ['封面']），空列表 = 齐全。
  /// 实时计算：批量入库 / 静默自动入库时评估，用户补全后再次确认即通过。
  List<String> get missingCoreFields => missingCoreDataFields(
        coverFilePath: coverFilePath,
        coverUrl: coverUrl,
        description: description,
      );

  Map<String, dynamic> toJson() => {
        'dir_path': dirPath,
        'inferred_title': title, // 持久化当前标题（向后兼容旧字段名）
        'original_title': originalTitle,
        'metadata_title': metadataTitle,
        'metadata': metadata,
        'task_status': taskStatus.name,
        'error_message': errorMessage,
        'is_hard_duplicate': isHardDuplicate,
        'cover_file_path': coverFilePath,
        'launch_exe': launchExe,
        'tags': tags,
        'description': description,
        'developer': developer,
        'subtitle': subtitle,
        'confidence': confidence,
        'discovered_at': discoveredAt.toIso8601String(),
        'engine_type': engineType,
        'main_exe_name': mainExeName,
        'reason_summary': reasonSummary,
        'duplicate_warning': duplicateWarning,
        'imported': imported,
        'ignored': ignored,
      };

  factory ImportCandidate.fromJson(Map<String, dynamic> json) {
    final originalTitle =
        json['original_title'] as String? ?? json['inferred_title'] as String;
    return ImportCandidate(
      dirPath: json['dir_path'] as String,
      inferredTitle: json['inferred_title'] as String? ?? originalTitle,
      metadataTitle: json['metadata_title'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      taskStatus: CandidateTaskStatus.values.firstWhere(
        (s) => s.name == json['task_status'],
        orElse: () => CandidateTaskStatus.pending,
      ),
      errorMessage: json['error_message'] as String?,
      isHardDuplicate: json['is_hard_duplicate'] as bool? ?? false,
      coverFilePath: json['cover_file_path'] as String?,
      launchExe: json['launch_exe'] as String?,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      description: json['description'] as String? ?? '',
      developer: json['developer'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      discoveredAt:
          DateTime.tryParse(json['discovered_at'] as String? ?? '') ??
              DateTime.now(),
      engineType: json['engine_type'] as String? ?? 'unknown',
      mainExeName: json['main_exe_name'] as String?,
      reasonSummary: json['reason_summary'] as String? ?? '',
      duplicateWarning: json['duplicate_warning'] as String?,
      imported: json['imported'] as bool? ?? false,
      ignored: json['ignored'] as bool? ?? false,
    );
  }
}
