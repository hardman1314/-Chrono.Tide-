import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import '../core/path_helper.dart';
import '../pages/join/utils/gal_game_detector.dart';
import 'storage/log_rotation_service.dart';

/// 扫描跳过原因
enum ScanSkipReason {
  /// 已入库
  alreadyImported,

  /// 父子目录重叠（与已找到的游戏互为父子）
  parentChildOverlap,

  /// 无可执行文件
  noExecutable,

  /// 置信度不足（识别器判定为非游戏）
  lowConfidence,

  /// 收集阶段被排除规则过滤
  excludedPattern,

  /// 共享启动程序（与已找到游戏共享 exe）
  sharedLauncher,

  /// 归纳文件夹（如 GAL/游戏库，本身非游戏但包含多个游戏子目录）
  aggregateFolder,

  /// 路径包含冲突（与已入库游戏路径有包含关系，硬跳过）
  pathConflict,

  /// 同名可能重复（软警告，实际不跳过但记录）
  possibleDuplicate,

  /// 同名副本（清洗后同名且引擎兼容的另一份拷贝，保留识别度最高者）
  duplicateTitle,
}

/// 扫描摘要
///
/// 记录一次扫描的接受/跳过统计，供 UI 展示与日志输出。
class ScanSummary {
  int accepted = 0;
  final Map<ScanSkipReason, int> _skips = {};
  final List<String> acceptedPaths = [];
  final List<String> skippedPaths = [];

  void addAccepted(String p) {
    accepted++;
    acceptedPaths.add(p);
  }

  void addSkipped(String p, ScanSkipReason r) {
    _skips[r] = (_skips[r] ?? 0) + 1;
    skippedPaths.add(p);
  }

  int get totalSkipped => skippedPaths.length;
  int get totalCandidates => accepted + totalSkipped;

  /// 人类可读摘要文案
  ///
  /// 示例：
  /// - 「识别到 5 个新游戏」
  /// - 「识别到 5 个新游戏，跳过 3 个（2 已导入、1 低置信度）」
  /// - 「未发现游戏，跳过 3 个（2 已导入、1 低置信度）」
  String get humanReadable {
    if (accepted == 0 && totalSkipped == 0) return '未发现游戏';

    final parts = <String>[];
    if (accepted > 0) {
      parts.add('识别到 $accepted 个新游戏');
    }
    if (totalSkipped > 0) {
      final detail = _skips.entries.map((e) {
        final count = e.value;
        final label = _reasonLabel(e.key);
        return '$count $label';
      }).join('、');
      parts.add('跳过 $totalSkipped 个（$detail）');
    }
    return parts.join('，');
  }

  static String _reasonLabel(ScanSkipReason r) {
    switch (r) {
      case ScanSkipReason.alreadyImported:
        return '已导入';
      case ScanSkipReason.parentChildOverlap:
        return '父子重叠';
      case ScanSkipReason.noExecutable:
        return '无启动程序';
      case ScanSkipReason.lowConfidence:
        return '低置信度';
      case ScanSkipReason.excludedPattern:
        return '排除规则';
      case ScanSkipReason.sharedLauncher:
        return '共享启动程序';
      case ScanSkipReason.aggregateFolder:
        return '归纳文件夹';
      case ScanSkipReason.pathConflict:
        return '路径冲突';
      case ScanSkipReason.possibleDuplicate:
        return '可能重复';
      case ScanSkipReason.duplicateTitle:
        return '同名副本';
    }
  }
}

/// 扫描日志记录器
///
/// 模仿 [LocaleLogger] 结构，将每次扫描过程写入独立日志文件
/// `<exeDir>/logs/scan_<timestamp>.log`，最多保留 [_maxLogFiles] 份轮转。
///
/// 使用方式：
/// ```dart
/// final summary = ScanSummary();
/// ScanLogger.instance.startScan(rootPath, candidateCount);
/// for (final path in candidates) {
///   // 决策...
///   ScanLogger.instance.logCandidate(path, accepted: true, summary: summary);
/// }
/// ScanLogger.instance.endScan(summary);
/// ```
class ScanLogger {
  static final ScanLogger instance = ScanLogger._();
  ScanLogger._();

  static const int _maxLogFiles = 10;

  StringBuffer? _buffer;
  DateTime? _scanStart;

  /// 最近一次扫描的摘要文案（供 UI 读取）
  ///
  /// 在 [endScan] 中赋值，每次 [startScan] 时清空。
  String? _lastSummaryText;
  String? get lastSummaryText => _lastSummaryText;

  /// 开始一次新扫描
  ///
  /// 重置内部 buffer 与时间戳。同一时刻仅支持单次扫描（单例模式）。
  void startScan(String rootPath, int candidateCount) {
    _scanStart = DateTime.now();
    _lastSummaryText = null;
    _buffer = StringBuffer();
    _buffer!.writeln('========================================');
    _buffer!.writeln(' 批量导入扫描日志');
    _buffer!.writeln(' 开始时间: ${_scanStart!.toIso8601String()}');
    _buffer!.writeln(' 根目录: $rootPath');
    _buffer!.writeln(' 候选目录数: $candidateCount');
    _buffer!.writeln('========================================');
    _buffer!.writeln('');
  }

  /// 记录单个候选目录的决策
  ///
  /// [accepted] 是否被接受为游戏；
  /// [reason] 跳过原因（accepted=false 时必填）；
  /// [detection] 识别器结果（含 confidence 与 reasonSummary，可选）。
  void logCandidate(
    String candidatePath, {
    required bool accepted,
    required ScanSummary summary,
    ScanSkipReason? reason,
    GalDetectionResult? detection,
  }) {
    if (_buffer == null) return;

    final folderName = candidatePath.split('/').last.split('\\').last;
    if (accepted) {
      _buffer!.writeln('✓ 接受: $folderName');
      _buffer!.writeln('  路径: $candidatePath');
      if (detection != null) {
        _buffer!.writeln('  置信度: ${(detection.confidence * 100).toInt()}%');
        _buffer!.writeln('  引擎: ${detection.engineType}');
        _buffer!.writeln('  依据: ${detection.reasonSummary}');
        if (detection.mainExeName != null) {
          _buffer!.writeln('  主程序: ${detection.mainExeName}');
        }
      }
      summary.addAccepted(candidatePath);
    } else {
      final r = reason ?? ScanSkipReason.lowConfidence;
      _buffer!.writeln('✗ 跳过: $folderName [${ScanSummary._reasonLabel(r)}]');
      _buffer!.writeln('  路径: $candidatePath');
      if (detection != null) {
        _buffer!.writeln('  置信度: ${(detection.confidence * 100).toInt()}%');
        _buffer!.writeln('  依据: ${detection.reasonSummary}');
        if (detection.negativeSignals.isNotEmpty) {
          _buffer!.writeln('  负信号: ${detection.negativeSignals.join(", ")}');
        }
      } else if (r == ScanSkipReason.noExecutable) {
        _buffer!.writeln('  原因: 无可执行文件');
      } else if (r == ScanSkipReason.alreadyImported) {
        _buffer!.writeln('  原因: 已入库');
      } else if (r == ScanSkipReason.parentChildOverlap) {
        _buffer!.writeln('  原因: 与已找到游戏父子重叠');
      } else if (r == ScanSkipReason.sharedLauncher) {
        _buffer!.writeln('  原因: 共享启动程序');
      } else if (r == ScanSkipReason.pathConflict) {
        _buffer!.writeln('  原因: 路径冲突（与已入库游戏路径有包含关系）');
      } else if (r == ScanSkipReason.possibleDuplicate) {
        _buffer!.writeln('  原因: 同名可能重复（软警告，未跳过）');
      }
      _buffer!.writeln('');
      // possibleDuplicate 为软警告，仅记录日志但不计入跳过统计
      if (r != ScanSkipReason.possibleDuplicate) {
        summary.addSkipped(candidatePath, r);
      }
    }
    _buffer!.writeln('');
  }

  /// 记录非致命错误（如收集阶段异常）
  void logError(String msg) {
    _buffer?.writeln('⚠ 错误: $msg');
    _buffer?.writeln('');
  }

  /// 结束扫描并写入磁盘
  ///
  /// 将累积的 buffer 写入 `logs/scan_<timestamp>.log`，并执行轮转。
  /// 同时更新 [_lastSummaryText] 供 UI 读取。
  Future<void> endScan(ScanSummary summary) async {
    final end = DateTime.now();
    final duration = _scanStart != null ? end.difference(_scanStart!) : Duration.zero;

    _buffer?.writeln('========================================');
    _buffer?.writeln(' 扫描结束: ${end.toIso8601String()}');
    _buffer?.writeln(' 耗时: ${duration.inMilliseconds}ms');
    _buffer?.writeln(' 结果: ${summary.humanReadable}');
    _buffer?.writeln('   - 接受: ${summary.accepted}');
    _buffer?.writeln('   - 跳过: ${summary.totalSkipped}');
    _buffer?.writeln('========================================');

    _lastSummaryText = summary.humanReadable;

    await _writeToFile();
    await _rotateLogs();

    _buffer = null;
    _scanStart = null;
  }

  /// 写入日志文件到 [PathHelper.logsDir]
  Future<void> _writeToFile() async {
    if (_buffer == null || _scanStart == null) return;
    try {
      final logsDir = Directory(PathHelper.logsDir);
      if (!logsDir.existsSync()) {
        await logsDir.create(recursive: true);
      }
      final timestamp = _formatTimestamp(_scanStart!);
      final filePath = path.join(PathHelper.logsDir, 'scan_$timestamp.log');
      final file = File(filePath);
      await file.writeAsString(_buffer.toString());
      debugPrint('[SCAN-LOG] ✅ 扫描日志已写入: $filePath');
    } catch (e) {
      debugPrint('[SCAN-LOG] ❌ 写入日志失败: $e');
    }
  }

  /// 轮转日志文件,委托给 LogRotationService 统一管理。
  Future<void> _rotateLogs() async {
    try {
      await LogRotationService.instance.rotateByCount(
        PathHelper.logsDir,
        'scan_',
        _maxLogFiles,
      );
    } catch (e) {
      debugPrint('[SCAN-LOG] ⚠️ 轮转日志异常: $e');
    }
  }

  /// 格式化时间戳用于文件名（避免非法字符）
  static String _formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '${y}${m}${d}_${h}${mi}${s}';
  }
}
