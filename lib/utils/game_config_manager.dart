import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class GameConfig {
  final String launchExePath;
  final DateTime? lastUpdated;

  const GameConfig({
    required this.launchExePath,
    this.lastUpdated,
  });

  factory GameConfig.fromJson(Map<String, dynamic> json) {
    return GameConfig(
      launchExePath: json['launch_exe_path'] ?? '',
      lastUpdated: json['last_updated'] != null
          ? DateTime.tryParse(json['last_updated'])
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'launch_exe_path': launchExePath,
        'last_updated': DateTime.now().toIso8601String(),
      };
}

class GameConfigManager {
  static final GameConfigManager instance = GameConfigManager._internal();
  GameConfigManager._internal();

  late String _configDir;

  Future<String> get configDir async {
    if (_configDir.isNotEmpty) return _configDir;
    try {
      final appDocDir = await getApplicationSupportDirectory();
      _configDir = p.join(appDocDir.path, 'ChronoTide', 'GameConfigs');
      final dir = Directory(_configDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      final tempBase =
          p.join(Directory.systemTemp.path, 'ChronoTide', 'GameConfigs');
      final dir = Directory(tempBase);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _configDir = tempBase;
    }
    return _configDir;
  }

  String _sanitizeGameId(String gameTitle) {
    return gameTitle
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
  }

  Future<String> _configFilePath(String gameTitle) async {
    final dir = await configDir;
    final safeName = _sanitizeGameId(gameTitle);
    return p.join(dir, 'game_${safeName}_config.json');
  }

  Future<GameConfig?> loadConfig(String gameTitle) async {
    try {
      final filePath = await _configFilePath(gameTitle);
      final file = File(filePath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      return GameConfig.fromJson(json);
    } catch (e) {
      print('[GameConfig] 加载配置失败 [$gameTitle]: $e');
      return null;
    }
  }

  Future<bool> saveConfig(String gameTitle, GameConfig config) async {
    try {
      final dir = await configDir;
      final directory = Directory(dir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final filePath = await _configFilePath(gameTitle);
      final file = File(filePath);
      final jsonString =
          const JsonEncoder.withIndent('  ').convert(config.toJson());
      await file.writeAsString(jsonString);

      print('[GameConfig] 配置已保存 [$gameTitle]: ${config.launchExePath}');
      return true;
    } catch (e) {
      print('[GameConfig] 保存配置失败 [$gameTitle]: $e');
      return false;
    }
  }

  Future<String?> getLaunchPath(String gameTitle) async {
    final config = await loadConfig(gameTitle);
    if (config == null || config.launchExePath.isEmpty) return null;

    final exeFile = File(config.launchExePath);
    if (await exeFile.exists()) {
      return config.launchExePath;
    }

    print(
        '[GameConfig] 已保存的exe不存在，清除无效配置 [$gameTitle]: ${config.launchExePath}');
    await removeConfig(gameTitle);
    return null;
  }

  Future<bool> saveLaunchPath(String gameTitle, String exePath) async {
    final config = GameConfig(launchExePath: exePath);
    return saveConfig(gameTitle, config);
  }

  Future<bool> hasValidConfig(String gameTitle) async {
    final path = await getLaunchPath(gameTitle);
    return path != null && path.isNotEmpty;
  }

  Future<bool> removeConfig(String gameTitle) async {
    try {
      final filePath = await _configFilePath(gameTitle);
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        print('[GameConfig] 配置已删除 [$gameTitle]');
      }
      return true;
    } catch (e) {
      print('[GameConfig] 删除配置失败 [$gameTitle]: $e');
      return false;
    }
  }

  Future<void> migrateFromSharedPreferences(
      String gameTitle, String? prefsPath) async {
    if (prefsPath == null || prefsPath.isEmpty) return;

    final existing = await hasValidConfig(gameTitle);
    if (existing) {
      print('[GameConfig] 已有有效配置，跳过迁移 [$gameTitle]');
      return;
    }

    final exeFile = File(prefsPath);
    if (await exeFile.exists()) {
      await saveLaunchPath(gameTitle, prefsPath);
      print('[GameConfig] 从SharedPreferences迁移完成 [$gameTitle]');
    }
  }

  Future<List<MapEntry<String, GameConfig>>> listAllConfigs() async {
    try {
      final dir = await configDir;
      final directory = Directory(dir);
      if (!await directory.exists()) return [];

      final configs = <MapEntry<String, GameConfig>>[];
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('_config.json')) {
          try {
            final content = await entity.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            final config = GameConfig.fromJson(json);
            final fileName = p.basename(entity.path);
            final match =
                RegExp(r'game_(.+)_config\.json').firstMatch(fileName);
            if (match != null) {
              final title = match.group(1)!.replaceAll('_', ' ');
              configs.add(MapEntry(title, config));
            }
          } catch (_) {}
        }
      }
      return configs;
    } catch (e) {
      print('[GameConfig] 列出所有配置失败: $e');
      return [];
    }
  }
}
