// LaunchResult 数据类单元测试
//
// 验证 LaunchResult 的工厂构造正确性。
// GameLaunchService.executeLaunch 深度依赖 File/SharedPreferences/
// LocalGameRegistry/MagpieService,完整 mock 成本高,改为依赖类型签名测试 + 手动验收。

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/game_launch_service.dart';

void main() {
  group('LaunchResult', () {
    test('success factory sets success=true and defaults modes to none', () {
      const result = LaunchResult.success();

      expect(result.success, isTrue);
      expect(result.error, isNull);
      expect(result.localeMode, 'none');
      expect(result.upscalingMode, 'none');
    });

    test('success factory preserves locale and upscaling modes', () {
      const result = LaunchResult.success(
        localeMode: 'japanese',
        upscalingMode: 'magpie',
      );

      expect(result.success, isTrue);
      expect(result.localeMode, 'japanese');
      expect(result.upscalingMode, 'magpie');
    });

    test('failure factory sets success=false and error message', () {
      final result = LaunchResult.failure('无法启动游戏');

      expect(result.success, isFalse);
      expect(result.error, '无法启动游戏');
      expect(result.localeMode, 'none');
      expect(result.upscalingMode, 'none');
    });

    test('default constructor allows custom all fields', () {
      const result = LaunchResult(
        success: false,
        error: '超分启动失败',
        localeMode: 'japanese',
        upscalingMode: 'magpie',
      );

      expect(result.success, isFalse);
      expect(result.error, '超分启动失败');
      expect(result.localeMode, 'japanese');
      expect(result.upscalingMode, 'magpie');
    });

    test('GameLaunchService is a singleton', () {
      expect(GameLaunchService.instance, same(GameLaunchService.instance));
    });
  });
}
