/// 归档清单 `meta.json` 的数据模型与序列化。
///
/// ## 定位
///
/// 归档目录的**唯一事实源**。`game.json` 只存「指针 + 状态」三个字段
/// （`storage_state` / `archive_dir` / `archive_at`），归档的详细元数据一律在这里。
/// 理由：① `game.json` 被高频读写，不该塞大结构；② 归档包要能**独立迁移到别的
/// 机器**，清单必须跟着包走。
///
/// ## 目录布局（方案 §4.2）
///
/// ```
/// <归档库根>/<dirNameFromTitle(标题)>/
///   latest.json                     ← 指向最新归档的指针
///   <时间戳>_<state>/               ← 例：2026-10-02_20-45-11_packed
///     meta.json                     ← 本文件的落盘形态（写它 = 归档完成）
///     appdata.7z                    ← 软件侧游戏数据
///     saves.7z                      ← 提取并压缩后的存档
///     body.7z                       ← 游戏本体（仅 packed 态存在）
/// ```
///
/// 🔴 **`meta.json` 是完成标记**：归档过程先建 `<时间戳>_<state>.partial/`，
/// 全部成功后才改名并把 `meta.json` 写进去。因此**目录存在但 `meta.json` 缺失
/// = 半成品**，可安全清理（Phase 0 实测：7z 自己不会产生这类标记，M3 必须由
/// Dart 侧实现）。
///
/// 🔴 本文件**刻意不 import `package:flutter/*`**，以便用 `dart.exe` 直接加载真实类
/// 做运行期验证（本环境 `flutter test` 跑不通）。改动时请保持这一约束。
library;

import 'dart:convert';

/// 归档包内的单个分片（appdata / saves / body 各是一份 7z）。
class ArchivePartInfo {
  /// 归档文件名（相对归档目录），如 `appdata.7z`
  final String archive;

  /// 归档文件字节数
  final int bytes;

  /// 归档内文件数（用于解包后比对，也是校验的一环）
  final int fileCount;

  /// 归档文件自身的 SHA256（小写十六进制）；空串 = 未计算
  final String sha256;

  /// 归档时的源根（`appdata` 用）。相对 `exeDir`，如 `Games/xxx`；
  /// 跨盘/外部路径则存绝对路径。
  final String root;

  /// 显式排除的条目（相对源根）。目前为 `.ctgame` 与 `saves/`
  /// —— 前者是无数据价值的在库标记（且磁盘上的原件始终保留），
  /// 后者单独打包成 `saves.7z`，避免双份占用。
  final List<String> excluded;

  /// 存档条目映射（仅 `saves` 用）。
  ///
  /// 🔴 **还原靠它**：7z 归档内不能直接存盘符，因此存档在包内被映射到
  /// `stage` 这种「无盘符」路径，原始绝对路径必须完整保留在本表里。
  final List<SaveEntryRef> entries;

  const ArchivePartInfo({
    required this.archive,
    this.bytes = 0,
    this.fileCount = 0,
    this.sha256 = '',
    this.root = '',
    this.excluded = const [],
    this.entries = const [],
  });

  factory ArchivePartInfo.fromJson(Map<String, dynamic> json) {
    return ArchivePartInfo(
      archive: json['archive'] as String? ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
      sha256: json['sha256'] as String? ?? '',
      root: json['root'] as String? ?? '',
      excluded: (json['excluded'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      entries: (json['entries'] as List?)
              ?.whereType<Map>()
              .map((e) => SaveEntryRef.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'archive': archive,
        'bytes': bytes,
        'file_count': fileCount,
        'sha256': sha256,
        if (root.isNotEmpty) 'root': root,
        if (excluded.isNotEmpty) 'excluded': excluded,
        if (entries.isNotEmpty) 'entries': entries.map((e) => e.toJson()).toList(),
      };
}

/// 单个存档条目的映射：原始绝对路径 ↔ 归档内路径。
class SaveEntryRef {
  /// 原始绝对路径（文件或目录）
  final String path;

  /// 原始大小（字节）；目录则为其递归总大小
  final int size;

  /// 归档内的相对路径（相对 `saves.7z` 根）
  final String stage;

  /// `true` = 原条目是目录
  final bool isDir;

  const SaveEntryRef({
    required this.path,
    this.size = 0,
    required this.stage,
    this.isDir = false,
  });

  factory SaveEntryRef.fromJson(Map<String, dynamic> json) => SaveEntryRef(
        path: json['path'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        stage: json['stage'] as String? ?? '',
        isDir: json['is_dir'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        if (size > 0) 'size': size,
        'stage': stage,
        if (isDir) 'is_dir': true,
      };
}

/// 游戏本体分片（仅 `packed` 态存在）。
class ArchiveBodyInfo {
  final String archive;
  final int bytes;

  /// 解包后的字节数 —— 解包前的磁盘空间预检用**精确值**，不用估算
  final int unpackedBytes;
  final int fileCount;
  final String sha256;

  /// 解包目标默认位置（原始本体目录的绝对路径）
  final String originalDir;

  /// 启动程序（相对 [originalDir]）
  final String launchPath;

  /// 分卷清单；一期不用分卷（Phase 0 结论：`extract_manager` 不认 `.7z.001`），
  /// 保留字段是为二期网盘上传可能需要的分卷留出位置。
  final List<String> volumes;

  const ArchiveBodyInfo({
    required this.archive,
    this.bytes = 0,
    this.unpackedBytes = 0,
    this.fileCount = 0,
    this.sha256 = '',
    this.originalDir = '',
    this.launchPath = '',
    this.volumes = const [],
  });

  factory ArchiveBodyInfo.fromJson(Map<String, dynamic> json) => ArchiveBodyInfo(
        archive: json['archive'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        unpackedBytes: (json['unpacked_bytes'] as num?)?.toInt() ?? 0,
        fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
        sha256: json['sha256'] as String? ?? '',
        originalDir: json['original_dir'] as String? ?? '',
        launchPath: json['launch_path'] as String? ?? '',
        volumes:
            (json['volumes'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
      );

  Map<String, dynamic> toJson() => {
        'archive': archive,
        'bytes': bytes,
        'unpacked_bytes': unpackedBytes,
        'file_count': fileCount,
        'sha256': sha256,
        if (originalDir.isNotEmpty) 'original_dir': originalDir,
        if (launchPath.isNotEmpty) 'launch_path': launchPath,
        if (volumes.isNotEmpty) 'volumes': volumes,
      };
}

/// 归档清单。
class ArchiveManifest {
  /// 清单 schema 版本。与 `game.json` 的 `format_version` 无关，独立演进。
  static const int currentSchema = 1;

  /// 落盘文件名
  static const String fileName = 'meta.json';

  /// 归档状态标记（目录名后缀）
  static const String stateSealed = 'sealed';
  static const String statePacked = 'packed';

  final int schema;

  /// 稳定主键（`game.json` 的 `game_id`）——跨改名可用
  final String gameId;

  /// 展示用标题
  final String title;

  /// `sealed` | `packed`
  final String state;

  /// 归档时间（ISO8601，带本地时区偏移）
  final String createdAt;

  /// 产生该归档的应用版本
  final String appVersion;

  final ArchivePartInfo? appdata;
  final ArchivePartInfo? saves;
  final ArchiveBodyInfo? body;

  const ArchiveManifest({
    this.schema = currentSchema,
    required this.gameId,
    required this.title,
    required this.state,
    required this.createdAt,
    this.appVersion = '',
    this.appdata,
    this.saves,
    this.body,
  });

  /// 宽松解析：字段缺失一律走默认值，**绝不抛异常**。
  ///
  /// 这样 `GameStorageStateController` 可以用「能否解析出 state」当作
  /// 「归档是否仍可信」的判据，而不必区分"文件损坏"与"字段缺省"。
  factory ArchiveManifest.fromJson(Map<String, dynamic> json) {
    return ArchiveManifest(
      schema: (json['schema'] as num?)?.toInt() ?? currentSchema,
      gameId: json['game_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      state: json['state'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      appVersion: json['app_version'] as String? ?? '',
      appdata: json['appdata'] is Map
          ? ArchivePartInfo.fromJson(
              Map<String, dynamic>.from(json['appdata'] as Map))
          : null,
      saves: json['saves'] is Map
          ? ArchivePartInfo.fromJson(
              Map<String, dynamic>.from(json['saves'] as Map))
          : null,
      body: json['body'] is Map
          ? ArchiveBodyInfo.fromJson(
              Map<String, dynamic>.from(json['body'] as Map))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'game_id': gameId,
        'title': title,
        'state': state,
        'created_at': createdAt,
        'app_version': appVersion,
        if (appdata != null) 'appdata': appdata!.toJson(),
        if (saves != null) 'saves': saves!.toJson(),
        if (body != null) 'body': body!.toJson(),
      };

  /// 供落盘使用（带缩进，便于用户/排障时直接阅读）
  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 从文本解析；失败返回 `null`（不抛）。
  static ArchiveManifest? tryParse(String text) {
    if (text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final m = ArchiveManifest.fromJson(Map<String, dynamic>.from(decoded));
      // state 是清单的"有没有归档"判据，缺失即视为无效清单
      if (m.state.isEmpty) return null;
      return m;
    } catch (_) {
      return null;
    }
  }

  /// 校验清单的自洽性，返回问题清单（空 = 通过）。
  ///
  /// 只做**清单内部**的自洽检查，不碰磁盘。磁盘层面的校验（文件是否存在、
  /// `7z t` 是否通过、文件数是否吻合）由 `GameArchiveService.verify()` 负责。
  List<String> validate() {
    final problems = <String>[];
    if (state != stateSealed && state != statePacked) {
      problems.add('state 非法: "$state"（应为 $stateSealed 或 $statePacked）');
    }
    if (gameId.isEmpty) problems.add('game_id 缺失');
    if (createdAt.isEmpty) problems.add('created_at 缺失');
    if (appdata == null && saves == null && body == null) {
      problems.add('appdata / saves / body 三者皆空 —— 这不是一份有效归档');
    }
    if (state == statePacked && body == null) {
      problems.add('state=packed 但缺少 body 段');
    }
    if (appdata != null && appdata!.archive.isEmpty) {
      problems.add('appdata.archive 为空');
    }
    if (saves != null && saves!.archive.isEmpty) {
      problems.add('saves.archive 为空');
    }
    for (final e in saves?.entries ?? const <SaveEntryRef>[]) {
      if (e.path.isEmpty || e.stage.isEmpty) {
        problems.add('saves.entries 存在缺失 path/stage 的条目');
        break;
      }
    }
    return problems;
  }

  /// 该归档包含的全部 7z 分片文件名
  List<String> get partArchives => [
        if (appdata != null && appdata!.archive.isNotEmpty) appdata!.archive,
        if (saves != null && saves!.archive.isNotEmpty) saves!.archive,
        if (body != null && body!.archive.isNotEmpty) body!.archive,
      ];

  /// 归档内声明的总文件数（校验用）
  int get declaredFileCount =>
      (appdata?.fileCount ?? 0) + (saves?.fileCount ?? 0) + (body?.fileCount ?? 0);
}
