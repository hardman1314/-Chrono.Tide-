import 'package:flutter/material.dart';

import '../../core/pb_config.dart';
import '../../models/game_model.dart';
import '../../pages/game_detail_page.dart';
import '../../services/game_publish_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../game_detail/publish_game_dialog.dart';
import '../interactive_wrapper.dart';

/// 文档板块 →【发布】tab —— 发布三步的**第 1 步**：
/// 输入游戏名 → 判定探索库中是否已存在（方案 §8.7②）。
///
/// - **命中**：内联列出匹配到的作品，点「前往上传资源」跳到该作品探索详情页
///   （那里有【上传】入口 —— 即「资源投稿」那一类，只写 `game_resources`）。
/// - **未命中**：弹出「发布 Galgame」窗口，进入第 2 步（游戏资料）与第 3 步（资源）。
///
/// ⚠️ 本 tab **完全在板块内完成第一步**，不弹窗、不跳路由。
class DocsPublishTab extends StatefulWidget {
  const DocsPublishTab({
    super.key,
    this.onOpenDiscoverGame,
    this.onPublished,
  });

  /// 命中已有作品 → 交给宿主跳转到探索详情页
  final void Function(GameModel game)? onOpenDiscoverGame;

  /// 发布成功后的回调（供【我的】刷新）
  final VoidCallback? onPublished;

  @override
  State<DocsPublishTab> createState() => _DocsPublishTabState();
}

class _DocsPublishTabState extends State<DocsPublishTab> {
  final _nameCtrl = TextEditingController();

  bool _checking = false;
  bool _submitting = false;
  String? _error;

  /// 「发布说明」默认收起（2026-10-02 UI 优化）：进入面板不再直铺大段文字，
  /// 点搜索框下方的折叠按钮才展开，避免说明占满面板、妨碍操作。
  bool _showGuide = false;

  /// null = 尚未查询；非 null = 查询结果（可能为空列表）
  List<GameModel>? _matches;
  String _queriedName = '';
  bool _lastQueryFailed = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _loggedIn => PBConfig.isLoggedIn;

  // ==================== 第 1 步：判重 ====================

  Future<void> _handleNext() async {
    if (_checking) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请先填写游戏名称');
      return;
    }
    if (!_loggedIn) {
      // 本地账号体系：统一权限文案（local_account_mode.md §2.5-7）
      setState(() => _error = '该功能需要登录账号后使用');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
      _matches = null;
    });

    final list = await GamePublishService.searchByTitle(name);
    if (!mounted) return;

    // 查询失败与「确实不存在」都会得到空列表 —— 用一次额外的探针区分不了
    // （searchByTitle 内部已静默降级），故此处只标记可能失败，不阻断流程。
    setState(() {
      _checking = false;
      _queriedName = name;
      _matches = list;
      _lastQueryFailed = false;
    });

    // 未命中时**不自动弹窗**：只在面板内给出「继续发布」入口，
    // 由用户点击后再打开「发布 Galgame」窗口（开发者明确要求）。
  }

  /// 命中已有作品：进它的探索详情页，并让它打开后**自动弹出【上传】窗口**。
  ///
  /// 走一次性信号 [GameDetailPage.pendingAutoUploadGameId] ⇒ 零稳定区改动
  /// （不需要动 main_container 的详情页构建）。详情页 initState 消费后立即清空。
  void _openGameAndUpload(GameModel g) {
    GameDetailPage.pendingAutoUploadGameId = g.id;
    widget.onOpenDiscoverGame?.call(g);
  }

  // ==================== 第 2 / 3 步：发布窗口 ====================

  Future<void> _openPublishDialog(String name) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final ok = await PublishGameDialog.show(
        context: context,
        initialTitle: name,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        if (ok == true) {
          _nameCtrl.clear();
          _matches = null;
          _queriedName = '';
        }
      });
      if (ok == true) widget.onPublished?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = '打开发布窗口失败：$e';
        });
      }
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _inputRow(),
          const SizedBox(height: 6),
          _guideToggle(),
          if (_showGuide) ...[
            const SizedBox(height: 6),
            _intro(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            _errorLine(),
          ],
          if (_matches != null) ...[
            const SizedBox(height: 12),
            if (_matches!.isNotEmpty) _matchList() else _notFoundPanel(),
          ],
        ],
      ),
    );
  }

  /// 「发布说明」折叠按钮：ghost 小胶囊，点击展开/收起原说明文案
  Widget _guideToggle() {
    return IntrinsicWidth(
      child: InteractiveWrapper(
        onTap: () => setState(() => _showGuide = !_showGuide),
        hoverScale: 1.03,
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 12, color: AppColors.secondaryText),
              const SizedBox(width: 4),
              Text(
                '发布说明',
                style: AppStyles.microCaption.copyWith(
                  color: AppColors.secondaryText,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 3),
              AnimatedRotation(
                turns: _showGuide ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(Icons.expand_more_rounded,
                    size: 13, color: AppColors.secondaryText),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.white.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        border: Border.all(color: AppColors.border.withOpacity(0.7)),
      ),
      child: Text(
        '把你的作品带进探索库。\n\n'
        '第 1 步 · 填写游戏名：我们会先查探索库中是否已有这部作品。\n'
        '　· 已有 → 直接跳到该作品详情页【上传】资源；\n'
        '　· 没有 → 继续填写游戏资料并上传资源，一次提交。\n\n'
        '提交后需管理员审核，通过后才对所有用户可见。',
        style: AppStyles.bodySmall.copyWith(height: 1.5),
      ),
    );
  }

  Widget _inputRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.isDark
                  ? Colors.white.withOpacity(0.05)
                  : Colors.white.withOpacity(0.7),
              borderRadius: BorderRadius.circular(AppRadius.sm + 2),
              border: Border.all(color: AppColors.border),
            ),
            child: Center(
              child: TextField(
                controller: _nameCtrl,
                onSubmitted: (_) => _handleNext(),
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.primaryText,
                  height: 1.2,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '输入游戏名称，例如 千恋＊万花',
                  hintStyle: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.secondaryText.withOpacity(0.75),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _pillButton(
          label: _checking ? '查询中…' : '下一步',
          icon: _checking ? null : Icons.arrow_forward_rounded,
          accent: AppColors.brandBlue,
          filled: true,
          onTap: (_checking || _submitting) ? null : _handleNext,
        ),
      ],
    );
  }

  Widget _errorLine() {
    return Row(
      children: [
        Icon(Icons.error_outline_rounded,
            size: 13, color: AppColors.dangerRed),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _error!,
            style: AppStyles.microCaption.copyWith(color: AppColors.dangerRed),
          ),
        ),
      ],
    );
  }

  Widget _matchList() {
    final list = _matches!.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '探索库中已有 ${_matches!.length} 部匹配《$_queriedName》的作品',
          style: AppStyles.microCaption.copyWith(
            color: AppColors.warningAmber,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        for (final g in list) ...[
          _matchRow(g),
          const SizedBox(height: 6),
        ],
        const SizedBox(height: 2),
        Text(
          '这类作品请走【上传】：在它的详情页提交你的资源链接即可，无需重复创建作品。',
          style: AppStyles.microCaption.copyWith(
            color: AppColors.secondaryText,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _matchRow(GameModel g) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                    fontSize: 12,
                    color: AppColors.primaryText,
                  ),
                ),
                if (g.developer.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    g.developer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppStyles.microCaption,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _pillButton(
            label: '前往上传资源',
            icon: Icons.upload_rounded,
            accent: AppColors.brandBlue,
            onTap: () => _openGameAndUpload(g),
          ),
        ],
      ),
    );
  }

  Widget _notFoundPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.045)
            : Colors.white.withOpacity(0.55),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: AppColors.isDark
              ? Colors.white.withOpacity(0.07)
              : AppColors.titleBrown.withOpacity(0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '探索库中还没有《$_queriedName》'
            '${_lastQueryFailed ? '（查询可能失败，按未收录处理）' : ''}',
            style: AppStyles.microCaption.copyWith(
              color: AppColors.successGreen,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '可以继续发布：第 2 步填写游戏资料，第 3 步上传资源，一次提交送审。',
            style: AppStyles.microCaption.copyWith(height: 1.5),
          ),
          const SizedBox(height: 10),
          _pillButton(
            label: _submitting ? '打开中…' : '继续发布',
            icon: Icons.rocket_launch_rounded,
            accent: AppColors.brandBlue,
            filled: true,
            onTap: _submitting
                ? null
                : () => _openPublishDialog(_queriedName),
          ),
        ],
      ),
    );
  }

  Widget _pillButton({
    required String label,
    required Color accent,
    IconData? icon,
    bool filled = false,
    VoidCallback? onTap,
  }) {
    // 🔴 包 IntrinsicWidth：InteractiveWrapper 的 AnimatedContainer 带
    // alignment: Alignment.center，放在 Column/横排松约束里会撑满整行
    // （_notFoundPanel 里的「继续发布」曾因此变成通栏色块）。
    return IntrinsicWidth(
      child: InteractiveWrapper(
        onTap: onTap,
        hoverScale: 1.03,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color:
                filled ? accent.withOpacity(0.14) : AppColors.buttonBackground,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: filled ? accent.withOpacity(0.45) : AppColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 12, color: filled ? accent : AppColors.primaryText),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: AppStyles.microCaption.copyWith(
                  color: filled ? accent : AppColors.primaryText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
