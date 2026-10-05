/// NSFW 局部检测的用户设置。
///
/// 持久化走项目既有的 `shared_preferences`（已被
/// `PortableSharedPreferencesStore` 重定向到 `data/prefs/shared_preferences.json`），
/// 因此便携版拷走整个目录即可带走设置。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nsfw_rating_postprocess.dart';

/// 推理输入边长（**方形**像素）。
///
/// v2.4 起模型为 `anime_dbrating` 评分分类器，预处理是把整图**拉伸**成
/// 384×384 正方形（timm 训练/推理的 PIL resize 语义），不再是 YOLO
/// 时代的「等比缩放 + ceil32」。384 是用户参考集分离间隙最干净的档位
/// （[0.6287, 0.6680]）；320/448/512 实测均更差（误报 +1 或间隙收窄）。
/// v2.1 起不向用户暴露档位选择；历史 fast/balanced 档随 YOLO 一并退役。
enum NsfwInferSize {
  accurate(384, '精确');

  const NsfwInferSize(this.pixels, this.label);

  final int pixels;
  final String label;

  static NsfwInferSize fromPixels(int px) => NsfwInferSize.accurate;
}

/// NSFW 内容的显示模式。
///
/// 两种模式共享同一套检测推理与判定缓存，区别只在**渲染策略**：
/// 检测结果持久化与模式无关，切换模式不需要重新推理。
enum NsfwDisplayMode {
  /// 纯净模式：本地 AI 判定敏感后，截图等内容图模糊隐藏，封面类整图模糊。
  /// 所有处理均只影响显示层，不修改任何原始数据。
  clean('纯净模式'),

  /// 工作模式（v2.1.15）：**不做任何内容判定、不加载模型、不入队检测**，
  /// 软件内全部图片统一替换为占位图，供办公/学习等场景完全遮挡。
  /// 最轻量模式，开销与未开启任何 NSFW 模式时几乎一致。
  work('工作模式');

  const NsfwDisplayMode(this.label);

  final String label;
}

class NsfwSettings extends ChangeNotifier {
  static const String _kEnabled = 'nsfw_filter_enabled';
  static const String _kConfThreshold = 'nsfw_conf_threshold';
  static const String _kDisplayMode = 'nsfw_display_mode';
  static const String _kAllowReveal = 'nsfw_allow_reveal';
  static const String _kBoxExpandRatio = 'nsfw_box_expand_ratio';
  static const String _kFullScanDoneAt = 'nsfw_full_scan_done_at';

  /// 模型标识，随模型文件更换时必须同步改动 —— 它参与
  /// [modelSignature]，签名变化会让整张检测缓存表失效。
  static const String modelId = 'anime_dbrating_mv3_v0';

  static NsfwSettings? _instance;
  static NsfwSettings get instance => _instance ??= NsfwSettings._();
  NsfwSettings._();

  bool _loaded = false;
  bool get loaded => _loaded;

  bool _enabled = true;
  double _confThreshold = NsfwRatingPostprocess.defaultFlagThreshold;
  NsfwInferSize _inferSize = NsfwInferSize.accurate;
  NsfwDisplayMode _mode = NsfwDisplayMode.clean;
  bool _allowReveal = true;
  double _boxExpandRatio = 0.2;
  int _fullScanDoneAtMs = 0;

  /// 总开关。默认**开启**（v2.1 起改默认值）：保护性功能，默认关闭
  /// 意味着新用户在不知情的状态下裸露图直出。曾显式关闭过的用户
  /// 存储值不受影响（尊重既有选择）。
  bool get enabled => _enabled;

  /// 敏感判定阈值。
  ///
  /// v2.3 起**固定为唯一判定口径**（见
  /// [NsfwRatingPostprocess.defaultFlagThreshold] = 0.648，v2.4 起为用户
  /// 参考集校准值；此前历经 YOLO 检测口径 0.278/0.360），不再从 prefs 读取：
  /// 该值从未在设置页暴露，持久化只会让不同用户/不同时期安装的版本
  /// 判定口径不一致（"同一张图你的糊了我的没糊"），与"判定稳定"冲突。
  double get confThreshold => _confThreshold;

  /// 推理输入边长，固定 [NsfwInferSize.accurate]（384，分类器方形输入）。
  NsfwInferSize get inferSize => _inferSize;

  /// 显示模式（纯净模式 / 工作模式）。默认纯净模式。
  NsfwDisplayMode get mode => _mode;

  /// 是否允许点击临时揭示（仅大图/轮播等场景生效，网格卡片不启用）。
  bool get allowReveal => _allowReveal;

  /// bbox 外扩比例，见 [NsfwBox.expanded] 与风险 R-2。
  double get boxExpandRatio => _boxExpandRatio;

  /// 上次全量扫描完成时间（毫秒），0 表示从未扫描过。
  int get fullScanDoneAtMs => _fullScanDoneAtMs;
  bool get hasEverFullScanned => _fullScanDoneAtMs > 0;

  /// 缓存有效性签名：`模型/分辨率/阈值`。
  ///
  /// 任一项变化都会让已存检测结果失去意义（阈值变了要重判、分辨率变了坐标精度变了），
  /// 因此签名不匹配时整表作废，见 §4.3。
  ///
  /// `rN/` 是**判定规则版本**，改动判定口径时必须递增，确保存量缓存
  /// 整表作废、全量重判（否则旧规则下的判定会一直沿用）：
  /// - `r2`（v2.2.1）：R18+ 复核门 + 阈值 0.45 —— **已证实有害**：它把
  ///   真实裸露的单框检出（0.3-0.55 置信度）清空成"判定健康"，直接造成
  ///   "全裸/漏点图没被处理"。v2.3 已移除该门。
  /// - `r3`（v2.3）：模型 n→s、分辨率 480→640、预处理改为等比缩放、
  ///   阈值 0.238、移除复核门。
  /// - `r4`（v2.3.1）：模型 s→n（体积回退 + 对本库封面 n 分更高）、
  ///   阈值 = n 官方 F1 最优点 0.278。
  /// - `r4`（v2.3.3）：阈值 0.278→0.360（用户参考集校准）。rN 不递增：
  ///   阈值本身在签名里，改阈值即自动整表作废重判。
  /// - `r5`（v2.4）：检测范式替换 —— YOLO 部位检测 → anime_dbrating
  ///   四级评分分类器（模型 n→dbrating-mv3、640 等比 → 384 方形拉伸、
  ///   阈值 0.360→0.648、敏感信号改为全图合成框）。
  /// - `r6`（v2.1.13）：后处理修复 —— 模型输出已是概率，误二次 softmax 把
  ///   分数压平致全量漏拦（r5 缓存 403 条全错判健康），升版本整表作废重判。
  String get modelSignature =>
      'r6/$modelId/${_inferSize.pixels}/${_confThreshold.toStringAsFixed(3)}';

  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? true;
      // 阈值固定取用户参考集校准值，**不读 prefs**（理由见 [confThreshold]）。
      // 历史上持久化过的值（0.2 / 0.45）会让判定口径漂移，一律丢弃。
      _confThreshold = NsfwRatingPostprocess.defaultFlagThreshold;
      // 推理档位固定均衡，不再从 prefs 读取（旧 key 残留无害）
      _mode = NsfwDisplayMode.values.firstWhere(
        (NsfwDisplayMode m) => m.name == prefs.getString(_kDisplayMode),
        orElse: () => NsfwDisplayMode.clean,
      );
      _allowReveal = prefs.getBool(_kAllowReveal) ?? true;
      _boxExpandRatio = (prefs.getDouble(_kBoxExpandRatio) ?? 0.2).clamp(0.0, 1.0);
      _fullScanDoneAtMs = prefs.getInt(_kFullScanDoneAt) ?? 0;
    } catch (e) {
      debugPrint('[NSFW-SETTINGS] 读取设置失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _write((SharedPreferences p) => p.setBool(_kEnabled, value));
  }

  Future<void> setConfThreshold(double value) async {
    final double v = value.clamp(0.1, 0.5);
    if (_confThreshold == v) return;
    _confThreshold = v;
    notifyListeners();
    await _write((SharedPreferences p) => p.setDouble(_kConfThreshold, v));
  }

  Future<void> setMode(NsfwDisplayMode value) async {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
    await _write((SharedPreferences p) => p.setString(_kDisplayMode, value.name));
  }

  Future<void> setAllowReveal(bool value) async {
    if (_allowReveal == value) return;
    _allowReveal = value;
    notifyListeners();
    await _write((SharedPreferences p) => p.setBool(_kAllowReveal, value));
  }

  Future<void> setBoxExpandRatio(double value) async {
    final double v = value.clamp(0.0, 1.0);
    if (_boxExpandRatio == v) return;
    _boxExpandRatio = v;
    notifyListeners();
    await _write((SharedPreferences p) => p.setDouble(_kBoxExpandRatio, v));
  }

  Future<void> markFullScanDone() async {
    _fullScanDoneAtMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    await _write(
        (SharedPreferences p) => p.setInt(_kFullScanDoneAt, _fullScanDoneAtMs));
  }

  Future<void> resetFullScanFlag() async {
    _fullScanDoneAtMs = 0;
    notifyListeners();
    await _write((SharedPreferences p) => p.remove(_kFullScanDoneAt));
  }

  Future<void> _write(Future<void> Function(SharedPreferences) op) async {
    try {
      await op(await SharedPreferences.getInstance());
    } catch (e) {
      debugPrint('[NSFW-SETTINGS] 写入设置失败: $e');
    }
  }

  /// 仅供单测重置单例。
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// 仅供单测注入设置值，绕过 `SharedPreferences`。
  @visibleForTesting
  void seedForTest({
    bool? enabled,
    double? confThreshold,
    NsfwInferSize? inferSize,
    NsfwDisplayMode? mode,
    bool? allowReveal,
    double? boxExpandRatio,
  }) {
    _loaded = true;
    if (enabled != null) _enabled = enabled;
    if (confThreshold != null) _confThreshold = confThreshold.clamp(0.1, 0.5);
    if (inferSize != null) _inferSize = inferSize;
    if (mode != null) _mode = mode;
    if (allowReveal != null) _allowReveal = allowReveal;
    if (boxExpandRatio != null) _boxExpandRatio = boxExpandRatio.clamp(0.0, 1.0);
    notifyListeners();
  }
}
