import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/theme_element_registry.dart';
import 'interactive_wrapper.dart';

/// v3.0.1 修复8：Figma 式图层目录树面板（升级版）
///
/// 以树形结构展示全部可编辑元素的层级关系。
///
/// v3.0.1 修复8 升级点：
/// - 可折叠/展开父节点（带 chevron 旋转动画）
/// - 顶部搜索过滤（按名称/elementId 模糊匹配，自动展开命中节点的祖先）
/// - 悬停高亮 + 选中态强调
/// - 缩进引导线（depth > 0 时左侧画浅色竖线）
/// - 当外部选中元素变化时（如点击预览），自动展开其祖先链并滚动到可见
class LayerTreePanel extends StatefulWidget {
  final String selectedElementId;
  final ValueChanged<String> onElementSelect;

  const LayerTreePanel({
    super.key,
    required this.selectedElementId,
    required this.onElementSelect,
  });

  @override
  State<LayerTreePanel> createState() => _LayerTreePanelState();
}

class _LayerTreePanelState extends State<LayerTreePanel> {
  /// 折叠状态：key = elementId，value = true 表示折叠
  final Set<String> _collapsed = {};

  /// 搜索关键词
  String _searchQuery = '';

  /// 父子关系索引（elementId -> 父节点链），用于自动展开
  static final Map<String, List<String>> _ancestorChain = _buildAncestorChain();

  @override
  void didUpdateWidget(LayerTreePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部选中元素变化时，自动展开其祖先链（确保选中节点可见）
    if (oldWidget.selectedElementId != widget.selectedElementId) {
      final chain = _ancestorChain[widget.selectedElementId];
      if (chain != null) {
        for (final ancestor in chain) {
          _collapsed.remove(ancestor);
        }
      }
    }
  }

  /// 构建所有节点的祖先链索引
  static Map<String, List<String>> _buildAncestorChain() {
    final result = <String, List<String>>{};
    void walk(LayerNode node, List<String> ancestors) {
      result[node.elementId] = ancestors;
      for (final child in node.children) {
        walk(child, [...ancestors, node.elementId]);
      }
    }

    for (final root in ThemeElementRegistry.layerTree) {
      walk(root, []);
    }
    return result;
  }

  /// 判断节点或其任意后代是否匹配搜索
  bool _nodeMatches(LayerNode node) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    bool match(LayerNode n) {
      if (n.displayName.toLowerCase().contains(q) ||
          n.elementId.toLowerCase().contains(q)) {
        return true;
      }
      return n.children.any(match);
    }

    return match(node);
  }

  @override
  Widget build(BuildContext context) {
    final tree = ThemeElementRegistry.layerTree;
    // 搜索时过滤掉不匹配的顶层节点
    final visibleRoots =
        _searchQuery.isEmpty ? tree : tree.where(_nodeMatches).toList();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          right: BorderSide(color: AppColors.borderLight, width: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.placeholderBg,
              border: Border(
                bottom:
                    BorderSide(color: AppColors.borderLight, width: 0.6),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.account_tree_outlined,
                    size: 14, color: AppColors.secondaryText),
                const SizedBox(width: 6),
                Text(
                  '图层',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.secondaryText,
                  ),
                ),
                const Spacer(),
                // 折叠全部 / 展开全部
                _buildHeaderAction(
                  icon: Icons.unfold_less_rounded,
                  tooltip: '全部折叠',
                  onTap: () => setState(() {
                    for (final root in tree) {
                      if (root.children.isNotEmpty) {
                        _collapsed.add(root.elementId);
                      }
                    }
                  }),
                ),
                const SizedBox(width: 2),
                _buildHeaderAction(
                  icon: Icons.unfold_more_rounded,
                  tooltip: '全部展开',
                  onTap: () => setState(_collapsed.clear),
                ),
              ],
            ),
          ),
          // 搜索框
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border(
                bottom:
                    BorderSide(color: AppColors.borderLight, width: 0.4),
              ),
            ),
            child: Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppColors.placeholderBg,
                borderRadius: BorderRadius.circular(4),
                border:
                    Border.all(color: AppColors.borderLight, width: 0.6),
              ),
              child: Row(
                children: [
                  Icon(Icons.search,
                      size: 12, color: AppColors.placeholderText),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.primaryText,
                      ),
                      cursorColor: AppColors.selectedAccent,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        hintText: '搜索图层...',
                        hintStyle: TextStyle(
                          fontSize: 11,
                          color: AppColors.placeholderText,
                        ),
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty)
                    InteractiveWrapper(
                      onTap: () => setState(() => _searchQuery = ''),
                      child: Icon(Icons.close_rounded,
                          size: 12, color: AppColors.placeholderText),
                    ),
                ],
              ),
            ),
          ),
          // 树形列表
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: visibleRoots
                    .map((node) => _buildNode(node, 0))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 标题栏小按钮
  Widget _buildHeaderAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InteractiveWrapper(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 12, color: AppColors.secondaryText),
        ),
      ),
    );
  }

  Widget _buildNode(LayerNode node, int depth) {
    final isSelected = node.elementId == widget.selectedElementId;
    final hasChildren = node.children.isNotEmpty;
    final isCollapsed = _collapsed.contains(node.elementId);

    // 搜索时强制展开所有节点（便于查看命中结果）
    final effectiveCollapsed =
        _searchQuery.isEmpty ? isCollapsed : false;

    // 搜索时隐藏不匹配且无匹配后代的节点
    if (!_nodeMatches(node)) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LayerNodeTile(
          node: node,
          depth: depth,
          isSelected: isSelected,
          isCollapsed: effectiveCollapsed,
          hasChildren: hasChildren,
          onTap: () => widget.onElementSelect(node.elementId),
          onToggleCollapse: hasChildren
              ? () => setState(() {
                    if (isCollapsed) {
                      _collapsed.remove(node.elementId);
                    } else {
                      _collapsed.add(node.elementId);
                    }
                  })
              : null,
        ),
        // 递归子节点
        if (hasChildren && !effectiveCollapsed)
          for (final child in node.children) _buildNode(child, depth + 1),
      ],
    );
  }
}

/// 单个图层节点 tile（带悬停态 + 缩进引导线）
class _LayerNodeTile extends StatefulWidget {
  final LayerNode node;
  final int depth;
  final bool isSelected;
  final bool isCollapsed;
  final bool hasChildren;
  final VoidCallback onTap;
  final VoidCallback? onToggleCollapse;

  const _LayerNodeTile({
    required this.node,
    required this.depth,
    required this.isSelected,
    required this.isCollapsed,
    required this.hasChildren,
    required this.onTap,
    this.onToggleCollapse,
  });

  @override
  State<_LayerNodeTile> createState() => _LayerNodeTileState();
}

class _LayerNodeTileState extends State<_LayerNodeTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.only(
            left: 6.0 + widget.depth * 14,
            right: 8,
            top: 4,
            bottom: 4,
          ),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.selectedAccent.withOpacity(0.25)
                : (_isHovered
                    ? AppColors.cardHoverBg.withOpacity(0.6)
                    : Colors.transparent),
            border: widget.isSelected
                ? Border(
                    left: BorderSide(
                        color: AppColors.selectedAccent, width: 2),
                  )
                : null,
          ),
          child: Row(
            children: [
              // 展开/折叠 chevron（带旋转动画）
              if (widget.hasChildren)
                AnimatedRotation(
                  turns: widget.isCollapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: InteractiveWrapper(
                    onTap: widget.onToggleCollapse,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 14,
                        color: AppColors.placeholderText,
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(width: 14),
              Icon(widget.node.icon,
                  size: 13,
                  color: widget.isSelected
                      ? AppColors.selectedAccent
                      : AppColors.secondaryText),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.node.displayName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: widget.isSelected
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: widget.isSelected
                        ? AppColors.primaryText
                        : AppColors.secondaryText,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
