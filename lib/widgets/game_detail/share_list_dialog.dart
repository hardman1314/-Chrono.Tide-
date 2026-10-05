import 'package:flutter/material.dart';

import '../../models/game_resource_model.dart';
import 'dark_surface.dart';
import 'kanban_identity.dart';

/// 「资源分享」浮层——锚定式对话栏（600dp 宽），列出某作品全部已发布的用户分享。
///
/// 设计（`素材/新建文件夹 (2)/分享窗口.json` + `Shell-1.png`），布局参照 KUN：
/// ```
/// 资源分享
/// ┌─────────────────────────────────────────────┐
/// │ (头像) 上传用户      [有效]                  │
/// │ [游戏本体][10.98 GB][Windows][简体中文][民间汉化] │
/// │ ┌─ 说明块（发布者备注）─────────────────────┐ │
/// │ └──────────────────────────────────────────┘ │
/// │ 百度网盘                       ↓244  [打开链接] │
/// └─────────────────────────────────────────────┘
/// ```
class ShareListDialog extends StatelessWidget {
  const ShareListDialog({
    super.key,
    required this.gameTitle,
    required this.resources,
    this.loading = false,
    this.error,
    this.onOpenDetail,
    this.onOpenLink,
    this.onUpload,
  });

  final String gameTitle;
  final List<GameResourceModel> resources;
  final bool loading;
  final String? error;

  /// 「打开链接 / 详情」→ 打开分享详情窗
  final void Function(GameResourceModel)? onOpenDetail;

  /// 直接跳转外链
  final void Function(GameResourceModel)? onOpenLink;

  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    return DarkShell(
      width: DarkPalette.shareListWidth,
      padding: const EdgeInsets.fromLTRB(11, 14, 11, 11),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 11),
            child: Row(
              children: [
                const Text(
                  '资源分享',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: DarkPalette.textPrimary,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                if (onUpload != null)
                  DarkGhostButton(
                    label: '发布资源',
                    onTap: onUpload,
                    foreground: DarkPalette.primaryBlue,
                    icon: const Icon(Icons.add_circle_outline),
                    fontSize: 11.5,
                  ),
              ],
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation(DarkPalette.primaryBlue),
                  ),
                ),
              ),
            )
          else if (error != null)
            _buildEmpty(error!)
          else if (resources.isEmpty)
            _buildEmpty('${'该作品暂无用户分享'}\n你可以在下方「上传」提交一份资源')
          else
            ConstrainedBox(
              // 窗口高度有限，卡片超过 3 张即内部滚动
              constraints: const BoxConstraints(maxHeight: 430),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < resources.length; i++) ...[
                      if (i > 0) const SizedBox(height: 10),
                      _ShareCard(
                        resource: resources[i],
                        onOpenDetail: onOpenDetail,
                        onOpenLink: onOpenLink,
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            color: DarkPalette.textMuted,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

/// 单条分享卡
class _ShareCard extends StatelessWidget {
  const _ShareCard({
    required this.resource,
    this.onOpenDetail,
    this.onOpenLink,
  });

  final GameResourceModel resource;
  final void Function(GameResourceModel)? onOpenDetail;
  final void Function(GameResourceModel)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final r = resource;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 0, 16, 8),
      decoration: BoxDecoration(
        color: DarkPalette.shareCardBg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: DarkPalette.shareCardBorder, width: 0.6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 11),
          _buildHeader(r),
          const SizedBox(height: 8),
          _buildBadges(r),
          if (r.note.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildNote(r.note),
          ],
          const SizedBox(height: 8),
          _buildFooter(r),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildHeader(GameResourceModel r) {
    return Row(
      children: [
        // 2026-10-02 UI 优化：头像 16 → 25，对齐「获取」（官方下载）窗口的
        // 用户面板设计（ct_download_dialog._buildMainRow 同款 size/层级）
        AvatarCircle(
          imageUrl: r.ownerAvatarUrl,
          fallbackAsset: KanbanIdentity.isKanban(r.ownerName)
              ? KanbanIdentity.assetPath
              : null,
          size: 25,
          borderColor: DarkPalette.cardBorder,
          borderWidth: 0.6,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.ownerName.isNotEmpty ? r.ownerName : '匿名分享者',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DarkPalette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              // 设计稿此处为**相对时间**（「4 个月前」），不是绝对日期
              Text(
                r.createdAgeLabel(),
                style: const TextStyle(
                  fontSize: 10,
                  color: DarkPalette.textMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        DarkBadge(
          label: r.status.label,
          background: DarkPalette.badgeGreenBg,
          foreground: DarkPalette.green,
          icon: const Icon(Icons.verified_outlined),
          fontSize: 10,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        ),
      ],
    );
  }

  /// 徽章行：资源类型 → 体积 → 平台 → 语言 → 兜底灰标
  Widget _buildBadges(GameResourceModel r) {
    final badges = <Widget>[
      for (final t in r.resourceTypes)
        DarkBadge(
          label: t,
          background: DarkPalette.badgeBlueBg,
          foreground: DarkPalette.lightBlue,
          icon: const Icon(Icons.videogame_asset_outlined),
          fontSize: 10,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        ),
      if (r.fileSize.isNotEmpty)
        DarkBadge(
          label: r.fileSize,
          background: DarkPalette.badgeYellowBg,
          foreground: DarkPalette.yellow,
          icon: const Icon(Icons.sd_storage_outlined),
          fontSize: 10,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        ),
      for (final p in r.platforms)
        DarkBadge(
          label: p,
          background: DarkPalette.badgeGreenBg,
          foreground: DarkPalette.green,
          icon: const Icon(Icons.desktop_windows_outlined),
          fontSize: 10,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        ),
      for (final l in r.languages)
        DarkBadge(
          label: l,
          background: DarkPalette.badgePinkBg,
          foreground: DarkPalette.pink,
          icon: const Icon(Icons.translate_rounded),
          fontSize: 10,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        ),
    ];

    if (badges.isEmpty) {
      badges.add(
        const DarkBadge.plain(
          label: '未分类',
          background: DarkPalette.badgeMutedBg,
          foreground: Color(0xFFB8B8C2),
          fontSize: 10,
          padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        ),
      );
    }

    return Wrap(spacing: 4, runSpacing: 4, children: badges);
  }

  Widget _buildNote(String note) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
      decoration: BoxDecoration(
        color: DarkPalette.shareNoteBg,
        borderRadius: BorderRadius.circular(5.5),
      ),
      child: Text(
        note,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10.5,
          color: DarkPalette.textBody,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildFooter(GameResourceModel r) {
    final provider = r.netdiskProviderLabel;
    return Row(
      children: [
        if (provider.isNotEmpty) ...[
          const Icon(
            Icons.cloud_outlined,
            size: 12,
            color: DarkPalette.textDim,
          ),
          const SizedBox(width: 4),
          Text(
            provider,
            style: const TextStyle(fontSize: 10.5, color: DarkPalette.textDim),
          ),
        ],
        const Spacer(),
        const Icon(
          Icons.file_download_outlined,
          size: 12,
          color: DarkPalette.textDim,
        ),
        const SizedBox(width: 3),
        Text(
          '${r.downloadCount}',
          style: const TextStyle(fontSize: 10.5, color: DarkPalette.textDim),
        ),
        const SizedBox(width: 10),
        // 设计（Shell.png x 1012..1060 / y 414..428）：
        // 48×14 的**全圆角药丸**按钮，云图标 + 4 字标签，
        // 语义 = 进入「分享详情」（拿链接 / 提取码 / 解压码）。
        DarkPrimaryButton(
          label: '获取资源',
          icon: const Icon(Icons.cloud_download_outlined),
          background: DarkPalette.linkBlue,
          fontSize: 10.5,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          radius: 999,
          onTap: () {
            if (onOpenDetail != null) {
              onOpenDetail!(r);
            } else {
              onOpenLink?.call(r);
            }
          },
        ),
      ],
    );
  }
}
