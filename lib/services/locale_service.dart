import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/path_helper.dart';

enum PeArchitecture { x86, x64, unknown }

class LocaleService {
  static String? _resolvedLrProcPath;
  static bool? _availabilityCache;
  static final List<String> _logBuffer = [];
  static const int _maxLogEntries = 500;

  static const int _peSignatureOffset = 0x3C;
  static const List<int> _peSignature = [0x50, 0x45, 0x00, 0x00];
  static const int _machineFieldOffset = 4;
  static const int _machineI386 = 0x014C;
  static const int _machineAmd64 = 0x8664;

  static Future<String?> get _leProcPath async {
    if (_resolvedLrProcPath != null) {
      if (File(_resolvedLrProcPath!).existsSync()) {
        return _resolvedLrProcPath;
      }
      _resolvedLrProcPath = null;
    }

    // 使用 PathHelper 统一路径（runtime/locale_emulator/）
    final possiblePaths = [
      PathHelper.leProcPath,
    ];

    for (final lePath in possiblePaths) {
      if (File(lePath).existsSync()) {
        _resolvedLrProcPath = lePath;
        _log('INFO', '✅ 找到内置 LE: $lePath');
        return _resolvedLrProcPath;
      }
    }

    _log('ERROR', '❌ 未找到内置 LEProc.exe');
    _log('ERROR', '   搜索路径:');
    for (final lePath in possiblePaths) {
      _log('ERROR',
          '     - $lePath (${File(lePath).existsSync() ? "存在" : "不存在"})');
    }
    _log('ERROR', '');
    _log('ERROR', '💡 请确保打包时包含 runtime/locale_emulator 文件夹及 LEProc.exe');

    return null;
  }

  static Future<bool> isLocaleAvailable() async {
    if (_availabilityCache != null) return _availabilityCache!;

    final lePath = await _leProcPath;
    _availabilityCache = lePath != null && File(lePath).existsSync();

    if (_availabilityCache!) {
      _log('INFO', '✅ 内置 Locale Emulator 可用');
    } else {
      _log('WARN', '⚠️ 内置 Locale Emulator 不可用');
    }

    return _availabilityCache!;
  }

  static PeArchitecture detectPeArchitecture(String exePath) {
    try {
      final file = File(exePath);
      if (!file.existsSync()) {
        _log('ERROR', '文件不存在: $exePath');
        return PeArchitecture.unknown;
      }

      final bytes = file.readAsBytesSync();
      if (bytes.length < 64) {
        _log('WARN', '文件过小: $exePath');
        return PeArchitecture.unknown;
      }

      final peOffsetByteData = ByteData.sublistView(
          Uint8List.fromList(
              bytes.sublist(_peSignatureOffset, _peSignatureOffset + 4)),
          0);
      final peOffset = peOffsetByteData.getUint32(0, Endian.little);

      if (peOffset + _machineFieldOffset + 2 > bytes.length) {
        return PeArchitecture.unknown;
      }

      final sigStart = peOffset;
      for (int i = 0; i < 4; i++) {
        if (bytes[sigStart + i] != _peSignature[i]) {
          return PeArchitecture.unknown;
        }
      }

      final machine = ByteData.sublistView(
              Uint8List.fromList(bytes.sublist(sigStart + _machineFieldOffset,
                  sigStart + _machineFieldOffset + 2)),
              0)
          .getUint16(0, Endian.little);

      if (machine == _machineI386) return PeArchitecture.x86;
      if (machine == _machineAmd64) return PeArchitecture.x64;

      return PeArchitecture.unknown;
    } catch (_) {
      return PeArchitecture.unknown;
    }
  }

  static Future<ProcessResult> launchWithLocale(
    String exePath, {
    String? workingDir,
    String locale = 'ja-JP',
  }) async {
    final startTime = DateTime.now();
    _log('INFO', '═══════════════════════════════════════');
    _log('INFO', '🌸 开始转区启动流程');
    _log('INFO', '目标程序: $exePath');
    _log('INFO', '工作目录: ${workingDir ?? "自动检测"}');

    final exeFile = File(exePath);
    if (!exeFile.existsSync()) {
      _log('ERROR', '❌ 目标程序不存在: $exePath');
      throw ArgumentError('目标程序不存在: $exePath');
    }

    final absExePath = exeFile.absolute.path;
    final effectiveWorkingDir = workingDir != null
        ? Directory(workingDir).absolute.path
        : exeFile.parent.absolute.path;

    if (!Directory(effectiveWorkingDir).existsSync()) {
      _log('ERROR', '❌ 工作目录不存在: $effectiveWorkingDir');
      throw ArgumentError('工作目录不存在: $effectiveWorkingDir');
    }

    final architecture = detectPeArchitecture(absExePath);
    _log('INFO', '程序架构: $architecture');

    final lePath = await _leProcPath;
    if (lePath == null) {
      _log('ERROR', '❌ 内置 LE 未找到');
      _log('ERROR', '');
      _log('ERROR', '🔧 解决方案:');
      _log('ERROR', '   1. 重新打包软件（确保 runtime/locale_emulator 文件夹被包含）');
      _log('ERROR', '   2. 检查 Release/runtime/locale_emulator/LEProc.exe 是否存在');
      throw StateError('内置 Locale Emulator 缺失，请重新安装软件');
    }

    _log('INFO', 'LE 路径: $lePath');
    _log('INFO', '完整参数: "$absExePath"');

    try {
      _log('INFO', '正在启动 LE 进程...');

      final result = await Process.run(
        lePath,
        [absExePath],
        workingDirectory: effectiveWorkingDir,
        runInShell: false,
        includeParentEnvironment: true,
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          return ProcessResult(-1, -1, '', 'LE 启动超时');
        },
      );

      final duration = DateTime.now().difference(startTime).inMilliseconds;

      _log('INFO', 'LE 执行完毕 | 耗时: ${duration}ms | 退出码: ${result.exitCode}');

      if (result.stdout.toString().trim().isNotEmpty) {
        _log('INFO', '标准输出: ${result.stdout}');
      }
      if (result.stderr.toString().trim().isNotEmpty) {
        _log('WARN', '错误输出: ${result.stderr}');
      }

      await Future.delayed(const Duration(milliseconds: 3000));

      final processName = absExePath.split(Platform.pathSeparator).last;
      _log('INFO', '验证进程存活: $processName...');

      final isAlive = await _checkProcessAlive(processName);

      if (isAlive) {
        _log('INFO', '✅ 游戏成功启动并运行中!');
      } else {
        _log('WARN', '⚠️ 未检测到游戏进程（可能已退出或启动延迟）');

        await Future.delayed(const Duration(milliseconds: 2000));
        if (await _checkProcessAlive(processName)) {
          _log('INFO', '✅ 延迟检测成功!');
        } else {
          _log('ERROR', '❌ 游戏未能成功启动');

          if (result.exitCode != 0) {
            _log('ERROR', 'LE 返回非零退出码: ${result.exitCode}');
            _log('ERROR', '这可能意味着游戏启动失败或 LE 配置有误');
          }
        }
      }

      _log('INFO', '═══════════════════════════════════════');
      return result;
    } catch (e) {
      _log('ERROR', '❌ 启动异常: $e');
      _log('INFO', '═══════════════════════════════════════');
      rethrow;
    }
  }

  static Future<bool> _checkProcessAlive(String processName) async {
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq $processName', '/NH'],
        runInShell: true,
      );
      return result.stdout.toString().contains(processName);
    } catch (_) {
      return false;
    }
  }

  static void _log(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final logEntry = '[$timestamp] [$level] [LocaleService] $message';
    _logBuffer.add(logEntry);

    if (_logBuffer.length > _maxLogEntries) {
      _logBuffer.removeRange(0, _logBuffer.length - _maxLogEntries);
    }
    debugPrint(logEntry);
  }

  static List<String> getLogs({int? limit}) {
    if (limit != null && limit < _logBuffer.length) {
      return _logBuffer.sublist(_logBuffer.length - limit);
    }
    return List.from(_logBuffer);
  }

  static void clearLogs() => _logBuffer.clear();

  static void exportLogs(String filePath) =>
      File(filePath).writeAsStringSync(_logBuffer.join('\n'));

  static void clearCache() {
    _resolvedLrProcPath = null;
    _availabilityCache = null;
    _log('INFO', '缓存已清除');
  }
}
