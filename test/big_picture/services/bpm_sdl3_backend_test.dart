import 'dart:io';

import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';
import 'package:chrono_tide/big_picture/services/bpm_sdl3_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// SDL3 后端单测。
///
/// 🔴 映射/换算逻辑全部走纯函数（不触碰真实 SDL3.dll），
///    因此这些用例在任何环境都能跑，与「是否插着手柄」无关。
///    涉及真实设备的验证（按键实测/热插拔）走 `dev_probe/sdl3_probe.dart live`。
void main() {
  group('位置化按键 → XInput 位掩码（跨厂商归一的核心）', () {
    test('Xbox 面键命名与 PS 面键命名映射到同一个语义位', () {
      // SDL3 位置化: SOUTH=下、EAST=右、WEST=左、NORTH=上
      // Xbox:        A(下) B(右) X(左) Y(上)
      // PlayStation: ×(下) ○(右) □(左) △(上)
      // ⇒ 两类手柄按「下面的键」都报 SOUTH → 都映射到 XInputButtons.a
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonSouth),
        XInputButtons.a,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonEast),
        XInputButtons.b,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonWest),
        XInputButtons.x,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonNorth),
        XInputButtons.y,
      );
    });

    test('功能键映射', () {
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonStart),
        XInputButtons.start,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonBack),
        XInputButtons.back,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonLeftShoulder),
        XInputButtons.leftShoulder,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonRightShoulder),
        XInputButtons.rightShoulder,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonDpadUp),
        XInputButtons.dpadUp,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonDpadDown),
        XInputButtons.dpadDown,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonDpadLeft),
        XInputButtons.dpadLeft,
      );
      expect(
        Sdl3Backend.sdlButtonToXInput(Sdl3.buttonDpadRight),
        XInputButtons.dpadRight,
      );
    });

    test('未映射键返回 0（GUIDE/摇杆键/摇杆下压/触摸板等无 XInput 语义）', () {
      expect(Sdl3Backend.sdlButtonToXInput(Sdl3.buttonGuide), 0);
      expect(Sdl3Backend.sdlButtonToXInput(Sdl3.buttonLeftStick), 0);
      expect(Sdl3Backend.sdlButtonToXInput(Sdl3.buttonRightStick), 0);
      // SDL3 还有 MISC1=15、摇杆板等 15..20
      for (var b = 15; b <= 20; b++) {
        expect(Sdl3Backend.sdlButtonToXInput(b), 0, reason: 'SDL 按键 $b');
      }
    });

    test('composeButtonsMask：按位组合，跨厂商等价', () {
      int makeMask(int down) => Sdl3Backend.composeButtonsMask((b) => b == down);

      expect(makeMask(Sdl3.buttonSouth), XInputButtons.a);
      expect(
        Sdl3Backend
            .composeButtonsMask((b) => b == Sdl3.buttonSouth || b == Sdl3.buttonEast),
        XInputButtons.a | XInputButtons.b,
      );
      expect(
        Sdl3Backend.composeButtonsMask((b) => b == Sdl3.buttonGuide),
        0,
        reason: '未映射键不产生任何位',
      );
      expect(Sdl3Backend.composeButtonsMask((b) => false), 0);
    });
  });

  group('扳机归一量 → 0..255', () {
    test('边界值', () {
      expect(Sdl3Backend.triggerToByte(0), 0);
      expect(Sdl3Backend.triggerToByte(Sdl3.axisMax), 255);
    });

    test('负值（SDL 摇杆轴可能为负）被钳到 0，不产生溢出', () {
      expect(Sdl3Backend.triggerToByte(-32768), 0);
      expect(Sdl3Backend.triggerToByte(-1), 0);
    });

    test('单调递增', () {
      var prev = -1;
      for (var v = 0; v <= Sdl3.axisMax; v += 1024) {
        final b = Sdl3Backend.triggerToByte(v);
        expect(b, greaterThanOrEqualTo(prev));
        prev = b;
      }
      // 循环步进 1024 未必恰好落在满幅值上，满幅由「边界值」用例单独锁定
      expect(Sdl3Backend.triggerToByte(Sdl3.axisMax), 255);
      expect(prev, lessThanOrEqualTo(255));
    });

    test('低于 BPM 服务阈值 128 的折算值与阈值语义一致', () {
      // BpmGamepadService.triggerThreshold = 128：
      // 折算后 >= 128 视为按下 ⇒ SDL 原始值约需 >= 16448（半程）
      const half = Sdl3.axisMax ~/ 2;
      expect(Sdl3Backend.triggerToByte(half), lessThan(128));
      final over = (Sdl3.axisMax * 0.51).round();
      expect(Sdl3Backend.triggerToByte(over), greaterThanOrEqualTo(128));
    });
  });

  group('摇杆 Y 轴取反（v3.10.2 同款方向 bug 的防线）', () {
    test('SDL「上推 = 负值」→ 我们约定「上 = 正」', () {
      expect(Sdl3Backend.stickY(-32767), 32767, reason: '上推应为正');
      expect(Sdl3Backend.stickY(0), 0);
      expect(Sdl3Backend.stickY(32767), -32767, reason: '下拉应为负');
    });

    test('X 轴不取反（SDL 右 = 正，与我们一致）', () {
      // 该约定由 sdlButton/轴常量与文档锁定；此处防呆：轴常量不被误改
      expect(Sdl3.axisLeftX, 0);
      expect(Sdl3.axisLeftY, 1);
      expect(Sdl3.axisRightX, 2);
      expect(Sdl3.axisRightY, 3);
      expect(Sdl3.axisLeftTrigger, 4);
      expect(Sdl3.axisRightTrigger, 5);
    });
  });

  group('sourceKey（换设备 → 重建基线）', () {
    test('格式稳定且随 instanceId 变化', () {
      expect(Sdl3Backend.sourceKeyFor(7), 'sdl3#7');
      expect(Sdl3Backend.sourceKeyFor(42), 'sdl3#42');
      expect(Sdl3Backend.sourceKeyFor(7), isNot(Sdl3Backend.sourceKeyFor(8)));
    });

    test('与 XInput 后端的 sourceKey 命名空间不冲突', () {
      // bpm_gamepad_service.dart 的 XInputBackend.sourceKey = 'slot<n>'
      expect(Sdl3Backend.sourceKeyFor(0), isNot('slot0'));
    });
  });

  group('tryCreate 静默降级', () {
    test('DLL 路径不存在 → 返回 null（不抛异常）', () {
      expect(
        Sdl3Backend.tryCreate(dllPath: r'C:\__不存在的路径__\SDL3.dll'),
        isNull,
      );
    });

    test('非 SDL 的合法 DLL → 符号解析失败 → 返回 null 且不再重试', () {
      // 用系统自带的 user32.dll 冒充：能加载但缺 SDL 符号
      final r = Sdl3Backend.tryCreate(dllPath: r'C:\Windows\System32\user32.dll');
      expect(r, isNull);
      // 永不重试语义：第二次调用（哪怕路径正确）也直接 null
      expect(
        Sdl3Backend.tryCreate(dllPath: r'D:\CTLIB\windows\runner\sdl3\SDL3.dll'),
        isNull,
        reason: '符号解析失败后 _lookupFailed 置位，本进程内不再尝试',
      );
    }, skip: !Platform.isWindows ? '仅 Windows' : null);
  });
}
