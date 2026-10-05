import 'package:flutter/material.dart';

import '../../models/game_resource_model.dart';
import '../../services/game_resource_service.dart';
import 'dark_surface.dart';
import 'kanban_identity.dart';

/// 资源安装状态（下载栏与详情页「获取」按钮共用同一状态源）
enum ResourceInstallState {
  /// 未安装，可获取
  idle,

  /// 已安装
  installed,

  /// 正在安装（带进度）
  installing,

  /// 排队中
  queued,

  /// 不可用（无官方来源 / 未登录等）
  disabled,
}

/// 「Chrono Tide 下载」浮层——锚定在「获取」按钮旁的对话栏（515dp 宽）。
///
/// 设计（`素材/新建文件夹 (2)/官方下载窗口栏.json` + `Shell.png`）：
/// ```
/// Chrono Tide 下载
/// ┌───────────────────────────────────────────┐
/// │ [游戏本体][民间汉化][Windows]              │
/// │ (汐乃) 时之 汐乃          ♥244  ↓245  [⬇] │
/// │        2026-09-01                          │
/// │ [版本信息][0.944 GB]                       │
/// └───────────────────────────────────────────┘
/// ```
///
/// - 顶部徽章 = 资源类型（默认「游戏本体」）+ 平台（默认「Windows」）
/// - 底部徽章 = 版本信息（有则显示）+ 资源大小
/// - 分享者恒为看板娘「时之 汐乃」（官方来源）
///
/// 🔴 **数据源（2026-10-01 修正）**：官方资源 = **`games` 表自身的原生下载**
/// （`downloadUrl` / `version` / `versionNote` / `installCount`），由
/// [OfficialResourceView] 统一承载；`game_resources` 的 `kind=official`
/// 记录只作**可选补充**。切勿再写成"必须有 official 记录才能下载"。
class CtDownloadDialog extends StatefulWidget {
  const CtDownloadDialog({
    super.key,
    required this.gameTitle,
    required this.resource,
    required this.state,
    this.ownerAvatarUrl,
    this.progress = 0,
    this.installedPath,
    this.fallbackFileSize = '',
    this.onDownload,
    this.onCancel,
    this.onReport,
  });

  final String gameTitle;

  /// 官方资源视图；为 null 表示该作品确实没有可下载的官方资源
  final OfficialResourceView? resource;

  final ResourceInstallState state;

  /// 看板娘头像（PB users.avatar 解析后的直链，可空 → 用内置资源）
  final String? ownerAvatarUrl;

  /// 安装进度 0..1（[ResourceInstallState.installing] 时有意义）
  final double progress;

  /// 已安装时的本地路径（展示用）
  final String? installedPath;

  /// 资源大小兜底串（原生来源：`games` 无大小字段，由本地预取
  /// `FileSizePrefetchService` 得到，如 `0.944 GB`）
  final String fallbackFileSize;

  final VoidCallback? onDownload;
  final VoidCallback? onCancel;

  /// 反馈（预设入口）
  final VoidCallback? onReport;

  @override
  State<CtDownloadDialog> createState() => _CtDownloadDialogState();
}

class _CtDownloadDialogState extends State<CtDownloadDialog> {
  late int _likeCount;
  bool _liked = false;

  /// `game_resources` 补充记录的 id。为空表示这条资源没有社区记录 ——
  /// 官方【获取】走的是 `games.downloadUrl` 原生通道，`game_resources`
  /// 的 official 记录「有则补充、无则照旧」。此时点赞只做本地乐观反馈，
  /// **不发**服务端请求（避免对不存在的记录打路由）。
  String get _recordId => widget.resource?.record?.id ?? '';

  @override
  void initState() {
    super.initState();
    // 点赞数：优先取 `game_resources` 补充记录的 like_count，无记录则为 0
    _likeCount = widget.resource?.record?.likeCount ?? 0;
    _loadMyLike();
  }

  /// 回显「我是否赞过这条资源」（`resource_likes` 只开放本人可见）
  Future<void> _loadMyLike() async {
    final id = _recordId;
    if (id.isEmpty) return;
    final liked = await GameResourceService.fetchMyLikedResourceIds([id]);
    if (!mounted) return;
    setState(() => _liked = liked.contains(id));
  }

  void _toggleLike() {
    final id = _recordId;
    final next = !_liked;
    // 乐观更新
    setState(() {
      _liked = next;
      _likeCount += next ? 1 : -1;
      if (_likeCount < 0) _likeCount = 0;
    });
    if (id.isEmpty) return; // 无社区记录：保持既有本地反馈行为
    // 服务端按 (resource, user) 去重后累加（自定义路由）；失败回滚乐观更新
    GameResourceService.setLike(id, next).then((ok) {
      if (ok || !mounted) return;
      setState(() {
        _liked = !next;
        _likeCount += next ? -1 : 1;
        if (_likeCount < 0) _likeCount = 0;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final res = widget.resource;
    return DarkShell(
      width: DarkPalette.downloadBarWidth,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 9),
            child: Text(
              'Chrono Tide 下载',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: DarkPalette.textPrimary,
                letterSpacing: 0.2,
              ),
            ),
          ),
          DarkCard(
            padding: const EdgeInsets.all(9),
            radius: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildBadgeRow(res),
                const SizedBox(height: 9),
                _buildMainRow(res),
                const SizedBox(height: 8),
                _buildFooterRow(res),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 顶部：资源类型 + 平台 ----------
  Widget _buildBadgeRow(OfficialResourceView? res) {
    final types = res?.resourceTypes.isNotEmpty == true
        ? res!.resourceTypes
        : const ['游戏本体'];
    final platforms = res?.platforms.isNotEmpty == true
        ? res!.platforms
        : const ['Windows'];

    final badges = <Widget>[
      for (final t in types)
        DarkBadge(
          label: t,
          background: DarkPalette.badgeBlueBg,
          foreground: DarkPalette.lightBlue,
        ),
      for (final p in platforms)
        DarkBadge(
          label: p,
          background: DarkPalette.badgeGreenBg,
          foreground: DarkPalette.green,
          icon: const Icon(Icons.desktop_windows_outlined),
        ),
    ];

    return Wrap(spacing: 4.5, runSpacing: 4.5, children: badges);
  }

  // ---------- 中部：分享者 + 点赞 / 下载人数 / 下载按钮 ----------
  Widget _buildMainRow(OfficialResourceView? res) {
    // 官方来源的分享者**恒为看板娘**（数据未就绪时也显示她，而非空白）
    final ownerName = (res?.ownerName.isNotEmpty ?? false)
        ? res!.ownerName
        : KanbanIdentity.name;
    final date = res?.createdDateLabel ?? '';
    final downloadCount = res?.downloadCount ?? 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AvatarCircle.kanban(
          imageUrl: widget.ownerAvatarUrl,
          size: 25,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ownerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DarkPalette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (date.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '分享于 $date',
                  style: const TextStyle(
                    fontSize: 10,
                    color: DarkPalette.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 6),
        _buildLikeChip(),
        const SizedBox(width: 9),
        _buildDownloadCount(downloadCount),
        const SizedBox(width: 9),
        _buildActionButton(),
      ],
    );
  }

  Widget _buildLikeChip() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _toggleLike,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _liked ? Icons.favorite : Icons.favorite_border,
              size: 12.5,
              color: _liked ? const Color(0xFFFF5A63) : DarkPalette.textDim,
            ),
            const SizedBox(width: 3),
            Text(
              '$_likeCount',
              style: TextStyle(
                fontSize: 11,
                color: _liked ? const Color(0xFFFF5A63) : DarkPalette.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadCount(int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.file_download_outlined,
          size: 12.5,
          color: DarkPalette.textDim,
        ),
        const SizedBox(width: 3),
        Text(
          '$count',
          style: const TextStyle(fontSize: 11, color: DarkPalette.textDim),
        ),
      ],
    );
  }

  Widget _buildActionButton() {
    switch (widget.state) {
      case ResourceInstallState.installing:
        return DarkIconButton(
          icon: const Icon(Icons.stop_rounded),
          onTap: widget.onCancel,
          size: 26,
          radius: 8,
          background: DarkPalette.badgeNeutralBg,
          foreground: DarkPalette.textSecondary,
          tooltip: '取消安装',
        );
      case ResourceInstallState.disabled:
        return const DarkIconButton(
          icon: Icon(Icons.download_rounded),
          onTap: null,
          size: 26,
          radius: 8,
          background: DarkPalette.badgeNeutralBg,
          foreground: DarkPalette.placeholder,
          tooltip: '暂无可下载的官方资源',
        );
      default:
        return DarkIconButton(
          icon: const Icon(Icons.download_rounded),
          onTap: widget.onDownload,
          size: 26,
          radius: 8,
          background: DarkPalette.actionBlue,
          foreground: Colors.white,
          tooltip: _actionTooltip,
        );
    }
  }

  String get _actionTooltip {
    switch (widget.state) {
      case ResourceInstallState.installed:
        return '已安装 · 点击重新下载';
      case ResourceInstallState.queued:
        return '已加入队列 · 点击查看';
      default:
        return '下载并安装';
    }
  }

  // ---------- 进度条（安装中）----------
  // ---------- 底部：版本信息 + 大小 ----------
  Widget _buildFooterRow(OfficialResourceView? res) {
    // 版本：原生 games 的 version/versionNote；大小：优先资源记录，
    // 为空时由调用方通过 [fallbackFileSize] 传入本地预取结果。
    final version = res?.versionLabel ?? '';
    final size = (res?.fileSize.isNotEmpty ?? false)
        ? res!.fileSize
        : widget.fallbackFileSize;
    final hasAny = version.isNotEmpty || size.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.state == ResourceInstallState.installing) ...[
          _buildProgressBar(),
          const SizedBox(height: 8),
        ],
        if (hasAny)
          Wrap(
            spacing: 4.5,
            runSpacing: 4.5,
            children: [
              if (version.isNotEmpty)
                DarkBadge(
                  label: version,
                  background: DarkPalette.badgeVioletBg,
                  foreground: DarkPalette.violet,
                  icon: const Icon(Icons.local_offer_outlined),
                ),
              if (size.isNotEmpty)
                DarkBadge(
                  label: size,
                  background: DarkPalette.badgeNeutralBg,
                  foreground: DarkPalette.textSecondary,
                  icon: const Icon(Icons.sd_storage_outlined),
                ),
              if (widget.state == ResourceInstallState.installed)
                const DarkBadge(
                  label: '已安装',
                  background: DarkPalette.badgeGreenBg,
                  foreground: DarkPalette.green,
                  icon: Icon(Icons.check_circle_outline),
                ),
              if (widget.state == ResourceInstallState.queued)
                const DarkBadge(
                  label: '排队中',
                  background: DarkPalette.badgeYellowBg,
                  foreground: DarkPalette.yellow,
                  icon: Icon(Icons.schedule_outlined),
                ),
            ],
          ),
        if (!hasAny && widget.state == ResourceInstallState.installing) ...[
          _buildProgressLabel(),
        ],
        if (widget.onReport != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: DarkGhostButton(
              label: '反馈',
              onTap: widget.onReport,
              foreground: DarkPalette.yellow,
              icon: const Icon(Icons.flag_outlined),
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProgressBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: widget.progress.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: DarkPalette.badgeNeutralBg,
            valueColor: const AlwaysStoppedAnimation(DarkPalette.primaryBlue),
          ),
        ),
        const SizedBox(height: 5),
        _buildProgressLabel(),
      ],
    );
  }

  Widget _buildProgressLabel() {
    final pct = (widget.progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0);
    return Text(
      '正在下载并安装 · $pct%',
      style: const TextStyle(fontSize: 10.5, color: DarkPalette.textMuted),
    );
  }
}
