import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../services/local_game_registry.dart';
import '../../widgets/app_dialog.dart';
import '../big_picture_theme.dart';
import '../focus/focus_grid_policy.dart';
import '../widgets/big_picture_game_card.dart';
import '../widgets/bpm_interactive_wrapper.dart';

/// BPM 游戏库页面
///
/// 网格布局展示所有游戏,支持搜索与排序。
/// 焦点策略由 [FocusGridPolicy] 接管,实现二维网格上下左右键盘导航。
///
/// v1.2 优化:
/// - 焦点滚动联动: 给 BigPictureGameCard 外层加 Focus 监听 + Scrollable.ensureVisible
/// - 顶部 Row 容错: 搜索框用 Flexible+ConstrainedBox,窄屏不溢出
/// - 数量显示: 改为过滤后/总数 "X / Y 个游戏"
/// - 排序菜单 BPM 风格化: 用 showAppDialog + BpmInteractiveWrapper
/// - autofocus 持久化: 仅首项首次 autofocus,避免 setState 重触发
class BigPictureLibraryPage extends StatefulWidget {
  /// 单击游戏卡片回调 (打开详情页)
  final ValueChanged<LibraryGame> onGameTap;

  /// 双击游戏卡片回调 (启动游戏)
  final ValueChanged<LibraryGame> onGameLaunch;

  /// 长按游戏卡片回调 (弹出动作表)
  final ValueChanged<LibraryGame>? onGameLongPress;

  /// 搜索框焦点节点 (由 Shell 注入,供 Ctrl+F 聚焦)
  final FocusNode? searchFocusNode;

  const BigPictureLibraryPage({
    super.key,
    required this.onGameTap,
    required this.onGameLaunch,
    this.onGameLongPress,
    this.searchFocusNode,
  });

  @override
  State<BigPictureLibraryPage> createState() => _BigPictureLibraryPageState();
}

class _BigPictureLibraryPageState extends State<BigPictureLibraryPage> {
  List<LibraryGame> _games = [];
  String _searchQuery = '';
  _SortMode _sortMode = _SortMode.installedDesc;
  final TextEditingController _searchController = TextEditingController();

  /// 首次焦点标志: 仅首次构建时让首卡 autofocus
  bool _initialFocusRequested = false;

  @override
  void initState() {
    super.initState();
    _loadGames();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onRegistryChanged() {
    // UX-34: 区分通知类型——结构性变化需重新加载,游玩时长变化仅刷新
    final reason = LocalGameRegistry.instance.lastChangeReason;
    if (reason == RegistryChangeReason.structural) {
      if (mounted) _loadGames();
    } else {
      // playTimeUpdate:游戏对象引用已被原地修改,仅 setState 让 UI 反映新值
      if (mounted) setState(() {});
    }
  }

  void _loadGames() {
    _games = LocalGameRegistry.instance.allGames;
    if (mounted) setState(() {});
  }

  List<LibraryGame> get _filteredGames {
    var filtered = _games;
    // 搜索过滤
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((g) {
        return g.title.toLowerCase().contains(query) ||
            g.developer.toLowerCase().contains(query) ||
            g.tags.any((t) => t.toLowerCase().contains(query));
      }).toList();
    }
    // 排序
    final sorted = List<LibraryGame>.from(filtered);
    switch (_sortMode) {
      case _SortMode.installedDesc:
        sorted.sort((a, b) => b.installedAt.compareTo(a.installedAt));
        break;
      case _SortMode.titleAsc:
        sorted.sort((a, b) => a.title.compareTo(b.title));
        break;
      case _SortMode.lastPlayedDesc:
        sorted.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
        break;
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final games = _filteredGames;
    return Container(
      color: AppColors.pageBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部: 标题 + 搜索框 + 排序 (v1.2: Flexible 容错)
          Padding(
            padding: const EdgeInsets.all(BigPictureTheme.pagePadding),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 窄屏: 标题/数量单独一行,搜索框+排序单独一行
                // 宽屏: 全部一行
                final isNarrow = constraints.maxWidth < 720;
                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '游戏库',
                            style: TextStyle(
                              fontFamily: 'ZhiMangXing',
                              fontSize: BigPictureTheme.displayFontSize,
                              color: AppColors.primaryText,
                            ),
                          ),
                          const SizedBox(width: 16),
                          // v1.2: 显示过滤后/总数
                          Flexible(
                            child: Text(
                              '${games.length} / ${_games.length} 个游戏',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: BigPictureTheme.bodyFontSize,
                                color: AppColors.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _buildSearchField(),
                          ),
                          const SizedBox(width: 16),
                          _buildSortButton(),
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Text(
                      '游戏库',
                      style: TextStyle(
                        fontFamily: 'ZhiMangXing',
                        fontSize: BigPictureTheme.displayFontSize,
                        color: AppColors.primaryText,
                      ),
                    ),
                    const SizedBox(width: 16),
                    // v1.2: 显示过滤后/总数
                    Text(
                      '${games.length} / ${_games.length} 个游戏',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: BigPictureTheme.bodyFontSize,
                        color: AppColors.secondaryText,
                      ),
                    ),
                    const Spacer(),
                    // v1.2: 搜索框用 Flexible+ConstrainedBox 容错
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: _buildSearchField(),
                      ),
                    ),
                    const SizedBox(width: 16),
                    _buildSortButton(),
                  ],
                );
              },
            ),
          ),
          // 游戏网格 (FocusGridPolicy 接管方向键导航)
          Expanded(
            child: games.isEmpty
                ? _buildEmptyState()
                : FocusTraversalGroup(
                    policy: FocusGridPolicy(),
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(
                          BigPictureTheme.pagePadding,
                          0,
                          BigPictureTheme.pagePadding,
                          BigPictureTheme.pagePadding),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: BigPictureTheme.cardWidth +
                            BigPictureTheme.cardSpacing,
                        crossAxisSpacing: BigPictureTheme.cardSpacing,
                        mainAxisSpacing: BigPictureTheme.cardSpacing,
                        childAspectRatio: BigPictureTheme.cardWidth /
                            BigPictureTheme.cardHeight,
                      ),
                      itemCount: games.length,
                      itemBuilder: (context, index) {
                        final game = games[index];
                        // v1.2: 仅首项首次 autofocus
                        final shouldAutofocus =
                            index == 0 && !_initialFocusRequested;
                        if (shouldAutofocus) _initialFocusRequested = true;
                        // v1.2: 外层加 Focus 监听联动 Scrollable.ensureVisible
                        return _FocusableGameCard(
                          game: game,
                          autofocus: shouldAutofocus,
                          onTap: () => widget.onGameTap(game),
                          onDoubleTap: () => widget.onGameLaunch(game),
                          onLongPress: widget.onGameLongPress != null
                              ? () => widget.onGameLongPress!(game)
                              : null,
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 搜索框 (v1.2: 提取为独立方法)
  Widget _buildSearchField() {
    return SizedBox(
      height: 48,
      child: TextField(
        controller: _searchController,
        focusNode: widget.searchFocusNode,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 16,
        ),
        decoration: InputDecoration(
          hintText: '搜索游戏...',
          hintStyle: TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            color: AppColors.placeholderText,
          ),
          prefixIcon:
              Icon(Icons.search, size: 22, color: AppColors.secondaryText),
          filled: true,
          fillColor: AppColors.background,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            borderSide: BorderSide(color: AppColors.border, width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            borderSide: BorderSide(color: AppColors.border, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            borderSide: BorderSide(color: AppColors.selectedAccent, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
    );
  }

  Widget _buildSortButton() {
    return BpmInteractiveWrapper(
      onTap: () => _showSortMenu(),
      semanticsLabel: '排序',
      borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
          border: Border.all(color: AppColors.border, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort_rounded, size: 22, color: AppColors.secondaryText),
            const SizedBox(width: 8),
            // v1.2: 窄屏可隐藏文字 (LayoutBuilder 已在外层处理)
            Text(
              _sortMode.label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// v1.2: BPM 风格排序菜单 (用 showAppDialog + BpmInteractiveWrapper)
  void _showSortMenu() {
    showAppDialog(
      context: context,
      builder: (context) => Align(
        alignment: Alignment.center,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(BigPictureTheme.widgetPadding),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius:
                BorderRadius.circular(BigPictureTheme.containerRadius),
            border: Border.all(color: AppColors.border, width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题
              Text(
                '排序方式',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: BigPictureTheme.subtitleFontSize,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 16),
              // 选项列表
              ..._SortMode.values.map((mode) {
                final isSelected = _sortMode == mode;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: BpmInteractiveWrapper(
                    onTap: () {
                      setState(() => _sortMode = mode);
                      Navigator.of(context).pop();
                    },
                    autofocus: isSelected,
                    semanticsLabel: mode.label,
                    borderRadius:
                        BorderRadius.circular(BigPictureTheme.buttonRadius),
                    child: Container(
                      height: BigPictureTheme.secondaryButtonHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.selectedAccent.withOpacity(0.15)
                            : AppColors.buttonBackground,
                        borderRadius:
                            BorderRadius.circular(BigPictureTheme.buttonRadius),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.selectedAccent
                              : AppColors.border.withOpacity(0.5),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSelected
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 20,
                            color: isSelected
                                ? AppColors.selectedAccent
                                : AppColors.secondaryText,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              mode.label,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: BigPictureTheme.bodyFontSize,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isSelected
                                    ? AppColors.selectedAccent
                                    : AppColors.primaryText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
              // 取消按钮
              BpmInteractiveWrapper(
                onTap: () => Navigator.of(context).pop(),
                semanticsLabel: '取消',
                borderRadius:
                    BorderRadius.circular(BigPictureTheme.buttonRadius),
                child: Container(
                  height: BigPictureTheme.secondaryButtonHeight,
                  decoration: BoxDecoration(
                    color: AppColors.buttonBackground,
                    borderRadius:
                        BorderRadius.circular(BigPictureTheme.buttonRadius),
                    border: Border.all(color: AppColors.border, width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      '取消',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: BigPictureTheme.bodyFontSize,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final isEmpty = _games.isEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isEmpty ? Icons.library_books_rounded : Icons.search_off_rounded,
            size: 96,
            color: AppColors.secondaryText.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          Text(
            isEmpty ? '库中没有游戏' : '未找到匹配的游戏',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.bodyFontSize,
              color: AppColors.placeholderText,
            ),
          ),
        ],
      ),
    );
  }
}

/// v1.2: 焦点感知的游戏卡片包装器
///
/// 外层加 Focus(canRequestFocus: false, descendantsAreFocusable: true, onFocusChange)
/// 监听焦点变化并联动 Scrollable.ensureVisible,让当前焦点卡片在网格中可见。
/// canRequestFocus: false 确保不参与焦点导航 (避免与 BigPictureGameCard 内部 Focus 冲突)。
class _FocusableGameCard extends StatelessWidget {
  final LibraryGame game;
  final bool autofocus;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;

  const _FocusableGameCard({
    required this.game,
    required this.autofocus,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: true,
      onFocusChange: (focused) {
        if (focused) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final renderObj = context.findRenderObject();
            if (renderObj != null) {
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
              );
            }
          });
        }
      },
      child: BigPictureGameCard(
        game: game,
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onLongPress: onLongPress,
        autofocus: autofocus,
      ),
    );
  }
}

/// 排序模式
enum _SortMode {
  installedDesc('最近安装'),
  titleAsc('名称 (A-Z)'),
  lastPlayedDesc('最近游玩');

  final String label;
  const _SortMode(this.label);
}
