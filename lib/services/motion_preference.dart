/// 全局「减少动效」偏好的单一来源。
///
/// 持久化走项目既有的 `shared_preferences`（已被
/// `PortableSharedPreferencesStore` 重定向到 `data/prefs/shared_preferences.json`），
/// 便携版拷走整个目录即可带走设置。
///
/// v3.10 R4：**当前唯一消费方是动态背景图**
/// （`lib/theme/background_image_resolver.dart`）——开启后 GIF 背景不再循环
/// 播放，只渲染静态首帧。做成全局偏好而不是 `BackgroundImageConfig` 字段的理由：
/// ① 它是「设备能力 / 使用习惯」维度的开关，不属于主题数据；
/// ② 写进配置就要动 schema，存量主题需要迁移（违反本功能「零迁移」约束）。
///
/// ⚠️ 名字里的「全局」指**全局唯一**，不代表作用范围覆盖全应用动效——
/// R4 的范围经用户 2026-09-17 确认为「**仅 GIF 动态背景**」，
/// 不包含界面过渡动效（`AnimatedSwitcher` 等）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MotionPreference extends ChangeNotifier {
  /// SharedPreferences key。
  /// 前缀 `background_` 是为了从 key 本身就能看出真实作用域，
  /// 避免日后误以为它管的是全应用动效。
  static const String _kReduceMotionBackground = 'reduce_motion_background';

  static MotionPreference? _instance;
  static MotionPreference get instance => _instance ??= MotionPreference._();
  MotionPreference._();

  bool _loaded = false;
  bool get loaded => _loaded;

  bool _reduceMotion = false;

  /// 是否减少动效。
  ///
  /// 默认 `false` —— 未设置过 prefs 的存量用户保持「动图照常播放」的既有行为，
  /// 因此本开关的引入对升级用户是零行为变化。
  bool get reduceMotion => _reduceMotion;

  /// 从 `SharedPreferences` 读取。幂等：已加载过则直接返回。
  ///
  /// 应用启动时在 `main.dart` 引导一次（与 `AppThemeManager.loadSavedTheme`
  /// 同层）；单测里用 [resetForTest] 清缓存后可重复加载。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _reduceMotion = prefs.getBool(_kReduceMotionBackground) ?? false;
    } catch (e) {
      debugPrint('[MOTION-PREF] 读取设置失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setReduceMotion(bool value) async {
    if (_reduceMotion == value) return;
    _reduceMotion = value;
    // 先通知再落盘：开关要立刻生效，背景层重建不依赖写盘结果
    // （写盘失败也只丢持久化，不影响本次会话）
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kReduceMotionBackground, value);
    } catch (e) {
      debugPrint('[MOTION-PREF] 写入设置失败: $e');
    }
  }

  /// 仅供单测重置单例。
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// 仅供单测注入设置值，绕过 `SharedPreferences`。
  @visibleForTesting
  void seedForTest({bool? reduceMotion}) {
    _loaded = true;
    if (reduceMotion != null) _reduceMotion = reduceMotion;
    notifyListeners();
  }
}
