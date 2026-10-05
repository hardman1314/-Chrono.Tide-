import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../services/bpm_op_video_preference.dart';
import '../../services/local_game_registry.dart';
import 'bpm_backdrop_media.dart';

/// 背景视频状态机的状态。
enum BpmBackdropVideoState {
  /// 无视频（静态背景）。
  idle,

  /// 已选中、正在 3s 计时（同时预热播放器）。
  arming,

  /// 正在播放。
  playing,

  /// 播放结束、正在淡出（播放器仍持有，淡出完成后释放）。
  fadingOut,
}

/// BPM 主页背景 OP 视频的状态机（**不含任何 UI**，便于单测）。
///
/// 交互契约（用户 2026-09-26 拍板，方案 §4.2）：
/// 1. 底部栏选中的游戏**停留 3 秒** → 封面淡出、视频在 UI 背后播放；
/// 2. 视频**完整播放至结束**（不循环），结束后淡出恢复原背景；
/// 3. 播放中**切换游戏 / 离开主页 / 打开详情面板 / 退出大屏** → 立即停播并释放；
/// 4. 停留不足 3 秒就切走 → **完全不播**（预热的控制器也一并丢弃）；
/// 5. 音频默认静音（[BpmOpVideoPreference]），重播默认每次选中都播。
///
/// 🔴 竞态防护（关键，勿删）：`initialize()` 是异步的，3 秒计时期间用户可能
/// 已切换 N 次游戏。每次启动流程都携带递增的 [_generation]，异步回调落地时
/// 校验世代号，不匹配则**立即 dispose 并丢弃**，绝不 `play()`。
class BpmBackdropMediaController extends ChangeNotifier {
  /// 允许注入播放器工厂（单测用假实现，不依赖真实解码）。
  BpmBackdropMediaController({
    VideoPlayerController Function(File file)? playerFactory,
    Duration armDelay = defaultArmDelay,
  })  : _playerFactory = playerFactory,
        _armDelay = armDelay;

  final VideoPlayerController Function(File file)? _playerFactory;

  /// 选中后延迟多久开始播放（**生产值 3 秒**，与需求一致；单测注入短时长）。
  static const Duration defaultArmDelay = Duration(seconds: 3);
  final Duration _armDelay;

  /// 淡入 / 淡出时长（与 BPM 既有 200ms 级过渡同量级）。
  static const Duration fadeDuration = Duration(milliseconds: 240);

  BpmBackdropVideoState _state = BpmBackdropVideoState.idle;
  BpmBackdropVideoState get state => _state;

  VideoPlayerController? _controller;
  VideoPlayerController? get controller => _controller;

  /// 每游戏静音覆盖（v3.14，二级详情「声音」按钮）：
  /// true = 当前视频音量 0；null = 跟随全局偏好（[BpmOpVideoPreference]）。
  bool? _gameMuted;

  /// 实际生效音量 = 全局偏好 × 每游戏静音覆盖。
  /// 实际播放音量。
  ///
  /// 🔴 v3.18：**只由每游戏开关决定**（`_gameMuted`）—— 出声时用固定的
  /// [BpmOpVideoPreference.audibleVolume]。设置页全局开关只提供「该游戏没
  /// 单独设置过时的默认值」，不得再把音量压成 0（旧实现 `pref.volume` 在
  /// 全局关闭时恒为 0，等于屏蔽了详情页开关）。
  double _effectiveVolume() =>
      _gameMuted == true ? 0.0 : BpmOpVideoPreference.audibleVolume;

  /// shell 在换游戏 / 用户切换声音开关时调用；对**当前正在播放**的视频即时生效。
  void applyGameMuted(bool muted) {
    if (_gameMuted == muted) return;
    _gameMuted = muted;
    _controller?.setVolume(_effectiveVolume());
  }

  /// 视频层目标不透明度（由 `AnimatedOpacity` 平滑到该值）。
  double get videoOpacity =>
      _state == BpmBackdropVideoState.playing ? 1.0 : 0.0;

  /// 图片层目标不透明度（与视频层交叉：视频播放时封面淡出）。
  double get imageOpacity => 1.0 - videoOpacity;

  /// 是否正在播放（供 backdrop 选择「播放态遮罩」）。
  bool get isPlaying => _state == BpmBackdropVideoState.playing;

  /// 当前舞台游戏键（title|directoryPath，与 shell 的比对口径一致）。
  String? _currentKey;
  String? _currentMetaDataDir;

  /// 是否允许播放（主页 + 面板未打开 + BPM 可见）。
  bool _canPlay = false;

  int _generation = 0;
  Timer? _armTimer;
  Timer? _disposeTimer;

  /// 「每次进入大屏只自动播一次」模式下，本会话已自动播过的游戏键。
  final Set<String> _playedThisSession = <String>{};

  /// 舞台游戏变化（主页 shelf 选中 / 焦点移动 / 点击）。
  ///
  /// 同一游戏重复调用是幂等的 —— 不会重置 3 秒计时（重要：`build` 里
  /// 反复调用不会导致视频永远不触发）。
  void onStageGameChanged(LibraryGame? game) {
    onStageKeyChanged(
      game == null ? null : '${game.title}|${game.directoryPath}',
      game?.metaDataDir,
    );
  }

  /// 测试友好入口：直接给「游戏键 + 元数据目录」。
  ///
  /// 单测无需构造完整的 [LibraryGame]（它有数十个字段）；
  /// 生产路径统一经 [onStageGameChanged] 调用本方法。
  @visibleForTesting
  void onStageKeyChanged(String? key, String? metaDataDir) {
    if (key == _currentKey) return;

    _currentKey = key;
    _currentMetaDataDir = metaDataDir;
    cancel();
    _maybeStart();
  }

  /// 页面 / 面板 / 可见性变化时的可播条件（由 shell 统一驱动）。
  void setCanPlay(bool value) {
    if (_canPlay == value) return;
    _canPlay = value;
    if (!value) {
      cancel();
    } else {
      _maybeStart();
    }
  }

  /// 手动重播（详情面板「重播 OP」按钮）。忽略「本会话已播过」限制。
  ///
  /// ⚠️ 调用方（shell）应先关闭详情面板，否则 `_canPlay` 仍为 false。
  void replay() {
    final String? dir = _currentMetaDataDir;
    if (dir == null) return;
    _replayFrom(dir);
  }

  /// 手动重播**指定游戏**的 OP。
  ///
  /// 详情面板可能来自「我的库」页，那里的游戏与舞台游戏不一定是同一个
  /// （库页不更新 `_stageGame`），因此需要显式指定。
  void replayFor(String metaDataDir) {
    if (metaDataDir.isEmpty) return;
    _replayFrom(metaDataDir);
  }

  void _replayFrom(String metaDataDir) {
    final String? path = BpmBackdropMedia.resolveSelectedVideo(metaDataDir);
    if (path == null) return;
    _currentMetaDataDir = metaDataDir;
    cancel();
    _arm(path);
  }

  /// 外部数据变化（背景窗口改了选中视频 / 删除 / 上传）后由 shell 调用：
  /// 停掉当前播放，按**新的选中视频**重新走一遍「3 秒停留 → 播放」流程。
  void refresh() {
    cancel();
    _maybeStart();
  }

  /// 立即停止并释放（换游戏 / 离开主页 / 面板打开 / 退出大屏）。
  void cancel() {
    _generation++; // 使所有在途异步回调失效
    _armTimer?.cancel();
    _armTimer = null;
    _disposeTimer?.cancel();
    _disposeTimer = null;
    _disposePlayer();
    if (_state != BpmBackdropVideoState.idle) {
      _state = BpmBackdropVideoState.idle;
      notifyListeners();
    }
  }

  /// 应用窗口最小化 / 失焦时的暂停（用户 2026-09-26 拍板：暂停）。
  ///
  /// 与 [cancel] 的区别：停在原处，恢复可见时从当前进度继续，
  /// 不重置 3 秒计时、不丢弃播放器。
  void pauseForLifecycle() {
    final VideoPlayerController? c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      unawaited(c.pause());
      notifyListeners();
    }
  }

  /// 恢复可见时继续（仅当仍处于播放态）。
  void resumeForLifecycle() {
    if (_state != BpmBackdropVideoState.playing) return;
    final VideoPlayerController? c = _controller;
    if (c == null || !c.value.isInitialized) return;
    unawaited(c.play());
  }

  // ============ 内部 ============

  void _maybeStart() {
    if (!_canPlay) return;
    final String? dir = _currentMetaDataDir;
    final String? key = _currentKey;
    if (dir == null || key == null) return;

    final String? opPath = BpmBackdropMedia.resolveSelectedVideo(dir);
    if (opPath == null) return;

    // 「每次进入一次只播一次」：本会话该游戏已自动播过 → 只显示静态背景
    final BpmOpVideoPreference prefs = BpmOpVideoPreference.instance;
    if (!prefs.autoplayAlways && _playedThisSession.contains(key)) return;

    _arm(opPath);
  }

  void _arm(String path) {
    final int gen = ++_generation;
    _state = BpmBackdropVideoState.arming;
    notifyListeners();

    // 关键：把「打开文件 + 首帧解码」的耗时挪进这 3 秒里，
    // 计时到点即可直接 play()，避免用户看到卡顿。
    unawaited(_prewarm(path, gen));

    _armTimer?.cancel();
    _armTimer = Timer(_armDelay, () {
      if (gen != _generation) return;
      _onArmComplete(gen);
    });
  }

  Future<void> _prewarm(String path, int gen) async {
    VideoPlayerController? created;
    try {
      created = (_playerFactory ?? _defaultFactory)(File(path));
      await created.initialize();
      if (gen != _generation) {
        await created.dispose();
        return;
      }
      await created.setLooping(false);
      await created.setVolume(_effectiveVolume());
      created.addListener(() => _onTick(created!, gen));
      _controller = created;
      notifyListeners();
    } catch (e) {
      // 冷门编码 / 文件损坏 → 静默回退静态背景（不打断用户，方案 §10 R3）
      debugPrint('[BPM-OP-VIDEO] 预热失败，回退静态背景: $e');
      try {
        await created?.dispose();
      } catch (_) {}
      if (gen == _generation) {
        _state = BpmBackdropVideoState.idle;
        notifyListeners();
      }
    }
  }

  void _onArmComplete(int gen) {
    if (gen != _generation) return;
    final VideoPlayerController? c = _controller;
    if (c == null || !c.value.isInitialized) {
      // 预热没赶上（大文件 / 慢盘）→ 放弃本次，回静态背景
      _generation++;
      _disposePlayer();
      _state = BpmBackdropVideoState.idle;
      notifyListeners();
      return;
    }

    final String? key = _currentKey;
    if (key != null) _playedThisSession.add(key);

    _state = BpmBackdropVideoState.playing;
    notifyListeners();
    unawaited(c.play());
  }

  void _onTick(VideoPlayerController c, int gen) {
    if (gen != _generation || c != _controller) return;
    if (c.value.hasError) {
      debugPrint('[BPM-OP-VIDEO] 播放出错，回退静态背景');
      cancel();
      return;
    }
    if (c.value.isCompleted) {
      _finish();
    }
  }

  /// 播完 → 淡出 → 释放（用户要求「结束后淡淡恢复原背景图」）。
  void _finish() {
    if (_state != BpmBackdropVideoState.playing) return;
    _state = BpmBackdropVideoState.fadingOut;
    notifyListeners(); // videoOpacity → 0，widget 开始淡出

    _disposeTimer?.cancel();
    _disposeTimer = Timer(fadeDuration, () {
      _generation++;
      _disposePlayer();
      _state = BpmBackdropVideoState.idle;
      notifyListeners();
    });
  }

  void _disposePlayer() {
    final VideoPlayerController? c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      unawaited(c.dispose());
    } catch (e) {
      debugPrint('[BPM-OP-VIDEO] 释放播放器失败: $e');
    }
  }

  static VideoPlayerController _defaultFactory(File file) =>
      VideoPlayerController.file(file);

  @override
  void dispose() {
    _generation++;
    _gameMuted = null;
    _armTimer?.cancel();
    _disposeTimer?.cancel();
    _disposePlayer();
    super.dispose();
  }

  /// 仅供单测观察「本会话已播过」集合。
  @visibleForTesting
  bool hasAutoPlayed(String key) => _playedThisSession.contains(key);
}
