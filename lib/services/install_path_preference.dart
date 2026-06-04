import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../core/path_helper.dart';

class InstallPathPreference {
  static const String _keyDefaultGameLocation = 'default_game_location';
  static const String _keyLastUsedLocation = 'last_used_location';
  static InstallPathPreference? _instance;
  static InstallPathPreference get instance =>
      _instance ??= InstallPathPreference._();
  InstallPathPreference._();

  Future<String> getDefaultGameLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final userSetPath = prefs.getString(_keyDefaultGameLocation);

    if (userSetPath != null && userSetPath.isNotEmpty) {
      return userSetPath;
    }

    final fallbackPath = Directory(PathHelper.gamesDir).absolute.path;

    debugPrint('[PATH-PREF] 未找到用户设置的默认路径');
    debugPrint('[PATH-PREF] 使用系统回退路径: $fallbackPath');
    debugPrint(
        '[PATH-PREF]   (基于 exeDir: ${Directory(PathHelper.exeDir).absolute.path})');

    return fallbackPath;
  }

  Future<bool> setDefaultGameLocation(String path) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.setString(_keyDefaultGameLocation, path);
  }

  Future<String?> getLastUsedLocation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLastUsedLocation);
  }

  Future<bool> setLastUsedLocation(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      return prefs.remove(_keyLastUsedLocation);
    }
    return prefs.setString(_keyLastUsedLocation, path);
  }

  Future<bool> clearDefaultGameLocation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.remove(_keyDefaultGameLocation);
  }

  Future<String?> pickDirectory({
    String? dialogTitle,
  }) async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle ?? '选择游戏存放位置',
      );
      if (result != null) {
        final dir = Directory(result);
        if (!await dir.exists()) {
          try {
            await dir.create(recursive: true);
          } catch (e) {
            return null;
          }
        }
        return result;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<String> resolveEffectiveLocation({String? customLocation}) async {
    if (customLocation != null && customLocation.isNotEmpty) {
      return customLocation;
    }

    return getDefaultGameLocation();
  }

  Future<bool> isValidLocation(String path) async {
    if (path.isEmpty) return false;

    try {
      final dir = Directory(path);

      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (e) {
          return false;
        }
      }

      final testFile =
          File('$path/.write_test_${DateTime.now().millisecondsSinceEpoch}');
      await testFile.writeAsString('test');
      if (await testFile.exists()) {
        await testFile.delete();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, int>?> getDiskSpaceInfo(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        return null;
      }

      final stat = await dir.stat();

      return {
        'total': -1,
        'free': -1,
      };
    } catch (e) {
      return null;
    }
  }
}
