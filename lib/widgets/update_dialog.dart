import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../theme/app_colors.dart';
import '../services/update/update_service.dart';
import '../services/process_cleanup_service.dart';
import 'interactive_wrapper.dart';
import 'custom_title_bar.dart';

OverlayEntry? _updateOverlayEntry;

class UpdateDialog extends StatefulWidget {
  final String currentVersion;
  final String newVersion;
  final String updateLog;
  final String downloadUrl;

  const UpdateDialog({
    super.key,
    required this.currentVersion,
    required this.newVersion,
    required this.updateLog,
    required this.downloadUrl,
  });

  static void show(
    BuildContext context, {
    required String currentVersion,
    required String newVersion,
    required String updateLog,
    required String downloadUrl,
  }) {
    if (_updateOverlayEntry != null) {
      _updateOverlayEntry!.remove();
      _updateOverlayEntry = null;
    }

    final overlay = Overlay.of(context, rootOverlay: true);

    _updateOverlayEntry = OverlayEntry(
      builder: (context) => UpdateDialog(
        currentVersion: currentVersion,
        newVersion: newVersion,
        updateLog: updateLog,
        downloadUrl: downloadUrl,
      ),
    );

    overlay.insert(_updateOverlayEntry!);
  }

  static void dismiss() {
    _updateOverlayEntry?.remove();
    _updateOverlayEntry = null;
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  double _progress = 0;
  bool _downloading = false;
  bool _downloadComplete = false;
  bool _error = false;
  String? _errorMsg;
  String? _savePath;
  CancelToken? _cancelToken;

  Future<void> _startDownload() async {
    setState(() {
      _downloading = true;
      _error = false;
      _errorMsg = null;
      _progress = 0;
      _cancelToken = CancelToken();
    });

    try {
      final path = await UpdateService.instance.downloadUpdate(
        url: widget.downloadUrl,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        cancelToken: _cancelToken,
      );
      if (!mounted) return;

      setState(() {
        _savePath = path;
        _downloading = false;
        _downloadComplete = true;
        _progress = 1.0;
      });
    } catch (e) {
      if (!mounted) return;
      final cancelled = e is DioException && e.type == DioExceptionType.cancel;
      if (cancelled) {
        // 取消下载后回到初始状态（而非直接关闭弹窗），让用户可以重新选择
        // 部分文件清理已由 UpdateService.downloadUpdate 内部完成
        setState(() {
          _downloading = false;
          _progress = 0;
          _cancelToken = null;
        });
        return;
      }
      setState(() {
        _downloading = false;
        _error = true;
        _errorMsg = e.toString();
      });
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('用户取消');
  }

  Future<void> _skipThisVersion() async {
    await UpdateService.instance.skipVersion(widget.newVersion);
    UpdateDialog.dismiss();
  }

  Future<void> _openInstaller() async {
    if (_savePath == null) return;
    try {
      await UpdateService.instance.installUpdate(_savePath!);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('启动安装程序失败: $e')),
      );
      return;
    }
    // 走正常的干净退出流程（显示退出遮罩、清理资源、销毁窗口、退出）
    // 跳过任务检查，因为用户已明确选择安装更新
    // 安装包缓存将在新版本启动时由 cleanupOldInstallerCache() 延迟清理
    // （安装程序运行期间 Windows 文件锁，无法立即删除）
    if (!mounted) return;
    await CustomTitleBar.performCleanExit(context);
  }

  /// 用户选择不立即安装：清理已下载的安装包并关闭弹窗
  Future<void> _cancelInstall() async {
    if (_savePath != null) {
      await UpdateService.instance.cleanupDownloadArtifacts(_savePath!);
      _savePath = null;
    }
    if (!mounted) return;
    UpdateDialog.dismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ModalBarrier(color: Colors.black54, dismissible: false),
        Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 440,
              constraints: BoxConstraints(
                minHeight: 300,
                maxHeight: MediaQuery.of(context).size.height * 0.82,
              ),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border, width: 2),
              ),
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 18),
                  _buildVersionInfo(),
                  if (widget.updateLog.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _buildUpdateLog(),
                  ],
                  const SizedBox(height: 20),
                  if (_downloadComplete)
                    _buildCompleteSection()
                  else if (_downloading)
                    _buildProgressSection()
                  else if (_error)
                    _buildErrorSection()
                  else
                    _buildActionButtons(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Icon(Icons.system_update_alt, size: 26, color: AppColors.border),
        const SizedBox(width: 12),
        Text(
          '发现新版本',
          style: TextStyle(
            fontFamily: 'ZhiMangXing',
            fontSize: 22,
            letterSpacing: 1.5,
            color: AppColors.border,
          ),
        ),
        const Spacer(),
        InteractiveWrapper(
          onTap: _handleCloseButton,
          hoverScale: 1.1,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.borderLight, width: 1.2),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.close, size: 16, color: AppColors.secondaryText),
          ),
        ),
      ],
    );
  }

  Future<void> _handleCloseButton() async {
    if (_downloading) {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border, width: 2),
          ),
          title: Text(
            '正在下载更新',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 22,
              letterSpacing: 1.5,
              color: AppColors.border,
            ),
          ),
          content: Text(
            '更新包正在下载中，关闭窗口将取消下载并删除临时文件，确定要关闭吗？',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              color: AppColors.primaryText,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                '继续下载',
                style: TextStyle(
                  color: AppColors.infoBlue,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                '取消并关闭',
                style: TextStyle(
                  color: AppColors.dangerRed,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      );

      if (result != true) return;

      _cancelDownload();
      // 取消后部分文件由 downloadUpdate 内部清理，直接关闭弹窗
    } else if (_downloadComplete && _savePath != null) {
      // 下载已完成但用户选择不安装：清理已下载的安装包缓存
      await UpdateService.instance.cleanupDownloadArtifacts(_savePath!);
      _savePath = null;
    }

    UpdateDialog.dismiss();
  }

  Widget _buildVersionInfo() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('当前版本 ',
              style: TextStyle(fontSize: 14, color: AppColors.secondaryText)),
          Text(widget.currentVersion,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText)),
          Text('  →  新版本 ',
              style: TextStyle(fontSize: 14, color: AppColors.secondaryText)),
          Text(widget.newVersion,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.selectedAccent)),
        ],
      ),
    );
  }

  Widget _buildUpdateLog() {
    return Flexible(
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: AppColors.borderLight.withOpacity(0.5), width: 1),
        ),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Text(
            widget.updateLog,
            style: TextStyle(
                fontSize: 13, color: AppColors.primaryText, height: 1.6),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildTextButton('稍后提醒', UpdateDialog.dismiss),
            const SizedBox(width: 14),
            _buildTextButton('跳过此版本', _skipThisVersion, isSkip: true),
            const SizedBox(width: 14),
            _buildPrimaryButton('立即更新', _startDownload),
          ],
        ),
      ],
    );
  }

  Widget _buildTextButton(String label, VoidCallback onTap,
      {bool isSkip = false}) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderLight, width: 1.4),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSkip ? AppColors.dangerRed : AppColors.secondaryText,
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryButton(String label, VoidCallback onTap) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: AppColors.selectedAccent,
          border: Border.all(color: AppColors.borderLight, width: 1.6),
          boxShadow: [
            BoxShadow(
                color: AppColors.primaryText.withOpacity(0.25),
                offset: Offset(2, 3),
                blurRadius: 0)
          ],
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSection() {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 10,
            backgroundColor: AppColors.buttonBackground,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
          ),
        ),
        const SizedBox(height: 10),
        Text('${(_progress * 100).toInt()}%',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.border)),
        const SizedBox(height: 12),
        InteractiveWrapper(
          onTap: _cancelDownload,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('取消下载',
                style: TextStyle(fontSize: 13, color: AppColors.dangerRed)),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorSection() {
    return Column(
      children: [
        Icon(Icons.error_outline, size: 36, color: AppColors.dangerRed),
        const SizedBox(height: 8),
        Text('下载失败',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.dangerRed)),
        const SizedBox(height: 6),
        Text(_errorMsg ?? '未知错误',
            style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildTextButton('关闭', UpdateDialog.dismiss),
            const SizedBox(width: 14),
            InteractiveWrapper(
              onTap: _startDownload,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                    color: AppColors.selectedAccent,
                    borderRadius: BorderRadius.circular(8)),
                alignment: Alignment.center,
                child: Text('重试',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCompleteSection() {
    return Column(
      children: [
        Icon(Icons.check_circle, size: 42, color: AppColors.successGreen),
        const SizedBox(height: 10),
        Text('下载完成！',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.successGreen)),
        const SizedBox(height: 6),
        Text('安装包已就绪，是否立即安装？',
            style: TextStyle(fontSize: 13, color: AppColors.secondaryText)),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildTextButton('稍后安装', _cancelInstall),
            const SizedBox(width: 14),
            InteractiveWrapper(
              onTap: _openInstaller,
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 36),
                decoration: BoxDecoration(
                  color: AppColors.successGreen,
                  boxShadow: [
                    BoxShadow(
                        color: AppColors.shadowColor,
                        offset: Offset(2, 3),
                        blurRadius: 0)
                  ],
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.install_desktop, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    Text('立即安装',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
