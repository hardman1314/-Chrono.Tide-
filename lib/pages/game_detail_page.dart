import 'dart:async';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../models/game_model.dart';
import '../models/game_resource_model.dart';
import '../models/series_model.dart';
import '../repositories/game_repository.dart';
import '../repositories/series_repository.dart';
import '../services/game_resource_service.dart';
import '../services/tag_library_override_store.dart';
import '../services/website_bookmark_service.dart';
import '../services/global_install_center.dart';
import '../services/cloud_install_flow.dart';
import '../services/local_game_registry.dart';
import '../widgets/nsfw/nsfw_image.dart';
import '../services/game_data_format.dart';
import '../services/metadata_fetcher.dart';
import '../services/discover_metadata_service.dart';
import '../services/file_size_service.dart';
import '../services/install_stats_service.dart';
import '../widgets/download_button.dart';
import '../widgets/screenshot_carousel.dart';
import '../widgets/series_strip.dart';
import '../widgets/series_panel.dart';
import '../core/path_helper.dart';
import '../core/pb_config.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/interactive_wrapper.dart';
import '../widgets/game_detail/ct_download_dialog.dart';
import '../widgets/game_detail/dark_surface.dart';
import '../widgets/game_detail/game_detail_header.dart';
import '../widgets/game_detail/share_detail_dialog.dart';
import '../widgets/game_detail/share_list_dialog.dart';
import '../widgets/game_detail/upload_resource_dialog.dart';

/// 面包屑条目：详情页导航栈中的一步
typedef SeriesNavCrumb = ({String id, String title, String coverUrl});

class GameDetailPage extends StatefulWidget {
  final String gameId;
  final VoidCallback onBack;

  /// 分级首级「列表」点击：直接回探索页游戏列表（清空导航栈），
  /// 区别于 onBack（栈深>1 时逐级回退）
  final VoidCallback? onBackToList;
  final VoidCallback? onGoToLibrary;

  /// 系列内跳转：点击系列中的其他作品时压入新详情页；
  /// 目标已在导航栈中时由 main_container 做历史折叠（截断回跳）
  final SeriesGameNavigate? onNavigateToGame;

  /// 返回目标提示：栈深 > 1 时为上一级作品标题；
  /// null = 已在栈底（返回 = 回到探索页）
  final String? backTargetLabel;

  /// 导航路径面包屑（栈内容快照）：用于分级可视化与直接回跳；
  /// 长度 ≤ 1（未发生系列内跳转）时不渲染，UI 保持原样
  final List<SeriesNavCrumb> navBreadcrumb;

  const GameDetailPage({
    super.key,
    required this.gameId,
    required this.onBack,
    this.onBackToList,
    this.onGoToLibrary,
    this.onNavigateToGame,
    this.backTargetLabel,
    this.navBreadcrumb = const [],
  });

  /// 一次性信号：值等于本页 gameId 时，**打开后自动弹出【上传】窗口**。
  ///
  /// 用途：探索大厅【发布】判重**命中已有作品**时，用户点「前往上传资源」
  /// 需要「进详情页 + 直接弹上传」。用静态一次性信号可以**不改
  /// `main_container`（稳定区）的详情页构建**；initState 消费后立即清空，
  /// 不会在后续手动打开时误触发。
  static String? pendingAutoUploadGameId;

  @override
  State<GameDetailPage> createState() => _GameDetailPageState();
}

class _GameDetailPageState extends State<GameDetailPage> {
  GameModel? _gameData;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isLocallyInstalled = false;
  bool _linkError = false;
  bool _isSubmitting = false;
  bool _backHovered = false;

  FileSizeInfo? _fileSizeInfo;
  bool _isFetchingSize = false;
  List<String> _screenshotUrls = [];
  List<String> _localScreenshots = [];
  bool _isLoadingScreenshots = true; // 截图URL获取中（仅影响占位显示）
  bool _screenshotFetchFailed = false; // 截图获取失败标记

  /// 阶段3.4：探索页元数据（评分/发售日/热度/来源平台）
  /// 由 DiscoverMetadataService 懒加载，详情页打开时同步触发抓取
  DiscoverGameMetadata? _metadata;

  /// 系列数据（所属系列的完整树）
  /// null = 无系列 / 加载失败 / 作品不足 2 部，系列区整体隐藏
  SeriesData? _seriesData;

  // ===== v4.0 探索详情页重构：资源来源 =====

  /// 官方来源（`kind=official`），驱动「Chrono Tide 下载」浮层与「获取」按钮状态
  List<GameResourceModel> _officialResources = const [];

  /// 已发布的用户分享（`kind=community & status=published`）
  List<GameResourceModel> _communityResources = const [];

  /// 资源加载中 / 失败提示（失败不阻塞页面，仅浮层内提示）
  bool _isLoadingResources = false;
  String? _resourceError;

  /// 「喜欢」点亮态（games 级点赞：initState 回显 + 乐观更新，主线补完 §14.2-P2）
  bool _likedByMe = false;

  /// 操作按钮行锚点：浮层定位到该行旁边（设计为"对话栏"而非居中窗）
  final GlobalKey _actionRowKey = GlobalKey();

  // 保存 listener 真实引用,避免 dispose 时按引用相等比较失败导致 listener 泄漏
  // (旧代码 dispose 时传空函数 removeListener,根本匹配不到,每次进入详情页都累积一个
  // 泄漏的 listener 持有 State 引用,高频 progress 事件 × N 个泄漏 listener × 全页 setState
  // 会让 UI 调度队列被淹没,直接表现为"白屏卡死")
  void Function(InstallPhase)? _phaseListener;
  void Function(InstallProgress)? _progressListener;

  @override
  void initState() {
    super.initState();
    _loadGameData();
    _setupInstallListener();
    _loadResources();
    // 点赞回显（非阻塞：未登录/失败静默保持未点亮）
    _loadLikeState();
    // 监听元数据服务变化（抓取完成后刷新详情页元数据行）
    DiscoverMetadataService.instance.addListener(_onMetadataChanged);

    // 一次性信号：探索大厅【发布】判重命中 → 打开本页后自动弹【上传】窗口。
    // 用 postFrameCallback：需等首帧完成、Navigator/context 就绪后再 showDialog。
    final pending = GameDetailPage.pendingAutoUploadGameId;
    if (pending != null) {
      GameDetailPage.pendingAutoUploadGameId = null;
      if (pending == widget.gameId) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleUploadTap();
        });
      }
    }
  }

  void _setupInstallListener() {
    _phaseListener = (phase) {
      if (!mounted) return;
      switch (phase) {
        case InstallPhase.completed:
          // 队列模式：仅当完成的是本页对应的游戏时才刷新本地安装状态与截图
          if (GlobalInstallCenter.instance.currentTask?.gameId !=
              widget.gameId) {
            break;
          }
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            _checkLocalInstallation().then((_) {
              // 安装完成后重新加载截图（从本地读取）
              if (mounted) {
                setState(() {
                  _isLoadingScreenshots = true;
                  _screenshotFetchFailed = false;
                });
                _loadScreenshotsParallel();
              }
            });
          });
          break;
        case InstallPhase.failed:
        case InstallPhase.downloading:
        case InstallPhase.extracting:
          // 关键:downloading/extracting 阶段也要 rebuild,让 _buildCurrentInstallingUI
          // 正确切到"正在获取中/安装中 + 取消"的状态,UI 与 GlobalInstallCenter 同步
          setState(() {});
          break;
        case InstallPhase.cancelled:
          setState(() {});
          break;
        default:
          break;
      }
    };
    _progressListener = (progress) {
      if (!mounted) return;
      // 关键:不再每次 progress 都 setState —— 进度显示交给 FloatingTaskButton 自身的节流
      // 详情页只需要在 phase 变化时 rebuild
    };
    GlobalInstallCenter.instance.addListener(
      phase: _phaseListener!,
      progress: _progressListener!,
    );
    // 队列模式：排队位置/队列内容变化时刷新"排队中"状态展示
    GlobalInstallCenter.instance.addQueueListener(_onQueueChanged);
  }

  /// 队列变更回调：本页游戏入队/出队/位置变化时重建 UI
  void _onQueueChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    GlobalInstallCenter.instance.removeListener(
      phase: _phaseListener!,
      progress: _progressListener!,
    );
    GlobalInstallCenter.instance.removeQueueListener(_onQueueChanged);
    _phaseListener = null;
    _progressListener = null;
    DiscoverMetadataService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  /// 阶段3.4：元数据抓取完成回调
  /// 仅当本页对应游戏的元数据更新时刷新，避免无关通知触发重建
  void _onMetadataChanged() {
    if (!mounted || _gameData == null) return;
    final newMeta = DiscoverMetadataService.instance.getMetadata(_gameData!.id);
    if (newMeta != _metadata) {
      setState(() => _metadata = newMeta);
    }
  }

  Future<void> _loadGameData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final game = await GameRepository.getGameById(widget.gameId);
      if (!mounted || game == null) return;

      setState(() {
        _gameData = game;
        _isLoading = false;
        _errorMessage = null;
      });

      _prefetchFileSize();
      // 并行执行：本地安装检查 + 截图API请求同时发起
      // 不再串行等待，大幅缩短截图加载时间
      _loadScreenshotsParallel();

      // 系列数据并行加载（非阻塞；无系列/失败时系列区整体隐藏）
      _loadSeriesData(game.id);

      // 阶段3.4：触发元数据懒加载（同步读取缓存，后台抓取）
      // 与截图加载并行，不阻塞 UI；抓取完成通过 _onMetadataChanged 刷新
      // v2.1.17：先登记云端沉淀的评分/发售日，云端有则完全免抓取
      DiscoverMetadataService.instance.registerCloudMetadata(game);
      _metadata = DiscoverMetadataService.instance.getMetadata(game.id);
      // 2026-10-04 缺口回填：云端条目缺预计时长时补抓一次（抓到自动回传
      // 云端）；无缓存时内部等价于 ensureMetadata，已有时长则零开销返回
      DiscoverMetadataService.instance
          .ensureEstimatedMinutes(game.id, game.title);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// 系列数据加载：静默失败，失败/无系列时系列区不渲染
  Future<void> _loadSeriesData(String gameId) async {
    final data = await SeriesRepository.getSeriesForGame(gameId);
    if (!mounted) return;
    if (data != _seriesData) {
      setState(() => _seriesData = data);
    }
  }

  /// 系列内跳转到其他作品（压入新详情页，由 main_container 维护返回栈）
  void _navigateToSeriesGame(String gameId, String title, String coverUrl) {
    widget.onNavigateToGame?.call(gameId, title, coverUrl);
  }

  /// 打开完整系列弹层（Overlay 顶层挂载）
  void _openSeriesPanel() {
    if (_seriesData == null) return;
    SeriesPanel.show(
      context,
      seriesData: _seriesData!,
      currentGameId: widget.gameId,
      onNavigateToGame: _navigateToSeriesGame,
    );
  }

  Future<void> _checkLocalInstallation() async {
    if (_gameData == null || _gameData!.title == null) return;

    await LocalGameRegistry.instance.refreshStaleEntries();

    final title = _gameData!.title!;
    // ★ 2026-09-26 P1-4：优先按云端主键判定（改名/译名差异不再误判）
    if (LocalGameRegistry.instance
        .isCloudGameInstalled(widget.gameId, title)) {
      if (mounted) setState(() => _isLocallyInstalled = true);
      return;
    }

    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    try {
      final gamesDir = io.Directory(PathHelper.gamesDir);
      if (!await gamesDir.exists()) return;

      await for (final entity in gamesDir.list()) {
        if (entity is io.Directory) {
          final dirName = entity.path.split('/').last.split('\\').last;
          if (dirName == safeName) {
            final hasCtgame = await GameDataFormat.hasCtgame(entity.path);
            final hasGameJson = await io.File(
                    '${entity.path}/${GameDataFormat.gameJsonFileName}')
                .exists();
            if (hasCtgame || hasGameJson) {
              if (LocalGameRegistry.instance
                  .isCloudGameInstalled(widget.gameId, title)) {
                if (mounted) setState(() => _isLocallyInstalled = true);
                return;
              }
              LocalGameRegistry.instance.registerExtractionComplete(
                gameTitle: title,
                directoryPath: entity.path,
              );
              if (mounted) setState(() => _isLocallyInstalled = true);
              return;
            }
          }
        }
      }
    } catch (e) {}
  }

  /// 重新加载截图（截图区域中央刷新图标点击时调用）
  ///
  /// 重走三级优先级加载流程（PB数据 → 本地截图 → 多平台并发抓取），
  /// 期间展示加载状态；成功后正常显示截图，仍失败则刷新图标重新出现
  Future<void> _reloadScreenshots() async {
    if (_gameData == null || _gameData!.title == null) return;
    if (!mounted) return;
    setState(() {
      _isLoadingScreenshots = true;
      _screenshotFetchFailed = false;
    });
    await _loadScreenshotsParallel();
  }

  /// 并行加载截图（三级优先级）
  /// Priority 1: PocketBase 截图数据 → 直接使用，最快
  /// Priority 2: 本地已安装游戏的截图文件
  /// Priority 3: 多平台并发抓取（VNDB/Hikarinagi/KunGal）→ 抓取成功后回传到PB供其他用户使用
  Future<void> _loadScreenshotsParallel() async {
    if (_gameData == null || _gameData!.title == null) return;

    final title = _gameData!.title!;
    final gameId = _gameData!.id;

    // ====== Priority 1: PB截图数据 ======
    if (_gameData!.screenshotUrls.isNotEmpty && mounted) {
      debugPrint(
          '[GameDetailPage] ✅ 使用PB截图数据: ${_gameData!.screenshotUrls.length}张');
      setState(() {
        _screenshotUrls = _gameData!.screenshotUrls;
        _localScreenshots = [];
        _isLoadingScreenshots = false;
        _screenshotFetchFailed = false;
      });
      return; // 有PB数据，直接返回
    }

    debugPrint('[GameDetailPage] PB无截图数据，继续检查本地/抓取...');

    // 同时发起：本地安装检查 + 截图多平台并发抓取
    // 截图来源：VNDB → Hikarinagi → KunGal 三源并发，按优先级合并去重
    // 主标题无截图时自动回退日文原标题/英文标题抓取
    final localCheckFuture = _checkLocalInstallation();
    final apiFetchFuture = MetadataFetcher.fetchScreenshots(
      title,
      altNames: [
        if (_gameData!.originalTitle.isNotEmpty) _gameData!.originalTitle,
        if (_gameData!.englishTitle.isNotEmpty) _gameData!.englishTitle,
      ],
    );

    // 先等本地安装检查完成
    await localCheckFuture;

    // ====== Priority 2: 本地已安装且有截图 ======
    if (_isLocallyInstalled) {
      final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final metaDataDir = '${PathHelper.gamesDir}/$safeName';
      final localFiles = GameDataFormat.findScreenshotFiles(metaDataDir);
      if (localFiles.isNotEmpty && mounted) {
        setState(() {
          _localScreenshots = localFiles;
          _screenshotUrls = [];
          _isLoadingScreenshots = false;
          _screenshotFetchFailed = false;
        });
        return;
      }
    }

    // ====== Priority 3: 多平台截图抓取（VNDB/Hikarinagi/KunGal 并发）======
    try {
      final urls = await apiFetchFuture;
      if (!mounted) return;

      if (urls.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoadingScreenshots = false;
            _screenshotFetchFailed = true;
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _screenshotUrls = urls;
          _localScreenshots = [];
          _isLoadingScreenshots = false;
          _screenshotFetchFailed = false;
        });
      }
      // 后台回传截图数据到PB，供其他用户使用
      _uploadScreenshotsToPB(gameId, urls);
    } catch (e) {
      debugPrint('[GameDetailPage] 截图获取失败: $e');
      if (mounted) {
        setState(() {
          _isLoadingScreenshots = false;
          _screenshotFetchFailed = true;
        });
      }
    }
  }

  /// 将抓取到的截图URL下载后上传到PocketBase的screenshots字段
  /// 后台执行，不影响UI展示
  void _uploadScreenshotsToPB(String gameId, List<String> urls) async {
    // ★ 本地账号体系：无云端会话（本地态）不回传截图 —— 服务端 update
    // 规则要求认证，避免带空 Bearer 的必败请求（local_account_mode.md §1.4）。
    if (!PBConfig.isLoggedIn) {
      debugPrint('[GameDetailPage] ⏭️ 未登录，跳过截图回传PB');
      return;
    }
    try {
      debugPrint('[GameDetailPage] 📤 开始上传${urls.length}张截图到PB...');

      final files = <Map<String, dynamic>>[];

      // 从缓存或网络下载每张图片
      for (int i = 0; i < urls.length && i < 6; i++) {
        try {
          // 优先从 CachedNetworkImage 缓存获取
          final cachedFile =
              await PortableImageCacheManager().getFileFromCache(urls[i]);
          if (cachedFile != null && cachedFile.file.existsSync()) {
            files.add({
              'bytes': cachedFile.file.readAsBytesSync(),
              'filename': cachedFile.file.path.split('/').last,
            });
            continue;
          }
          // 缓存未命中，从网络下载
          final client = io.HttpClient();
          client.connectionTimeout = const Duration(seconds: 10);
          final request = await client.getUrl(Uri.parse(urls[i]));
          final response = await request.close();
          if (response.statusCode == 200) {
            final bytes = await response.fold<List<int>>(
              <int>[],
              (prev, chunk) => prev..addAll(chunk),
            );
            final ext = urls[i].contains('.png')
                ? 'png'
                : urls[i].contains('.webp')
                    ? 'webp'
                    : 'jpg';
            files.add({
              'bytes': bytes,
              'filename': 'screenshot_${i + 1}.$ext',
            });
          }
          client.close();
        } catch (e) {
          debugPrint('[GameDetailPage] ⚠️ 截图[$i]下载失败: $e');
        }
      }

      if (files.isEmpty) {
        debugPrint('[GameDetailPage] ⚠️ 没有可上传的截图');
        return;
      }

      // 使用 MultipartRequest 上传到PB（与auth_service一致的模式）
      final uri = Uri.parse(
          '${PBConfig.pb.baseURL}/api/collections/games/records/$gameId');
      final request = http.MultipartRequest('PATCH', uri);
      request.headers['Authorization'] =
          'Bearer ${PBConfig.pb.authStore.token}';

      for (final file in files) {
        final multipartFile = http.MultipartFile.fromBytes(
          'screenshots',
          file['bytes'],
          filename: file['filename'],
        );
        request.files.add(multipartFile);
      }

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        debugPrint(
            '[GameDetailPage] ✅ 已上传${files.length}张截图到PB (gameId=$gameId)');
      } else {
        debugPrint('[GameDetailPage] ⚠️ 截图上传PB失败: HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[GameDetailPage] ⚠️ 截图上传PB失败: $e');
    }
  }

  Future<void> _prefetchFileSize() async {
    if (_gameData == null || _gameData!.downloadUrl.isEmpty) return;

    setState(() => _isFetchingSize = true);

    try {
      final info = await FileSizePrefetchService.instance.prefetchSize(
        widget.gameId,
        _gameData!.downloadUrl,
      );

      if (mounted && info != null) {
        setState(() {
          _fileSizeInfo = info;
          _isFetchingSize = false;
        });
      } else if (mounted) {
        setState(() => _isFetchingSize = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isFetchingSize = false);
    }
  }

  Widget _buildFileSizeDisplay() {
    if (_isFetchingSize) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.secondaryText.withOpacity(0.4),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '获取中...',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.secondaryText.withOpacity(0.8),
            ),
          ),
        ],
      );
    }

    if (_fileSizeInfo != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sd_storage_outlined,
              size: 14, color: AppColors.secondaryText.withOpacity(0.5)),
          const SizedBox(width: 4),
          Text(
            _fileSizeInfo!.formatted,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText.withOpacity(0.85),
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  /// 是否有可展示的版本信息（版本名或版本详情任一非空）
  bool get _hasVersionInfo {
    final version = _gameData?.version ?? '';
    final versionNote = _gameData?.versionNote ?? '';
    return version.isNotEmpty || versionNote.isNotEmpty;
  }

  /// 版本信息（安装按钮上方，轻量设计）
  /// 版本名：小图标 + 加粗文字，相对显眼
  /// 版本详情：小字体次要色，最多两行
  Widget _buildVersionInfo() {
    final version = _gameData?.version ?? '';
    final versionNote = _gameData?.versionNote ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (version.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.new_releases_outlined,
                  size: 15, color: AppColors.secondaryText.withOpacity(0.6)),
              const SizedBox(width: 5),
              Flexible(
                child: Text(version,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText.withOpacity(0.85))),
              ),
            ],
          ),
        if (version.isNotEmpty && versionNote.isNotEmpty)
          const SizedBox(height: 4),
        if (versionNote.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(versionNote,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    height: 16 / 12,
                    color: AppColors.secondaryText.withOpacity(0.7))),
          ),
      ],
    );
  }

  Future<void> _handleInstallTap() async {
    final gamePath = _gameData?.downloadUrl ?? '';
    if (gamePath.isEmpty) {
      setState(() => _linkError = true);
      return;
    }

    // 下载登记：仅当这条资源有 `game_resources` 社区记录时才打点
    // （官方【获取】走 `games.downloadUrl` 原生通道，没有记录 id 可挂）。
    // 不 await、失败静默 —— 统计绝不阻塞或影响下载主流程。
    final statId = _officialResource?.record?.id ?? '';
    if (statId.isNotEmpty) {
      GameResourceService.registerDownload(statId);
    }

    setState(() {
      _linkError = false;
      _isSubmitting = true;
    });

    try {
      debugPrint('[DETAIL] 经共享安装流提交...');
      // ★ 2026-09-26 安装审计 P1-3/P3-1：确认弹窗 / 安装位置 / 直链解析 /
      // InstallTask 组装收敛到 CloudInstallFlow，与 BPM 探索页共用同一份
      // 前置流程（原两处复制实现已出现字段漂移）。
      final result = await CloudInstallFlow.submit(
        context: context,
        gameId: widget.gameId,
        title: _gameData?.title ?? widget.gameId,
        description: _gameData?.description,
        coverUrl: _gameData?.coverUrl,
        // 横幅封面（云端 games.bannerUrl）：入库写 game.json banner_file
        bannerUrl: _gameData?.bannerUrl,
        tags: _gameData?.tags,
        downloadPath: gamePath,
        developer: _gameData?.developer,
        screenshotUrls: _screenshotUrls.isNotEmpty ? _screenshotUrls : null,
        // 副标题：PB 日文原版标题（原版标题字段），入库时写入 game.json
        subtitle: _gameData?.originalTitle,
      );

      if (!mounted) return;
      switch (result) {
        case CloudInstallResult.submitted:
          final queued = GlobalInstallCenter.instance.queueLength > 0;
          AppSnackBar.info(
            context,
            queued
                  ? '《${_gameData?.title}》已加入安装队列（前方还有任务）'
                  : '《${_gameData?.title}》已提交安装',
            duration: const Duration(seconds: 2),
          );
        case CloudInstallResult.duplicate:
          AppSnackBar.warning(
            context,
            '《${_gameData?.title}》已在安装队列中，无需重复提交',
            duration: const Duration(seconds: 3),
          );
        case CloudInstallResult.cancelled:
          break;
        case CloudInstallResult.linkFailed:
          debugPrint('[DETAIL] ❌ 链接获取失败');
          setState(() => _linkError = true);
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('[DETAIL] ❌ 异常: $e');
      setState(() => _linkError = true);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        color: AppColors.background,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 16),
              Text(
                '正在加载游戏详情...',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null || _gameData == null) {
      return _buildErrorView();
    }

    // v4.0 重构：改为「顶部游戏数据区（头部）+ 下方两栏（简介 / 截图+系列）」。
    // 旧版把「封面 + 标题 + 元数据 + 标签」塞在左列、安装按钮贴在右列底部；
    // 新版头部横跨整宽，安装入口迁入「Chrono Tide 下载」浮层。
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(32, 18, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDetailHeader(),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左列 flex 5 / 右列 flex 6 —— 与设计实测比例
                // （简介面板 462 : 截图 556 = 45.4% ≈ 5:6）一致
                Expanded(flex: 5, child: _buildLeftSection()),
                const SizedBox(width: 32),
                Expanded(flex: 6, child: _buildRightSection()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部游戏数据区：返回键 + 封面 + 标题/别名/元数据/标签 + 操作按钮行
  Widget _buildDetailHeader() {
    final game = _gameData;
    return GameDetailHeader(
      leading: _buildBackButton(),
      cover: _buildGameCover(),
      actionRowKey: _actionRowKey,
      title: game?.title ?? '未知游戏',
      alias: _headerAlias(),
      metaItems: _buildHeaderMetaItems(),
      tags: _buildHeaderTags(),
      getLabel: _getButtonLabel,
      getEnabled: _getButtonEnabled,
      getBusy: _getButtonBusy,
      onGet: _handleGetTap,
      onShare: _handleShareTap,
      onUpload: _handleUploadTap,
      onLike: _handleLikeTap,
      onFeedback: _handleFeedbackTap,
      liked: _likedByMe,
      likeCount: _gameData?.likeCount ?? 0,
    );
  }

  /// 头部别名：日语原标题优先，回退英语标题（与主标题相同则视为无别名）
  String _headerAlias() {
    final game = _gameData;
    if (game == null) return '';
    final title = game.title;
    final original = game.originalTitle;
    final english = game.englishTitle;
    if (original.isNotEmpty && original != title) return original;
    if (english.isNotEmpty && english != title) return english;
    return '';
  }

  /// 头部元数据条目：会社 + 既有元数据行（复用 `_buildMetadataChips`，样式零改动）
  List<Widget> _buildHeaderMetaItems() {
    final developer = (_gameData?.developer ?? '').isNotEmpty
        ? _gameData!.developer
        : (_metadata?.developer ?? '');
    return [
      if (developer.isNotEmpty)
        _buildMetaItem(icon: Icons.business_rounded, text: developer),
      ..._buildMetadataChips(),
    ];
  }

  /// 头部标签区：复用既有 `_buildTag`
  ///
  /// 设计实测（`Shell.png`）标签胶囊外框 ≈ 50×20（x 393..443 / y 186..204），
  /// 明显小于旧版非紧凑样式（fontSize 14 → ≈84×31），故此处**恒用紧凑档**
  /// （fontSize 12 → ≈64×22），高度与设计基本对齐。
  /// ⚠️ 残留差异：设计字号实测 ≈9.5px，紧凑档 12px，故宽度偏大 ~14px；
  ///    如需像素级复刻，需再给 `_buildTag` 增加一档 dense（本次未做）。
  Widget _buildHeaderTags() {
    // 全局隐藏标签（分类匣·标签库内联编辑）在此生效——所有本地标签展示点
    // 统一走 TagLibraryOverrideStore.filterVisibleTags
    final tags = TagLibraryOverrideStore.instance
        .filterVisibleTags(_gameData?.tags ?? const []);
    if (tags.isEmpty) {
      return Text(
        '暂无标签',
        style: AppStyles.bodyRegular.copyWith(
          fontSize: 12,
          color: AppColors.secondaryText.withOpacity(0.7),
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [for (final tag in tags) _buildTag(tag, compact: true)],
    );
  }

  // ==================== v4.0 资源来源 ====================

  /// 加载官方补充 / 用户分享资源（失败不阻塞页面）。
  ///
  /// 🔴 `game_resources` 只是**补充**通道：官方下载的真正依据是原生
  /// `games.downloadUrl`（见 [_officialResource]）。因此这里失败**不得**
  /// 让「获取」按钮变成不可用——只记日志 + 供分享弹窗显示错误。
  Future<void> _loadResources() async {
    setState(() {
      _isLoadingResources = true;
      _resourceError = null;
    });
    try {
      final results = await Future.wait([
        GameResourceService.fetchOfficial(widget.gameId),
        GameResourceService.fetchCommunity(widget.gameId),
      ]);
      if (!mounted) return;
      setState(() {
        _officialResources = results[0];
        _communityResources = results[1];
        _isLoadingResources = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingResources = false;
        // 只影响「分享」弹窗的列表展示，不影响「获取」（原生下载）
        _resourceError = e.toString().replaceFirst('Exception: ', '');
      });
      debugPrint('[DETAIL] ⚠️ 资源补充信息加载失败（不影响原生下载）: $e');
    }
  }

  /// 主官方来源：优先有下载路径的那条
  ///
  /// ⚠️ 只用于**补充展示**（资源类型/平台/下载人数）。判断"能不能装"请看
  /// [_officialResource]，它的依据是原生 `games.downloadUrl`。
  GameResourceModel? get _primaryOfficial {
    for (final r in _officialResources) {
      if (r.hasDownloadPath) return r;
    }
    return _officialResources.isNotEmpty ? _officialResources.first : null;
  }

  /// 「获取」弹窗与安装可用性的**统一官方资源视图**。
  ///
  /// 🔴 **关键修复（2026-10-01）**：官方/原生资源的真正依据是 `games` 表自身
  /// （`downloadUrl` + `version` + `versionNote` + `installCount`）——它**一直都在**，
  /// 只是历史上没被这一步读取。改造前这里写成 `_primaryOfficial`（即
  /// `game_resources` 的 `kind=official` 记录），而该表 official 记录为 0 条
  /// ⇒ 按钮/弹窗被判「无资源」，即便用户明明有原生下载。
  ///
  /// 合并规则：**以 `games` 为准，`game_resources` 记录仅作补充**。
  /// 返回 null **仅当** `downloadUrl` 也为空（该作品确实无官方资源）。
  OfficialResourceView? get _officialResource {
    final g = _gameData;
    if (g == null) return null;
    final path = g.downloadUrl.trim();
    if (path.isEmpty) return null;
    return OfficialResourceView.fromGame(
      downloadPath: path,
      version: g.version,
      versionNote: g.versionNote,
      installCount: g.installCount,
      created: g.created,
      supplement: _primaryOfficial,
    );
  }

  /// 当前本机安装状态（与右列旧安装区使用同一数据源，语义不变）
  ResourceInstallState get _installState {
    if (_isLocallyInstalled) return ResourceInstallState.installed;
    final center = GlobalInstallCenter.instance;
    if (center.isBusy && center.currentTask?.gameId == widget.gameId) {
      return ResourceInstallState.installing;
    }
    if (center.isQueued(widget.gameId)) return ResourceInstallState.queued;
    // 判据改为「原生 downloadUrl 是否可用」，而非「有没有 official 记录」
    if (_officialResource == null) return ResourceInstallState.disabled;
    return ResourceInstallState.idle;
  }

  double get _installProgress {
    final center = GlobalInstallCenter.instance;
    if (center.currentTask?.gameId != widget.gameId) return 0;
    return (center.progress.downloadPercent / 100).clamp(0.0, 1.0);
  }

  String get _getButtonLabel {
    switch (_installState) {
      case ResourceInstallState.installed:
        return '已安装';
      case ResourceInstallState.installing:
        return '安装中';
      case ResourceInstallState.queued:
        return '排队中';
      case ResourceInstallState.disabled:
      case ResourceInstallState.idle:
        return '获取';
    }
  }

  /// 「获取」按钮是否可点。
  ///
  /// 🔴 历史上这里写成 `_installState != disabled`，而 `disabled` 的触发条件是
  /// **`game_resources` 里没有 `kind=official` 记录**。但官方下载的真正依据是
  /// 原生 `games.downloadUrl`——它一直都在。于是按钮被判「无资源」，
  /// 表现为「完全点不动且没有任何提示」，真机反馈即「我明明有官方资源却说没有」。
  ///
  /// 现已两处一起修正：① [ResourceInstallState.disabled] 改由
  /// [_officialResource]（原生路径）判定；② 本 getter 只在**安装中**才禁用，
  /// 其余一律可点，点击后由 [_resolveGetBlockReason] 给出明确原因。
  bool get _getButtonEnabled =>
      _installState != ResourceInstallState.installing;

  bool get _getButtonBusy =>
      _installState == ResourceInstallState.installing;

  /// 「获取」按钮当前为何不能打开下载浮层；返回 null 表示可以打开。
  ///
  /// ⚠️ **不要**因为"没有用户上传/没有 official 记录"而拦下——
  /// 官方下载走的是原生 `games.downloadUrl`，与用户分享是两条独立通道。
  /// 按「先本地、后远端」顺序排查，每条都给可执行的下一步。
  String? _resolveGetBlockReason() {
    if (!PBConfig.isLoggedIn) {
      // 本地账号体系：统一权限文案（local_account_mode.md §2.5-7）
      return '该功能需要登录账号后使用';
    }
    if (_resourceError != null) {
      return '资源信息加载失败：$_resourceError';
    }
    if (_isLoadingResources) {
      return '正在加载资源信息，请稍候再点';
    }
    // 只有原生 downloadUrl 也为空时才是「真的没有官方资源」
    if (_officialResource == null) {
      return '《${_gameData?.title ?? '本作品'}》暂无官方下载，可点「分享」查看用户分享';
    }
    return null;
  }

  /// 「获取」→ 打开 Chrono Tide 下载浮层（锚定在本按钮所在区域）
  ///
  /// 展示的官方资源信息（版本 / 大小 / 下载人数）全部来自**原生 `games` 记录**，
  /// `game_resources` 的 official 记录存在时仅作补充。
  Future<void> _handleGetTap() async {
    final blockReason = _resolveGetBlockReason();
    if (blockReason != null) {
      AppSnackBar.warning(context, blockReason);
      return;
    }
    final anchor = _actionAnchorRect();
    await showDarkAnchoredPanel<void>(
      context: context,
      anchor: anchor,
      preferredWidth: DarkPalette.downloadBarWidth,
      builder: (_) => CtDownloadDialog(
        gameTitle: _gameData?.title ?? '',
        resource: _officialResource,
        state: _installState,
        ownerAvatarUrl: null,
        progress: _installProgress,
        // 原生来源在 `games` 无大小字段 → 用本地预取结果兜底
        fallbackFileSize: _fileSizeInfo?.formatted ?? '',
        onDownload: _handleInstallTap,
        onCancel: _handleCancelInstall,
        onReport: _handleFeedbackTap,
      ),
    );
  }

  /// 「分享」→ 打开资源分享浮层
  Future<void> _handleShareTap() async {
    final anchor = _actionAnchorRect();
    await showDarkAnchoredPanel<void>(
      context: context,
      anchor: anchor,
      preferredWidth: DarkPalette.shareListWidth,
      builder: (dialogCtx) => ShareListDialog(
        gameTitle: _gameData?.title ?? '',
        resources: _communityResources,
        loading: _isLoadingResources,
        error: _resourceError,
        onOpenDetail: (r) => _openShareDetail(dialogCtx, r),
        onOpenLink: (r) => _openResourceLink(r),
        onUpload: () {
          Navigator.of(dialogCtx).maybePop();
          _handleUploadTap();
        },
      ),
    );
  }

  /// 从分享浮层进入分享详情（先关列表再开详情，避免路由叠加）
  Future<void> _openShareDetail(BuildContext listCtx, GameResourceModel r) async {
    Navigator.of(listCtx).maybePop();
    await showDarkCenteredDialog<void>(
      context: context,
      builder: (_) => ShareDetailDialog(
        resource: r,
        onClose: () => Navigator.of(context).maybePop(),
        onReport: () => _handleResourceReport(r),
        onOpenLink: () => _openResourceLink(r),
      ),
    );
  }

  /// 「上传」→ 打开发布资源表单
  ///
  /// 前置守卫：`game_resources.createRule` 要求 `@request.auth.id != ""`，
  /// 未登录就填完整张表单再被 401 拒掉体验很差，故在入口处先拦。
  /// （此处只提示，不主动弹登录框——登录框由 `main_container` 的 Overlay
  /// 统一管理，属稳定区，不在本次改动范围内。）
  Future<void> _handleUploadTap() async {
    if (!PBConfig.isLoggedIn) {
      // 本地账号体系：统一权限文案
      AppSnackBar.warning(context, '该功能需要登录账号后使用');
      return;
    }
    await showDarkCenteredDialog<void>(
      context: context,
      builder: (dialogCtx) => UploadResourceDialog(
        gameTitle: _gameData?.title ?? '',
        onClose: () => Navigator.of(dialogCtx).maybePop(),
        onSubmit: (draft) async {
          // 先捕获 Navigator：await 之后再用 dialogCtx 会触发
          // use_build_context_synchronously（该 context 属弹窗，与 State.mounted 无关）。
          final dialogNav = Navigator.of(dialogCtx);
          await GameResourceService.createCommunityResource(
            gameId: widget.gameId,
            url: draft.url,
            title: draft.title,
            fileSize: draft.fileSize,
            version: draft.version,
            linkType: draft.linkType,
            netdiskProvider: draft.netdiskProvider,
            extractCode: draft.extractCode,
            unzipCode: draft.unzipCode,
            note: draft.note,
            resourceTypes: draft.resourceTypes,
            languages: draft.languages,
            platforms: draft.platforms,
          );
          if (!mounted) return;
          dialogNav.maybePop();
          AppSnackBar.success(context, '已提交，审核通过后对所有用户可见');
          _loadResources();
        },
      ),
    );
  }

  /// 「喜欢」→ 作品级点赞（games 级，主线补完 §14.2-P2）
  ///
  /// 登录/本地态守卫（统一文案，不主动弹登录框）→ 乐观更新（点亮态 +
  /// likeCount 本地 ±1）→ 服务端 `setGameLike`；失败回滚。真实计数由
  /// 服务端按 (user, game) 去重保证，重复点亮幂等不重复计数。
  Future<void> _handleLikeTap() async {
    if (!PBConfig.isLoggedIn) {
      // 本地账号体系：统一权限文案
      AppSnackBar.warning(context, '该功能需要登录账号后使用');
      return;
    }
    final gameId = _gameData?.id ?? '';
    if (gameId.isEmpty) return;
    final target = !_likedByMe;
    final prevCount = _gameData?.likeCount ?? 0;
    setState(() {
      _likedByMe = target;
      if (_gameData != null) {
        _gameData = _gameData!
            .copyWith(likeCount: (prevCount + (target ? 1 : -1)).clamp(0, 1 << 31));
      }
    });
    final ok = await GameResourceService.setGameLike(gameId, target);
    if (!mounted) return;
    if (ok) {
      AppSnackBar.info(context, target ? '已加入喜欢' : '已取消喜欢');
    } else {
      // 失败回滚（路由未部署 / 网络 / 服务端异常一律回到操作前状态）
      setState(() {
        _likedByMe = !target;
        if (_gameData != null) {
          _gameData = _gameData!.copyWith(likeCount: prevCount);
        }
      });
      AppSnackBar.error(context, '操作未同步，请稍后再试');
    }
  }

  /// 点赞回显：查询我是否已赞本作品（未登录 / 失败静默，保持未点亮）
  Future<void> _loadLikeState() async {
    final liked = await GameResourceService.fetchMyLikedGameIds([widget.gameId]);
    if (!mounted || liked.isEmpty) return;
    setState(() => _likedByMe = true);
  }

  /// 「反馈」→ 官网 FAQ 引导的反馈通道（GitHub Issues）。
  /// 官网 faq.html 的用户引导即为此地址（「欢迎在 GitHub Issues 提问」），
  /// 客户端按钮与官网语义对齐。
  Future<void> _handleFeedbackTap() async {
    const feedbackUrl = 'https://github.com/hardman1314/-Chrono.Tide-/issues';
    final ok = await WebsiteBookmarkService.openExternal(feedbackUrl);
    if (!ok && mounted) {
      AppSnackBar.error(context, '无法打开反馈页面，请确认网络是否可用');
    }
  }

  /// 分享详情「报告失效」→ 上报举报（Phase 3 任务 B）
  ///
  /// 服务端按（用户, 资源）唯一去重：重复举报幂等成功且不重复计数。
  /// 未登录先提示（与上传入口同策略，不主动弹登录框）。
  Future<void> _handleResourceReport(GameResourceModel r) async {
    if (!PBConfig.isLoggedIn) {
      // 本地账号体系：统一权限文案
      AppSnackBar.warning(context, '该功能需要登录账号后使用');
      return;
    }
    final confirmed = await showConfirmDialog(
      context: context,
      title: '报告失效',
      message: '确认报告这个资源的问题吗？（如链接失效、内容与描述不符等）\n'
          '每位用户对同一资源只计一次，重复点击不会重复计数。',
      confirmText: '确认报告',
    );
    if (!confirmed || !mounted) return;
    final ok = await GameResourceService.reportResource(r.id);
    if (!mounted) return;
    if (ok) {
      AppSnackBar.success(context, '已收到你的报告，我们会尽快核实处理');
    } else {
      AppSnackBar.error(context, '报告失败，请稍后再试');
    }
  }

  /// 打开资源外链（复用既有外链白名单校验）
  ///
  /// 🔴 权限 gate（local_account_mode.md §2.4）：「通过分享获取资源」对
  /// 未登录/本地用户 ❌。分享列表/详情可匿名浏览（矩阵允许），但
  /// 「获取资源 → 打开链接」是资源获取的实际出口，必须拦——
  /// 否则本地用户可绕过「获取」「上传」的既有 gate 走通分享下载全链路。
  /// 分享列表「获取资源」按钮两条路径（进详情后开链 / 列表 fallback 直接开链）
  /// 都汇聚到本方法，此处拦一处即全覆盖。
  Future<void> _openResourceLink(GameResourceModel r) async {
    if (!PBConfig.isLoggedIn) {
      // 本地账号体系：统一权限文案
      AppSnackBar.warning(context, '该功能需要登录账号后使用');
      return;
    }
    if (!r.hasUrl) {
      AppSnackBar.warning(context, '该资源没有可跳转的链接');
      return;
    }
    final ok = await WebsiteBookmarkService.openExternal(r.url);
    if (ok) {
      // 主线补完 §14.2-P1：下载计数打点（产品定义：打开链接点一次 +1）。
      // 服务端按登录用户去重；路由未部署时静默失败——统计绝不阻塞主流程
      // （打点风格对齐 _handleInstallTap，本文件 :682）。
      GameResourceService.registerDownload(r.id);
    } else if (mounted) {
      AppSnackBar.error(context, '无法打开链接，请确认网址是否有效');
    }
  }

  /// 操作按钮行的锚点矩形（用于把浮层定位到按钮旁）
  ///
  /// 用 [_actionRowKey] 拿全局 Rect；拿不到时退化为内容区左上角，
  /// 至少保证浮层落在可视区内。
  Rect _actionAnchorRect() {
    final box = _actionRowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final offset = box.localToGlobal(Offset.zero);
      return offset & box.size;
    }
    return const Rect.fromLTWH(64, 160, 240, 38);
  }

  /// 返回按钮（44×44 原样）+ 分级框（返回按钮右侧同一行）
  ///
  /// 分级框（参考库页面包屑设计，单行轻量）：
  /// - 位置：返回按钮右边、内容区顶栏高度带内（top: 16 与按钮同线），
  ///   不向下延伸，避免与封面图/标签区域重叠
  /// - 首级固定为「列表」（点击 = onBack 回探索页）
  /// - 1 个层级（未发生系列内跳转）：分级框不显示，仅返回按钮
  /// - 2 个层级：列表 › A › B，完整显示
  /// - 3 个及以上：省略机制——只显示「列表 › … › 前一级 › 当前级」，
  ///   「…」点击弹出被折叠的中间级菜单，可直达任意层级
  /// - 当前级高亮不可点；历史级可点（走 main_container 的历史折叠跳转）
  Widget _buildBackButton() {
    final crumbs = widget.navBreadcrumb;
    final hasLevels = crumbs.length > 1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildBackIconButton(),
        if (hasLevels) ...[
          const SizedBox(width: 12),
          _buildHierarchyBar(crumbs),
        ],
      ],
    );
  }

  /// 44×44 返回图标按钮（保持原有样式）
  Widget _buildBackIconButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _backHovered = true),
      onExit: (_) => setState(() => _backHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _backHovered = true),
        onTapUp: (_) => setState(() => _backHovered = false),
        onTapCancel: () => setState(() => _backHovered = false),
        onTap: widget.onBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _backHovered
                ? AppColors.placeholderCover
                : AppColors.background,
            border: Border.all(
              color: _backHovered ? AppColors.border : AppColors.border,
              width: _backHovered ? 2.0 : 1.6,
            ),
            boxShadow: _backHovered
                ? [
                    BoxShadow(
                      color: const Color(0x408B7355),
                      offset: const Offset(0, 2),
                      blurRadius: 10,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: AppColors.border,
                      offset: const Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 20,
              color: AppColors.border,
            ),
          ),
        ),
      ),
    );
  }

  /// 分级框：列表 › … › 前一级 › 当前级（库页面包屑风格，单行轻量）
  ///
  /// 宽度：屏幕的 40%，上限 560——比返回按钮右侧可用空间更长，
  /// 但不会伸到右侧截图区。文字重合修复：框内不再横向滚动，
  /// 改为每个层级段各自省略（ellipsis）+ Flexible 弹性分配，
  /// 当前级优先获得更大宽度，任何情况下级与级之间不会叠字。
  Widget _buildHierarchyBar(List<SeriesNavCrumb> crumbs) {
    // 省略机制：>2 个作品层级时，中间级折叠为「…」，
    // 只保留当前级的前一级（用户最常回跳的位置）
    final List<Object> segments; // SeriesNavCrumb 或 '…'
    if (crumbs.length <= 2) {
      segments = [...crumbs];
    } else {
      segments = ['…', crumbs[crumbs.length - 2], crumbs.last];
    }

    return LayoutBuilder(builder: (context, constraints) {
      final barWidth =
          (MediaQuery.sizeOf(context).width * 0.4).clamp(220.0, 560.0);
      return Container(
        width: barWidth,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.background.withOpacity(0.82),
          border: Border.all(color: AppColors.border.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            // 首级：「列表」= 直接回探索页游戏列表（首页语义，清空栈）
            _buildHierarchyText(
              '列表',
              onTap: widget.onBackToList ?? widget.onBack,
              isCurrent: false,
              icon: Icons.apps_rounded,
            ),
            for (final seg in segments) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Icon(Icons.chevron_right,
                    size: 14, color: AppColors.placeholderText),
              ),
              if (seg == '…')
                _buildEllipsisEntry(crumbs)
              else
                Flexible(
                  // 当前级权重更高（flex 2 vs 1），挤压时获得更多显示空间
                  flex: seg == crumbs.last ? 2 : 1,
                  child: _buildHierarchyCrumb(seg as SeriesNavCrumb,
                      isCurrent: seg == crumbs.last),
                ),
            ],
          ],
        ),
      );
    });
  }

  /// 历史级（可点回跳）/「列表」级：次级色 + 悬停变亮
  Widget _buildHierarchyText(
    String text, {
    required VoidCallback? onTap,
    required bool isCurrent,
    IconData? icon,
    FontWeight? weight,
  }) {
    final node = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: AppColors.secondaryText),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 12.5,
              fontWeight: weight ?? FontWeight.w500,
              color: isCurrent
                  ? AppColors.primaryText
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ],
    );
    if (onTap == null) return node;
    return InteractiveWrapper(
      onTap: onTap,
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: node,
      ),
    );
  }

  /// 单个作品分级段：当前级加粗高亮不可点，历史级可点回跳；
  /// 宽度自适应收缩（外层 Flexible），文字超长省略不叠字
  Widget _buildHierarchyCrumb(SeriesNavCrumb crumb, {required bool isCurrent}) {
    return Tooltip(
      message: isCurrent ? crumb.title : '回到「${crumb.title}」',
      waitDuration: const Duration(milliseconds: 300),
      child: _buildHierarchyText(
        crumb.title,
        onTap: isCurrent
            ? null
            : () => widget.onNavigateToGame
                ?.call(crumb.id, crumb.title, crumb.coverUrl),
        isCurrent: isCurrent,
        weight: isCurrent ? FontWeight.w700 : null,
      ),
    );
  }

  /// 省略号「…」：悬停/点击弹出被折叠的中间级列表，可直达任意层级
  Widget _buildEllipsisEntry(List<SeriesNavCrumb> crumbs) {
    // 被折叠的中间级（去掉首尾各一级）
    final hidden = crumbs.sublist(0, crumbs.length - 2);
    return Tooltip(
      message: '查看全部 ${crumbs.length} 级',
      waitDuration: const Duration(milliseconds: 400),
      child: InteractiveWrapper(
        onTap: () => _showEllipsisMenu(hidden),
        hoverScale: 1.0,
        hoverOffset: const Offset(0, -1),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.buttonBackground,
              border: Border.all(color: AppColors.border.withOpacity(0.6)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '…',
              style: AppStyles.bodyRegular.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.secondaryText),
            ),
          ),
        ),
      ),
    );
  }

  /// 省略级菜单：锚定弹出（Overlay），点击任意被折叠层级直接回跳
  void _showEllipsisMenu(List<SeriesNavCrumb> hidden) {
    if (hidden.isEmpty) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    // 菜单关闭：点外部屏障或点选某级后移除
    void close() => entry.remove();
    entry = OverlayEntry(
      builder: (context) => GestureDetector(
        // 全屏透明屏障：点击任意处关闭菜单
        onTap: close,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            // 菜单本体：锚定在分级框「…」附近（左上角区域下方）
            Positioned(
              left: 60,
              top: 76,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: 260,
                  constraints: const BoxConstraints(maxHeight: 300),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    border: Border.all(color: AppColors.border, width: 2),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.border,
                          offset: const Offset(4, 5),
                          blurRadius: 0),
                    ],
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < hidden.length; i++) ...[
                          InteractiveWrapper(
                            onTap: () {
                              final c = hidden[i];
                              close();
                              widget.onNavigateToGame
                                  ?.call(c.id, c.title, c.coverUrl);
                            },
                            hoverScale: 1.0,
                            hoverOffset: const Offset(0, -1),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                child: Row(
                                  children: [
                                    Text(
                                      '${i + 1}',
                                      style: AppStyles.bodyRegular.copyWith(
                                          fontSize: 11,
                                          color: AppColors.secondaryText
                                              .withOpacity(0.6)),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        hidden[i].title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppStyles.bodyRegular.copyWith(
                                            fontSize: 13,
                                            color: AppColors.primaryText),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (i < hidden.length - 1)
                            Container(
                                height: 1,
                                color:
                                    AppColors.border.withOpacity(0.25)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    overlay.insert(entry);
  }

  Widget _buildErrorView() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.background,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: AppColors.dangerRed.withOpacity(0.6)),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '加载游戏详情失败',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 15,
                  height: 22 / 15,
                  color: AppColors.dangerRed),
            ),
            const SizedBox(height: 24),
            InteractiveWrapper(
              onTap: _loadGameData,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  border: Border.all(color: AppColors.border, width: 2),
                  boxShadow: [
                    BoxShadow(
                        color: AppColors.border,
                        offset: const Offset(2, 3),
                        blurRadius: 0)
                  ],
                ),
                child: Text('重新加载',
                    style: AppStyles.bodyRegular
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 16),
            InteractiveWrapper(
              onTap: widget.onBack,
              hoverScale: 1.0,
              hoverOffset: const Offset(0, -1),
              child: Text('返回',
                  style: TextStyle(
                      fontSize: 15,
                      color: AppColors.secondaryText,
                      decoration: TextDecoration.underline,
                      decorationColor:
                          AppColors.secondaryText.withOpacity(0.5))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftSection() {
    // v4.0 重构：封面 + 标题/元数据/标签已上移为整宽「游戏数据区」，
    // 左列现在只剩「游戏简介」面板——面板吃掉整列可用高度，
    // 面板内部独立滚动（超长简介不会撑破两栏布局）。
    return _buildDescription();
  }

  Widget _buildGameCover() {
    // v4.0 重构：封面 216×323 → 135×205（设计实测 2:3，明显缩小）
    return Transform.rotate(
      angle: -2 * 3.14159 / 180,
      child: Container(
        width: GameDetailHeader.coverWidth,
        height: GameDetailHeader.coverHeight,
        decoration: BoxDecoration(
          color: AppColors.placeholderCover,
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 5),
                blurRadius: 0)
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(fit: StackFit.expand, children: [_buildCoverImage()]),
      ),
    );
  }

  Widget _buildCoverImage() {
    final coverUrl = _gameData?.coverUrl ?? '';
    if (coverUrl.isEmpty || !coverUrl.startsWith('http')) {
      return Container(
          color: AppColors.placeholderCover,
          child: Center(
              child: Icon(Icons.image_outlined,
                  size: 48, color: AppColors.secondaryText.withOpacity(0.25))));
    }
    return Stack(fit: StackFit.expand, children: [
      // UX-15: 统一使用 CachedNetworkImage，提供磁盘缓存避免重复下载
      NsfwImage.network(
        coverUrl,
        contentKind: NsfwContentKind.cover,
        // 封面若只存在于图片磁盘缓存（未经 CoverDownloadService 落盘），
        // 需在缓存就绪后按需补检（§7.1 风险🟠4）
        detectOnDemand: true,
        child: CachedNetworkImage(
          cacheManager: PortableImageCacheManager(),
          imageUrl: coverUrl,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(
            color: AppColors.placeholderCover,
            child: Center(
              child: Icon(Icons.image_outlined,
                  size: 48, color: AppColors.secondaryText.withOpacity(0.25)),
            ),
          ),
          errorWidget: (_, __, ___) => Container(
              color: AppColors.placeholderCover,
              child: Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 40,
                      color: AppColors.secondaryText.withOpacity(0.2)))),
        ),
      ),
      Container(color: Colors.white.withOpacity(0.38)),
    ]);
  }

  // v4.0 重构后本方法无调用点（编译器的 unused_element 已证明）。
  // 按 AGENTS §2.3「删除既有代码须先证明无用并请示」，此处**暂不删除**，
  // 仅加 ignore 抑制噪声；待开发者确认新流程（获取按钮 + 下载浮层）稳定后统一清理。
  // ignore: unused_element
  Widget _buildGameInfo() {
    final tags = _gameData?.tags ?? [];
    // 开发者优先使用 PB 数据，缺失时回退到元数据
    final developer = (_gameData?.developer ?? '').isNotEmpty
        ? _gameData!.developer
        : (_metadata?.developer ?? '');
    // 阶段3.4：构造元数据信息条目（发售日/评分/热度/来源平台）
    final metaChips = _buildMetadataChips();

    return Container(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      // 高度自适应：封面高 323 为参考上限，内容多时自然超出（外层整列可滚动）
      constraints: const BoxConstraints(minHeight: 200, maxHeight: 380),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_gameData?.title ?? '未知游戏',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.titleLarge.copyWith(
                fontSize: 32,
                letterSpacing: 2.0,
              )),
          // 日语/英语标题副标题：小字体显示在主标题下方，仅详情页展示
          ..._buildSubtitleTitles(),
          const SizedBox(height: 12),
          if (developer.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.business_rounded,
                      size: 15,
                      color: AppColors.secondaryText.withOpacity(0.6)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(developer,
                        style: AppStyles.bodyRegular.copyWith(
                            fontSize: 14,
                            color: AppColors.secondaryText.withOpacity(0.7),
                            fontStyle: FontStyle.normal)),
                  ),
                ],
              ),
            ),
          // 阶段3.4：元数据信息行（仅当有数据时显示，融洽不喧宾夺主）
          if (metaChips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 14,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: metaChips,
              ),
            ),
          const SizedBox(height: 4),
          // 标签区：宽度自适应——挤压时标签整体缩小（padding/字号/边框），
          // 保证完整显示且不与下方简介重叠
          LayoutBuilder(builder: (context, constraints) {
            final compactTags =
                constraints.maxWidth < 320 || tags.length > 12;
            return tags.isNotEmpty
                ? Wrap(
                    spacing: compactTags ? 5 : 8,
                    runSpacing: compactTags ? 5 : 8,
                    children: [
                      for (final tag in tags) _buildTag(tag, compact: compactTags)
                    ],
                  )
                : Text('暂无标签',
                    style: AppStyles.bodyRegular.copyWith(
                        fontSize: 13,
                        color: AppColors.secondaryText.withOpacity(0.7),
                        fontStyle: FontStyle.italic));
          }),
        ],
      ),
    );
  }

  /// 日语/英语标题副标题：小字体显示在主标题下方
  /// 仅当字段非空且与主标题不同时展示，避免重复信息
  List<Widget> _buildSubtitleTitles() {
    final title = _gameData?.title ?? '';
    final original = _gameData?.originalTitle ?? '';
    final english = _gameData?.englishTitle ?? '';
    final widgets = <Widget>[];

    if (original.isNotEmpty && original != title) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(original,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppStyles.bodyRegular.copyWith(
                fontSize: 13,
                color: AppColors.secondaryText.withOpacity(0.75))),
      ));
    }
    if (english.isNotEmpty && english != title) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(english,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppStyles.bodyRegular.copyWith(
                fontSize: 13,
                color: AppColors.secondaryText.withOpacity(0.75))),
      ));
    }
    return widgets;
  }

  Widget _buildTag(String tag, {bool compact = false}) {
    return Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 12, vertical: compact ? 2 : 4),
        decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            border: Border.all(
                color: AppColors.border, width: compact ? 1 : 2)),
        child: Text(tag,
            overflow: TextOverflow.clip,
            style: AppStyles.bodyRegular
                .copyWith(fontSize: compact ? 12 : 14)));
  }

  /// 阶段3.4：构造元数据信息条目列表
  ///
  /// 仅返回有数据的条目，无数据时返回空列表（不渲染该行）。
  /// 条目顺序：发售日 → 评分 → 热度（投票数）→ 数据来源
  /// 样式：图标 + 文字，次要色调，与开发者行保持视觉一致
  List<Widget> _buildMetadataChips() {
    final meta = _metadata;
    if (meta == null) return [];

    final chips = <Widget>[];

    // 发售日：优先展示完整日期，长度过长时降级为年份
    if (meta.releaseDate != null && meta.releaseDate!.isNotEmpty) {
      final date = meta.releaseDate!;
      // 格式化：2024-01-15 → 2024年1月15日（仅当格式标准时）
      String display;
      final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(date);
      if (match != null) {
        display =
            '${match.group(1)}年${int.parse(match.group(2)!)}月${int.parse(match.group(3)!)}日';
      } else {
        display = date;
      }
      chips.add(_buildMetaItem(
        icon: Icons.event_rounded,
        text: display,
      ));
    }

    // 评分：0-10 分制，仅当 > 0 时显示
    if (meta.rating != null && meta.rating! > 0) {
      chips.add(_buildMetaItem(
        icon: Icons.star_rounded,
        text: meta.rating!.toStringAsFixed(1),
        iconColor: AppColors.starGold,
      ));
    }

    // 热度：VNDB 投票数作为热度代理，仅当 > 0 时显示
    if (meta.voteCount != null && meta.voteCount! > 0) {
      chips.add(_buildMetaItem(
        icon: Icons.people_alt_rounded,
        text: _formatVoteCount(meta.voteCount!),
      ));
    }

    // 预计游玩时长：VNDB 多用户平均（2026-10-04），仅当 > 0 时显示
    if (meta.estimatedMinutes != null && meta.estimatedMinutes! > 0) {
      chips.add(_buildMetaItem(
        icon: Icons.schedule_rounded,
        text: _formatEstimatedPlaytime(meta.estimatedMinutes!),
      ));
    }

    // 数据来源：标注元数据出处，便于用户判断数据可信度
    if (meta.sourcePlatform != null && meta.sourcePlatform!.isNotEmpty) {
      chips.add(_buildMetaItem(
        icon: Icons.language_rounded,
        text: meta.sourcePlatform!,
      ));
    }

    return chips;
  }

  /// 单个元数据条目：图标 + 文字，次要色调
  Widget _buildMetaItem({
    required IconData icon,
    required String text,
    Color? iconColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 13,
          color: iconColor ?? AppColors.secondaryText.withOpacity(0.6),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: AppStyles.bodyRegular.copyWith(
            fontSize: 12,
            color: AppColors.secondaryText.withOpacity(0.75),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// 格式化投票数：1000+ → 1.0k，10000+ → 10k
  String _formatVoteCount(int count) {
    if (count >= 10000) {
      return '${(count / 1000).toStringAsFixed(0)}k';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return count.toString();
  }

  /// 格式化预计游玩时长（分钟）：≥60 → 「约 X 小时」（小数仅保留非零一位），
  /// <60 → 「约 X 分钟」
  String _formatEstimatedPlaytime(int minutes) {
    if (minutes < 60) return '约 $minutes 分钟';
    final hours = minutes / 60;
    final text = hours == hours.roundToDouble()
        ? '${hours.toInt()}'
        : hours.toStringAsFixed(1);
    return '约 $text 小时';
  }

  Widget _buildDescription() {
    String rawDescription =
        _gameData?.description.isNotEmpty == true ? _gameData!.description : '';

    final description = rawDescription
        .replaceAll(RegExp(r'\*\*\*(.+?)\*\*\*'), r'$1')
        .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
        .replaceAll(RegExp(r'\*(.+?)\*'), r'$1')
        .replaceAll(RegExp(r'~~(.+?)~~'), r'$1')
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
        .trim();

    return Container(
      width: double.infinity,
      // 高度由外层布局分配（v4.0：头部上移后，左列 = 简介面板整列）
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
          // 设计：面板填充 #F8F5EE / 描边 #9B805E → 走主题令牌
          // （暖阳主题的 placeholderBg #F5F1E8 / border #8B7355，色差 < 4%）
          color: AppColors.placeholderBg,
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
                color: AppColors.border.withOpacity(0.05),
                offset: const Offset(2, 3),
                blurRadius: 5)
          ]),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                padding: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color: AppColors.placeholderCover, width: 2))),
                child: Text('游戏简介',
                    style: AppStyles.heading.copyWith(
                      fontSize: 19,
                      letterSpacing: 4,
                    ))),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Text(description,
                    style: TextStyle(
                      fontSize: 15,
                      height: 24 / 15,
                      color: AppColors.primaryText,
                    )),
              ),
            ),
          ]),
    );
  }

  Widget _buildRightSection() {
    final hasScreenshots =
        _screenshotUrls.isNotEmpty || _localScreenshots.isNotEmpty;

    // 决定截图展示区内容
    Widget screenshotArea;
    if (_isLoadingScreenshots) {
      // 阶段1：截图URL获取中，显示加载占位
      screenshotArea = _buildScreenshotLoadingPlaceholder();
    } else if (_screenshotFetchFailed && !hasScreenshots) {
      // 阶段2：获取失败且无截图，显示中央刷新图标（点击重新加载）
      // 传入 gameTitle 以便感知本地截图后台下载状态
      screenshotArea = ScreenshotCarousel(
        paths: const [],
        gameTitle: _gameData?.title,
        onRefresh: _reloadScreenshots,
      );
    } else if (!hasScreenshots) {
      // 无截图数据（抓取成功但各平台均无截图）：中央刷新图标可重试
      screenshotArea = ScreenshotCarousel(
        paths: const [],
        gameTitle: _gameData?.title,
        onRefresh: _reloadScreenshots,
      );
    } else {
      // 阶段3：有截图URL或本地文件，直接传给轮播组件
      // CachedNetworkImage 会逐张加载，先加载完的先显示
      screenshotArea = ScreenshotCarousel(
        paths:
            _localScreenshots.isNotEmpty ? _localScreenshots : _screenshotUrls,
        isNetwork: _screenshotUrls.isNotEmpty && _localScreenshots.isEmpty,
        gameTitle: _gameData?.title,
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        // 截图展示区（强制占比 2/3）：
        // - 有系列数据：弹性 2 份配额 + FittedBox 等比缩放——空间充足按 16:9
        //   原尺寸，空间不足整体等比缩小不变形，任何情况下完整可见
        // - 无系列数据：保持原有布局零改动
        if (_seriesData != null)
          Flexible(
            flex: 2,
            child: LayoutBuilder(builder: (context, constraints) {
              return FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: screenshotArea,
                ),
              );
            }),
          )
        else
          screenshotArea,
        // 系列框（有系列数据时才渲染；无系列时布局零偏移）。
        // 弹性 1 份配额 → 截图:系列 恒定 2:1；内容超高时静默裁剪兜底
        //（单行列表实际高度 ≈ 127px，仅在极端矮窗口才触发裁剪）
        if (_seriesData != null) ...[
          const SizedBox(height: 14),
          Flexible(
            flex: 1,
            child: SingleChildScrollView(
              physics: NeverScrollableScrollPhysics(),
              child: SeriesStrip(
                seriesData: _seriesData!,
                currentGameId: widget.gameId,
                onNavigateToGame: _navigateToSeriesGame,
                onOpenPanel: _openSeriesPanel,
              ),
            ),
          ),
        ],
        // v4.0 重构：右列底部的安装按钮区（排队中/安装中/已安装/获取）整体移除——
        // 安装入口与状态改由顶部「获取」按钮 + 「Chrono Tide 下载」浮层承载，
        // 因此这里不再需要 Spacer 把按钮顶到底部。
      ],
    );
  }

  /// 本游戏排队中：显示排队状态与前方任务数（轻量文字，无大标题）
  // v4.0 重构后本方法无调用点（编译器的 unused_element 已证明）。
  // 按 AGENTS §2.3「删除既有代码须先证明无用并请示」，此处**暂不删除**，
  // 仅加 ignore 抑制噪声；待开发者确认新流程（获取按钮 + 下载浮层）稳定后统一清理。
  // ignore: unused_element
  Widget _buildQueuedUI() {
    final center = GlobalInstallCenter.instance;
    final queued = center.queuedTasks;
    final position = queued.indexWhere((t) => t.gameId == widget.gameId) + 1;
    final activeTitle = center.currentTask?.title ?? '';

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(
          position > 0
              ? '已加入安装队列 · 排队第 $position 位\n正在安装「$activeTitle」，完成后自动开始'
              : '已加入安装队列\n前方任务完成后自动开始',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 14,
              height: 22 / 14,
              color: AppColors.secondaryText)),
      const SizedBox(height: 14),
      Text(
        '可在安装中心查看队列或移除任务',
        style: TextStyle(
            fontSize: 12,
            color: AppColors.secondaryText.withOpacity(0.5)),
      ),
    ]);
  }

  /// 截图加载中的占位图
  Widget _buildScreenshotLoadingPlaceholder() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.placeholderCover,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.border),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '获取截图中...',
                style: TextStyle(
                  fontSize: 14,
                  letterSpacing: 1.5,
                  color: AppColors.border,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // v4.0 重构后本方法无调用点（编译器的 unused_element 已证明）。
  // 按 AGENTS §2.3「删除既有代码须先证明无用并请示」，此处**暂不删除**，
  // 仅加 ignore 抑制噪声；待开发者确认新流程（获取按钮 + 下载浮层）稳定后统一清理。
  // ignore: unused_element
  Widget _buildIdleUI() {
    // 状态大标题（如「等待安装」）已移除：
    // 安装状态由按钮本身与安装中心表达，此处仅保留轻量元信息
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (_linkError) ...[
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
                color: const Color(0xFFFFF0F2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: AppColors.dangerRed.withOpacity(0.35), width: 1.5)),
            child: Text('❌ 获取链接失败',
                style: TextStyle(
                    fontSize: 14,
                    color: AppColors.dangerRed,
                    fontWeight: FontWeight.w500))),
        const SizedBox(height: 20),
        _buildDisabledButton(),
      ] else ...[
        // 轻量元信息行：文件大小 + 安装人数（Wrap 自适应，窄窗口自动换行）
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 18,
          runSpacing: 6,
          children: [
            _buildFileSizeDisplay(),
            if (_gameData != null && _gameData!.installCount > 0)
              _buildInstallCountHint(),
          ],
        ),
        const SizedBox(height: 12),
        // 版本信息（安装按钮上方）：版本名更显眼，版本详情为辅
        if (_hasVersionInfo) ...[
          _buildVersionInfo(),
          const SizedBox(height: 16),
        ],
        DownloadButton(
            onTap: _isSubmitting ? null : () => _handleInstallTap(),
            isDownloading: _isSubmitting),
        // 底部缓冲：避免安装按钮被挤压到软件底部边缘
        const SizedBox(height: 8),
      ],
    ]);
  }

  /// 安装人数小提示（安装按钮上方，轻量不喧宾夺主）
  /// 数据来自 PB games.installCount，仅用于活跃度展示
  Widget _buildInstallCountHint() {
    final count = _gameData?.installCount ?? 0;
    if (count <= 0) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.download_done_outlined,
            size: 13, color: AppColors.secondaryText.withOpacity(0.5)),
        const SizedBox(width: 4),
        Text(
          '${InstallStatsService.formatCount(count)} 人安装',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.secondaryText.withOpacity(0.85),
          ),
        ),
      ],
    );
  }

  // v4.0 重构后本方法无调用点（编译器的 unused_element 已证明）。
  // 按 AGENTS §2.3「删除既有代码须先证明无用并请示」，此处**暂不删除**，
  // 仅加 ignore 抑制噪声；待开发者确认新流程（获取按钮 + 下载浮层）稳定后统一清理。
  // ignore: unused_element
  Widget _buildLocallyInstalledUI() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Opacity(
          opacity: 0.57,
          child: Text('准备就绪',
              style: TextStyle(
                  fontSize: 28,
                  letterSpacing: 4.0,
                  color: AppColors.border))),
      const SizedBox(height: 12),
      Opacity(
          opacity: 0.65,
          child: Text('游戏已成功入库，可在游戏库中查看',
              style: TextStyle(
                  fontSize: 15,
                  height: 24 / 15,
                  color: AppColors.secondaryText))),
      const SizedBox(height: 48),
      DownloadButton(
          onTap: widget.onGoToLibrary ?? widget.onBack,
          variant: ButtonVariant.openLibrary),
    ]);
  }

  // v4.0 重构后本方法无调用点（编译器的 unused_element 已证明）。
  // 按 AGENTS §2.3「删除既有代码须先证明无用并请示」，此处**暂不删除**，
  // 仅加 ignore 抑制噪声；待开发者确认新流程（获取按钮 + 下载浮层）稳定后统一清理。
  // ignore: unused_element
  Widget _buildCurrentInstallingUI() {
    final center = GlobalInstallCenter.instance;
    final phaseText = center.phase == InstallPhase.downloading ? '获取中' : '安装中';

    // 轻量状态行（无大标题）：进度详情由安装中心表达
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('正在$phaseText · 可在安装中心查看进度',
          style: TextStyle(
              fontSize: 14,
              color: AppColors.secondaryText)),
      const SizedBox(height: 14),
      InteractiveWrapper(
        onTap: _handleCancelInstall,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFFE6EA),
            border: Border.all(color: const Color(0xFFD4183D), width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text('取消',
              style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFFD4183D),
                  fontWeight: FontWeight.w600)),
        ),
      ),
      const SizedBox(height: 24),
    ]);
  }

  void _handleCancelInstall() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.buttonBackground,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: BorderSide(color: AppColors.border, width: 2)),
        title: Text('确认取消安装？',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText)),
        content: Text('取消后将删除已获取的文件，是否继续？',
            style: TextStyle(
                fontSize: 15,
                height: 24 / 15,
                color: AppColors.secondaryText)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('继续安装',
                  style: TextStyle(
                      fontSize: 14,
                      color: AppColors.infoBlue,
                      fontWeight: FontWeight.w600))),
          TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                GlobalInstallCenter.instance.cancelCurrentTask();
                AppSnackBar.warning(
                  context,
                  '已取消《${_gameData?.title}》的安装',
                  duration: Duration(seconds: 2),
                );
              },
              child: Text('确认取消',
                  style: TextStyle(
                      fontSize: 14,
                      color: AppColors.dangerRed,
                      fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _buildDisabledButton() {
    return Container(
        constraints: const BoxConstraints(minWidth: 160, maxWidth: 260),
        height: 56,
        decoration: BoxDecoration(
            color: const Color(0xFFEDEDED),
            border: Border.all(color: const Color(0xFFCCCCCC), width: 1.5),
            borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.block,
              size: 20, color: Colors.grey[600]?.withOpacity(0.5)),
          const SizedBox(width: 10),
          Text(_isLocallyInstalled ? '已安装' : '无法安装',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3.0,
                  color: Color(0xFFBDBDBD))),
        ]));
  }
}
