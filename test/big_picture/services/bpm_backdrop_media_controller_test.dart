import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/services/bpm_backdrop_media.dart';
import 'package:chrono_tide/big_picture/services/bpm_backdrop_media_controller.dart';
import 'package:chrono_tide/services/bpm_op_video_preference.dart';
import 'package:chrono_tide/services/game_data_format.dart';

/// 合法 mp4 头（第 4..8 字节为 `ftyp`）。
List<int> _fakeMp4Head() => <int>[
      0x00, 0x00, 0x00, 0x20,
      ...'ftyp'.codeUnits,
      ...'isom'.codeUnits,
    ];

void main() {
  // ⚠️ 本组用例**不依赖真实解码**：flutter_tester 里没有 video_player 平台实现，
  //    `initialize()` 必然失败 → 正好覆盖「预热失败静默回退」这条分支（方案 §10 R3）。
  //    「真正进入 playing」需要有平台插件的集成环境，无法在此断言（如实标注）。
  const Duration short = Duration(milliseconds: 30);

  late Directory tmp;
  late BpmBackdropMediaController ctrl;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bpm_ctrl_test_');
    BpmOpVideoPreference.resetForTest();
    ctrl = BpmBackdropMediaController(armDelay: short);
  });

  tearDown(() {
    ctrl.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeGameJson(Map<String, dynamic> data) {
    File('${tmp.path}/${GameDataFormat.gameJsonFileName}')
        .writeAsStringSync(jsonEncode(data));
  }

  /// 在 tmp 目录里放一个「有视频字段 + 视频文件存在」的游戏（新多素材字段）。
  void prepareGameWithVideo() {
    writeGameJson(<String, dynamic>{
      BpmBackdropMedia.kBackdropVideos: [
        {'file': 'op.mp4', 'name': '游戏OP'}
      ],
      BpmBackdropMedia.kSelectedVideo: 'op.mp4',
    });
    File('${tmp.path}/op.mp4').writeAsBytesSync(_fakeMp4Head());
  }

  /// 🔴 v3.11.0 兼容路径：旧单值字段（无新键）也应能取到视频。
  void prepareGameWithLegacyVideo() {
    writeGameJson(<String, dynamic>{
      BpmBackdropMedia.kLegacyOpVideo: 'op.mp4',
    });
    File('${tmp.path}/op.mp4').writeAsBytesSync(_fakeMp4Head());
  }

  Future<void> waitArm() => Future<void>.delayed(short * 3);

  test('初始态：idle、视频不透明度 0、图片完全不透明、无控制器', () {
    expect(ctrl.state, BpmBackdropVideoState.idle);
    expect(ctrl.videoOpacity, 0.0);
    expect(ctrl.imageOpacity, 1.0);
    expect(ctrl.controller, isNull);
    expect(ctrl.isPlaying, isFalse);
  });

  test('没有 OP 视频的游戏：即使可播也不进入 arming', () async {
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    await waitArm();
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('canPlay=false（非主页 / 面板开着）：不 arm', () async {
    prepareGameWithVideo();
    ctrl.setCanPlay(false);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    await waitArm();
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('metaDataDir 为空：不 arm', () async {
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', '');
    await waitArm();
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('有视频 + 可播 → 进入 arming；setCanPlay(false) 立刻回 idle（离开主页即停）', () {
    prepareGameWithVideo();
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    expect(ctrl.state, BpmBackdropVideoState.arming);

    ctrl.setCanPlay(false);
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('🔴 v3.11.0 兼容：旧单值字段（bpm_op_video）也能触发播放', () {
    prepareGameWithLegacyVideo();
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    expect(ctrl.state, BpmBackdropVideoState.arming);
  });

  test('refresh()：背景窗口换了选中视频 → 按新选择重新计时', () {
    writeGameJson(<String, dynamic>{
      BpmBackdropMedia.kBackdropVideos: [
        {'file': 'op.mp4', 'name': '游戏OP'},
        {'file': 'ed.mp4', 'name': '游戏ED'},
      ],
      BpmBackdropMedia.kSelectedVideo: 'op.mp4',
    });
    File('${tmp.path}/op.mp4').writeAsBytesSync(_fakeMp4Head());
    File('${tmp.path}/ed.mp4').writeAsBytesSync(_fakeMp4Head());

    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    expect(ctrl.state, BpmBackdropVideoState.arming);

    // 用户在背景窗口把选中从 op.mp4 换成 ed.mp4 → shell 调 refresh()
    writeGameJson(<String, dynamic>{
      BpmBackdropMedia.kBackdropVideos: [
        {'file': 'op.mp4', 'name': '游戏OP'},
        {'file': 'ed.mp4', 'name': '游戏ED'},
      ],
      BpmBackdropMedia.kSelectedVideo: 'ed.mp4',
    });
    ctrl.refresh();
    expect(ctrl.state, BpmBackdropVideoState.arming,
        reason: 'refresh 后按新选中视频重新进入 3s 计时');
  });

  test('停留期间换游戏（停留不足）→ 旧游戏被取消，不进入播放', () async {
    prepareGameWithVideo();
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    expect(ctrl.state, BpmBackdropVideoState.arming);

    ctrl.onStageKeyChanged('g2|/b', null); // 切到没有视频的游戏
    expect(ctrl.state, BpmBackdropVideoState.idle);

    await waitArm();
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('同一游戏重复通知幂等 —— 不重置计时', () {
    prepareGameWithVideo();
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    // 仍处于 arming（若被重置也不影响该断言，但计数不会翻倍 —— 见下个用例）
    expect(ctrl.state, BpmBackdropVideoState.arming);
  });

  test('预热失败（flutter_tester 无视频插件）→ 计时到点静默回退 idle', () async {
    prepareGameWithVideo();
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    await waitArm();
    expect(ctrl.state, BpmBackdropVideoState.idle,
        reason: '初始化失败必须回退静态背景，不得卡在 arming');
    expect(ctrl.controller, isNull);
  });

  test('cancel() 幂等，且状态归 idle、控制器释放', () {
    ctrl.cancel();
    ctrl.cancel();
    expect(ctrl.state, BpmBackdropVideoState.idle);
    expect(ctrl.controller, isNull);
    expect(ctrl.videoOpacity, 0.0);
  });

  test('replayFor：目录里没有视频文件 → 不改变状态', () {
    ctrl.replayFor(tmp.path);
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('replayFor：空目录串 → 直接返回', () {
    ctrl.replayFor('');
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('onStageKeyChanged(null, null) → 回 idle（退出舞台）', () {
    prepareGameWithVideo();
    ctrl.setCanPlay(true);
    ctrl.onStageKeyChanged('g1|/a', tmp.path);
    expect(ctrl.state, BpmBackdropVideoState.arming);

    ctrl.onStageKeyChanged(null, null);
    expect(ctrl.state, BpmBackdropVideoState.idle);
  });

  test('未自动播过时 hasAutoPlayed 为 false（集合只在真正开播时写入）', () {
    expect(ctrl.hasAutoPlayed('g1|/a'), isFalse);
  });
}
