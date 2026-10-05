import 'dart:math';

import 'package:flutter/material.dart';

import '../../models/game_model.dart';
import '../../services/discover_metadata_service.dart';
import '../../services/local_game_registry.dart';
import '../../services/update/update_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../../widgets/game_detail_dialog.dart';
import '../interactive_wrapper.dart';
import 'docs_my_tab.dart';
import 'docs_publish_tab.dart';
import 'hall_cover_image.dart';
import 'hall_section_shell.dart';
import 'hall_visuals.dart';

/// 板块⑥：文档与趣味
///
/// 左侧：介绍 / 使用说明 / 通知 / 动态 四个 tab（一期本地静态，动态占位）；
/// 右侧：「随机一作」——从本地库 + 探索库随机抽一部作品。
class DocsSection extends StatefulWidget {
  /// 本地库随机池（默认 LocalGameRegistry.instance.allGames；测试可注入空池）
  final List<LibraryGame> Function()? localPool;

  /// 探索库随机池（按需读取，避免监听整表刷新）
  final List<GameModel> Function()? discoverPool;

  /// 探索库元数据读取（评分展示用）
  final DiscoverGameMetadata? Function(String gameId)? discoverMetadataOf;

  /// 本地库启动（透传 main_container._onLaunchGame）
  final void Function(String gameTitle)? onLaunchGame;

  /// 「进探索库看看」（切到探索库页）
  final VoidCallback? onEnterLibrary;

  /// 通知文本加载（测试注入；默认走 UpdateService 的 version.json 更新日志）
  final Future<String> Function()? noticeLoader;

  /// 【发布】第 1 步判重**命中**时，跳转到该作品的探索详情页
  /// （详情页里有【上传】入口 —— 即"已有作品"那一类投稿）
  final void Function(GameModel game)? onOpenDiscoverGame;

  const DocsSection({
    super.key,
    this.localPool,
    this.discoverPool,
    this.discoverMetadataOf,
    this.onLaunchGame,
    this.onEnterLibrary,
    this.noticeLoader,
    this.onOpenDiscoverGame,
  });

  @override
  State<DocsSection> createState() => _DocsSectionState();
}

enum _RandomSource { none, local, discover }

class _DocsSectionState extends State<DocsSection> {
  final Random _random = Random();
  LibraryGame? _localPick;
  GameModel? _discoverPick;
  _RandomSource _source = _RandomSource.none;
  Future<String>? _noticeFuture;

  @override
  void initState() {
    super.initState();
    _noticeFuture = _loadNotice();
  }

  Future<String> _loadNotice() async {
    final loader = widget.noticeLoader;
    if (loader != null) return loader();
    try {
      final result = await UpdateService.instance
          .checkForUpdate(silent: true)
          .timeout(const Duration(seconds: 10));
      final log = result.versionInfo?.updateLog.trim() ?? '';
      return log.isNotEmpty ? log : '暂无新通知，一切运行正常。';
    } catch (_) {
      return '通知获取失败（离线？），稍后自动重试。';
    }
  }

  void _roll() {
    final local = widget.localPool?.call() ?? LocalGameRegistry.instance.allGames;
    final discover = widget.discoverPool?.call() ?? const <GameModel>[];
    final hasLocal = local.isNotEmpty;
    final hasDiscover = discover.isNotEmpty;
    if (!hasLocal && !hasDiscover) {
      setState(() => _source = _RandomSource.none);
      return;
    }
    // 两池 50/50 优先选择，空池落到另一边
    final preferLocal = hasLocal && (!hasDiscover || _random.nextBool());
    setState(() {
      if (preferLocal) {
        _localPick = local[_random.nextInt(local.length)];
        _discoverPick = null;
        _source = _RandomSource.local;
      } else {
        _discoverPick = discover[_random.nextInt(discover.length)];
        _localPick = null;
        _source = _RandomSource.discover;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return HallSectionShell(
      title: '文档与趣味',
      subtitle: '玩法 · 通知 · 随机一作',
      icon: Icons.description_rounded,
      iconAccent: AppColors.titleBrown,
      engCaption: 'DOCS & FUN',
      child: LayoutBuilder(
        builder: (context, c) {
          // 右区宽度：40%（用户要求加大占比），小窗口兜底 150px——
          // 960×540 时左区分段胶囊行需 ~190px，右区最大只能给 ~168px，
          // 物理上无法再大；1280 起即达 40% 比例。上限 47% 防止极端宽比。
          final rightWidth =
              (c.maxWidth * 0.40).clamp(150.0, c.maxWidth * 0.47);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左：文档阅读区（Tab 栏 + 说明文本）
              Expanded(child: _buildDocsTabs()),
              const SizedBox(width: 12),
              // 竖直分隔线：阅读区 | 趣味功能区
              Container(
                width: 1,
                margin: const EdgeInsets.symmetric(vertical: 4),
                color:
                    (AppColors.isDark ? Colors.white : AppColors.titleBrown)
                        .withOpacity(0.08),
              ),
              const SizedBox(width: 12),
              // 右：随机一作独立子容器
              SizedBox(width: rightWidth, child: _buildRandomPanel()),
            ],
          );
        },
      ),
    );
  }

  // ---------- 左侧文档 tabs（自绘分段胶囊，替代默认 TabBar） ----------

  /// 「介绍」与「使用说明」合并为一个入口（2026-10-02 UI 优化）：
  /// 顶部 5 个胶囊在大分辨率下单行放得下；两者的切换收进合并 tab 内部的
  /// 二级分段胶囊（参考【我的】面板的「我的作品/我的资源」二级设计）。
  static const List<String> _tabLabels = ['介绍', '通知', '发布', '我的', '动态'];
  int _docsTab = 0;

  /// 合并 tab 内部的二级切换：0 = 介绍，1 = 使用说明
  int _introSubTab = 0;

  /// 已访问过的 tab 下标：IndexedStack 会构建全部 child，
  /// 而【发布】【我的】首次构建就要发网络请求 ⇒ 未访问前先占位，
  /// 访问过之后一直保留（保持 IndexedStack 的保活语义）。
  final Set<int> _visitedTabs = {0};

  /// 用于【发布】成功后主动刷新【我的】列表（IndexedStack 保活，不刷新会过期）
  final GlobalKey<DocsMyTabState> _myTabKey = GlobalKey<DocsMyTabState>();

  Widget _buildDocsTabs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ⚠️ 必须是 Wrap 不是 Row：左区内容宽度在最小窗口（960×540，
        // main.dart:488）下仅 ≈194px，而 5 个标签单行需 ≈225px。
        // 用 Row 会直接溢出（此前 4 个标签刚好占满 ~190px，是新增
        // 【发布】【我的】两个 tab 触发的边界，属回归风险点）。
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (var i = 0; i < _tabLabels.length; i++)
              _SegmentPill(
                key: ValueKey('docsTab_$i'),
                label: _tabLabels[i],
                selected: _docsTab == i,
                onTap: () => setState(() {
                  _docsTab = i;
                  _visitedTabs.add(i);
                  // 切回【我的】时刷新一次（含重新登录后回来的场景）
                  if (i == 3) _myTabKey.currentState?.reload();
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          // IndexedStack 保活：通知页的 FutureBuilder 不因切 tab 重建
          child: IndexedStack(
            index: _docsTab,
            children: [
              _buildIntroGuideTab(),
              _buildNoticeTab(),
              // ③【发布】发布三步的**第 1 步（判重）完全在本板块内完成**（§8.7②）
              if (_visitedTabs.contains(2))
                DocsPublishTab(
                  onOpenDiscoverGame: widget.onOpenDiscoverGame,
                  onPublished: () => _myTabKey.currentState?.reload(),
                )
              else
                const SizedBox.shrink(),
              // ④【我的】我发布的游戏 + 我上传的资源（§8.8）
              if (_visitedTabs.contains(3))
                DocsMyTab(
                  key: _myTabKey,
                  onOpenDiscoverGame: widget.onOpenDiscoverGame,
                )
              else
                const SizedBox.shrink(),
              Center(
                child: Text('用户动态 · 敬请期待（二期上线）',
                    style: AppStyles.microCaption),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 合并入口：顶部二级胶囊（介绍 / 使用说明）+ 内容区。
  /// 文本均为本地静态字符串，无需保活，条件渲染即可。
  Widget _buildIntroGuideTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            _SegmentPill(
              label: '介绍',
              selected: _introSubTab == 0,
              onTap: () => setState(() => _introSubTab = 0),
            ),
            _SegmentPill(
              label: '使用说明',
              selected: _introSubTab == 1,
              onTap: () => setState(() => _introSubTab = 1),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _scrollableText(_introSubTab == 0 ? _introText : _guideText),
        ),
      ],
    );
  }

  Widget _scrollableText(String text) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      child: Text(text, style: AppStyles.bodySmall),
    );
  }

  Widget _buildNoticeTab() {
    return FutureBuilder<String>(
      future: _noticeFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.brandBlue),
            ),
          );
        }
        return _scrollableText(snap.data ?? '暂无新通知。');
      },
    );
  }

  static const String _introText = '探索大厅是 Chrono Tide 的发现入口：发售月历帮你追新番档期，今日推荐按评分与热度每日轮换，'
      '系列合集与常用站点方便快速导航。\n\n'
      '本管理器定位为本地游戏管理工具：探索库仅展示云端公开索引信息（评分、发售日、标签等），'
      '不托管、不分发任何游戏本体；下载需用户主动发起，请理性消费、支持正版。';

  static const String _guideText = '· 月历：点日期查看当天发售的作品，点「待定」看暂无发售日的作品；\n'
      '· 数据补全：发售日由后台逐步整理，首次会较慢，之后秒开；\n'
      '· 常用站点：可自由添加/编辑，点击卡片直达浏览器；\n'
      '· 随机一作：选不出来就摇一个，本地库与探索库各有一半机会；\n'
      '· 「开始探索」：进入完整探索库浏览与搜索。';

  // ---------- 右侧随机一作（独立子容器，内嵌悬浮小卡片） ----------

  Widget _buildRandomPanel() {
    return Container(
      key: const Key('docsRandomPanel'),
      padding: const EdgeInsets.all(10),
      decoration: HallDecor.panel.copyWith(
        // 内嵌悬浮感：比面板更明显一点的柔和投影
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowColor
                .withOpacity(AppColors.isDark ? 0.25 : 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 主操作按钮：通栏胶囊——柔和（淡底+主色描边+主色字）但点击区
          // 够大，配合图标圆徽让功能更突出（不用渐变/辉光，避免在窄栏突兀）
          _rollButton(),
          const SizedBox(height: 5),
          // 抽签结果：撑满子容器剩余高度，按真实尺寸渲染（不缩放）
          Expanded(child: _buildPickCard()),
        ],
      ),
    );
  }

  /// 主操作按钮：柔和的强化胶囊（主色淡底 + 描边 + 图标圆徽）
  Widget _rollButton() {
    return InteractiveWrapper(
      onTap: _roll,
      hoverScale: 1.02,
      child: Container(
        height: 24,
        decoration: BoxDecoration(
          color: AppColors.brandBlue.withOpacity(0.14),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.brandBlue.withOpacity(0.45)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.brandBlue.withOpacity(0.18),
              ),
              child: Icon(Icons.casino_rounded,
                  size: 10, color: AppColors.brandBlue),
            ),
            const SizedBox(width: 5),
            Text('随机一作',
                style: AppStyles.microCaption.copyWith(
                  color: AppColors.brandBlue,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildPickCard() {
    switch (_source) {
      case _RandomSource.none:
        return const HallEmptyHint(
          text: '抽一部今天玩什么',
          icon: Icons.casino_rounded,
        );
      case _RandomSource.local:
        return _buildLocalPick();
      case _RandomSource.discover:
        return _buildDiscoverPick();
    }
  }

  Widget _buildLocalPick() {
    final g = _localPick!;
    return _PickCardShell(
      cover: HallCoverImage(filePath: g.coverUrl),
      title: g.title,
      sourceLabel: '本地库',
      sourceColor: AppColors.successGreen,
      subtitle: g.developer,
      actions: [
        _MiniAction(
          label: '启动',
          icon: Icons.play_arrow_rounded,
          onTap: () => widget.onLaunchGame?.call(g.title),
        ),
        _MiniAction(
          label: '详情',
          icon: Icons.info_outline_rounded,
          onTap: () => GameDetailDialog.show(
            context: context,
            directoryPath: g.directoryPath,
          ),
        ),
      ],
    );
  }

  Widget _buildDiscoverPick() {
    final g = _discoverPick!;
    final meta = widget.discoverMetadataOf?.call(g.id);
    return _PickCardShell(
      cover: HallCoverImage(networkUrl: g.coverUrl),
      title: g.title,
      sourceLabel: '探索库',
      sourceColor: AppColors.brandBlue,
      subtitle: meta?.developer ?? g.developer,
      rating: meta?.rating,
      actions: [
        _MiniAction(
          label: '进库查看',
          icon: Icons.explore_rounded,
          onTap: () => widget.onEnterLibrary?.call(),
        ),
      ],
    );
  }
}

/// 随机结果卡片：封面 + 标题 + 来源徽标 + 动作行
class _PickCardShell extends StatelessWidget {
  final Widget cover;
  final String title;
  final String sourceLabel;
  final Color sourceColor;
  final String subtitle;
  final double? rating;
  final List<Widget> actions;

  const _PickCardShell({
    required this.cover,
    required this.title,
    required this.sourceLabel,
    required this.sourceColor,
    required this.subtitle,
    required this.actions,
    this.rating,
  });

  @override
  Widget build(BuildContext context) {
    // 杂志感：封面撑满子上剩余高度（横幅）+ 底部渐变压字，
    // 信息全部压在封面上，底部只留动作行——高度预算有限时的最优形态
    return Container(
      decoration: BoxDecoration(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.045)
            : Colors.white.withOpacity(0.55),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: AppColors.isDark
              ? Colors.white.withOpacity(0.07)
              : AppColors.titleBrown.withOpacity(0.12),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                cover,
                const Positioned.fill(
                  child: DecoratedBox(
                      decoration:
                          BoxDecoration(gradient: HallGradients.coverScrim)),
                ),
                // 来源徽标（左上）
                Positioned(
                  left: 6,
                  top: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: sourceColor.withOpacity(0.30),
                      borderRadius: BorderRadius.circular(AppRadius.xs + 1),
                    ),
                    child: Text(sourceLabel,
                        style: AppStyles.microCaption.copyWith(
                            color: Colors.white, fontSize: 8.5)),
                  ),
                ),
                // 评分（右上）
                if (rating != null && rating! > 0)
                  Positioned(
                    right: 6,
                    top: 5,
                    child: Row(
                      children: [
                        Icon(Icons.star_rounded,
                            size: 10, color: AppColors.starGold),
                        const SizedBox(width: 2),
                        Text(rating!.toStringAsFixed(1),
                            style: const TextStyle(
                              fontFamily: AppStyles.uiFontFamily,
                              fontSize: 9.5,
                              height: 1,
                              color: Colors.white,
                            )),
                      ],
                    ),
                  ),
                // 标题 + 副标题（压字）
                Positioned(
                  left: 7,
                  right: 6,
                  bottom: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: AppStyles.uiFontFamily,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontFamily: AppStyles.uiFontFamily,
                            fontSize: 9,
                            height: 1.2,
                            color: Colors.white.withOpacity(0.72),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 文档区分段胶囊（替代默认 TabBar 指示条的轻量控件）
class _SegmentPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.brandBlue;
    // 🔴 必须包 IntrinsicWidth —— InteractiveWrapper 内部的 AnimatedContainer
    // 带 `alignment: Alignment.center`，而 Wrap 传给子项的是**有界松约束**，
    // Align 会直接撑满整行 ⇒ 每个胶囊各占一行、N 个标签竖排成 N 行，
    // 并且撑爆板块内容区（RenderFlex 溢出）。IntrinsicWidth 给的是 tight
    // 宽度（= 内容宽），胶囊按自身内容定宽，Wrap 才能正常换行。
    // （同源坑见 game_detail/upload_resource_dialog.dart:627 的注释）
    return IntrinsicWidth(
      child: InteractiveWrapper(
        onTap: onTap,
        hoverScale: 1.04,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? accent.withOpacity(0.13) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color:
                  selected ? accent.withOpacity(0.42) : AppColors.borderLight,
            ),
          ),
          child: Text(
            label,
            style: AppStyles.labelMedium.copyWith(
              fontSize: 11,
              color: selected ? accent : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _MiniAction({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InteractiveWrapper(
      onTap: onTap,
      hoverScale: 1.04,
      child: Container(
        height: 20,
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: AppColors.primaryText),
            const SizedBox(width: 3),
            Text(label, style: AppStyles.microCaption),
          ],
        ),
      ),
    );
  }
}
