import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'game_launcher_detector.dart';

class GameDataFormat {
  static const int currentVersion = 1;
  static const String ctgameFileName = '.ctgame';
  static const String gameJsonFileName = 'game.json';
  static const String defaultCoverFileName = 'cover.png';

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

    final effectiveDirectoryPath =
        directoryPath.isNotEmpty ? directoryPath : targetDir;

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
      'developer': developer,
    };

    final jsonStr = JsonEncoder.withIndent('  ').convert(gameData);
    final jsonFile = File('$targetDir/$gameJsonFileName');
    await jsonFile.writeAsString(jsonStr);

    debugPrint(
        '[GAME-DATA] ✅ 写入完成: $targetDir/$gameJsonFileName | launch_path=$relativeLaunchPath | source=$source');
  }

  static Future<void> updateGameJson(
      String targetDir, Map<String, dynamic> updates) async {
    final jsonFile = File('$targetDir/$gameJsonFileName');
    if (!await jsonFile.exists()) return;

    try {
      final content = await jsonFile.readAsString();
      final jsonData = jsonDecode(content) as Map<String, dynamic>;

      for (final entry in updates.entries) {
        jsonData[entry.key] = entry.value;
      }
      jsonData['updated_at'] = DateTime.now().toIso8601String();

      final jsonStr = JsonEncoder.withIndent('  ').convert(jsonData);
      await jsonFile.writeAsString(jsonStr);
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 更新game.json失败: $e');
    }
  }

  static Future<void> addPlayTime(String targetDir, int seconds) async {
    if (seconds <= 0) return;
    final data = await readGameJson(targetDir);
    if (data == null) return;
    await updateGameJson(targetDir, {'play_time': data.playTime + seconds});
  }

  static Future<void> setCompleted(String targetDir, bool value) async {
    await updateGameJson(targetDir, {'completed': value});
  }

  static String formatPlayTime(int totalSeconds) {
    if (totalSeconds <= 0) return '0h';
    final hours = totalSeconds ~/ 3600;
    if (hours > 0) return '${hours}h';
    final minutes = (totalSeconds ~/ 60) % 60;
    return '${minutes}m';
  }

  static Future<GameJsonData?> readGameJson(String targetDir) async {
    final jsonFile = File('$targetDir/$gameJsonFileName');
    if (!await jsonFile.exists()) return null;

    try {
      final content = await jsonFile.readAsString();
      final jsonData = jsonDecode(content) as Map<String, dynamic>;
      return GameJsonData.fromJson(jsonData);
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 读取game.json失败: $e');
      return null;
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
    final absolute = '$directoryPath\\$relativePath'.replaceAll('/', '\\');
    if (File(absolute).existsSync()) return absolute;
    final withForwardSlash =
        '$directoryPath/${relativePath.replaceAll('\\', '/')}';
    if (File(withForwardSlash).existsSync()) return withForwardSlash;
    return absolute;
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
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode == 200) {
        final bytes = await response.fold<List<int>>(
          <int>[],
          (previous, chunk) => previous..addAll(chunk),
        );

        String ext = 'jpg';
        final pathSegments = Uri.parse(url).pathSegments;
        if (pathSegments.isNotEmpty) {
          final last = pathSegments.last.toLowerCase();
          if (last.endsWith('.png')) {
            ext = 'png';
          } else if (last.endsWith('.gif')) {
            ext = 'gif';
          } else if (last.endsWith('.webp')) {
            ext = 'webp';
          }
        }

        final coverFileName = 'cover.$ext';
        final destPath = '$targetDir/$coverFileName';
        await File(destPath).writeAsBytes(bytes);
        debugPrint(
            '[GAME-DATA] ✅ 封面已下载保存: $destPath (${(bytes.length / 1024).toStringAsFixed(1)}KB)');
        client.close();
        return coverFileName;
      }
      client.close();
    } catch (e) {
      debugPrint('[GAME-DATA] ⚠️ 封面下载失败: $e');
    }
    return defaultCoverFileName;
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
  final String developer;

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
    this.developer = '',
  });

  factory GameJsonData.fromJson(Map<String, dynamic> json) {
    return GameJsonData(
      formatVersion: json['format_version'] as int? ?? 1,
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
      playTime: json['play_time'] as int? ?? 0,
      completed: json['completed'] as bool? ?? false,
      localeMode: json['locale_mode'] as String? ?? 'none',
      developer: json['developer'] as String? ?? '',
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
        'developer': developer,
      };
}
