import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/path_helper.dart';

/// .rar.lz4 专用解压服务（Dart 原生实现，替代原 Python 黑盒 rar_lz4_unzip.exe）
///
/// 解压流程（复刻自反编译还原的 rar_lz4_unzip.py）：
///   1. bz.exe(Bandizip) 解 LZ4 外层 → 在源目录生成临时 .rar
///   2. UnRAR.exe 解 RAR 内层（带密码）→ 游戏文件输出到 gameOutputDir/<压缩包名>/
///   3. 删除临时 .rar
///
/// 密码：Bilibili_Slpeey（与 ExtractManager._defaultPassword 一致，
///       经反编译原 rar_lz4_unzip.exe 确认）
class RarLz4UnzipService {
  // Bandizip(bz.exe) + UnRAR.exe 运行所需的全套文件（从 Flutter asset 释放到 toolsDir）
  static const List<String> _toolFiles = [
    'bz.exe',
    'UnRAR.exe',
    'ark.x64.dll',
    'ark.x64.lgpl.dll',
    'bdzshl.x64.dll',
  ];

  // .rar.lz4 内层 RAR 的解压密码（反编译自原 rar_lz4_unzip.exe 确认）
  static const String _rarPassword = 'Bilibili_Slpeey';

  /// 首次运行时从 assets/tools 释放工具到 toolsDir
  Future<void> _ensureToolsExist() async {
    final toolsDir = Directory(PathHelper.toolsDir);
    if (!await toolsDir.exists()) {
      await toolsDir.create(recursive: true);
      debugPrint('[RAR-LZ4] 创建工具目录: ${PathHelper.toolsDir}');
    }

    // 清理旧版本遗留的 rar_lz4_unzip.exe（已废弃，改用 Dart 原生实现）
    final legacyExe = File(path.join(PathHelper.toolsDir, 'rar_lz4_unzip.exe'));
    if (await legacyExe.exists()) {
      try {
        await legacyExe.delete();
        debugPrint('[RAR-LZ4] 已清理废弃的旧工具: rar_lz4_unzip.exe');
      } catch (e) {
        debugPrint('[RAR-LZ4] ⚠️ 清理废弃工具失败: $e');
      }
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
  }

  /// 解压 .rar.lz4 文件
  ///
  /// [lz4FilePath] .rar.lz4 源文件路径
  /// [gameOutputDir] 游戏输出根目录，实际游戏文件输出到 gameOutputDir/<压缩包名>/
  /// 返回 true=成功，false=失败
  Future<bool> unzip(String lz4FilePath, String gameOutputDir) async {
    try {
      await _ensureToolsExist();

      debugPrint('[RAR-LZ4] ✅ 工具就绪');
      debugPrint('[RAR-LZ4] 📥 压缩包: $lz4FilePath');
      debugPrint('[RAR-LZ4] 📤 输出目录: $gameOutputDir');

      // --- 校验 ---
      final archiveFile = File(lz4FilePath);
      if (!await archiveFile.exists()) {
        debugPrint('[RAR-LZ4] ❌ ERR_FILE_NOT_EXIST: $lz4FilePath');
        return false;
      }

      if (!lz4FilePath.toLowerCase().endsWith('.rar.lz4')) {
        debugPrint('[RAR-LZ4] ❌ ERR_NOT_RAR_LZ4: $lz4FilePath');
        return false;
      }

      // --- 路径计算（复刻原 rar_lz4_unzip.py 逻辑）---
      // base_dir     = 源文件所在目录（临时 .rar 生成于此）
      // name_clear   = 去掉 .rar.lz4 后缀的压缩包名（也是输出子目录名）
      // target_dir   = gameOutputDir/name_clear（游戏文件最终输出目录）
      // temp_rar     = base_dir/name_clear.rar（LZ4 解压后的临时 RAR）
      final baseDir = path.dirname(lz4FilePath);
      final fullName = path.basename(lz4FilePath);
      final nameClear =
          fullName.replaceAll(RegExp(r'\.rar\.lz4$', caseSensitive: false), '');
      final targetDir = path.join(gameOutputDir, nameClear);
      final tempRarPath = '${path.join(baseDir, nameClear)}.rar';

      debugPrint('[RAR-LZ4] name_clear: $nameClear');
      debugPrint('[RAR-LZ4] target_dir: $targetDir');
      debugPrint('[RAR-LZ4] temp_rar: $tempRarPath');

      // 创建目标目录
      final targetDirObj = Directory(targetDir);
      if (!await targetDirObj.exists()) {
        await targetDirObj.create(recursive: true);
        debugPrint('[RAR-LZ4] 已创建目标目录: $targetDir');
      }

      // 若临时 .rar 已存在则先删除
      final tempRarFile = File(tempRarPath);
      if (await tempRarFile.exists()) {
        await tempRarFile.delete();
        debugPrint('[RAR-LZ4] 已删除旧的临时 .rar: $tempRarPath');
      }

      // --- 第一步：bz.exe(Bandizip) 解 LZ4 外层，得到 .rar ---
      // 命令: bz.exe x -y <lz4_file> <base_dir>\
      // 输出目录参数带尾部 '\\' 以区分"解压到目录"与"解压为文件"
      debugPrint('[RAR-LZ4] 🔹 第1步: bz.exe 解 LZ4 外层...');
      final lz4Result = await Process.run(
        PathHelper.bandizipExePath,
        ['x', '-y', lz4FilePath, '$baseDir\\'],
        workingDirectory: PathHelper.toolsDir,
        runInShell: false,
        includeParentEnvironment: true,
      );

      final lz4Stdout = lz4Result.stdout.toString().trim();
      final lz4Stderr = lz4Result.stderr.toString().trim();
      debugPrint('[RAR-LZ4] bz.exe 返回码: ${lz4Result.exitCode}');
      if (lz4Stdout.isNotEmpty) debugPrint('[RAR-LZ4] bz.exe 输出: $lz4Stdout');
      if (lz4Stderr.isNotEmpty) debugPrint('[RAR-LZ4] bz.exe 错误: $lz4Stderr');

      if (lz4Result.exitCode != 0) {
        debugPrint(
            '[RAR-LZ4] ❌ ERR_LZ4_EXTRACT: bz.exe 退出码 ${lz4Result.exitCode}');
        return false;
      }

      // 校验临时 .rar 是否生成
      if (!await tempRarFile.exists()) {
        debugPrint(
            '[RAR-LZ4] ❌ ERR_RAR_NOT_FOUND: 解压外层后未生成 $tempRarPath');
        return false;
      }

      // --- 第二步：UnRAR.exe 解 RAR 内层（带密码）---
      // 命令: UnRAR.exe x -pBilibili_Slpeey -y <temp_rar> <target_dir>\
      debugPrint('[RAR-LZ4] 🔹 第2步: UnRAR.exe 解 RAR 内层（带密码）...');
      final rarResult = await Process.run(
        PathHelper.unrarExePath,
        ['x', '-p$_rarPassword', '-y', tempRarPath, '$targetDir\\'],
        workingDirectory: PathHelper.toolsDir,
        runInShell: false,
        includeParentEnvironment: true,
      );

      final rarStdout = rarResult.stdout.toString().trim();
      final rarStderr = rarResult.stderr.toString().trim();
      debugPrint('[RAR-LZ4] UnRAR.exe 返回码: ${rarResult.exitCode}');
      if (rarStdout.isNotEmpty) debugPrint('[RAR-LZ4] UnRAR.exe 输出: $rarStdout');
      if (rarStderr.isNotEmpty) debugPrint('[RAR-LZ4] UnRAR.exe 错误: $rarStderr');

      if (rarResult.exitCode != 0) {
        debugPrint(
            '[RAR-LZ4] ❌ ERR_RAR_EXTRACT: UnRAR.exe 退出码 ${rarResult.exitCode}');
        // 失败也尝试清理临时 .rar
        await _safeDelete(tempRarFile);
        return false;
      }

      // --- 清理临时 .rar ---
      await _safeDelete(tempRarFile);

      debugPrint('[RAR-LZ4] ✅ SUCCESS: .rar.lz4 解压完成');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[RAR-LZ4] ❌ 调用异常: $e');
      debugPrint('[RAR-LZ4] 堆栈: $stackTrace');
      return false;
    }
  }

  /// 安全删除文件（忽略删除失败）
  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
        debugPrint('[RAR-LZ4] 已清理临时文件: ${file.path}');
      }
    } catch (e) {
      debugPrint('[RAR-LZ4] ⚠️ 清理临时文件失败: ${file.path} | $e');
    }
  }
}
