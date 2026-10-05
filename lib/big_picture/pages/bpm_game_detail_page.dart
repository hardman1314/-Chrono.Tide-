import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/game_data_format.dart';
import '../../services/local_game_registry.dart';
import '../../services/tag_library_override_store.dart';
import '../../theme/app_styles.dart';
import '../../widgets/nsfw/nsfw_image.dart';
import '../big_picture_theme.dart';
import '../services/bpm_play_history.dart';
import '../widgets/bpm_interactive_wrapper.dart';

/// BPM 二级游戏详情（v3.13，2026-09-28 二次重构）—— **全屏整页**。
///
/// 🔴 视觉基准 = 用户桌面《详情面板设计.md》+ Playnite 主题 (u)biquity 实机截图：
/// **没有面板**。此前 v3.12 的「磨砂玻璃侧牌」被用户否定（「僵硬的侧边牌子」），
/// 正确形态是《设计.md》定义的两层遮罩，内容像自然浮现在背景上：
///
///   Layer 1（Base Mask）左→右线性暗色体积遮罩：深黑 0.95 → 半透明灰 0.0，
///            **尾段 30% 衰减要非常平缓**（模拟自然衰减）。
///   Layer 2（Edge Dissolve）遮罩右缘的**非规则晕染**：一串大小/浓度各异、
///            固定伪随机的径向柔光斑打破线性规律（等价于文档里
///            「ShaderMask + blur / 噪点」要达成的有机边缘，且无 GPU 模糊开销）。
///
/// 排版（对齐 PN 实机截图）：
///   - 标题块垂直落在 **~1/3 高度**（不是从屏幕顶端贴起）；
///   - 统计与按钮行**不贴底**，整体上移，保证版面重心；
///   - 底部按钮行 = 游玩（宽，左上角 M / L 指示灯）→ **⋯ 菜单**（编辑 / 目录 /
///     删除收进菜单，由 shell 弹出，带模态门禁与手柄支持）→ 背景 →
///     播放（正上方为隐藏 UI 按钮）。
///
/// 🔴 手柄 / 滚动接线（不得改动）：[primaryFocusNode] 挂「游玩」按钮 =
///    shell「A 进入详情内容操作」的落点；[scrollController] 挂简介+截图滚动视口 =
///    shell 右摇杆 / LT·RT 的滚动落点。
class BpmGameDetailPage extends StatefulWidget {
  final LibraryGame game;

  /// 是否可见（shell 用它驱动进出场动画；关闭态 widget 仍在树上做退场）
  final bool visible;

  final VoidCallback onLaunch;

  /// 该游戏背景视频是否被用户静音（game.json，shell 传入用于按钮图标）
  final bool soundMuted;

  /// 切换每游戏背景声音（shell 写 game.json 并对当前播放即时生效）
  final VoidCallback onToggleSound;

  /// 打开手柄映射配置（与主页原「手柄」按钮同链路）
  final VoidCallback onOpenGamepadConfig;

  final VoidCallback onBackdropTune;

  /// 「⋯」拉出菜单的三个动作（菜单是按钮旁的面板，不再是路由弹窗）
  final VoidCallback onEdit;
  final VoidCallback onOpenDirectory;
  final VoidCallback onDelete;

  /// 重播背景视频（OP）。null = 该游戏没有视频 → **不显示播放按钮**。
  final VoidCallback? onReplayOp;

  /// 面板内容操作入口节点（挂在「游玩」按钮上）
  final FocusNode? primaryFocusNode;

  /// 简介 + 截图滚动视口控制器（右摇杆 / LT·RT 的落点）
  final ScrollController? scrollController;

  /// 隐藏 UI 态（欣赏背景）
  final bool uiHidden;

  /// 切换隐藏 UI 态
  final VoidCallback? onToggleUiHidden;

  /// 「⋯」拉出菜单的开合（shell 持有：B 键「只关菜单不关详情」需要）
  final ValueNotifier<bool> menuOpen;

  const BpmGameDetailPage({
    super.key,
    required this.game,
    required this.visible,
    required this.onLaunch,
    required this.soundMuted,
    required this.onToggleSound,
    required this.onOpenGamepadConfig,
    required this.onBackdropTune,
    required this.onEdit,
    required this.onOpenDirectory,
    required this.onDelete,
    required this.menuOpen,
    this.onReplayOp,
    this.primaryFocusNode,
    this.scrollController,
    this.uiHidden = false,
    this.onToggleUiHidden,
  });

  @override
  State<BpmGameDetailPage> createState() => _BpmGameDetailPageState();
}

class _BpmGameDetailPageState extends State<BpmGameDetailPage> {
  /// 内容列占屏宽的比例（v3.14：内容成为主体，约 1/3 屏宽）
  static const double _contentWidthRatio = 0.32;

  /// 内容列左缘占屏宽的比例（v3.14：整体右移，对齐 PN 的 ~8%）
  static const double _contentLeftRatio = 0.075;

  /// 遮罩带占屏幕宽度的比例（PN 实机约 50%~60%）
  static const double _maskExtentRatio = 0.58;

  /// 启动模式缓存（game.json）
  String _localeMode = 'none';
  String _upscalingMode = 'none';

  /// 启动次数（BpmPlayHistory，倒序条数）
  int _launchCount = 0;

  /// 「⋯」拉出菜单：锚点（⋯ 按钮的全局左上角）与开合
  final GlobalKey _menuAnchorKey = GlobalKey();
  Offset _menuAnchor = Offset.zero;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _loadJsonData();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    super.dispose();
  }

  void _onRegistryChanged() => _loadJsonData();

  Future<void> _loadJsonData() async {
    final dir = widget.game.metaDataDir;
    if (dir.isEmpty) return;
    try {
      final data = await GameDataFormat.readGameJson(dir);
      final launchCount = BpmPlayHistory.load(dir).length;
      if (!mounted) return;
      setState(() {
        _localeMode = data?.localeMode ?? 'none';
        _upscalingMode = data?.upscalingMode ?? 'none';
        _launchCount = launchCount;
      });
    } catch (_) {}
  }

  /// 开/关「⋯」拉出菜单（记录 ⋯ 按钮的全局位置用于锚定）
  void _toggleMenu() {
    if (_menuOpen) {
      widget.menuOpen.value = false;
      setState(() => _menuOpen = false);
      return;
    }
    final box = _menuAnchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    setState(() {
      _menuAnchor = box.localToGlobal(Offset.zero);
      _menuOpen = true;
      widget.menuOpen.value = true;
    });
  }

  void _closeMenu() {
    if (!_menuOpen) return;
    widget.menuOpen.value = false;
    setState(() => _menuOpen = false);
  }

  /// 执行菜单动作并收起菜单（动作可能是弹编辑窗 / 打开目录 / 删除确认）
  void _runMenuAction(VoidCallback action) {
    _closeMenu();
    action();
  }

  // ============ 游玩状态切换（与桌面同源） ============

  String _statusToString(PlayStatus s) => switch (s) {
        PlayStatus.notStarted => 'not_started',
        PlayStatus.inProgress => 'in_progress',
        PlayStatus.completed => 'completed',
        PlayStatus.dropped => 'dropped',
      };

  Future<void> _setPlayStatus(PlayStatus status) async {
    if (status == widget.game.playStatus) return;
    await GameDataFormat.setPlayStatus(
        widget.game.metaDataDir, _statusToString(status));
    widget.game.playStatus = status;
    LocalGameRegistry.instance.notifyDataChanged();
    if (mounted) setState(() {});
  }

  /// 统计区「点击循环切换」。刻意不用 PopupMenu（弹出层是路由，手柄事件
  /// 不经 Flutter 键盘通道、桥接不进去），循环切换在任意模式下都可被 A 激活。
  Future<void> _cyclePlayStatus() async {
    const values = PlayStatus.values;
    final next = values[(values.indexOf(widget.game.playStatus) + 1) %
        values.length];
    await _setPlayStatus(next);
  }

  // ============ 启动模式开关（M / L，写 game.json 与桌面同源） ============

  Future<void> _toggleUpscaling() async {
    final next = _upscalingMode == 'magpie' ? 'none' : 'magpie';
    final ok = await GameDataFormat.updateGameJson(
        widget.game.metaDataDir, {'upscaling_mode': next});
    if (!ok || !mounted) return;
    setState(() => _upscalingMode = next);
  }

  Future<void> _toggleLocale() async {
    final next = _localeMode == 'japanese' ? 'none' : 'japanese';
    final ok = await GameDataFormat.updateGameJson(
        widget.game.metaDataDir, {'locale_mode': next});
    if (!ok || !mounted) return;
    setState(() => _localeMode = next);
  }

  // ============ 构建 ============

  @override
  Widget build(BuildContext context) {
    // 🔴 `Positioned.fill` 必须是根 Stack 的直接子级；内层定位一律挂内层 Stack
    //    （Positioned 隔着 AnimatedSlide/AnimatedOpacity 挂 Stack 会踩
    //    ParentDataWidget 的父级约定，运行期才炸）。
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: AnimatedSlide(
            offset: widget.visible ? Offset.zero : const Offset(-0.03, 0),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: (widget.visible && !widget.uiHidden) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              child: LayoutBuilder(builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // Layer 1：基础暗色体积遮罩（左 → 右，尾段 30% 平缓衰减）
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: w * _maskExtentRatio,
                      child: const IgnorePointer(child: _BaseMask()),
                    ),
                    // Layer 2：右缘非规则晕染（打破线性规律）
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _EdgeDissolvePainter(
                            edgeX: w * _maskExtentRatio,
                            extent: w * _maskExtentRatio * 0.42,
                            height: h,
                            color: BpmColors.deepPanel,
                          ),
                        ),
                      ),
                    ),
                    // 底部轻压暗（衬按钮行，PN 同款）
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: h * 0.34,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                BpmColors.deepBase.withOpacity(0.42),
                                BpmColors.deepBase.withOpacity(0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 内容列（v3.14：整体右移 + 加宽到 ~1/3 屏宽，内容成为主体）
                    Positioned(
                      left: w * _contentLeftRatio,
                      top: 0,
                      bottom: 0,
                      width: w * _contentWidthRatio,
                      child: _buildContent(h, w * _contentWidthRatio),
                    ),

                    // ── 「⋯」拉出菜单（v3.14：按钮旁的面板，不再是路由弹窗）──
                    if (_menuOpen) ...[
                      // 菜单外任意点击 = 只关菜单（opaque：不穿透到「点背景关详情」）
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _closeMenu,
                        ),
                      ),
                      // 锚定在 ⋯ 按钮正上方，右缘对齐按钮右缘
                      Positioned(
                        left: (_menuAnchor.dx - 172).clamp(8.0, w - 224.0),
                        bottom: h - _menuAnchor.dy + 8,
                        width: 216,
                        child: _DetailMenuPanel(
                          gameTitle: widget.game.title,
                          onEdit: () =>
                              _runMenuAction(widget.onEdit),
                          onOpenDirectory: () =>
                              _runMenuAction(widget.onOpenDirectory),
                          onDelete: () => _runMenuAction(widget.onDelete),
                        ),
                      ),
                    ],
                  ],
                );
              }),
            ),
          ),
        ),

        // 隐藏 UI 期间的「任意输入唤回」层。
        // 🔴 必须 opaque：否则点击穿透到 shell 的面板外屏障，想唤回却把详情关了。
        if (widget.uiHidden && widget.visible)
          Positioned.fill(child: _buildRevealLayer()),
      ],
    );
  }

  /// 隐藏 UI 时的唤回层：鼠标移动 / 点击 / 任意键 → 唤回。
  Widget _buildRevealLayer() {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => widget.onToggleUiHidden?.call(),
      onPointerHover: (_) => widget.onToggleUiHidden?.call(),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              widget.onToggleUiHidden?.call();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// 内容列：标题带垂直中心 ≈ 1/4 屏高；统计与按钮行不贴底。
  ///
  /// v3.14：全列内容整体放大（字号随列宽缩放），右移到 ~7.5% 屏宽处。
  Widget _buildContent(double h, double cw) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部留白 → 标题垂直中心 ≈ 1/4 屏高
          SizedBox(height: h * 0.20),
          _buildGameHeader(cw),
          const SizedBox(height: 24),
          // 简介 + 截图（L 型排版）—— **唯一垂直滚动视口**
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(0, 2, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _introHeading(),
                  _buildIntroSection(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          _buildStatsRow(),
          // v3.14: 数据贴近按钮行（原 18）
          const SizedBox(height: 10),
          _buildBottomBar(),
          // 底部不上贴边：整体上移，保住版面重心
          SizedBox(height: h * 0.065),
        ],
      ),
    );
  }

  /// 「Introduction」大顶标（简介区的大标题，PN 同款层级）
  Widget _introHeading() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        'Introduction',
        style: TextStyle(
          fontFamily: AppStyles.zhDecorativeFont,
          fontSize: 24,
          height: 1.2,
          letterSpacing: 1.5,
          color: BpmColors.textPrimary.withOpacity(0.92),
          shadows: [Shadow(color: BpmColors.heroTextShadow, blurRadius: 14)],
        ),
      ),
    );
  }

  // ============ ① 标题块 ============

  Widget _buildGameHeader(double cw) {
    final game = widget.game;
    // v3.14: 大标题随列宽缩放（比 v3.13 的固定 42 明显放大）
    final titleSize = (cw * 0.088).clamp(38.0, 60.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          game.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AppStyles.zhDecorativeFont,
            fontSize: titleSize,
            height: 1.14,
            letterSpacing: 0.5,
            color: BpmColors.textPrimary,
            shadows: [
              Shadow(
                color: BpmColors.heroTextShadow,
                blurRadius: 22,
                offset: const Offset(0, 3),
              ),
            ],
          ),
        ),
        if (game.developer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(
              game.developer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 16.5,
                letterSpacing: 1.8,
                color: BpmColors.mistBlue,
                shadows: [
                  Shadow(color: BpmColors.heroTextShadow, blurRadius: 12)
                ],
              ),
            ),
          ),
        if (game.subtitle.isNotEmpty && game.subtitle != game.title)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              game.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 13.5,
                color: BpmColors.textMuted,
              ),
            ),
          ),
        const SizedBox(height: 22),
        _buildTagGroup(),
      ],
    );
  }

  Widget _buildTagGroup() {
    // 全局隐藏标签（分类匣·标签库）在 BPM 详情页同样生效
    final tags = TagLibraryOverrideStore.instance
        .filterVisibleTags(widget.game.tags);
    if (tags.isEmpty) {
      return Text(
        '暂无标签',
        style: TextStyle(
          fontFamily: AppStyles.uiFontFamily,
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: BpmColors.textMuted,
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tag in tags.take(12))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              // v3.14: 圆角方框（不再是全圆胶囊）
              borderRadius: BorderRadius.circular(6),
              color: BpmColors.deepBase.withOpacity(0.45),
              border: Border.all(color: BpmColors.mistBlueBorder, width: 1),
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 13,
                color: BpmColors.mistBlueSoft,
              ),
            ),
          ),
      ],
    );
  }

  // ============ ② 介绍（简介 + 截图，L 型排版） ============

  Widget _buildIntroSection() {
    final shots = widget.game.screenshotFiles;
    final desc = widget.game.description;
    final hasDesc = desc.isNotEmpty;

    if (shots.isEmpty) {
      // v3.19: 有截图源 URL 但本地文件未就绪 = 后台下载进行中/待回填
      // （ScreenshotFetchService 异步下载 + 启动时 backfill）。此前直接
      // 显示「暂无简介」，用户感知「添加导入后截图丢失」。
      final pendingShots = widget.game.screenshotUrls.isNotEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasDesc)
            Text(desc, style: _descStyle)
          else
            Text(
              '暂无简介',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
                color: BpmColors.textMuted,
              ),
            ),
          if (pendingShots) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: BpmColors.textMuted.withOpacity(0.7),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '截图正在后台获取，完成后自动显示',
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 12,
                    color: BpmColors.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }

    final carousel = _BpmShotCarousel(
      metaDataDir: widget.game.metaDataDir,
      shots: shots,
      onView: _showScreenshotViewer,
    );

    if (!hasDesc) return carousel;

    return LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      const gap = 12.0;
      // v3.14: 截图展示面积放大 —— 截图列占 58%，文字列 42%
      const shotFlex = 58;
      const textFlex = 42;
      final carouselWidth =
          (totalWidth - gap) * shotFlex / (shotFlex + textFlex);
      final textWidth = totalWidth - gap - carouselWidth;
      final shotHeight = carouselWidth * 9 / 16;
      final panelHeight = shotHeight + 2;
      // 「简介」小标题已由大顶标 Introduction 取代
      const titleGap = 0.0;
      final firstAreaHeight = panelHeight - titleGap;

      if (firstAreaHeight < 24) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            carousel,
            const SizedBox(height: 12),
            Text(desc, style: _descStyle),
          ],
        );
      }

      final parts =
          _splitDescriptionForLShape(desc, textWidth, firstAreaHeight, _descStyle);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: textFlex,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (parts[0].isNotEmpty)
                      Text(parts[0], style: _descStyle),
                  ],
                ),
              ),
              const SizedBox(width: gap),
              Expanded(flex: shotFlex, child: carousel),
            ],
          ),
          if (parts[1].isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(parts[1], style: _descStyle),
          ],
        ],
      );
    });
  }

  TextStyle get _descStyle => TextStyle(
        fontFamily: AppStyles.uiFontFamily,
        fontSize: 15,
        height: 1.7,
        color: BpmColors.textSecondary,
      );

  /// 按可用高度把简介切成两段，实现 L 型环绕排版（桌面同款 TextPainter 算法）
  List<String> _splitDescriptionForLShape(
      String text, double width, double maxHeight, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

    final lines = painter.computeLineMetrics();
    double usedHeight = 0;
    int fitLines = 0;
    for (final line in lines) {
      if (usedHeight + line.height <= maxHeight + 0.5) {
        usedHeight += line.height;
        fitLines++;
      } else {
        break;
      }
    }

    if (fitLines >= lines.length) return [text, ''];
    if (fitLines == 0) return ['', text];

    final pos = painter.getPositionForOffset(Offset(width, usedHeight - 1));
    var end = pos.offset;
    if (end <= 0) return ['', text];
    if (end >= text.length) return [text, ''];
    return [text.substring(0, end), text.substring(end)];
  }

  void _showScreenshotViewer(int initialIndex) {
    final shots = widget.game.screenshotFiles;
    if (shots.isEmpty) return;
    showDialog(
      context: context,
      barrierColor: BpmColors.deepBase.withOpacity(0.94),
      builder: (_) => _BpmLightbox(
        metaDataDir: widget.game.metaDataDir,
        shots: shots,
        initialIndex: initialIndex,
      ),
    );
  }

  // ============ ③ 游玩统计 ============

  Widget _buildStatsRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _statItem('游玩时长', _formatPlayTime(widget.game.playTime)),
        ),
        Expanded(
          child: _statItem('启动次数', '$_launchCount 次'),
        ),
        Expanded(
          child: _statItem(
            '上次游玩',
            widget.game.lastOpenedAt.isNotEmpty
                ? _formatDate(widget.game.lastOpenedAt)
                : '未游玩',
          ),
        ),
        Expanded(child: _buildStatusStat()),
      ],
    );
  }

  Widget _statItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 13,
            color: BpmColors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: BpmColors.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusStat() {
    final status = widget.game.playStatus;
    final color = _statusColor(status);
    const values = PlayStatus.values;
    final next = values[(values.indexOf(status) + 1) % values.length];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '游玩状态',
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 13,
            color: BpmColors.textMuted,
          ),
        ),
        const SizedBox(height: 5),
        BpmInteractiveWrapper(
          onTap: _cyclePlayStatus,
          requestFocusOnTap: true,
          semanticsLabel: '游玩状态：${status.label}，点击切换为${next.label}',
          borderRadius: BorderRadius.circular(10),
          child: Tooltip(
            message: '点击切换游玩状态',
            waitDuration: const Duration(milliseconds: 400),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: color.withOpacity(0.14),
                border: Border.all(color: color.withOpacity(0.5), width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: color),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      status.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.swap_horiz_rounded, size: 15, color: color),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Color _statusColor(PlayStatus status) => switch (status) {
        PlayStatus.notStarted => BpmColors.textMuted,
        PlayStatus.inProgress => BpmColors.mistBlue,
        PlayStatus.completed => const Color(0xFF9FE6B8),
        PlayStatus.dropped => const Color(0xFFD9A066),
      };

  // ============ ④ 底部按钮行 ============

  /// PN 同款按钮行（v3.17 统一规格重做）：
  ///   游玩（160x44 透明描边 + 左上角 M / L 指示灯）→ 手柄 → ⋯（拉出菜单）
  ///   → 背景（其正上方为声音拉杆）→ 播放（其正上方为隐藏 UI 按钮）。
  ///
  /// 🔴 v3.17: **所有按钮同高 44**、方形 + 圆角 + 图标（游玩多文字但同规格）；
  ///    游玩不再用渐变底 —— 透明底 + 细亮边，与其它钮同一设计语言；
  ///    声音改为**拉杆式开关**且只在游戏有背景视频时出现（与播放同规则），
  ///    挂在背景按钮正上方（与「隐藏钮在播放上方」同构的卫星位）。
  ///    整行仍用 [FittedBox] scaleDown：窄窗口等比缩小而不是溢出。
  Widget _buildBottomBar() {
    final hasVideo = widget.onReplayOp != null;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.bottomLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // ── 游玩按钮 + 其左上角的两个启动模式指示灯 ──
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _modeLight(
                    letter: 'M',
                    label: '超分启动开关（Magpie）',
                    active: _upscalingMode == 'magpie',
                    activeColor: BpmColors.cherryRose,
                    onTap: _toggleUpscaling,
                  ),
                  const SizedBox(width: 5),
                  _modeLight(
                    letter: 'L',
                    label: '转区启动开关（Locale Emulator）',
                    active: _localeMode == 'japanese',
                    activeColor: BpmColors.mistBlue,
                    onTap: _toggleLocale,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _PnButton(
                icon: Icons.play_arrow_rounded,
                semantics: '启动 ${widget.game.title}',
                label: '游玩',
                width: 160,
                focusNode: widget.primaryFocusNode,
                onTap: widget.onLaunch,
              ),
            ],
          ),
          const SizedBox(width: 8),
          // ── 手柄（与主页原「手柄」按钮同链路：每游戏开关 / 预设 / 自定义映射）──
          _PnButton(
            icon: Icons.sports_esports_rounded,
            semantics: '手柄映射配置',
            onTap: widget.onOpenGamepadConfig,
          ),
          const SizedBox(width: 8),
          // ── ⋯ 拉出菜单（编辑 / 目录 / 删除）──
          _PnButton(
            key: _menuAnchorKey,
            icon: Icons.more_horiz_rounded,
            semantics: '更多操作',
            active: _menuOpen,
            onTap: _toggleMenu,
          ),
          const SizedBox(width: 8),
          // ── 背景（其正上方为声音拉杆：有背景视频才出现）──
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (hasVideo) ...[
                _SoundToggle(
                  muted: widget.soundMuted,
                  onToggle: widget.onToggleSound,
                ),
                const SizedBox(height: 6),
              ],
              _PnButton(
                icon: Icons.wallpaper_rounded,
                semantics: '背景图与背景视频管理',
                onTap: widget.onBackdropTune,
              ),
            ],
          ),
          const SizedBox(width: 8),
          // ── 播放（有视频才出现；其正上方为隐藏 UI 按钮）──
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _hideUiButton(),
              const SizedBox(height: 6),
              if (hasVideo)
                _PnButton(
                  icon: Icons.play_circle_outline_rounded,
                  semantics: '重播背景 OP 视频',
                  onTap: widget.onReplayOp!,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 轻量「指示灯」式启动模式开关（M = 超分 / L = 转区）
  Widget _modeLight({
    required String letter,
    required String label,
    required bool active,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return BpmInteractiveWrapper(
      onTap: onTap,
      requestFocusOnTap: true,
      semanticsLabel: label,
      borderRadius: BorderRadius.circular(11),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? activeColor.withOpacity(0.30)
                : BpmColors.deepBase.withOpacity(0.45),
            border: Border.all(
              color: active ? activeColor : BpmColors.micaBorder,
              width: active ? 1.4 : 1,
            ),
            boxShadow: active
                ? [BoxShadow(color: activeColor.withOpacity(0.45), blurRadius: 10)]
                : null,
          ),
          child: Center(
            child: Text(
              letter,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: active ? activeColor : BpmColors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 隐藏 UI 按钮（位于「播放」按钮正上方）
  Widget _hideUiButton() {
    return BpmInteractiveWrapper(
      onTap: widget.onToggleUiHidden,
      requestFocusOnTap: true,
      semanticsLabel: '隐藏界面（欣赏背景）',
      borderRadius: BorderRadius.circular(10),
        child: Tooltip(
          message: '隐藏界面，欣赏背景',
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            // v3.18: 与下方 60 宽按钮列对齐
            width: 60,
            height: 24,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: BpmColors.deepBase.withOpacity(0.45),
            border: Border.all(color: Colors.white.withOpacity(0.30)),
          ),
          child: Icon(Icons.visibility_off_outlined,
              size: 14, color: BpmColors.textMuted),
        ),
      ),
    );
  }

  // ============ 工具 ============

  String _formatPlayTime(int seconds) {
    if (seconds <= 0) return '未游玩';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) return '$hours 小时 $minutes 分钟';
    if (hours > 0) return '$hours 小时';
    return '$minutes 分钟';
  }

  String _formatDate(String raw) {
    final dt =
        DateTime.tryParse(raw) ?? DateTime.tryParse(raw.split(' ').first);
    if (dt == null) return raw.split(' ').first;
    return '${dt.year}/${dt.month}/${dt.day}';
  }
}

/// Layer 1：基础暗色体积遮罩（《详情面板设计.md》）
///
/// 左→右：深黑 0.95 → 半透明灰 0.0，**尾段衰减非常平缓**；
/// 颜色取自 BPM 调色板（深色 = 深夜蓝黑，浅色 = 晨白），两套主题各自成立。
class _BaseMask extends StatelessWidget {
  const _BaseMask();

  @override
  Widget build(BuildContext context) {
    final base = BpmColors.deepBase;
    final mist = BpmColors.deepPanel;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: const [0.0, 0.50, 0.68, 0.85, 1.0],
          colors: [
            base.withOpacity(0.95),
            base.withOpacity(0.90),
            base.withOpacity(0.62),
            mist.withOpacity(0.28),
            mist.withOpacity(0.0),
          ],
        ),
      ),
    );
  }
}

/// Layer 2：右缘**非规则晕染**（Edge Dissolve）。
///
/// 《详情面板设计.md》要求边缘「模糊、有机、非几何切割」——这里用一串
/// **固定伪随机**（同尺寸同图案，不随帧抖动）的大小/浓度各异的径向柔光斑
/// 沿遮罩右缘铺开，打破线性渐变的规律感；等价于文档建议的
/// 「ShaderMask + blur / 噪点纹理」要达成的有机边缘，且没有 GPU 模糊开销。
class _EdgeDissolvePainter extends CustomPainter {
  final double edgeX;
  final double extent;
  final double height;
  final Color color;

  const _EdgeDissolvePainter({
    required this.edgeX,
    required this.extent,
    required this.height,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    void blob(Offset center, double radius, double strength) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withOpacity(strength),
            color.withOpacity(strength * 0.55),
            color.withOpacity(strength * 0.22),
            color.withOpacity(0.0),
          ],
          stops: const [0.0, 0.42, 0.72, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    // 固定种子伪随机（LCG）：同尺寸 → 同图案，避免每帧重绘闪烁
    var seed = 0x5EED;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    const count = 16;
    final step = height / count;
    for (var i = 0; i <= count; i++) {
      final r = extent * (0.34 + rnd() * 0.85);
      final cx = edgeX + (rnd() - 0.35) * extent * 0.35;
      final cy = i * step + (rnd() - 0.5) * step * 0.9;
      blob(Offset(cx, cy), r, 0.06 + rnd() * 0.12);
    }
    // 内侧两团更淡的大斑：让暗区内部也有「体积」而非平涂
    blob(Offset(edgeX * 0.62, height * 0.30), extent * 1.15, 0.05);
    blob(Offset(edgeX * 0.55, height * 0.78), extent * 1.35, 0.045);
  }

  @override
  bool shouldRepaint(covariant _EdgeDissolvePainter old) {
    return old.edgeX != edgeX ||
        old.extent != extent ||
        old.height != height ||
        old.color != color;
  }
}

/// PN 式描边按钮（透明底 + 细亮边 + 圆角 10）。
///
/// 🔴 鼠标悬停 / 键盘手柄选中时的高亮色 = 「游玩」按钮的调色（cherryRose）：
/// 用自身的 [MouseRegion] + `onFocusChange` 驱动装饰，并把
/// [BpmInteractiveWrapper] 的焦点环关掉（避免双高亮打架）。
/// 可选 [label]（如「手柄」）时为自适应宽度的胶囊行，否则为 [size] 见方的方钮。
class _PnButton extends StatefulWidget {
  const _PnButton({
    super.key,
    required this.icon,
    required this.semantics,
    required this.onTap,
    this.label,
    this.width,
    this.focusNode,
    this.active = false,
  });

  final IconData icon;
  final String semantics;
  final VoidCallback onTap;

  /// 文字标签（如「游玩」）。null = 纯图标方钮。
  final String? label;

  /// 固定宽度（null = 自适应：方钮 44 / 带文字自适应胶囊）。
  final double? width;

  /// 焦点节点（「游玩」是 shell 两段式 A 键的落点，需挂 shell 的节点）。
  final FocusNode? focusNode;

  /// 常亮态（如「菜单已打开」）→ 用高亮色描边提示
  final bool active;

  @override
  State<_PnButton> createState() => _PnButtonState();
}

class _PnButtonState extends State<_PnButton> {
  bool _hover = false;
  bool _focus = false;

  bool get _active => widget.active || _hover || _focus;

  @override
  Widget build(BuildContext context) {
    final hasLabel = widget.label != null;
    return BpmInteractiveWrapper(
      onTap: widget.onTap,
      requestFocusOnTap: true,
      focusNode: widget.focusNode,
      focusRing: false,
      semanticsLabel: widget.semantics,
      borderRadius: BorderRadius.circular(10),
      onFocusChange: (f) => setState(() => _focus = f),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          height: 44,
          // v3.18: 方钮统一宽 60（此前 width=null → 只有图标的 20px 宽，过窄）
          width: widget.width ?? (hasLabel ? null : 60),
          padding: hasLabel && widget.width == null
              ? const EdgeInsets.symmetric(horizontal: 14)
              : EdgeInsets.zero,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _active
                ? BpmColors.cherryRose.withOpacity(0.16)
                : BpmColors.deepBase.withOpacity(0.45),
            border: Border.all(
              color: _active
                  ? BpmColors.cherryRose.withOpacity(0.85)
                  : Colors.white.withOpacity(0.30),
            ),
          ),
          child: hasLabel
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon,
                        size: 20,
                        color: _active
                            ? BpmColors.cherryRose
                            : BpmColors.textSecondary),
                    const SizedBox(width: 8),
                    Text(
                      widget.label!,
                      style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 15,
                        color: _active
                            ? BpmColors.cherryRose
                            : BpmColors.textSecondary,
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Icon(widget.icon,
                      size: 20,
                      color: _active
                          ? BpmColors.cherryRose
                          : BpmColors.textSecondary),
                ),
        ),
      ),
    );
  }
}

/// 🔊/🔇 拉杆式声音开关（v3.17）。
///
/// 设计目标：轻量、直观、美观 —— 44x24 胶囊滑杆（与「隐藏 UI」卫星钮同
/// 规格），滑块带弹簧滑动；**开声 = 滑块居右 + mistBlue 高亮**，静音 =
/// 滑块居左 + 灰底。状态图标永远出现在滑块对侧（开声时左侧 🔊 / 静音时
/// 右侧 🔇），一眼可读。仅当游戏有背景视频时渲染（与「播放」同规则），
/// 位于「背景」按钮正上方（与「隐藏钮在播放上方」同构的卫星位）。
class _SoundToggle extends StatefulWidget {
  const _SoundToggle({required this.muted, required this.onToggle});

  final bool muted;
  final VoidCallback onToggle;

  @override
  State<_SoundToggle> createState() => _SoundToggleState();
}

class _SoundToggleState extends State<_SoundToggle> {
  bool _hover = false;
  bool _focus = false;

  bool get _hot => _hover || _focus;
  bool get _on => !widget.muted;

  @override
  Widget build(BuildContext context) {
    final label = widget.muted ? '开启背景声音' : '静音背景声音';
    return BpmInteractiveWrapper(
      onTap: widget.onToggle,
      requestFocusOnTap: true,
      focusRing: false,
      semanticsLabel: label,
      borderRadius: BorderRadius.circular(12),
      onFocusChange: (f) => setState(() => _focus = f),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Tooltip(
          message: label,
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            // v3.18: 与背景按钮（60）同宽
            width: 60,
            height: 24,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: _on
                  ? BpmColors.mistBlue.withOpacity(0.30)
                  : (_hot
                      ? BpmColors.cherryRose.withOpacity(0.14)
                      : BpmColors.deepBase.withOpacity(0.45)),
              border: Border.all(
                color: _on
                    ? BpmColors.mistBlue.withOpacity(0.70)
                    : (_hot
                        ? BpmColors.cherryRose.withOpacity(0.80)
                        : Colors.white.withOpacity(0.30)),
              ),
            ),
            child: Stack(
              children: [
                // 状态图标：永远在滑块对侧
                Positioned(
                  left: _on ? 6 : null,
                  right: _on ? null : 6,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Icon(
                      widget.muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      size: 12,
                      color: _on ? BpmColors.mistBlue : BpmColors.textMuted,
                    ),
                  ),
                ),
                // 滑块
                AnimatedAlign(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  alignment:
                      widget.muted ? Alignment.centerLeft : Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _on
                            ? BpmColors.mistBlue
                            : BpmColors.textMuted.withOpacity(0.55),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「⋯」拉出菜单面板（编辑 / 打开游戏目录 / 删除游戏）。
///
/// 🔴 v3.14：不再是路由弹窗 —— 由页面在自身 Stack 内锚定到 ⋯ 按钮正上方，
/// 焦点域仍在详情内（手柄方向移动 / A 激活照常），B 由 shell 交给
/// `_detailMenuOpen` 处理（只关菜单不关详情）。菜单外点击 = 只关菜单。
class _DetailMenuPanel extends StatelessWidget {
  const _DetailMenuPanel({
    required this.gameTitle,
    required this.onEdit,
    required this.onOpenDirectory,
    required this.onDelete,
  });

  final String gameTitle;
  final VoidCallback onEdit;
  final VoidCallback onOpenDirectory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: BpmColors.menuSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BpmColors.micaBorder, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _item(Icons.edit_note_rounded, '编辑信息', onEdit, autofocus: true),
          _item(Icons.folder_open_rounded, '打开游戏目录', onOpenDirectory),
          _item(Icons.delete_outline_rounded, '删除游戏', onDelete,
              danger: true),
        ],
      ),
    );
  }

  Widget _item(
    IconData icon,
    String label,
    VoidCallback action, {
    bool autofocus = false,
    bool danger = false,
  }) {
    final color = danger ? BpmColors.dangerAccent : BpmColors.textSecondary;
    return BpmInteractiveWrapper(
      onTap: action,
      autofocus: autofocus,
      semanticsLabel: label,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 13.5,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// BPM 截图滚页图：PageView 轮播 + 左右箭头 + 图上指示点。
/// 单击任意一页 → 全屏 [_BpmLightbox]。
class _BpmShotCarousel extends StatefulWidget {
  final String metaDataDir;
  final List<String> shots; // 相对 metaDataDir 的文件名
  final ValueChanged<int> onView;

  const _BpmShotCarousel({
    required this.metaDataDir,
    required this.shots,
    required this.onView,
  });

  @override
  State<_BpmShotCarousel> createState() => _BpmShotCarouselState();
}

class _BpmShotCarouselState extends State<_BpmShotCarousel> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    if (widget.shots.length < 2 || !_controller.hasClients) return;
    final next = (_index + delta).clamp(0, widget.shots.length - 1);
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shots = widget.shots;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BpmColors.micaBorder, width: 1),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: shots.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final abs = '${widget.metaDataDir}/${shots[i]}';
                // NSFW 铁律: 截图属内容图 contentKind: image
                return BpmInteractiveWrapper(
                  onTap: () => widget.onView(i),
                  semanticsLabel: '查看截图 ${i + 1}',
                  child: NsfwImage.file(
                    abs,
                    contentKind: NsfwContentKind.image,
                    fit: BoxFit.cover,
                    decodeWidth: 420,
                    child: Image.file(
                      File(abs),
                      fit: BoxFit.cover,
                      cacheWidth: 420,
                      errorBuilder: (_, __, ___) => Container(
                        color: BpmColors.deepBase,
                        child: Icon(Icons.broken_image_outlined,
                            size: 28, color: BpmColors.textMuted),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (shots.length > 1) ...[
              if (_index > 0) _arrow(forward: false),
              if (_index < shots.length - 1) _arrow(forward: true),
              Positioned(
                left: 0,
                right: 0,
                bottom: 5,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < shots.length; i++)
                      Container(
                        width: i == _index ? 9 : 3.5,
                        height: 3.5,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: i == _index
                              ? BpmColors.mistBlue
                              : Colors.white.withOpacity(0.4),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _arrow({required bool forward}) {
    return Positioned(
      left: forward ? null : 4,
      right: forward ? 4 : null,
      top: 0,
      bottom: 0,
      child: Center(
        child: BpmInteractiveWrapper(
          onTap: () => _go(forward ? 1 : -1),
          requestFocusOnTap: true,
          semanticsLabel: forward ? '下一张截图' : '上一张截图',
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: BpmColors.deepBase.withOpacity(0.55),
              border: Border.all(color: BpmColors.micaBorder, width: 1),
            ),
            child: Icon(
              forward
                  ? Icons.chevron_right_rounded
                  : Icons.chevron_left_rounded,
              size: 16,
              color: BpmColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// BPM 截图全屏查看器：多图翻页 + 键盘方向键 + 双击 / ESC / × 关闭。
class _BpmLightbox extends StatefulWidget {
  final String metaDataDir;
  final List<String> shots;
  final int initialIndex;

  const _BpmLightbox({
    required this.metaDataDir,
    required this.shots,
    required this.initialIndex,
  });

  @override
  State<_BpmLightbox> createState() => _BpmLightboxState();
}

class _BpmLightboxState extends State<_BpmLightbox> {
  late int _index = widget.initialIndex.clamp(0, widget.shots.length - 1);

  void _close() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || !route.isActive) return;
    Navigator.of(context).pop();
  }

  void _go(int delta) {
    if (widget.shots.length < 2) return;
    setState(() {
      _index = (_index + delta) % widget.shots.length;
      if (_index < 0) _index += widget.shots.length;
    });
  }

  String get _absPath => '${widget.metaDataDir}/${widget.shots[_index]}';

  @override
  Widget build(BuildContext context) {
    final hasMultiple = widget.shots.length > 1;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(32),
      child: Focus(
        autofocus: true,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _close,
            if (hasMultiple) ...{
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _go(-1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _go(1),
            },
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Spacer(),
                  if (hasMultiple)
                    Text(
                      '${_index + 1} / ${widget.shots.length}',
                      style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 12.5,
                        color: BpmColors.textMuted,
                      ),
                    ),
                  if (hasMultiple) const SizedBox(width: 12),
                  BpmInteractiveWrapper(
                    onTap: _close,
                    requestFocusOnTap: true,
                    semanticsLabel: '关闭截图预览',
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: BpmColors.deepBase.withOpacity(0.55),
                        border:
                            Border.all(color: BpmColors.micaBorder, width: 1),
                      ),
                      child: Icon(Icons.close_rounded,
                          size: 18, color: BpmColors.textSecondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: GestureDetector(
                  onDoubleTap: _close,
                  child: InteractiveViewer(
                    maxScale: 4,
                    // NSFW 铁律: 截图属内容图 contentKind: image
                    child: NsfwImage.file(
                      _absPath,
                      contentKind: NsfwContentKind.image,
                      fit: BoxFit.contain,
                      decodeWidth: 1920,
                      child: Image.file(
                        File(_absPath),
                        fit: BoxFit.contain,
                        cacheWidth: 1920,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.broken_image_outlined,
                          size: 48,
                          color: BpmColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (hasMultiple)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _lbArrow(false),
                      const SizedBox(width: 18),
                      BpmInteractiveWrapper(
                        onTap: () => _go(1),
                        requestFocusOnTap: true,
                        semanticsLabel: '下一张截图',
                        borderRadius: BorderRadius.circular(17),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(17),
                            color: BpmColors.deepBase.withOpacity(0.55),
                            border: Border.all(
                                color: BpmColors.micaBorder, width: 1),
                          ),
                          child: Text(
                            '下一张',
                            style: TextStyle(
                              fontFamily: AppStyles.uiFontFamily,
                              fontSize: 12,
                              color: BpmColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      _lbArrow(true),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lbArrow(bool forward) {
    return BpmInteractiveWrapper(
      onTap: () => _go(forward ? 1 : -1),
      requestFocusOnTap: true,
      semanticsLabel: forward ? '下一张截图' : '上一张截图',
      borderRadius: BorderRadius.circular(17),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: BpmColors.deepBase.withOpacity(0.55),
          border: Border.all(color: BpmColors.micaBorder, width: 1),
        ),
        child: Icon(
          forward ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
          size: 20,
          color: BpmColors.textSecondary,
        ),
      ),
    );
  }
}
