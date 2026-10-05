import 'package:flutter/material.dart';

import '../../theme/app_spacing.dart';
import '../../theme/app_styles.dart';

/// 设置页内的一个分组（标题 + 可选描述 + 若干设置行）。
///
/// 这是本次 IA 重构引入的**分组抽象**——此前偏好设置页只有「卡片粒度」的封装，
/// 9 张卡片平铺在一个 `Column` 里，没有任何分组，是「内容繁杂」的直接原因。
///
/// 分组间距固定 [AppSpacing.xxl]；首个分组传 [isFirst] = true 去掉顶部间距。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.description,
    this.isFirst = false,
  });

  /// 分组标题（如「游戏窗口」）。
  final String title;

  /// 分组下的一行说明，可选。
  final String? description;

  /// 分组内的设置行/卡片。
  final List<Widget> children;

  /// 是否为内容区第一个分组（去掉顶部间距）。
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 0 : AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: AppStyles.labelLarge
                .copyWith(color: AppStyles.bodySmall.color),
          ),
          if (description != null && description!.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(description!, style: AppStyles.labelMedium),
          ],
          const SizedBox(height: AppSpacing.sm),
          ..._spaced(children),
        ],
      ),
    );
  }

  /// 子项之间插入固定间距（行与行紧密排列，形成列表感）。
  List<Widget> _spaced(List<Widget> items) {
    if (items.isEmpty) return items;
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      if (i > 0) out.add(const SizedBox(height: AppSpacing.xs));
      out.add(items[i]);
    }
    return out;
  }
}
