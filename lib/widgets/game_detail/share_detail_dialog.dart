import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/game_resource_model.dart';
import 'dark_surface.dart';
import 'kanban_identity.dart';
import '../app_snack_bar.dart';

/// 「分享详情」居中窗口（725dp 宽，内部滚动）。
///
/// 设计（`素材/新建文件夹 (2)/分享详情窗口.json` + `Component 7.png`）：
/// ```
/// ┌ [✓] 该资源链接可用              [百度网盘] [收起] ┐  ← 顶部条 #1A2C23
/// │ (头像) 上传用户                  [245 次下载]     │
/// │ [游戏本体][10.98 GB][Windows 电脑版][简体中文]    │
/// │ ┌ 发布者备注 ────────────────────────┐            │
/// │ ┌ 下载链接 ─────────────────────────┐            │
/// │ [提取码 CC ⧉] [解压码1 CC ⧉] [解压码2 77 ⧉]      │
/// │ ┌ 汐乃的小请求 ─────────────────────┐            │
/// │ ┌ 补票提示 ────────────────────────┐（红描边）    │
/// │ [⚑ 报告失效]                        [关闭]       │
/// └──────────────────────────────────────────────────┘
/// ```
class ShareDetailDialog extends StatelessWidget {
  const ShareDetailDialog({
    super.key,
    required this.resource,
    this.ownerAvatarUrl,
    this.onClose,
    this.onReport,
    this.onOpenLink,
    this.maxHeight,
  });

  final GameResourceModel resource;
  final String? ownerAvatarUrl;
  final VoidCallback? onClose;
  final VoidCallback? onReport;
  final VoidCallback? onOpenLink;

  /// 可用最大高度（由调用方按窗口尺寸传入），超出则内部滚动
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final r = resource;
    final height = maxHeight ?? (MediaQuery.of(context).size.height - 96);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: DarkPalette.shareDetailWidth,
        maxHeight: height.clamp(280.0, 2400.0),
      ),
      child: DarkShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(r),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(21, 21, 21, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildOwnerRow(r),
                    const SizedBox(height: 21),
                    _buildBadges(r),
                    const SizedBox(height: 22),
                    if (r.note.trim().isNotEmpty) ...[
                      _SectionCard(
                        title: '发布者备注',
                        background: DarkPalette.noteCardBg,
                        body: r.note.trim(),
                      ),
                      const SizedBox(height: 22),
                    ],
                    _buildLinkCard(context, r),
                    const SizedBox(height: 22),
                    if (r.hasExtractCode || r.unzipCodeList.isNotEmpty)
                      _buildCodeRow(context, r),
                    const SizedBox(height: 22),
                    const _SectionCard(
                      title: '汐乃的小请求',
                      background: DarkPalette.requestCardBg,
                      body: '如果这部作品陪你度过了一段愉快的时光，'
                          '请在有条件时支持正版，让创作者能继续把好作品做下去。\n'
                          '分享不易，也请友善对待每一位上传者。',
                    ),
                    const SizedBox(height: 22),
                    const _SectionCard(
                      title: '补票提示',
                      background: DarkPalette.tipCardBg,
                      borderColor: DarkPalette.tipCardBorder,
                      body: '本资源仅供学习与交流使用，请在下载后 24 小时内自行删除。\n'
                          '如果你喜欢这部作品，请前往官方渠道购买正版。',
                    ),
                    const SizedBox(height: 22),
                    _buildFooter(r),
                    const SizedBox(height: 22),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 顶部条 ----------
  Widget _buildHeader(GameResourceModel r) {
    final provider = r.netdiskProviderLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 21, vertical: 14),
      color: DarkPalette.detailHeaderBg,
      child: Row(
        children: [
          Icon(
            r.isPublished
                ? Icons.verified_user_outlined
                : Icons.info_outline_rounded,
            size: 20,
            color: DarkPalette.textPrimary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              r.isPublished ? '该资源链接可用' : '该资源${r.status.label}',
              style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: DarkPalette.textPrimary,
              ),
            ),
          ),
          if (provider.isNotEmpty)
            DarkBadge(
              label: provider,
              background: DarkPalette.badgeGreenBg,
              foreground: DarkPalette.green,
              fontSize: 12,
              padding:
                  const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            ),
          const SizedBox(width: 8),
          DarkCloseButton(onTap: onClose ?? () {}, size: 26),
        ],
      ),
    );
  }

  // ---------- 上传者行 ----------
  Widget _buildOwnerRow(GameResourceModel r) {
    final name = r.ownerName.isNotEmpty ? r.ownerName : '匿名分享者';
    return Row(
      children: [
        AvatarCircle(
          imageUrl: ownerAvatarUrl ?? r.ownerAvatarUrl,
          fallbackAsset: KanbanIdentity.isKanban(r.ownerName)
              ? KanbanIdentity.assetPath
              : null,
          size: 44,
          borderColor: DarkPalette.cardBorder,
          borderWidth: 0.8,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: DarkPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '分享于 ${r.createdDateLabel}'
                '${r.sourceNote.isNotEmpty ? ' · ${r.sourceNote}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DarkPalette.textMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        DarkBadge(
          label: '${r.downloadCount} 次下载',
          background: DarkPalette.badgeNeutralBg,
          foreground: DarkPalette.textSecondary,
          icon: const Icon(Icons.file_download_outlined),
          fontSize: 12,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        ),
      ],
    );
  }

  // ---------- 徽章行 ----------
  Widget _buildBadges(GameResourceModel r) {
    final items = <Widget>[
      for (final t in r.resourceTypes)
        _badge(t, DarkPalette.badgeBlueBg, DarkPalette.lightBlue,
            Icons.videogame_asset_outlined),
      if (r.fileSize.isNotEmpty)
        _badge(r.fileSize, DarkPalette.badgeYellowBg, DarkPalette.yellow,
            Icons.sd_storage_outlined),
      for (final p in r.platforms)
        _badge(p, DarkPalette.badgeGreenBg, DarkPalette.green,
            Icons.desktop_windows_outlined),
      for (final l in r.languages)
        _badge(l, DarkPalette.badgePinkBg, DarkPalette.pink,
            Icons.translate_rounded),
    ];
    if (items.isEmpty) {
      items.add(_badge('未分类', DarkPalette.badgeNeutralBg,
          const Color(0xFFB8B8C2), Icons.label_outline));
    }
    return Wrap(spacing: 8, runSpacing: 8, children: items);
  }

  Widget _badge(String label, Color bg, Color fg, IconData icon) => DarkBadge(
        label: label,
        background: bg,
        foreground: fg,
        icon: Icon(icon),
        fontSize: 12,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      );

  // ---------- 下载链接卡 ----------
  Widget _buildLinkCard(BuildContext context, GameResourceModel r) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(19, 18, 19, 19),
      decoration: BoxDecoration(
        color: DarkPalette.linkCardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardHeading('下载链接'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  r.url.isNotEmpty ? r.url : '（该资源未提供外链）',
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DarkPalette.textBody,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (r.url.isNotEmpty) ...[
                DarkIconButton(
                  icon: const Icon(Icons.copy_rounded),
                  onTap: () => _copy(context, r.url, '链接'),
                  size: 30,
                  radius: 8,
                  background: DarkPalette.badgeNeutralBg,
                  foreground: DarkPalette.textSecondary,
                  tooltip: '复制链接',
                ),
                const SizedBox(width: 8),
                DarkPrimaryButton(
                  label: '打开链接',
                  background: DarkPalette.linkBlue,
                  fontSize: 12,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  radius: 9,
                  onTap: onOpenLink,
                ),
              ],
            ],
          ),
          if (r.versionLabel.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.local_offer_outlined,
                    size: 13, color: DarkPalette.violet),
                const SizedBox(width: 6),
                Text(
                  '版本：${r.versionLabel}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: DarkPalette.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ---------- 提取码 / 解压码 ----------
  Widget _buildCodeRow(BuildContext context, GameResourceModel r) {
    final codes = <Widget>[];
    if (r.hasExtractCode) {
      codes.add(_codeButton(context, '提取码 ${r.extractCode}'));
    }
    final unzip = r.unzipCodeList;
    for (var i = 0; i < unzip.length; i++) {
      final label = unzip.length == 1 ? '解压码' : '解压码${i + 1}';
      codes.add(_codeButton(context, '$label ${unzip[i]}'));
    }
    return Wrap(spacing: 10, runSpacing: 10, children: codes);
  }

  Widget _codeButton(BuildContext context, String text) {
    return DarkPrimaryButton(
      label: text,
      background: DarkPalette.copyGreen,
      foreground: DarkPalette.copyGreenText,
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      radius: 13,
      onTap: () {
        // 只复制「码」本身，方便直接粘贴
        final parts = text.split(' ');
        final code = parts.length > 1 ? parts.last : text;
        _copy(context, code, '提取码');
      },
    );
  }

  // ---------- 底部 ----------
  Widget _buildFooter(GameResourceModel r) {
    return Row(
      children: [
        DarkGhostButton(
          label: '报告失效',
          onTap: onReport,
          foreground: DarkPalette.yellow,
          icon: const Icon(Icons.flag_outlined),
          fontSize: 13,
        ),
        const Spacer(),
        DarkPrimaryButton(
          label: '关闭',
          background: DarkPalette.closeButtonBg,
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
          radius: 13,
          onTap: onClose ?? () {},
        ),
      ],
    );
  }

  void _copy(BuildContext context, String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    AppSnackBar.info(
      context,
      '已复制$what：$text',
      duration: const Duration(seconds: 2),
    );
  }
}

// ============================================================
// 通用小部件
// ============================================================

class _CardHeading extends StatelessWidget {
  const _CardHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        color: DarkPalette.textPrimary,
      ),
    );
  }
}

/// 深色区块卡（标题 + 正文），对应设计里的「发布者备注 / 请求 / 补票提示」
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.body,
    required this.background,
    this.borderColor,
  });

  final String title;
  final String body;
  final Color background;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(19, 18, 19, 19),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: borderColor != null
            ? Border.all(color: borderColor!, width: 0.9)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeading(title),
          const SizedBox(height: 12),
          Text(
            body,
            style: const TextStyle(
              fontSize: 12,
              color: DarkPalette.textBody,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
