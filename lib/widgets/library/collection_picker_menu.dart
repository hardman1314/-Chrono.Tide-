import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/collection_service.dart';
import '../../services/local_game_registry.dart';
import '../../theme/app_colors.dart';

/// 「加入收藏夹」选择弹层（Overlay 菜单）
///
/// 视觉规范与 LibraryContextMenu 同族：2px 边框 + 硬边阴影(4,5) + 边界检测。
/// - 单游戏模式（games 长度为 1）：勾选式切换归属
/// - 批量模式（games 长度 > 1）：全选中均为成员时点击=全部移出，否则=全部加入
class CollectionPickerMenu extends StatelessWidget {
  const CollectionPickerMenu({
    super.key,
    required this.position,
    required this.games,
    required this.collections,
    required this.onToggle,
    required this.onCreate,
    required this.onClose,
  });

  final Offset position;
  final List<LibraryGame> games;
  final List<GameCollection> collections;
  final ValueChanged<GameCollection> onToggle;
  final VoidCallback onCreate;
  final VoidCallback onClose;

  static const double _menuWidth = 210;
  static const double _itemHeight = 40;
  static const double _maxHeight = 380;

  bool _isMember(GameCollection c) {
    // 全部选中游戏都属于该收藏夹时才显示勾选态（批量语义）
    if (games.isEmpty) return false;
    for (final g in games) {
      if (!g.collectionIds.contains(c.id)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    const margin = 8.0;

    final menuHeight =
        math.min(_maxHeight, 48 + collections.length * _itemHeight + 46)
            .clamp(120.0, _maxHeight);

    final maxLeft = math.max(margin, screenSize.width - _menuWidth - margin);
    final left = position.dx.clamp(margin, maxLeft);

    double top;
    if (position.dy + menuHeight > screenSize.height - margin) {
      top = math.max(margin, position.dy - menuHeight);
    } else {
      top = position.dy;
    }

    final isBatch = games.length > 1;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: _menuWidth,
              constraints: const BoxConstraints(maxHeight: _maxHeight),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.13),
                    offset: const Offset(4, 5),
                    blurRadius: 0,
                  ),
                ],
                color: AppColors.background,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 头部说明
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(14, 10, 14, 8),
                    child: Row(
                      children: [
                        Icon(Icons.collections_bookmark_outlined,
                            size: 14, color: AppColors.secondaryText),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            isBatch ? '已选 ${games.length} 部作品' : '加入收藏夹',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                      height: 1, thickness: 1, color: AppColors.border),
                  // 收藏夹列表
                  Flexible(
                    child: collections.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              '还没有收藏夹，先创建一个吧',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.placeholderText,
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: collections.length,
                            itemBuilder: (context, index) {
                              final c = collections[index];
                              // 置顶区（准备入手 / 特别关注）与普通收藏夹之间加分隔线
                              final hasFollowing =
                                  index + 1 < collections.length;
                              final isLastPinned = c.isPinnedTop &&
                                  hasFollowing &&
                                  !collections[index + 1].isPinnedTop;
                              return _buildItem(c,
                                  showDividerBelow: isLastPinned);
                            },
                          ),
                  ),
                  Divider(
                      height: 1, thickness: 1, color: AppColors.border),
                  // 新建入口
                  _buildCreateItem(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItem(GameCollection c, {bool showDividerBelow = false}) {
    final isMember = _isMember(c);
    final color = Color(c.colorValue);

    final item = GestureDetector(
      onTap: () {
        onClose();
        onToggle(c);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          height: _itemHeight,
          color: Colors.transparent,
          child: Row(
            children: [
              // 勾选态 / 色点
              SizedBox(
                width: 18,
                height: 18,
                child: isMember
                    ? Icon(Icons.check_rounded, size: 18, color: color)
                    : Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              // 置顶收藏夹标记（恒显示在前两位）
              if (c.isPinnedTop)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.push_pin,
                      size: 11, color: AppColors.placeholderText),
                ),
              Icon(
                isMember ? Icons.remove_circle_outline : Icons.add_circle_outline,
                size: 16,
                color: AppColors.placeholderText,
              ),
            ],
          ),
        ),
      ),
    );

    if (!showDividerBelow) return item;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        item,
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 14),
          height: 1,
          color: AppColors.shadowColor,
        ),
      ],
    );
  }

  Widget _buildCreateItem() {
    return GestureDetector(
      onTap: () {
        onClose();
        onCreate();
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          height: 44,
          child: Row(
            children: [
              Icon(Icons.add, size: 18, color: AppColors.selectedAccent),
              const SizedBox(width: 10),
              Text(
                '新建收藏夹…',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.selectedAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
