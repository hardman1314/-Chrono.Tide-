import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 迁移标志位与 prefs JSON 直接读写辅助。
///
/// 迁移过程分两个阶段：
/// - Phase A：SharedPreferences store 替换前，无法使用 SharedPreferences API
/// - Phase B：store 替换后，但若混用 SharedPreferences 单例缓存与直接文件写入，
///   可能导致单例缓存覆盖直接写入的标志位（数据丢失）。
///
/// 因此 **全程统一使用本类的直接 JSON 文件读写**，不调用 SharedPreferences API，
/// 避免缓存一致性问题。所有标志位读写均在 `SharedPreferences.getInstance()`
/// 首次调用之前完成，之后 app 的 getInstance 会从文件读入全部标志位。
class MigrationMarkers {
  /// 迁移标志位前缀（SharedPreferences 层会自动加 `flutter.` 前缀存储，
  /// 直接操作文件时需手动带上 `flutter.`）。
  static const String flagPrefix = 'storage_migration_v1_';
  static const String _prefsKeyPrefix = 'flutter.';

  /// 直接读取 prefs JSON 文件为 Map（缺失/损坏返回空 Map，不抛错）。
  static Map<String, Object> readPrefsJsonDirect(File file) {
    try {
      if (!file.existsSync()) return {};
      final content = file.readAsStringSync();
      if (content.trim().isEmpty) return {};
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        return Map<String, Object>.from(decoded);
      }
    } catch (e) {
      debugPrint('[Migration] 读取 prefs JSON 失败 ${file.path}: $e');
    }
    return {};
  }

  /// 判断指定单元的迁移标志是否已设置。
  static bool isFlagSet(File prefsFile, String unitId) {
    final data = readPrefsJsonDirect(prefsFile);
    return data['$_prefsKeyPrefix$flagPrefix$unitId'] == true;
  }

  /// 向 prefs JSON 文件注入迁移完成标志（事务写入：先 .tmp 再 rename）。
  /// 重新读取现有内容以保留其他标志位，避免覆盖。
  static Future<void> injectFlag(File prefsFile, String unitId) async {
    try {
      final data = readPrefsJsonDirect(prefsFile);
      data['$_prefsKeyPrefix$flagPrefix$unitId'] = true;
      if (!prefsFile.parent.existsSync()) {
        prefsFile.parent.createSync(recursive: true);
      }
      final tmp = File('${prefsFile.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(data), flush: true);
      await tmp.rename(prefsFile.path);
    } catch (e) {
      debugPrint('[Migration] 注入标志失败 $unitId: $e');
    }
  }
}
