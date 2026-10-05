import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/path_helper.dart';

/// 自定义会社条目（分类匣·会社墙「自定义」来源）。
@immutable
class CustomCompany {
  const CustomCompany({
    required this.id,
    required this.name,
    required this.subName,
    required this.createdAt,
  });

  /// 稳定标识（`custom_<ms>_<rand>`），关注关系的键。
  final String id;
  final String name;

  /// 副名（英文/日文原名，可为空）。
  final String subName;
  final String createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (subName.isNotEmpty) 'sub_name': subName,
        'created_at': createdAt,
      };

  static CustomCompany fromJson(Map<String, dynamic> json) => CustomCompany(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        subName: json['sub_name'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

/// 分类匣·会社墙的本地状态存储：**关注关系 + 自定义会社 + 显示层覆盖**。
///
/// 与成员计数彻底分离：卡片的「N 部作品」永远从库内游戏派生
/// （词典会社按 company_id、自定义会社按 developer 原文匹配），不落盘；
/// 本文件只存用户意愿：
/// - 关注了谁 / 添加了哪些自定义会社；
/// - **会社显示名覆盖**（`display_names`）：把标准会社名改成用户习惯的叫法
///   （如 `Yuzusoft` → `柚子社`）——**只改显示名，会社身份与筛选功能不变**
///   （卡片键、company_id、成员计数都不受影响）；
/// - **会社图标覆盖**（`logo_files`）：用户上传或平台抓取的会社图标文件名，
///   实体文件落在 [logoDir]，本文件只记相对文件名。
///
/// 会社键口径与关注关系一致：词典会社 = `"<company_id>"` 数字字符串，
/// 自定义会社 = 其 [CustomCompany.id]。
///
/// 纪律与 `CollectionService` 一致（P1-4b/4c）：
/// - 加载失败**不覆写磁盘**（保留人工恢复机会），内存退化为空态；
/// - 写盘串行化 + 唯一 tmp 文件 + 原子 rename。
class CompanyWallStore extends ChangeNotifier {
  CompanyWallStore._();

  static final CompanyWallStore _instance = CompanyWallStore._();
  static CompanyWallStore get instance => _instance;

  static String get _filePath =>
      '${PathHelper.dataDir}${Platform.pathSeparator}company_wall.json';

  /// 会社图标目录（用户上传 / 平台抓取的会社图标实体文件落盘处）。
  static String get logoDir =>
      '${PathHelper.dataDir}${Platform.pathSeparator}company_logos';

  /// 已关注的会社键集合（词典会社 = `"<company_id>"` 数字字符串；
  /// 自定义会社 = 其 [CustomCompany.id]）。
  ///
  /// 键统一字符串化，避免 int/dynamic 比较陷阱。
  final Set<String> _followedKeys = {};
  final List<CustomCompany> _customCompanies = [];

  /// 会社键 → 用户显示名覆盖（空 = 无覆盖，用词典展示名）。
  final Map<String, String> _displayNames = {};

  /// 会社键 → 图标文件名（相对 [logoDir]，如 `98.webp`）。
  final Map<String, String> _logoFiles = {};

  bool _loaded = false;
  bool _loadFailed = false;

  /// 修订号：每次关注/自定义变更自增（UI 缓存失效用）。
  int _revision = 0;
  int get revision => _revision;

  /// 串行化写队列 + 唯一 tmp 序号（与 CollectionService._save 同款）。
  Future<void> _saveQueue = Future<void>.value();
  int _tmpSeq = 0;

  bool get isLoaded => _loaded;

  /// 最近一次 load() 是否失败（磁盘数据保留，未被覆写）。
  bool get loadFailed => _loadFailed;

  /// 只读视图：已关注键集合（含词典会社与自定义会社）。
  Set<String> get followedKeys => Set.unmodifiable(_followedKeys);

  /// 只读视图：自定义会社列表（创建顺序）。
  List<CustomCompany> get customCompanies => List.unmodifiable(_customCompanies);

  bool isFollowed(Object key) => _followedKeys.contains(key.toString());

  /// 会社显示名覆盖（无覆盖返回 null，由调用方回退词典展示名）。
  String? displayNameOf(Object key) {
    final n = _displayNames[key.toString()];
    return (n == null || n.isEmpty) ? null : n;
  }

  /// 会社图标文件名（无则 null）。
  String? logoFileOf(Object key) => _logoFiles[key.toString()];

  /// 会社图标绝对路径（无图标 / 文件名为空时返回 null）。
  String? logoPathOf(Object key) {
    final f = _logoFiles[key.toString()];
    if (f == null || f.isEmpty) return null;
    return '$logoDir${Platform.pathSeparator}$f';
  }

  /// 幂等加载（不存在视为空态）。format_version 1/2 均兼容读取。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final followed = data['followed_ids'];
        if (followed is List) {
          _followedKeys
            ..clear()
            ..addAll(followed.map((e) => e.toString()));
        }
        final customs = data['custom_companies'];
        if (customs is List) {
          _customCompanies
            ..clear()
            ..addAll(customs
                .whereType<Map>()
                .map((e) =>
                    CustomCompany.fromJson(e.cast<String, dynamic>()))
                .where((c) => c.id.isNotEmpty && c.name.isNotEmpty));
        }
        // v2 字段：缺失（v1 旧文件）时保持空 Map，功能零回归
        final names = data['display_names'];
        _displayNames.clear();
        if (names is Map) {
          names.forEach((k, v) {
            final key = k.toString();
            final val = v.toString().trim();
            if (key.isNotEmpty && val.isNotEmpty) _displayNames[key] = val;
          });
        }
        final logos = data['logo_files'];
        _logoFiles.clear();
        if (logos is Map) {
          logos.forEach((k, v) {
            final key = k.toString();
            final val = v.toString().trim();
            if (key.isNotEmpty && val.isNotEmpty) _logoFiles[key] = val;
          });
        }
      }
      _loaded = true;
      _loadFailed = false;
      _revision++;
      notifyListeners();
    } catch (e) {
      // ★ 加载失败绝不清空内存、绝不写盘（与 CollectionService P1-4b 一致）
      debugPrint('[COMPANY-WALL] ⚠️ 加载失败（保留磁盘数据，不覆写）: $e');
      _loadFailed = true;
      _loaded = true;
      _revision++;
      notifyListeners();
    }
  }

  /// 切换关注状态，返回切换后的状态。
  Future<bool> toggleFollow(String key) async {
    if (key.isEmpty) return false;
    final nowFollowed = !_followedKeys.contains(key);
    if (nowFollowed) {
      _followedKeys.add(key);
    } else {
      _followedKeys.remove(key);
    }
    _revision++;
    await _save();
    notifyListeners();
    return nowFollowed;
  }

  /// 新增自定义会社（重名拒绝，返回 null 表示已存在）。
  Future<CustomCompany?> addCustomCompany(String name, String subName) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final exists = _customCompanies.any(
        (c) => c.name.trim().toLowerCase() == trimmed.toLowerCase());
    if (exists) return null;
    final rng = DateTime.now().microsecondsSinceEpoch % 0xFFFF;
    final company = CustomCompany(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}_$rng',
      name: trimmed,
      subName: subName.trim(),
      createdAt: DateTime.now().toIso8601String(),
    );
    _customCompanies.add(company);
    _revision++;
    await _save();
    notifyListeners();
    return company;
  }

  /// 删除自定义会社（连带取消关注 + 清显示名/图标）。返回是否删除了条目。
  Future<bool> removeCustomCompany(String id) async {
    final before = _customCompanies.length;
    _customCompanies.removeWhere((c) => c.id == id);
    if (_customCompanies.length == before) return false;
    _followedKeys.remove(id);
    _displayNames.remove(id);
    await _deleteLogoFile(_logoFiles.remove(id));
    _revision++;
    await _save();
    notifyListeners();
    return true;
  }

  /// 设置会社显示名覆盖（空串 = 清除覆盖，回退词典展示名）。
  ///
  /// ⚠️ **只改显示名**：会社键、company_id、成员计数、筛选行为全部不变。
  Future<void> setDisplayName(String key, String? name) async {
    if (key.isEmpty) return;
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) {
      _displayNames.remove(key);
    } else {
      _displayNames[key] = trimmed;
    }
    _revision++;
    await _save();
    notifyListeners();
  }

  /// 记录会社图标文件名（调用方负责先把文件落到 [logoDir]）。
  ///
  /// 若旧图标文件名不同，顺带删除旧文件（避免残留孤儿文件）。
  Future<void> setLogo(String key, String? fileName) async {
    if (key.isEmpty) return;
    final trimmed = fileName?.trim() ?? '';
    final old = _logoFiles[key];
    if (trimmed.isEmpty) {
      _logoFiles.remove(key);
      await _deleteLogoFile(old);
    } else {
      _logoFiles[key] = trimmed;
      if (old != null && old != trimmed) {
        await _deleteLogoFile(old);
      }
    }
    _revision++;
    await _save();
    notifyListeners();
  }

  /// 移除会社图标（删文件 + 清记录）。
  Future<void> clearLogo(String key) async {
    if (key.isEmpty) return;
    await _deleteLogoFile(_logoFiles.remove(key));
    _revision++;
    await _save();
    notifyListeners();
  }

  Future<void> _deleteLogoFile(String? fileName) async {
    if (fileName == null || fileName.isEmpty) return;
    try {
      final f = File('$logoDir${Platform.pathSeparator}$fileName');
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[COMPANY-WALL] ⚠️ 删除图标文件失败: $fileName | $e');
    }
  }

  Future<void> _save() async {
    // ★ P1-4b：加载失败后禁止写盘（磁盘原文可能人工可恢复，不覆盖）
    if (_loadFailed) {
      debugPrint('[COMPANY-WALL] ⚠️ 加载失败态，跳过写盘（保护磁盘原文）');
      return;
    }
    final previous = _saveQueue;
    final completer = Completer<void>();
    _saveQueue = completer.future;
    await previous;

    try {
      final file = File(_filePath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      final data = {
        'format_version': 2,
        'followed_ids': _followedKeys.toList(),
        'custom_companies': _customCompanies.map((c) => c.toJson()).toList(),
        'display_names': _displayNames,
        'logo_files': _logoFiles,
      };
      final content = const JsonEncoder.withIndent('  ').convert(data);
      final tempPath =
          '$_filePath.${_tmpSeq++}_${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsString(content, flush: true);
        await tempFile.rename(_filePath);
      } catch (e) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        rethrow;
      }
    } catch (e) {
      debugPrint('[COMPANY-WALL] ⚠️ 保存失败: $e');
    } finally {
      completer.complete();
    }
  }

  /// 测试专用：清空内存态（不触碰磁盘）。
  @visibleForTesting
  void resetForTest() {
    _followedKeys.clear();
    _customCompanies.clear();
    _displayNames.clear();
    _logoFiles.clear();
    _loaded = false;
    _loadFailed = false;
  }
}
