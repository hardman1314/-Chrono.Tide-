import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// BPM 背景 OP 视频渲染层（单一职责：把已初始化的控制器"画"出来）。
///
/// 所有生命周期 / 计时 / 状态转移都在
/// `lib/big_picture/services/bpm_backdrop_media_controller.dart`，
/// 本文件**不含任何状态**，便于单测与复用。
///
/// 🔴 关键约束（勿回退）：
/// 1. **必须 cover 而非 contain** —— BPM 背景是全屏铺满的，视频若按 contain
///    会留黑边，破坏"视频在背后播放"的观感。做法是 `FittedBox(fit: cover)`
///    包一个按视频原始尺寸撑开的 `SizedBox`（见方案 §4.3）。
/// 2. **未初始化 → `SizedBox.shrink()`**，绝不渲染半成品，避免首帧黑/白闪。
/// 3. **`IgnorePointer` 包裹** —— 背景层永远不参与命中测试，
///    否则会挡住 hero / shelf 的手柄与鼠标操作。
///
/// 不在此处处理 NSFW：用户 2026-09-26 拍板「照常播放」（方案 §13 Q2）。
class BpmOpVideoLayer extends StatelessWidget {
  /// 已初始化的播放器控制器；`null` = 当前不渲染视频层。
  final VideoPlayerController? controller;

  /// 目标不透明度（0..1），由状态机驱动；内部用 [AnimatedOpacity] 平滑过渡。
  final double opacity;

  /// 淡入 / 淡出时长。
  final Duration duration;

  const BpmOpVideoLayer({
    super.key,
    required this.controller,
    required this.opacity,
    this.duration = const Duration(milliseconds: 240),
  });

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? c = controller;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final Size size = c.value.size;
    if (size.width <= 0 || size.height <= 0) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: opacity.clamp(0.0, 1.0),
        duration: duration,
        curve: Curves.easeInOut,
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(c),
          ),
        ),
      ),
    );
  }
}
