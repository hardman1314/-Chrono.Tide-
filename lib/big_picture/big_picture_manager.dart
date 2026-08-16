import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import '../theme/app_theme_manager.dart';

/// 全屏切换函数类型 (用于测试注入)
typedef SetFullScreenHandler = Future<void> Function(bool fullscreen);

/// 大屏模式 (Big Picture Mode / BPM) 全局状态管理器
///
/// 仿 [AppThemeManager] 的单例 ChangeNotifier 模式,通过 [isActive] 标志驱动
/// [MainContainer] 在桌面外壳与 [BigPictureShell] 之间切换。
///
/// 进入 BPM 时会自动将窗口置为全屏;退出时恢复窗口模式。
/// 模式切换通过 [enter]/[exit]/[toggle] 显式调用,不在构造时持久化,
/// 每次应用启动默认处于桌面模式,符合用户预期。
class BigPictureManager extends ChangeNotifier {
  BigPictureManager._();
  static final BigPictureManager instance = BigPictureManager._();

  bool _isActive = false;

  /// 全屏切换 handler (生产环境用 windowManager,测试可通过 [setFullScreenHandler] 注入)
  SetFullScreenHandler _setFullScreenHandler = (fullscreen) async {
    await windowManager.setFullScreen(fullscreen);
  };

  /// 当前是否处于大屏模式
  bool get isActive => _isActive;

  /// 测试注入: 替换全屏切换实现,避免在测试环境调用 windowManager
  @visibleForTesting
  void setFullScreenHandler(SetFullScreenHandler handler) {
    _setFullScreenHandler = handler;
  }

  /// 进入大屏模式
  ///
  /// 幂等: 重复调用不会触发副作用。
  /// 会调用全屏切换 handler 切换到全屏,
  /// 然后通过 [notifyListeners] 通知 [MainContainer] 重建为 [BigPictureShell]。
  Future<void> enter() async {
    if (_isActive) return;
    _isActive = true;
    debugPrint('[BPM] 进入大屏模式');
    try {
      // 修复 4K 全屏黑/白边：全屏前同步窗口背景色为当前主题色
      // 避免全屏切换瞬间露出旧背景色 (在 4K 高 DPI 下会被放大为明显边框)
      await _syncWindowBackground();
      await _setFullScreenHandler(true);
    } catch (e) {
      debugPrint('[BPM] 全屏切换异常: $e');
    }
    notifyListeners();
  }

  /// 退出大屏模式
  ///
  /// 幂等: 重复调用不会触发副作用。
  /// 会调用全屏切换 handler 退出全屏,恢复窗口模式。
  Future<void> exit() async {
    if (!_isActive) return;
    _isActive = false;
    debugPrint('[BPM] 退出大屏模式');
    try {
      await _setFullScreenHandler(false);
      // 退出全屏后再次同步窗口背景色
      await _syncWindowBackground();
    } catch (e) {
      debugPrint('[BPM] 退出全屏异常: $e');
    }
    notifyListeners();
  }

  /// 切换大屏模式状态
  Future<void> toggle() async => _isActive ? exit() : enter();

  /// 同步窗口背景色为当前主题色
  ///
  /// 修复 4K/高 DPI 下的视觉问题：
  /// - 全屏切换瞬间，窗口背景色可能与当前主题不一致
  /// - 在 4K 高 DPI 下，这个色差会被放大为明显的边框
  Future<void> _syncWindowBackground() async {
    try {
      final windowBgColor = AppThemeManager.instance.current.background;
      await windowManager.setBackgroundColor(windowBgColor);
    } catch (e) {
      debugPrint('[BPM] 同步窗口背景色异常: $e');
    }
  }
}
