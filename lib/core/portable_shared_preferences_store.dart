import 'dart:async';
import 'dart:convert' show json;
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// 便携式 SharedPreferences 存储后端。
///
/// 将 `shared_preferences` 的持久化文件从系统 C 盘
/// (`%APPDATA%\<org>\<app>\shared_preferences.json`) 重定向到软件安装目录
/// (`<安装目录>/data/prefs/shared_preferences.json`)，使应用产生的偏好数据
/// 不再占用系统盘空间。
///
/// 实现严格镜像 Flutter 官方 `SharedPreferencesWindows`（Windows native 实现）：
/// - 文件格式为纯 JSON：`{"flutter.<key>": <value>, ...}`，key 带 `flutter.` 前缀
/// - 类型保持依赖 JSON 原生类型（int/double/bool/String/List），无类型标签
/// - 因此旧 C 盘文件可直接复制迁移，格式完全兼容
///
/// 在 `main()` 早期、任何 `SharedPreferences.getInstance()` 之前执行
/// `SharedPreferencesStorePlatform.instance = PortableSharedPreferencesStore()`
/// 即可让全应用 30+ 调用点透明重定向，无需逐处改造。
///
/// 相比 native 实现的增强：写入采用「先 .tmp 再 rename」事务模式，避免应用
/// 崩溃时文件被截断导致偏好损坏（参考 ThemeStorage.saveUserTheme 已验证模式）。
class PortableSharedPreferencesStore extends SharedPreferencesStorePlatform {
  static const String _defaultPrefix = 'flutter.';

  final File _file;
  Map<String, Object>? _data;

  PortableSharedPreferencesStore(this._file);

  /// 从磁盘加载偏好（首次访问时触发，结果缓存）。
  /// 文件不存在或解析失败时返回空 Map，不抛错（保证应用可启动）。
  Future<Map<String, Object>> _ensureLoaded() async {
    if (_data != null) return _data!;
    final Map<String, Object> result = <String, Object>{};
    try {
      if (_file.existsSync()) {
        final String content = _file.readAsStringSync();
        if (content.trim().isNotEmpty) {
          final Object? decoded = json.decode(content);
          if (decoded is Map) {
            // 与 native 实现一致：直接 cast。List 值保持 List<dynamic>，
            // 由 SharedPreferences 的 getStringList 做 cast<String>()。
            result.addEntries(
              decoded.entries.where((e) => e.value != null).map(
                    (e) => MapEntry(e.key as String, e.value as Object),
                  ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[PortablePrefs] 读取偏好失败，将以空数据启动: $e');
    }
    _data = result;
    return result;
  }

  /// 事务性写入：先写 .tmp 再 rename 覆盖目标，防止崩溃截断。
  Future<bool> _save() async {
    final data = _data;
    if (data == null) return false;
    try {
      if (!_file.parent.existsSync()) {
        _file.parent.createSync(recursive: true);
      }
      final String encoded = json.encode(data);
      final File tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(encoded, flush: true);
      // Windows 上 rename 会覆盖已存在目标
      await tmp.rename(_file.path);
      return true;
    } catch (e) {
      debugPrint('[PortablePrefs] 写入偏好失败: $e');
      return false;
    }
  }

  @override
  Future<bool> remove(String key) async {
    final data = await _ensureLoaded();
    data.remove(key);
    return _save();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final data = await _ensureLoaded();
    data[key] = value;
    return _save();
  }

  @override
  Future<bool> clear() async {
    return clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<bool> clearWithPrefix(String prefix) async {
    return clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: prefix)));
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final PreferencesFilter filter = parameters.filter;
    final data = await _ensureLoaded();
    data.removeWhere((String key, _) =>
        key.startsWith(filter.prefix) &&
        (filter.allowList == null || filter.allowList!.contains(key)));
    return _save();
  }

  @override
  Future<Map<String, Object>> getAll() async {
    return getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) async {
    return getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)));
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    final PreferencesFilter filter = parameters.filter;
    final Map<String, Object> source = await _ensureLoaded();
    final Map<String, Object> result = Map<String, Object>.from(source);
    result.removeWhere((String key, _) =>
        !(key.startsWith(filter.prefix) &&
            (filter.allowList?.contains(key) ?? true)));
    return result;
  }
}
