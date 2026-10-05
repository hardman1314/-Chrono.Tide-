import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme_manager.dart';
import 'local_game_registry.dart';

/// 快捷自定义窗口服务（借鉴 AltSnap 交互模型）
///
/// 原生引擎编译进 runner 可执行文件（windows/runner/quick_window.cpp），
/// 通过 DynamicLibrary.process() 查找 qw_* 导出符号，无需加载额外 DLL。
///
/// 交互模型（仅作用于被跟踪的游戏窗口）：
/// - Alt + 左键拖拽窗口内部 → 移动窗口
/// - Alt + 左键拖拽窗口边缘 → 调整大小
/// - Alt + 中键             → 弹出动作菜单（置顶/透明/静音/最大化…）
/// - Alt + 滚轮             → 调整窗口透明度
///
/// 跟踪模型：自动跟踪运行中游戏——每 2s 从 LocalGameRegistry 读取所有
/// 活跃会话的 candidatePids，取首个运行中游戏作为跟踪目标；
/// 游戏退出后目标窗口失效，自动清空。
///
/// "静音游戏"使用 WASAPI 音频会话 API 按进程静音（替代 AltSnap 的
/// 全局系统静音），不影响系统其他声音。
class QuickWindowService {
  QuickWindowService._();
  static final QuickWindowService instance = QuickWindowService._();

  // 设置页开关 prefs key：仅控制"游戏启动后是否默认自动开启"，
  // 与"当前会话 g_enabled"是两个独立概念
  // （长按中键切 g_enabled 不写此 prefs；设置页切换改此 prefs 并立即应用到 g_enabled）
  static const _prefKey = 'quick_window_auto_enable';

  // ═════════════ FFI 绑定（runner 内置导出符号） ═════════════

  /// qw_* 符号是否可用（非 Windows 平台 / 旧构建下为 false）
  bool _available = false;
  bool _bound = false;

  // 启用/关闭引擎
  late final int Function(int) _qwEnable;
  late final int Function() _qwIsEnabled;
  // 菜单标签（原生侧 wcsdup 复制）
  late final void Function(Pointer<Pointer<Utf16>>, int) _qwSetLabels;
  // 菜单/提示窗口主题（亮/暗调色板切换）
  late final void Function(int) _qwSetTheme;
  // 跟踪目标
  late final void Function(Pointer<Void>) _qwSetTarget;
  late final Pointer<Void> Function() _qwGetTarget;
  // PID 集合（音频会话匹配 + 主窗口查找）
  late final int Function(Pointer<UnsignedLong>, int) _qwSetPids;
  late final Pointer<Void> Function() _qwFindWindow;
  // 状态查询
  late final int Function() _qwIsTopmost;
  late final int Function() _qwGetOpacity;
  late final int Function() _qwGetMuted;
  // 动作分发（供 Dart UI 未来直接调用）
  late final int Function(int) _qwPerform;

  // ═════════════ 运行状态 ═════════════

  bool _enabled = false;
  Timer? _pollTimer;
  String? _trackedGameTitle;

  bool get isAvailable => _available;
  bool get isEnabled => _enabled;
  String? get trackedGameTitle => _trackedGameTitle;

  /// 供设置页等 UI 打开时调用：同步原生侧最新状态（长按中键可能已挂起/恢复）
  void syncFromNative() => _syncNativeState();

  // ═════════════ 初始化 ═════════════

  Future<void> init() async {
    if (!Platform.isWindows) return;
    try {
      final lib = DynamicLibrary.process();
      _qwEnable = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>('qw_enable');
      _qwIsEnabled = lib
          .lookupFunction<Int32 Function(), int Function()>('qw_is_enabled');
      _qwSetLabels = lib.lookupFunction<
          Void Function(Pointer<Pointer<Utf16>>, Int32),
          void Function(Pointer<Pointer<Utf16>>, int)>('qw_set_labels');
      _qwSetTheme = lib
          .lookupFunction<Void Function(Int32), void Function(int)>(
              'qw_set_theme');
      _qwSetTarget = lib
          .lookupFunction<Void Function(Pointer<Void>), void Function(
              Pointer<Void>)>('qw_set_target');
      _qwGetTarget = lib.lookupFunction<
          Pointer<Void> Function(),
          Pointer<Void> Function()>('qw_get_target');
      _qwSetPids = lib.lookupFunction<
          Int32 Function(Pointer<UnsignedLong>, Int32),
          int Function(Pointer<UnsignedLong>, int)>('qw_set_pids');
      _qwFindWindow = lib.lookupFunction<
          Pointer<Void> Function(),
          Pointer<Void> Function()>('qw_find_window');
      _qwIsTopmost = lib
          .lookupFunction<Int32 Function(), int Function()>('qw_is_topmost');
      _qwGetOpacity = lib
          .lookupFunction<Int32 Function(), int Function()>('qw_get_opacity');
      _qwGetMuted =
          lib.lookupFunction<Int32 Function(), int Function()>('qw_get_muted');
      _qwPerform = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
              'qw_perform');
      _available = true;
      _bound = true;

      // 菜单/提示窗口跟随应用亮暗主题（亮色模式切换为浅底深字）
      AppThemeManager.instance.addListener(_onThemeChanged);
      _pushTheme();
    } catch (e) {
      debugPrint('[QUICK-WINDOW] ⚠️ qw_* 符号不可用（旧构建？）: $e');
      return;
    }

    // ★ 修复 1: 总是创建工作线程（钩子常驻），让长按中键任何状态下都能切换
    // （包括用户上次"关闭"后，下次启动通过长按中键重新开启）
    _pushLabels();
    final rc = _qwEnable(1);  // 创建线程 + 置 g_enabled=true
    if (rc <= 0) {
      debugPrint('[QUICK-WINDOW] ❌ 启动工作线程失败 rc=$rc');
      return;
    }
    _enabled = true;
    _ensurePoll();

    // 读 prefs（设置页开关：游戏启动后是否默认自动开启），
    // 决定初始 g_enabled：auto=false 时挂起（保留钩子，等长按中键开启）
    try {
      final prefs = await SharedPreferences.getInstance();
      // 默认开启（新用户首次进入游戏时自动启用）
      if (prefs.getBool(_prefKey) == null) {
        await prefs.setBool(_prefKey, true);
      }
      final auto = prefs.getBool(_prefKey) ?? true;
      if (!auto) {
        await _suspend();  // 切 g_enabled=false，钩子保留
      }
      debugPrint('[QUICK-WINDOW] ✅ 初始化完成: ${auto ? "已自动启用" : "已挂起（需长按中键开启）"}');
    } catch (e) {
      debugPrint('[QUICK-WINDOW] ⚠️ 读取开关状态失败: $e');
    }
  }

  // ═════════════ 开关（两个独立概念） ═════════════
  //
  // 1. "自动启用" prefs（设置页开关 / autoEnable）：
  //    - 控制"游戏启动后是否默认自动开启"
  //    - 由 setAutoEnable() 写 prefs 并立即应用
  //    - 长按中键切换不影响此 prefs
  //
  // 2. "当前会话启用" 状态（_enabled / g_enabled）：
  //    - 当前是否启用（运行时）
  //    - 由 _applyEnable() / _suspend() 切换
  //    - 长按中键可切；不写 prefs

  /// 内部：启用当前会话（切 g_enabled=true，**不写 prefs**）。
  /// 由 init()（按 prefs 决定初始状态）和 setAutoEnable() 触发。
  Future<void> _applyEnable() async {
    if (!_bound) return;
    if (_enabled) return;
    _qwEnable(1);
    _enabled = true;
    _ensurePoll();
    _refreshTarget();
    debugPrint('[QUICK-WINDOW] ▶ 已启用当前会话');
  }

  /// 内部：挂起当前会话（切 g_enabled=false，**不写 prefs**）。
  /// 钩子常驻，长按中键可重新开启。
  Future<void> _suspend() async {
    if (!_bound) return;
    if (!_enabled) return;
    _qwEnable(0);  // 仅切 g_enabled 标志（不销毁线程）
    _enabled = false;
    _trackedGameTitle = null;
    debugPrint('[QUICK-WINDOW] ⏸ 已挂起当前会话（钩子常驻，长按中键可重新开启）');
  }

  /// 设置页"快捷窗口控制"开关调用：写 prefs（决定下次游戏启动时是否自动启用）
  /// 并立即应用到当前会话——用户切换时立即看到效果
  Future<bool> setAutoEnable(bool value) async {
    if (!_bound) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (e) {
      debugPrint('[QUICK-WINDOW] ⚠️ 写入自动启用开关失败: $e');
      return false;
    }
    if (value) {
      await _applyEnable();
    } else {
      await _suspend();
    }
    debugPrint('[QUICK-WINDOW] 💾 自动启用开关已${value ? "开启" : "关闭"} → 当前会话${value ? "已启用" : "已挂起"}');
    return true;
  }

  /// 读设置页"自动启用"开关 prefs（设置页 UI 显示用）
  Future<bool> getAutoEnable() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefKey) ?? true;  // 默认开启
    } catch (e) {
      return true;
    }
  }

  // ═════════════ 菜单标签 / 主题 ═════════════

  /// 主题变化 → 同步原生菜单调色板
  void _onThemeChanged() => _pushTheme();

  /// 推送当前亮/暗主题到原生层（原生侧切换菜单与提示窗口调色板）
  void _pushTheme() {
    if (!_bound) return;
    final dark =
        AppThemeManager.instance.current.brightness == Brightness.dark;
    _qwSetTheme(dark ? 1 : 0);
  }

  /// 推送中文菜单标签到原生层（原生代码不含 UI 文案，避免源码编码问题）
  void _pushLabels() {
    const labels = [
      '窗口置顶', // 0 QL_TOPMOST_ON
      '取消置顶', // 1 QL_TOPMOST_OFF
      '增加透明度', // 2 QL_OPACITY_UP
      '降低透明度', // 3 QL_OPACITY_DOWN
      '恢复不透明', // 4 QL_OPACITY_FULL
      '静音游戏', // 5 QL_MUTE_ON
      '取消静音', // 6 QL_MUTE_OFF
      '最大化', // 7 QL_MAXIMIZE
      '还原窗口', // 8 QL_RESTORE
      '最小化', // 9 QL_MINIMIZE
      '居中显示', // 10 QL_CENTER
      '关闭窗口', // 11 QL_CLOSE
      '正在关闭快捷窗口控制', // 12 QL_HINT_CLOSING
      '正在开启快捷窗口控制', // 13 QL_HINT_OPENING
      '继续长按 · 松开取消', // 14 QL_HINT_SUB
      '已关闭快捷窗口控制', // 15 QL_HINT_CLOSED
      '已开启快捷窗口控制', // 16 QL_HINT_OPENED
    ];
    final ptr = calloc<Pointer<Utf16>>(labels.length);
    try {
      for (var i = 0; i < labels.length; i++) {
        ptr[i] = labels[i].toNativeUtf16();
      }
      _qwSetLabels(ptr, labels.length);
      // 原生侧已 wcsdup 复制，释放 Dart 分配的临时内存
      for (var i = 0; i < labels.length; i++) {
        calloc.free(ptr[i]);
      }
    } finally {
      calloc.free(ptr);
    }
  }

  // ═════════════ WindowTracker：自动跟踪运行中游戏 ═════════════

  /// 常驻轮询：同步原生挂起/恢复状态（长按中键切换）+ 刷新跟踪目标。
  /// 挂起（native=false）时 timer 继续运行以便捕捉长按恢复；仅在用户
  /// 从设置页完全关闭时才停止。
  void _ensurePoll() {
    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _syncNativeState();
      _refreshTarget();
    });
  }

  /// 同步原生功能标志：长按中键切换后，g_enabled 已被原生翻面；
  /// Dart 侧据此同步 _enabled（**不写 prefs**——长按中键是会话级切换）。
  /// 设置页开关 prefs 仅在 setAutoEnable() / init() 中读写，与此处无关。
  void _syncNativeState() {
    if (!_bound) return;

    // 防御性同步：万一 _enabled 与原生不一致（长按中键翻转），修正本地缓存
    final native = _qwIsEnabled() == 1;
    if (native != _enabled) {
      _enabled = native;
      debugPrint('[QUICK-WINDOW] 🔁 同步原生状态: ${native ? "已开启" : "已挂起"}（会话级）');
    }
  }

  /// 刷新跟踪目标：取运行中游戏的 candidatePids → 查找主窗口 → 设为引擎目标
  void _refreshTarget() {
    if (!_bound || !_enabled) return;

    List<Map<String, dynamic>> sessions;
    try {
      sessions = LocalGameRegistry.instance.getActiveSessionsInfo();
    } catch (e) {
      debugPrint('[QUICK-WINDOW] ⚠️ 读取活跃会话失败: $e');
      return;
    }

    // 运行中 = candidatePids 非空（进程确认存活时由注册表回填）
    Map<String, dynamic>? active;
    for (final s in sessions) {
      final pids = (s['candidatePids'] as List?) ?? const [];
      if (pids.isNotEmpty) {
        active = s;
        break;
      }
    }

    if (active == null) {
      // 无运行中游戏：清空目标（手势自动失效，钩子保持待命）
      final cur = _qwGetTarget();
      if (cur != nullptr) {
        _qwSetTarget(nullptr);
        _trackedGameTitle = null;
      }
      return;
    }

    final title = active['gameTitle'] as String? ?? '';
    if (title != _trackedGameTitle) {
      debugPrint('[QUICK-WINDOW] 🎯 跟踪目标: $title');
      _trackedGameTitle = title;
    }

    // 推送 PID 集合（音频会话匹配用，含子进程）
    final pids = ((active['candidatePids'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList();
    if (pids.isEmpty) return;
    final pidPtr = calloc<UnsignedLong>(pids.length);
    try {
      for (var i = 0; i < pids.length; i++) {
        pidPtr[i] = pids[i];
      }
      _qwSetPids(pidPtr, pids.length);
    } finally {
      calloc.free(pidPtr);
    }

    // 每次重新查找主窗口并比较：目标失效（游戏重启换 HWND）时自动切换
    final cur = _qwGetTarget();
    final found = _qwFindWindow();
    if (found != nullptr && found != cur) {
      _qwSetTarget(found);
    }
  }

  // ═════════════ 状态查询 / 动作（供 Dart UI 未来使用） ═════════════

  bool get isTargetTopmost => _bound && _qwIsTopmost() == 1;
  int get targetOpacity => _bound ? _qwGetOpacity() : 255;
  bool get isTargetMuted => _bound && _qwGetMuted() == 1;

  /// Dart 侧动作分发（与原生菜单同实现）
  ///
  /// action: 1=置顶切换 2=最小化 3=最大化切换 4=居中 5=关闭
  ///         6=透明度+ 7=透明度- 8=不透明 9=静音切换
  int perform(int action) => _bound ? _qwPerform(action) : -1;
}
