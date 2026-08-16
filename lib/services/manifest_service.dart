import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'save_manifest.dart';

/// Ludusavi 存档清单服务（单例）
///
/// 应用启动时从 assets/data/manifest.yaml 加载 Ludusavi 兼容清单，
/// 为 [SaveScanner] 提供游戏存档路径查询能力。
///
/// 清单覆盖 5 万+ 游戏，包含存档文件路径、注册表路径、Steam/GOG ID 等。
/// 加载失败不阻塞应用启动，[isReady] 为 false 时扫描器回退到通用检测。
class ManifestService with ChangeNotifier {
  static final ManifestService instance = ManifestService._();
  ManifestService._();

  static const _assetPath = 'assets/data/manifest.yaml';

  SaveManifest? _manifest;
  bool _isReady = false;
  String? _loadError;

  /// 清单是否已加载就绪
  bool get isReady => _isReady;

  /// 加载错误信息（加载失败时设置，供诊断用）
  String? get loadError => _loadError;

  /// 已加载的清单实例（未就绪时为 null）
  SaveManifest? get manifest => _manifest;

  /// 条目总数（未就绪时为 0）
  int get count => _manifest?.count ?? 0;

  /// 初始化：从 asset 加载清单并解析
  ///
  /// 失败不抛异常，仅设置 [_loadError] 并保持 [isReady] 为 false。
  /// 调用方无需 try-catch。
  Future<void> init() async {
    if (_isReady) return;
    try {
      final yaml = await rootBundle.loadString(_assetPath);
      _manifest = SaveManifest.fromYaml(yaml);
      _isReady = true;
      _loadError = null;
      debugPrint('[INIT] ✅ 存档清单加载完成（${_manifest!.count} 条目）');
    } catch (e) {
      _loadError = e.toString();
      _isReady = false;
      debugPrint('[INIT] ⚠️ 存档清单加载失败: $e');
    }
    notifyListeners();
  }

  /// 按游戏名查找清单条目（自动解析别名）
  ManifestGame? lookup(String gameName) {
    if (!_isReady || _manifest == null) return null;
    return _manifest!.lookup(gameName);
  }

  /// 模糊查找（支持部分匹配）
  List<ManifestGame> fuzzyLookup(String query) {
    if (!_isReady || _manifest == null) return const [];
    return _manifest!.fuzzyLookup(query);
  }

  /// 按 Steam App ID 查找
  ManifestGame? lookupBySteamId(int steamId) {
    if (!_isReady || _manifest == null) return null;
    return _manifest!.lookupBySteamId(steamId);
  }

  /// 按 GOG ID 查找
  ManifestGame? lookupByGogId(int gogId) {
    if (!_isReady || _manifest == null) return null;
    return _manifest!.lookupByGogId(gogId);
  }
}
