import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_colors.dart';
import '../../services/local_game_registry.dart';
import '../../services/game_data_format.dart';
import '../../services/game_launch_service.dart';
import '../../widgets/screenshot_carousel.dart';
import '../../widgets/launch_manager_dialog.dart';
import '../../widgets/app_snack_bar.dart';
import '../big_picture_theme.dart';
import '../widgets/bpm_interactive_wrapper.dart';

/// BPM 游戏详情全屏页
///
/// 布局:
/// - 顶部: 返回按钮
/// - 左侧 (40%): 大封面 + 标题 + 开发者 + 标签 + 启动按钮组
/// - 右侧 (60%): 截图轮播 + 简介 + 元数据
///
/// 启动按钮调用 [GameLaunchService] 完成启动流程 (与桌面模式一致)。
class BigPictureDetail extends StatefulWidget {
  /// 游戏数据
  final LibraryGame game;

  /// 返回回调
  final VoidCallback onBack;

  /// 启动游戏回调 (用于状态刷新,实际启动逻辑走 GameLaunchService)
  final VoidCallback? onLaunchComplete;

  const BigPictureDetail({
    super.key,
    required this.game,
    required this.onBack,
    this.onLaunchComplete,
  });

  @override
  State<BigPictureDetail> createState() => _BigPictureDetailState();
}

class _BigPictureDetailState extends State<BigPictureDetail> {
  String? _coverPath;
  bool _isLaunching = false;

  @override
  void initState() {
    super.initState();
    _resolveCoverPath();
  }

  void _resolveCoverPath() {
    final game = widget.game;
    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      _coverPath = game.coverUrl;
      return;
    }
    try {
      _coverPath = GameDataFormat.findCoverFile(game.pathForCover)?.path;
    } catch (_) {
      _coverPath = null;
    }
  }

  Future<void> _handleLaunch() async {
    if (_isLaunching) return;
    setState(() => _isLaunching = true);

    try {
      final game = widget.game;
      final exePath =
          await GameLaunchService.instance.resolveUserChoice(game.title);
      if (exePath == null) {
        // P1: 无 exe 时直接打开启动管理器,就地引导用户选择
        //     (不再让用户切换桌面模式右键启动管理)
        if (mounted) {
          AppSnackBar.warning(context, '请先选择启动程序');
          await _openLaunchManager();
        }
        return;
      }
      final result =
          await GameLaunchService.instance.executeLaunch(game, exePath);
      if (!result.success && mounted) {
        AppSnackBar.error(context, result.error ?? '无法启动游戏');
      }
      widget.onLaunchComplete?.call();
    } finally {
      if (mounted) setState(() => _isLaunching = false);
    }
  }

  Future<void> _openLaunchManager() async {
    // P2: 预解析当前 exe 路径作为初始值; locale/upscaling 默认 'none'
    //     (详情页不维护内存 map,避免过度设计;对话框内部仍会读写 game.json)
    final currentExe =
        await GameLaunchService.instance.resolveUserChoice(widget.game.title);
    if (!mounted) return;
    await LaunchManagerDialog.show(
      context: context,
      gameTitle: widget.game.title,
      gameDirectory: widget.game.directoryPath,
      metaDataDir: widget.game.metaDataDir,
      initialExePath: currentExe,
      initialLocaleMode: 'none',
      initialUpscalingMode: 'none',
      onExeSelected: (selectedExe) async {
        await GameLaunchService.instance
            .persistUserChoice(widget.game.title, selectedExe);
        if (!mounted) return;
        AppSnackBar.info(context, '已更新启动程序');
      },
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.pageBackground,
      child: Focus(
        // P4: 移除 autofocus,改由返回按钮 autofocus 接管初始焦点
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            widget.onBack();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        // P5: 主体包裹 FocusTraversalGroup 统一焦点导航顺序
        child: FocusTraversalGroup(
          child: CustomScrollView(
            slivers: [
              // 顶部返回栏 (P6: 标题改为 "详情" 避免与左面板大标题重复)
              SliverToBoxAppBar(
                onBack: widget.onBack,
                title: '详情',
              ),
              // 主体内容
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(BigPictureTheme.pagePadding),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 左侧: 封面 + 信息 + 启动按钮 (40%)
                      Expanded(
                        flex: 4,
                        child: _buildLeftPanel(),
                      ),
                      const SizedBox(width: BigPictureTheme.sectionSpacing),
                      // 右侧: 截图 + 简介 + 元数据 (60%)
                      Expanded(
                        flex: 6,
                        child: _buildRightPanel(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 左侧面板: 大封面 + 标题 + 开发者 + 标签 + 启动按钮
  Widget _buildLeftPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 大封面
        Container(
          width: double.infinity,
          height: BigPictureTheme.detailCoverHeight,
          decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            borderRadius:
                BorderRadius.circular(BigPictureTheme.containerRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: _buildCover(),
        ),
        const SizedBox(height: 24),
        // 标题
        Text(
          widget.game.title,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: BigPictureTheme.titleFontSize,
            fontWeight: FontWeight.w800,
            color: AppColors.primaryText,
            height: 1.3,
          ),
        ),
        if (widget.game.developer.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            widget.game.developer,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.subtitleFontSize,
              color: AppColors.secondaryText,
            ),
          ),
        ],
        // 标签
        if (widget.game.tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: widget.game.tags.take(6).map((tag) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  borderRadius:
                      BorderRadius.circular(BigPictureTheme.buttonRadius),
                  border: Border.all(color: AppColors.border, width: 1),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.labelFontSize,
                    color: AppColors.secondaryText,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 24),
        // 启动按钮组 (P3: Row → Wrap 兜底换行; 启动按钮 width → ConstrainedBox(minWidth) 允许窄屏收缩)
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            BpmInteractiveWrapper(
              onTap: _isLaunching ? null : _handleLaunch,
              semanticsLabel: '开始游戏',
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: BigPictureTheme.launchButtonWidth,
                ),
                child: Container(
                  height: BigPictureTheme.launchButtonHeight,
                  decoration: BoxDecoration(
                    color: AppColors.selectedAccent,
                    borderRadius:
                        BorderRadius.circular(BigPictureTheme.buttonRadius),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.selectedAccent.withOpacity(0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isLaunching)
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      else
                        const Icon(Icons.play_arrow_rounded,
                            size: 32, color: Colors.white),
                      const SizedBox(width: 12),
                      Text(
                        _isLaunching ? '启动中...' : '开始游戏',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            BpmInteractiveWrapper(
              onTap: _openLaunchManager,
              semanticsLabel: '启动管理',
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              child: Container(
                height: BigPictureTheme.launchButtonHeight,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  borderRadius:
                      BorderRadius.circular(BigPictureTheme.buttonRadius),
                  border: Border.all(
                    color: AppColors.border,
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune_rounded,
                          size: 22, color: AppColors.secondaryText),
                      const SizedBox(width: 8),
                      Text(
                        '启动管理',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: BigPictureTheme.bodyFontSize,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 右侧面板: 截图轮播 + 简介 + 元数据
  Widget _buildRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 截图轮播
        ClipRRect(
          borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
          child: ScreenshotCarousel(
            paths: widget.game.screenshotUrls.isNotEmpty
                ? widget.game.screenshotUrls
                : widget.game.screenshotFiles,
            isNetwork: widget.game.screenshotUrls.isNotEmpty,
            height: 320,
            showIndicator: true,
            showArrows: true,
            gameTitle: widget.game.title,
          ),
        ),
        const SizedBox(height: 24),
        // 简介
        if (widget.game.description.isNotEmpty) ...[
          Text(
            '游戏简介',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.subtitleFontSize,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.background.withOpacity(0.5),
              borderRadius:
                  BorderRadius.circular(BigPictureTheme.containerRadius),
              border: Border.all(color: AppColors.borderLight, width: 1),
            ),
            child: Text(
              widget.game.description,
              // P8: 加 maxLines 防止超长描述挤压布局
              maxLines: 12,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.bodyFontSize,
                color: AppColors.primaryText,
                height: 1.6,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        // 元数据
        _buildMetadataGrid(),
      ],
    );
  }

  /// 元数据网格: 游玩状态 / 游玩时长 / 安装时间 / 最后游玩
  Widget _buildMetadataGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 4.0,
      children: [
        _buildMetadataItem(
          '游玩状态',
          _playStatusLabel(widget.game.playStatus),
          Icons.sports_esports_rounded,
        ),
        _buildMetadataItem(
          '游玩时长',
          _formatPlayTime(widget.game.playTime),
          Icons.schedule_rounded,
        ),
        _buildMetadataItem(
          '安装时间',
          _formatDate(widget.game.installedAt),
          Icons.download_done_rounded,
        ),
        _buildMetadataItem(
          '最后游玩',
          widget.game.lastOpenedAt.isNotEmpty
              ? _formatDate(widget.game.lastOpenedAt)
              : '尚未游玩',
          Icons.history_rounded,
        ),
      ],
    );
  }

  Widget _buildMetadataItem(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background.withOpacity(0.5),
        borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.secondaryText),
          const SizedBox(width: 12),
          // P7: Column 包 Expanded 防止长文本横向溢出
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    // P9: 11 → labelFontSize (14) 符合 BPM 最小字号规范
                    fontSize: BigPictureTheme.labelFontSize,
                    color: AppColors.secondaryText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.bodyFontSize,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover() {
    if (_coverPath != null &&
        _coverPath!.isNotEmpty &&
        File(_coverPath!).existsSync()) {
      return Image.file(
        File(_coverPath!),
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
          fontSize: 96,
          color: AppColors.secondaryText.withOpacity(0.4),
        ),
      ),
    );
  }

  String _playStatusLabel(PlayStatus status) {
    return switch (status) {
      PlayStatus.notStarted => '未开始',
      PlayStatus.inProgress => '进行中',
      PlayStatus.completed => '已完成',
      PlayStatus.dropped => '已弃坑',
    };
  }

  String _formatPlayTime(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours < 100) return '$hours小时$mins分';
    return '$hours小时';
  }

  String _formatDate(String iso) {
    if (iso.isEmpty) return '未知';
    try {
      final dt = DateTime.parse(iso);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

/// 详情页顶部应用栏 (Sliver 版)
class SliverToBoxAppBar extends StatelessWidget {
  final VoidCallback onBack;
  final String title;

  const SliverToBoxAppBar({
    super.key,
    required this.onBack,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BigPictureTheme.pagePadding,
          BigPictureTheme.pagePadding,
          BigPictureTheme.pagePadding,
          16,
        ),
        child: Row(
          children: [
            BpmInteractiveWrapper(
              autofocus: true, // P4: 接管初始焦点 (原外层 Focus autofocus 已移除)
              onTap: onBack,
              semanticsLabel: '返回',
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  borderRadius:
                      BorderRadius.circular(BigPictureTheme.buttonRadius),
                  border: Border.all(color: AppColors.border, width: 1.5),
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 24,
                  color: AppColors.primaryText,
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: BigPictureTheme.subtitleFontSize,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
