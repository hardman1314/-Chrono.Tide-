import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/pb_config.dart';
import '../../models/game_model.dart';
import '../../services/game_publish_service.dart';
import '../app_snack_bar.dart';
import '../nsfw/nsfw_image.dart';
import 'dark_surface.dart';
import 'publish_game_dialog.dart';

/// 探索页顶栏「上传 / 发布」选择器（2026-10-02 UI 优化，需求 3b）。
///
/// 与探索大厅文档板块【发布】tab 形成发布双通道；窗口内先判重再分流：
/// ```
/// 搜索游戏名 → 命中已有作品 → 选中 → 跳详情页并自动弹出【上传】窗口
///            → 未命中       → 「自行发布」→ 「发布 Galgame」窗口
/// ```
///
/// 命中跳转复用一次性信号 `GameDetailPage.pendingAutoUploadGameId`：
/// 调用方（DiscoverPage）设置信号后走 `onGameTap` 通道，详情页 initState
/// 消费并自动弹上传（零稳定区改动，同文档板块判重命中那一类投稿）。
class UploadPublishDialog extends StatefulWidget {
  const UploadPublishDialog({
    super.key,
    required this.onSelectGame,
    this.onClose,
  });

  /// 选中已有作品 → 调用方跳转该作品探索详情页（并自动弹上传窗口）
  final void Function(GameModel game) onSelectGame;

  final VoidCallback? onClose;

  /// 弹出窗口。未登录直接SnackBar提示并跳过（不弹窗）。
  static Future<void> show(
    BuildContext context, {
    required void Function(GameModel game) onSelectGame,
  }) {
    if (!PBConfig.isLoggedIn) {
      AppSnackBar.warning(context, '该功能需要登录账号后使用');
      return Future.value();
    }
    return showDarkCenteredDialog<void>(
      context: context,
      builder: (ctx) => UploadPublishDialog(
        onSelectGame: onSelectGame,
        onClose: () => Navigator.of(ctx).maybePop(),
      ),
    );
  }

  @override
  State<UploadPublishDialog> createState() => _UploadPublishDialogState();
}

class _UploadPublishDialogState extends State<UploadPublishDialog> {
  final _nameCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  bool _checking = false;
  bool _submitting = false;

  /// null = 尚未搜索；非 null = 搜索结果（可能为空列表 = 未命中）
  List<GameModel>? _results;
  String _queriedName = '';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_checking) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      AppSnackBar.warning(context, '请先输入游戏名再搜索');
      return;
    }
    setState(() {
      _checking = true;
      _results = null;
    });
    final list = await GamePublishService.searchByTitle(name);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _queriedName = name;
      _results = list;
    });
    if (list.isEmpty) {
      // 未命中 → 自动聚焦「自行发布」，提示语义在结果区给出
      _searchFocus.unfocus();
    }
  }

  void _pick(GameModel g) {
    if (_submitting) return;
    widget.onSelectGame(g);
    widget.onClose?.call();
  }

  /// 未命中 → 转入发布流程（询问语义由本按钮承担：点击即打开发布窗口，
  /// 用户可随时取消；发布成功后本窗口一并关闭）
  Future<void> _publishInstead() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final ok = await PublishGameDialog.show(
        context: context,
        initialTitle: _queriedName,
      );
      if (!mounted) return;
      if (ok == true) widget.onClose?.call();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DarkShell(
      width: 540,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 14),
          _buildSearchRow(),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              clipBehavior: Clip.hardEdge,
              child: _buildResultArea(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '发布 / 上传',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: DarkPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '已有这部作品？选中后进入详情页直接上传资源；'
                '还没有？可以自行发布它。',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DarkPalette.textMuted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        DarkCloseButton(onTap: widget.onClose ?? () {}, size: 24),
      ],
    );
  }

  Widget _buildSearchRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF23232A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
            ),
            child: Center(
              child: TextField(
                controller: _nameCtrl,
                focusNode: _searchFocus,
                onSubmitted: (_) => _search(),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: DarkPalette.textPrimary,
                  height: 1.2,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '输入游戏名，例如 千恋＊万花',
                  hintStyle: TextStyle(
                    fontSize: 12.5,
                    color: DarkPalette.placeholder.withOpacity(0.85),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        DarkPrimaryButton(
          label: _checking ? '搜索中…' : '搜索',
          busy: _checking,
          onTap: _search,
          background: DarkPalette.primaryBlue,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          radius: 8,
          fontSize: 12.5,
        ),
      ],
    );
  }

  Widget _buildResultArea() {
    final results = _results;
    if (results == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: Text(
            '输入游戏名开始搜索',
            style: const TextStyle(
                fontSize: 12, color: DarkPalette.placeholder),
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return _buildNotFoundPanel();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '探索库中已有 ${results.length} 部匹配《$_queriedName》的作品',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: DarkPalette.yellow,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < results.length; i++) ...[
          _buildGameRow(results[i]),
          if (i < results.length - 1) const SizedBox(height: 6),
        ],
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildGameRow(GameModel g) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 7, 10, 7),
      decoration: BoxDecoration(
        color: const Color(0xFF23232A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
      ),
      child: Row(
        children: [
          _coverThumb(g.coverUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  g.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: DarkPalette.textPrimary,
                  ),
                ),
                if (g.developer.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    g.developer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: DarkPalette.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          DarkPrimaryButton(
            label: '上传资源',
            icon: const Icon(Icons.upload_rounded),
            background: DarkPalette.linkBlue,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            radius: 999,
            fontSize: 11,
            onTap: () => _pick(g),
          ),
        ],
      ),
    );
  }

  /// 列表行封面缩略（48×64，2:3）；无封面用占位图标
  Widget _coverThumb(String coverUrl) {
    return Container(
      width: 48,
      height: 64,
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B21),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: DarkPalette.fieldBorder, width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: coverUrl.isEmpty
          ? const Icon(Icons.image_outlined,
              size: 16, color: DarkPalette.placeholder)
          : NsfwImage.network(
              coverUrl,
              contentKind: NsfwContentKind.cover,
              fit: BoxFit.cover,
              width: 48,
              height: 64,
              child: CachedNetworkImage(
                imageUrl: coverUrl,
                width: 48,
                height: 64,
                fit: BoxFit.cover,
                memCacheWidth: 96,
                errorWidget: (_, __, ___) => const Icon(Icons.image_outlined,
                    size: 16, color: DarkPalette.placeholder),
              ),
            ),
    );
  }

  Widget _buildNotFoundPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DarkPalette.badgeGreenBg.withOpacity(0.55),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: DarkPalette.green.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '探索库中还没有《$_queriedName》',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: DarkPalette.green,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            '你可以自行发布这部作品：填写游戏资料并上传资源，提交后经管理员审核进入探索库。',
            style: TextStyle(
              fontSize: 11.5,
              color: DarkPalette.textMuted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          DarkPrimaryButton(
            label: _submitting ? '打开发布窗口…' : '自行发布这部作品',
            icon: const Icon(Icons.rocket_launch_rounded),
            busy: _submitting,
            onTap: _publishInstead,
            background: DarkPalette.primaryBlue,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            radius: 9,
            fontSize: 12,
          ),
        ],
      ),
    );
  }
}
