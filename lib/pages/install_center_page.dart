import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/global_install_center.dart';
import '../widgets/download_button.dart';
import '../widgets/download_progress_bar.dart';
import '../widgets/interactive_wrapper.dart';

class InstallCenterPage extends StatefulWidget {
  final VoidCallback onClose;

  const InstallCenterPage({super.key, required this.onClose});

  @override
  State<InstallCenterPage> createState() => _InstallCenterPageState();
}

class _InstallCenterPageState extends State<InstallCenterPage> {
  InstallPhase _phase = InstallPhase.idle;
  InstallProgress _progress = const InstallProgress();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _syncFromGlobal();
    GlobalInstallCenter.instance
        .addListener(phase: _onPhaseChanged, progress: _onProgressChanged);
  }

  @override
  void dispose() {
    GlobalInstallCenter.instance.removeListener(
      phase: _onPhaseChanged,
      progress: _onProgressChanged,
    );
    super.dispose();
  }

  void _syncFromGlobal() {
    final center = GlobalInstallCenter.instance;
    setState(() {
      _phase = center.phase;
      _progress = center.progress;
      _errorMessage = center.errorMessage;
    });
  }

  void _onPhaseChanged(InstallPhase newPhase) {
    if (!mounted) return;
    setState(() {
      _phase = newPhase;
      _errorMessage = GlobalInstallCenter.instance.errorMessage;
    });
  }

  void _onProgressChanged(InstallProgress newProgress) {
    if (!mounted) return;
    setState(() {
      _progress = newProgress;
    });
  }

  @override
  Widget build(BuildContext context) {
    final task = GlobalInstallCenter.instance.currentTask;

    return Material(
      color: Colors.black54,
      child: Center(
        child: Container(
          width: 900,
          height: 580,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 1.6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                offset: const Offset(4, 8),
                blurRadius: 24,
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildContent()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border(
          bottom: BorderSide(color: AppColors.borderLight, width: 0.8),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                Icons.download_rounded,
                size: 22,
                color: AppColors.border,
              ),
              const SizedBox(width: 10),
              Text(
                '全局安装中心',
                style: AppStyles.titleLarge.copyWith(
                  fontSize: 18,
                  letterSpacing: 1.5,
                ),
              ),
              if (_phase != InstallPhase.idle &&
                  _phase != InstallPhase.completed &&
                  _phase != InstallPhase.failed) ...[
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _phase == InstallPhase.downloading
                        ? const Color(0xFF4A72A5).withOpacity(0.12)
                        : const Color(0xFFD4A017).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _phase == InstallPhase.downloading ? '下载中' : '解压中',
                    style: TextStyle(
                      fontFamily: 'Mali',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _phase == InstallPhase.downloading
                          ? const Color(0xFF4A72A5)
                          : const Color(0xFFD4A017),
                    ),
                  ),
                ),
              ],
            ],
          ),
          InteractiveWrapper(
            onTap: widget.onClose,
            hoverScale: 1.1,
            child: Container(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final task = GlobalInstallCenter.instance.currentTask;

    if (task == null || _phase == InstallPhase.idle) {
      return _buildIdleView();
    }

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLeftSection(task),
          const SizedBox(width: 40),
          Expanded(child: _buildRightSection()),
        ],
      ),
    );
  }

  Widget _buildIdleView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 64,
            color: AppColors.secondaryText.withOpacity(0.2),
          ),
          const SizedBox(height: 16),
          Text(
            '当前无安装任务',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 16,
              color: AppColors.secondaryText.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '前往探索页点击游戏详情中的"安装"按钮开始',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 13,
              color: AppColors.secondaryText.withOpacity(0.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftSection(InstallTask task) {
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
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
                    blurRadius: 0,
                  ),
                ],
              ),
              clipBehavior: Clip.hardEdge,
              child: Stack(
                fit: StackFit.expand,
                children: [_buildCoverImage(task.coverUrl)],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            task.title,
            textAlign: TextAlign.center,
            style: AppStyles.titleLarge.copyWith(fontSize: 24),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.tags != null && task.tags!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: task.tags!
                  .take(3)
                  .map((tag) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.buttonBackground,
                          border: Border.all(color: AppColors.border, width: 1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          tag,
                          style: AppStyles.bodyRegular.copyWith(fontSize: 11),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoverImage(String? coverUrl) {
    if (coverUrl == null || coverUrl.isEmpty || !coverUrl.startsWith('http')) {
      return Container(
        color: const Color(0xFFE9E0D1),
        child: Center(
          child: Icon(
            Icons.image_outlined,
            size: 48,
            color: AppColors.secondaryText.withOpacity(0.25),
          ),
        ),
      );
    }

    return Image.network(
      coverUrl,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: const Color(0xFFE9E0D1),
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: 40,
            color: AppColors.secondaryText.withOpacity(0.2),
          ),
        ),
      ),
    );
  }

  Widget _buildRightSection() {
    switch (_phase) {
      case InstallPhase.idle:
        return const SizedBox.shrink();

      case InstallPhase.downloading:
        return _buildDownloadingUI();

      case InstallPhase.extracting:
        return _buildExtractingUI();

      case InstallPhase.completed:
        return _buildCompletedUI();

      case InstallPhase.failed:
        return _buildFailedUI();

      case InstallPhase.cancelled:
        return _buildCancelledUI();
    }
  }

  Widget _buildDownloadingUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: 0.77,
            child: Text(
              '正 在 下 载',
              style: TextStyle(
                fontFamily: 'ZhiMangXing',
                fontSize: 30,
                letterSpacing: 2.0,
                color: const Color(0xFF8B7355),
              ),
            ),
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: 465,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Opacity(
                      opacity: 0.8,
                      child: Text(
                        '下载速度: ${_progress.downloadSpeed}',
                        style: const TextStyle(
                          fontFamily: 'Mali',
                          fontSize: 16,
                          height: 24 / 16,
                          color: Color(0xFF5C4A3D),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${_progress.downloadPercent.toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontFamily: 'Mali',
                        fontSize: 24,
                        height: 32 / 24,
                        letterSpacing: 1.2,
                        color: Color(0xFF5C4A3D),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DownloadProgressBar(
                  progress: _progress.downloadPercent / 100,
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
          DownloadButton(
            onTap: () => GlobalInstallCenter.instance.cancelCurrentTask(),
            isDownloading: true,
          ),
        ],
      ),
    );
  }

  Widget _buildExtractingUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: 0.77,
            child: Text(
              '正 在 解 压',
              style: TextStyle(
                fontFamily: 'ZhiMangXing',
                fontSize: 30,
                letterSpacing: 2.0,
                color: const Color(0xFF8B7355),
              ),
            ),
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: 465,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        _progress.statusMessage.isNotEmpty
                            ? _progress.statusMessage
                            : '正在解压...',
                        style: const TextStyle(
                          fontFamily: 'Mali',
                          fontSize: 16,
                          height: 24 / 16,
                          color: Color(0xFF5C4A3D),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${_progress.extractPercent.toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontFamily: 'Mali',
                        fontSize: 24,
                        height: 32 / 24,
                        letterSpacing: 1.2,
                        color: Color(0xFF5C4A3D),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DownloadProgressBar(progress: 1.0),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  minHeight: 6,
                  value: _progress.extractPercent / 100,
                  backgroundColor: AppColors.buttonBackground,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Color(0xFFD4A017)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.check_rounded,
              size: 42,
              color: const Color(0xFF4CAF50),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '安 装 完 成',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 32,
              letterSpacing: 2.5,
              color: const Color(0xFF4CAF50),
            ),
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: 0.65,
            child: Text(
              '游戏已成功入库，可在库中查看并启动',
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 15,
                height: 24 / 15,
                color: const Color(0xFFA08264),
              ),
            ),
          ),
          const SizedBox(height: 36),
          DownloadButton(
            onTap: widget.onClose,
            variant: ButtonVariant.openLibrary,
          ),
        ],
      ),
    );
  }

  Widget _buildFailedUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0F0),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.error_rounded,
              size: 42,
              color: AppColors.dangerRed,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '安 装 失 败',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 32,
              letterSpacing: 2.5,
              color: AppColors.dangerRed,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            constraints: const BoxConstraints(maxWidth: 450),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0F2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.dangerRed.withOpacity(0.35),
                width: 1.5,
              ),
            ),
            child: Text(
              _errorMessage ?? '操作过程中发生异常，请稍后重试',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 14,
                height: 22 / 14,
                color: const Color(0xFFD4A0A8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 28),
          DownloadButton(
            onTap: widget.onClose,
            variant: ButtonVariant.retry,
          ),
          const SizedBox(width: 16),
          InteractiveWrapper(
            onTap: widget.onClose,
            hoverScale: 1.0,
            hoverOffset: const Offset(0, -1),
            child: Text(
              '关闭',
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 15,
                color: AppColors.secondaryText,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.secondaryText.withOpacity(0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelledUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已 取 消',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 30,
              letterSpacing: 2.0,
              color: const Color(0xFF8B7355),
            ),
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: 0.6,
            child: Text(
              '已清理临时缓存文件，任务已终止',
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 14,
                height: 22 / 14,
                color: const Color(0xFFA08264),
              ),
            ),
          ),
          const SizedBox(height: 32),
          DownloadButton(onTap: widget.onClose),
        ],
      ),
    );
  }
}
