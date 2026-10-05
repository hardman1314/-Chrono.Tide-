import 'package:flutter/material.dart';

import '../../models/series_model.dart';
import '../../repositories/series_repository.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../interactive_wrapper.dart';
import '../series_panel.dart';
import 'hall_cover_image.dart';
import 'hall_section_shell.dart';
import 'hall_visuals.dart';

/// 板块⑤：Galgame 系列合集
///
/// 云端 PB series 集合整表展示（横向卡片）；
/// 点卡片 → 成员面板（getSeriesDataById，复用详情页完整系列弹层
/// [SeriesPanel]，无当前作品模式，风格与详情页统一）；
/// 「全部」→ 可搜索的全部合集列表；
/// 面板内点作品经 [onOpenGame] 跳探索详情页。
class SeriesSection extends StatefulWidget {
  /// 整表加载器（默认 SeriesRepository.fetchAllSeries；测试可注入）
  final Future<List<SeriesModel>> Function()? loader;

  /// 面板内点作品跳详情页（大厅接线 main_container 通道；null=纯展示）
  final void Function(String gameId, String title, String coverUrl)?
      onOpenGame;

  const SeriesSection({super.key, this.loader, this.onOpenGame});

  @override
  State<SeriesSection> createState() => _SeriesSectionState();
}

class _SeriesSectionState extends State<SeriesSection> {
  List<SeriesModel>? _series; // null = 加载中
  bool _openingMembers = false; // 防双击重复拉取/叠开面板

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await (widget.loader ?? SeriesRepository.fetchAllSeries)();
      if (!mounted) return;
      setState(() => _series = data);
    } catch (_) {
      if (!mounted) return;
      setState(() => _series = const []);
    }
  }

  /// 打开系列成员面板：拉全量数据后挂 Overlay 面板
  /// （复用详情页 [SeriesPanel]，currentGameId 空 = 无当前作品模式）
  Future<void> _openMembers(SeriesModel series) async {
    if (_openingMembers) return;
    _openingMembers = true;
    try {
      final data = await SeriesRepository.getSeriesDataById(series.id);
      if (!mounted) return;
      if (data == null || data.entries.isEmpty) return; // 静默：失败不弹
      SeriesPanel.show(
        context,
        seriesData: data,
        currentGameId: '',
        onNavigateToGame: (gameId, title, coverUrl) =>
            widget.onOpenGame?.call(gameId, title, coverUrl),
      );
    } finally {
      _openingMembers = false;
    }
  }

  Future<void> _openAll() async {
    final all = _series;
    if (all == null || all.isEmpty) return;
    SeriesModel? picked;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _AllSeriesDialog(
        seriesList: all,
        onPick: (s) {
          picked = s;
          Navigator.of(ctx).pop();
        },
      ),
    );
    if (picked != null && mounted) await _openMembers(picked!);
  }

  @override
  Widget build(BuildContext context) {
    final series = _series;
    return HallSectionShell(
      title: '系列合集',
      subtitle: series == null
          ? '云端加载中…'
          : (series.isEmpty ? '云端暂无数据' : '云端整理 · ${series.length} 个'),
      icon: Icons.layers_rounded,
      iconAccent: AppColors.infoBlue,
      engCaption: 'SERIES',
      trailing: series != null && series.isNotEmpty
          ? InteractiveWrapper(
              onTap: _openAll,
              hoverScale: 1.06,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.collections_bookmark_rounded,
                        size: 11, color: AppColors.primaryText),
                    const SizedBox(width: 3),
                    Text('全部', style: AppStyles.microCaption),
                  ],
                ),
              ),
            )
          : null,
      child: series == null
          ? const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : series.isEmpty
              ? const HallEmptyHint(
                  text: '暂无系列数据（网络不可用或云端为空）',
                  icon: Icons.collections_bookmark_rounded,
                )
              : HallHScroll(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemCount: series.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _SeriesChip(
                    series: series[i],
                    onTap: () => _openMembers(series[i])),
              ),
            ),
    );
  }
}

/// 单个合集卡片：封面全幅 + 底部渐变压字 + 左上「系列/合集」角标
class _SeriesChip extends StatelessWidget {
  final SeriesModel series;
  final VoidCallback onTap;

  const _SeriesChip({required this.series, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InteractiveWrapper(
      onTap: onTap,
      hoverScale: 1.03,
      child: SizedBox(
        width: 132,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Stack(
            fit: StackFit.expand,
            children: [
              HallCoverImage(networkUrl: series.coverUrl),
              // 底部渐变压字（白字在深浅主题的封面上都要暗底）
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration:
                      BoxDecoration(gradient: HallGradients.coverScrim),
                  child: SizedBox(height: 30),
                ),
              ),
              Positioned(
                left: 7,
                right: 6,
                bottom: 5,
                child: Text(
                  series.title,
                  style: const TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Positioned(
                left: 5,
                top: 5,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    series.mode == SeriesMode.collection ? '合集' : '系列',
                    style: const TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 8.5,
                      height: 1,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全部合集弹层：标题搜索过滤
class _AllSeriesDialog extends StatefulWidget {
  final List<SeriesModel> seriesList;
  final void Function(SeriesModel) onPick;

  const _AllSeriesDialog({required this.seriesList, required this.onPick});

  @override
  State<_AllSeriesDialog> createState() => _AllSeriesDialogState();
}

class _AllSeriesDialogState extends State<_AllSeriesDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.seriesList
        : widget.seriesList
            .where((s) => s.title.toLowerCase().contains(q))
            .toList();
    return AlertDialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: AppColors.border),
      ),
      title: Text('全部合集 · ${widget.seriesList.length} 个',
          style: AppStyles.titleSmall.copyWith(fontSize: 15)),
      content: SizedBox(
        width: 380,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              autofocus: false,
              style: AppStyles.bodyMedium,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: '搜索合集标题…',
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text('没有匹配的合集', style: AppStyles.bodySmall))
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, i) {
                        final s = filtered[i];
                        return InteractiveWrapper(
                          onTap: () => widget.onPick(s),
                          hoverScale: 1.01,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppColors.isDark
                                  ? Colors.white.withOpacity(0.04)
                                  : Colors.black.withOpacity(0.03),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 36,
                                  height: 48,
                                  child: ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.xs),
                                    child: HallCoverImage(
                                        networkUrl: s.coverUrl),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    s.title,
                                    style: AppStyles.bodyMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  s.mode == SeriesMode.collection
                                      ? '合集'
                                      : '系列',
                                  style: AppStyles.microCaption,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('关闭', style: AppStyles.labelMedium),
        ),
      ],
    );
  }
}
