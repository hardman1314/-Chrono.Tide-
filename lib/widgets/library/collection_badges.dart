import 'package:flutter/material.dart';
import '../../services/collection_service.dart';

/// 收藏夹书签角标：游戏所属收藏夹的图标徽章（替代原小黄星标记）
///
/// 游戏归类到收藏夹后，在卡片右上角显示对应收藏夹图标（颜色跟随收藏夹），
/// 视觉效果类似在作品封面上打上彩色书签。
/// 最多显示 3 个图标，超出部分合并为 +N 计数。
class CollectionBadges extends StatelessWidget {
  const CollectionBadges({
    super.key,
    required this.collectionIds,
    this.iconSize = 17,
  });

  final List<String> collectionIds;

  /// 图标尺寸（拖拽浮层等大尺寸场景可放大）
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final service = CollectionService.instance;
    final collections = collectionIds
        .map((id) => service.byId(id))
        .whereType<GameCollection>()
        .toList();
    if (collections.isEmpty) return const SizedBox.shrink();

    final shown = collections.take(3);
    final overflow = collections.length - 3;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        // 深色半透明胶囊底：封面颜色不可控，保证任意封面下图标可读
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in shown)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Icon(
                c.icon,
                size: iconSize,
                color: Color(c.colorValue),
              ),
            ),
          if (overflow > 0)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Text(
                '+$overflow',
                style: TextStyle(
                  fontSize: iconSize - 4,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
