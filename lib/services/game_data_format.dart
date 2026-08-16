import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/portable_image_cache_manager.dart';
import 'game_launcher_detector.dart';
import 'cover_download_service.dart';
import '../utils/path_normalizer.dart';

class GameDataFormat {
  static const int currentVersion = 1;
  static const String ctgameFileName = '.ctgame';
  static const String gameJsonFileName = 'game.json';
  static const String defaultCoverFileName = 'cover.png';

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

  static Future<void> writeGameDir({
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
    String? metadataTitle,
    String? metadataSource,
    String? metadataSourceId,
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
    final List<String> screenshotUrlList =
        screenshotUrls != null ? screenshotUrls : const <String>[];
    // 截图状态：有 URL 则标记 pending（待后台下载），无 URL 则标记 completed（无截图）
    final String screenshotStatus =
        screenshotUrlList.isNotEmpty ? 'pending' : 'completed';

    final gameData = {
      'format_version': currentVersion,
      'title': title,
      'description': description,
      'tags': tags,
      'cover_file': coverFile,
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
      'play_status': 'not_started',
      'is_blurred': false,
      'first_opened_at': '',
      'last_opened_at': '',
      'screenshot_files': <String>[],
      'screenshot_urls': screenshotUrlList,
      'screenshot_status': screenshotStatus,
      'screenshot_retry_count': 0,
      // 双标题持久化：导入时记录原标题与元数据标题，重启后可恢复切换状态
      'original_title': originalTitle ?? '',
      'metadata_title': metadataTitle ?? '',
      // 元数据源持久化：用于 ImportDedupIndex 源 ID 排重维度
      'metadata_source': metadataSource ?? '',
      'metadata_source_id': metadataSourceId ?? '',
    };

    final jsonStr = JsonEncoder.withIndent('  ').convert(gameData);
    final jsonFile = File('$targetDir/$gameJsonFileName');

    // ★ writeGameDir 必须经过写队列，否则与并发 updateGameJsonAtomic 互相覆盖 (C2)
    // 使用原子写入避免崩溃时文件损坏 (C3)
    final key = _normalizeQueueKey(targetDir);
    final previous = _writeQueues[key] ?? Future<void>.value();
    final completer = Completer<void>();
    _writeQueues[key] = completer.future;

    await previous;
    try {
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

    debugPrint(
        '[GAME-DATA] ✅ 写入完成: $targetDir/$gameJsonFileName | launch_path=$relativeLaunchPath | source=$source | screenshot_urls=${screenshotUrlList.length}张 | status=$screenshotStatus');
  }

  /// 返回 true 表示写入成功，false 表示失败（文件不存在或写入异常）
  static Future<bool> updateGameJson(
      String targetDir, Map<String, dynamic> updates) async {
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
      final isTitleLocked = jsonData['title_locked'] == true;
      if (isTitleLocked && updates.containsKey('title')) {
        debugPrint('[GAME-DATA] 🔒 标题已锁定，跳过 title 字段更新');
        updates.remove('title');
      }

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
    Map<String, dynamic> Function(Map<String, dynamic> current) updater,
  ) async {
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

      // 标题锁定保护
      final isTitleLocked = jsonData['title_locked'] == true;
      if (isTitleLocked && updates.containsKey('title')) {
        updates.remove('title');
      }

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
          final archiveData = jsonDecode(archiveContent) as Map<String, dynamic>;
          archivedSessions =
              (archiveData['sessions'] as List?)?.toList() ?? [];
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
        final duration =
            (session['duration_seconds'] as num?)?.toInt() ?? 0;
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
        final dailyDistribution = _distributeSessionByDays(
            startTime, endTime, duration);
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
    final startDate =
        DateTime(startTime.year, startTime.month, startTime.day);
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
      final nextMidnight =
          currentDate.add(const Duration(days: 1));
      // 当前日期的边界（开始时间或午夜，取较晚者）
      final dayBoundary = nextMidnight.isBefore(endTime) ? nextMidnight : endTime;
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

  static Future<void> setCompleted(String targetDir, bool value) async {
    await updateGameJson(targetDir, {'completed': value});
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
      final jsonData = jsonDecode(content) as Map<String, dynamic>;
      return GameJsonData.fromJson(jsonData);
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
          try {
            await Process.run('attrib', ['-r', '-h', ctgamePath],
                runInShell: true);
          } catch (_) {}
        }

        await ctgameFile.writeAsString(ctgameData, flush: true);

        if (Platform.isWindows) {
          try {
            await Process.run('attrib', ['+h', ctgamePath], runInShell: true);
          } catch (_) {}
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

  static File? findCoverFile(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    try {
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
class _ScreenshotDownloadResult {
  final bool success;
  final String relativePath;
  _ScreenshotDownloadResult(
      {required this.success, required this.relativePath});
}

class GameJsonData {
  final int formatVersion;
  final String title;
  final String description;
  final List<String> tags;
  final String coverFile;
  final String launchPath;
  final String directoryPath;
  final String source;
  final String installedAt;
  final String updatedAt;
  final String mark;
  final int playTime;
  final bool completed;
  final String localeMode;
  final String upscalingMode;
  final String developer;
  final String playStatus;
  final bool isBlurred;
  final String firstOpenedAt;
  final String lastOpenedAt;
  final List<String> screenshotFiles;
  // ===== 截图异步抓取相关字段 =====
  // 原始截图URL列表，入库时直接写入，由 ScreenshotFetchService 异步下载
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
  // 双标题：导入时的文件夹/文件名 vs 元数据抓取的标准名
  final String originalTitle;
  final String metadataTitle;
  // 元数据源（如 VNDB/Bangumi）与源内 ID，用于排重
  final String metadataSource;
  final String metadataSourceId;

  GameJsonData({
    required this.formatVersion,
    required this.title,
    this.description = '',
    this.tags = const [],
    this.coverFile = 'cover.png',
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
    this.metadataSource = '',
    this.metadataSourceId = '',
  });

  factory GameJsonData.fromJson(Map<String, dynamic> json) {
    return GameJsonData(
      // 使用 num?.toInt() 兼容 double 值（外部工具可能写入 0.0）(M7)
      formatVersion: (json['format_version'] as num?)?.toInt() ?? 1,
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      tags: (json['tags'] as List?)?.map((t) => t.toString()).toList() ?? [],
      coverFile: json['cover_file'] as String? ?? 'cover.png',
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
      originalTitle: json['original_title'] as String? ?? '',
      metadataTitle: json['metadata_title'] as String? ?? '',
      metadataSource: json['metadata_source'] as String? ?? '',
      metadataSourceId: json['metadata_source_id'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'format_version': formatVersion,
        'title': title,
        'description': description,
        'tags': tags,
        'cover_file': coverFile,
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
        'metadata_title': metadataTitle,
        'metadata_source': metadataSource,
        'metadata_source_id': metadataSourceId,
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
