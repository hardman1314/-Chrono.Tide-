import 'package:flutter/material.dart';

import '../models/game_model.dart';
import '../models/kungal_calendar_game.dart';
import '../models/series_model.dart';
import '../pages/discover_page.dart' show DiscoverPage, GameCardData;
import '../services/discover_metadata_service.dart';
import '../services/daily_recommendation_service.dart';
import '../services/explore_calendar_service.dart';
import '../services/kungal_calendar_service.dart';
import '../services/website_bookmark_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/explore_hall/calendar_section.dart';
import '../widgets/explore_hall/docs_section.dart';
import '../widgets/explore_hall/hall_visuals.dart';
import '../widgets/explore_hall/related_topics_section.dart';
import '../widgets/explore_hall/series_section.dart';
import '../widgets/explore_hall/website_section.dart';
import '../widgets/interactive_wrapper.dart';

/// 探索大厅 —— 【探索】侧边栏项的默认首界面
///
/// 单页固定式两栏布局（设计稿 素材/探索大厅设计图.png）：
/// 左栏 ①发售月历 + ②相关话题（今日推荐）；
/// 右栏 ③大标题 ④常用站点 ⑤系列合集 ⑥文档与趣味 ⑦开始探索。
///
/// 原【探索库】页（DiscoverPage）零改动：经 ⑦ 整页进入（免责弹窗由其
/// initState 自行触发），左下角「返回大厅」chip 回到本页；
/// 两视图 Offstage 保活，进出不丢状态、预热不中断。
class ExploreHallPage extends StatefulWidget {
  /// 点探索库作品 → main_container 详情页（原 DiscoverPage 同款回调）
  final ValueChanged<GameCardData>? onGameTap;

  /// 本地库启动（透传 main_container._onLaunchGame，随机一作用）
  final void Function(String gameTitle)? onLaunchGame;

  /// 测试/预览注入：日历服务实例（默认全局单例）
  final ExploreCalendarService? calendarService;

  /// 测试/预览注入：KUNGAL 月历服务实例（默认全局单例）
  final KungalCalendarService? kungalService;

  /// 测试/预览注入：每日推荐服务（默认全局单例；板块②相关话题）
  final DailyRecommendationService? dailyService;

  /// 测试注入：系列整表加载器
  final Future<List<SeriesModel>> Function()? seriesLoader;

  /// 测试注入：通知文本加载器
  final Future<String> Function()? noticeLoader;

  /// 是否触发后台预热（测试关闭避免网络请求）
  final bool autoWarmup;

  const ExploreHallPage({
    super.key,
    this.onGameTap,
    this.onLaunchGame,
    this.calendarService,
    this.kungalService,
    this.dailyService,
    this.seriesLoader,
    this.noticeLoader,
    this.autoWarmup = true,
  });

  @override
  State<ExploreHallPage> createState() => _ExploreHallPageState();
}

class _ExploreHallPageState extends State<ExploreHallPage> {
  ExploreCalendarService get _calendar =>
      widget.calendarService ?? ExploreCalendarService.instance;

  KungalCalendarService get _kungal =>
      widget.kungalService ?? KungalCalendarService.instance;

  bool _showLibrary = false;
  bool _libraryCreated = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoWarmup) {
      // ⚠️ 只调 startWarmup：其内部按序 init → loadState → ensureGamesLoaded。
      // 此前这里并发先调了 ensureGamesLoaded，其 _loadingGames 在途守卫
      // 会把 startWarmup 内部的同调用短路 → _games.isEmpty → 预热静默中止，
      // 月历/今日推荐在生产环境永远拿不到数据（P0 竞态，2026-09-11 修复）。
      _calendar.startWarmup();
      // KUNGAL 当月月历预热（24h 缓存，失败静默回落）
      _kungal.ensureMonth(KungalCalendarService.monthKey(DateTime.now()));
    }
  }

  void _enterLibrary() {
    setState(() {
      _showLibrary = true;
      _libraryCreated = true; // 首次进入才构建 DiscoverPage（免责弹窗届时触发）
    });
  }

  void _backToHall() => setState(() => _showLibrary = false);

  void _forwardGameTap(GameModel game) =>
      widget.onGameTap?.call(GameCardData.fromModel(game));

  /// 月历条目点击：先按规范化标题匹配本地探索库——
  /// 命中 → 进我们的详情页（保留下载入口）；未命中 → 开 KUNGAL 详情页。
  void _onCalendarItemTap(KungalCalendarGame item) {
    final match = _matchLibraryGame(item);
    if (match != null) {
      _forwardGameTap(match);
      return;
    }
    final url = item.detailUrl;
    if (url.isNotEmpty) {
      WebsiteBookmarkService.openExternal(url);
      return;
    }
    // 既不中本地库、KUNGAL 站内也没有详情页 —— 过去这里直接 return，
    // 表现为「点了完全没反应」，用户会误判成被遮罩层挡住。现在明确告知。
    AppSnackBar.info(
      context,
      '「${item.displayName}」暂无 KUNGAL 详情页',
      duration: const Duration(seconds: 4),
    );
  }

  /// 本地探索库「规范化标题」索引，供月历行判定是否命中本地库。
  ///
  /// 月历面板每次重建都要对每行问一次「能不能打开」；若每次都线性扫库
  /// 并对每个标题跑 [KungalCalendarGame.normalizeTitle]（Unicode 正则），
  /// 1000 部库 × 8 行 ≈ 8000 次正则会明显卡帧，故按库快照缓存。
  /// 探索库只在首次加载时整体替换（explore_calendar_service.dart:116-131），
  /// 用「加载态 + 条数」两个信号足以可靠识别快照变化。
  Set<String>? _localTitleKeys;
  bool _localTitleKeysLoaded = false;
  int _localTitleKeysCount = -1;

  Set<String> _localTitleKeySet() {
    final games = _calendar.games;
    if (_localTitleKeys == null ||
        _localTitleKeysLoaded != _calendar.gamesLoaded ||
        _localTitleKeysCount != games.length) {
      final keys = <String>{};
      for (final g in games) {
        keys.add(KungalCalendarGame.normalizeTitle(g.title));
      }
      _localTitleKeys = keys;
      _localTitleKeysLoaded = _calendar.gamesLoaded;
      _localTitleKeysCount = games.length;
    }
    return _localTitleKeys!;
  }

  /// 月历条目是否有可打开的目标：本地探索库命中（→ 我们自己的详情页）
  /// 或 KUNGAL 站内详情页存在。两者皆无时点击无处可去，行样式随之下调，
  /// 让「可点 / 不可点」在点击之前就看得出来（判定口径与
  /// [_onCalendarItemTap] / [_matchLibraryGame] 完全一致）。
  bool _isCalendarItemOpenable(KungalCalendarGame item) {
    if (item.detailUrl.isNotEmpty) return true;
    final keys = _localTitleKeySet();
    return keys.contains(item.normalizedKey) ||
        keys.contains(item.normalizedOriginalKey);
  }

  GameModel? _matchLibraryGame(KungalCalendarGame item) {
    GameModel? find(String key) {
      if (key.isEmpty) return null;
      for (final g in _calendar.games) {
        if (KungalCalendarGame.normalizeTitle(g.title) == key) return g;
      }
      return null;
    }

    return find(item.normalizedKey) ?? find(item.normalizedOriginalKey);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 大厅常驻：进库后 Offstage 保活（预热/选中状态不丢）
        Offstage(offstage: _showLibrary, child: _buildHall()),
        if (_libraryCreated)
          Offstage(offstage: !_showLibrary, child: _buildLibraryView()),
      ],
    );
  }

  // ---------- 大厅视图 ----------

  Widget _buildHall() {
    final now = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    return HallAmbientBackdrop(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ③ 界面大标题（F1 标题 + 渐变笔触下划线 + 英文小字幕 + 日期胶囊）
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('探索大厅',
                        style: AppStyles.displaySmall.copyWith(fontSize: 26)),
                    const SizedBox(height: 3),
                    const HallAccentUnderline(),
                  ],
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'EXPLORE HALL',
                    style: TextStyle(
                      fontFamily: AppStyles.enDecorativeFont,
                      fontSize: 11,
                      letterSpacing: 4,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.isDark
                        ? Colors.white.withOpacity(0.045)
                        : Colors.white.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: AppColors.isDark
                          ? Colors.white.withOpacity(0.09)
                          : AppColors.titleBrown.withOpacity(0.18),
                    ),
                  ),
                  child: Text(
                    '${now.year}年${now.month}月${now.day}日 · ${weekdays[now.weekday - 1]}',
                    style: AppStyles.labelMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 两栏主体
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 左栏：①月历 + ②相关话题
                  Expanded(
                    flex: 11,
                    child: Column(
                      children: [
                        Expanded(
                          flex: 13,
                          child: CalendarSection(
                            kungal: _kungal,
                            onItemTap: _onCalendarItemTap,
                            canOpen: _isCalendarItemOpenable,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          flex: 10,
                          child: RelatedTopicsSection(
                            service: _calendar,
                            onGameTap: _forwardGameTap,
                            daily: widget.dailyService,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 右栏：④常用站点 + ⑤系列合集 + ⑥文档与趣味 + ⑦开始探索
                  Expanded(
                    flex: 9,
                    child: Column(
                      children: [
                        const Expanded(flex: 15, child: WebsiteSection()),
                        const SizedBox(height: 10),
                        Expanded(
                          flex: 14,
                          child: SeriesSection(
                            loader: widget.seriesLoader,
                            // 面板内点作品 → main_container 详情页通道
                            // （复用 onGameTap 同一条路，零稳定区改动）
                            onOpenGame: (gameId, title, coverUrl) => widget
                                .onGameTap
                                ?.call(GameCardData(
                                    id: gameId,
                                    title: title,
                                    coverPath: coverUrl)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          flex: 24,
                          child: DocsSection(
                            discoverPool: () => _calendar.games,
                            discoverMetadataOf: (id) =>
                                DiscoverMetadataService.instance.getMetadata(id),
                            onLaunchGame: widget.onLaunchGame,
                            onEnterLibrary: _enterLibrary,
                            noticeLoader: widget.noticeLoader,
                            // 【发布】判重命中 → 进该作品探索详情页（复用既有
                            // onGameTap → main_container 详情页通道，零稳定区改动）
                            onOpenDiscoverGame: _forwardGameTap,
                          ),
                        ),
                        const SizedBox(height: 10),
                        // ⑦ 底部入口按钮
                        SizedBox(height: 50, child: _buildStartButton()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStartButton() {
    return SizedBox(
      width: double.infinity,
      child: HoverButton(
        onTap: _enterLibrary,
        borderRadius: AppRadius.lg,
        padding: EdgeInsets.zero,
        normalColor: Colors.transparent,
        hoverColor: Colors.transparent,
        pressColor: Colors.transparent,
        borderColor: Colors.transparent,
        borderWidth: 0,
        hoverBorderColor: Colors.white.withOpacity(0.45),
        hoverBorderWidth: 1.4,
        normalShadow: const [],
        hoverShadow: [
          // 辉光贴按钮圆角矩形（同形渐变投影，非圆形底块）
          BoxShadow(
            color: AppColors.brandBlue.withOpacity(0.45),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
        child: Container(
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: HallGradients.accentLinear,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.22),
                  ),
                  child: const Icon(Icons.explore_rounded,
                      size: 15, color: Colors.white),
                ),
                const SizedBox(width: 9),
                const Text(
                  '开始探索',
                  style: TextStyle(
                    fontFamily: AppStyles.zhDecorativeFont,
                    fontSize: 17,
                    letterSpacing: 3,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'ENTER ›',
                  style: TextStyle(
                    fontFamily: AppStyles.enDecorativeFont,
                    fontSize: 9,
                    letterSpacing: 1.5,
                    color: Colors.white.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 探索库视图（原页面零改动 + 左下返回 chip） ----------

  Widget _buildLibraryView() {
    return Stack(
      children: [
        Positioned.fill(
          child: DiscoverPage(onGameTap: widget.onGameTap),
        ),
        // discover_page 顶部是全宽悬浮顶栏（top:0），返回 chip 放左下角避让
        Positioned(
          left: 16,
          bottom: 20,
          child: InteractiveWrapper(
            onTap: _backToHall,
            hoverScale: 1.05,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.isDark
                    ? Colors.black.withOpacity(0.55)
                    : Colors.white.withOpacity(0.75),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_back_rounded,
                      size: 16, color: AppColors.primaryText),
                  const SizedBox(width: 6),
                  Text('返回大厅', style: AppStyles.labelMedium),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
