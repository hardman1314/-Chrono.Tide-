import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_pkg;
import '../core/path_helper.dart';
import '../models/game_metadata.dart';

class MetadataScraperService {
  static String? _resolvedExecutable;

  static String get _scriptPath {
    if (_resolvedExecutable != null) return _resolvedExecutable!;

    // 优先使用 runtime/ 目录下的 EXE（新路径）
    final exePath = PathHelper.scraperServicePath;
    if (File(exePath).existsSync()) {
      _resolvedExecutable = exePath;
      debugPrint('[MetadataScraper] 使用 EXE 模式: $exePath');
      return exePath;
    }

    // 兼容旧路径：根目录下的 scraper_service.exe
    final legacyExePath =
        path_pkg.join(PathHelper.exeDir, 'scraper_service.exe');
    if (File(legacyExePath).existsSync()) {
      _resolvedExecutable = legacyExePath;
      debugPrint('[MetadataScraper] 使用 EXE 模式(兼容): $legacyExePath');
      return legacyExePath;
    }

    // Python 模式（开发环境）
    final pyPath =
        path_pkg.join(PathHelper.exeDir, 'python', 'scraper_service.py');
    if (File(pyPath).existsSync()) {
      _resolvedExecutable = pyPath;
      debugPrint('[MetadataScraper] 使用 Python 模式: $pyPath');
      return pyPath;
    }

    _resolvedExecutable = path_pkg.join('python', 'scraper_service.py');
    debugPrint('[MetadataScraper] ⚠️ 未找到抓取工具，使用默认路径: $_resolvedExecutable');
    return _resolvedExecutable!;
  }

  static bool get _isExeMode => _scriptPath.endsWith('.exe');

  static const bool _silentMode = true;

  static Future<SearchResult> searchGame(String query) async {
    if (query.trim().isEmpty) {
      throw ArgumentError('查询词不能为空');
    }

    try {
      print('[MetadataScraper] 开始查询: $query');

      var args = [_scriptPath, '--query', query];
      if (_silentMode) {
        args.add('--silent');
      }

      String executable;
      if (_isExeMode) {
        executable = _scriptPath;
        args = ['--query', query];
        if (_silentMode) {
          args.add('--silent');
        }
      } else {
        executable = Platform.isWindows ? 'python' : 'python3';
      }

      var process = await Process.run(
        executable,
        args,
        runInShell: !_isExeMode,
        stdoutEncoding: Encoding.getByName('utf-8'),
        stderrEncoding: Encoding.getByName('utf-8'),
      );

      if (process.exitCode != 0) {
        var error = process.stderr.toString().trim();
        if (error.isEmpty) {
          error =
              '${_isExeMode ? "抓取程序" : "Python脚本"}执行失败 (exit code: ${process.exitCode})';
        }
        throw Exception(error);
      }

      var output = process.stdout.toString().trim();

      if (output.isEmpty) {
        throw Exception('${_isExeMode ? "抓取程序" : "Python脚本"}无输出');
      }

      Map<String, dynamic> jsonData;
      try {
        jsonData = jsonDecode(output);
      } catch (e) {
        throw Exception(
            'JSON解析失败: ${output.substring(0, output.length.clamp(0, 200))}');
      }

      var result = SearchResult.fromJson(jsonData);

      print('[MetadataScraper] 查询完成: '
          '${result.totalCount}个结果 (${result.elapsedSeconds}s)');

      return result;
    } on FormatException catch (e) {
      throw Exception('数据格式错误: $e');
    } catch (e) {
      print('[MetadataScraper] 错误: $e');
      rethrow;
    }
  }

  static Future<List<SearchResult>> batchSearch(
    List<String> queries, {
    int delay = 1500,
  }) async {
    List<SearchResult> results = [];

    for (var i = 0; i < queries.length; i++) {
      var query = queries[i].trim();
      if (query.isEmpty) continue;

      try {
        print('[Batch] 查询 [${i + 1}/${queries.length}]: $query');

        var result = await searchGame(query);
        results.add(result);

        if (i < queries.length - 1) {
          await Future.delayed(Duration(milliseconds: delay));
        }
      } catch (e) {
        print('[Batch] 查询失败 [$query]: $e');
      }
    }

    return results;
  }

  static Future<bool> testConnection() async {
    try {
      var result = await searchGame('CLANNAD');
      return result.success && result.hasResults;
    } catch (e) {
      print('[Test] 连接测试失败: $e');
      return false;
    }
  }

  static Future<void> dispose() async {
    debugPrint('[MetadataScraper] 终止抓取程序进程...');
    try {
      final result = await Process.run(
        'taskkill',
        ['/IM', 'scraper_service.exe', '/F', '/T'],
        runInShell: true,
      );
      if (result.exitCode == 0) {
        debugPrint('[MetadataScraper] ✅ scraper_service.exe 已终止');
      } else {
        final stderr = result.stderr.toString().trim();
        if (stderr.contains('not found') || stderr.isEmpty) {
          debugPrint('[MetadataScraper] ✅ 无运行中的 scraper_service.exe 进程');
        } else {
          debugPrint('[MetadataScraper] ⚠️ 终止警告: $stderr');
        }
      }
    } catch (e) {
      debugPrint('[MetadataScraper] ⚠️ 终止异常（非致命）: $e');
    }
    _resolvedExecutable = null;
  }
}
