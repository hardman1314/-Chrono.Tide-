import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';
import 'package:chrono_tide/services/gamepad/gamepad_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2 数据模型单测：枚举映射、容错解析、预设内容、生效配置解析。
void main() {
  group('GamepadSource ↔ JSON 标识', () {
    test('14 个源全部可往返', () {
      for (final s in GamepadSource.values) {
        expect(GamepadSource.fromJsonId(s.jsonId), s, reason: s.jsonId);
      }
      expect(GamepadSource.values.length, 18); // 14 按键 + LS/RS + 双摇杆源
    });

    test('未知标识 → null（不抛错）', () {
      expect(GamepadSource.fromJsonId('button.turbo'), isNull);
      expect(GamepadSource.fromJsonId(''), isNull);
    });

    test('后端原始按键 → 配置源（扳机记作 button.lt/rt）', () {
      expect(GamepadSource.fromRawButton(GamepadRawButton.a),
          GamepadSource.a);
      expect(GamepadSource.fromRawButton(GamepadRawButton.leftShoulder),
          GamepadSource.lb);
      expect(GamepadSource.fromRawButton(GamepadRawButton.rightShoulder),
          GamepadSource.rb);
      expect(GamepadSource.fromRawButton(GamepadRawButton.leftTrigger),
          GamepadSource.lt);
      expect(GamepadSource.fromRawButton(GamepadRawButton.rightTrigger),
          GamepadSource.rt);
      expect(GamepadSource.fromRawButton(GamepadRawButton.dpadUp),
          GamepadSource.dpadUp);
      // 14 个原始按键全部有映射（与配置源一一对应）
      for (final b in GamepadRawButton.values) {
        expect(GamepadSource.fromRawButton(b), isNotNull, reason: b.name);
      }
    });
  });

  group('GamepadAction 容错解析', () {
    test('key：合法 vk 解析成功', () {
      final a = GamepadAction.fromJson({'type': 'key', 'vk': 13});
      expect(a?.type, GamepadActionType.key);
      expect(a?.vk, 13);
    });

    test('key：vk 越界/缺失/非整数 → null', () {
      expect(GamepadAction.fromJson({'type': 'key', 'vk': 0}), isNull);
      expect(GamepadAction.fromJson({'type': 'key', 'vk': 999}), isNull);
      expect(GamepadAction.fromJson({'type': 'key', 'vk': '13'}), isNull);
      expect(GamepadAction.fromJson({'type': 'key'}), isNull);
    });

    test('mouse_button：仅接受 left/right', () {
      expect(GamepadAction.fromJson({'type': 'mouse_button', 'button': 'left'})
          ?.mouseButtonName, 'left');
      expect(
          GamepadAction.fromJson({'type': 'mouse_button', 'button': 'middle'}),
          isNull);
    });

    test('mouse_move：缺省灵敏度/死区', () {
      final a = GamepadAction.fromJson({'type': 'mouse_move'});
      expect(a?.sensitivity, 1.0);
      expect(a?.deadzone, 0.15);
    });

    test('未知 type → null', () {
      expect(GamepadAction.fromJson({'type': 'macro'}), isNull);
      expect(GamepadAction.fromJson({}), isNull);
    });

    test('toJson 往返', () {
      const action = GamepadAction.key(13);
      final back = GamepadAction.fromJson(action.toJson());
      expect(back?.type, GamepadActionType.key);
      expect(back?.vk, 13);
    });
  });

  group('GamepadMapping 容错解析', () {
    test('合法映射解析', () {
      final m = GamepadMapping.fromJson({
        'source': 'button.rb',
        'action': {'type': 'key', 'vk': 17},
        'mode': 'hold',
      });
      expect(m?.source, GamepadSource.rb);
      expect(m?.mode, GamepadMappingMode.hold);
      expect(m?.action.vk, 17);
    });

    test('mode 缺省为 tap', () {
      final m = GamepadMapping.fromJson({
        'source': 'button.a',
        'action': {'type': 'key', 'vk': 13},
      });
      expect(m?.mode, GamepadMappingMode.tap);
    });

    test('未知 source / action / mode 的处理', () {
      expect(
        GamepadMapping.fromJson({
          'source': 'button.turbo',
          'action': {'type': 'key', 'vk': 13},
        }),
        isNull,
      );
      expect(
        GamepadMapping.fromJson({
          'source': 'button.a',
          'action': {'type': 'key', 'vk': 13},
          'mode': 'turbo',
        })?.mode,
        GamepadMappingMode.tap,
        reason: '未知 mode 回落 tap',
      );
    });

    test('toJson 往返', () {
      const m = GamepadMapping(
        source: GamepadSource.rb,
        action: GamepadAction.key(17),
        mode: GamepadMappingMode.hold,
      );
      final back = GamepadMapping.fromJson(m.toJson());
      expect(back?.source, GamepadSource.rb);
      expect(back?.mode, GamepadMappingMode.hold);
      expect(back?.action.vk, 17);
    });
  });

  group('GamepadProfileFile（落盘根对象）', () {
    test('fromJson：profiles 解析、非法条目跳过', () {
      final f = GamepadProfileFile.fromJson({
        'format_version': 1,
        'profiles': {
          'game-1': {
            'game_title': '命运石之门',
            'preset': 'generic_vn',
            'enabled': true,
            'mappings': [
              {
                'source': 'button.a',
                'action': {'type': 'key', 'vk': 13},
                'mode': 'tap',
              },
              {'garbage': true},
              {
                'source': 'button.b',
                'action': {'type': 'key', 'vk': 999999},
              },
            ],
          },
          'bad-key': 'not-a-map',
        },
      });
      expect(f.profiles.length, 1, reason: '非法条目被跳过');
      expect(f.profiles['game-1']?.gameTitle, '命运石之门');
      expect(f.profiles['game-1']?.mappings.length, 1, reason: '非法映射被丢弃');
    });

    test('effectiveFor：专属配置优先', () {
      const own = GamepadProfile(
          enabled: true,
          mappings: [GamepadMapping(source: GamepadSource.a, action: GamepadAction.key(65))]);
      final f = GamepadProfileFile(
        profiles: {'game-1': own},
        defaults: const GamepadProfile(preset: 'generic_vn'),
      );
      expect(f.effectiveFor('game-1').mappings.single.action.vk, 65);
    });

    test('effectiveFor：无专属 → 默认 + 预设展开', () {
      final f = GamepadProfileFile(
        defaults: const GamepadProfile(preset: 'generic_vn'),
      );
      final effective = f.effectiveFor('unknown-game');
      expect(effective.preset, 'generic_vn');
      expect(effective.mappings.length, GamepadPresets.genericVn.length);
    });

    test('effectiveFor：专属 enabled=false 原样返回（不回落默认）', () {
      const disabled = GamepadProfile(enabled: false);
      final f = GamepadProfileFile(
        profiles: {'game-1': disabled},
        defaults: const GamepadProfile(preset: 'generic_vn'),
      );
      expect(f.effectiveFor('game-1').enabled, isFalse);
    });

    test('toJson 往返（含 profiles 键与 defaults）', () {
      final f = GamepadProfileFile(
        profiles: {
          'game-1': const GamepadProfile(
            gameTitle: '白色相簿2',
            preset: 'generic_vn',
            mappings: [
              GamepadMapping(
                  source: GamepadSource.a,
                  action: GamepadAction.key(13),
                  mode: GamepadMappingMode.tap),
            ],
          ),
        },
        defaults: const GamepadProfile(preset: 'generic_vn'),
        updatedAt: '2026-09-26T16:00:00Z',
      );
      final back = GamepadProfileFile.fromJson(f.toJson());
      expect(back.profiles['game-1']?.gameTitle, '白色相簿2');
      expect(back.profiles['game-1']?.mappings.single.source, GamepadSource.a);
      expect(back.defaults.preset, 'generic_vn');
      expect(back.updatedAt, '2026-09-26T16:00:00Z');
    });
  });

  group('内置预设 generic_vn', () {
    test('A=Enter(tap) B=Esc(tap) RB=Ctrl(hold)', () {
      GamepadMapping find(GamepadSource s) =>
          GamepadPresets.genericVn.firstWhere((m) => m.source == s);

      expect(find(GamepadSource.a).action.vk, 13, reason: 'Enter');
      expect(find(GamepadSource.a).mode, GamepadMappingMode.tap);
      expect(find(GamepadSource.b).action.vk, 27, reason: 'Esc');
      expect(find(GamepadSource.rb).action.vk, 17, reason: 'Ctrl');
      expect(find(GamepadSource.rb).mode, GamepadMappingMode.hold,
          reason: '按住快进必须是 hold 语义');
    });

    test('RT/LT = 鼠标左/右键（覆盖 WA2 这类纯鼠标标题菜单）', () {
      GamepadMapping find(GamepadSource s) =>
          GamepadPresets.genericVn.firstWhere((m) => m.source == s);
      expect(find(GamepadSource.rt).action.type, GamepadActionType.mouseButton);
      expect(find(GamepadSource.rt).action.mouseButtonName, 'left');
      expect(find(GamepadSource.lt).action.mouseButtonName, 'right');
    });

    test('十字键 = 方向键', () {
      GamepadMapping find(GamepadSource s) =>
          GamepadPresets.genericVn.firstWhere((m) => m.source == s);
      expect(find(GamepadSource.dpadUp).action.vk, 38);
      expect(find(GamepadSource.dpadDown).action.vk, 40);
      expect(find(GamepadSource.dpadLeft).action.vk, 37);
      expect(find(GamepadSource.dpadRight).action.vk, 39);
    });

    test('byId：未知预设 → null', () {
      expect(GamepadPresets.byId('steamos_vn'), isNotNull);
      expect(GamepadPresets.byId('generic_vn'), isNotNull);
      expect(GamepadPresets.byId('unknown'), isNull);
      expect(GamepadPresets.byId(null), isNull);
    });

    test('steamos_vn（用户拍板默认）：A=左键按住(拖拽) LT=Ctrl按住 LS=Enter RS=F', () {
      GamepadMapping find(GamepadSource s) =>
          GamepadPresets.steamosVn.firstWhere((m) => m.source == s);
      expect(find(GamepadSource.a).action.type, GamepadActionType.mouseButton);
      expect(find(GamepadSource.a).action.mouseButtonName, 'left');
      expect(find(GamepadSource.a).mode, GamepadMappingMode.hold,
          reason: '按住 A + 摇杆 = 拖拽');
      expect(find(GamepadSource.b).action.mouseButtonName, 'right');
      expect(find(GamepadSource.lt).action.vk, 17);
      expect(find(GamepadSource.lt).mode, GamepadMappingMode.hold,
          reason: '快进必须是按住语义');
      expect(find(GamepadSource.ls).action.vk, 13);
      expect(find(GamepadSource.rs).action.vk, 0x46);
      expect(find(GamepadSource.start).action.vk, 27);
      expect(find(GamepadSource.back).action.vk, 0x50);
      expect(find(GamepadSource.x).action.vk, 0x48);
      expect(find(GamepadSource.y).action.vk, 0x53);
      expect(find(GamepadSource.lb).action.vk, 0x4C);
      expect(find(GamepadSource.rb).action.vk, 0x41);
      expect(find(GamepadSource.stickLeft).action.type,
          GamepadActionType.mouseMove);
      expect(find(GamepadSource.stickRight).action.type,
          GamepadActionType.mouseWheel);
      expect(find(GamepadSource.dpadUp).action.direction, 'up');
      expect(find(GamepadSource.dpadRight).action.stepPixels, 24);
    });

    test('mouse_move 方向/步长 容错解析与往返', () {
      final a = GamepadAction.fromJson({
        'type': 'mouse_move',
        'direction': 'up',
        'step_pixels': 32,
      });
      expect(a?.direction, 'up');
      expect(a?.stepPixels, 32);
      // 非法方向 → 丢弃（回落连续移动）
      expect(GamepadAction.fromJson({
        'type': 'mouse_move',
        'direction': 'diagonal',
      })?.direction, isNull);
    });

    test('prompted 标记往返（首启询问只问一次）', () {
      const p = GamepadProfile(enabled: true, prompted: true);
      final back = GamepadProfile.fromJson(const {
        'enabled': true,
        'prompted': true,
      });
      expect(back.prompted, isTrue);
      expect(p.prompted, isTrue);
      // 缺省 = false（未询问）
      expect(GamepadProfile.fromJson(const {}).prompted, isFalse);
    });

    test('预设内无重复源', () {
      final sources = GamepadPresets.genericVn.map((m) => m.source).toSet();
      expect(sources.length, GamepadPresets.genericVn.length);
    });
  });
}
