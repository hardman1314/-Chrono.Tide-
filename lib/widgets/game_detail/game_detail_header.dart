import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';

/// 探索详情页顶部「游戏数据区」。
///
/// 设计（`素材/新建文件夹 (2)/Shell.png`，1281×721 = 窗口 1:1，可直接当 dp 读）：
/// ```
/// [←] [面包屑]
/// ┌────────┐  大标题（35dp，F1 得意黑，字距 2.0）
/// │        │  [别名胶囊]
/// │ 封面   │  ⌂会社  📅发售日  ★评分(人数)  ⛁来源
/// │135×205 │  #标签 #标签 #标签
/// │        │  ─────────────────────────────
/// │        │  [⬇获取][分享][⬆上传]  ▏ ♡ 💬
/// └────────┘
/// ```
///
/// ⚠️ 与旧版差异（本轮重构的**核心视觉变化**）：
/// - 封面 216×323 → **135×205**（设计实测：边框 x 240→378、y 81→283，
///   含约 2.4° 旋转，正交化后 ≈ 138×202）
/// - 大标题 32 → **35**，仍用 F1 得意黑、字距 2.0（AGENTS 禁止 w700）
/// - 右列大「获取作品」安装按钮**移除**，改为本区下方的一行操作按钮
///   （安装状态与进度改由「Chrono Tide 下载」浮层承载）
/// - 右列内容底部的强调分割线（设计 #2B2B2B → `AppColors.dividerStrong`）
class GameDetailHeader extends StatelessWidget {
  const GameDetailHeader({
    super.key,
    required this.cover,
    required this.title,
    required this.alias,
    required this.metaItems,
    required this.tags,
    required this.leading,
    required this.onGet,
    required this.onShare,
    required this.onUpload,
    required this.onLike,
    required this.onFeedback,
    this.actionRowKey,
    this.getLabel = '获取',
    this.getEnabled = true,
    this.getBusy = false,
    this.shareEnabled = true,
    this.uploadEnabled = true,
    this.liked = false,
    this.likeCount = 0,
  });

  /// 封面（由页面传入，保持既有旋转/阴影/NSFW 处理逻辑不变）
  final Widget cover;

  final String title;

  /// 别名（日语原标题优先，回退英语标题）；为空则不显示胶囊
  final String alias;

  /// 元数据条目（会社 / 发售日 / 星级 / 热度 / 数据来源），
  /// 由页面复用既有 `_buildMetadataChips()` 生成，样式零改动
  final List<Widget> metaItems;

  final Widget tags;

  /// 返回键 + 分级面包屑（沿用页面既有实现）
  final Widget leading;

  /// 操作按钮行的测量锚点：页面据此把「下载 / 分享」浮层贴到按钮旁
  final Key? actionRowKey;

  final VoidCallback? onGet;
  final VoidCallback? onShare;
  final VoidCallback? onUpload;
  final VoidCallback onLike;
  final VoidCallback onFeedback;

  /// 「获取」按钮文案（按安装状态变形：获取 / 已安装 / 安装中 / 排队中）
  final String getLabel;
  final bool getEnabled;
  final bool getBusy;
  final bool shareEnabled;
  final bool uploadEnabled;

  /// 「喜欢」点亮态 + 作品级点赞数（主线补完 §14.2-P2）：
  /// liked=true 显示实心心形；likeCount>0 时图标旁显示计数
  final bool liked;
  final int likeCount;

  static const double coverWidth = 135;
  static const double coverHeight = 205;

  /// 封面 → 右列的横向间距
  ///
  /// 设计实测（`Shell.png`）：封面右边框 x≈378（含 2.4° 旋转，在分割线所在的
  /// y=213 处为 378.4），右列（分割线 / 别名胶囊 / 元数据 / 标签 / 按钮行）统一
  /// 左起 x=388 ⇒ **间距 10**。
  static const double _coverGap = 10;
  static const double _actionHeight = 38;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        leading,
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(width: _coverGap),
            Expanded(child: _buildRightColumn(context)),
          ],
        ),
      ],
    );
  }

  /// 右列纵向排布。
  ///
  /// 设计实测（`Shell.png` 右列 x 388..1000，逐行非背景扫描；
  /// 封面顶 y=81 与标题**行盒**顶对齐 ⟹ 标题 lineHeight = 42/35 ≈ 1.2，
  /// 据此把「ink 边界」换算成「行盒边界」）：
  /// ```
  /// 大标题   行盒 81..122   ink  85..119（字号 35，字距 2.0，F1 得意黑）
  /// 别名胶囊 125..149  h25  ← 间距 3（行盒底 122 → 胶囊顶 125）
  /// 元数据行 ink 164..175   ← 间距 12（胶囊底 149 → 行盒顶 161）
  /// 标签行   186..204  h19  ← 间距 8
  /// 分割线   213..214  2px  ← 间距 9
  /// 按钮行   223..260  h38  ← 间距 8
  /// [截图/系列] 279..       ← 间距 18（由外层页面控制）
  /// ```
  Widget _buildRightColumn(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppStyles.titleLarge.copyWith(
            fontSize: 35,
            letterSpacing: 2.0,
            height: 1.18, // 设计 1.2
          ),
        ),
        if (alias.isNotEmpty) ...[
          const SizedBox(height: 3),
          _buildAliasPill(alias),
        ],
        if (metaItems.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: metaItems,
          ),
        ],
        const SizedBox(height: 8),
        tags,
        const SizedBox(height: 9),
        _buildDivider(),
        const SizedBox(height: 8),
        _buildActionRow(),
      ],
    );
  }

  /// 别名胶囊（设计 136×25，圆角全，浅底 + 描边）
  Widget _buildAliasPill(String text) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      // 设计实测：胶囊外框 136(宽) × 25(高)；12.5px 中文 9 字 ≈ 112.5，
      // 故水平内边距取 12、垂直取 2（文字行盒约 21）。
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border.withOpacity(0.55), width: 1),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppStyles.bodyRegular.copyWith(
          fontSize: 12.5,
          color: AppColors.secondaryText,
          fontStyle: FontStyle.normal,
        ),
      ),
    );
  }

  /// 强调分割线（设计 #2B2B2B；走主题令牌随主题明暗自适应）
  Widget _buildDivider() {
    return Container(
      height: 2,
      decoration: BoxDecoration(
        color: AppColors.dividerStrong,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  // ---------- 操作按钮行 ----------
  //
  // 设计实测（`Shell.png` 1:1 像素采样，y 223..260）：
  // ```
  // |获取 86|9|分享 82|9|上传 88|22|▏|29|♡|33|💬        (388 → 774)
  // ```
  // - 获取：底 #2DA6D4 / 内容纯白 / 图标 = 下箭头入托盘
  // - 分享：底 #262626 / **内容与 1px 描边均为 #2DA6D4**（不是白字）
  // - 上传：底 #6841C4 / 图标 = 上箭头出托盘
  // - ▏：2×36 竖线，色 #454544
  // - ♡ / 💬：**裸描边图标**（无 38×38 描边框），色 #DD1B24 / #00AD38
  //
  // ⚠️ 一处**有意偏离设计原值**：设计稿里「上传」的内容色实测为 #2A5FA5
  //    （暗蓝），落在 #6841C4 底上对比度仅 ~2.1:1，肉眼近乎糊掉；同排的
  //    「获取」用的是纯白。判定为设计稿笔误，故此处统一取纯白。
  //    如需严格复刻，把 `AppColors.onAccentSolid` 换成 `Color(0xFF2A5FA5)` 即可。
  Widget _buildActionRow() {
    // Wrap 的 spacing 会插在所有子项之间，故用「目标间距 − spacing」的
    // 无高占位块补齐设计间距（9 / 22 / 29 / 33）。
    const gap = 9.0;
    return KeyedSubtree(
      key: actionRowKey,
      child: Wrap(
        spacing: gap,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // 文案随安装状态变形（获取 / 已安装 / 安装中 / 排队中），
          // 由页面通过 getLabel 传入（`_getButtonLabel`）。
          _buildPrimary(
            getLabel,
            Icons.download_rounded,
            onGet,
            background: AppColors.accentCyan,
            foreground: AppColors.onAccentSolid,
            enabled: getEnabled,
            busy: getBusy,
          ),
          _buildPrimary(
            '分享',
            Icons.account_tree_outlined,
            onShare,
            background: AppColors.accentInk,
            foreground: AppColors.accentCyan,
            borderColor: AppColors.accentCyan,
            enabled: shareEnabled,
          ),
          _buildPrimary(
            '上传',
            Icons.upload_rounded,
            onUpload,
            background: AppColors.accentViolet,
            foreground: AppColors.onAccentSolid,
            enabled: uploadEnabled,
          ),
          const SizedBox(width: 22 - gap),
          _buildActionSeparator(),
          const SizedBox(width: 29 - gap),
          _buildIconAction(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              '喜欢', AppColors.heartRed, onLike,
              count: likeCount),
          const SizedBox(width: 33 - gap),
          _buildIconAction(Icons.chat_bubble_outline_rounded, '反馈',
              AppColors.feedbackGreen, onFeedback),
        ],
      ),
    );
  }

  /// 竖线分隔（设计 2×36，#454544）
  Widget _buildActionSeparator() {
    return Container(
      width: 2,
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.dividerStrong.withOpacity(0.55),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  /// 实底主按钮。
  ///
  /// ⚠️ 刻意**不用 `alignment:`** —— `Container` 一旦设了 `alignment`，在
  /// `Wrap`（传入 maxWidth 的松约束）里会**撑满整行**，三个按钮就会各占一行。
  /// 改为 `Center(widthFactor: 1.0)` + `minWidth` 让按钮按内容定宽。
  Widget _buildPrimary(
    String label,
    IconData icon,
    VoidCallback? onTap, {
    required Color background,
    required Color foreground,
    Color? borderColor,
    bool enabled = true,
    bool busy = false,
  }) {
    final active = enabled && !busy && onTap != null;
    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.5,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: _actionHeight,
            constraints: const BoxConstraints(minWidth: 82),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
              border: borderColor == null
                  ? null
                  : Border.all(color: borderColor, width: 1),
            ),
            child: Center(
              widthFactor: 1.0,
              child: busy
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(foreground),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 17, color: foreground),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: AppStyles.bodyRegular.copyWith(
                            fontSize: 13.5,
                            color: foreground,
                            fontWeight: FontWeight.w600,
                            fontStyle: FontStyle.normal,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 裸描边图标按钮（无外框、无底板，仅图标本身；设计 17×17 / 15×15）。
  /// [count] 非空且 >0 时图标右侧显示计数文字（「喜欢」作品级点赞数），
  /// null / 0 时渲染与旧版完全一致（零回归）。
  Widget _buildIconAction(
    IconData icon,
    String tooltip,
    Color color,
    VoidCallback onTap, {
    int? count,
  }) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          // 命中区保持 38 高（与按钮行等高），视觉只有图标（+可选计数）
          child: SizedBox(
            height: _actionHeight,
            child: Center(
              widthFactor: 1.0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: color),
                  if (count != null && count > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                        color: color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
