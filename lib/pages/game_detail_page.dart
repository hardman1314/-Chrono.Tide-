import 'dart:async';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../theme/app_breakpoints.dart';
import '../models/game_model.dart';
import '../repositories/game_repository.dart';
import '../services/global_install_center.dart';
import '../services/openlist_service.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/metadata_fetcher.dart';
import '../services/discover_metadata_service.dart';
import '../services/install_path_preference.dart';
import '../services/file_size_service.dart';
import '../widgets/download_button.dart';
import '../widgets/install_confirmation_dialog.dart';
import '../widgets/screenshot_carousel.dart';
import '../core/path_helper.dart';
import '../core/pb_config.dart';
import '../widgets/interactive_wrapper.dart';

class GameDetailPage extends StatefulWidget {
  final String gameId;
  final VoidCallback onBack;
  final VoidCallback? onGoToLibrary;

  const GameDetailPage({
    super.key,
    required this.gameId,
    required this.onBack,
    this.onGoToLibrary,
  });

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
    // 监听元数据服务变化（抓取完成后刷新详情页元数据行）
    DiscoverMetadataService.instance.addListener(_onMetadataChanged);
  }

  void _setupInstallListener() {
    _phaseListener = (phase) {
      if (!mounted) return;
      switch (phase) {
        case InstallPhase.completed:
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
  }

  @override
  void dispose() {
    GlobalInstallCenter.instance.removeListener(
      phase: _phaseListener!,
      progress: _progressListener!,
    );
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

      // 阶段3.4：触发元数据懒加载（同步读取缓存，后台抓取）
      // 与截图加载并行，不阻塞 UI；抓取完成通过 _onMetadataChanged 刷新
      _metadata = DiscoverMetadataService.instance.getMetadata(game.id);
      if (_metadata == null) {
        DiscoverMetadataService.instance.ensureMetadata(game.id, game.title);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _checkLocalInstallation() async {
    if (_gameData == null || _gameData!.title == null) return;

    await LocalGameRegistry.instance.refreshStaleEntries();

    final title = _gameData!.title!;
    if (LocalGameRegistry.instance.isTitleInstalled(title)) {
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
              if (LocalGameRegistry.instance.isTitleInstalled(title)) {
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

  /// 并行加载截图（三级优先级）
  /// Priority 1: PocketBase 截图数据 → 直接使用，最快
  /// Priority 2: 本地已安装游戏的截图文件
  /// Priority 3: 元数据API抓取 → 抓取成功后回传到PB供其他用户使用
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

    // 同时发起：本地安装检查 + 元数据API请求
    final localCheckFuture = _checkLocalInstallation();
    final apiFetchFuture = MetadataFetcher.fetchGame(title);

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

    // ====== Priority 3: 元数据API抓取 ======
    try {
      final results = await apiFetchFuture;
      if (!mounted) return;

      if (results.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoadingScreenshots = false;
            _screenshotFetchFailed = true;
          });
        }
        return;
      }

      for (final result in results) {
        final urls = (result['screenshot_urls'] as List?)
                ?.map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList() ??
            [];
        if (urls.isNotEmpty) {
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
          return;
        }
      }
      // 所有结果都没有截图
      if (mounted) {
        setState(() {
          _isLoadingScreenshots = false;
          _screenshotFetchFailed = true;
        });
      }
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
              fontFamily: 'Inter',
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
              fontFamily: 'Inter',
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

  Future<void> _handleInstallTap() async {
    final gamePath = _gameData?.downloadUrl ?? '';
    if (gamePath.isEmpty) {
      setState(() => _linkError = true);
      return;
    }

    final result = await InstallConfirmationDialog.show(
      context: context,
      gameTitle: _gameData?.title ?? widget.gameId,
      gameCoverUrl: _gameData?.coverUrl,
      gameDescription: _gameData?.description,
      gameTags: _gameData?.tags,
    );

    if (result != InstallConfirmationResult.confirmed) {
      return;
    }

    String? customLocation =
        await InstallPathPreference.instance.getLastUsedLocation();

    if (customLocation == null || customLocation.isEmpty) {
      customLocation =
          await InstallPathPreference.instance.getDefaultGameLocation();
    }

    setState(() {
      _linkError = false;
      _isSubmitting = true;
    });

    try {
      debugPrint('[DETAIL] 获取下载链接...');
      final proxyUrl = await OpenListService.getGameDownloadUrl(gamePath);

      if (!mounted) return;

      if (proxyUrl != null) {
        debugPrint('[DETAIL] ✅ 链接获取成功，推送至安装中心');

        final task = InstallTask(
          gameId: widget.gameId,
          title: _gameData?.title ?? widget.gameId,
          description: _gameData?.description,
          coverUrl: _gameData?.coverUrl,
          tags: _gameData?.tags,
          downloadUrl: proxyUrl,
          developer: _gameData?.developer,
          customGameLocation: customLocation,
          screenshotUrls: _screenshotUrls.isNotEmpty ? _screenshotUrls : null,
        );

        // 关键修复:改为 fire-and-forget 模式,不 await 整个 install 流程
        // 旧实现 await submitTask 会等 download + extract + completed 全部跑完
        // 期间 _isSubmitting=true 阻塞 UI,叠加 listener 泄漏导致"白屏卡死"
        // 现在:立即恢复 UI 交互,进度显示交给 FloatingTaskButton
        unawaited(GlobalInstallCenter.instance.submitTask(task).then((success) {
          if (!mounted) return;
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('《${_gameData?.title}》已提交安装'),
                duration: const Duration(seconds: 2),
                backgroundColor: AppColors.infoBlue,
              ),
            );
          } else {
            if (GlobalInstallCenter.instance.isBusy) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('当前有其他游戏正在安装，请等待完成'),
                  duration: const Duration(seconds: 3),
                  backgroundColor: AppColors.starGold,
                ),
              );
            }
          }
        }));
      } else {
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
                  fontFamily: 'Inter',
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

    return Stack(
      children: [
        Container(
          width: double.infinity,
          height: double.infinity,
          color: AppColors.background,
          padding: const EdgeInsets.all(32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLeftSection(),
              const SizedBox(width: 32),
              Expanded(child: _buildRightSection()),
            ],
          ),
        ),
        Positioned(
          left: 16,
          top: 16,
          child: _buildBackButton(),
        ),
      ],
    );
  }

  Widget _buildBackButton() {
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
                  fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
    // UX-07: 左侧宽度随窗口尺寸自适应，避免窄窗口下右侧内容被挤压溢出
    final sizeClass = AppBreakpoints.of(context);
    final leftWidth = switch (sizeClass) {
      WindowSizeClass.compact => 380.0,
      WindowSizeClass.medium => 420.0,
      WindowSizeClass.expanded => 460.0,
      WindowSizeClass.large => 480.0,
    };
    return SizedBox(
      width: leftWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildGameCover(),
              const SizedBox(width: 29),
              Expanded(child: _buildGameInfo()),
            ],
          ),
          const SizedBox(height: 24),
          _buildDescription(),
        ],
      ),
    );
  }

  Widget _buildGameCover() {
    return Transform.rotate(
      angle: -2 * 3.14159 / 180,
      child: Container(
        width: 216,
        height: 323,
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
      CachedNetworkImage(
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
      Container(color: Colors.white.withOpacity(0.38)),
    ]);
  }

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
      height: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_gameData?.title ?? '未知游戏',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.titleLarge
                  .copyWith(fontSize: 36, letterSpacing: 2.0)),
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
          Expanded(
            child: tags.isNotEmpty
                ? Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: tags.map((tag) => _buildTag(tag)).toList())
                : Center(
                    child: Text('暂无标签',
                        style: AppStyles.bodyRegular.copyWith(
                            fontSize: 13,
                            color: AppColors.secondaryText.withOpacity(0.7),
                            fontStyle: FontStyle.italic))),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String tag) {
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            border: Border.all(color: AppColors.border, width: 2)),
        child: Text(tag, style: AppStyles.bodyRegular.copyWith(fontSize: 14)));
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
      constraints: const BoxConstraints(maxHeight: 280),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      decoration: BoxDecoration(
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
                margin: const EdgeInsets.only(right: 282),
                padding: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color: AppColors.placeholderCover, width: 2))),
                child: Text('游 戏 简 介',
                    style: AppStyles.heading.copyWith(fontSize: 20))),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: Text(description,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 17,
                      height: 23 / 17,
                      color: AppColors.primaryText,
                    )),
              ),
            ),
          ]),
    );
  }

  Widget _buildRightSection() {
    final center = GlobalInstallCenter.instance;
    final globalBusy =
        center.isBusy && center.currentTask?.gameId != widget.gameId;
    final isCurrentGameInstalling =
        center.isBusy && center.currentTask?.gameId == widget.gameId;

    final hasScreenshots =
        _screenshotUrls.isNotEmpty || _localScreenshots.isNotEmpty;

    // 决定截图展示区内容
    Widget screenshotArea;
    if (_isLoadingScreenshots) {
      // 阶段1：截图URL获取中，显示加载占位
      screenshotArea = _buildScreenshotLoadingPlaceholder();
    } else if (_screenshotFetchFailed && !hasScreenshots) {
      // 阶段2：获取失败且无截图，显示暂无截图（由ScreenshotCarousel空状态处理）
      // 传入 gameTitle 以便感知本地截图后台下载状态
      screenshotArea = ScreenshotCarousel(
        paths: const [],
        gameTitle: _gameData?.title,
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
        // 截图展示区域
        const SizedBox(height: 24),
        screenshotArea,
        if (hasScreenshots) const Spacer(),
        // 安装按钮区域
        if (_isLocallyInstalled)
          _buildLocallyInstalledUI()
        else if (isCurrentGameInstalling)
          _buildCurrentInstallingUI()
        else if (globalBusy)
          _buildGlobalBusyUI()
        else
          _buildIdleUI(),
      ],
    );
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
                  fontFamily: 'ZhiMangXing',
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

  Widget _buildIdleUI() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('等待安装',
          style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 28,
              letterSpacing: 4.0,
              color: AppColors.border)),
      if (_linkError) ...[
        const SizedBox(height: 16),
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
                color: const Color(0xFFFFF0F2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: AppColors.dangerRed.withOpacity(0.35), width: 1.5)),
            child: Text('❌ 获取链接失败',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.dangerRed,
                    fontWeight: FontWeight.w500))),
        const SizedBox(height: 24),
        _buildDisabledButton(),
      ] else ...[
        const SizedBox(height: 48),
        _buildFileSizeDisplay(),
        const SizedBox(height: 16),
        DownloadButton(
            onTap: _isSubmitting ? null : () => _handleInstallTap(),
            isDownloading: _isSubmitting),
      ],
    ]);
  }

  Widget _buildLocallyInstalledUI() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Opacity(
          opacity: 0.57,
          child: Text('准备就绪',
              style: TextStyle(
                  fontFamily: 'ZhiMangXing',
                  fontSize: 28,
                  letterSpacing: 4.0,
                  color: AppColors.border))),
      const SizedBox(height: 12),
      Opacity(
          opacity: 0.65,
          child: Text('游戏已成功入库，可在游戏库中查看',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  height: 24 / 15,
                  color: AppColors.secondaryText))),
      const SizedBox(height: 48),
      DownloadButton(
          onTap: widget.onGoToLibrary ?? widget.onBack,
          variant: ButtonVariant.openLibrary),
    ]);
  }

  Widget _buildGlobalBusyUI() {
    final center = GlobalInstallCenter.instance;
    final activeTitle = center.currentTask?.title ?? '未知游戏';

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('其他任务进行中',
          style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 24,
              letterSpacing: 3.0,
              color: AppColors.border)),
      const SizedBox(height: 12),
      Opacity(
          opacity: 0.6,
          child: Text('「$activeTitle」正在安装中，请等待完成后再操作',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  height: 22 / 14,
                  color: AppColors.secondaryText))),
      const SizedBox(height: 40),
      _buildDisabledButton(),
    ]);
  }

  Widget _buildCurrentInstallingUI() {
    final center = GlobalInstallCenter.instance;
    final phaseText = center.phase == InstallPhase.downloading ? '获取中' : '安装中';

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('正在$phaseText',
          style: const TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 28,
              letterSpacing: 3.0,
              color: Color(0xFF4A72A5))),
      const SizedBox(height: 24),
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
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: Color(0xFFD4183D),
                  fontWeight: FontWeight.w600)),
        ),
      ),
      const SizedBox(height: 60),
    ]);
  }

  void _handleCancelInstall() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.buttonBackground,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: AppColors.border, width: 2)),
        title: Text('确认取消安装？',
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText)),
        content: Text('取消后将删除已获取的文件，是否继续？',
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                height: 24 / 15,
                color: AppColors.secondaryText)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('继续安装',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: AppColors.infoBlue,
                      fontWeight: FontWeight.w600))),
          TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                GlobalInstallCenter.instance.cancelCurrentTask();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('已取消《${_gameData?.title}》的安装'),
                  duration: Duration(seconds: 2),
                  backgroundColor: AppColors.starGold,
                ));
              },
              child: Text('确认取消',
                  style: TextStyle(
                      fontFamily: 'Inter',
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
                  fontFamily: 'Inter',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3.0,
                  color: Color(0xFFBDBDBD))),
        ]));
  }
}
