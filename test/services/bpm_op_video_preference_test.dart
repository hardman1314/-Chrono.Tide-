import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/bpm_op_video_preference.dart';

void main() {
  setUp(() => BpmOpVideoPreference.resetForTest());

  test('默认值：静音 + 每次选中都自动播', () {
    final p = BpmOpVideoPreference.instance;
    expect(p.soundEnabled, isFalse, reason: '默认静音（用户拍板）');
    expect(p.autoplayAlways, isTrue, reason: '默认每次选中都播（用户拍板）');
    // v3.18 语义变更：全局开关只是「新游戏的默认出声状态」，不再压音量 ——
    // 出声与否由每游戏开关（详情页）决定，volume 恒为 audibleVolume。
    expect(p.volume, closeTo(BpmOpVideoPreference.audibleVolume, 0.0001),
        reason: '音量与全局开关解耦');
    expect(p.loaded, isFalse);
  });

  test('出声音量恒为 audibleVolume（0.35，不盖过环境音）', () {
    final p = BpmOpVideoPreference.instance
      ..seedForTest(soundEnabled: true);
    expect(p.soundEnabled, isTrue);
    expect(p.volume, closeTo(0.35, 0.0001));
  });

  test('关闭「每次选中都播」', () {
    final p = BpmOpVideoPreference.instance
      ..seedForTest(autoplayAlways: false);
    expect(p.autoplayAlways, isFalse);
  });

  test('setSoundEnabled 写入相同值时不发通知', () async {
    final p = BpmOpVideoPreference.instance
      ..seedForTest(soundEnabled: false);
    int notified = 0;
    p.addListener(() => notified++);

    await p.setSoundEnabled(false);

    expect(notified, 0, reason: '值未变化 → 不打扰监听者');
  });

  test('setAutoplayAlways 改变值会通知一次', () async {
    final p = BpmOpVideoPreference.instance
      ..seedForTest(autoplayAlways: true);
    int notified = 0;
    p.addListener(() => notified++);

    await p.setAutoplayAlways(false);

    expect(notified, 1);
    expect(p.autoplayAlways, isFalse);
  });

  test('seedForTest 会置 loaded 并通知', () {
    final p = BpmOpVideoPreference.instance;
    int notified = 0;
    p.addListener(() => notified++);
    p.seedForTest();
    expect(p.loaded, isTrue);
    expect(notified, 1);
  });
}
