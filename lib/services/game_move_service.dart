import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import '../utils/network_path.dart';
import '../utils/path_normalizer.dart';
import 'local_game_registry.dart';
import 'path_validator.dart';
import 'storage/cleanup_utils.dart';

/// 游戏目录真迁移服务（单例）。
///
/// 将「移动游戏位置」从"复制+改引用"升级为真正的事务化迁移：
///
/// - M0 前置校验：互斥 / 游戏存在 / 源存在 / 目标合法且不存在 / 运行中守卫 /
///   嵌套路径拒绝 / 元数据目录位于本体目录内时拒绝 / 跨卷空间预检
/// - M1 事务登记：`data/move_in_progress.json` 先于任何落盘动作（ADR-008：
///   回滚归属依据用显式登记，不用时间戳判定）
/// - M2 搬运：同卷 = `Directory.rename` 原子移动（Phase 0 实测 4ms，天然完整）；
///   跨卷 = worker isolate 流式 copy + 逐文件字节数校验
/// - M3 清源（仅跨卷）：全文件校验通过后删除源目录（走 CleanupUtils + 审计日志）
/// - M4 引用切换：`LocalGameRegistry.finalizeGameMove` 聚合更新 game.json /
///   启动配置 / 快捷方式 / Magpie / 存档清单，逐项 best-effort
/// - M5 收尾：清除登记，返回 [MoveResult]
///
/// 失败原则（方案 §4.2）：先保源；回滚只删 M1 登记过的自建目标目录；
/// M3 之后的失败绝不回滚文件（新目录已完整可用，relink 是修复兜底）。
class GameMoveService {
  GameMoveService._();
  static final GameMoveService instance = GameMoveService._();

  /// 服务级互斥（同一时刻仅一个迁移任务，照 IMP-10/11 批量入库互斥范式）
  static bool _moving = false;
  static bool get isMoving => _moving;

  /// 仅供测试：强制走跨卷 copy 路径（覆盖同卷判定，验证 isolate 搬运/校验/清源链路）
  @visibleForTesting
  static bool debugForceCrossVolume = false;

  /// 仅供测试：worker 复制到该相对路径时抛错（注入 copy 失败以验证回滚）
  @visibleForTesting
  static String? debugFailAtRelativePath;

  /// 用户取消请求标志（进度回调里置位，worker 在下一条进度消息时被 kill）
  bool _cancelRequested = false;

  /// 进度通知（UI 进度对话框订阅）
  final ValueNotifier<GameMoveProgress?> progressNotifier =
      ValueNotifier<GameMoveProgress?>(null);

  /// 登记文件位置：data/move_in_progress.json
  static String get _registryFilePath =>
      p.join(PathHelper.dataDir, 'move_in_progress.json');

  // ==========================================================================
  // 公开 API
  // ==========================================================================

  /// 迁移游戏本体目录到 [targetDirPath]（完整目标目录，由 UI 拼好游戏名）。
  ///
  /// 源目录一律从注册表读取 [LibraryGame.directoryPath]，不接受外部传入
  /// （方案 §10 P0 防护②：源路径必须 == game.directoryPath 当前值）。
  Future<MoveResult> moveGame({
    required String gameTitle,
    required String targetDirPath,
  }) async {
    // ---- M0 前置校验 ----
    if (_moving) {
      return MoveResult.failed('已有迁移任务正在进行，请等待其完成');
    }
    final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
    if (game == null) {
      return MoveResult.failed('未找到游戏: $gameTitle');
    }
    final sourcePath = game.directoryPath;
    if (sourcePath.isEmpty) {
      return MoveResult.failed('该游戏未记录本地目录，无法移动');
    }
    final source = Directory(sourcePath);
    if (!await source.exists()) {
      return MoveResult.failed('游戏目录不存在: $sourcePath',
          sourcePath: sourcePath);
    }

    // 归一化为绝对路径（相对路径会让同卷判定失效、卷空间查询失败）
    final target = _toAbsolute(targetDirPath.trim());
    if (target.isEmpty) {
      return MoveResult.failed('目标路径为空');
    }
    if (_sameNormalizedPath(sourcePath, target)) {
      return MoveResult.failed('目标目录与当前目录相同');
    }
    if (_isNestedPath(sourcePath, target)) {
      return MoveResult.failed('目标目录不能位于游戏目录内部');
    }
    if (_isNestedPath(target, sourcePath)) {
      return MoveResult.failed('游戏目录不能被移动到其目标目录内部');
    }
    final targetDir = Directory(target);
    if (await targetDir.exists()) {
      return MoveResult.failed('目标目录已存在，为避免覆盖请选择一个不存在的位置');
    }
    // 元数据目录位于本体目录内（本地导入同名重叠特例）时，移动本体会把
    // game.json 一起搬走导致引用断裂 → 拒绝（与 updateGameTitle 的 IMP-05 护栏同语义）
    if (_metaInsideBody(game.metaDataDir, sourcePath)) {
      return MoveResult.failed('该游戏的元数据目录位于游戏目录内部，无法安全迁移');
    }
    // 运行中守卫：活跃会话键为 metaDataDir（GameMoveService 不直接依赖
    // RunningTasksService，registry.activeSessionDirs 已是权威来源）
    if (LocalGameRegistry.instance.activeSessionDirs.contains(game.metaDataDir)) {
      return MoveResult.failed('游戏正在运行中，请先退出游戏再移动');
    }

    final sameVolume =
        debugForceCrossVolume ? false : _isSameVolume(sourcePath, target);

    // 跨卷空间预检：目标父目录的可用空间必须 ≥ 源目录实际大小 + 5% 余量。
    // 空间信息不可信（isAvailable=false 或负值）时跳过预检——
    // 让 copy 阶段的实际写盘失败兜底报错（方案 §13 开放问题 2 的降级路径）
    int totalBytes = 0;
    if (!sameVolume) {
      totalBytes = await _measureTreeBytes(source);
      final parentOfTarget = p.dirname(target);
      final space = await PathValidator.getDiskSpaceInfo(parentOfTarget);
      if (space.isAvailable &&
          space.freeSpaceBytes >= 0 &&
          space.freeSpaceBytes < (totalBytes * 1.05).round()) {
        return MoveResult.failed(
            '目标磁盘空间不足：需要约 ${_formatBytes(totalBytes)}，'
            '目标盘仅剩 ${_formatBytes(space.freeSpaceBytes)}',
            sourcePath: sourcePath);
      }
    }

    _moving = true;
    _cancelRequested = false;
    progressNotifier.value = GameMoveProgress.initial(
        phase: sameVolume ? 'moving' : 'preparing');

    try {
      // ---- M1 事务登记（先于任何落盘动作） ----
      await _writePendingRecord(gameTitle, sourcePath, target);

      // ---- M2 搬运 ----
      bool moved;
      bool viaRename = false;
      if (sameVolume) {
        // 同卷：确保目标父目录存在后原子 rename
        final targetParent = Directory(p.dirname(target));
        if (!await targetParent.exists()) {
          await targetParent.create(recursive: true);
        }
        _updateProgress(GameMoveProgress.initial(phase: 'moving'));
        try {
          await source.rename(target);
          moved = true;
          viaRename = true;
        } on FileSystemException catch (e) {
          debugPrint('[MOVE] 同卷 rename 失败: $e');
          await _clearPendingRecord();
          return MoveResult.failed('移动失败: ${e.osError?.message ?? e.message}'
              '（文件可能被占用，请关闭游戏后重试）',
              sourcePath: sourcePath);
        }
      } else {
        _updateProgress(GameMoveProgress.initial(
            phase: 'copying', totalBytes: totalBytes));
        moved = await _copyViaIsolate(source, target);
        if (!moved) {
          // 失败/取消 → 回滚：仅删除 M1 登记过的自建目标目录，源目录从未被改动
          debugPrint('[MOVE] 跨卷搬运失败或被取消，回滚清理目标目录: $target');
          await CleanupUtils.deleteWithRetry(
            Directory(target),
            retries: 1,
            reason: 'move_rollback',
          );
          await _clearPendingRecord();
          return MoveResult.failed(_cancelRequested
              ? '已取消移动，原文件未受影响'
              : '移动失败：文件复制未通过完整性校验，原文件未受影响，已清理目标目录',
              sourcePath: sourcePath);
        }
      }

      // ---- M3 清源（仅跨卷；rename 路径无残留） ----
      String? sourceLeftover;
      if (!viaRename) {
        // 清源前重验：源路径必须与 M1 登记值归一化相等
        // （防并发改写 game.directoryPath 后按错误路径删除，方案 §10 P0 防护②）
        final record = await _readPendingRecord();
        final registeredSource = record?['sourcePath']?.toString() ?? '';
        if (record == null ||
            !_sameNormalizedPath(registeredSource, sourcePath)) {
          debugPrint('[MOVE] ⛔ 登记校验不一致，保守跳过清源: '
              'registered=$registeredSource actual=$sourcePath');
          sourceLeftover = sourcePath;
        } else {
          _updateProgress(GameMoveProgress(phase: 'cleaning',
              copiedFiles: progressNotifier.value?.copiedFiles ?? 0,
              totalFiles: progressNotifier.value?.totalFiles ?? 0,
              copiedBytes: progressNotifier.value?.copiedBytes ?? 0,
              totalBytes: progressNotifier.value?.totalBytes ?? 0,
              currentFile: ''));
          final deleted = await CleanupUtils.deleteWithRetry(
            source,
            retries: 1,
            reason: 'move_source_cleanup',
          );
          if (!deleted) {
            sourceLeftover = sourcePath;
            debugPrint('[MOVE] ⚠️ 旧目录清理失败（可能被占用），已保留: $sourcePath');
          }
        }
      }

      // ---- M4 引用切换（逐项 best-effort，失败不回滚文件） ----
      _updateProgress(GameMoveProgress(phase: 'switching',
          copiedFiles: progressNotifier.value?.copiedFiles ?? 0,
          totalFiles: progressNotifier.value?.totalFiles ?? 0,
          copiedBytes: progressNotifier.value?.copiedBytes ?? 0,
          totalBytes: progressNotifier.value?.totalBytes ?? 0,
          currentFile: ''));
      final warnings = <String>[];
      try {
        final refWarnings =
            await LocalGameRegistry.instance.finalizeGameMove(
          gameTitle: gameTitle,
          newDirectoryPath: target,
          oldDirectoryPath: sourcePath,
        );
        warnings.addAll(refWarnings);
      } catch (e) {
        warnings.add('引用更新整体失败: $e（可使用「更换游戏目录」修复指向新目录 $target）');
      }

      // ---- M5 收尾 ----
      await _clearPendingRecord();
      await CleanupLog.append({
        'op': 'game_move',
        'source': sourcePath,
        'target': target,
        'viaRename': viaRename,
        'sourceLeftover': sourceLeftover ?? '',
        'refWarnings': warnings.length,
        'result': 'ok',
        'reason': 'game_location_move',
      });
      debugPrint('[MOVE] ✅ 迁移完成: $sourcePath → $target (rename=$viaRename)');
      return MoveResult(
        status: sourceLeftover != null || warnings.isNotEmpty
            ? MoveStatus.partial
            : MoveStatus.success,
        sourcePath: sourcePath,
        sourceLeftoverPath: sourceLeftover,
        referenceWarnings: warnings,
        movedViaRename: viaRename,
      );
    } catch (e, st) {
      debugPrint('[MOVE] 迁移异常: $e\n$st');
      // 兜底回滚：目标可能是本任务自建的半成品（登记仍在 → 归属明确）
      try {
        final record = await _readPendingRecord();
        if (record != null && record['targetPath'] == target) {
          await CleanupUtils.deleteWithRetry(
            Directory(target),
            retries: 1,
            reason: 'move_exception_rollback',
          );
        }
      } catch (_) {}
      await _clearPendingRecord();
      return MoveResult.failed('移动失败: $e（原文件未受影响）',
          sourcePath: sourcePath);
    } finally {
      _moving = false;
      _cancelRequested = false;
    }
  }

  /// 请求取消当前迁移（跨卷 copy 阶段生效；同卷 rename 瞬时完成无需取消）。
  void cancelCurrentMove() {
    _cancelRequested = true;
  }

  /// 启动检测：读取登记文件，若存在未完成迁移则如实报告（不自动删除任何文件）。
  ///
  /// 由 `InterruptCleanup.startupScan` 调用。检测结果存入
  /// [startupPendingMoves]，供详情弹窗打开时向用户提示（用户确认后自行
  /// 清理半成品，遵循 ADR-007「无法确认时保留」方向）。
  Future<void> checkPendingMoveOnStartup() async {
    try {
      final record = await _readPendingRecord();
      if (record == null) return;
      final targetPath = record['targetPath']?.toString() ?? '';
      final sourcePath = record['sourcePath']?.toString() ?? '';
      final targetExists =
          targetPath.isNotEmpty && await Directory(targetPath).exists();
      final sourceExists =
          sourcePath.isNotEmpty && await Directory(sourcePath).exists();
      // 归属明确（登记文件为本应用写入）且源已不存在 → 目标目录即迁移产物；
      // 但清理仍需用户确认，这里只记录与审计。
      await CleanupLog.append({
        'op': 'move_startup_detect',
        'source': sourcePath,
        'target': targetPath,
        'targetExists': targetExists,
        'sourceExists': sourceExists,
        'result': 'detected',
        'reason': 'startup_pending_move',
      });
      startupPendingMoves.add(PendingMoveRecord(
        gameTitle: record['gameTitle']?.toString() ?? '',
        sourcePath: sourcePath,
        targetPath: targetPath,
        targetExists: targetExists,
        sourceExists: sourceExists,
      ));
      debugPrint('[MOVE] ⚠️ 检测到未完成的迁移任务: $sourcePath → $targetPath '
          '(targetExists=$targetExists, sourceExists=$sourceExists)');
    } catch (e) {
      debugPrint('[MOVE] 启动检测迁移登记失败: $e');
    }
  }

  /// 启动检测到的未完成迁移（由详情弹窗消费后清除）
  final List<PendingMoveRecord> startupPendingMoves = [];

  /// 取出并清除指定游戏的启动残留提示（存在则返回记录）
  PendingMoveRecord? takeStartupPendingMove(String gameTitle) {
    for (final r in startupPendingMoves) {
      if (r.gameTitle == gameTitle) {
        startupPendingMoves.remove(r);
        return r;
      }
    }
    return null;
  }

  // ==========================================================================
  // M2: 跨卷 isolate 搬运
  // ==========================================================================

  /// worker isolate：流式逐文件 copy + 逐文件字节数校验。
  ///
  /// 通信协议（worker → main）：
  /// - {'type':'plan','files':n,'bytes':n}
  /// - {'type':'file','path':相对路径}
  /// - {'type':'progress','bytes':本次新增字节}（≥120ms 节流）
  /// - {'type':'done'}
  /// - {'type':'error','path':相对路径,'msg':错误}
  ///
  /// 取消机制：主 isolate 收到进度消息时若 [_cancelRequested] 置位，
  /// 直接 kill worker（Phase 0 已验证 kill 后源完好、目标半成品可控）。
  static void _copyWorker(Map<String, dynamic> params) {
    final SendPort out = params['sendPort'] as SendPort;
    final String sourcePath = params['sourcePath'] as String;
    final String targetPath = params['targetPath'] as String;
    final String? failAtFile = params['failAtFile'] as String?;
    try {
      // 计划阶段：流式枚举收集文件（isolate 内存，不占 UI isolate）
      final srcDir = Directory(sourcePath);
      final files = <String>[];
      int totalBytes = 0;
      final srcPrefix = sourcePath.endsWith('\\')
          ? sourcePath
          : '$sourcePath\\';
      srcDir.listSync(recursive: true, followLinks: false).forEach((entity) {
        if (entity is File) {
          final rel = entity.path.substring(srcPrefix.length);
          files.add(rel);
          totalBytes += entity.lengthSync();
        }
      });
      out.send({'type': 'plan', 'files': files.length, 'bytes': totalBytes});

      // 搬运阶段：逐文件分块 copy + 字节数校验
      int sentBytesSinceThrottle = 0;
      var lastThrottle = DateTime.now();
      for (final rel in files) {
        if (failAtFile != null && rel == failAtFile) {
          throw FileSystemException('测试注入的复制失败', rel);
        }
        final srcFile = File(p.join(sourcePath, rel));
        final dstFile = File(p.join(targetPath, rel));
        dstFile.parent.createSync(recursive: true);

        out.send({'type': 'file', 'path': rel});
        final rs = srcFile.openSync();
        try {
          final ws = dstFile.openSync(mode: FileMode.write);
          try {
            final buf = Uint8List(1024 * 1024); // 1MB 块
            while (true) {
              final read = rs.readIntoSync(buf);
              if (read <= 0) break;
              ws.writeFromSync(buf, 0, read);
              sentBytesSinceThrottle += read;
              final now = DateTime.now();
              if (now.difference(lastThrottle).inMilliseconds >= 120) {
                out.send({'type': 'progress', 'bytes': sentBytesSinceThrottle});
                sentBytesSinceThrottle = 0;
                lastThrottle = now;
              }
            }
          } finally {
            ws.closeSync();
          }
        } finally {
          rs.closeSync();
        }

        // 逐文件完整性校验：复制后字节数对比
        final srcLen = srcFile.lengthSync();
        final dstLen = dstFile.lengthSync();
        if (srcLen != dstLen) {
          throw FileSystemException(
              '完整性校验失败（字节数不一致）', dstFile.path);
        }
      }
      out.send({'type': 'done'});
    } catch (e) {
      out.send({'type': 'error', 'msg': e.toString()});
    }
  }

  Future<bool> _copyViaIsolate(Directory source, String target) async {
    await Directory(target).create(recursive: true);
    final port = ReceivePort();
    Isolate? worker;
    final completer = Completer<bool>();
    String? errorMessage;

    worker = await Isolate.spawn(_copyWorker, {
      'sendPort': port.sendPort,
      'sourcePath': source.path,
      'targetPath': target,
      'failAtFile': debugFailAtRelativePath,
    });

    late final StreamSubscription sub;
    sub = port.listen((msg) {
      if (msg is! Map) return;
      switch (msg['type']) {
        case 'plan':
          _updateProgress(GameMoveProgress(
            phase: 'copying',
            totalFiles: (msg['files'] as num?)?.toInt() ?? 0,
            totalBytes: (msg['bytes'] as num?)?.toInt() ?? 0,
            copiedFiles: 0,
            copiedBytes: 0,
            currentFile: '',
          ));
          break;
        case 'file':
          _updateProgress(GameMoveProgress(
            phase: 'copying',
            totalFiles: progressNotifier.value?.totalFiles ?? 0,
            totalBytes: progressNotifier.value?.totalBytes ?? 0,
            copiedFiles: (progressNotifier.value?.copiedFiles ?? 0) + 1,
            copiedBytes: progressNotifier.value?.copiedBytes ?? 0,
            currentFile: msg['path']?.toString() ?? '',
          ));
          break;
        case 'progress':
          final done = _cancelRequested;
          final value = progressNotifier.value;
          _updateProgress(GameMoveProgress(
            phase: 'copying',
            totalFiles: value?.totalFiles ?? 0,
            totalBytes: value?.totalBytes ?? 0,
            copiedFiles: value?.copiedFiles ?? 0,
            copiedBytes: (value?.copiedBytes ?? 0) +
                ((msg['bytes'] as num?)?.toInt() ?? 0),
            currentFile: value?.currentFile ?? '',
          ));
          if (done) {
            // 取消：kill worker，目标半成品由调用方回滚清理
            worker?.kill(priority: Isolate.immediate);
            sub.cancel();
            port.close();
            if (!completer.isCompleted) completer.complete(false);
          }
          break;
        case 'done':
          sub.cancel();
          port.close();
          if (!completer.isCompleted) completer.complete(true);
          break;
        case 'error':
          errorMessage = msg['msg']?.toString();
          debugPrint('[MOVE] worker 失败: $errorMessage');
          worker?.kill(priority: Isolate.immediate);
          sub.cancel();
          port.close();
          if (!completer.isCompleted) completer.complete(false);
          break;
      }
    });

    final ok = await completer.future;
    return ok;
  }

  // ==========================================================================
  // 工具方法
  // ==========================================================================

  /// M1：写入迁移登记（先于任何目标目录写入）
  Future<void> _writePendingRecord(
      String gameTitle, String sourcePath, String targetPath) async {
    final file = File(_registryFilePath);
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'task_id': 'move-${DateTime.now().millisecondsSinceEpoch}',
      'gameTitle': gameTitle,
      'sourcePath': sourcePath,
      'targetPath': targetPath,
      'phase': 'copy',
      'startedAt': DateTime.now().toIso8601String(),
    }), flush: true);
  }

  Future<Map<String, dynamic>?> _readPendingRecord() async {
    final file = File(_registryFilePath);
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[MOVE] 迁移登记文件解析失败: $e');
      return null;
    }
  }

  Future<void> _clearPendingRecord() async {
    try {
      final file = File(_registryFilePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[MOVE] 清除迁移登记失败: $e');
    }
  }

  void _updateProgress(GameMoveProgress progress) {
    progressNotifier.value = progress;
  }

  /// 归一化路径相等比较（大小写不敏感 + 统一分隔符）
  static bool _sameNormalizedPath(String a, String b) {
    final na = PathNormalizer.forCompare(a);
    final nb = PathNormalizer.forCompare(b);
    return na.isNotEmpty && na == nb;
  }

  /// 相对路径 → 绝对路径（已绝对则原样返回，归一化分隔符）
  static String _toAbsolute(String pathStr) {
    if (pathStr.isEmpty) return pathStr;
    final d = Directory(pathStr);
    return d.absolute.path.replaceAll('/', '\\');
  }

  /// [child] 是否位于 [parent] 内部（不含相等）
  static bool _isNestedPath(String parent, String child) {
    var np = PathNormalizer.forCompare(parent);
    var nc = PathNormalizer.forCompare(child);
    if (np.isEmpty || nc.isEmpty) return false;
    if (!np.endsWith('\\')) np = '$np\\';
    return nc.startsWith(np);
  }

  /// 元数据目录是否位于本体目录内或与之相同（IMP-05 同语义）
  static bool _metaInsideBody(String metaDataDir, String bodyDir) {
    return _sameNormalizedPath(metaDataDir, bodyDir) ||
        _isNestedPath(bodyDir, metaDataDir);
  }

  /// 卷身份比较（★ 2026-09-26 NAS 映射网络驱动器适配）。
  ///
  /// 旧实现只比较盘符字母，导致两类误判：
  /// ① 源为 UNC（`\\host\share\x`）、目标为同一共享的映射盘（`Z:\x`）时
  ///    UNC 侧解析为 null → 恒判跨卷 → 本可原子 `rename` 的移动退化成
  ///    isolate copy + delete（慢，且只读共享下清源会失败）；
  /// ② `Z:` 与 `\\host\share` 混用时排重/同卷判定不一致。
  ///
  /// 现统一走 [NetworkPath.isSameVolume]：映射盘盘符经 `WNetGetUniversalNameW`
  /// 解析为 UNC 后比较，本地盘仍只比较盘符（行为不变）。
  /// 卷身份无法解析时**保守按跨卷处理**（走 copy 路径，源目录不受影响）。
  static bool _isSameVolume(String a, String b) =>
      NetworkPath.isSameVolume(a, b);

  /// 流式统计目录树总字节数（不一次性拉全树列表）
  static Future<int> _measureTreeBytes(Directory dir) async {
    int total = 0;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[MOVE] 统计目录大小异常（按已统计部分继续）: $e');
    }
    return total;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 迁移状态
enum MoveStatus { success, partial, failed }

/// 迁移结果
class MoveResult {
  final MoveStatus status;
  final String? errorMessage;

  /// 迁移的源目录（供 UI 结果页展示与注册表旧路径扫描使用）
  final String? sourcePath;

  /// M3 清源失败时的旧目录残留路径（新目录已完整可用）
  final String? sourceLeftoverPath;

  /// M4 引用切换的部分失败项描述
  final List<String> referenceWarnings;

  /// 是否走了同卷 rename 快速路径
  final bool movedViaRename;

  const MoveResult({
    required this.status,
    this.errorMessage,
    this.sourcePath,
    this.sourceLeftoverPath,
    this.referenceWarnings = const [],
    this.movedViaRename = false,
  });

  factory MoveResult.failed(String message, {String? sourcePath}) => MoveResult(
        status: MoveStatus.failed,
        errorMessage: message,
        sourcePath: sourcePath,
      );
}

/// 迁移进度快照
class GameMoveProgress {
  /// moving / copying / cleaning / switching
  final String phase;
  final int totalFiles;
  final int copiedFiles;
  final int totalBytes;
  final int copiedBytes;
  final String currentFile;

  const GameMoveProgress({
    required this.phase,
    this.totalFiles = 0,
    this.copiedFiles = 0,
    this.totalBytes = 0,
    this.copiedBytes = 0,
    this.currentFile = '',
  });

  factory GameMoveProgress.initial({required String phase, int totalBytes = 0}) =>
      GameMoveProgress(phase: phase, totalBytes: totalBytes);

  double get fraction =>
      totalBytes > 0 ? (copiedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
}

/// 启动检测到的未完成迁移记录
class PendingMoveRecord {
  final String gameTitle;
  final String sourcePath;
  final String targetPath;
  final bool targetExists;
  final bool sourceExists;

  const PendingMoveRecord({
    required this.gameTitle,
    required this.sourcePath,
    required this.targetPath,
    required this.targetExists,
    required this.sourceExists,
  });
}
