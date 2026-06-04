import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../models/game_model.dart';
import '../repositories/game_repository.dart';
import '../services/global_install_center.dart';
import '../services/openlist_service.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/install_path_preference.dart';
import '../services/file_size_service.dart';
import '../widgets/download_button.dart';
import '../widgets/install_confirmation_dialog.dart';
import '../core/path_helper.dart';
import '../core/backend_config.dart';
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

  @override
  void initState() {
    super.initState();
    _loadGameData();
    _setupInstallListener();
  }

  void _setupInstallListener() {
    GlobalInstallCenter.instance.addListener(
      phase: (phase) {
        if (!mounted) return;
        if (phase == InstallPhase.completed) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            _checkLocalInstallation();
          });
        } else if (phase == InstallPhase.failed) {
          setState(() {});
        }
      },
      progress: (progress) {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    GlobalInstallCenter.instance
        .removeListener(phase: (_) {}, progress: (_) {});
    super.dispose();
  }

  Future<void> _loadGameData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final game = await GameRepository.getGameById(widget.gameId);
      if (!mounted) return;

      setState(() {
        _gameData = game;
        _isLoading = false;
        _errorMessage = null;
      });

      _checkLocalInstallation();
      _prefetchFileSize();
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
      final gamesDir = Directory(PathHelper.gamesDir);
      if (!await gamesDir.exists()) return;

      await for (final entity in gamesDir.list()) {
        if (entity is Directory) {
          final dirName = entity.path.split('/').last.split('\\').last;
          if (dirName == safeName) {
            final hasCtgame = await GameDataFormat.hasCtgame(entity.path);
            final hasGameJson =
                await File('${entity.path}/${GameDataFormat.gameJsonFileName}')
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
              fontSize: 11.5,
              color: AppColors.secondaryText.withOpacity(0.6),
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
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  Future<void> _handleInstallTap() async {
    if (!BackendConfig.isBackendAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(BackendConfig.unavailableMessage)),
      );
      return;
    }

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
          customGameLocation: customLocation,
        );

        final success = await GlobalInstallCenter.instance.submitTask(task);

        if (!mounted) return;

        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('《${_gameData?.title}》已提交安装'),
              duration: const Duration(seconds: 2),
              backgroundColor: const Color(0xFF4A72A5),
            ),
          );
        } else {
          if (GlobalInstallCenter.instance.isBusy) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('当前有其他游戏正在安装，请等待完成'),
                duration: const Duration(seconds: 3),
                backgroundColor: const Color(0xFFD4A017),
              ),
            );
          }
        }
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
            color:
                _backHovered ? const Color(0xFFF0E6D2) : AppColors.background,
            border: Border.all(
              color: _backHovered ? const Color(0xFF8B7355) : AppColors.border,
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
              color: const Color(0xFF8B7355),
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
                      fontFamily: 'Mali',
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
    return SizedBox(
      width: 460,
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
          color: const Color(0xFFE9E0D1),
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
          color: const Color(0xFFE9E0D1),
          child: Center(
              child: Icon(Icons.image_outlined,
                  size: 48, color: AppColors.secondaryText.withOpacity(0.25))));
    }
    return Stack(fit: StackFit.expand, children: [
      Image.network(coverUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
              color: const Color(0xFFE9E0D1),
              child: Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 40,
                      color: AppColors.secondaryText.withOpacity(0.2))))),
      Container(color: Colors.white.withOpacity(0.38)),
    ]);
  }

  Widget _buildGameInfo() {
    final tags = _gameData?.tags ?? [];
    final developer = _gameData?.developer ?? '';
    return Container(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      height: 147,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_gameData?.title ?? '未知游戏',
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
                            color: AppColors.secondaryText.withOpacity(0.5),
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
                            color: const Color(0xFFE9E0D1), width: 2))),
                child: Text('游 戏 简 介',
                    style: AppStyles.heading.copyWith(fontSize: 20))),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: Text(description,
                    style: TextStyle(
                        fontFamily: 'Mali',
                        fontSize: 17,
                        height: 23 / 17,
                        color: const Color(0xFF6D5B4D),
                        fontWeight: FontWeight.w500)),
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

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isLocallyInstalled)
            _buildLocallyInstalledUI()
          else if (isCurrentGameInstalling)
            _buildCurrentInstallingUI()
          else if (globalBusy)
            _buildGlobalBusyUI()
          else
            _buildIdleUI(),
        ],
      ),
    );
  }

  Widget _buildIdleUI() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('等 待 安 装',
          style: TextStyle(
              fontFamily: 'Zhi Mang Xing',
              fontSize: 30,
              letterSpacing: 2.0,
              color: Color(0xFF8B7355))),
      if (_linkError) ...[
        const SizedBox(height: 16),
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
                color: const Color(0xFFFFF0F2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: const Color(0xFFD4183D).withOpacity(0.35),
                    width: 1.5)),
            child: const Text('❌ 下载链接获取失败',
                style: TextStyle(
                    fontFamily: 'Mali',
                    fontSize: 14,
                    color: Color(0xFFD4A0A8),
                    fontWeight: FontWeight.w500))),
        const SizedBox(height: 24),
        _buildDisabledButton(),
      ] else ...[
        const SizedBox(height: 80),
        _buildFileSizeDisplay(),
        const SizedBox(height: 12),
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
          child: const Text('准 备 就 绪',
              style: TextStyle(
                  fontFamily: 'Zhi Mang Xing',
                  fontSize: 30,
                  letterSpacing: 2.0,
                  color: Color(0xFF8B7355)))),
      const SizedBox(height: 12),
      Opacity(
          opacity: 0.65,
          child: Text('游戏已成功入库，可在游戏库中查看',
              style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 15,
                  height: 24 / 15,
                  color: Color(0xFFA08264)))),
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
      const Text('其 他 任 务 进 行 中',
          style: TextStyle(
              fontFamily: 'Zhi Mang Xing',
              fontSize: 24,
              letterSpacing: 2.0,
              color: Color(0xFF8B7355))),
      const SizedBox(height: 12),
      Opacity(
          opacity: 0.6,
          child: Text('「$activeTitle」正在安装中，请等待完成后再操作',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 14,
                  height: 22 / 14,
                  color: Color(0xFFA08264)))),
      const SizedBox(height: 40),
      _buildDisabledButton(),
    ]);
  }

  Widget _buildCurrentInstallingUI() {
    final center = GlobalInstallCenter.instance;
    final phaseText = center.phase == InstallPhase.downloading ? '下载中' : '安装中';

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('正 在 $phaseText',
          style: TextStyle(
              fontFamily: 'Zhi Mang Xing',
              fontSize: 28,
              letterSpacing: 2.0,
              color: Color(0xFF4A72A5))),
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
        content: Text('取消后将删除已下载的文件，是否继续？',
            style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 15,
                height: 24 / 15,
                color: AppColors.secondaryText)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('继 续 安 装',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: Color(0xFF4A72A5),
                      fontWeight: FontWeight.w600))),
          TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                GlobalInstallCenter.instance.cancelCurrentTask();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('已取消《${_gameData?.title}》的安装'),
                  duration: Duration(seconds: 2),
                  backgroundColor: Color(0xFFD4A017),
                ));
              },
              child: Text('确 认 取 消',
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
        width: 218,
        height: 67,
        decoration: BoxDecoration(
            color: const Color(0xFFEDEDED),
            border: Border.all(color: const Color(0xFFCCCCCC), width: 1.5)),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.block, size: 20, color: const Color(0xFF999999)),
          const SizedBox(width: 12),
          Text(_isLocallyInstalled ? '已 安 装' : '无 法 安 装',
              style: AppStyles.heading.copyWith(
                  fontSize: 24,
                  letterSpacing: 2.0,
                  color: const Color(0xFF999999))),
        ]));
  }
}
