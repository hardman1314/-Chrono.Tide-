import 'package:flutter/material.dart';

import '../../services/openlist_provision.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../interactive_wrapper.dart';

enum OpenListPairResult { paired, cancelled }

/// 服务对接窗口（半移植化 2026-10-02；文案 v2：对用户不提 OpenList，
/// 统一称「服务」）。
///
/// 两个入口共用：用户窗口「对接 / 更新对接」胶囊按钮 + 官方下载前置拦截
/// （CloudInstallFlow.submit → 未对接时弹出）。
///
/// 状态机：intro（说明+确认）→ working（进度条）→ done / error（重试）。
/// [isUpdate] = 已对接后的更新语义：标题/文案改为「更新服务」。
class OpenListPairDialog extends StatefulWidget {
  final bool isUpdate;

  const OpenListPairDialog({super.key, this.isUpdate = false});

  /// 弹出对接窗口。返回 [OpenListPairResult.paired] = 对接成功。
  static Future<OpenListPairResult> show(BuildContext context,
      {bool isUpdate = false}) async {
    final result = await showDialog<OpenListPairResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OpenListPairDialog(isUpdate: isUpdate),
    );
    return result ?? OpenListPairResult.cancelled;
  }

  @override
  State<OpenListPairDialog> createState() => _OpenListPairDialogState();
}

enum _PairPhase { intro, working, done, error }

class _OpenListPairDialogState extends State<OpenListPairDialog> {
  _PairPhase _phase = _PairPhase.intro;
  double _progress = 0;
  String _stage = '';
  String? _error;

  Future<void> _startPair() async {
    setState(() {
      _phase = _PairPhase.working;
      _progress = 0;
      _stage = '下载中…';
      _error = null;
    });

    final err = await OpenListProvision.pair(
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
      onStage: (s) {
        if (mounted) setState(() => _stage = s);
      },
    );

    if (!mounted) return;

    if (err == null) {
      setState(() => _phase = _PairPhase.done);
    } else {
      setState(() {
        _phase = _PairPhase.error;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final closable = _phase != _PairPhase.working;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 470,
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 1.6),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(26, 20, 26, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(closable),
              const SizedBox(height: 18),
              switch (_phase) {
                _PairPhase.intro => _buildIntro(),
                _PairPhase.working => _buildWorking(),
                _PairPhase.done => _buildDone(),
                _PairPhase.error => _buildError(),
              },
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool closable) {
    return Row(
      children: [
        Text(
          widget.isUpdate ? '更新服务' : '对接服务',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.primaryText,
          ),
        ),
        const Spacer(),
        if (closable)
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(OpenListPairResult.cancelled),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, size: 18, color: AppColors.secondaryText),
            ),
          ),
      ],
    );
  }

  Widget _buildIntro() {
    // 双态文案：首次对接 = 功能引导；更新对接 = 修复/升级语义
    final body = widget.isUpdate
        ? '将重新从官方服务器下载服务整合包（约 53MB）并覆盖安装，'
            '可用于修复或更新本地服务组件。下载采用多连接加速，'
            '期间会短暂占用网络。'
        : '官方下载功能依赖一个本地服务组件。当前程序未包含该组件，'
            '确认对接后将自动从官方服务器下载整合包（约 53MB）并完成配置，'
            '下载采用多连接加速，全程无需其他操作。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          body,
          style: TextStyle(fontSize: 13.5, height: 1.55, color: AppColors.primaryText),
        ),
        const SizedBox(height: 10),
        Text(
          '来源：Chrono Tide 官方服务器 · 重复对接可修复组件',
          style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: _pairButton(
                label: widget.isUpdate ? '开始更新' : '确认对接',
                base: AppColors.selectedAccent,
                onTap: _startPair,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _pairButton(
                label: widget.isUpdate ? '暂不更新' : '暂不对接',
                base: AppColors.background,
                foreground: AppColors.secondaryText,
                onTap: () =>
                    Navigator.of(context).pop(OpenListPairResult.cancelled),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWorking() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _stage,
          style: TextStyle(fontSize: 13.5, color: AppColors.primaryText),
        ),
        const SizedBox(height: 14),
        // 自绘硬边进度条（贴应用像素风；indeterminate 阶段用动画条）
        ClipRect(
          child: Container(
            height: 10,
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1),
            ),
            child: _progress > 0
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: _progress.clamp(0.02, 1.0),
                      child: Container(color: AppColors.infoBlue),
                    ),
                  )
                : const LinearProgressIndicator(minHeight: 8),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _progress > 0 ? '${(_progress * 100).toStringAsFixed(0)}%' : '',
          style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
        ),
        const SizedBox(height: 8),
        Text(
          '对接期间请保持网络连接，不要关闭窗口。',
          style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
        ),
      ],
    );
  }

  Widget _buildDone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_outline, size: 20, color: AppColors.successGreen),
            const SizedBox(width: 8),
            Text(
              widget.isUpdate ? '更新完成' : '对接完成',
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          widget.isUpdate
              ? '服务组件已更新至最新版本。如需取消对接，可手动删除程序'
                  '目录下 runtime/openlist 文件夹。'
              : '官方下载功能已激活。如需取消对接，可手动删除程序目录下'
                  ' runtime/openlist 文件夹。',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.secondaryText),
        ),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            child: _pairButton(
              label: '完成',
              base: AppColors.selectedAccent,
              onTap: () => Navigator.of(context).pop(OpenListPairResult.paired),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, size: 20, color: AppColors.dangerRed),
            const SizedBox(width: 8),
            Text(
              widget.isUpdate ? '更新失败' : '对接失败',
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _error ?? '未知错误',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.secondaryText),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: _pairButton(
                label: '重试',
                base: AppColors.selectedAccent,
                onTap: _startPair,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _pairButton(
                label: '关闭',
                base: AppColors.background,
                foreground: AppColors.secondaryText,
                onTap: () =>
                    Navigator.of(context).pop(OpenListPairResult.cancelled),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _pairButton({
    required String label,
    required Color base,
    Color? foreground,
    required VoidCallback onTap,
  }) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: base,
          border: Border.all(color: AppColors.border, width: 1.2),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: foreground ?? AppColors.primaryText,
          ),
        ),
      ),
    );
  }
}
