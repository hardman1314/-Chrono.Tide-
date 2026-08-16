import 'dart:io';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../services/local_game_registry.dart';
import '../../services/game_data_format.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 大尺寸游戏卡片
///
/// 16:9 比例 (320x180),展示游戏封面 + 标题 + 状态徽章。
/// 支持:
/// - 鼠标悬停 (轻微缩放)
/// - 键盘焦点 (高亮边框 + 1.05x 缩放)
/// - 单击 (打开详情页)
/// - 双击 (启动游戏)
///
/// 封面加载策略:
/// 1. 优先使用 [LibraryGame.coverUrl] (本地缓存路径)
/// 2. 回退到 [GameDataFormat.findCoverFile] 在 metaDataDir 搜索
/// 3. 都失败时显示首字占位
class BigPictureGameCard extends StatefulWidget {
  /// 游戏数据
  final LibraryGame game;

  /// 单击回调 (通常打开详情页)
  final VoidCallback? onTap;

  /// 双击回调 (通常启动游戏)
  final VoidCallback? onDoubleTap;

  /// 长按回调 (通常弹出动作表)
  final VoidCallback? onLongPress;

  /// 是否自动获取焦点
  final bool autofocus;

  /// 外部预解析的封面路径 (可选,若提供则跳过内部解析)
  final String? coverPath;

  const BigPictureGameCard({
    super.key,
    required this.game,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.autofocus = false,
    this.coverPath,
  });

  @override
  State<BigPictureGameCard> createState() => _BigPictureGameCardState();
}

class _BigPictureGameCardState extends State<BigPictureGameCard> {
  String? _resolvedCoverPath;

  @override
  void initState() {
    super.initState();
    _resolvedCoverPath = widget.coverPath ?? _resolveCoverPath();
  }

  @override
  void didUpdateWidget(BigPictureGameCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.directoryPath != widget.game.directoryPath ||
        oldWidget.game.coverUrl != widget.game.coverUrl ||
        oldWidget.coverPath != widget.coverPath) {
      _resolvedCoverPath = widget.coverPath ?? _resolveCoverPath();
    }
  }

  String? _resolveCoverPath() {
    final game = widget.game;
    // 1. 优先 game.coverUrl (本地缓存路径)
    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      return game.coverUrl;
    }
    // 2. 回退到 GameDataFormat 搜索
    try {
      return GameDataFormat.findCoverFile(game.pathForCover)?.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: 隔离卡片重绘,避免相邻卡片焦点动画触发整网格重绘
    return RepaintBoundary(
      child: BpmInteractiveWrapper(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        autofocus: widget.autofocus,
        semanticsLabel: widget.game.title,
        borderRadius: BorderRadius.circular(BigPictureTheme.cardRadius),
        child: Container(
          width: BigPictureTheme.cardWidth,
          height: BigPictureTheme.cardHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BigPictureTheme.cardRadius),
            color: AppColors.buttonBackground,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 封面层
              _buildCover(),
              // 底部渐变 + 标题层
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.85),
                        Colors.black.withOpacity(0.4),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.game.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      if (widget.game.developer.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            widget.game.developer,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 状态徽章 (右上角)
              Positioned(
                top: 8,
                right: 8,
                child: _buildStatusBadge(),
              ),
              // 标记徽章 (左上角)
              if (widget.game.mark != GameMark.none)
                Positioned(
                  top: 8,
                  left: 8,
                  child: _buildMarkBadge(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover() {
    final path = _resolvedCoverPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(
        File(path),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
      );
    }
    return _buildPlaceholderCover();
  }

  Widget _buildPlaceholderCover() {
    final initial =
        widget.game.title.isNotEmpty ? widget.game.title.characters.first : '?';
    return Container(
      color: AppColors.buttonBackground,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: 'ZhiMangXing',
          fontSize: 72,
          color: AppColors.secondaryText.withOpacity(0.4),
        ),
      ),
    );
  }

  Widget _buildStatusBadge() {
    final (label, color) = switch (widget.game.playStatus) {
      PlayStatus.notStarted => ('未开始', AppColors.secondaryText),
      PlayStatus.inProgress => ('进行中', AppColors.infoBlue),
      PlayStatus.completed => ('已完成', AppColors.successGreen),
      PlayStatus.dropped => ('已弃坑', AppColors.dangerRed),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildMarkBadge() {
    final (icon, color) = switch (widget.game.mark) {
      GameMark.favorite => (Icons.favorite_rounded, Colors.redAccent),
      GameMark.star => (Icons.star_rounded, const Color(0xFFFFC107)),
      GameMark.none => (Icons.bookmark_border_rounded, AppColors.secondaryText),
    };

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 14, color: color),
    );
  }
}
