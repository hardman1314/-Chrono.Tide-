/// BPM 操作引导的全局开关（v3.21）。
///
/// 用户拍板：设置页「大屏模式」栏提供开关 —— 开启时显示上下文引导
/// （键帽角标 / 侧缘翻页提示 / 切页提示等），关闭时**完全不显示**。
///
/// 持久化走 `shared_preferences`（已被 `PortableSharedPreferencesStore`
/// 重定向到 `data/prefs/shared_preferences.json`），与
/// `BpmOpVideoPreference` 同构：`ChangeNotifier` 单例 + 首帧前 `load()`。
///
/// 消费方式：引导类组件经 `BpmGuideScope.enabledOf(context)` 短路退出；
/// scope 由 shell 用 [AnimatedBuilder] 监听本单例重建下发。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BpmGuidePreference extends ChangeNotifier {
  static const String _kEnabled = 'bpm_guide_enabled';

  static BpmGuidePreference? _instance;
  static BpmGuidePreference get instance =>
      _instance ??= BpmGuidePreference._();
  BpmGuidePreference._();

  bool _loaded = false;
  bool get loaded => _loaded;

  /// 是否显示操作引导。**默认 `true`**（新手引导应默认可见）。
  bool _enabled = true;

  bool get enabled => _enabled;

  /// 从 `SharedPreferences` 读取。幂等；必须在 `runApp` 之前调用。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? true;
    } catch (e) {
      debugPrint('[BPM-GUIDE] 读取设置失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    // 先通知再落盘：开关要立刻生效（引导 UI 重建不依赖写盘结果）
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, value);
    } catch (e) {
      debugPrint('[BPM-GUIDE] 写入设置失败: $e');
    }
  }

  /// 仅供单测重置单例。
  @visibleForTesting
  static void resetForTest() => _instance = null;
}
