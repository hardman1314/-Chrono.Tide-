import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/path_helper.dart';

class RarLz4UnzipService {
  static const List<String> _toolFiles = [
    'rar_lz4_unzip.exe',
    'bz.exe',
    'UnRAR.exe',
    'ark.x64.dll',
    'ark.x64.lgpl.dll',
    'bdzshl.x64.dll',
  ];

  Future<String> _ensureToolsExist() async {
    final toolsDir = Directory(PathHelper.toolsDir);
    if (!await toolsDir.exists()) {
      await toolsDir.create(recursive: true);
      debugPrint('[RAR-LZ4] 创建工具目录: ${PathHelper.toolsDir}');
    }

    for (final fileName in _toolFiles) {
      final destFile = File(path.join(PathHelper.toolsDir, fileName));
      if (!await destFile.exists()) {
        try {
          final assetPath = 'assets/tools/$fileName';
          final byteData = await rootBundle.load(assetPath);
          final bytes = byteData.buffer.asUint8List();
          await destFile.writeAsBytes(bytes);
          debugPrint(
              '[RAR-LZ4] 从Assets复制: $fileName (${(bytes.length / 1024).toStringAsFixed(1)}KB)');
        } catch (e) {
          debugPrint('[RAR-LZ4] ⚠️ 无法从Assets复制 $fileName: $e');
        }
      }
    }

    return PathHelper.rarLz4UnzipExePath;
  }

  Future<bool> unzip(String lz4FilePath, String gameOutputDir) async {
    try {
      final exePath = await _ensureToolsExist();

      final exeFile = File(exePath);
      if (!await exeFile.exists()) {
        debugPrint('[RAR-LZ4] ❌ 工具不存在: $exePath');
        return false;
      }

      debugPrint('[RAR-LZ4] ✅ 工具就绪: $exePath');
      debugPrint('[RAR-LZ4] 📥 压缩包: $lz4FilePath');
      debugPrint('[RAR-LZ4] 📤 输出目录: $gameOutputDir');

      final result = await Process.run(
        exePath,
        [lz4FilePath, gameOutputDir],
        workingDirectory: PathHelper.toolsDir,
        runInShell: false,
        includeParentEnvironment: true,
      );

      final output = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();

      debugPrint('[RAR-LZ4] 📝 返回码: ${result.exitCode}');
      if (output.isNotEmpty) debugPrint('[RAR-LZ4] 📝 输出: $output');
      if (stderr.isNotEmpty) debugPrint('[RAR-LZ4] ⚠️ 错误输出: $stderr');

      return output == "SUCCESS";
    } catch (e, stackTrace) {
      debugPrint('[RAR-LZ4] ❌ 调用异常: $e');
      debugPrint('[RAR-LZ4] 堆栈: $stackTrace');
      return false;
    }
  }
}
