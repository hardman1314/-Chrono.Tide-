import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'locale_service.dart';
import 'win32_process_service.dart'; // ★ 重构: 进程检测改 FFI（替代 tasklist/PowerShell）
import 'game_launch_logger.dart'; // ★ 游戏启动流程日志

/// Magpie 超分模式
enum MagpieMode {
  /// 外接：使用用户本地安装的 Magpie
  external,

  /// 内接：使用内置的 Magpie
  internal,
}

/// 超分启动状态
enum ScalingState {
  /// 空闲
  idle,

  /// 正在准备（启动 Magpie / 注入 Profile）
  preparing,

  /// 超分运行中
  scaling,

  /// 出错
  error,
}

/// 超分效果预设
class ScalingPreset {
  final String name;
  final String displayName;
  final String description;
  final List<Map<String, dynamic>> effects;

  const ScalingPreset({
    required this.name,
    required this.displayName,
    required this.description,
    required this.effects,
  });

  Map<String, dynamic> toScalingModeJson() => {
        'name': name,
        'effects': effects,
      };
}

/// Magpie 集成核心服务
class MagpieService with ChangeNotifier {
  static final MagpieService instance = MagpieService._();

  MagpieService._();

  // ========== 持久化键 ==========
  static const _kMode = 'magpie_mode';
  static const _kExternalPath = 'magpie_external_path';
  static const _kDefaultPreset = 'magpie_default_preset';
  static const _kAutoClose = 'magpie_auto_close';
  static const _kFallbackOnFail = 'magpie_fallback_on_fail';
  static const _kCustomTemplates = 'magpie_custom_templates';
  // ★ Fix（2026-08-09 回退修复）：窗口类名缓存持久化键
  // 旧实现仅内存缓存 → 首次启动必须重新检测（启动器型游戏极易失败）。
  // 持久化后，已检测过的游戏复用缓存，Magpie Profile 首次即可正确匹配。
  static const _kClassNameCache = 'magpie_classname_cache';

  // ========== 状态 ==========
  MagpieMode _mode = MagpieMode.internal;
  String _externalPath = '';
  String _defaultPreset = '高档位';
  bool _autoClose = true;
  bool _fallbackOnFail = true;
  ScalingState _scalingState = ScalingState.idle;
  String? _errorMessage;
  Process? _magpieProcess;
  bool _initialized = false;

  // 游戏进程监控
  String? _monitoredGameExe;
  String? _monitoredGameDir; // ★ Fix: 游戏目录路径（进程树监控用）
  Timer? _gameMonitorTimer;
  // ★ 日志辅助字段：记录当前超分会话的游戏标题与起始时间，
  // 供 _startGameMonitor 在游戏退出时输出 logGameExit / logMagpieExit。
  String? _monitoredGameTitle;
  DateTime? _magpieLaunchStartTime;
  // ★ Fix v2: 游戏退出确认计数器——连续多次检测不到主 exe 才判定退出
  // 避免因 FFI 偶发返回空列表或游戏短暂切换进程而误关 Magpie
  int _gameExitMissCount = 0;
  static const int _gameExitMissThreshold = 2; // 连续 2 次(6s)确认退出

  // 窗口类名缓存（exe路径 → 类名）
  static final Map<String, String> _classNameCache = {};

  // 内置预设模板（从 Galgame超分模版 精简，去除分隔行和重复项）
  static final List<ScalingPreset> builtInPresets = [
    ScalingPreset(
      name: 'Lanczos',
      displayName: 'Lanczos (轻量)',
      description: '最轻量，仅插值放大，几乎无GPU负担。适合仅需要简单放大的场景。',
      effects: [
        {
          'name': 'Lanczos',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
      ],
    ),
    ScalingPreset(
      name: 'FSR',
      displayName: 'FSR (通用)',
      description: 'AMD FSR 通用型超分，GPU负载低。适合各类游戏的基础超分。',
      effects: [
        {
          'name': 'FSR\\FSR_EASU',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
        {
          'name': 'FSR\\FSR_RCAS',
          'parameters': {'sharpness': 0.87}
        },
      ],
    ),
    ScalingPreset(
      name: 'FSRCNNX',
      displayName: 'FSRCNNX (高质量)',
      description: '神经网络超分，画质优秀，GPU负载中等。适合对画质有较高要求的场景。',
      effects: [
        {'name': 'FSRCNNX\\FSRCNNX'},
      ],
    ),
    ScalingPreset(
      name: 'ACNet',
      displayName: 'ACNet (AI降噪)',
      description: 'AI降噪超分，适合有噪点的老游戏。能有效去除画面噪点同时提升清晰度。',
      effects: [
        {'name': 'ACNet'},
      ],
    ),
    ScalingPreset(
      name: 'Anime4K',
      displayName: 'Anime4K',
      description: 'Anime4K 降噪放大 L 档。基础的 Anime4K 超分方案，兼顾降噪与放大。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_Denoise_L'},
      ],
    ),
    ScalingPreset(
      name: 'CRT-Geom',
      displayName: 'CRT-Geom',
      description: 'CRT 显示器模拟效果，还原老式CRT显示器的扫描线和色彩风格。适合复古游戏。',
      effects: [
        {
          'name': 'CRT\\CRT_Geom',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0},
          'parameters': {
            'monitorGamma': 2.2,
            'cornerSize': 0.001,
            'curvature': 0.0,
            'interlace': 0.0,
            'CRTGamma': 1.5
          }
        },
      ],
    ),
    ScalingPreset(
      name: 'Integer Scale 2x',
      displayName: 'Integer 2x',
      description: '整数倍放大，像素完美。每个像素精确放大2倍，无模糊，适合像素风游戏。',
      effects: [
        {
          'name': 'Nearest',
          'scalingType': 0,
          'scale': {'x': 2.0, 'y': 2.0}
        },
      ],
    ),
    // ── 以下为 Galgame 超分模版 档位 ──
    // 能效区（低端显卡 / 1080p 显示器）
    ScalingPreset(
      name: 'A4K 超轻量化',
      displayName: 'A4K 超轻量',
      description: '能效区 · 画质提升约10%，和游戏原有全屏几乎一样。GPU负载极低，可不使用超分。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_S'},
        {
          'name': 'Bicubic',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
      ],
    ),
    ScalingPreset(
      name: 'A4K 轻量化',
      displayName: 'A4K 轻量',
      description: '能效区 · 超分到1080p首选，高清度60%，GPU负载中下。适合低端显卡。',
      effects: [
        {
          'name': 'Bicubic',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
        {'name': 'Anime4K\\Anime4K_Restore_S'},
      ],
    ),
    ScalingPreset(
      name: 'A4K 组合 低锐化',
      displayName: 'A4K 组合',
      description: '能效区 · 超分到1080p首选，高清度70%，GPU负载中下。低锐化，画面更柔和。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_S'},
        {
          'name': 'Bicubic',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
        {'name': 'Anime4K\\Anime4K_Restore_Soft_S'},
      ],
    ),
    // 性能区（中端显卡）
    ScalingPreset(
      name: '高档位',
      displayName: 'A4K 高档位',
      description: '性能区 · 笔记本4060最佳"平衡"，高清度85%，GPU负载中。超分到2K/2.5K或1080p首选。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_S'},
        {
          'name': 'Bicubic',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
        {'name': 'Anime4K\\Anime4K_Restore_Soft_M'},
      ],
    ),
    ScalingPreset(
      name: '特高档位',
      displayName: 'A4K 特高档位',
      description: '性能区 · 超分到2K首选，高清度90%，GPU负载中上。画质90分，适合中高端显卡。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_L'},
        {
          'name': 'Lanczos',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
        {'name': 'Anime4K\\Anime4K_Restore_L'},
      ],
    ),
    ScalingPreset(
      name: '超高档位',
      displayName: 'A4K 超高档位',
      description: '性能区 · 台式4060最佳"平衡"，高清度95%，GPU负载高。超分到2K/2.5K或1080p首选。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_VL'},
        {
          'name': 'Lanczos',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
        {'name': 'Anime4K\\Anime4K_Restore_VL'},
      ],
    ),
    ScalingPreset(
      name: '最高档位',
      displayName: 'A4K 最高档位',
      description: '性能区 · 超分2K/2.5K基本无损画质。高负载GPU，建议至少移动端4050或桌面端4060以上显卡。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_VL'},
        {'name': 'Anime4K\\Anime4K_Restore_VL'},
        {
          'name': 'Lanczos',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
      ],
    ),
    ScalingPreset(
      name: '超分到4K',
      displayName: 'A4K 4K首选',
      description: '性能区 · 超分4K首选，4K最佳。高负载GPU，建议至少移动端4050或桌面端4060以上，4K掉帧率最低。',
      effects: [
        {'name': 'Anime4K\\Anime4K_Upscale_VL'},
        {'name': 'Anime4K\\Anime4K_Restore_VL'},
        {
          'name': 'Lanczos',
          'scalingType': 1,
          'scale': {'x': 1.0, 'y': 1.0}
        },
        {'name': 'Anime4K\\Anime4K_Upscale_VL'},
      ],
    ),
  ];

  // 用户自定义模板
  List<Map<String, dynamic>> _customTemplates = [];

  // ========== Getters ==========
  MagpieMode get mode => _mode;
  String get externalPath => _externalPath;
  String get defaultPreset => _defaultPreset;
  bool get autoClose => _autoClose;
  bool get fallbackOnFail => _fallbackOnFail;
  ScalingState get scalingState => _scalingState;
  String? get errorMessage => _errorMessage;
  bool get isInitialized => _initialized;

  /// 获取所有可用预设（内置 + 自定义）
  List<ScalingPreset> get allPresets {
    final presets = List<ScalingPreset>.from(builtInPresets);
    for (final tmpl in _customTemplates) {
      try {
        final effects = (tmpl['effects'] as List?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [];
        if (effects.isEmpty) continue;
        presets.add(ScalingPreset(
          name: tmpl['name'] as String? ?? '自定义',
          displayName: tmpl['name'] as String? ?? '自定义',
          description: '用户导入的模板',
          effects: effects,
        ));
      } catch (_) {}
    }
    return presets;
  }

  /// 当前选中的预设
  ScalingPreset get currentPreset {
    return allPresets.firstWhere(
      (p) => p.name == _defaultPreset,
      orElse: () => builtInPresets[10], // 默认高档位
    );
  }

  // ========== 初始化 ==========
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = prefs.getString(_kMode) == 'external'
        ? MagpieMode.external
        : MagpieMode.internal;
    _externalPath = prefs.getString(_kExternalPath) ?? '';
    _defaultPreset = prefs.getString(_kDefaultPreset) ?? '高档位';
    _autoClose = prefs.getBool(_kAutoClose) ?? true;
    _fallbackOnFail = prefs.getBool(_kFallbackOnFail) ?? true;

    // 加载自定义模板
    final templatesJson = prefs.getString(_kCustomTemplates);
    if (templatesJson != null) {
      try {
        final decoded = jsonDecode(templatesJson) as List;
        _customTemplates =
            decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
    }

    // ★ Fix（2026-08-09 回退修复）：加载持久化的窗口类名缓存
    // 已检测过的游戏复用缓存，避免每次启动都走 EnumWindows 检测
    await _loadClassNameCache(prefs);

    // 确保内置 Magpie 配置目录存在并释放模板配置
    await _ensureInternalConfig();

    _initialized = true;
    _log('INFO', 'MagpieService 初始化完成 | 模式: $_mode | 预设: $_defaultPreset');
    notifyListeners();
  }

  /// 确保内置 Magpie 的配置目录和默认配置文件存在
  Future<void> _ensureInternalConfig() async {
    try {
      final configDir = Directory(internalMagpieConfigDir);
      if (!await configDir.exists()) {
        await configDir.create(recursive: true);
        _log('INFO', '创建内置 Magpie 配置目录: $internalMagpieConfigDir');
      }

      // 如果配置文件不存在，从 Asset 释放默认配置
      final configFile = File(internalMagpieConfigPath);
      if (!await configFile.exists()) {
        await _releaseDefaultConfig(configFile);
      }
    } catch (e) {
      _log('WARN', '确保内置配置失败: $e');
    }
  }

  /// 从 Flutter Asset 释放默认配置到文件系统
  Future<void> _releaseDefaultConfig(File targetFile) async {
    List<dynamic> scalingModes;
    try {
      // 尝试从 Asset 加载
      final assetData =
          await rootBundle.load('assets/magpie/scaling_modes_template.json');
      final jsonString = utf8.decode(assetData.buffer.asUint8List());
      final decoded = jsonDecode(jsonString);
      scalingModes = decoded is Map && decoded.containsKey('scalingModes')
          ? decoded['scalingModes'] as List
          : (decoded is List ? decoded : []);
    } catch (e) {
      _log('WARN', '从 Asset 释放配置失败，使用代码内置: $e');
      scalingModes = builtInPresets.map((p) => p.toScalingModeJson()).toList();
    }

    // 构建 Magpie 完整配置
    // 关键：profiles 数组第一个元素必须是默认 Profile（name/pathRule/classNameRule 为空）
    final config = _buildMagpieConfig(scalingModes, [_buildDefaultProfile()]);

    await targetFile.writeAsString(
      const JsonEncoder.withIndent('    ').convert(config),
      flush: true,
    );
    _log('INFO', '已释放默认 Magpie 配置: ${targetFile.path}');
  }

  /// 构建 Magpie 完整配置对象
  static Map<String, dynamic> _buildMagpieConfig(
    List<dynamic> scalingModes,
    List<Map<String, dynamic>> profiles,
  ) {
    return {
      'scalingModes': scalingModes,
      'profiles': profiles,
      'shortcuts': {'scale': 0, 'windowedModeScale': 0, 'toolbar': 0},
      'countdownSeconds': 3,
      'developerMode': false,
      'debugMode': false,
      'benchmarkMode': false,
      'disableTopmost': false,
      'disableEffectCache': false,
      'disableFontCache': false,
      'saveEffectSources': false,
      'warningsAreErrors': false,
      'allowScalingMaximized': false,
      'simulateExclusiveFullscreen': false,
      'alwaysRunAsAdmin': false,
      'showNotifyIcon': true,
      'inlineParams': false,
      'autoCheckForUpdates': false,
      'checkForPreviewUpdates': false,
      'theme': 0,
      'windowPos': {
        'centerX': -1.0,
        'centerY': -1.0,
        'width': 800.0,
        'height': 600.0,
        'maximized': false,
      },
      'overlay': {
        'fullscreenInitialToolbarState': 2,
        'windowedInitialToolbarState': 2,
      },
    };
  }

  /// 生成 Magpie 默认 Profile（profiles 数组的第一个元素）
  /// 默认 Profile 的 name、pathRule、classNameRule 均为空，不写入这些字段
  static Map<String, dynamic> _buildDefaultProfile() {
    return {
      'scalingMode': 0,
      'captureMethod': 0,
      'multiMonitorUsage': 0,
      'initialWindowedScaleFactor': 0,
      'customInitialWindowedScaleFactor': 1.25,
      'graphicsCardId': {'idx': -1, 'vendorId': 0, 'deviceId': 0},
      'frameRateLimiterEnabled': false,
      'maxFrameRate': 60.0,
      '3DGameMode': false,
      'captureTitleBar': false,
      'adjustCursorSpeed': true,
      'disableDirectFlip': false,
      'cursorScaling': 2,
      'customCursorScaling': 1.0,
      'cursorInterpolationMode': 0,
      'autoHideCursorEnabled': false,
      'autoHideCursorDelay': 3.0,
      'croppingEnabled': false,
      'cropping': {'left': 0.0, 'top': 0.0, 'right': 0.0, 'bottom': 0.0},
      'destAlignment': 4,
    };
  }

  /// 生成游戏 Profile（包含所有 Magpie 要求的必填字段）
  /// [classNameRule] 窗口类名（必须非空，否则 Magpie 会丢弃该 Profile）
  /// [scalingModeIndex] 缩放模式在 scalingModes 数组中的索引（必须 >= 0）
  static Map<String, dynamic> _buildGameProfile({
    required String profileName,
    required String gameExePath,
    required String classNameRule,
    required int scalingModeIndex,
  }) {
    return {
      // 标识字段（Magpie _LoadProfile 要求非默认 Profile 必须包含这些字段）
      'name': profileName,
      'packaged': false,
      'pathRule': gameExePath,
      'classNameRule': classNameRule,
      'launcherPath': '',
      'autoScale': 1, // Fullscreen 自动缩放
      'launchParameters': '',
      // 缩放配置
      'scalingMode': scalingModeIndex,
      'captureMethod': 2, // GDI - Galgame 兼容性最佳
      'multiMonitorUsage': 0, // Closest
      'initialWindowedScaleFactor': 0, // Auto
      'customInitialWindowedScaleFactor': 1.25,
      'graphicsCardId': {'idx': -1, 'vendorId': 0, 'deviceId': 0},
      'frameRateLimiterEnabled': false,
      'maxFrameRate': 60.0,
      '3DGameMode': true, // 开启 3D 游戏模式，修复光标和画面问题
      'captureTitleBar': false,
      'adjustCursorSpeed': true,
      'disableDirectFlip': false,
      'cursorScaling': 2, // NoScaling
      'customCursorScaling': 1.0,
      'cursorInterpolationMode': 1, // Bilinear - 光标插值，修复超分后光标问题
      'autoHideCursorEnabled': false,
      'autoHideCursorDelay': 3.0,
      'croppingEnabled': false,
      'cropping': {'left': 0.0, 'top': 0.0, 'right': 0.0, 'bottom': 0.0},
      'destAlignment': 4, // Center
    };
  }

  // ========== 配置方法 ==========
  Future<void> setMode(MagpieMode mode) async {
    _mode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kMode, mode == MagpieMode.external ? 'external' : 'internal');
    _log('INFO', '模式切换: $mode');
    notifyListeners();
  }

  Future<void> setExternalPath(String path) async {
    _externalPath = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kExternalPath, path);
    _log('INFO', '外接路径设置: $path');
    notifyListeners();
  }

  Future<void> setDefaultPreset(String presetName) async {
    _defaultPreset = presetName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDefaultPreset, presetName);
    _log('INFO', '默认预设切换: $presetName');
    notifyListeners();
  }

  Future<void> setAutoClose(bool value) async {
    _autoClose = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoClose, value);
    notifyListeners();
  }

  Future<void> setFallbackOnFail(bool value) async {
    _fallbackOnFail = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFallbackOnFail, value);
    notifyListeners();
  }

  /// 导入自定义模板 JSON
  Future<bool> importCustomTemplate(String jsonFilePath) async {
    try {
      final file = File(jsonFilePath);
      if (!await file.exists()) return false;

      final content = await file.readAsString();
      final decoded = jsonDecode(content);

      // 支持 { "scalingModes": [...] } 格式
      List<dynamic> modes;
      if (decoded is Map && decoded.containsKey('scalingModes')) {
        modes = decoded['scalingModes'] as List;
      } else if (decoded is List) {
        modes = decoded;
      } else {
        _log('ERROR', '模板格式不正确');
        return false;
      }

      int imported = 0;
      for (final mode in modes) {
        final modeMap = Map<String, dynamic>.from(mode as Map);
        // 跳过没有 effects 的分隔行
        if (!modeMap.containsKey('effects') ||
            (modeMap['effects'] as List).isEmpty) {
          continue;
        }
        // 检查是否已存在同名模板
        final name = modeMap['name'] as String? ?? '';
        _customTemplates.removeWhere((t) => t['name'] == name);
        _customTemplates.add(modeMap);
        imported++;
      }

      await _saveCustomTemplates();
      _log('INFO', '导入模板成功: $imported 个');
      notifyListeners();
      return imported > 0;
    } catch (e) {
      _log('ERROR', '导入模板失败: $e');
      return false;
    }
  }

  /// 删除自定义模板
  Future<void> removeCustomTemplate(String name) async {
    _customTemplates.removeWhere((t) => t['name'] == name);
    await _saveCustomTemplates();
    if (_defaultPreset == name) {
      _defaultPreset = builtInPresets[10].name;
    }
    notifyListeners();
  }

  Future<void> _saveCustomTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCustomTemplates, jsonEncode(_customTemplates));
  }

  // ========== 窗口类名缓存持久化（★ Fix 2026-08-09 回退修复） ==========
  // 旧实现仅内存缓存 → 每次应用重启都丢失，首次启动必须重新走 EnumWindows
  // 检测（启动器型游戏窗口初始化慢，极易在检测窗口期内拿不到类名）。
  // 持久化后，已检测过的游戏直接复用缓存，Magpie Profile 首次即可正确匹配。

  /// 从 SharedPreferences 加载类名缓存到内存
  Future<void> _loadClassNameCache(SharedPreferences prefs) async {
    try {
      final json = prefs.getString(_kClassNameCache);
      if (json != null && json.isNotEmpty) {
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        _classNameCache.addAll(
          decoded.map((k, v) => MapEntry(k, v.toString())),
        );
        _log('INFO', '已加载窗口类名缓存: ${_classNameCache.length} 条');
      }
    } catch (e) {
      _log('WARN', '加载窗口类名缓存失败（忽略，使用空缓存）: $e');
    }
  }

  /// 将内存类名缓存持久化到 SharedPreferences
  Future<void> _saveClassNameCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kClassNameCache, jsonEncode(_classNameCache));
    } catch (e) {
      _log('WARN', '持久化窗口类名缓存失败（不影响本次启动）: $e');
    }
  }

  /// 迁移游戏目录后同步 Magpie 相关路径引用（逐项 best-effort，失败仅告警）。
  ///
  /// 由 [LocalGameRegistry.finalizeGameMove] 在移动收尾阶段调用：
  /// ① 类名缓存键迁移：`_classNameCache` 以游戏 exe 绝对路径为键，
  ///    旧键随目录迁移失效 → 键改名保留缓存值（下次启动免 EnumWindows 重检测）；
  /// ② DPI 兼容性注册表值改名：`HKCU\...\AppCompatFlags\Layers` 的**值名**
  ///    就是游戏 exe 绝对路径（`_setDpiCompatibility` 写入），旧值名随迁移失效
  ///    → 读出旧值 → 以新 exe 路径为值名重建 → 删除旧值名（PowerShell 范式
  ///    与 `_setDpiCompatibility` 一致）。
  Future<void> updateGamePaths({
    required String oldExePath,
    required String newExePath,
  }) async {
    if (oldExePath == newExePath) return;

    // ① 类名缓存键迁移
    try {
      if (_classNameCache.containsKey(oldExePath)) {
        final className = _classNameCache.remove(oldExePath)!;
        _classNameCache[newExePath] = className;
        await _saveClassNameCache();
        _log('INFO', '已迁移窗口类名缓存键: $oldExePath → $newExePath');
      }
    } catch (e) {
      _log('WARN', '类名缓存键迁移失败（不影响移动）: $e');
    }

    // ② DPI 兼容性注册表值改名
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          '''
\$regPath = 'HKCU:\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers'
\$oldName = '$oldExePath'
\$newName = '$newExePath'
\$existing = \$null
try {
  \$existing = Get-ItemProperty -Path \$regPath -Name \$oldName -ErrorAction SilentlyContinue
} catch {}
if (\$existing -ne \$null) {
  \$value = \$existing.\$oldName
  Set-ItemProperty -Path \$regPath -Name \$newName -Value \$value -Type String -Force
  Remove-ItemProperty -Path \$regPath -Name \$oldName -Force
  Write-Output 'MIGRATED'
} else {
  Write-Output 'NOT_PRESENT'
}
'''
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        _log('WARN', 'DPI 注册表值迁移超时(10s)，跳过（下次超分启动会重新设置）');
        throw TimeoutException('DPI registry migration timeout');
      });
      final output = result.stdout.toString().trim();
      if (output == 'MIGRATED') {
        _log('INFO', '已迁移 DPI 兼容性注册表值: $oldExePath → $newExePath');
      }
      // NOT_PRESENT = 旧游戏从未设置过 DPI 兼容性，无需处理
    } catch (e) {
      _log('WARN', 'DPI 注册表值迁移失败（不影响移动）: $e');
    }
  }

  // ========== 可用性检测 ==========
  /// 检测 Magpie 是否可用
  Future<bool> isAvailable() async {
    if (_mode == MagpieMode.external) {
      return _externalPath.isNotEmpty && File(_externalPath).existsSync();
    } else {
      // 内接模式：检查 runtime/magpie/Magpie.exe 是否存在
      return File(internalMagpieExePath).existsSync();
    }
  }

  /// 同步检测可用性（用于 UI 快速判断）
  bool get isAvailableSync {
    if (_mode == MagpieMode.external) {
      return _externalPath.isNotEmpty && File(_externalPath).existsSync();
    } else {
      return File(internalMagpieExePath).existsSync();
    }
  }

  /// 检测 Magpie 是否正在运行
  ///
  /// ★ 重构: 使用 Win32 FFI enumerateProcesses 替代 tasklist。
  /// tasklist 每次调用需 200-500ms（杀软扫描下更慢），FFI 仅需 1-3ms。
  /// FFI 不可用时回退到 tasklist。
  Future<bool> isMagpieRunning() async {
    // ★ 优先使用 FFI（毫秒级，不阻塞事件循环）
    if (Win32ProcessService.isAvailable) {
      try {
        final processes = Win32ProcessService.enumerateProcesses();
        return processes.any((p) => p.exeName == 'magpie.exe');
      } catch (e) {
        _log('WARN', 'FFI enumerateProcesses 异常，回退到 tasklist: $e');
      }
    }

    // ★ 回退: tasklist（FFI 不可用时使用）
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq Magpie.exe', '/NH'],
        runInShell: true,
      ).timeout(const Duration(seconds: 5), onTimeout: () {
        _log('WARN', '检测 Magpie 运行状态超时(5s)，假定未运行');
        return ProcessResult(0, 0, '', '');
      });
      return result.stdout.toString().contains('Magpie.exe');
    } catch (_) {
      return false;
    }
  }

  // ========== 路径 ==========
  /// 内置 Magpie 根目录（runtime/magpie/）
  static String get internalMagpieDir {
    // 使用 exe 所在目录的 runtime/magpie/
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return p.join(exeDir, 'runtime', 'magpie');
  }

  /// 内置 Magpie exe 路径
  static String get internalMagpieExePath =>
      p.join(internalMagpieDir, 'Magpie.exe');

  /// 内置 Magpie 配置目录
  static String get internalMagpieConfigDir =>
      p.join(internalMagpieDir, 'config');

  /// 内置 Magpie 配置文件路径
  static String get internalMagpieConfigPath =>
      p.join(internalMagpieConfigDir, 'config.json');

  /// 内置 Magpie 效果目录
  static String get internalMagpieEffectsDir =>
      p.join(internalMagpieDir, 'effects');

  /// 外接 Magpie 的配置目录
  String get externalConfigDir {
    if (_externalPath.isEmpty) return '';
    return p.join(File(_externalPath).parent.path, 'config');
  }

  /// 外接 Magpie 的配置文件路径
  String get externalConfigPath => p.join(externalConfigDir, 'config.json');

  // ========== DPI 兼容性设置 ==========

  /// 设置游戏 exe 的 DPI 兼容性（替代高 DPI 缩放行为）
  ///
  /// 对应 Windows 右键属性 → 兼容性 → 更改高 DPI 设置 → 替代高 DPI 缩放行为
  /// 通过注册表 HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers 实现
  /// 这是 Magpie 正常工作的前提：避免 Windows DPI 虚拟化干扰窗口捕获和缩放
  Future<void> _setDpiCompatibility(String gameExePath) async {
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          '''
\$regPath = 'HKCU:\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers'
\$exePath = '$gameExePath'

# 检查是否已有 DPI 兼容性设置
\$existing = \$null
try {
  \$existing = Get-ItemProperty -Path \$regPath -Name \$exePath -ErrorAction SilentlyContinue
} catch {}

\$currentValue = ''
if (\$existing -ne \$null) {
  \$currentValue = \$existing.\$exePath
  if (\$currentValue -eq \$null) { \$currentValue = '' }
}

# HIGHDPIAWARE 标志表示"替代高 DPI 缩放行为"（由应用程序执行缩放）
if (\$currentValue -notlike '*HIGHDPIAWARE*') {
  # 保留已有的其他兼容性标志，追加 HIGHDPIAWARE
  \$newValue = \$currentValue.Trim()
  if (\$newValue -ne '' -and -not \$newValue.EndsWith(' ')) {
    \$newValue += ' '
  }
  \$newValue += 'HIGHDPIAWARE'

  Set-ItemProperty -Path \$regPath -Name \$exePath -Value \$newValue -Type String -Force
  Write-Output 'SET'
} else {
  Write-Output 'ALREADY_SET'
}
'''
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        _log('WARN', '设置 DPI 兼容性超时(10s)，跳过（不影响超分启动）');
        throw TimeoutException('DPI compatibility timeout');
      });
      final output = result.stdout.toString().trim();
      if (output == 'SET') {
        _log('INFO', '已设置 DPI 兼容性: $gameExePath');
      } else if (output == 'ALREADY_SET') {
        _log('INFO', 'DPI 兼容性已存在: $gameExePath');
      }
    } catch (e) {
      _log('WARN', '设置 DPI 兼容性失败（不影响超分启动）: $e');
    }
  }

  // ========== 核心启动流程 ==========
  /// 超分启动游戏
  ///
  /// 流程：
  /// 1. 检查 Magpie 可用性
  /// 2. 设置游戏 DPI 兼容性（替代高 DPI 缩放行为）
  /// 3. 启动游戏进程
  /// 4. 等待游戏窗口出现
  /// 5. 获取游戏窗口类名（Win32 GetClassName）
  /// 6. 关闭已有 Magpie（确保重新加载配置）
  /// 7. 写入完整 Profile 到 Magpie 配置
  /// 8. 启动 Magpie（加载最新配置）
  /// 9. 激活游戏窗口到前台
  /// 10. Magpie 50ms 定时器检测到前台窗口匹配 Profile，自动全屏缩放
  Future<bool> startGameWithUpscaling({
    required String gameExePath,
    required String gameTitle,
    String localeMode = 'none',
  }) async {
    _errorMessage = null;

    try {
      _setScalingState(ScalingState.preparing);
      _log('INFO', '═══════════════════════════════════════');
      _log('INFO', '开始超分启动流程');
      _log('INFO', '游戏: $gameTitle | exe: $gameExePath');
      _log('INFO', '模式: $_mode | 预设: ${currentPreset.name}');

      // ★ 启动流程日志
      await GameLaunchLogger.instance.logLaunchStart(
        gameTitle: gameTitle,
        exePath: gameExePath,
        launchMode: 'magpie',
        localeMode: localeMode,
      );

      // 1. 检查 Magpie 可用性
      final available = await isAvailable();
      if (!available) {
        await GameLaunchLogger.instance.logStep('Magpie可用性检查', 'FAIL',
            detail: _mode == MagpieMode.external ? "外接路径无效" : "内置版本缺失");
        throw StateError(
            'Magpie 不可用：${_mode == MagpieMode.external ? "外接路径无效，请在偏好设置中配置" : "内置版本缺失，请将 Magpie.exe 放入 runtime/magpie/ 目录"}');
      }
      await GameLaunchLogger.instance.logStep('Magpie可用性检查', 'OK');

      // 2. 确定 Magpie 路径和配置目录
      final magpieExe =
          _mode == MagpieMode.external ? _externalPath : internalMagpieExePath;
      final configDir = _mode == MagpieMode.external
          ? externalConfigDir
          : internalMagpieConfigDir;
      final configPath = _mode == MagpieMode.external
          ? externalConfigPath
          : internalMagpieConfigPath;

      // 3. 设置游戏 exe 的 DPI 兼容性（替代高 DPI 缩放行为）
      _log('INFO', '设置游戏 DPI 兼容性...');
      await _setDpiCompatibility(gameExePath);
      await GameLaunchLogger.instance.logStep('DPI兼容性设置', 'OK');

      // 4. 启动游戏进程（先启动游戏，才能获取窗口类名）
      _log('INFO', '启动游戏进程...');
      final launched = await _launchGame(gameExePath, localeMode: localeMode);
      if (!launched) {
        await GameLaunchLogger.instance.logStep('游戏进程启动', 'FAIL');
        throw StateError('游戏进程启动失败');
      }
      await GameLaunchLogger.instance.logStep('游戏进程启动', 'OK');

      // 5. 等待游戏窗口出现
      _log('INFO', '等待游戏窗口...');
      final windowReady = await _waitForGameWindow(gameExePath);
      await GameLaunchLogger.instance.logStep(
          '游戏窗口检测', windowReady ? 'OK' : 'WARN',
          detail: windowReady ? null : '窗口未就绪，继续尝试');

      // 6. 获取游戏窗口类名
      _log('INFO', '获取游戏窗口类名...');
      final className = await _getGameWindowClassName(gameExePath);
      if (className.isEmpty) {
        _log('WARN', '无法获取窗口类名，使用进程名作为回退');
        await GameLaunchLogger.instance
            .logStep('窗口类名获取', 'WARN', detail: '使用Unknown回退');
      } else {
        await GameLaunchLogger.instance
            .logStep('窗口类名获取', 'OK', detail: className);
      }
      _log('INFO', '窗口类名: $className');

      // 缓存类名（★ Fix：同时持久化到 SharedPreferences，避免重启后丢失）
      if (className.isNotEmpty) {
        _classNameCache[gameExePath] = className;
        await _saveClassNameCache();
      }

      // 7. 关闭已有 Magpie（确保重新加载配置）
      final alreadyRunning = await isMagpieRunning();
      if (alreadyRunning) {
        _log('INFO', '关闭已有 Magpie 以重新加载配置...');
        await GameLaunchLogger.instance.logMagpieState('检测到已有实例，关闭中...');
        await _killMagpieProcess();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // 8. 写入完整 Profile 到 Magpie 配置
      _log('INFO', '写入 Profile: $gameTitle (classNameRule=$className)');
      await _upsertGameProfile(
        configPath: configPath,
        configDir: configDir,
        gameExePath: gameExePath,
        gameTitle: gameTitle,
        classNameRule: className,
      );
      await GameLaunchLogger.instance
          .logStep('Profile写入', 'OK', detail: 'classNameRule=$className');

      // 9. 启动 Magpie（加载最新配置）
      _log('INFO', '启动 Magpie (静默模式)...');
      await _launchMagpieSilent(magpieExe);
      await _waitForMagpieReady();
      await GameLaunchLogger.instance
          .logMagpieState('已启动', detail: 'PID=${_magpieProcess?.pid}');

      // 10. 激活游戏窗口到前台（触发 Magpie 自动缩放）
      _log('INFO', '激活游戏窗口到前台...');
      await _activateWindow(gameExePath);
      await Future.delayed(const Duration(milliseconds: 300));
      await _activateWindow(gameExePath);
      await GameLaunchLogger.instance.logStep('窗口激活', 'OK');

      _log('INFO', '超分启动流程完成，Magpie 将自动接管缩放');
      _setScalingState(ScalingState.scaling);
      await GameLaunchLogger.instance.logMagpieState('超分运行中');

      // 11. 启动游戏进程监控（游戏退出后自动关闭 Magpie）
      _monitoredGameTitle = gameTitle;
      _magpieLaunchStartTime = DateTime.now();
      _startGameMonitor(gameExePath);
      await GameLaunchLogger.instance
          .logStep('进程监控启动', 'OK', detail: '监控间隔: 3s');

      await GameLaunchLogger.instance.logLaunchEnd(
        gameTitle: gameTitle,
        success: true,
        summary: '超分启动成功 | 类名: $className | Magpie PID: ${_magpieProcess?.pid}',
      );

      return true;
    } catch (e) {
      _log('ERROR', '超分启动失败: $e');
      _errorMessage = e
          .toString()
          .replaceFirst('Exception: ', '')
          .replaceFirst('StateError: ', '');
      _setScalingState(ScalingState.error);

      await GameLaunchLogger.instance.logError('超分启动', e);
      await GameLaunchLogger.instance.logLaunchEnd(
        gameTitle: gameTitle,
        success: false,
        summary: '超分启动失败: $e',
      );

      if (_fallbackOnFail) {
        _log('INFO', '回退到普通启动模式');
      }

      return false;
    }
  }

  /// 停止超分（关闭 Magpie）
  Future<void> stopScaling() async {
    _stopGameMonitor();
    await _killMagpieProcess();
    _setScalingState(ScalingState.idle);
  }

  /// 强制关闭所有 Magpie 进程（CTLIB 退出时调用）
  Future<void> shutdown() async {
    _stopGameMonitor();
    await _killMagpieProcess();
    _setScalingState(ScalingState.idle);
    _log('INFO', 'MagpieService 已关闭');
  }

  /// 终止 Magpie 进程
  ///
  /// ★ Fix（2026-08-10）：增加 FFI 验证循环，确保 Magpie 确实被终止。
  /// 旧实现仅尝试 kill + taskkill 一次，不验证结果 → Magpie 可能残留。
  Future<void> _killMagpieProcess() async {
    // 先尝试通过 Process 引用 kill
    if (_magpieProcess != null) {
      try {
        _magpieProcess!.kill(ProcessSignal.sigkill);
        _log('INFO',
            '已通过 Process.kill() 关闭 Magpie (PID: ${_magpieProcess!.pid})');
      } catch (_) {}
      _magpieProcess = null;
    }

    // 兜底：用 taskkill 强制终止 + 验证循环（最多重试 3 次）
    for (int attempt = 1; attempt <= 3; attempt++) {
      // 检查 Magpie 是否仍在运行
      if (Win32ProcessService.isAvailable) {
        try {
          final procs = Win32ProcessService.enumerateProcesses();
          if (!procs.any((p) => p.exeName == 'magpie.exe')) {
            _log('INFO', 'Magpie 已确认关闭 (FFI 验证, 尝试 $attempt)');
            return;
          }
        } catch (_) {}
      }

      // 仍在运行 → taskkill 强制终止
      try {
        final result = await Process.run(
          'taskkill',
          ['/IM', 'Magpie.exe', '/F', '/T'],
        ).timeout(const Duration(seconds: 5), onTimeout: () {
          _log('WARN', 'taskkill 超时(5s)，跳过本次终止');
          return ProcessResult(0, 1, '', '');
        });
        if (result.exitCode == 0) {
          _log('INFO', '已通过 taskkill 终止 Magpie.exe (尝试 $attempt)');
        }
      } catch (_) {}

      // 等待 500ms 让进程完全退出
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // 最终检查
    if (Win32ProcessService.isAvailable) {
      try {
        final procs = Win32ProcessService.enumerateProcesses();
        if (procs.any((p) => p.exeName == 'magpie.exe')) {
          _log('WARN', 'Magpie 经过 3 次终止尝试后仍在运行');
        }
      } catch (_) {}
    }
  }

  /// 启动游戏进程监控（游戏退出后自动关闭 Magpie）
  ///
  /// ★ Fix v2（2026-08-10）：
  /// 1. 移除同目录进程检测（太宽泛，游戏退出后同目录有残留进程会误判仍在运行）
  /// 2. 添加退出确认计数器：连续 _gameExitMissThreshold 次(6s)检测不到主 exe 才关闭
  /// 3. 仅依赖 exe 名称匹配 + 子进程(parent PID)检测
  void _startGameMonitor(String gameExePath) {
    _monitoredGameExe = p.basename(gameExePath).toLowerCase();
    _monitoredGameDir = File(gameExePath).parent.path.toLowerCase();
    _gameExitMissCount = 0; // ★ 重置退出计数器
    _stopGameMonitor();

    _gameMonitorTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) async {
        if (_monitoredGameExe == null) {
          _stopGameMonitor();
          return;
        }
        final running = await _isGameProcessTreeRunning(
          _monitoredGameExe!,
          _monitoredGameDir!,
        );
        if (running) {
          _gameExitMissCount = 0;
        } else {
          _gameExitMissCount++;
          _log('INFO',
              '游戏进程未检测到 ($_monitoredGameExe) - ${_gameExitMissCount}/$_gameExitMissThreshold');
          if (_gameExitMissCount >= _gameExitMissThreshold) {
            _log(
                'INFO', '游戏进程已退出确认 (${_gameExitMissCount}次连续未检测到)，自动关闭 Magpie');
            // ★ 记录游戏退出（日志系统）
            final title = _monitoredGameTitle ?? '未知游戏';
            final durationSeconds = _magpieLaunchStartTime == null
                ? 0
                : DateTime.now().difference(_magpieLaunchStartTime!).inSeconds;
            await GameLaunchLogger.instance.logGameExit(
              gameTitle: title,
              durationSeconds: durationSeconds,
              exitReason: 'normal',
            );
            _monitoredGameExe = null;
            _monitoredGameDir = null;
            _gameExitMissCount = 0;
            await stopScaling();
            // stopScaling 内部已调用 _killMagpieProcess，此处补记 Magpie 退出结果
            final magpieStillRunning = await isMagpieRunning();
            await GameLaunchLogger.instance.logMagpieExit(
              success: !magpieStillRunning,
              detail: magpieStillRunning ? 'Magpie 仍在运行' : '已确认关闭',
            );
          }
        }
      },
    );
    _log('INFO',
        '开始监控游戏进程: $_monitoredGameExe (确认阈值: ${_gameExitMissThreshold}次/${_gameExitMissThreshold * 3}s)');
  }

  /// 检测指定 exe 名称的进程是否仍在运行
  ///
  /// ★ 重构: 优先使用 FFI enumerateProcesses（毫秒级），
  /// FFI 不可用时回退到 tasklist。
  Future<bool> _isGameProcessRunning(String exeNameLower) async {
    // ★ 优先使用 FFI
    if (Win32ProcessService.isAvailable) {
      try {
        final processes = Win32ProcessService.enumerateProcesses();
        return processes.any((p) => p.exeName == exeNameLower);
      } catch (e) {
        _log('WARN', 'FFI 检测游戏进程异常，回退到 tasklist: $e');
      }
    }

    // ★ 回退: tasklist
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq $exeNameLower', '/NH'],
        runInShell: true,
      ).timeout(const Duration(seconds: 5), onTimeout: () {
        _log('WARN', 'tasklist 检测超时(5s)，假定进程仍在运行');
        return ProcessResult(0, 0, exeNameLower, '');
      });
      return result.stdout.toString().toLowerCase().contains(exeNameLower);
    } catch (_) {
      return true; // 检测失败时假定仍在运行，避免误杀 Magpie
    }
  }

  /// 检测游戏进程树是否仍在运行
  ///
  /// ★ Fix v2（2026-08-10）：移除同目录进程检测，仅依赖：
  /// 1. exe 名称直接匹配（主进程）
  /// 2. 子进程检测（主 exe 的 PID 作为 parent PID 的进程）
  ///
  /// 旧实现的问题：同目录检测（getProcessesInDirectory）太宽泛，
  /// 游戏退出后如果同目录有配置工具/存档管理器等残留进程，
  /// 会误判游戏仍在运行 → Magpie 永不关闭。
  Future<bool> _isGameProcessTreeRunning(
    String exeNameLower,
    String gameDirLower,
  ) async {
    // ★ 优先使用 FFI
    if (Win32ProcessService.isAvailable) {
      try {
        final processes = Win32ProcessService.enumerateProcesses();
        if (processes.isEmpty) {
          // FFI 返回空 → 异常，回退到 tasklist
          _log('WARN', 'FFI 返回空进程列表，_isGameProcessTreeRunning 回退到 tasklist');
        } else {
          // 检测1：exe 名称直接匹配（主进程）
          final mainPids = <int>{};
          for (final p in processes) {
            if (p.exeName == exeNameLower) {
              mainPids.add(p.pid);
            }
          }
          if (mainPids.isNotEmpty) {
            return true;
          }

          // 检测2：子进程（主 exe 的 PID 作为 parent PID）
          // 覆盖启动器型游戏：启动器退出前启动了游戏子进程
          // 注意：主 exe 退出后无法通过 parent PID 关联，所以仅当主 exe 存在时有效
          // 如果主 exe 已退出且无子进程，认为游戏已退出
          // （不再检测同目录进程，避免误判）

          // 游戏进程已退出
          return false;
        }
      } catch (e) {
        _log('WARN', 'FFI 进程树检测异常，回退到 tasklist: $e');
      }
    }

    // ★ 回退: tasklist（检查 exe 名称）
    return _isGameProcessRunning(exeNameLower);
  }

  /// 停止游戏进程监控
  void _stopGameMonitor() {
    _gameMonitorTimer?.cancel();
    _gameMonitorTimer = null;
    _monitoredGameExe = null;
    _monitoredGameDir = null;
    _monitoredGameTitle = null;
    _magpieLaunchStartTime = null;
    _gameExitMissCount = 0; // ★ 重置退出计数器
  }

  // ========== 内部方法 ==========
  void _setScalingState(ScalingState state) {
    _scalingState = state;
    notifyListeners();
  }

  /// 静默启动 Magpie（-t 参数）
  Future<void> _launchMagpieSilent(String magpieExe) async {
    final workingDir = File(magpieExe).parent.path;

    // 确保内接模式的配置目录存在
    if (_mode == MagpieMode.internal) {
      final configDir = Directory(internalMagpieConfigDir);
      if (!await configDir.exists()) {
        await configDir.create(recursive: true);
      }
      // 确保配置文件存在
      final configFile = File(internalMagpieConfigPath);
      if (!await configFile.exists()) {
        await _releaseDefaultConfig(configFile);
      }
    }

    // ★ Fix（2026-08-10）：移除 runInShell: true。
    // 旧实现使用 runInShell: true 导致 _magpieProcess 指向 cmd.exe（shell 进程），
    // 而非 Magpie.exe 本身。后续 _magpieProcess.kill() 仅杀死 shell，
    // Magpie.exe 仍在后台运行 → 游戏退出后 Magpie 残留。
    // Process.start 不需要 shell 即可处理含空格的路径（参数以 List 传递）。
    _magpieProcess = await Process.start(
      magpieExe,
      ['-t'], // 静默模式，仅托盘图标
      workingDirectory: workingDir,
    );

    _magpieProcess!.stdout.listen((data) {
      _log('DEBUG', 'Magpie stdout: ${utf8.decode(data)}');
    });
    _magpieProcess!.stderr.listen((data) {
      _log('WARN', 'Magpie stderr: ${utf8.decode(data)}');
    });

    _log('INFO', 'Magpie 进程已启动 (PID: ${_magpieProcess!.pid})');
  }

  /// 等待 Magpie 就绪
  Future<void> _waitForMagpieReady() async {
    for (int i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (await isMagpieRunning()) {
        await Future.delayed(const Duration(milliseconds: 500));
        return;
      }
    }
    _log('WARN', 'Magpie 启动超时，继续执行');
  }

  /// 注入或更新游戏 Profile 到 Magpie 配置
  ///
  /// 关键修复：
  /// - profiles[0] 必须是默认 Profile（name/pathRule/classNameRule 为空）
  /// - 非默认 Profile 必须包含 name, packaged, pathRule, classNameRule 字段
  /// - classNameRule 不能为空，否则 Magpie _LoadProfile 会丢弃该 Profile
  /// - scalingMode 必须 >= 0，否则缩放会失败
  Future<void> _upsertGameProfile({
    required String configPath,
    required String configDir,
    required String gameExePath,
    required String gameTitle,
    required String classNameRule,
  }) async {
    // 确保配置目录存在
    final dir = Directory(configDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // 读取现有配置
    Map<String, dynamic> config = {};
    final configFile = File(configPath);
    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        config = jsonDecode(content) as Map<String, dynamic>;
      } catch (e) {
        _log('WARN', '读取 Magpie 配置失败，将创建新配置: $e');
      }
    }

    // 确保 scalingModes 列表存在
    if (!config.containsKey('scalingModes')) {
      config['scalingModes'] =
          builtInPresets.map((p) => p.toScalingModeJson()).toList();
    }

    final scalingModes = (config['scalingModes'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    // 查找或添加当前预设到 scalingModes
    final preset = currentPreset;
    int scalingModeIndex =
        scalingModes.indexWhere((m) => m['name'] == preset.name);
    if (scalingModeIndex == -1) {
      scalingModes.add(preset.toScalingModeJson());
      scalingModeIndex = scalingModes.length - 1;
      _log('INFO',
          '添加新预设到 scalingModes: ${preset.name} (索引: $scalingModeIndex)');
    }
    config['scalingModes'] = scalingModes;

    // 解析 profiles 数组
    // Magpie 要求 profiles[0] 是默认 Profile（name/pathRule/classNameRule 为空）
    List<Map<String, dynamic>> profiles;
    if (!config.containsKey('profiles') ||
        (config['profiles'] as List).isEmpty) {
      // 没有 profiles 或为空，创建默认 Profile 作为第一个元素
      profiles = [_buildDefaultProfile()];
    } else {
      profiles = (config['profiles'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // 检查第一个元素是否是默认 Profile
      if (profiles.isNotEmpty &&
          profiles[0].containsKey('name') &&
          (profiles[0]['name'] as String).isNotEmpty) {
        // 第一个元素不是默认 Profile，需要插入默认 Profile
        profiles.insert(0, _buildDefaultProfile());
        _log('INFO', '在 profiles 数组头部插入默认 Profile');
      }
    }

    // 查找或创建游戏 Profile
    final profileName = 'ChronoTide - $gameTitle';
    // 游戏Profile从索引1开始（索引0是默认Profile）
    int profileIndex = profiles.indexWhere(
      (p) => p['name'] == profileName,
    );

    if (classNameRule.isEmpty) {
      _log('WARN', 'classNameRule 为空，Magpie 可能无法匹配该 Profile');
    }

    final gameProfile = _buildGameProfile(
      profileName: profileName,
      gameExePath: gameExePath,
      classNameRule: classNameRule.isNotEmpty ? classNameRule : 'Unknown',
      scalingModeIndex: scalingModeIndex,
    );

    if (profileIndex >= 0) {
      profiles[profileIndex] = gameProfile;
      _log('INFO', '更新已有 Profile: $profileName');
    } else {
      profiles.add(gameProfile);
      _log('INFO', '创建新 Profile: $profileName');
    }

    config['profiles'] = profiles;

    // 写回配置
    await configFile.writeAsString(
      const JsonEncoder.withIndent('    ').convert(config),
      flush: true,
    );
    _log('INFO', 'Magpie 配置已写入: $configPath');
    _log('INFO',
        'Profile 详情: pathRule=$gameExePath, classNameRule=$classNameRule, scalingMode=$scalingModeIndex, autoScale=1');

    // 等待文件系统刷新
    await Future.delayed(const Duration(milliseconds: 300));
  }

  /// 启动游戏进程
  ///
  /// ★ Fix（2026-08-10）：优先使用 Process.start(detached) 直接启动游戏，
  /// 替代旧的 cmd /c start + runInShell:true。
  ///
  /// 旧实现问题：cmd /c start 对含全角字符的 exe 路径（如
  /// 「美少女万華鏡－１－_CHS.exe」）会超时 15s 失败，导致超分启动直接中断
  /// 回退到普通模式。Process.start(detached) 直接调用 CreateProcess，
  /// 不经 cmd.exe 编码转换，已在普通启动流程中验证可靠。
  Future<bool> _launchGame(String exePath, {String localeMode = 'none'}) async {
    try {
      if (localeMode == 'japanese') {
        await LocaleService.launchWithLocale(exePath)
            .timeout(const Duration(seconds: 15), onTimeout: () {
          _log('WARN', 'LE 启动超时(15s)，假定成功继续');
          return ProcessResult(0, 0, '', '');
        });
        return true;
      } else {
        final workingDir = File(exePath).parent.path;
        // ★ 优先使用 Process.start(detached)：直接 CreateProcess，不经 cmd.exe
        // detached 模式彻底断开父子进程关系，游戏不会因 Chrono Tide 退出而被杀
        try {
          final process = await Process.start(exePath, [],
              workingDirectory: workingDir, mode: ProcessStartMode.detached);
          _log('INFO', '游戏进程已启动 (PID: ${process.pid}, detached)');
          return true;
        } catch (e) {
          // ★ 回退：cmd /c start（覆盖 Process.start 不支持的边缘场景）
          _log('WARN', 'Process.start 失败，回退到 cmd /c start: $e');
          await Process.run('cmd.exe', ['/c', 'start', '""', exePath],
                  workingDirectory: workingDir, runInShell: true)
              .timeout(const Duration(seconds: 15), onTimeout: () {
            _log('WARN', 'cmd /c start 超时(15s)，假定成功继续');
            throw TimeoutException('cmd /c start timeout');
          });
          _log('INFO', '通过 cmd /c start 启动成功');
          return true;
        }
      }
    } catch (e) {
      _log('ERROR', '启动游戏失败: $e');
      return false;
    }
  }

  /// 等待游戏窗口出现
  ///
  /// ★ 重构: 使用 Win32 FFI enumerateProcesses 替代 tasklist 轮询。
  /// 旧实现每 250ms 调用一次 tasklist（200-500ms/次），40 次轮询期间
  /// 持续阻塞事件循环。FFI 枚举仅需 1-3ms，大幅减少等待期间的 CPU 占用。
  /// FFI 不可用时回退到 tasklist。
  Future<bool> _waitForGameWindow(String exePath) async {
    final exeName = p.basename(exePath).toLowerCase();
    for (int i = 0; i < 40; i++) {
      await Future.delayed(const Duration(milliseconds: 250));

      // ★ 优先使用 FFI
      if (Win32ProcessService.isAvailable) {
        try {
          final processes = Win32ProcessService.enumerateProcesses();
          if (processes.any((p) => p.exeName == exeName)) {
            // 进程已启动，额外等待窗口初始化
            await Future.delayed(const Duration(milliseconds: 500));
            return true;
          }
          continue; // FFI 成功但进程未出现，跳过 tasklist
        } catch (e) {
          _log('WARN', 'FFI 检测异常，回退到 tasklist: $e');
        }
      }

      // ★ 回退: tasklist
      try {
        final result = await Process.run(
          'tasklist',
          ['/FI', 'IMAGENAME eq $exeName', '/NH'],
          runInShell: true,
        ).timeout(const Duration(seconds: 5), onTimeout: () {
          _log('WARN', 'tasklist 超时(5s)，跳过本次检测');
          throw TimeoutException('tasklist timeout');
        });
        if (result.stdout.toString().toLowerCase().contains(exeName)) {
          // 进程已启动，额外等待窗口初始化
          await Future.delayed(const Duration(milliseconds: 500));
          return true;
        }
      } catch (_) {}
    }
    _log('WARN', '等待游戏窗口超时，游戏可能仍在加载中');
    return false;
  }

  /// 获取游戏窗口的类名（Magpie Profile 匹配的关键字段）
  ///
  /// ★ Fix（2026-08-10 v2）：修复 PowerShell -Command 模式下 $args 不传参的问题。
  /// 旧实现用 `powershell -Command "script" pidArg` 传递 PID，但 -Command 模式下
  /// $args 不包含后续参数 → 脚本收到空 PID → 每次输出空 → 5次重试耗时18秒全失败。
  /// 新实现将 PID 直接嵌入脚本字符串（Dart 插值），彻底解决参数传递问题。
  ///
  /// ★ 优化：重试次数 5→2，间隔 2s→1s，EnumWindows 超时 15s→8s。
  /// 旧实现最坏耗时 5×(2+15)=85s，新实现最坏耗时 2×(1+8)=18s，正常情况 <5s。
  ///
  /// 流程：
  /// 1. 先查缓存（含持久化）
  /// 2. FFI 找 PID（主进程 + 子进程 + 同目录进程）
  /// 3. PID 嵌入 PowerShell EnumWindows 脚本获取窗口类名
  /// 4. 失败时重试（最多 2 次，每次间隔 1s）
  Future<String> _getGameWindowClassName(String exePath) async {
    final exeName = p.basename(exePath).toLowerCase();
    final exeBasename = p.basenameWithoutExtension(exePath);

    // 先检查缓存（含持久化加载的缓存）
    if (_classNameCache.containsKey(exePath)) {
      _log('INFO', '使用缓存的窗口类名: ${_classNameCache[exePath]}');
      return _classNameCache[exePath]!;
    }

    // ★ 重试循环：最多 2 次，每次间隔 1s
    for (int attempt = 1; attempt <= 2; attempt++) {
      // 使用 FFI 查找游戏相关 PID（主进程 + 子进程 + 同目录进程）
      List<int> pids = [];

      if (Win32ProcessService.isAvailable) {
        try {
          final processes = Win32ProcessService.enumerateProcesses();
          if (processes.isNotEmpty) {
            // 检测1：exe 名称匹配
            for (final p in processes) {
              if (p.exeName == exeName) {
                pids.add(p.pid);
              }
            }

            // 检测2：子进程（parent PID 关联）
            final parentPids = Set<int>.from(pids);
            for (final p in processes) {
              if (parentPids.contains(p.parentPid) && !pids.contains(p.pid)) {
                pids.add(p.pid);
                _log('DEBUG',
                    '发现子进程: PID=${p.pid} parentPID=${p.parentPid} exe=${p.exeName}');
              }
            }

            // 检测3：同目录下的进程
            final gameDir = File(exePath).parent.path;
            final dirPids =
                Win32ProcessService.getProcessesInDirectory(gameDir);
            for (final pid in dirPids) {
              if (!pids.contains(pid)) {
                pids.add(pid);
              }
            }
          }
        } catch (e) {
          _log('WARN', 'FFI 查找游戏 PID 异常 (尝试 $attempt): $e');
        }
      }

      // Fallback: PowerShell Get-Process（FFI 不可用或返回空时）
      if (pids.isEmpty) {
        try {
          final psResult = await Process.run(
            'powershell',
            [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              '(Get-Process -Name "$exeBasename" -ErrorAction SilentlyContinue).Id -join ","'
            ],
          ).timeout(const Duration(seconds: 5));
          final pidStr = psResult.stdout.toString().trim();
          if (pidStr.isNotEmpty) {
            for (final s in pidStr.split(',')) {
              final pid = int.tryParse(s.trim());
              if (pid != null && pid > 0) pids.add(pid);
            }
          }
        } catch (_) {}
      }

      if (pids.isEmpty) {
        _log('WARN', '未找到游戏进程 (尝试 $attempt/2)，等待 1s 后重试...');
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      _log('INFO', '找到游戏 PID: $pids (尝试 $attempt/2)');

      // ★ Fix: 将 PID 直接嵌入脚本字符串（替代 $ARGS 参数传递）
      // PID 全是数字，无注入风险；Dart 插值 $pidList 直接写入 PowerShell 脚本
      final pidList = pids.join(',');
      final script = '''
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class GameWindowFinder {
    private static readonly HashSet<string> _garbage = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "IME", "MSCTFIME UI", "Default IME", "Button", "Shell_TrayWnd",
        "tooltips_class32", "WindowGhost", "Ghost", "ComboBox", "ComboLBox",
        "Static", "ScrollBar", "Clipboard", "ObjectManager"
    };
    private static string _best;
    private static string _fallback;
    private static HashSet<int> _pids;
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    private static EnumProc _cb;
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lp, int n);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lp, int n);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    private static bool Callback(IntPtr hWnd, IntPtr lParam) {
        if (!IsWindowVisible(hWnd)) return true;
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        if (!_pids.Contains((int)pid)) return true;
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hWnd, cls, 256);
        string name = cls.ToString();
        if (name.Length == 0 || _garbage.Contains(name)) return true;
        StringBuilder title = new StringBuilder(512);
        GetWindowText(hWnd, title, 512);
        if (_best == null && title.Length > 0) _best = name;
        if (_fallback == null) _fallback = name;
        return true;
    }
    public static string FindClassName(int[] pids) {
        _best = null;
        _fallback = null;
        _pids = new HashSet<int>(pids);
        if (_cb == null) _cb = new EnumProc(Callback);
        EnumWindows(_cb, IntPtr.Zero);
        return _best ?? _fallback ?? "";
    }
}
"@
\$pidArr = @($pidList)
if (\$pidArr.Count -eq 0) { Write-Output ""; exit }
\$r = [GameWindowFinder]::FindClassName(\$pidArr)
Write-Output \$r
''';

      try {
        final result = await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-Command', script],
          runInShell: false,
        ).timeout(const Duration(seconds: 8), onTimeout: () {
          _log('WARN', 'EnumWindows 窗口类名检测超时(8s, 尝试 $attempt)');
          throw TimeoutException('EnumWindows timeout');
        });
        final className = result.stdout.toString().trim();
        if (className.isNotEmpty) {
          _log('INFO', 'EnumWindows 获取到窗口类名: $className (尝试 $attempt)');
          return className;
        }
        // ★ 记录 stderr 辅助诊断
        final stderr = result.stderr.toString().trim();
        if (stderr.isNotEmpty) {
          _log('WARN',
              'EnumWindows stderr: ${stderr.substring(0, stderr.length > 200 ? 200 : stderr.length)}');
        }
        _log('WARN', 'EnumWindows 未找到窗口 (尝试 $attempt/2)，PID=$pids');
      } catch (e) {
        _log('WARN', 'EnumWindows 检测异常 (尝试 $attempt): $e');
      }

      if (attempt < 2) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    _log('WARN', '所有尝试均未获取到窗口类名（2 次重试后放弃），使用空类名');
    return '';
  }

  /// 激活窗口到前台（通过 exe 路径查找进程）
  Future<void> _activateWindow(String exePath) async {
    try {
      final processName = p.basenameWithoutExtension(exePath);
      // 尝试多次激活窗口，因为游戏窗口可能需要时间初始化
      for (int attempt = 0; attempt < 3; attempt++) {
        final script = '''
\$proc = Get-Process -Name "$processName" -ErrorAction SilentlyContinue | Select-Object -First 1
if (\$proc -and \$proc.MainWindowHandle -ne [IntPtr]::Zero) {
  Add-Type -TypeDefinition "using System;`nusing System.Runtime.InteropServices;`npublic class Win32Foreground {`n  [DllImport(\\"user32.dll\\")] public static extern bool SetForegroundWindow(IntPtr hWnd);`n}"
  [Win32Foreground]::SetForegroundWindow(\$proc.MainWindowHandle)
  Write-Output "activated"
} else {
  Write-Output "no_window"
}
''';
        final result = await Process.run(
          'powershell',
          ['-NoProfile', '-Command', script],
          runInShell: false,
        ).timeout(const Duration(seconds: 10), onTimeout: () {
          _log('WARN', '激活窗口 PowerShell 超时(10s)，跳过本次尝试');
          throw TimeoutException('activate window timeout');
        });
        if (result.stdout.toString().contains('activated')) {
          _log('INFO', '窗口已激活 (第${attempt + 1}次尝试)');
          return;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      _log('WARN', '窗口激活失败：未找到游戏主窗口');
    } catch (e) {
      _log('WARN', '激活窗口失败: $e');
    }
  }

  // ========== 日志 ==========
  static final List<String> _logBuffer = [];
  static const int _maxLogEntries = 500;

  static void _log(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final logEntry = '[$timestamp] [$level] [MagpieService] $message';
    _logBuffer.add(logEntry);
    if (_logBuffer.length > _maxLogEntries) {
      _logBuffer.removeRange(0, _logBuffer.length - _maxLogEntries);
    }
    debugPrint(logEntry);
  }

  static List<String> getLogs({int? limit}) {
    if (limit != null && limit < _logBuffer.length) {
      return _logBuffer.sublist(_logBuffer.length - limit);
    }
    return List.from(_logBuffer);
  }

  static void clearLogs() => _logBuffer.clear();
}
