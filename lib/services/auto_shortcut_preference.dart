/// 全局「首次启动游戏时自动生成桌面快捷方式」偏好。
///
/// 2026-09-27：原为**每游戏**开关（`game.json.auto_create_shortcut`，默认 `true`），
/// 现迁移为**全局唯一**偏好并**默认关闭**（用户拍板）：
/// - 桌面设置页「游戏与启动 → 系统」提供唯一开关；
/// - 启动管理弹窗（`LaunchManagerDialog`）中的每游戏开关已移除；
/// - 「选择启动程序」弹窗（`ExeSelectorDialog`）中的本次启动勾选已移除；
/// - `game.json.auto_create_shortcut` 字段**保留但不再读取**（不删任何用户数据）。
///
/// 持久化走项目既有的 `shared_preferences`（已被
/// `PortableSharedPreferencesStore` 重定向到 `data/prefs/shared_preferences.json`），
/// 便携版拷走整个目录即可带走设置。
///
/// 与 `lib/services/motion_preference.dart` / `lib/services/bpm_op_video_preference.dart`
/// 同构：`ChangeNotifier` 单例 + **首帧前 `load()`**（在 `main.dart` 与
/// `MotionPreference.load()` 同层调用），避免首屏先按默认值渲染再跳变。
///
/// 消费方：`lib/services/game_launch_service.dart`（`_maybeCreateDesktopShortcut`）
/// 与桌面设置页。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AutoShortcutPreference extends ChangeNotifier {
  /// SharedPreferences key。
  static const String _kAutoCreateOnFirstLaunch =
      'auto_create_shortcut_first_launch';

  static AutoShortcutPreference? _instance;
  static AutoShortcutPreference get instance =>
      _instance ??= AutoShortcutPreference._();
  AutoShortcutPreference._();

  bool _loaded = false;
  bool get loaded => _loaded;

  bool _enabled = false;

  /// 是否在首次启动游戏时自动生成桌面快捷方式。
  ///
  /// **默认 `false`（关闭）** —— 未设置过 prefs 的用户不会被隐式创建桌面图标；
  /// 需要该行为的用户到「设置 → 游戏与启动 → 系统」显式打开。
  bool get enabled => _enabled;

  /// 从 `SharedPreferences` 读取。幂等：已加载过则直接返回。
  ///
  /// 必须在 `runApp` 之前调用（与 `MotionPreference.load()` 同层）。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kAutoCreateOnFirstLaunch) ?? false;
    } catch (e) {
      debugPrint('[AUTO-SHORTCUT] 读取设置失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    // 先通知再落盘：开关要立刻生效（后续启动不依赖写盘结果）
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoCreateOnFirstLaunch, value);
    } catch (e) {
      debugPrint('[AUTO-SHORTCUT] 写入设置失败: $e');
    }
  }

  /// 仅供单测重置单例。
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// 仅供单测注入设置值，绕过 `SharedPreferences`。
  @visibleForTesting
  void seedForTest({bool? enabled}) {
    _loaded = true;
    if (enabled != null) _enabled = enabled;
    notifyListeners();
  }
}
