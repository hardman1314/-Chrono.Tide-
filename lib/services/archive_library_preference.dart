/// 归档库偏好（方案 §5.5）。
///
/// 三个设置：
/// - [rootPath]：归档库根目录。默认 `<exeDir>/archives`，用户可指到别的盘 /
///   移动硬盘 / NAS 映射盘 —— 这才能实现"换盘腾空间"。
/// - [retention]：每个游戏保留的归档份数（默认 5，LunaBox 云端存档默认值同数）。
/// - [compressionLevel]：压缩档位（`balanced` / `max`）。
///
/// 持久化走项目既有的 `shared_preferences`（已被 `PortableSharedPreferencesStore`
/// 重定向到 `data/prefs/shared_preferences.json`），便携版拷走整个目录即可带走设置。
///
/// 写法与 `lib/services/bpm_op_video_preference.dart` 同构：
/// `ChangeNotifier` 单例 + **首帧前 `load()`**，避免首屏先按默认值渲染再跳变。
///
/// 🔴 **为什么根目录常量不放 `lib/core/path_helper.dart`**
///
/// `path_helper.dart` 是项目**稳定区**（AGENTS.md §2.4），任何改动需开发者显式批准。
/// 2026-10-02 开发者拍板：本次不为它开例外，默认目录常量就落在这里。代价是与
/// `downloadsDir` / `logsDir` 集中在 path_helper 的惯例略有出入 —— 属有意取舍。
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/path_helper.dart';
import 'archive_compressor.dart';

class ArchiveLibraryPreference extends ChangeNotifier {
  static const String _kRootPath = 'archive_library_path';
  static const String _kRetention = 'archive_retention';
  static const String _kLevel = 'archive_compression_level';

  /// 默认保留份数（方案 §13 Q6 建议值，开发者未反对）
  static const int defaultRetention = 5;
  static const int minRetention = 1;
  static const int maxRetention = 50;

  static ArchiveLibraryPreference? _instance;
  static ArchiveLibraryPreference get instance =>
      _instance ??= ArchiveLibraryPreference._();
  ArchiveLibraryPreference._();

  bool _loaded = false;
  bool get loaded => _loaded;

  String _rootPath = '';
  int _retention = defaultRetention;
  ArchiveCompressionLevel _level = ArchiveCompressionLevel.balanced;

  /// 默认归档库根目录：`<exeDir>/archives`。
  ///
  /// 落在 `exeDir` 下有个额外好处：`PathHelper.isInsideAppStorage` 覆盖 `exeDir`
  /// 递归，因此默认归档目录天然通过 ADR-007 的归属判定。
  static String get defaultRootPath => p.join(PathHelper.exeDir, 'archives');

  /// 当前生效的归档库根目录（未设置时回落默认值）
  String get rootPath =>
      _rootPath.trim().isEmpty ? defaultRootPath : _rootPath.trim();

  /// 用户显式设置的值（空串 = 未设置，走默认）
  String get configuredRootPath => _rootPath;

  /// 是否为用户自定义路径（UI 用来显示「默认 / 自定义」）
  bool get isCustomRoot => _rootPath.trim().isNotEmpty;

  /// 当前生效的根目录是否在应用自有目录内（决定能否对它做删除类操作）
  bool get rootInsideAppStorage =>
      PathHelper.isInsideAppStorage(rootPath);

  int get retention => _retention;

  ArchiveCompressionLevel get compressionLevel => _level;

  /// 校验一个候选根目录是否可用，返回错误提示（`null` = 可用）。
  ///
  /// 🔴 两条硬约束：
  /// 1. **不能是 `Games/` 内的路径** —— `LocalGameRegistry.scan()` 会把 `Games/`
  ///    下的每个子目录当候选游戏目录扫，归档库混进去会污染扫描并可能被
  ///    `InterruptCleanup.cleanupExtraction`（只按 `.ctgame`/`game.json` 判定）
  ///    误认为"不完整游戏目录"。
  /// 2. **不能是 `downloads/` 内的路径** —— 那里有下载临时文件清理逻辑。
  static String? validateRoot(String candidate) {
    final t = candidate.trim();
    if (t.isEmpty) return '归档库路径不能为空';
    if (!p.isAbsolute(t)) return '请填写绝对路径';

    final norm = p.normalize(t);
    final games = p.normalize(PathHelper.gamesDir);
    final downloads = p.normalize(PathHelper.downloadsDir);

    if (p.equals(norm, games) || p.isWithin(games, norm)) {
      return '归档库不能放在 Games 目录内（会与游戏扫描冲突）';
    }
    if (p.equals(norm, downloads) || p.isWithin(downloads, norm)) {
      return '归档库不能放在 downloads 目录内（会与下载清理冲突）';
    }
    return null;
  }

  /// 从 `SharedPreferences` 读取。幂等。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _rootPath = prefs.getString(_kRootPath) ?? '';
      _retention =
          _clampRetention(prefs.getInt(_kRetention) ?? defaultRetention);
      _level = ArchiveCompressionLevel.fromWire(prefs.getString(_kLevel));
    } catch (e) {
      debugPrint('[ARCHIVE-PREF] 读取设置失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 设置归档库根目录。传空串 = 恢复默认。
  ///
  /// 返回 `null` 表示成功；否则返回错误提示（校验见 [validateRoot]）。
  Future<String?> setRootPath(String value) async {
    final t = value.trim();
    if (t.isNotEmpty) {
      final err = validateRoot(t);
      if (err != null) return err;
    }
    if (_rootPath == t) return null;
    _rootPath = t;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (t.isEmpty) {
        await prefs.remove(_kRootPath);
      } else {
        await prefs.setString(_kRootPath, t);
      }
    } catch (e) {
      debugPrint('[ARCHIVE-PREF] 写入归档库路径失败: $e');
      return '保存失败：$e';
    }
    return null;
  }

  Future<void> setRetention(int value) async {
    final v = _clampRetention(value);
    if (_retention == v) return;
    _retention = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kRetention, v);
    } catch (e) {
      debugPrint('[ARCHIVE-PREF] 写入保留份数失败: $e');
    }
  }

  Future<void> setCompressionLevel(ArchiveCompressionLevel value) async {
    if (_level == value) return;
    _level = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLevel, value.wire);
    } catch (e) {
      debugPrint('[ARCHIVE-PREF] 写入压缩档位失败: $e');
    }
  }

  static int _clampRetention(int v) =>
      v < minRetention ? minRetention : (v > maxRetention ? maxRetention : v);

  /// 仅供单测重置单例。
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// 仅供单测注入设置值，绕过 `SharedPreferences`。
  @visibleForTesting
  void seedForTest({
    String? rootPath,
    int? retention,
    ArchiveCompressionLevel? compressionLevel,
  }) {
    _loaded = true;
    if (rootPath != null) _rootPath = rootPath;
    if (retention != null) _retention = _clampRetention(retention);
    if (compressionLevel != null) _level = compressionLevel;
    notifyListeners();
  }
}
