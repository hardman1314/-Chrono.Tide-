import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/path_helper.dart';
import 'game_data_format.dart';
import 'local_game_registry.dart';

/// 桌面快捷方式管理服务
///
/// 通过 PowerShell 调用 WScript.Shell COM 对象创建/删除 .lnk 快捷方式。
/// 快捷方式目标指向主程序 exe，通过 --launch-game 参数传递游戏标题。
/// 图标默认使用游戏 exe 自带图标，也支持自定义 .ico 文件。
class ShortcutService {
  static final ShortcutService _instance = ShortcutService._internal();
  static ShortcutService get instance => _instance;

  ShortcutService._internal();

  /// 桌面目录路径
  String get _desktopPath {
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    if (userProfile.isEmpty) return p.join(Directory.current.path, 'Desktop');
    return p.join(userProfile, 'Desktop');
  }

  /// 主程序 exe 路径
  String get _appExePath => Platform.resolvedExecutable;

  /// 主程序工作目录
  String get _appWorkingDir => PathHelper.exeDir;

  /// 转义字符串用于 PowerShell 单引号上下文
  /// 在 PowerShell 单引号字符串中，唯一需要转义的是单引号本身，用 '' 表示
  String _psEscape(String value) {
    return value.replaceAll("'", "''");
  }

  /// 生成安全的快捷方式文件名
  String _sanitizeFileName(String title) {
    final safe = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return safe.isEmpty ? 'UnknownGame' : safe;
  }

  /// 获取快捷方式的完整路径
  String getShortcutPath(String gameTitle) {
    return p.join(_desktopPath, '${_sanitizeFileName(gameTitle)}.lnk');
  }

  /// 检查桌面快捷方式是否存在
  bool hasShortcut(String gameTitle) {
    return File(getShortcutPath(gameTitle)).existsSync();
  }

  /// 创建桌面快捷方式
  ///
  /// [gameTitle] 游戏标题（用于快捷方式名称和启动参数）
  /// [exePath] 游戏 exe 路径（用于提取默认图标）
  /// [gameDirectory] 游戏目录（用于解析相对路径）
  /// [customIconPath] 自定义图标路径（.ico 文件），为空则使用 exe 自带图标
  /// [localeMode] 转区模式（写入快捷方式备注）
  /// [upscalingMode] 超分模式（写入快捷方式备注）
  Future<bool> createShortcut({
    required String gameTitle,
    required String exePath,
    required String gameDirectory,
    String? customIconPath,
    String localeMode = 'none',
    String upscalingMode = 'none',
  }) async {
    try {
      final shortcutPath = getShortcutPath(gameTitle);
      final appExe = _appExePath;
      final appDir = _appWorkingDir;

      // 确定图标位置
      String iconLocation;
      if (customIconPath != null && customIconPath.isNotEmpty && File(customIconPath).existsSync()) {
        iconLocation = '$customIconPath,0';
      } else if (exePath.isNotEmpty && File(exePath).existsSync()) {
        // 使用游戏 exe 自带的图标
        iconLocation = '$exePath,0';
      } else {
        // 回退到主程序图标
        iconLocation = '$appExe,0';
      }

      // 构建启动参数
      final args = '--launch-game="$gameTitle"';

      // 构建 PowerShell 脚本（使用单引号字符串防止注入）
      // 单引号字符串中 PowerShell 不解释 $, `, " 等特殊字符
      // 唯一需要转义的是单引号本身（用 '' 表示）
      final psScript = """
\$ws = New-Object -ComObject WScript.Shell
\$shortcut = \$ws.CreateShortcut('${_psEscape(shortcutPath)}')
\$shortcut.TargetPath = '${_psEscape(appExe)}'
\$shortcut.Arguments = '${_psEscape(args)}'
\$shortcut.WorkingDirectory = '${_psEscape(appDir)}'
\$shortcut.IconLocation = '${_psEscape(iconLocation)}'
\$shortcut.WindowStyle = 7
\$shortcut.Description = '${_psEscape("Chrono Tide - $gameTitle | Locale: $localeMode | Upscaling: $upscalingMode")}'
\$shortcut.Save()
Write-Output 'SUCCESS'
""";

      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', psScript],
      );

      if (result.exitCode == 0 && result.stdout.toString().contains('SUCCESS')) {
        // 保存快捷方式路径到 game.json
        final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
        if (game != null) {
          await GameDataFormat.updateGameJson(game.metaDataDir, {
            'shortcut_path': shortcutPath,
            'custom_icon_path': customIconPath ?? '',
          });
        }
        debugPrint('[SHORTCUT] ✅ 快捷方式已创建: $shortcutPath');
        return true;
      } else {
        debugPrint('[SHORTCUT] ❌ 创建失败: ${result.stderr}');
        return false;
      }
    } catch (e) {
      debugPrint('[SHORTCUT] ❌ 创建异常: $e');
      return false;
    }
  }

  /// 删除桌面快捷方式
  Future<bool> deleteShortcut(String gameTitle) async {
    try {
      final shortcutPath = getShortcutPath(gameTitle);
      final file = File(shortcutPath);

      if (await file.exists()) {
        await file.delete();

        // 清除 game.json 中的记录
        final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
        if (game != null) {
          await GameDataFormat.updateGameJson(game.metaDataDir, {
            'shortcut_path': '',
          });
        }

        debugPrint('[SHORTCUT] ✅ 快捷方式已删除: $shortcutPath');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[SHORTCUT] ❌ 删除异常: $e');
      return false;
    }
  }

  /// 更新快捷方式图标
  ///
  /// 重新创建快捷方式，使用新的图标路径
  Future<bool> updateShortcutIcon({
    required String gameTitle,
    required String exePath,
    required String gameDirectory,
    String? customIconPath,
    String localeMode = 'none',
    String upscalingMode = 'none',
  }) async {
    return createShortcut(
      gameTitle: gameTitle,
      exePath: exePath,
      gameDirectory: gameDirectory,
      customIconPath: customIconPath,
      localeMode: localeMode,
      upscalingMode: upscalingMode,
    );
  }

  /// ★ H8: 游戏标题变更后更新桌面快捷方式
  /// 删除旧标题的快捷方式，用新标题重新创建（保持 exe 路径/图标等不变）
  Future<bool> updateShortcutTitle(String oldTitle, String newTitle) async {
    try {
      final oldPath = getShortcutPath(oldTitle);
      if (!File(oldPath).existsSync()) {
        debugPrint('[SHORTCUT] 旧标题无快捷方式，跳过更新: $oldTitle');
        return false;
      }

      // 读取旧快捷方式的目标信息（从 game.json 获取）
      final game = LocalGameRegistry.instance.getGameByTitle(newTitle);
      if (game == null) {
        debugPrint('[SHORTCUT] 无法找到新标题对应游戏: $newTitle');
        return false;
      }

      // 删除旧快捷方式
      await File(oldPath).delete();
      debugPrint('[SHORTCUT] 已删除旧快捷方式: $oldTitle');

      // 读取 game.json 获取完整配置
      final jsonData = await GameDataFormat.readGameJson(game.metaDataDir);
      final exePath = GameDataFormat.resolveLaunchPath(
        game.launchPath,
        game.directoryPath,
      );
      if (exePath.isEmpty || !File(exePath).existsSync()) {
        debugPrint('[SHORTCUT] exe 路径无效，无法重建快捷方式');
        return false;
      }

      // 用新标题重新创建
      return createShortcut(
        gameTitle: newTitle,
        exePath: exePath,
        gameDirectory: game.directoryPath,
        customIconPath: jsonData?.customIconPath,
        localeMode: jsonData?.localeMode ?? 'none',
        upscalingMode: jsonData?.upscalingMode ?? 'none',
      );
    } catch (e) {
      debugPrint('[SHORTCUT] 更新标题异常: $e');
      return false;
    }
  }

  /// 批量创建快捷方式
  ///
  /// 为所有已入库且有启动路径的游戏创建桌面快捷方式
  Future<int> createShortcutsForAllGames() async {
    int count = 0;
    final games = LocalGameRegistry.instance.allGames;

    for (final game in games) {
      if (game.launchPath.isEmpty) continue;

      final exePath = GameDataFormat.resolveLaunchPath(
        game.launchPath,
        game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir,
      );

      if (exePath.isEmpty || !File(exePath).existsSync()) continue;

      // 从 game.json 读取转区/超分模式
      final jsonData = await GameDataFormat.readGameJson(game.metaDataDir);
      final localeMode = jsonData?.localeMode ?? 'none';
      final upscalingMode = jsonData?.upscalingMode ?? 'none';
      final customIconPath = jsonData?.customIconPath ?? '';

      final success = await createShortcut(
        gameTitle: game.title,
        exePath: exePath,
        gameDirectory: game.directoryPath,
        customIconPath: customIconPath.isNotEmpty ? customIconPath : null,
        localeMode: localeMode,
        upscalingMode: upscalingMode,
      );

      if (success) count++;
    }

    return count;
  }

  /// 获取快捷方式的当前状态信息
  Future<ShortcutInfo?> getShortcutInfo(String gameTitle) async {
    try {
      final shortcutPath = getShortcutPath(gameTitle);
      if (!File(shortcutPath).existsSync()) return null;

      // 读取 game.json 中的自定义图标路径
      final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
      String? customIconPath;
      if (game != null) {
        final jsonData = await GameDataFormat.readGameJson(game.metaDataDir);
        customIconPath = jsonData?.customIconPath;
      }

      return ShortcutInfo(
        path: shortcutPath,
        exists: true,
        customIconPath: customIconPath,
      );
    } catch (e) {
      debugPrint('[SHORTCUT] 获取信息异常: $e');
      return null;
    }
  }
}

/// 快捷方式信息
class ShortcutInfo {
  final String path;
  final bool exists;
  final String? customIconPath;

  ShortcutInfo({
    required this.path,
    required this.exists,
    this.customIconPath,
  });
}
