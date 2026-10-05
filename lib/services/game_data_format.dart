import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/portable_image_cache_manager.dart';
import '../core/path_helper.dart';
import 'game_launcher_detector.dart';
import 'cover_download_service.dart';
import '../utils/game_key.dart';
import '../utils/path_normalizer.dart';
import 'win32_file_attributes.dart';
import 'company_alias_store.dart';
import 'company_alias_pending.dart'; // ★ 会社归一化（v4）：命中后清理待审漏斗

class GameDataFormat {
  /// game.json 的 schema 版本（P2-2）。
  ///
  /// 🔴 v2（2026-09-19 游戏数据结构审查批 2）：引入稳定主键 `game_id`。
  /// 🔴 v3（2026-09-19 游戏数据结构审查批 4）：标题槽位收敛——
  ///    `metadata_title` 并入 `original_title` 后删除该键（P2-4）。
  /// 🔴 v4（2026-09-28 会社归一化 Phase 2）：新增**可选**字段 `company_id`
  ///    （会社词典解析结果，int，可空）。见
  ///    `docs/DEV/features/company_alias_normalization.md` §5。
  ///
  /// 🔴 **2026-10-02 游戏数据保存（存储状态）—— 刻意不升版本**
  ///    新增 3 个字段 `storage_state` / `archive_dir` / `archive_at`（均为可空
  ///    语义、有默认值），**版本号保持 4**。依据 ADR-012 的显式例外：纯新增
  ///    可空字段用 `?? 默认值` 读取即完全兼容，升版本只会触发一次全库写回
  ///    （有 I/O 成本与风险），收益为零。开发者 2026-10-02 深夜拍板接受该例外。
  ///    ⚠️ 后人若看到这里与 ADR-012 的"必须升版本"冲突，以本条为准 —— 这是
  ///    经开发者确认的**有意例外**，不是漏做迁移。
  ///    见 `docs/DEV/features/game_storage_state_implementation_plan.md` §5.2。
  ///
  /// 🔴 **2026-10-04 横幅封面（banner）—— 同上，刻意不升版本**
  ///    新增可空字段 `banner_file`（横幅封面文件名，空串 = 无横幅），版本号
  ///    保持 4。与 storage_state 同一例外依据：老文件无键 → `?? ''` 读取即
  ///    完全兼容；toJson 仅在非默认值时输出，避免全库无意义改写。
  ///    见 `docs/DEV/features/game_banner_cover.md`。
  ///
  /// 此前这个值从建立之日起**一直是 1**，而 `sessions` / `daily_play_log` /
  /// `title_locked` / `collection_ids` / `metadata_source*` 都是后期追加的字段——
  /// schema 一直在演进，版本号却停摆，等于没有承载点，任何"老文件缺新字段"
  /// 的情况都只能靠读取代码的 `?? 默认值` 兜着，谁也不知道某份 game.json
  /// 到底是哪个年代的产物。
  ///
  /// 🔴 维护纪律：字段新增 / 改名 / 语义变更时，必须同时
  /// ① 在 [_migrations] 追加一条迁移 ② 提升本值 ③ 补一条回归测试。
  ///    漏做 ① 的后果是：老用户的 game.json 永远停在旧版本号，
  ///    而新代码读到的是缺字段的 map（被默认值静默顶替，无任何日志）。
  static const int currentVersion = 4;
  static const String ctgameFileName = '.ctgame';
  static const String gameJsonFileName = 'game.json';
  static const String defaultCoverFileName = 'cover.png';

  /// schema 版本迁移链（P2-2）。
  ///
  /// key = 磁盘上的 `format_version`；value = 把该版本的 json 升到 `key + 1`
  /// 的纯变换（不落盘、不抛异常）。[migrateGameJsonMap] 从旧版本开始逐级应用，
  /// 直到 [currentVersion]。
  static final Map<int, Map<String, dynamic> Function(Map<String, dynamic>)>
      _migrations = <int, Map<String, dynamic> Function(Map<String, dynamic>)>{
    1: _migrateV1ToV2,
    2: _migrateV2ToV3,
    3: _migrateV3ToV4,
  };

  /// v1 → v2：为老的 game.json 补发稳定主键 `game_id`。
  ///
  /// 补发只做一次：迁移函数的产物由 [readGameJson] 写回磁盘，
  /// 之后版本号已经是 2，不会重复进入本函数。因此同一个游戏不会被
  /// 反复换 id（id 一旦落盘即终身不变）。
  static Map<String, dynamic> _migrateV1ToV2(Map<String, dynamic> json) {
    final existing = (json['game_id'] as String?)?.trim() ?? '';
    if (existing.isEmpty) {
      json['game_id'] = GameKey.generateId();
    }
    json['format_version'] = 2;
    return json;
  }

  /// v2 → v3：收敛「标题四件套」（P2-4）。
  ///
  /// 背景：`metadata_title`（抓取到的标准名）与 `original_title`（数据源原名）
  /// 在磁盘上是同一份数据的两个副本 —— [writeGameDir] 两个键一起写。
  /// 经全库核对，**没有任何读取方读 game.json 的 `metadata_title`**：
  /// 界面上的"双标题切换"读的是内存里的导入候选对象（WatchFolder /
  /// BatchGameItem），与这个落盘字段无关。于是它是一个纯写入型冗余字段，
  /// 只会让人误以为"磁盘上存了两套标题"。
  ///
  /// 迁移策略（**无损**）：
  /// - `original_title` 为空而 `metadata_title` 有值 → 先把值搬过去；
  /// - 然后删除 `metadata_title` 键。
  ///
  /// 迁移后标题系统只剩三个语义清晰的槽位（见 [GameJsonData.originalTitle]）：
  /// `title`（展示用，用户可改）/ `original_title`（数据源原名，只读）/
  /// `subtitle`（用户自定义副标题）。
  static Map<String, dynamic> _migrateV2ToV3(Map<String, dynamic> json) {
    final String legacy = (json['metadata_title'] as String?) ?? '';
    final String existing = (json['original_title'] as String?) ?? '';
    if (existing.isEmpty && legacy.isNotEmpty) {
      json['original_title'] = legacy;
    }
    json.remove('metadata_title');
    json['format_version'] = 3;
    return json;
  }

  /// v3 → v4：会社归一化（2026-09-28，`company_alias_normalization.md` §5）。
  ///
  /// 新增**可选**字段 `company_id`（会社词典 `CompanyAliasStore` 的解析结果，
  /// int，可空）。迁移本身**不动数据**，只升版本号：
  /// - 老文件缺该键 = 尚未解析；读取方一律按 null 容错，
  ///   由 `LocalGameRegistry` 的 backfill（扫描后补算）负责落值；
  /// - 仍走迁移链的原因：让「这份文件已被 company_id 感知的构建读过」有版本
  ///   承载点，并满足 P2-2 维护纪律（字段变更 = 迁移 + 升版本 + 测试三件套）。
  static Map<String, dynamic> _migrateV3ToV4(Map<String, dynamic> json) {
    json['format_version'] = 4;
    return json;
  }

  /// 把任意版本的 game.json 映射逐级升到 [currentVersion]（**不落盘**）。
  ///
  /// 与磁盘内容相比是否发生实质变化由 [GameJsonMigrationResult.changed] 告知，
  /// 调用方据此决定要不要写回——这是"读时迁移 + 一次写回"模式的关键：
  /// 读路径不做 IO 副作用，写回由显式的一处完成。
  static GameJsonMigrationResult migrateGameJsonMap(
      Map<String, dynamic> json) {
    var version = (json['format_version'] as num?)?.toInt() ?? 1;
    // 复制一份再改：迁移函数会就地修改入参，直接改会污染调用方持有的 map
    var working = Map<String, dynamic>.from(json);
    var changed = false;

    while (version < currentVersion) {
      final step = _migrations[version];
      if (step == null) {
        // 版本号比程序还新 / 落在链路空洞里：不猜、不降级，原样放行
        debugPrint('[GAME-DATA] ⚠️ 未知 format_version=$version，跳过迁移链');
        break;
      }
      working = step(working);
      version++;
      changed = true;
    }

    // 自愈：即使版本号已是最新，也保证 game_id 存在。
    // （历史文件可能由"版本号没动过"的旧构建写入，天然缺这个字段）
    final id = (working['game_id'] as String?)?.trim() ?? '';
    if (id.isEmpty) {
      working['game_id'] = GameKey.generateId();
      changed = true;
    }
    if ((working['format_version'] as num?)?.toInt() != version) {
      working['format_version'] = version;
      changed = true;
    }
    return GameJsonMigrationResult(working, changed);
  }

  /// ★ v3 阶段 2：会话事实表相关常量
  /// sessions 数组在 game.json 中保存最近的会话记录
  /// 超过 _sessionsArchiveThreshold 条时，旧记录归档到 sessions_archive.json
  /// 归档后 game.json 中保留最近 _sessionsRetainCount 条
  static const String sessionsArchiveFileName = 'sessions_archive.json';
  static const int _sessionsArchiveThreshold = 100; // 触发归档的阈值
  static const int _sessionsRetainCount = 50; // 归档后在 game.json 中保留的条数

  /// 每个目录的写入队列，串行化 game.json 读写防止数据丢失
  /// 使用 Future 链式排队，避免 check-then-act 竞态
  static final Map<String, Future<void>> _writeQueues = {};

  /// 规范化队列 key：统一分隔符 + 绝对路径 + 小写
  /// 解决同一物理目录因路径形态差异（C:\games vs C:/games/）绕过串行化的问题 (H3)
  static String _normalizeQueueKey(String targetDir) {
    var normalized = p.normalize(targetDir.replaceAll('/', '\\'));
    if (!p.isAbsolute(normalized)) {
      normalized = p.absolute(normalized);
    }
    return normalized.toLowerCase();
  }

  /// 原子写入：先写临时文件再 rename，避免 truncate-then-write 导致崩溃时文件损坏 (C3)
  /// rename 在同一卷上是原子操作（Windows MoveFileEx + REPLACE_EXISTING）
  static Future<void> _atomicWriteFile(File targetFile, String content) async {
    final tempPath = '${targetFile.path}.tmp';
    final tempFile = File(tempPath);
    try {
      await tempFile.writeAsString(content, flush: true);
      await tempFile.rename(targetFile.path);
    } catch (e) {
      // 清理临时文件
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// ★ P1-4a（2026-09-19 语义翻转）：writeGameDir 覆盖写入时**允许被新值覆盖**的字段
  ///
  /// 旧实现是「保留白名单」：列出要保留的字段，未列出的一律用本次默认值覆盖。
  /// 该方向的失败模式极危险——累积型字段（play_time / sessions / daily_play_log / …）
  /// 只要漏列，重复入库 / 覆盖安装就会把它**清零且不落任何日志**，
  /// 而这类数据是用户无法重建的。
  ///
  /// 现改为「覆盖黑名单」语义：
  /// - 旧文件中**已存在**的字段默认**全部保留**；
  /// - 只有显式列在本集合中的字段，才由本次写入的新值覆盖；
  /// - 旧文件中**不存在**的字段仍取 freshData 的默认值（首入库 / 后加字段语义不变）。
  /// 漏列的最坏后果退化为「该字段没被更新」——可见、可修、不丢数据。
  ///
  /// 🔴 维护纪律：往 writeGameDir 的 freshData 新增字段时问一句
  /// 「这个字段是本次导入必须生效的，还是用户累积出来的？」，前者才加进本集合。
  static const Set<String> _overwritableFields = {
    'format_version', // 格式版本（迁移链条的依据）
    'title', // 标题（元数据抓取 / 用户命名 → 本次生效）
    'description',
    'tags',
    'cover_file', // 本次导入写入的封面文件名
    'banner_file', // ★ 2026-10-04 横幅封面：抓取派生数据，与 cover_file 同类，
    // 重复入库以本次抓取为准；缺失时落空串（= 无横幅，UI 回退竖封面）
    'launch_path', // 本次导入识别到的启动程序
    'directory_path', // 本次导入指向的本体目录
    'source', // 入库来源
    'updated_at', // 始终刷新为本次写入时间
    'developer',
    // ★ 会社归一化（v4）：company_id 必须跟随 developer 一起生效——
    //   重复入库用新 developer 覆盖旧值时，若 company_id 保留旧值会指向
    //   已不存在的会社原文（悬空绑定）。未命中词典时写入 null（=未解析）。
    'company_id',
    'screenshot_urls', // 本次抓取到的截图 URL 清单
    'screenshot_status', // 有新 URL 即置 pending 触发后台下载（保持原行为）
    'screenshot_retry_count',
    'original_title', // 导入时的原始名 / 抓取到的标准名（P2-4：二者已合并）
    // metadata_title 已废弃：v3 迁移把它并入 original_title 并删除该键
    'subtitle',
    'metadata_source',
    'metadata_source_id',
    // ★ 2026-10-04：探索页对齐元数据（发售日/评分/评分人数/预计游玩时长）。
    // 抓取派生数据（与 developer/subtitle 同类），重复入库以本次抓取为准；
    // 缺失时详情窗口有懒回填兜底（game_detail_dialog._maybeBackfillExternalMetadata）。
    'release_date',
    'rating',
    'rating_count',
    'estimated_minutes',
    // ★ 2026-09-26 P1-4：云端主键是「本次导入必须生效」的字段——重复安装
    // 同一云端游戏（或目录名被另一部云端游戏占用）时以本次任务为准。
    'cloud_game_id',
    // ── 以下刻意**不在**集合内：旧文件已有值时一律保留 ──
    // game_id（★ P0-1 稳定主键：重复入库必须沿用旧 id，绝不允许换新）
    // play_time / sessions / daily_play_log（不可重建的用户数据）
    // installed_at（= 首次入库时间，重复入库不得重置）
    // first_opened_at / last_opened_at / play_status / mark / completed
    // title_locked / is_blurred / locale_mode / upscaling_mode
    // shortcut_path / custom_icon_path / auto_create_shortcut
    // screenshot_files（已下载截图索引，丢失会导致 UI 上截图消失）
    // collection_ids（收藏夹归属）
    // storage_state / archive_dir / archive_at（★ 2026-10-02 存储状态：
    //   用户累积出来的归档事实，重复入库绝不允许清掉 —— 清掉等于"封装/打包
    //   状态凭空消失"，用户会以为数据丢了。见 §5.4）
  };

  /// 把 [freshData] 按「覆盖黑名单」语义合并进 [jsonFile] 的既有内容
  ///
  /// - 文件不存在 / 内容为空 / 解析失败：原样返回 [freshData]（首次入库语义不变）。
  /// - 既有字段默认保留，除非列名于 [_overwritableFields]。
  /// - 旧文件中缺失的字段（含后加的新字段）取 [freshData] 的默认值。
  /// - `updated_at` 恒为"本次写入时间"。
  static Future<Map<String, dynamic>> _mergePreservedFields(
      File jsonFile, Map<String, dynamic> freshData) async {
    Map<String, dynamic> existing;
    try {
      if (!await jsonFile.exists()) return freshData;
      final content = await jsonFile.readAsString();
      if (content.trim().isEmpty) return freshData;
      existing = jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      // 读取失败按新入库处理：宁可丢失统计，也不能阻塞入库流程
      debugPrint('[GAME-DATA] ⚠️ 读取既有 game.json 失败，按新入库处理: $e');
      return freshData;
    }

    // ★ 2026-09-19：以旧文件为底，只让 _overwritableFields 内的字段用新值覆盖；
    //   旧文件中缺失的字段仍取 freshData 默认值（保证后加字段能落盘）。
    final merged = Map<String, dynamic>.from(existing);
    var overwrittenCount = 0;
    var carriedCount = 0;
    for (final entry in freshData.entries) {
      if (_overwritableFields.contains(entry.key) ||
          !existing.containsKey(entry.key)) {
        merged[entry.key] = entry.value;
        overwrittenCount++;
      } else {
        carriedCount++;
      }
    }
    debugPrint(
        '[GAME-DATA] ♻️ 覆盖写入: 新值生效 $overwrittenCount 项 / 保留既有 $carriedCount 项'
        '（play_time=${existing['play_time']}, sessions=${(existing['sessions'] as List?)?.length ?? 0}条）');
    return merged;
  }

  /// 写入 / 覆盖一个游戏的 game.json。
  ///
  /// 返回值：本次写入后 game.json 中**生效的稳定主键** `game_id`。
  /// - 老文件已有 id → 返回旧 id（id 终身不变）；
  /// - 首次入库 → 返回新生成的 id。
  /// 调用方可直接把它交给 [LocalGameRegistry.registerExtractionComplete]，
  /// 使内存对象与磁盘使用同一个 id（否则要等下一次 scan 才对得上）。
  static Future<String> writeGameDir({
    required String targetDir,
    required String title,
    String description = '',
    List<String> tags = const [],
    String? coverFilePath,
    String? coverUrl,
    String launchPath = '',
    String directoryPath = '',
    String source = 'download',
    String developer = '',
    List<String>? screenshotUrls,
    String? originalTitle,
    String? subtitle,
    String? metadataTitle,
    String? metadataSource,
    String? metadataSourceId,
    String? cloudGameId,
    // ★ 2026-10-04：探索页对齐元数据（导入时由抓取结果写入；
    // null = 本次无数据，落盘为默认空值，详情窗口懒回填兜底）
    String? releaseDate,
    double? rating,
    int? ratingCount,
    int? estimatedMinutes,
    // ★ 2026-10-04：横幅封面 URL（横向大图，BPM 背景 / 主页大图优先用）。
    // null / 空 = 本次无横幅数据；非 http 开头忽略。
    String? bannerUrl,
  }) async {
    final dir = Directory(targetDir);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    await _writeCtgame(targetDir);

    String coverFile = defaultCoverFileName;
    if (coverFilePath != null && File(coverFilePath).existsSync()) {
      coverFile = await _saveCoverFile(targetDir, coverFilePath);
    } else if (coverUrl != null && coverUrl.startsWith('http')) {
      coverFile = await _downloadAndSaveCover(targetDir, coverUrl);
    }

    // 横幅封面：只有 URL 一条路（横幅图来自元数据抓取，本地导入没有横幅源）。
    // 下载失败 → 空串（= 无横幅，UI 回退竖向封面），绝不阻塞入库。
    String bannerFile = '';
    if (bannerUrl != null && bannerUrl.startsWith('http')) {
      bannerFile = await _downloadAndSaveBanner(targetDir, bannerUrl);
    }

    final relativeLaunchPath = _toRelativePath(launchPath, targetDir);

    // 写入前规范化路径：统一分隔符、解析符号链接（路径存在时），
    // 解决排重比较时因路径形态差异导致的失效。
    // 不小写以保留可读性；比较时由 PathNormalizer.forCompare 统一小写。
    final effectiveDirectoryPath = directoryPath.isNotEmpty
        ? PathNormalizer.forStore(directoryPath, resolveSymlinks: true)
        : targetDir;

    // ===== 截图异步化改造 =====
    // 入库时不再同步下载截图文件，仅将原始 URL 写入 game.json
    // 实际下载由 ScreenshotFetchService 在后台异步完成
    // 这样可显著缩短入库耗时（避免 6 张截图网络下载阻塞）
    // ★ P2-4：标题槽位收敛。`originalTitle`（导入时的原始名）与
    //   `metadataTitle`（抓取到的标准名）此前是两个键写同一份数据。
    //   现在只落 `original_title`：originalTitle 优先，为空时用 metadataTitle
    //   兜底，保证"抓取到的标准名"这一信息不丢。
    //   入参 metadataTitle 保留，是为了不改动 6 处导入调用点。
    final String effectiveOriginalTitle =
        (originalTitle != null && originalTitle.isNotEmpty)
            ? originalTitle
            : (metadataTitle ?? '');

    final List<String> screenshotUrlList =
        screenshotUrls != null ? screenshotUrls : const <String>[];
    // 截图状态：有 URL 则标记 pending（待后台下载），无 URL 则标记 completed（无截图）
    final String screenshotStatus =
        screenshotUrlList.isNotEmpty ? 'pending' : 'completed';

    // ★ 会社归一化（v4）：developer 落盘的同时解析 company_id 一起写入。
    // 词典未加载 / 未命中 → null（缺键语义 = 未解析，由 registry 的
    // backfill 与 pending 漏斗兜底），绝不在此处做模糊匹配。
    final int? resolvedCompanyId =
        CompanyAliasStore.instanceOrNull?.resolve(developer)?.record.companyId;
    // 命中即清待审漏斗（幂等；未命中是空操作）——否则词典扩批后
    // 旧 pending 条目永不消化，审阅列表只增不减。
    await CompanyAliasPendingStore.instance
        .removeIfResolved(developer, resolvedCompanyId);

    final gameData = <String, dynamic>{
      'format_version': currentVersion,
      // ★ P0-1：稳定主键。老文件已有值时由覆盖黑名单语义保留（见
      //   _overwritableFields —— game_id 刻意不在其中），这里只在首入库生效。
      'game_id': GameKey.generateId(),
      'title': title,
      'description': description,
      'tags': tags,
      'cover_file': coverFile,
      // 横幅封面文件名（banner.*，空串 = 无横幅；2026-10-04 新增，不升版本）
      'banner_file': bannerFile,
      'launch_path': relativeLaunchPath,
      'directory_path': effectiveDirectoryPath,
      'source': source,
      'installed_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'mark': 'none',
      'play_time': 0,
      'completed': false,
      'locale_mode': 'none',
      'upscaling_mode': 'none',
      'developer': developer,
      // 会社归一化解析结果（v4 新增；null = 未解析，与 developer 原文并存）
      'company_id': resolvedCompanyId,
      'play_status': 'not_started',
      'is_blurred': false,
      'first_opened_at': '',
      'last_opened_at': '',
      'screenshot_files': <String>[],
      'screenshot_urls': screenshotUrlList,
      'screenshot_status': screenshotStatus,
      'screenshot_retry_count': 0,
      // 标题槽位（P2-4 收敛后只有 original_title，见本方法开头的说明）
      'original_title': effectiveOriginalTitle,
      // 副标题：与主标题共同构成标题系统（通常为日文原版标题），用户可自定义
      'subtitle': subtitle ?? '',
      // 元数据源持久化：用于 ImportDedupIndex 源 ID 排重维度
      'metadata_source': metadataSource ?? '',
      'metadata_source_id': metadataSourceId ?? '',
      // ★ 2026-09-26 P1-4：云端来源主键（探索库云端记录的 record.id）。
      // 与 metadata_source_id（元数据抓取平台 ID）语义不同、互不覆盖；
      // 「是否已安装」按它优先判定，不受本地改标题影响。老文件无此键。
      'cloud_game_id': cloudGameId ?? '',
      // ★ 2026-10-04：探索页对齐元数据（发售日 / 评分 / 评分人数 /
      // 预计游玩时长分钟数）。老文件无键 → 读取侧 ?? 默认值（不升版本）。
      'release_date': releaseDate ?? '',
      'rating': rating ?? 0.0,
      'rating_count': ratingCount ?? 0,
      'estimated_minutes': estimatedMinutes ?? 0,
      // 收藏夹归属（多对多），新入库默认为空
      'collection_ids': <String>[],
    };

    final jsonFile = File('$targetDir/$gameJsonFileName');

    // ★ writeGameDir 必须经过写队列，否则与并发 updateGameJsonAtomic 互相覆盖 (C2)
    // 使用原子写入避免崩溃时文件损坏 (C3)
    final key = _normalizeQueueKey(targetDir);
    final previous = _writeQueues[key] ?? Future<void>.value();
    final completer = Completer<void>();
    _writeQueues[key] = completer.future;

    await previous;
    var mergedData = gameData;
    try {
      // ★ P1-4a：重复入库 / 覆盖安装时保留已有游玩数据。
      // 读取必须发生在写队列内，否则与并发写入构成 check-then-act 竞态。
      mergedData = await _mergePreservedFields(jsonFile, gameData);
      final jsonStr = const JsonEncoder.withIndent('  ').convert(mergedData);
      await _atomicWriteFile(jsonFile, jsonStr);
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ writeGameDir写入失败: $e');
      rethrow;
    } finally {
      completer.complete();
      if (_writeQueues[key] == completer.future) {
        _writeQueues.remove(key);
      }
    }

    final effectiveGameId = (mergedData['game_id'] as String?) ?? '';
    debugPrint(
        '[GAME-DATA] ✅ 写入完成: $targetDir/$gameJsonFileName | game_id=${effectiveGameId.isEmpty ? "(空)" : effectiveGameId} | launch_path=$relativeLaunchPath | source=$source | screenshot_urls=${screenshotUrlList.length}张 | status=$screenshotStatus');
    return effectiveGameId;
  }

  /// 稳定主键护栏（P0-1）：拒绝把已存在的 `game_id` 改成不同值。
  ///
  /// `game_id` 是"一个游戏一辈子只有一个"的身份标识：所有以它为键的派生索引、
  /// 以及未来的 `library_index.db` 都依赖它不漂移。任何试图改写它的调用
  /// 都视为 bug——忽略并留日志，而不是让主键悄悄换掉（漂移一次，
  /// 所有 id 索引同时失配，且无法自动修复）。
  static void _guardGameIdUpdates(
      Map<String, dynamic> updates, Map<String, dynamic> current) {
    if (!updates.containsKey('game_id')) return;
    final requested = updates['game_id'];
    final existing = current['game_id'];

    if (requested is! String || requested.trim().isEmpty) {
      debugPrint('[GAME-DATA] 🔒 拒绝写入空 game_id');
      updates.remove('game_id');
      return;
    }
    if (existing is String &&
        existing.isNotEmpty &&
        existing != requested) {
      debugPrint('[GAME-DATA] 🔒 拒绝覆盖 game_id: $existing → $requested');
      updates.remove('game_id');
    }
  }

  /// 返回 true 表示写入成功，false 表示失败（文件不存在或写入异常）
  ///
  /// [forceTitle] 为 true 时跳过 title_locked 锁定保护——仅用于用户在编辑器中
  /// 主动修改标题的场景（用户开锁编辑即视为接管标题，持久化时同时解除锁定标记）
  static Future<bool> updateGameJson(String targetDir,
      Map<String, dynamic> updates,
      {bool forceTitle = false}) async {
    final key = _normalizeQueueKey(targetDir);
    final previous = _writeQueues[key] ?? Future<void>.value();
    final completer = Completer<void>();
    _writeQueues[key] = completer.future;

    await previous;

    try {
      final jsonFile = File('$targetDir/$gameJsonFileName');
      if (!await jsonFile.exists()) return false;

      final content = await jsonFile.readAsString();
      final jsonData = jsonDecode(content) as Map<String, dynamic>;

      // ★ 标题锁定保护：如果 title_locked 为 true，移除 updates 中的 title 字段
      // （forceTitle=true 时跳过保护：用户主动改标题必须生效）
      final isTitleLocked = !forceTitle && jsonData['title_locked'] == true;
      if (isTitleLocked && updates.containsKey('title')) {
        debugPrint('[GAME-DATA] 🔒 标题已锁定，跳过 title 字段更新');
        updates.remove('title');
      }

      // ★ P0-1：稳定主键护栏（禁止把 game_id 改成别的值）
      _guardGameIdUpdates(updates, jsonData);

      for (final entry in updates.entries) {
        jsonData[entry.key] = entry.value;
      }
      jsonData['updated_at'] = DateTime.now().toIso8601String();

      final jsonStr = JsonEncoder.withIndent('  ').convert(jsonData);
      await _atomicWriteFile(jsonFile, jsonStr); // 原子写 (C3)
      return true;
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 更新game.json失败: $e');
      return false; // 不再吞掉错误，返回 false 让调用方知晓 (H2)
    } finally {
      completer.complete();
      if (_writeQueues[key] == completer.future) {
        _writeQueues.remove(key);
      }
    }
  }

  /// 累加 play_time（原子操作，消除 check-then-act 竞态）(H13)
  /// 旧实现 readGameJson 在队列外读取，updateGameJson 用旧值写入，存在竞态。
  static Future<bool> addPlayTime(String targetDir, int seconds) async {
    if (seconds <= 0) return false;
    return updateGameJsonAtomic(targetDir, (current) {
      final filePlayTime = (current['play_time'] as num?)?.toInt() ?? 0;
      return {'play_time': filePlayTime + seconds};
    });
  }

  /// 原子性读-改-写：在写队列内执行读取+修改+写入，消除竞态
  ///
  /// [updater] 接收当前 JSON 全量数据，返回需要更新的字段。
  /// 读取和写入都在同一个队列任务中完成，保证不会被其他写入操作插入。
  /// 返回 true 表示成功，false 表示失败（H2: 不再静默吞掉错误）
  static Future<bool> updateGameJsonAtomic(
    String targetDir,
    Map<String, dynamic> Function(Map<String, dynamic> current) updater, {
    bool forceTitle = false,
  }) async {
    final key = _normalizeQueueKey(targetDir);
    final previous = _writeQueues[key] ?? Future<void>.value();
    final completer = Completer<void>();
    _writeQueues[key] = completer.future;

    await previous;

    try {
      final jsonFile = File('$targetDir/$gameJsonFileName');
      if (!await jsonFile.exists()) return false;

      final content = await jsonFile.readAsString();
      final jsonData = jsonDecode(content) as Map<String, dynamic>;

      // 在队列内执行读-改-写，此时不会有其他写入操作干扰
      final updates = updater(jsonData);

      // 标题锁定保护（forceTitle=true 时跳过：用户主动改标题必须生效）
      final isTitleLocked = !forceTitle && jsonData['title_locked'] == true;
      if (isTitleLocked && updates.containsKey('title')) {
        updates.remove('title');
      }

      // ★ P0-1：稳定主键护栏（禁止把 game_id 改成别的值）
      _guardGameIdUpdates(updates, jsonData);

      for (final entry in updates.entries) {
        jsonData[entry.key] = entry.value;
      }
      jsonData['updated_at'] = DateTime.now().toIso8601String();

      final jsonStr = JsonEncoder.withIndent('  ').convert(jsonData);
      await _atomicWriteFile(jsonFile, jsonStr); // 原子写 (C3)
      return true;
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 原子更新game.json失败: $e');
      return false; // 返回 false 让调用方知晓写入失败 (H2)
    } finally {
      completer.complete();
      if (_writeQueues[key] == completer.future) {
        _writeQueues.remove(key);
      }
    }
  }

  /// 累加每日游玩时长（原子操作，消除竞态）
  ///
  /// 在写队列内读取 daily_play_log，累加当日 seconds，再写回。
  /// 兼容旧格式（纯数字）和新格式（{seconds, count}）。
  static Future<void> addDailyPlaySeconds(
      String targetDir, int secondsToAdd) async {
    if (secondsToAdd <= 0) return;
    await updateGameJsonAtomic(targetDir, (current) {
      final today = DateTime.now();
      final dateKey =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

      Map<String, dynamic> dailyLog = {};
      final existing = current['daily_play_log'];
      if (existing is Map) {
        dailyLog = Map<String, dynamic>.from(existing);
        // 兼容旧格式
        for (final key in dailyLog.keys.toList()) {
          final val = dailyLog[key];
          if (val is num) {
            dailyLog[key] = {'seconds': val.toInt(), 'count': 0};
          }
        }
      }

      final todayEntry = (dailyLog[dateKey] as Map<String, dynamic>?) ??
          {'seconds': 0, 'count': 0};
      final todaySeconds = (todayEntry['seconds'] as num?)?.toInt() ?? 0;
      todayEntry['seconds'] = todaySeconds + secondsToAdd;
      dailyLog[dateKey] = todayEntry;

      // 清理超过90天的旧数据
      final cutoff = today.subtract(const Duration(days: 90));
      dailyLog.removeWhere((key, _) {
        final date = DateTime.tryParse(key);
        return date == null || date.isBefore(cutoff);
      });

      return {'daily_play_log': dailyLog};
    });
  }

  /// 累加每日游玩次数（原子操作，消除竞态）
  static Future<void> incrementDailyPlayCount(String targetDir) async {
    await updateGameJsonAtomic(targetDir, (current) {
      final today = DateTime.now();
      final dateKey =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

      Map<String, dynamic> dailyLog = {};
      final existing = current['daily_play_log'];
      if (existing is Map) {
        dailyLog = Map<String, dynamic>.from(existing);
        // 兼容旧格式
        for (final key in dailyLog.keys.toList()) {
          final val = dailyLog[key];
          if (val is num) {
            dailyLog[key] = {'seconds': val.toInt(), 'count': 0};
          }
        }
      }

      final todayEntry = (dailyLog[dateKey] as Map<String, dynamic>?) ??
          {'seconds': 0, 'count': 0};
      final todayCount = (todayEntry['count'] as num?)?.toInt() ?? 0;
      todayEntry['count'] = todayCount + 1;
      dailyLog[dateKey] = todayEntry;

      // 与 addDailyPlaySeconds 对齐：清理超过 90 天的旧数据，防止日志无界增长
      final cutoff = today.subtract(const Duration(days: 90));
      dailyLog.removeWhere((key, _) {
        final date = DateTime.tryParse(key);
        return date == null || date.isBefore(cutoff);
      });

      return {'daily_play_log': dailyLog};
    });
  }

  // ===========================================================================
  // ★ v3 阶段 2：会话事实表（Sessions）—— 自愈能力的根基
  //
  // 设计哲学（借鉴 ReinaManager 三层数据模型）：
  //   - sessions 是不可变的事实记录（每次游玩都是一条独立记录）
  //   - play_time / daily_play_log 是 sessions 的派生投影
  //   - 投影损坏时可由 sessions 全量重建（自愈）
  //
  // 会话记录结构：
  //   {
  //     "session_id": "uuid-v4",
  //     "start_time": "ISO8601",
  //     "end_time": "ISO8601",
  //     "duration_seconds": 3600,
  //     "tracking_mode": "playtime" | "elapsed",
  //     "exit_reason": "normal" | "crash" | "manual" | "app_shutdown" | "recovered" | "aborted"
  //   }
  //
  // 归档机制：
  //   - game.json 的 sessions 数组超过 100 条时触发归档
  //   - 旧记录（前 50 条）移动到 sessions_archive.json
  //   - game.json 保留最近 50 条
  //   - 归档文件采用追加模式，可累积多次归档
  // ===========================================================================

  /// 追加一条会话记录到 game.json 的 sessions 数组
  ///
  /// 原子操作，自动触发归档检查。会话记录采用追加写入（append-only），
  /// 不修改已有记录，保证事实表的不可变性。
  ///
  /// [session] 必须包含以下字段：
  ///   - session_id: String (UUID)
  ///   - start_time: String (ISO8601)
  ///   - end_time: String (ISO8601)
  ///   - duration_seconds: int
  ///   - tracking_mode: String ('playtime' | 'elapsed')
  ///   - exit_reason: String
  static Future<bool> appendSession(
      String targetDir, Map<String, dynamic> session) async {
    try {
      // 校验必填字段
      _validateSessionRecord(session);
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 会话记录校验失败，拒绝写入: $e');
      return false;
    }

    final success = await updateGameJsonAtomic(targetDir, (current) {
      final sessions = (current['sessions'] as List?)?.toList() ?? <dynamic>[];
      // 深拷贝避免外部修改
      final sessionCopy = Map<String, dynamic>.from(session);
      sessions.add(sessionCopy);
      return {'sessions': sessions};
    });

    if (!success) {
      debugPrint('[GAME-DATA] ⚠️ 追加会话记录失败: $targetDir');
      return false;
    }

    // ★ 触发归档检查（非阻塞，失败不影响主流程）
    await _archiveSessionsIfNeeded(targetDir);

    debugPrint(
        '[GAME-DATA] ✅ 会话记录已追加: ${session['session_id']} | 时长=${session['duration_seconds']}s | 退出原因=${session['exit_reason']}');
    return true;
  }

  /// 校验会话记录的必填字段
  static void _validateSessionRecord(Map<String, dynamic> session) {
    final requiredFields = [
      'session_id',
      'start_time',
      'end_time',
      'duration_seconds',
      'tracking_mode',
      'exit_reason',
    ];
    for (final field in requiredFields) {
      if (!session.containsKey(field)) {
        throw ArgumentError('会话记录缺少必填字段: $field');
      }
    }
    if (session['session_id'] is! String ||
        (session['session_id'] as String).isEmpty) {
      throw ArgumentError('session_id 必须是非空字符串');
    }
    if (session['duration_seconds'] is! int ||
        (session['duration_seconds'] as int) < 0) {
      throw ArgumentError('duration_seconds 必须是非负整数');
    }
    final mode = session['tracking_mode'];
    if (mode != 'playtime' && mode != 'elapsed') {
      throw ArgumentError('tracking_mode 必须是 playtime 或 elapsed');
    }
  }

  /// 检查 sessions 数组是否超过阈值，超过则归档旧记录
  ///
  /// 归档策略：
  /// 1. 读取 game.json 中的 sessions 数组
  /// 2. 如果长度 > _sessionsArchiveThreshold (100)
  /// 3. 将前 (length - _sessionsRetainCount) 条移动到 sessions_archive.json
  /// 4. game.json 中保留最后 _sessionsRetainCount (50) 条
  ///
  /// 归档文件格式：
  ///   { "archived_count": 50, "sessions": [...] }
  /// 多次归档时，sessions 数组追加，archived_count 累加。
  static Future<void> _archiveSessionsIfNeeded(String targetDir) async {
    try {
      final jsonFile = File('$targetDir/$gameJsonFileName');
      if (!await jsonFile.exists()) return;

      final content = await jsonFile.readAsString();
      final jsonData = jsonDecode(content) as Map<String, dynamic>;
      final sessions = jsonData['sessions'];
      if (sessions is! List || sessions.length <= _sessionsArchiveThreshold) {
        return; // 未达阈值，无需归档
      }

      final totalSessions = sessions.length;
      final toArchiveCount = totalSessions - _sessionsRetainCount;
      if (toArchiveCount <= 0) return;

      // 待归档的旧记录（前 toArchiveCount 条）
      final toArchive =
          sessions.sublist(0, toArchiveCount).cast<Map<String, dynamic>>();
      // 保留的近期记录（后 _sessionsRetainCount 条）
      final retained = sessions.sublist(toArchiveCount);

      // 读取现有归档文件（如有）
      final archiveFile = File('$targetDir/$sessionsArchiveFileName');
      List<dynamic> archivedSessions = [];
      int existingArchivedCount = 0;
      if (await archiveFile.exists()) {
        try {
          final archiveContent = await archiveFile.readAsString();
          final archiveData =
              jsonDecode(archiveContent) as Map<String, dynamic>;
          archivedSessions = (archiveData['sessions'] as List?)?.toList() ?? [];
          existingArchivedCount =
              (archiveData['archived_count'] as num?)?.toInt() ?? 0;
        } catch (e) {
          debugPrint('[GAME-DATA] ⚠️ 读取归档文件失败，将重建: $e');
          archivedSessions = [];
          existingArchivedCount = 0;
        }
      }

      // 追加到归档文件
      archivedSessions.addAll(toArchive);
      final newArchivedCount = existingArchivedCount + toArchiveCount;
      final archiveData = {
        'archived_count': newArchivedCount,
        'last_archived_at': DateTime.now().toIso8601String(),
        'sessions': archivedSessions,
      };
      final archiveStr = JsonEncoder.withIndent('  ').convert(archiveData);
      await _atomicWriteFile(archiveFile, archiveStr);

      // 更新 game.json 中的 sessions 数组
      jsonData['sessions'] = retained;
      jsonData['updated_at'] = DateTime.now().toIso8601String();
      final jsonStr = JsonEncoder.withIndent('  ').convert(jsonData);
      await _atomicWriteFile(jsonFile, jsonStr);

      debugPrint(
          '[GAME-DATA] 📦 会话归档完成: $targetDir | 归档 $toArchiveCount 条 | 保留 ${retained.length} 条 | 累计归档 $newArchivedCount 条');
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 会话归档失败（不影响主流程）: $e');
    }
  }

  /// 读取 game.json 中的所有会话记录（不包含归档）
  ///
  /// 返回最近的会话列表，按时间正序排列。
  static Future<List<Map<String, dynamic>>> readSessions(
      String targetDir) async {
    try {
      final data = await readGameJson(targetDir);
      if (data == null) return [];
      // readGameJson 返回 GameJsonData，但我们这里需要原始 JSON
      // 直接读取以获取 sessions 字段
      final jsonFile = File('$targetDir/$gameJsonFileName');
      if (!await jsonFile.exists()) return [];
      final content = await jsonFile.readAsString();
      final jsonData = jsonDecode(content) as Map<String, dynamic>;
      final sessions = jsonData['sessions'];
      if (sessions is! List) return [];
      return sessions
          .whereType<Map<String, dynamic>>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 读取会话记录失败: $e');
      return [];
    }
  }

  /// 读取归档的会话记录（sessions_archive.json）
  static Future<List<Map<String, dynamic>>> readArchivedSessions(
      String targetDir) async {
    try {
      final archiveFile = File('$targetDir/$sessionsArchiveFileName');
      if (!await archiveFile.exists()) return [];
      final content = await archiveFile.readAsString();
      final archiveData = jsonDecode(content) as Map<String, dynamic>;
      final sessions = archiveData['sessions'];
      if (sessions is! List) return [];
      return sessions
          .whereType<Map<String, dynamic>>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 读取归档会话失败: $e');
      return [];
    }
  }

  /// 从 sessions 数组重建 play_time 和 daily_play_log（自愈方法）
  ///
  /// 当 play_time 字段损坏或不准时，可调用此方法从会话事实表全量重算。
  /// 包含跨日会话的比例分配（借鉴 ReinaManager session_statistics_contribution）。
  ///
  /// 返回重建后的统计信息，失败返回 null。
  static Future<RebuiltStatistics?> rebuildPlayTimeFromSessions(
      String targetDir) async {
    try {
      // 读取所有会话（活跃 + 归档）
      final activeSessions = await readSessions(targetDir);
      final archivedSessions = await readArchivedSessions(targetDir);
      final allSessions = [...archivedSessions, ...activeSessions];

      if (allSessions.isEmpty) {
        debugPrint('[GAME-DATA] 📊 重建统计: 无会话记录可重建');
        return RebuiltStatistics(
          totalPlayTime: 0,
          sessionCount: 0,
          dailyPlayLog: {},
        );
      }

      int totalSeconds = 0;
      int sessionCount = 0;
      final Map<String, Map<String, int>> dailyLog = {};

      for (final session in allSessions) {
        final duration = (session['duration_seconds'] as num?)?.toInt() ?? 0;
        final startTimeStr = session['start_time'] as String? ?? '';
        final endTimeStr = session['end_time'] as String? ?? '';

        if (duration <= 0) continue;
        // 过滤误启动会话（duration < 60s 不计入）
        if (duration < 60) continue;

        totalSeconds += duration;
        sessionCount++;

        // ★ 跨日会话比例分配
        final startTime = DateTime.tryParse(startTimeStr);
        final endTime = DateTime.tryParse(endTimeStr);
        if (startTime == null || endTime == null) {
          // 时间解析失败，归入开始日期（如有）
          if (startTime != null) {
            final dateKey = _formatDateKey(startTime);
            dailyLog[dateKey] ??= {'seconds': 0, 'count': 0};
            dailyLog[dateKey]!['seconds'] =
                dailyLog[dateKey]!['seconds']! + duration;
          }
          continue;
        }

        // 跨日分配
        final dailyDistribution =
            _distributeSessionByDays(startTime, endTime, duration);
        for (final entry in dailyDistribution.entries) {
          dailyLog[entry.key] ??= {'seconds': 0, 'count': 0};
          dailyLog[entry.key]!['seconds'] =
              dailyLog[entry.key]!['seconds']! + entry.value;
        }
        // 会话次数归入开始日期
        final startDateKey = _formatDateKey(startTime);
        dailyLog[startDateKey] ??= {'seconds': 0, 'count': 0};
        dailyLog[startDateKey]!['count'] =
            dailyLog[startDateKey]!['count']! + 1;
      }

      // 清理超过 90 天的旧数据
      final cutoff = DateTime.now().subtract(const Duration(days: 90));
      dailyLog.removeWhere((key, _) {
        final date = DateTime.tryParse(key);
        return date == null || date.isBefore(cutoff);
      });

      // 原子写入重建后的 play_time 和 daily_play_log
      final success = await updateGameJsonAtomic(targetDir, (current) {
        return {
          'play_time': totalSeconds,
          'daily_play_log': dailyLog,
        };
      });

      if (!success) {
        debugPrint('[GAME-DATA] ⚠️ 重建统计写入失败');
        return null;
      }

      debugPrint(
          '[GAME-DATA] 📊 统计重建完成: $targetDir | 总时长=${formatPlayTime(totalSeconds)} | 会话数=$sessionCount | 日志天数=${dailyLog.length}');

      return RebuiltStatistics(
        totalPlayTime: totalSeconds,
        sessionCount: sessionCount,
        dailyPlayLog: dailyLog,
      );
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 重建统计失败: $e');
      return null;
    }
  }

  /// 将跨日会话按时长比例分配到各天
  ///
  /// 借鉴 ReinaManager session_statistics_contribution：
  /// 23:00 → 01:00（120分钟）→ 01-01: 60分钟, 01-02: 60分钟
  ///
  /// 返回 {dateKey: seconds} 映射
  static Map<String, int> _distributeSessionByDays(
      DateTime startTime, DateTime endTime, int totalDurationSeconds) {
    final result = <String, int>{};

    // 转换为本地日期（不含时间）
    final startDate = DateTime(startTime.year, startTime.month, startTime.day);
    final endDate = DateTime(endTime.year, endTime.month, endTime.day);

    // 同日会话
    if (startDate == endDate) {
      final dateKey = _formatDateKey(startTime);
      result[dateKey] = totalDurationSeconds;
      return result;
    }

    // 跨日会话：按比例分配
    final totalSeconds = endTime.difference(startTime).inSeconds;
    if (totalSeconds <= 0) {
      // 时间异常，归入开始日期
      result[_formatDateKey(startTime)] = totalDurationSeconds;
      return result;
    }

    DateTime currentDate = startDate;
    int allocatedSeconds = 0;

    while (currentDate.isBefore(endDate)) {
      // 当前日期的午夜（次日 00:00）
      final nextMidnight = currentDate.add(const Duration(days: 1));
      // 当前日期的边界（开始时间或午夜，取较晚者）
      final dayBoundary =
          nextMidnight.isBefore(endTime) ? nextMidnight : endTime;
      final dayStart =
          currentDate.isBefore(startTime) ? startTime : currentDate;

      final elapsedSeconds = dayBoundary.difference(dayStart).inSeconds;
      if (elapsedSeconds > 0) {
        // 按比例计算当日时长
        final daySeconds =
            (elapsedSeconds * totalDurationSeconds / totalSeconds).round();
        if (daySeconds > 0) {
          result[_formatDateKey(currentDate)] = daySeconds;
          allocatedSeconds += daySeconds;
        }
      }

      currentDate = nextMidnight;
    }

    // 最后一天（确保总和一致）
    final lastDayKey = _formatDateKey(endDate);
    final lastDaySeconds = totalDurationSeconds - allocatedSeconds;
    if (lastDaySeconds > 0) {
      result[lastDayKey] = (result[lastDayKey] ?? 0) + lastDaySeconds;
    }

    return result;
  }

  /// 格式化日期为 YYYY-MM-DD
  static String _formatDateKey(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  static Future<void> setPlayStatus(String targetDir, String status) async {
    await updateGameJson(targetDir, {'play_status': status});
  }

  static Future<void> setBlurred(String targetDir, bool value) async {
    await updateGameJson(targetDir, {'is_blurred': value});
  }

  static String formatPlayTime(int totalSeconds) {
    if (totalSeconds <= 0) return '0m';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds ~/ 60) % 60;
    final seconds = totalSeconds % 60;
    if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h';
    if (minutes > 0) return '${minutes}m';
    return '${seconds}s'; // 1-59秒显示秒数，不再显示误导性的 0m (L4)
  }

  static Future<GameJsonData?> readGameJson(String targetDir) async {
    // ★ 读取也进入写队列，确保不会读到半写状态 (H1)
    // 等待当前 pending 写入完成后再读取
    final key = _normalizeQueueKey(targetDir);
    final previous = _writeQueues[key] ?? Future<void>.value();
    final completer = Completer<void>();
    _writeQueues[key] = completer.future;

    await previous;

    try {
      final jsonFile = File('$targetDir/$gameJsonFileName');
      if (!await jsonFile.exists()) return null;

      final content = await jsonFile.readAsString();
      final raw = jsonDecode(content) as Map<String, dynamic>;

      // ★ P2-2/P0-1：读时迁移 —— 老 game.json 就地升到 currentVersion
      //（至少会补发 game_id）。迁移结果与磁盘不一致时**写回**，
      // 这是"补发 id"唯一的落盘点，读路径只识别、不重复补。
      // 注意：此处已在写队列内持有该目录的锁，写回必须绕开队列直接原子写，
      //      否则 updateGameJson 会等待自己（死锁）。
      final migration = migrateGameJsonMap(raw);
      if (migration.changed) {
        try {
          final upgraded = JsonEncoder.withIndent('  ').convert(migration.json);
          await _atomicWriteFile(jsonFile, upgraded);
          debugPrint('[GAME-DATA] 🔼 schema 升级并写回: $targetDir → v$currentVersion');
        } catch (e) {
          // 写回失败不影响本次读取：内存里已是升级后的数据
          debugPrint('[GAME-DATA] ⚠️ schema 升级写回失败（不阻塞读取）: $e');
        }
      }
      return GameJsonData.fromJson(migration.json);
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 读取game.json失败: $e');
      return null;
    } finally {
      completer.complete();
      if (_writeQueues[key] == completer.future) {
        _writeQueues.remove(key);
      }
    }
  }

  static Future<bool> hasCtgame(String dirPath) async {
    final ctgameFile = File('$dirPath/$ctgameFileName');
    return await ctgameFile.exists();
  }

  static Future<String> detectAndWriteLaunchPath(String targetDir) async {
    final detection = await GameLauncherDetector.detect(targetDir);
    if (detection.success && detection.launcherPath != null) {
      final relativePath = _toRelativePath(detection.launcherPath!, targetDir);
      await updateGameJson(targetDir, {'launch_path': relativePath});
      return relativePath;
    }
    return '';
  }

  static String _toRelativePath(String absoluteOrRelativePath, String baseDir) {
    if (absoluteOrRelativePath.isEmpty) return '';

    var normalized = absoluteOrRelativePath.replaceAll('/', '\\');
    var normalizedBase = baseDir.replaceAll('/', '\\');

    if (!normalizedBase.endsWith('\\')) {
      normalizedBase += '\\';
    }

    if (normalized.toLowerCase().startsWith(normalizedBase.toLowerCase())) {
      return normalized.substring(normalizedBase.length);
    }

    if (!normalized.contains('\\') && !normalized.contains('/')) {
      return normalized;
    }

    return absoluteOrRelativePath;
  }

  static String resolveLaunchPath(String relativePath, String directoryPath) {
    if (relativePath.isEmpty) return '';
    if (File(relativePath).existsSync()) return relativePath;
    // 规范化拼接，避免双反斜杠 (M8)
    final absolute = p.join(directoryPath, relativePath);
    if (File(absolute).existsSync()) return absolute;
    final withForwardSlash =
        p.join(directoryPath, relativePath.replaceAll('\\', '/'));
    if (File(withForwardSlash).existsSync()) return withForwardSlash;
    // 所有候选都不存在时返回空字符串，而非返回不存在的路径 (M8)
    return '';
  }

  static Future<void> _writeCtgame(String targetDir) async {
    final ctgamePath = '$targetDir\\$ctgameFileName'.replaceAll('/', '\\');
    final ctgameFile = File(ctgamePath);
    final ctgameData = jsonEncode({'format_version': currentVersion});

    const maxRetries = 3;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        if (ctgameFile.existsSync()) {
          // ★ P0-6（2026-09-16 稳定性/性能审计）：优先 FFI 清属性（零进程），
          // 失败才回退 attrib 进程 —— 旧实现每游戏 2 次进程创建（含 shell），
          // 2000 条导入 = 4000 次，是入库阶段的确定性开销。
          if (!Win32FileAttributes.clearReadOnlyHidden(ctgamePath)) {
            try {
              await Process.run('attrib', ['-r', '-h', ctgamePath],
                  runInShell: true);
            } catch (_) {}
          }
        }

        await ctgameFile.writeAsString(ctgameData, flush: true);

        if (Platform.isWindows) {
          if (!Win32FileAttributes.setHidden(ctgamePath)) {
            try {
              await Process.run('attrib', ['+h', ctgamePath],
                  runInShell: true);
            } catch (_) {}
          }
        }
        return;
      } catch (e) {
        if (attempt < maxRetries - 1) {
          debugPrint(
              '[GAME-DATA] ⚠️ .ctgame写入失败(第${attempt + 1}次重试): $targetDir | $e');
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        } else {
          debugPrint('[GAME-DATA] ❌ .ctgame写入最终失败: $targetDir | $e');
          rethrow;
        }
      }
    }
  }

  static Future<String> _saveCoverFile(
      String targetDir, String sourcePath) async {
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) return defaultCoverFileName;

    final ext = sourcePath.split('.').last.toLowerCase();
    final validExts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
    final coverExt = validExts.contains(ext) ? ext : 'png';
    final coverFileName = 'cover.$coverExt';
    final destPath = '$targetDir/$coverFileName';

    // ★ IMP-05 护栏（2026-09-12 导入审查）
    // 元数据目录若位于应用自有目录之外，说明它与用户自己的游戏文件夹重叠
    // （元数据目录由清洗后的标题拼成，可能与源目录同名）。此时目标位置的
    // cover.* 可能是用户或游戏自带的图片，覆盖即破坏用户文件 → 跳过覆盖。
    // 正常导入（元数据目录在应用目录内）行为不变。
    if (!PathHelper.isInsideAppStorage(targetDir) &&
        File(destPath).existsSync()) {
      debugPrint('[GAME-DATA] ⏭️ 跳过覆盖应用目录外的既有封面: $destPath');
      return coverFileName;
    }

    await sourceFile.copy(destPath);
    debugPrint('[GAME-DATA] ✅ 封面已保存: $destPath');
    return coverFileName;
  }

  static Future<String> _downloadAndSaveCover(
      String targetDir, String url) async {
    // Phase 3.1: 委托给统一的 CoverDownloadService
    // 原实现含缓存优先 + HttpClient 下载，现已统一到带重试 + 标准请求头的服务
    final savedName = await CoverDownloadService.instance.downloadCover(
      targetDir: targetDir,
      coverUrl: url,
    );
    return savedName ?? defaultCoverFileName;
  }

  /// 下载横幅封面到游戏元数据目录，返回落盘文件名（如 'banner_3.jpg'）。
  ///
  /// 与封面同一套下载服务（缓存优先 + 重试 + NSFW 检测入队），仅文件名
  /// 前缀不同。失败返回**空串**（= 无横幅，调用方与 UI 均按缺省处理回退
  /// 竖向封面）——横幅是增强数据，绝不因它阻塞或污染入库。
  static Future<String> _downloadAndSaveBanner(
      String targetDir, String url) async {
    // ★ 2026-10-05：downloadBanner 带宽高比校验（≥1.15），假横幅在此拒收
    final savedName = await CoverDownloadService.instance.downloadBanner(
      targetDir: targetDir,
      bannerUrl: url,
    );
    if (savedName == null) {
      debugPrint('[GAME-DATA] ⚠️ 横幅封面下载失败（按无横幅处理）: $url');
      return '';
    }
    return savedName;
  }

  /// 查找横幅封面文件，找不到返回 null。
  ///
  /// 逻辑比 [findCoverFile] 简单：横幅完全由应用落盘（无用户手放 /
  /// local_cover 之类的历史包袱），探测顺序：
  /// ① 传入的已解析 `banner_file` 值（热路径，跳过二次读 json）
  /// ② game.json 的 `banner_file` 键
  /// ③ 目录内 `banner.*` 文件名扫描
  static File? findBannerFile(String dirPath, {String? bannerFileName}) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    try {
      if (bannerFileName != null && bannerFileName.isNotEmpty) {
        final file = File('$dirPath/$bannerFileName');
        if (file.existsSync()) return file;
      }

      final jsonFile = File('$dirPath/$gameJsonFileName');
      if (jsonFile.existsSync()) {
        try {
          final content = jsonFile.readAsStringSync();
          final jsonData = jsonDecode(content) as Map<String, dynamic>;
          final bannerFile = jsonData['banner_file'] as String?;
          if (bannerFile != null && bannerFile.isNotEmpty) {
            final file = File('$dirPath/$bannerFile');
            if (file.existsSync()) return file;
          }
        } catch (_) {}
      }

      final entities = dir.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.contains('banner.')) {
            return entity;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 保存截图到 screenshots/ 子目录，返回相对路径列表，最多6张
  /// 优先从 CachedNetworkImage 的磁盘缓存复制，缓存未命中才下载
  ///
  /// 改造为 public，供 ScreenshotFetchService 在后台异步调用
  static Future<List<String>> downloadAndSaveScreenshots(
      String targetDir, List<String> urls) async {
    final screenshotDir = Directory('$targetDir/screenshots');
    if (!await screenshotDir.exists()) {
      await screenshotDir.create(recursive: true);
    }

    final limitedUrls = urls.take(6).toList();
    final futures = <Future<_ScreenshotDownloadResult>>[];

    for (int i = 0; i < limitedUrls.length; i++) {
      futures.add(_saveSingleScreenshot(i, limitedUrls[i], targetDir));
    }

    final results = await Future.wait(futures);

    // 按序号排列，跳过失败的
    final files = <String>[];
    for (final result in results) {
      if (result.success) {
        files.add(result.relativePath);
      }
    }

    return files;
  }

  /// 保存单张截图：优先从缓存复制，缓存未命中才网络下载
  static Future<_ScreenshotDownloadResult> _saveSingleScreenshot(
      int index, String url, String targetDir) async {
    String ext = 'jpg';
    final pathSegments = Uri.parse(url).pathSegments;
    if (pathSegments.isNotEmpty) {
      final last = pathSegments.last.toLowerCase();
      if (last.endsWith('.png'))
        ext = 'png';
      else if (last.endsWith('.webp')) ext = 'webp';
    }
    final fileName = 'screenshot_${index + 1}.$ext';
    final targetPath = '$targetDir/screenshots/$fileName';

    try {
      // 优先从 CachedNetworkImage 的磁盘缓存获取
      final cachedFile =
          await PortableImageCacheManager().getFileFromCache(url);
      if (cachedFile != null && cachedFile.file.existsSync()) {
        await cachedFile.file.copy(targetPath);
        debugPrint(
            '[GAME-DATA] ✅ 截图从缓存复制: $fileName (${(cachedFile.file.lengthSync() / 1024).toStringAsFixed(1)}KB)');
        return _ScreenshotDownloadResult(
            success: true, relativePath: 'screenshots/$fileName');
      }
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 截图缓存读取失败 [$index]，回退到下载: $e');
    }

    // 缓存未命中，从网络下载
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytes = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        await File(targetPath).writeAsBytes(bytes);
        debugPrint(
            '[GAME-DATA] ✅ 截图已下载: $fileName (${(bytes.length / 1024).toStringAsFixed(1)}KB)');
        return _ScreenshotDownloadResult(
            success: true, relativePath: 'screenshots/$fileName');
      }
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 截图下载失败 [$index]: $e');
    } finally {
      client.close();
    }
    return _ScreenshotDownloadResult(success: false, relativePath: '');
  }

  /// 查找游戏目录中的截图文件列表
  /// 封面库子目录名（2026-10-04 封面管理浮层）：用户上传的自定义封面
  /// 统一放 `covers/` 子目录，与 canonical cover.* / banner.* 区分
  /// （对齐 screenshots/ 子目录的既有先例，不改 game.json schema）。
  static const String coversDirName = 'covers';

  /// 扫描某个游戏的全部封面候选（2026-10-04 封面管理浮层用）。
  ///
  /// 顺序：canonical 竖封面（`cover_file` / cover.*）→ 横幅（`banner_file`
  /// / banner.*）→ `covers/` 子目录内的自定义图（按文件名排序）。
  /// 同一路径只出现一次；canonical 文件名缺失时回退读 game.json 与常见
  /// 命名，口径与 [findCoverFile] / [findBannerFile] 一致。
  static List<CoverGalleryEntry> listCoverGallery(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];

    final entries = <CoverGalleryEntry>[];
    final seen = <String>{};
    void add(String path, {required bool isVertical, required bool isBanner}) {
      final norm = path.replaceAll('\\', '/');
      if (seen.add(norm)) {
        entries.add(CoverGalleryEntry(
            path: norm, isVertical: isVertical, isBanner: isBanner));
      }
    }

    String? nameFromJson(String key) {
      final jsonFile = File('$dirPath/$gameJsonFileName');
      if (!jsonFile.existsSync()) return null;
      try {
        final data = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
        final v = data[key] as String?;
        return (v != null && v.isNotEmpty) ? v : null;
      } catch (_) {
        return null;
      }
    }

    // 1) 竖屏封面（canonical）
    final coverName = nameFromJson('cover_file');
    if (coverName != null) {
      final f = File('$dirPath/$coverName');
      if (f.existsSync()) add(f.path, isVertical: true, isBanner: false);
    } else {
      for (final name in const ['cover.png', 'cover.jpg', 'cover.jpeg']) {
        final f = File('$dirPath/$name');
        if (f.existsSync()) {
          add(f.path, isVertical: true, isBanner: false);
          break;
        }
      }
    }

    // 2) 横幅封面（canonical）
    final bannerName = nameFromJson('banner_file');
    if (bannerName != null) {
      final f = File('$dirPath/$bannerName');
      if (f.existsSync()) add(f.path, isVertical: false, isBanner: true);
    } else {
      for (final name
          in const ['banner.png', 'banner.jpg', 'banner.jpeg', 'banner.webp']) {
        final f = File('$dirPath/$name');
        if (f.existsSync()) {
          add(f.path, isVertical: false, isBanner: true);
          break;
        }
      }
    }

    // 3) covers/ 自定义图
    final coversDir = Directory('$dirPath/$coversDirName');
    if (coversDir.existsSync()) {
      final files = coversDir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => _isImageFileName(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        add(f.path, isVertical: false, isBanner: false);
      }
    }

    return entries;
  }

  static bool _isImageFileName(String path) {
    final ext = path.split('.').last.toLowerCase();
    return const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].contains(ext);
  }

  static List<String> findScreenshotFiles(String dirPath) {
    final result = <String>[];

    // 优先从 game.json 读取
    try {
      final jsonFile = File('$dirPath/$gameJsonFileName');
      if (jsonFile.existsSync()) {
        final content = jsonFile.readAsStringSync();
        final jsonData = jsonDecode(content) as Map<String, dynamic>;
        final files = (jsonData['screenshot_files'] as List?)
            ?.map((e) => e.toString())
            .toList();
        if (files != null && files.isNotEmpty) {
          for (final f in files) {
            final file = File('$dirPath/$f');
            if (file.existsSync()) result.add(file.path);
          }
          return result;
        }
      }
    } catch (_) {}

    // 回退: 扫描 screenshots/ 子目录
    final screenshotDir = Directory('$dirPath/screenshots');
    if (screenshotDir.existsSync()) {
      final entities = screenshotDir.listSync(followLinks: false);
      final imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.gif'];
      for (final entity in entities) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (imageExts.contains(ext)) {
            result.add(entity.path);
          }
        }
      }
      result.sort();
    }

    return result;
  }

  /// 查找封面文件
  ///
  /// [coverFileName] 可传入**已解析**出来的 `cover_file` 值：命中即直接返回，
  /// 跳过对 game.json 的第二次同步读取 + jsonDecode（扫描热路径上的纯收益）。
  /// 传 null、或该文件名在磁盘上不存在时，回退到原有探测逻辑，行为不变。
  static File? findCoverFile(String dirPath, {String? coverFileName}) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    try {
      if (coverFileName != null && coverFileName.isNotEmpty) {
        final file = File('$dirPath/$coverFileName');
        if (file.existsSync()) return file;
      }

      final jsonFile = File('$dirPath/$gameJsonFileName');
      if (jsonFile.existsSync()) {
        try {
          final content = jsonFile.readAsStringSync();
          final jsonData = jsonDecode(content) as Map<String, dynamic>;
          final coverFile = jsonData['cover_file'] as String?;
          if (coverFile != null && coverFile.isNotEmpty) {
            final file = File('$dirPath/$coverFile');
            if (file.existsSync()) return file;
          }
        } catch (_) {}
      }

      const coverNames = ['cover.png', 'cover.jpg', 'cover.jpeg'];
      for (final name in coverNames) {
        final file = File('$dirPath/$name');
        if (file.existsSync()) return file;
      }

      final entities = dir.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.contains('cover.') && !name.contains('local_cover')) {
            return entity;
          }
        }
      }
      for (final entity in entities) {
        if (entity is File &&
            entity.path.toLowerCase().contains('local_cover')) {
          return entity;
        }
      }
    } catch (_) {}
    return null;
  }
}

/// 截图下载结果
/// 封面管理浮层的单个封面候选（2026-10-04）。
///
/// [isVertical] / [isBanner] 标记该文件当前是否正被用作竖屏封面
/// （`cover_file`）/ 横幅封面（`banner_file`）；两者均为 false 即
/// `covers/` 子目录内的自定义图。
class CoverGalleryEntry {
  final String path;
  final bool isVertical;
  final bool isBanner;

  const CoverGalleryEntry({
    required this.path,
    required this.isVertical,
    required this.isBanner,
  });
}

class _ScreenshotDownloadResult {
  final bool success;
  final String relativePath;
  _ScreenshotDownloadResult(
      {required this.success, required this.relativePath});
}

/// [GameDataFormat.migrateGameJsonMap] 的返回值。
class GameJsonMigrationResult {
  /// 升级后的 json 映射（与输入**不是**同一个对象）
  final Map<String, dynamic> json;

  /// 与磁盘内容相比是否发生实质变更（调用方据此决定要不要写回）
  final bool changed;

  const GameJsonMigrationResult(this.json, this.changed);
}

class GameJsonData {
  final int formatVersion;

  /// 稳定主键（`game_id`，UUID v4）。老数据（未经 v2 迁移）可能是空串。
  final String gameId;

  final String title;
  final String description;
  final List<String> tags;
  final String coverFile;

  /// 横幅封面文件名（相对游戏元数据目录，如 'banner_3.jpg'）。
  ///
  /// 空串 = 无横幅（老文件无此键 → `?? ''`，不升版本的兼容前提）。
  /// UI 使用优先级：BPM 背景 / 主页大图**横幅优先**，缺失回退 [coverFile]。
  final String bannerFile;
  final String launchPath;
  final String directoryPath;
  final String source;
  final String installedAt;
  final String updatedAt;
  final String mark;
  final int playTime;

  /// ⚠️ **已废弃**（P2-1）：与 [playStatus] 语义重叠，且没有任何写入方
  /// （唯一写入点是首入库时的 `false`，旧 API setCompleted 零调用者）。
  /// 保留字段是为了读懂老文件，**读取方一律忽略它**，判定通关只看 [playStatus]。
  final bool completed;
  final String localeMode;
  final String upscalingMode;
  final String developer;

  /// 会社归一化解析结果（会社词典 `CompanyAliasStore` 的 company_id，v4 新增）。
  ///
  /// null = 未解析（老数据 / 词典未命中 / 词典未加载）；[developer] 原文
  /// 永远保留，二者并存。筛选 / 分组以 companyId 优先、原文兜底。
  final int? companyId;
  final String playStatus;
  final bool isBlurred;
  final String firstOpenedAt;
  final String lastOpenedAt;
  /// **本地产物**（派生）：已下载到游戏目录的截图文件名清单。
  ///
  /// 渲染只看这个字段。丢失它会导致 UI 上截图直接消失（文件其实还在磁盘上），
  /// 因此它刻意**不在** `_overwritableFields` 内，重复入库不会把它清空。
  final List<String> screenshotFiles;

  // ===== 截图异步抓取相关字段 =====

  /// **源清单**（只读语义）：元数据源给的原始 URL，入库时写入，
  /// 由 ScreenshotFetchService 在后台下载。
  ///
  /// ⚠️ 下载完成后**不会**从中移除已落地的项（P2-3 记录在案）：保留它可以
  /// 支持"失败重试"与"换机重下"。它不参与渲染（渲染只看 [screenshotFiles]），
  /// 因此很容易被误读成"当前应显示的截图"。语义以此为准：
  /// `screenshotUrls` = 源，`screenshotFiles` = 产物。
  final List<String> screenshotUrls;
  // 截图下载状态：pending | downloading | completed | failed
  final String screenshotStatus;
  // 失败重试次数，最多3次
  final int screenshotRetryCount;
  final String shortcutPath;
  final String customIconPath;

  /// 首次启动时是否自动生成桌面快捷方式（默认 true）
  /// 用户可在启动管理对话框中关闭，关闭后首次启动不会自动生成
  final bool autoCreateShortcut;
  /// 标题系统的槽位定义（P2-4 收敛后）：
  ///
  /// - [title]          **展示用主标题**，用户可改（`title_locked` 可锁定）
  /// - [originalTitle]  **数据源原名**：导入时的文件夹名，或元数据抓取到的
  ///                    标准名。只读。v2→v3 迁移会把原 `metadata_title`
  ///                    并入这里，所以"抓取到的标准名"不会丢。
  /// - [subtitle]       **用户自定义副标题**（通常填日文原版标题）
  ///
  /// 读取方一律用 [originalTitle]；不要新增对 [metadataTitle] 的依赖。
  final String originalTitle;

  /// ⚠️ **遗留字段**（P2-4）：只在读 v3 之前的 game.json 时被填充，
  /// 不再写入磁盘（v3 迁移已删除该键）。保留它只为让老文件能被解析出来，
  /// 新代码一律读 [originalTitle]。
  final String metadataTitle;
  // 副标题：与主标题共同构成标题系统（通常为日文原版标题），用户可自定义
  final String subtitle;
  // 元数据源（如 VNDB/Bangumi）与源内 ID，用于排重
  final String metadataSource;
  final String metadataSourceId;
  // ★ 2026-09-26 P1-4：云端来源主键（探索库云端记录 record.id）。
  // 空 = 老数据 / 非云端来源。「是否已安装」按它优先判定。
  final String cloudGameId;

  // ===== 探索页对齐元数据（2026-10-04，仅详情窗口展示）=====
  //
  // 老文件无键 → 默认值（不升 format_version，ADR-012 路线）。
  // 写入方：导入时 writeGameDir（抓取结果透传）+ 详情窗口懒回填。

  /// 发售日期（ISO YYYY-MM-DD；详情窗口「开发日期」行展示）
  final String releaseDate;

  /// 评分（0-10 分制；<=0 视为无）
  final double rating;

  /// 评分人数（VNDB 投票数；<=0 视为无）
  final int ratingCount;

  /// 预计游玩时长（分钟，VNDB 多用户平均；<=0 视为无）
  final int estimatedMinutes;

  // 所属收藏夹 ID 列表（多对多，收藏夹本体存于 data/collections.json）
  final List<String> collectionIds;

  // ===== 游戏数据保存（存储状态）=====
  //
  // 🔴 这三个字段是**用户状态**（语义与 [playStatus] 同类），因此刻意**不列入**
  //    [_overwritableFields]：一旦列进去，重新导入同一游戏会清掉封装/打包状态，
  //    用户会以为数据丢了。与同处的既有注释「用户累积型字段不列入」一致。
  //    见 `game_storage_state_implementation_plan.md` §5.4。

  /// 存储状态：`normal` / `sealed` / `packed`。
  ///
  /// ⚠️ `display_only`（仅展示）是**派生态** —— 由「本体目录是否存在」推导，
  /// **不写盘**。因此这里永远不会是 `display_only`。
  /// 判定逻辑见 `game_storage_state_controller.dart`。
  final String storageState;

  /// 当前生效归档目录的**绝对路径**（指向
  /// `<归档库根>/<目录名>/<时间戳>_<state>`）；空串 = 无归档。
  final String archiveDir;

  /// 归档时间（ISO8601）；空串 = 无归档。
  final String archiveAt;

  // ===== 累积型字段（writeGameDir 覆盖写入时必须保留，不可随重复入库清零）=====
  // 这三个字段此前**未在本类中建模**，导致磁盘 schema 与模型不一致：
  // 任何走 GameJsonData 全量序列化的路径都会把它们写没。补齐后模型即 schema。
  /// 会话事实表（sessions 数组）；null = 该 game.json 中不存在此字段
  final List<Map<String, dynamic>>? sessions;
  /// 每日游玩日志：{ 'YYYY-MM-DD': {'seconds': n, 'count': n} }
  final Map<String, dynamic>? dailyPlayLog;
  /// 自动导入写入的标题锁定标记（true 时 updateGameJson* 拒绝覆盖 title）
  final bool? titleLocked;

  GameJsonData({
    required this.formatVersion,
    this.gameId = '',
    required this.title,
    this.description = '',
    this.tags = const [],
    this.coverFile = 'cover.png',
    this.bannerFile = '',
    this.launchPath = '',
    this.directoryPath = '',
    this.source = 'download',
    this.installedAt = '',
    this.updatedAt = '',
    this.mark = 'none',
    this.playTime = 0,
    this.completed = false,
    this.localeMode = 'none',
    this.upscalingMode = 'none',
    this.developer = '',
    this.companyId,
    this.playStatus = 'not_started',
    this.isBlurred = false,
    this.firstOpenedAt = '',
    this.lastOpenedAt = '',
    this.screenshotFiles = const [],
    this.screenshotUrls = const [],
    this.screenshotStatus = 'completed',
    this.screenshotRetryCount = 0,
    this.shortcutPath = '',
    this.customIconPath = '',
    this.autoCreateShortcut = true,
    this.originalTitle = '',
    this.metadataTitle = '',
    this.subtitle = '',
    this.metadataSource = '',
    this.metadataSourceId = '',
    this.cloudGameId = '',
    this.releaseDate = '',
    this.rating = 0.0,
    this.ratingCount = 0,
    this.estimatedMinutes = 0,
    this.collectionIds = const [],
    this.storageState = 'normal',
    this.archiveDir = '',
    this.archiveAt = '',
    this.sessions,
    this.dailyPlayLog,
    this.titleLocked,
  });

  /// P2-4 的读取兜底：老文件只有 `metadata_title` 时，把它当作
  /// `original_title` 返回。这样即便某条读路径没走 v3 迁移，
  /// 也拿不到"标题缺失"的假象（迁移会落盘，这里只是双保险）。
  static String _pickTitle(String? primary, String? legacy) {
    if (primary != null && primary.isNotEmpty) return primary;
    return legacy ?? '';
  }

  factory GameJsonData.fromJson(Map<String, dynamic> json) {
    return GameJsonData(
      // 使用 num?.toInt() 兼容 double 值（外部工具可能写入 0.0）(M7)
      formatVersion: (json['format_version'] as num?)?.toInt() ?? 1,
      gameId: json['game_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      tags: (json['tags'] as List?)?.map((t) => t.toString()).toList() ?? [],
      coverFile: json['cover_file'] as String? ?? 'cover.png',
      // ★ 2026-10-04 横幅封面：老文件无键 → 空串（不升版本）
      bannerFile: json['banner_file'] as String? ?? '',
      launchPath: json['launch_path'] as String? ?? '',
      directoryPath: json['directory_path'] as String? ?? '',
      source: json['source'] as String? ?? 'download',
      installedAt: json['installed_at'] as String? ?? '',
      updatedAt: json['updated_at'] as String? ?? '',
      mark: json['mark'] as String? ?? 'none',
      playTime: (json['play_time'] as num?)?.toInt() ?? 0,
      completed: json['completed'] as bool? ?? false,
      localeMode: json['locale_mode'] as String? ?? 'none',
      upscalingMode: json['upscaling_mode'] as String? ?? 'none',
      developer: json['developer'] as String? ?? '',
      // num?.toInt() 兼容外部工具写入的 double（与 play_time 同一策略 M7）
      companyId: (json['company_id'] as num?)?.toInt(),
      playStatus: json['play_status'] as String? ?? 'not_started',
      isBlurred: json['is_blurred'] as bool? ?? false,
      firstOpenedAt: json['first_opened_at'] as String? ?? '',
      lastOpenedAt: json['last_opened_at'] as String? ?? '',
      screenshotFiles: (json['screenshot_files'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      screenshotUrls: (json['screenshot_urls'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      screenshotStatus: json['screenshot_status'] as String? ?? 'completed',
      screenshotRetryCount:
          (json['screenshot_retry_count'] as num?)?.toInt() ?? 0,
      shortcutPath: json['shortcut_path'] as String? ?? '',
      customIconPath: json['custom_icon_path'] as String? ?? '',
      autoCreateShortcut: json['auto_create_shortcut'] as bool? ?? true,
      originalTitle: _pickTitle(
          json['original_title'] as String?, json['metadata_title'] as String?),
      metadataTitle: json['metadata_title'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      metadataSource: json['metadata_source'] as String? ?? '',
      metadataSourceId: json['metadata_source_id'] as String? ?? '',
      collectionIds: (json['collection_ids'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      sessions: (json['sessions'] as List?)
          ?.map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
          .toList(),
      dailyPlayLog: json['daily_play_log'] is Map
          ? Map<String, dynamic>.from(json['daily_play_log'] as Map)
          : null,
      titleLocked: json['title_locked'] as bool?,
      // ★ 2026-09-26 P1-4：老文件无此键 → 空串（判定回退标题匹配）
      cloudGameId: json['cloud_game_id'] as String? ?? '',
      // ★ 2026-10-02 存储状态：老文件无这 3 个键 → 走默认值（不升版本的兼容前提）
      storageState: json['storage_state'] as String? ?? 'normal',
      archiveDir: json['archive_dir'] as String? ?? '',
      archiveAt: json['archive_at'] as String? ?? '',
      // ★ 2026-10-04 探索页对齐元数据：老文件无键 → 默认值（不升版本）
      releaseDate: json['release_date'] as String? ?? '',
      rating: (json['rating'] as num?)?.toDouble() ?? 0.0,
      ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
      estimatedMinutes: (json['estimated_minutes'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'format_version': formatVersion,
        // 空 id 不回写：避免用空值覆盖掉磁盘上已有的稳定主键
        if (gameId.isNotEmpty) 'game_id': gameId,
        'title': title,
        'description': description,
        'tags': tags,
        'cover_file': coverFile,
        // ★ 2026-10-04 横幅封面：仅在非默认值时输出（与存储状态同一考量，
        //   避免「无横幅的老游戏」game.json 被无意义改写）
        if (bannerFile.isNotEmpty) 'banner_file': bannerFile,
        'launch_path': launchPath,
        'directory_path': directoryPath,
        'source': source,
        'installed_at': installedAt,
        'updated_at': updatedAt,
        'mark': mark,
        'play_time': playTime,
        'completed': completed,
        'locale_mode': localeMode,
        'upscaling_mode': upscalingMode,
        'developer': developer,
        if (companyId != null) 'company_id': companyId,
        'play_status': playStatus,
        'is_blurred': isBlurred,
        'first_opened_at': firstOpenedAt,
        'last_opened_at': lastOpenedAt,
        'screenshot_files': screenshotFiles,
        'screenshot_urls': screenshotUrls,
        'screenshot_status': screenshotStatus,
        'screenshot_retry_count': screenshotRetryCount,
        'shortcut_path': shortcutPath,
        'custom_icon_path': customIconPath,
        'auto_create_shortcut': autoCreateShortcut,
        'original_title': originalTitle,
        // ⚠️ 不再输出 metadata_title：v3 已把该槽位并入 original_title
        'subtitle': subtitle,
        'metadata_source': metadataSource,
        'metadata_source_id': metadataSourceId,
        'cloud_game_id': cloudGameId,
        // ★ 2026-10-04 探索页对齐元数据：**仅在非默认值时输出**（与下方
        //   存储状态同一考量——避免老文件全库无意义改写）
        if (releaseDate.isNotEmpty) 'release_date': releaseDate,
        if (rating > 0) 'rating': rating,
        if (ratingCount > 0) 'rating_count': ratingCount,
        if (estimatedMinutes > 0) 'estimated_minutes': estimatedMinutes,
        'collection_ids': collectionIds,
        // ★ 2026-10-02 存储状态：**仅在非默认值时输出**。
        //   目的是让「从未归档过的游戏」的 game.json 保持在字节级不变的旧形态，
        //   避免一次全库无意义改写（1000+ 个文件）。
        if (storageState != 'normal') 'storage_state': storageState,
        if (archiveDir.isNotEmpty) 'archive_dir': archiveDir,
        if (archiveAt.isNotEmpty) 'archive_at': archiveAt,
        // 累积型字段只在**已加载**时回写：避免用空值把磁盘上的事实表覆盖掉
        if (sessions != null) 'sessions': sessions,
        if (dailyPlayLog != null) 'daily_play_log': dailyPlayLog,
        if (titleLocked != null) 'title_locked': titleLocked,
      };
}

/// ★ v3 阶段 2：统计重建结果
///
/// 由 [GameDataFormat.rebuildPlayTimeFromSessions] 返回，
/// 包含从 sessions 全量重算的统计信息。
class RebuiltStatistics {
  /// 重建后的总游玩时长（秒）
  final int totalPlayTime;

  /// 重建后的有效会话数（过滤误启动 < 60s 后）
  final int sessionCount;

  /// 重建后的每日游玩日志
  /// key: YYYY-MM-DD, value: {seconds: int, count: int}
  final Map<String, Map<String, int>> dailyPlayLog;

  RebuiltStatistics({
    required this.totalPlayTime,
    required this.sessionCount,
    required this.dailyPlayLog,
  });

  @override
  String toString() {
    return 'RebuiltStatistics(totalPlayTime=$totalPlayTime, sessionCount=$sessionCount, dailyLogDays=${dailyPlayLog.length})';
  }
}
