/// 游戏手柄适配 —— 每游戏映射数据模型（Phase 2）
///
/// 落盘 schema 见 `docs/DEV/features/gamepad_adaptation_implementation_plan.md` §5.2：
/// 独立文件 `data/gamepad_profiles.json`，**不触碰 game.json** ⇒ 不触发
/// `format_version` 迁移（`game_data_format.dart` 当前为 3）⇒ 零 schema 回归面。
///
/// 设计要点（均为已批准决策）：
/// - **键用 ADR-011 的稳定主键 `game_id`**（UUID v4，一经生成禁止改写），
///   不用 `directoryPath` —— 后者会被「游戏目录真迁移」改变，导致配置失联；
/// - **mode 三种语义**：`tap`（按一下）/ `hold`（手柄按住=键盘按住，galgame 的
///   Ctrl 快进是按住语义）/ `repeat`（连发，380/130ms 节奏）；
/// - **读容错**：JSON 里任何非法枚举值/未知字段 → 丢弃该条（绝不抛错），
///   解析失败整体降级为内置预设（由 store 层负责）；
/// - `mouse_move` / `mouse_wheel` 的 schema 本期就位（用户可手配），但
///   会话层 Phase 2 暂不执行（Phase 4 实现摇杆模拟鼠标），分发时记 skipped。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../big_picture/services/bpm_gamepad_service.dart'
    show GamepadRawButton;

/// 手柄输入源（与具体后端无关的稳定标识，落盘用 `jsonId`）
enum GamepadSource {
  a('button.a'),
  b('button.b'),
  x('button.x'),
  y('button.y'),
  lb('button.lb'),
  rb('button.rb'),
  lt('button.lt'),
  rt('button.rt'),
  start('button.start'),
  back('button.back'),
  ls('button.ls'),
  rs('button.rs'),
  stickLeft('stick.left'),
  stickRight('stick.right'),
  dpadUp('dpad.up'),
  dpadDown('dpad.down'),
  dpadLeft('dpad.left'),
  dpadRight('dpad.right');

  const GamepadSource(this.jsonId);

  /// 落盘/展示用标识
  final String jsonId;

  static GamepadSource? fromJsonId(String id) => _byId[id];

  static final Map<String, GamepadSource> _byId = {
    for (final s in values) s.jsonId: s,
  };

  /// 后端原始按键 → 配置源（扳机按方案 §5.3 记作 `button.lt` / `button.rt`）
  static GamepadSource? fromRawButton(GamepadRawButton b) => switch (b) {
        GamepadRawButton.a => GamepadSource.a,
        GamepadRawButton.b => GamepadSource.b,
        GamepadRawButton.x => GamepadSource.x,
        GamepadRawButton.y => GamepadSource.y,
        GamepadRawButton.leftShoulder => GamepadSource.lb,
        GamepadRawButton.rightShoulder => GamepadSource.rb,
        GamepadRawButton.leftTrigger => GamepadSource.lt,
        GamepadRawButton.rightTrigger => GamepadSource.rt,
        GamepadRawButton.start => GamepadSource.start,
        GamepadRawButton.back => GamepadSource.back,
        GamepadRawButton.leftStick => GamepadSource.ls,
        GamepadRawButton.rightStick => GamepadSource.rs,
        GamepadRawButton.dpadUp => GamepadSource.dpadUp,
        GamepadRawButton.dpadDown => GamepadSource.dpadDown,
        GamepadRawButton.dpadLeft => GamepadSource.dpadLeft,
        GamepadRawButton.dpadRight => GamepadSource.dpadRight,
      };
}

/// 映射的触发语义
enum GamepadMappingMode {
  tap('tap'),
  hold('hold'),
  repeat('repeat');

  const GamepadMappingMode(this.jsonId);
  final String jsonId;

  static GamepadMappingMode? fromJsonId(String id) => _byId[id];

  static final Map<String, GamepadMappingMode> _byId = {
    for (final m in values) m.jsonId: m,
  };
}

/// 注入动作类型
enum GamepadActionType {
  key('key'),
  mouseButton('mouse_button'),
  mouseMove('mouse_move'),
  mouseWheel('mouse_wheel');

  const GamepadActionType(this.jsonId);
  final String jsonId;

  static GamepadActionType? fromJsonId(String id) => _byId[id];

  static final Map<String, GamepadActionType> _byId = {
    for (final t in values) t.jsonId: t,
  };
}

/// 一个输入动作（按 [type] 只有一组字段有效，其余为 null）
class GamepadAction {
  const GamepadAction.key(int this.vk)
      : type = GamepadActionType.key,
        mouseButtonName = null,
        direction = null,
        stepPixels = null,
        sensitivity = null,
        deadzone = null;

  const GamepadAction.mouseButton(String this.mouseButtonName)
      : type = GamepadActionType.mouseButton,
        vk = null,
        direction = null,
        stepPixels = null,
        sensitivity = null,
        deadzone = null;

  /// 连续移动（摇杆）：[direction] 为 null；
  /// 步进移动（十字键）：[direction] = up/down/left/right，[stepPixels] 为每按一次的像素数。
  const GamepadAction.mouseMove({
    this.sensitivity = 1.0,
    this.deadzone = 0.15,
    this.direction,
    this.stepPixels = 24,
  })  : type = GamepadActionType.mouseMove,
        vk = null,
        mouseButtonName = null;

  const GamepadAction.mouseWheel()
      : type = GamepadActionType.mouseWheel,
        vk = null,
        direction = null,
        stepPixels = null,
        mouseButtonName = null,
        sensitivity = null,
        deadzone = null;

  final GamepadActionType type;

  /// `key`：Win32 虚拟键码
  final int? vk;

  /// `mouse_button`：`left` / `right`
  final String? mouseButtonName;

  /// `mouse_move`：灵敏度倍率（Phase 4 消费）
  final double? sensitivity;

  /// `mouse_move`：死区比例 0..1（摇杆连续移动消费）
  final double? deadzone;

  /// `mouse_move`：步进方向（十字键光标步进用；null = 摇杆连续移动）
  final String? direction;

  /// `mouse_move`：步进像素数（十字键每次按下的位移）
  final int? stepPixels;

  static GamepadAction? fromJson(Map<dynamic, dynamic> j) {
    final type = GamepadActionType.fromJsonId(j['type'] as String? ?? '');
    if (type == null) return null;
    switch (type) {
      case GamepadActionType.key:
        final vk = j['vk'];
        if (vk is! int || vk <= 0 || vk > 255) return null;
        return GamepadAction.key(vk);
      case GamepadActionType.mouseButton:
        final name = j['button'];
        if (name is! String || (name != 'left' && name != 'right')) {
          return null;
        }
        return GamepadAction.mouseButton(name);
      case GamepadActionType.mouseMove:
        final sd = j['sensitivity'];
        final d = j['deadzone'];
        final dir = j['direction'];
        final step = j['step_pixels'];
        return GamepadAction.mouseMove(
          sensitivity: sd is num ? sd.toDouble() : 1.0,
          deadzone: d is num ? d.toDouble().clamp(0.0, 1.0) : 0.15,
          direction:
              (dir == 'up' || dir == 'down' || dir == 'left' || dir == 'right')
                  ? dir
                  : null,
          stepPixels: step is int && step > 0 ? step : 24,
        );
      case GamepadActionType.mouseWheel:
        return const GamepadAction.mouseWheel();
    }
  }

  Map<String, dynamic> toJson() => switch (type) {
        GamepadActionType.key => {'type': type.jsonId, 'vk': vk},
        GamepadActionType.mouseButton => {
            'type': type.jsonId,
            'button': mouseButtonName,
          },
        GamepadActionType.mouseMove => {
            'type': type.jsonId,
            'sensitivity': sensitivity,
            'deadzone': deadzone,
            if (direction != null) 'direction': direction,
            if (direction != null) 'step_pixels': stepPixels,
          },
        GamepadActionType.mouseWheel => {'type': type.jsonId},
      };
}

/// 一条映射：手柄输入源 → 动作 + 触发语义
class GamepadMapping {
  const GamepadMapping({
    required this.source,
    required this.action,
    this.mode = GamepadMappingMode.tap,
  });

  final GamepadSource source;
  final GamepadAction action;
  final GamepadMappingMode mode;

  static GamepadMapping? fromJson(Map<dynamic, dynamic> j) {
    final source = GamepadSource.fromJsonId(j['source'] as String? ?? '');
    if (source == null) return null;
    final actionRaw = j['action'];
    if (actionRaw is! Map) return null;
    final action = GamepadAction.fromJson(actionRaw);
    if (action == null) return null;
    final mode = GamepadMappingMode.fromJsonId(j['mode'] as String? ?? '') ??
        GamepadMappingMode.tap;
    return GamepadMapping(source: source, action: action, mode: mode);
  }

  Map<String, dynamic> toJson() => {
        'source': source.jsonId,
        'action': action.toJson(),
        'mode': mode.jsonId,
      };
}

/// 单个游戏（或全局默认）的生效配置
class GamepadProfile {
  const GamepadProfile({
    this.gameTitle,
    this.preset,
    this.enabled = true,
    this.prompted = false,
    this.mappings = const [],
  });

  /// 仅用于 UI 显示与调试
  final String? gameTitle;

  /// 命中的内置预设名（可为 null）
  final String? preset;

  /// false = 该游戏禁用手柄适配（会话层直接不启动）
  final bool enabled;

  /// 首次启动询问是否已做过（true = 不再弹询问框）
  final bool prompted;

  final List<GamepadMapping> mappings;

  static GamepadProfile fromJson(Map<dynamic, dynamic> j) {
    final enabled = j['enabled'];
    final prompted = j['prompted'];
    final mappingsRaw = j['mappings'];
    return GamepadProfile(
      gameTitle: j['game_title'] is String ? j['game_title'] as String : null,
      preset: j['preset'] is String ? j['preset'] as String : null,
      enabled: enabled is bool ? enabled : true,
      prompted: prompted is bool ? prompted : false,
      mappings: mappingsRaw is List
          ? mappingsRaw
              .whereType<Map>()
              .map(GamepadMapping.fromJson)
              .whereType<GamepadMapping>()
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        if (gameTitle != null) 'game_title': gameTitle,
        if (preset != null) 'preset': preset,
        'enabled': enabled,
        'prompted': prompted,
        'mappings': mappings.map((m) => m.toJson()).toList(),
      };

  GamepadProfile copyWith({
    String? gameTitle,
    String? preset,
    bool? enabled,
    bool? prompted,
    List<GamepadMapping>? mappings,
  }) =>
      GamepadProfile(
        gameTitle: gameTitle ?? this.gameTitle,
        preset: preset ?? this.preset,
        enabled: enabled ?? this.enabled,
        prompted: prompted ?? this.prompted,
        mappings: mappings ?? this.mappings,
      );
}

/// 内置预设（galgame 通用映射）
abstract final class GamepadPresets {
  /// SteamOS 通用方案（2026-09-27 用户拍板，复刻 Steam Input 社区 VN 通用映射）：
  /// 摇杆=光标移动 / A·RT=左键(A 可按住拖拽) / B=右键 / X=H 历史 / Y=S 快存 /
  /// LB=L 快读 / RB=A 自动播放 / LT=按住 Ctrl 快进 / LS=Enter / RS=F 全屏 /
  /// Start=Esc / View=P / 十字键=光标步进。
  static const String steamosVnId = 'steamos_vn';

  static const List<GamepadMapping> steamosVn = [
    GamepadMapping(
        source: GamepadSource.a,
        action: GamepadAction.mouseButton('left'),
        mode: GamepadMappingMode.hold), // 按住可拖拽
    GamepadMapping(
        source: GamepadSource.b,
        action: GamepadAction.mouseButton('right'),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.x,
        action: GamepadAction.key(0x48), // H 历史
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.y,
        action: GamepadAction.key(0x53), // S 快存
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.lb,
        action: GamepadAction.key(0x4C), // L 快读
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.rb,
        action: GamepadAction.key(0x41), // A 自动播放
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.lt,
        action: GamepadAction.key(17), // Ctrl 按住快进
        mode: GamepadMappingMode.hold),
    GamepadMapping(
        source: GamepadSource.rt,
        action: GamepadAction.mouseButton('left'),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.ls,
        action: GamepadAction.key(13), // Enter
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.rs,
        action: GamepadAction.key(0x46), // F 全屏
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.start,
        action: GamepadAction.key(27), // Esc
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.back,
        action: GamepadAction.key(0x50), // P
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.stickLeft,
        action: GamepadAction.mouseMove(sensitivity: 1.0, deadzone: 0.15),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.stickRight,
        action: GamepadAction.mouseWheel(),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadUp,
        action: GamepadAction.mouseMove(direction: 'up', stepPixels: 24),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadDown,
        action: GamepadAction.mouseMove(direction: 'down', stepPixels: 24),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadLeft,
        action: GamepadAction.mouseMove(direction: 'left', stepPixels: 24),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadRight,
        action: GamepadAction.mouseMove(direction: 'right', stepPixels: 24),
        mode: GamepadMappingMode.tap),
  ];

  /// galgame 通用预设：A 推进 / B 取消 / X 空格 / RB 按住 Ctrl 快进 /
  /// RT 鼠标左键（点纯鼠标 UI 的标题菜单）/ LT 鼠标右键 / 十字键 = 方向键
  static const String genericVnId = 'generic_vn';

  static const List<GamepadMapping> genericVn = [
    GamepadMapping(
        source: GamepadSource.a,
        action: GamepadAction.key(13), // VK_RETURN
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.b,
        action: GamepadAction.key(27), // VK_ESCAPE
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.x,
        action: GamepadAction.key(32), // VK_SPACE
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.rb,
        action: GamepadAction.key(17), // VK_CONTROL
        mode: GamepadMappingMode.hold), // 按住快进
    GamepadMapping(
        source: GamepadSource.rt,
        action: GamepadAction.mouseButton('left'),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.lt,
        action: GamepadAction.mouseButton('right'),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadUp,
        action: GamepadAction.key(38),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadDown,
        action: GamepadAction.key(40),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadLeft,
        action: GamepadAction.key(37),
        mode: GamepadMappingMode.tap),
    GamepadMapping(
        source: GamepadSource.dpadRight,
        action: GamepadAction.key(39),
        mode: GamepadMappingMode.tap),
  ];

  static List<GamepadMapping>? byId(String? id) =>
      id == steamosVnId
          ? steamosVn
          : id == genericVnId
              ? genericVn
              : null;
}

/// 自定义预设（2026-09-27 用户拍板：类似游戏手柄预设系统，用户自调配
/// 一套映射命名保存、可复用到任意游戏；区别于内置 steamos_vn/generic_vn）
class GamepadCustomPreset {
  const GamepadCustomPreset({
    required this.id,
    required this.name,
    required this.mappings,
  });

  /// 稳定 id（ISO 时间戳 + 微秒随机后缀，生成时定）
  final String id;

  /// 用户可读名
  final String name;

  final List<GamepadMapping> mappings;

  static GamepadCustomPreset? fromJson(Map<dynamic, dynamic> j) {
    final id = j['id'];
    final name = j['name'];
    final mappingsRaw = j['mappings'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    if (mappingsRaw is! List) return null;
    final mappings = mappingsRaw
        .whereType<Map>()
        .map(GamepadMapping.fromJson)
        .whereType<GamepadMapping>()
        .toList();
    if (mappings.isEmpty) return null;
    return GamepadCustomPreset(id: id, name: name, mappings: mappings);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mappings': mappings.map((m) => m.toJson()).toList(),
      };
}

/// 整份落盘文件的内存模型（根对象）
class GamepadProfileFile {
  GamepadProfileFile({
    Map<String, GamepadProfile>? profiles,
    GamepadProfile? defaults,
    Map<String, GamepadCustomPreset>? customPresets,
    this.updatedAt,
  })  : profiles = profiles ?? <String, GamepadProfile>{},
        defaults =
            defaults ?? const GamepadProfile(preset: GamepadPresets.steamosVnId),
        customPresets = customPresets ?? <String, GamepadCustomPreset>{};

  static const int formatVersion = 1;

  /// 🔴 键 = ADR-011 稳定主键 game_id（UUID v4）
  final Map<String, GamepadProfile> profiles;

  /// 全局默认（无专属配置的游戏用它）
  final GamepadProfile defaults;

  /// 自定义预设表（键 = preset id）。纯增量字段：旧文件读出为空表即兼容，
  /// 不需要 format_version 迁移（读端对未知字段本就容错）。
  final Map<String, GamepadCustomPreset> customPresets;

  final String? updatedAt;

  /// 取某游戏的生效配置：专属配置优先；无专属 → 全局默认（展开预设映射，
  /// 🔴 含自定义预设）。专属配置 enabled=false 时**原样返回**
  /// （会话层据此不启动），不回落默认。
  GamepadProfile effectiveFor(String gameId) {
    final own = profiles[gameId];
    if (own != null) return own;
    final presetMappings = mappingsFor(defaults.preset) ?? const [];
    return defaults.mappings.isEmpty
        ? defaults.copyWith(mappings: presetMappings)
        : defaults;
  }

  static GamepadProfileFile fromJson(Map<dynamic, dynamic> j) {
    final profilesRaw = j['profiles'];
    final defaultsRaw = j['defaults'];
    final profiles = <String, GamepadProfile>{};
    if (profilesRaw is Map) {
      profilesRaw.forEach((key, value) {
        if (key is String && value is Map) {
          final profile = GamepadProfile.fromJson(value);
          profiles[key] = profile;
        }
      });
    }
    GamepadProfile? defaults;
    if (defaultsRaw is Map) defaults = GamepadProfile.fromJson(defaultsRaw);
    final customRaw = j['custom_presets'];
    final customPresets = <String, GamepadCustomPreset>{};
    if (customRaw is Map) {
      customRaw.forEach((key, value) {
        if (key is String && value is Map) {
          final preset = GamepadCustomPreset.fromJson(value);
          if (preset != null) customPresets[key] = preset;
        }
      });
    }
    return GamepadProfileFile(
      profiles: profiles,
      defaults: defaults,
      customPresets: customPresets,
      updatedAt: j['updated_at'] is String ? j['updated_at'] as String : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'format_version': formatVersion,
        'updated_at': updatedAt,
        'defaults': defaults.toJson(),
        'profiles': profiles.map((k, v) => MapEntry(k, v.toJson())),
        'custom_presets':
            customPresets.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// 写回自身（updatedAt 由 store 层盖时间戳）
  GamepadProfileFile copyWith({
    Map<String, GamepadProfile>? profiles,
    GamepadProfile? defaults,
    Map<String, GamepadCustomPreset>? customPresets,
    String? updatedAt,
  }) =>
      GamepadProfileFile(
        profiles: profiles ?? this.profiles,
        defaults: defaults ?? this.defaults,
        customPresets: customPresets ?? this.customPresets,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 按 id 取映射列表：内置预设 > 自定义预设；都没有返回 null
  List<GamepadMapping>? mappingsFor(String? presetId) {
    if (presetId == null) return null;
    final custom = customPresets[presetId];
    if (custom != null) return custom.mappings;
    return GamepadPresets.byId(presetId);
  }
}

/// 诊断辅助：预设是否覆盖某源（Phase 3 编辑器用）
@visibleForTesting
bool presetCoversSource(List<GamepadMapping> mappings, GamepadSource s) =>
    mappings.any((m) => m.source == s);
