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

/// 发现的候选游戏
class ImportCandidate {
  final String dirPath;
  final String inferredTitle;
  final double confidence;
  final DateTime discoveredAt;
  final String engineType;
  final String? mainExeName;
  final String reasonSummary;
  /// 排重软警告（如同名游戏可能重复）。非空时 UI 可提示用户，但不阻止导入。
  /// 由 AutoImportPipeline.processCandidate 通过 ImportDedupIndex 填充。
  final String? duplicateWarning;
  bool imported;
  bool ignored;

  ImportCandidate({
    required this.dirPath,
    required this.inferredTitle,
    required this.confidence,
    required this.discoveredAt,
    this.engineType = 'unknown',
    this.mainExeName,
    this.reasonSummary = '',
    this.duplicateWarning,
    this.imported = false,
    this.ignored = false,
  });

  Map<String, dynamic> toJson() => {
        'dir_path': dirPath,
        'inferred_title': inferredTitle,
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
    return ImportCandidate(
      dirPath: json['dir_path'] as String,
      inferredTitle: json['inferred_title'] as String,
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
