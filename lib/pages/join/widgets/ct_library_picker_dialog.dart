import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../core/portable_image_cache_manager.dart';
import '../../../models/game_model.dart';
import '../../../repositories/game_repository.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/app_dialog.dart';
import '../../../widgets/interactive_wrapper.dart';
import '../../../widgets/nsfw/nsfw_image.dart';
import '../join_controller.dart';

/// CT 探索库作品选择弹窗（2026-10-05）
///
/// 展示 CT 探索库（自有 PocketBase `games` 集合）中的全部作品并支持
/// 搜索查找（标题/日文原名/英文名/繁中别名模糊匹配），用户点击某个
/// 作品后经 [JoinController.importFromCtLibrary] 自动导入添加页左侧
/// 数据板块。
///
/// 数据通道：与探索页全量加载同源（[GameRepository.getAllGames]，
/// 服务端分页驱动 + 单页重试 + id 去重），搜索在客户端本地过滤
/// （探索库当前数百条量级，全量拉取一次后本地过滤零延迟）。
class CtLibraryPickerDialog extends StatefulWidget {
  final JoinController controller;

  const CtLibraryPickerDialog({super.key, required this.controller});

  @override
  State<CtLibraryPickerDialog> createState() => _CtLibraryPickerDialogState();
}

class _CtLibraryPickerDialogState extends State<CtLibraryPickerDialog> {
  /// null = 加载中；加载失败时 [_error] 非空
  List<GameModel>? _games;
  String _error = '';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _games = null;
      _error = '';
    });
    try {
      final result = await GameRepository.getAllGames();
      if (!mounted) return;
      setState(() => _games = result.games);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载失败，请检查网络后重试');
    }
  }

  /// 本地搜索过滤：标题 / 日文原名 / 英文名 / 繁中别名。
  ///
  /// 匹配统一走 [CTService.normalizeForSearch]（小写化 + 全角→半角 +
  /// 去空白标点）——用户输入「美少女万華鏡１」「Bishoujo Mangekyou!」
  /// 等变体或部分名称时仍能命中（2026-10-05 别名索引优化）。
  List<GameModel> get _filteredGames {
    final all = _games;
    if (all == null) return const [];
    final q = CTService.normalizeForSearch(_query.trim());
    if (q.isEmpty) return all;
    return all.where((g) {
      final haystack = <String>[
        g.title,
        g.originalTitle,
        g.englishTitle,
        g.traditionalChineseTitle,
      ].map(CTService.normalizeForSearch).join('\n');
      return haystack.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 560,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 2),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 5),
                blurRadius: 0,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              _buildSearchBar(),
              Flexible(child: _buildBody()),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final games = _games;
    final countText = games == null
        ? '加载中...'
        : '${games.length} 部作品';
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.shadowColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.travel_explore, size: 18, color: AppColors.border),
          const SizedBox(width: 8),
          Text(
            'CT 探索库',
            style: TextStyle(
              fontSize: 18,
              letterSpacing: 2.0,
              color: AppColors.border,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            countText,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.secondaryText,
            ),
          ),
          const Spacer(),
          // 刷新按钮
          InteractiveWrapper(
            onTap: _games == null ? null : _load,
            cursor: _games == null
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.refresh,
                  size: 18, color: AppColors.secondaryText),
            ),
          ),
          const SizedBox(width: 4),
          // 关闭按钮
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child:
                  Icon(Icons.close, size: 18, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border, width: 1.4),
        ),
        child: TextField(
          autofocus: true,
          onChanged: (v) => setState(() => _query = v),
          style: TextStyle(
            fontSize: 13,
            color: AppColors.primaryText,
          ),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search,
                size: 16, color: AppColors.secondaryText),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            hintText: '搜索作品（标题 / 日文原名 / 英文名 / 繁中别名）',
            hintStyle: TextStyle(
              fontSize: 12,
              color: AppColors.inputHint,
            ),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // 加载中
    if (_games == null && _error.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.border),
              ),
              const SizedBox(height: 12),
              Text(
                '正在从 CT 探索库加载作品...',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 加载失败
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off,
                  size: 32, color: AppColors.secondaryText),
              const SizedBox(height: 10),
              Text(
                _error,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(height: 14),
              InteractiveWrapper(
                onTap: _load,
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    border: Border.all(color: AppColors.border, width: 1.4),
                  ),
                  child: Text(
                    '重试',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.border,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final items = _filteredGames;

    // 空结果
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _query.trim().isEmpty ? '探索库暂无作品' : '未找到与「${_query.trim()}」匹配的作品',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.secondaryText,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      itemCount: items.length,
      itemBuilder: (context, index) =>
          _buildGameRow(context, items[index]),
    );
  }

  Widget _buildGameRow(BuildContext context, GameModel game) {
    final aliases = game.aliasTitles;
    final year = game.releaseDate.length >= 4
        ? game.releaseDate.substring(0, 4)
        : '';
    final metaLine = <String>[
      if (game.developer.trim().isNotEmpty) game.developer.trim(),
      if (year.isNotEmpty) '$year 发行',
    ].join(' · ');

    return InteractiveWrapper(
      onTap: () {
        Navigator.of(context).pop();
        widget.controller.importFromCtLibrary(game);
      },
      hoverScale: 1.0,
      hoverOffset: Offset.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.borderLight, width: 1.2),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 竖版封面（NSFW 处理与一键抓取结果卡片同款）
              Container(
                width: 42,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.placeholderCover,
                  border:
                      Border.all(color: AppColors.border, width: 1.2),
                ),
                clipBehavior: Clip.hardEdge,
                child: _buildCoverImage(game),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        game.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.titleBrown,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (aliases.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          aliases.join(' / '),
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.secondaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (metaLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          metaLine,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.secondaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (game.tags.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          game.tags.take(4).join(' / '),
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.secondaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // 评分角标（云端沉淀值，无评分不显示）
              if (game.rating != null && game.rating! > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    game.rating!.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.border,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(GameModel game) {
    final coverUrl = game.coverUrl;
    if (coverUrl.isNotEmpty && coverUrl.startsWith('http')) {
      return NsfwImage.network(
        coverUrl,
        contentKind: NsfwContentKind.cover,
        width: 42,
        height: 56,
        detectOnDemand: true,
        child: CachedNetworkImage(
          cacheManager: PortableImageCacheManager(),
          imageUrl: coverUrl,
          width: 42,
          height: 56,
          fit: BoxFit.cover,
          memCacheWidth: 84,
          memCacheHeight: 112,
          placeholder: (context, url) => Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.border),
            ),
          ),
          errorWidget: (context, url, error) => Center(
            child:
                Icon(Icons.image_outlined, size: 14, color: AppColors.border),
          ),
        ),
      );
    }
    return Center(
      child: Icon(Icons.image_outlined, size: 16, color: AppColors.border),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.shadowColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 13, color: AppColors.secondaryText),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '数据来自 CT 探索库（社区共建中文元数据平台），点击作品即导入左侧数据板块',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: AppColors.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 显示 CT 探索库作品选择弹窗
void showCtLibraryPickerDialog(BuildContext context, JoinController controller) {
  showAppDialog(
    context: context,
    builder: (context) => CtLibraryPickerDialog(controller: controller),
  );
}
