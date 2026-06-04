import 'dart:io';
import 'package:flutter/material.dart';

class GalGameDetector {
  static const List<String> _galIndicators = [
    'data.ks',
    'scenario.ks',
    'game.exe',
    'kikyo.exe',
    'nss.npa',
    'arc.nsa',
    'data.xp3',
    'game.dat',
    'script.ks',
    'initial.ks',
    'system.ks',
    'config.ini',
    'config.sys',
    'game.ini',
    'startup.tjs',
    'initialize.tjs',
    'krkr.exe',
    'kirikiri',
    'buriko',
    'monshiro',
    'siglus',
    'malie',
    'musica',
    'ruggie',
    'eagls',
    'cmvs',
    'yuris',
    'fns',
    'agi4',
    'artalk',
    'mages',
    'nitroplus',
    'leaf',
    'cabbage',
    'realLive',
    'willplus',
    'runscript',
    'advhd',
    'bgi',
    'anex86',
    'alice',
    'system40',
    'rpgmaker',
    'tyrano',
    'onscripter',
  ];

  static final List<String> _nonGalPatterns = [
    'windows',
    'program files',
    'program files (x86)',
    'steam',
    'steamapps',
    'epic games',
    'origin',
    'uplay',
    'gog galaxy',
    'microsoft',
    'appdata',
    'temp',
    '\$recycle.bin',
    'system volume information',
    'documents and settings',
    'users',
    '.git',
    '.svn',
    '.idea',
    'node_modules',
    '__pycache__',
    '.gradle',
    'build',
    'dist',
    'out',
    'bin',
    'obj',
  ];

  static bool isLikelyGalGame(String folderPath) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return false;

      final folderName =
          folderPath.split('/').last.split('\\').last.toLowerCase();

      if (_isSystemFolder(folderName, folderPath)) {
        return false;
      }

      if (_hasGalIndicators(dir)) {
        return true;
      }

      if (_hasExecutableFiles(dir)) {
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('[GAL-DETECTOR] 检测异常: $e');
      return false;
    }
  }

  static bool _isSystemFolder(String folderName, String fullPath) {
    for (final pattern in _nonGalPatterns) {
      if (fullPath.toLowerCase().contains(pattern.toLowerCase())) {
        return true;
      }
    }

    if (folderName.startsWith('.') && folderName.length > 1) {
      return true;
    }

    if (folderName == '\$recycle.bin') {
      return true;
    }

    return false;
  }

  static bool _hasGalIndicators(Directory dir) {
    int indicatorCount = 0;
    bool hasExe = false;

    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is File) {
        final fileName = entity.path.toLowerCase();

        if (fileName.endsWith('.exe') &&
            !fileName.contains('uninstall') &&
            !fileName.contains('setup') &&
            !fileName.contains('installer') &&
            !fileName.contains('patch') &&
            !fileName.contains('update') &&
            !fileName.contains('config') &&
            !fileName.contains('tool') &&
            !fileName.contains('editor')) {
          hasExe = true;
        }

        for (final indicator in _galIndicators) {
          if (fileName.contains(indicator)) {
            indicatorCount++;
            break; // 每个文件只计数一次
          }
        }
      } else if (entity is Directory) {
        final dirName =
            entity.path.split('/').last.split('\\').last.toLowerCase();

        if (dirName == 'data' ||
            dirName == 'sound' ||
            dirName == 'bg' ||
            dirName == 'cg' ||
            dirName == 'graphic' ||
            dirName == 'image' ||
            dirName == 'movie' ||
            dirName == 'music' ||
            dirName == 'bgm' ||
            dirName == 'se' ||
            dirName == 'voice' ||
            dirName == 'sav' ||
            dirName == 'save' ||
            dirName == 'script' ||
            dirName == 'scenario') {
          indicatorCount++;
        }
      }
    }

    // 放宽条件：有exe文件 + 至少1个其他特征，或者有>=1个特征目录即可
    return (hasExe && indicatorCount >= 1) || indicatorCount >= 1;
  }

  static bool _hasExecutableFiles(Directory dir) {
    int exeCount = 0;

    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is File) {
        final fileName = entity.path.toLowerCase();

        if (fileName.endsWith('.exe')) {
          if (!fileName.contains('uninstall') &&
              !fileName.contains('setup') &&
              !fileName.contains('installer') &&
              !fileName.contains('patch') &&
              !fileName.contains('update') &&
              !fileName.contains('config') &&
              !fileName.contains('tool') &&
              !fileName.contains('editor')) {
            exeCount++;
            if (exeCount >= 1) {
              return true;
            }
          }
        }
      }
    }

    return false;
  }

  static Future<List<String>> filterGalFolders(List<String> folders) async {
    final galFolders = <String>[];

    for (final folder in folders) {
      if (isLikelyGalGame(folder)) {
        galFolders.add(folder);
      }
    }

    return galFolders;
  }

  static double getConfidenceScore(String folderPath) {
    int score = 0;

    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return 0.0;

      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.path.toLowerCase();

          for (final indicator in _galIndicators) {
            if (fileName.contains(indicator)) {
              score += 10;
              break;
            }
          }

          if (fileName.endsWith('.exe')) {
            score += 5;
          }

          if (fileName.endsWith('.ks') ||
              fileName.endsWith('.tjs') ||
              fileName.endsWith('.xp3') ||
              fileName.endsWith('.npa')) {
            score += 15;
          }
        } else if (entity is Directory) {
          final dirName =
              entity.path.split('/').last.split('\\').last.toLowerCase();

          if (['data', 'sound', 'bg', 'cg', 'graphic', 'movie', 'voice']
              .contains(dirName)) {
            score += 8;
          }
        }
      }
    } catch (e) {
      return 0.0;
    }

    return (score / 100.0).clamp(0.0, 1.0);
  }
}
