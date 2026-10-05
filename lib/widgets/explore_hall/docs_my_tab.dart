import 'package:flutter/material.dart';

import '../../core/pb_config.dart';
import '../../models/game_model.dart';
import '../../models/game_resource_model.dart';
import '../../services/game_publish_service.dart';
import '../../services/game_resource_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../app_snack_bar.dart';
import '../confirm_dialog.dart';
import '../game_detail/dark_surface.dart';
import '../game_detail/publish_game_dialog.dart';
import '../game_detail/upload_resource_dialog.dart';
import '../interactive_wrapper.dart';

/// 文档板块 →【我的】tab（方案 §8.8）。
///
/// 两个分区：
/// | 分区 | 数据源 | 可执行操作 |
/// |---|---|---|
/// | 我发布的游戏 | `games` filter `owner='<uid>' && origin='user'` | 编辑 / 删除 |
/// | 我上传的资源 | `game_resources` filter `owner='<uid>'` | 编辑 / 删除 |
///
/// 🔴 **编辑边界来自服务端规则，不是随意限制**：
/// - `games.updateRule` 含 `review_status != "approved"` ⇒ 已通过的作品不可编辑；
/// - `game_resources.updateRule` 含 `status != "published"` ⇒ 已发布的资源不可编辑。
/// 规则不满足时 PB 返回 **404 而非 403**，所以按钮必须**提前禁用并说明原因**
/// （⛔ 不做「静默禁用」——点击时给出 SnackBar 解释）。
class DocsMyTab extends StatefulWidget {
  const DocsMyTab({super.key, this.onOpenDiscoverGame});

  /// 查看作品在探索库中的详情（可选）
  final void Function(GameModel game)? onOpenDiscoverGame;

  @override
  State<DocsMyTab> createState() => DocsMyTabState();
}

/// 公开 State：宿主（文档板块）在【发布】成功后调用 [reload] 刷新列表。
class DocsMyTabState extends State<DocsMyTab> {
  bool _loading = true;
  String? _error;

  List<GameModel> _games = const [];
  List<GameResourceModel> _resources = const [];

  /// 我的喜欢（作品级）：expand 一跳拿全的 (作品, 喜欢时间) 列表
  /// （my_likes_section.md §2-P1；按喜欢时间倒序，service 已排序）
  List<({GameModel game, DateTime likedAt})> _likedGames = const [];

  /// 我的喜欢（资源级）：v12 部署前查询静默空（resource_likes 读规则
  /// 未开放时普通用户查到空集），部署后自动生效（my_likes_section.md §2-P2）
  List<({GameResourceModel resource, DateTime likedAt})> _likedResources = const [];

  /// 「我的喜欢」分段内的子分段：0 = 作品，1 = 资源
  int _likeSub = 0;

  /// 取消喜欢进行中的记录 id（作品或资源；防重复点击，按钮置为沙漏并禁用）
  final Set<String> _unlikingIds = {};

  /// 0 = 我发布的游戏，1 = 我上传的资源，2 = 我的喜欢
  int _section = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _loggedIn => PBConfig.isLoggedIn;

  /// 供宿主调用（【发布】成功 / 切回本 tab）
  Future<void> reload() => _load();

  Future<void> _load() async {
    if (!_loggedIn) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    List<GameModel> games = const [];
    List<GameResourceModel> resources = const [];
    List<({GameModel game, DateTime likedAt})> likedGames = const [];
    List<({GameResourceModel resource, DateTime likedAt})> likedResources = const [];
    String? err;

    try {
      games = await GamePublishService.fetchMyGames();
    } catch (e) {
      err = e.toString().replaceFirst('Exception: ', '');
    }
    try {
      resources = await GameResourceService.fetchAllMine();
    } catch (e) {
      err ??= e.toString().replaceFirst('Exception: ', '');
    }
    // 我的喜欢（作品/资源）：失败静默空（service 容错一致），不阻塞另两个分区
    likedGames = await GameResourceService.fetchMyLikedGames();
    likedResources = await GameResourceService.fetchMyLikedResources();

    if (!mounted) return;
    setState(() {
      _loading = false;
      _games = games;
      _resources = resources;
      _likedGames = likedGames;
      _likedResources = likedResources;
      _error = err;
    });
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    if (!_loggedIn) return _loginHint();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        const SizedBox(height: 8),
        if (_error != null) ...[
          _errorLine(_error!),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: _loading
              ? const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : switch (_section) {
                  0 => _gameList(),
                  1 => _resourceList(),
                  _ => _likeList(),
                },
        ),
      ],
    );
  }

  Widget _loginHint() {
    // 🔴 必须包可滚动视口：960×540 最小窗口下板块内容区扣掉 2 行标签后
    // 仅剩 ≈58px，Center+Column 不可滚动会纵向溢出（真机 flutter test 抓到
    // 34px 溢出，2026-10-01）。滚动视口给松高度约束，内容按需收缩+可滚动。
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 26, color: AppColors.secondaryText),
              const SizedBox(height: 10),
              Text(
                '登录后可在这里管理你发布的作品、上传的资源与查看喜欢的作品。',
                textAlign: TextAlign.center,
                style: AppStyles.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ⚠️ 两个分段胶囊在最小窗口（960×540）下会超出左区 ≈194px 的可用宽度
        // （main.dart:488 + 板块外壳内边距 14×2），故外层用 Wrap 兜底换行。
        Expanded(
          child: Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              _segment(0, '我的作品 (${_games.length})'),
              _segment(1, '我的资源 (${_resources.length})'),
              _segment(
                  2, '我的喜欢 (${_likedGames.length + _likedResources.length})'),
            ],
          ),
        ),
        const SizedBox(width: 6),
        _iconAction(
          icon: Icons.refresh_rounded,
          tooltip: '刷新',
          onTap: _loading ? null : _load,
        ),
      ],
    );
  }

  Widget _segment(int index, String label) {
    final selected = _section == index;
    // 🔴 包 IntrinsicWidth：InteractiveWrapper 的 AnimatedContainer 带
    // alignment: Alignment.center，在 Wrap 的有界松约束下会撑满整行 ⇒
    // 两个分段胶囊各占一行竖排。IntrinsicWidth 给出 tight 宽度（= 内容宽）。
    return IntrinsicWidth(
      child: InteractiveWrapper(
        onTap: () => setState(() => _section = index),
        hoverScale: 1.04,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.brandBlue.withOpacity(0.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected
                  ? AppColors.brandBlue.withOpacity(0.42)
                  : AppColors.borderLight,
            ),
          ),
          child: Text(
            label,
            style: AppStyles.labelMedium.copyWith(
              fontSize: 11,
              color: selected ? AppColors.brandBlue : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconAction({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: AppColors.buttonBackground,
              borderRadius: BorderRadius.circular(AppRadius.sm + 1),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(icon, size: 13, color: AppColors.primaryText),
          ),
        ),
      ),
    );
  }

  Widget _errorLine(String text) {
    return Row(
      children: [
        Icon(Icons.error_outline_rounded,
            size: 13, color: AppColors.dangerRed),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: AppStyles.microCaption.copyWith(color: AppColors.dangerRed),
          ),
        ),
      ],
    );
  }

  // ---------- 我发布的游戏 ----------

  Widget _gameList() {
    if (_games.isEmpty) {
      return _emptyHint('还没有发布过作品。到【发布】页提交第一部吧。');
    }
    return ListView.separated(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      itemCount: _games.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _gameRow(_games[i]),
    );
  }

  Widget _gameRow(GameModel g) {
    final canEdit = g.canEditAsOwner(GamePublishService.currentUserId);
    final badgeText = g.isReviewApproved
        ? '已通过'
        : (g.isReviewRejected
            ? '已驳回'
            : (g.isReviewEditing
                ? '编辑中'
                : (g.isReviewPendingDelete ? '删除待审' : '审核中')));
    final badgeColor = g.isReviewApproved
        ? AppColors.successGreen
        : ((g.isReviewRejected || g.isReviewPendingDelete)
            ? AppColors.dangerRed
            : AppColors.warningAmber);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  g.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.labelMedium.copyWith(
                    fontSize: 12.5,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _badge(badgeText, badgeColor),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            [
              if (g.developer.isNotEmpty) g.developer,
              _fmtDate(g.created),
            ].where((s) => s.isNotEmpty).join(' · '),
            style: AppStyles.microCaption,
          ),
          if (g.isReviewRejected) ...[
            const SizedBox(height: 4),
            Text(
              '未通过审核：修改并保存后会重新提交审核。',
              style: AppStyles.microCaption.copyWith(
                color: AppColors.dangerRed,
                height: 1.45,
              ),
            ),
          ],
          if (g.isReviewPendingDelete) ...[
            const SizedBox(height: 4),
            Text(
              '删除申请审核中：期间作品保持下架，可撤回申请恢复上架。',
              style: AppStyles.microCaption.copyWith(
                color: AppColors.dangerRed,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 8),
          // ⚠️ Wrap 而非 Row：三个动作在最小窗口下会超出卡片内宽
          // （左区 ≈194px − 卡片内边距 20 = 174px，而「编辑资料+删除+查看」
          // 约需 192px）。用 Row + Spacer 会直接溢出。
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _miniAction(
                label: g.isReviewPendingDelete ? '撤回删除' : '编辑资料',
                icon: g.isReviewPendingDelete
                    ? Icons.undo_rounded
                    : Icons.edit_rounded,
                enabled: canEdit,
                disabledReason: '只能编辑自己发布的作品',
                onTap: () => _editGame(g),
              ),
              _miniAction(
                label: g.isReviewApproved ? '申请删除' : '删除',
                icon: Icons.delete_outline_rounded,
                enabled: g.canDeleteAsOwner(GamePublishService.currentUserId),
                disabledReason: '只能删除自己发布的作品',
                onTap: () => _deleteGame(g),
              ),
              if (widget.onOpenDiscoverGame != null)
                _miniAction(
                  label: '查看',
                  icon: Icons.open_in_new_rounded,
                  onTap: () => widget.onOpenDiscoverGame!(g),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 我上传的资源 ----------

  Widget _resourceList() {
    if (_resources.isEmpty) {
      return _emptyHint('还没有上传过资源。可在作品详情页【上传】或在【发布】第三步提交。');
    }
    return ListView.separated(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      itemCount: _resources.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _resourceRow(_resources[i]),
    );
  }

  Widget _resourceRow(GameResourceModel r) {
    final workName = r.gameTitle.isNotEmpty
        ? r.gameTitle
        : (r.gameId.isNotEmpty ? r.gameId : '未知作品');
    final badgeColor = r.status == ResourceStatus.published
        ? AppColors.successGreen
        : ((r.status == ResourceStatus.rejected ||
                r.status == ResourceStatus.pending_delete)
            ? AppColors.dangerRed
            : (r.status == ResourceStatus.hidden
                ? AppColors.secondaryText
                : AppColors.warningAmber));
    final isPendingDelete = r.status == ResourceStatus.pending_delete;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.title.isEmpty ? '（未命名资源）' : r.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.labelMedium.copyWith(
                    fontSize: 12.5,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _badge(r.status.label, badgeColor),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            [
              '《$workName》',
              if (r.fileSize.isNotEmpty) r.fileSize,
              if (r.version.isNotEmpty) r.version,
              _fmtDate(r.created),
              // 主线补完 §14.2-P1：每条分享的下载/点赞计数（模型已解析字段，
              // 客户端 download 打点接线后此数字开始增长）
              '下载 ${r.downloadCount} · 赞 ${r.likeCount}',
            ].join(' · '),
            maxLines: 2,
            style: AppStyles.microCaption,
          ),
          if (r.status == ResourceStatus.rejected && r.rejectReason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '驳回理由：${r.rejectReason}',
              style: AppStyles.microCaption.copyWith(
                color: AppColors.dangerRed,
                height: 1.45,
              ),
            ),
          ],
          if (isPendingDelete) ...[
            const SizedBox(height: 4),
            Text(
              '删除申请审核中：期间资源保持下架（下载量与点赞数保留），可撤回。',
              style: AppStyles.microCaption.copyWith(
                color: AppColors.dangerRed,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              if (!isPendingDelete) ...[
                _miniAction(
                  label: '编辑',
                  icon: Icons.edit_rounded,
                  onTap: () => _editResource(r),
                ),
                const SizedBox(width: 6),
              ],
              _miniAction(
                label: isPendingDelete
                    ? '撤回删除'
                    : (r.status.isInLibrary ? '申请删除' : '删除'),
                icon: isPendingDelete
                    ? Icons.undo_rounded
                    : Icons.delete_outline_rounded,
                onTap: () => _deleteResource(r),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 我的喜欢（作品级） ----------

  /// 「我的喜欢」分段：顶部作品/资源子胶囊，下方对应列表
  Widget _likeList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              _likeSubPill(0, '作品 (${_likedGames.length})'),
              _likeSubPill(1, '资源 (${_likedResources.length})'),
            ],
          ),
        ),
        Expanded(
          child: _likeSub == 0 ? _likeGameList() : _likeResourceList(),
        ),
      ],
    );
  }

  /// 子分段胶囊（形态同 _segment，但绑定 [_likeSub] 独立状态空间）
  Widget _likeSubPill(int index, String label) {
    final selected = _likeSub == index;
    // 🔴 包 IntrinsicWidth：同 _segment——InteractiveWrapper 在 Wrap 松约束下
    // 会撑满整行，IntrinsicWidth 给出 tight 宽度。
    return IntrinsicWidth(
      child: InteractiveWrapper(
        onTap: () => setState(() => _likeSub = index),
        hoverScale: 1.04,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.brandBlue.withOpacity(0.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected
                  ? AppColors.brandBlue.withOpacity(0.42)
                  : AppColors.borderLight,
            ),
          ),
          child: Text(
            label,
            style: AppStyles.labelMedium.copyWith(
              fontSize: 11,
              color: selected ? AppColors.brandBlue : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _likeGameList() {
    if (_likedGames.isEmpty) {
      return _emptyHint('还没有喜欢的作品。到作品详情页点 ♡ 收藏吧。');
    }
    return ListView.separated(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      itemCount: _likedGames.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _likeRow(_likedGames[i]),
    );
  }

  Widget _likeResourceList() {
    if (_likedResources.isEmpty) {
      // 🔴 v12 部署前 resource_likes 读规则未开放，本列表恒为空集（静默）；
      // 部署后自动生效，文案无需提及部署状态
      return _emptyHint('还没有喜欢的资源。到作品详情页的资源浮层点 ♡ 收藏吧。');
    }
    return ListView.separated(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      itemCount: _likedResources.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _likeResourceRow(_likedResources[i]),
    );
  }

  Widget _likeRow(({GameModel game, DateTime likedAt}) item) {
    final g = item.game;
    final busy = _unlikingIds.contains(g.id);
    return GestureDetector(
      onTap: () => widget.onOpenDiscoverGame?.call(g),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: _card(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppStyles.labelMedium.copyWith(
                        fontSize: 12.5,
                        color: AppColors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (g.developer.isNotEmpty) g.developer,
                        '赞 ${g.likeCount}',
                        '喜欢于 ${_fmtDate(item.likedAt)}',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppStyles.microCaption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _iconAction(
                icon: busy
                    ? Icons.hourglass_top_rounded
                    : Icons.favorite_rounded,
                tooltip: '取消喜欢',
                onTap: busy ? null : () => _unlikeGame(item),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 取消喜欢（乐观移除 → 失败回滚 + 提示，与详情页 _handleLikeTap 同策略）
  Future<void> _unlikeGame(({GameModel game, DateTime likedAt}) item) async {
    final g = item.game;
    setState(() => _unlikingIds.add(g.id));
    final ok = await GameResourceService.setGameLike(g.id, false);
    if (!mounted) return;
    setState(() => _unlikingIds.remove(g.id));
    if (ok) {
      setState(() {
        final next = [..._likedGames]..removeWhere((e) => e.game.id == g.id);
        _likedGames = next;
      });
      AppSnackBar.info(context, '已取消喜欢');
    } else {
      AppSnackBar.error(context, '操作未同步，请稍后再试');
    }
  }

  /// 资源级取消喜欢：走既有资源 unlike 路由（hook 超管通道写删，与读规则无关）
  Future<void> _unlikeResource(
      ({GameResourceModel resource, DateTime likedAt}) item) async {
    final r = item.resource;
    setState(() => _unlikingIds.add(r.id));
    final ok = await GameResourceService.setLike(r.id, false);
    if (!mounted) return;
    setState(() => _unlikingIds.remove(r.id));
    if (ok) {
      setState(() {
        final next =
            [..._likedResources]..removeWhere((e) => e.resource.id == r.id);
        _likedResources = next;
      });
      AppSnackBar.info(context, '已取消喜欢');
    } else {
      AppSnackBar.error(context, '操作未同步，请稍后再试');
    }
  }

  /// 喜欢的资源列表项：无详情跳转目标（资源浮层依赖详情页上下文），
  /// 仅提供取消喜欢；主信息 = 标题 + 所属作品 + 计数 + 喜欢日期
  Widget _likeResourceRow(
      ({GameResourceModel resource, DateTime likedAt}) item) {
    final r = item.resource;
    final busy = _unlikingIds.contains(r.id);
    final workName = r.gameTitle.isNotEmpty
        ? r.gameTitle
        : (r.gameId.isNotEmpty ? r.gameId : '未知作品');
    return _card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title.isEmpty ? '（未命名资源）' : r.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.labelMedium.copyWith(
                    fontSize: 12.5,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    '《$workName》',
                    '下载 ${r.downloadCount} · 赞 ${r.likeCount}',
                    '喜欢于 ${_fmtDate(item.likedAt)}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.microCaption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _iconAction(
            icon: busy ? Icons.hourglass_top_rounded : Icons.favorite_rounded,
            tooltip: '取消喜欢',
            onTap: busy ? null : () => _unlikeResource(item),
          ),
        ],
      ),
    );
  }

  // ---------- 原子件 ----------

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.045)
            : Colors.white.withOpacity(0.55),
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        border: Border.all(
          color: AppColors.isDark
              ? Colors.white.withOpacity(0.07)
              : AppColors.titleBrown.withOpacity(0.12),
        ),
      ),
      child: child,
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withOpacity(0.42)),
      ),
      child: Text(
        label,
        style: AppStyles.microCaption.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _miniAction({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool enabled = true,
    String? disabledReason,
  }) {
    final color = enabled ? AppColors.primaryText : AppColors.secondaryText;
    // 🔴 同 _segment：InteractiveWrapper 带 alignment，在 Wrap 里会撑满整行。
    return IntrinsicWidth(
      child: InteractiveWrapper(
        onTap: () {
          if (!enabled) {
            // ⛔ 不做静默禁用：点得动，但要说明为什么不行
            AppSnackBar.warning(
              context,
              disabledReason ?? '当前状态不支持该操作',
            );
            return;
          }
          onTap();
        },
        hoverScale: 1.04,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.buttonBackground,
              borderRadius: BorderRadius.circular(AppRadius.sm + 1),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: AppStyles.microCaption.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyHint(String text) {
    // 🔴 同 _loginHint：必须包可滚动视口（长文案在最小窗口下会折 3-4 行，
    // 超出板块内容区剩余高度 ⇒ 纵向 RenderFlex 溢出）。
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(text, textAlign: TextAlign.center, style: AppStyles.bodySmall),
        ),
      ),
    );
  }

  // ==================== 操作 ====================

  Future<void> _editGame(GameModel g) async {
    final uid = GamePublishService.currentUserId;
    if (g.ownerId != uid || !g.isUserWork) {
      AppSnackBar.warning(context, '只能编辑自己发布的作品');
      return;
    }
    if (g.isReviewPendingDelete) {
      // 按钮文案已是「撤回删除」——但保险兜底
      await _deleteGame(g);
      return;
    }
    if (g.isReviewApproved) {
      // 统一审核机制：已进库作品发起「编辑即重新上传」——先下架暂存
      final ok = await showConfirmDialog(
        context: context,
        title: '编辑已通过审核的作品',
        message: '发起编辑后《${g.title}》将从探索库暂时下架，'
            '修改并重新提交后需再次审核，通过前其他用户看不到它。',
        confirmText: '发起编辑',
      );
      if (!ok || !mounted) return;
      try {
        await GamePublishService.startGameEditing(g.id);
        if (!mounted) return;
      } catch (e) {
        if (mounted) {
          AppSnackBar.error(context, e.toString().replaceFirst('Exception: ', ''));
        }
        return;
      }
    }
    final ok = await PublishGameDialog.showEdit(context: context, game: g);
    if (ok == true && mounted) {
      AppSnackBar.success(context, '已保存修改，重新进入审核队列');
      await _load();
    }
  }

  Future<void> _deleteGame(GameModel g) async {
    final uid = GamePublishService.currentUserId;
    if (g.ownerId != uid || !g.isUserWork) {
      AppSnackBar.warning(context, '只能删除自己发布的作品');
      return;
    }
    // ---- 撤回删除申请（pending_delete → approved）----
    if (g.isReviewPendingDelete) {
      final ok = await showConfirmDialog(
        context: context,
        title: '撤回删除申请',
        message: '《${g.title}》的删除申请正在审核中。'
            '撤回后作品将恢复上架，数据保持不变。',
        confirmText: '撤回申请',
      );
      if (!ok || !mounted) return;
      try {
        await GamePublishService.withdrawGameDelete(g.id);
        if (!mounted) return;
        AppSnackBar.success(context, '已撤回删除申请，作品恢复上架');
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnackBar.error(context, e.toString().replaceFirst('Exception: ', ''));
        }
      }
      return;
    }
    // ---- 已进库：申请删除（须管理员审核）----
    if (g.isReviewApproved) {
      final ok = await showConfirmDialog(
        context: context,
        title: '申请删除作品',
        message: '《${g.title}》已进入探索库，删除申请将提交管理员审核。'
            '审核通过前作品保持下架，你可随时撤回。\n\n'
            '注意：申请通过后作品与其名下全部资源会被一并删除，不可恢复。',
        confirmText: '申请删除',
        isDanger: true,
      );
      if (!ok || !mounted) return;
      try {
        await GamePublishService.requestGameDelete(g.id);
        if (!mounted) return;
        AppSnackBar.success(context, '删除申请已提交，等待管理员审核');
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnackBar.error(context, e.toString().replaceFirst('Exception: ', ''));
        }
      }
      return;
    }
    // ---- 未进库：直接删除（现状流程）----
    final ok = await showConfirmDialog(
      context: context,
      title: '删除作品',
      message: '确定删除《${g.title}》吗？此操作不可撤销。',
      hint: '该作品名下的全部资源记录会一并删除（级联删除）。',
      confirmText: '删除',
      isDanger: true,
    );
    if (!ok || !mounted) return;
    try {
      await GamePublishService.deleteMyGame(g.id);
      if (!mounted) return;
      AppSnackBar.success(context, '已删除《${g.title}》');
      await _load();
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    }
  }

  Future<void> _editResource(GameResourceModel r) async {
    if (r.status == ResourceStatus.pending_delete) {
      AppSnackBar.warning(context, '删除申请审核中，请先撤回申请');
      return;
    }
    var target = r;
    if (r.status == ResourceStatus.published) {
      // 统一审核机制：已进库资源发起「编辑即重新上传」——先下架暂存
      final ok = await showConfirmDialog(
        context: context,
        title: '编辑已发布资源',
        message: '发起编辑后该资源将从探索库暂时下架'
            '（下载量与点赞数保留）。修改并重新提交后需再次审核，'
            '通过前其他用户看不到它。\n\n'
            '注意：重新提交后原内容不再保留；'
            '如需回退请先记下当前链接与提取码。',
        confirmText: '发起编辑',
      );
      if (!ok || !mounted) return;
      try {
        await GameResourceService.startEditing(r.id);
        if (!mounted) return;
        target = r.copyWith(status: ResourceStatus.editing);
      } catch (e) {
        if (mounted) {
          AppSnackBar.error(context, e.toString().replaceFirst('Exception: ', ''));
        }
        return;
      }
    }
    // 「已驳回 / 编辑中」的资源保存后要能重新进入审核队列
    // （服务端 v6 白名单放行 owner 本人的 rejected→pending / editing→pending）。
    final resubmit = target.status == ResourceStatus.rejected ||
        target.status == ResourceStatus.editing;
    var didResubmit = false;
    final updated = await showDarkCenteredDialog<GameResourceModel>(
      context: context,
      builder: (ctx) => UploadResourceDialog(
        gameTitle: target.gameTitle,
        submitLabel: '保存修改',
        initial: ResourceDraft(
          url: target.url,
          title: target.title,
          fileSize: target.fileSize,
          linkType: target.linkType ?? ResourceLinkType.other,
          netdiskProvider: target.netdiskProvider,
          version: target.version.isEmpty ? null : target.version,
          extractCode: target.extractCode.isEmpty ? null : target.extractCode,
          unzipCode: target.unzipCode.isEmpty ? null : target.unzipCode,
          note: target.note.isEmpty ? null : target.note,
          resourceTypes: target.resourceTypes,
          languages: target.languages,
          platforms: target.platforms,
        ),
        onClose: () => Navigator.of(ctx).maybePop(),
        onSubmit: (draft) async {
          final nav = Navigator.of(ctx);
          final model = target.copyWith(
            url: draft.url,
            title: draft.title,
            fileSize: draft.fileSize,
            version: draft.version ?? '',
            extractCode: draft.extractCode ?? '',
            unzipCode: draft.unzipCode ?? '',
            note: draft.note ?? '',
            resourceTypes: draft.resourceTypes,
            languages: draft.languages,
            platforms: draft.platforms,
          );
          await GameResourceService.updateMine(target.id, model,
              resubmit: resubmit);
          didResubmit = resubmit;
          nav.maybePop();
        },
      ),
    );
    if (!mounted) return;
    if (updated == null) {
      // 弹窗正常关闭也会返回 null —— 统一刷新，保证列表与云端一致
      await _load();
    }
    if (didResubmit) {
      AppSnackBar.success(context, '已重新提交，等待管理员审核');
    }
  }

  Future<void> _deleteResource(GameResourceModel r) async {
    // ---- 撤回删除申请（pending_delete → published）----
    if (r.status == ResourceStatus.pending_delete) {
      final ok = await showConfirmDialog(
        context: context,
        title: '撤回删除申请',
        message: '该资源的删除申请正在审核中。撤回后资源将恢复上架，'
            '下载量与点赞数保持不变。',
        confirmText: '撤回申请',
      );
      if (!ok || !mounted) return;
      try {
        await GameResourceService.withdrawDelete(r.id);
        if (!mounted) return;
        AppSnackBar.success(context, '已撤回删除申请，资源恢复上架');
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnackBar.error(context, e.toString().replaceFirst('Exception: ', ''));
        }
      }
      return;
    }
    // ---- 已进库：申请删除（须管理员审核）----
    if (r.status.isInLibrary) {
      final ok = await showConfirmDialog(
        context: context,
        title: '申请删除资源',
        message: '「${r.title.isEmpty ? '未命名资源' : r.title}」已进入探索库，'
            '删除申请将提交管理员审核。审核通过前资源保持下架，'
            '你可随时撤回。',
        confirmText: '申请删除',
        isDanger: true,
      );
      if (!ok || !mounted) return;
      try {
        await GameResourceService.requestDelete(r.id);
        if (!mounted) return;
        AppSnackBar.success(context, '删除申请已提交，等待管理员审核');
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnackBar.error(context, e.toString().replaceFirst('Exception: ', ''));
        }
      }
      return;
    }
    // ---- 未进库：直接删除（现状流程）----
    final ok = await showConfirmDialog(
      context: context,
      title: '删除资源',
      message: '确定删除「${r.title.isEmpty ? '未命名资源' : r.title}」吗？'
          '此操作不可撤销。',
      confirmText: '删除',
      isDanger: true,
    );
    if (!ok || !mounted) return;
    try {
      await GameResourceService.deleteMine(r.id);
      if (!mounted) return;
      AppSnackBar.success(context, '资源已删除');
      await _load();
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    }
  }

  static String _fmtDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
