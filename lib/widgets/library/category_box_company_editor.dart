import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/company_logo_service.dart';
import '../../services/company_wall_store.dart';
import '../../theme/app_colors.dart';
import '../app_dialog.dart';
import '../app_snack_bar.dart';

/// 「编辑会社信息」弹窗（会社卡片右上角入口）。
///
/// 能力：
/// - **上传图标**：本地选图 → 复制到 [CompanyWallStore.logoDir] 并记录；
/// - **自动抓取**：调 [CompanyLogoService] 从 NextMoe 会社目录取 logo 落盘；
/// - **移除图标**：删文件 + 清记录（回退文字字标）；
/// - **改会社名**：写入显示名覆盖。
///
/// ⚠️ **改会社名只改变显示名称** —— 会社键、company_id、成员计数、筛选行为
/// 全部不变（弹窗内置醒目提示，向用户说明这点）。
///
/// 一切写入直接落在 [CompanyWallStore]（ChangeNotifier）——库页监听其 revision
/// 自动刷新，弹窗无需回传结果。返回 `true` 表示发生过任何变更。
class CompanyEditorDialog extends StatefulWidget {
  const CompanyEditorDialog({
    super.key,
    required this.companyKey,
    required this.originalName,
    required this.currentDisplayName,
    required this.currentLogoPath,
    this.vndbId,
    this.nameCandidates = const [],
    this.isCustom = false,
  });

  /// 会社键（词典会社 = `"<company_id>"`，自定义会社 = 自定义 id）。
  final String companyKey;

  /// 词典标准名（输入框 hint 用）。
  final String originalName;

  /// 当前展示名（含用户覆盖）。
  final String currentDisplayName;

  /// 当前图标绝对路径（无则 null）。
  final String? currentLogoPath;

  /// VNDB producer id（如 `p98`；自定义会社通常为 null）。
  final String? vndbId;

  /// 抓取时依次尝试的名字。
  final List<String> nameCandidates;
  final bool isCustom;

  static Future<bool?> show(
    BuildContext context, {
    required String companyKey,
    required String originalName,
    required String currentDisplayName,
    required String? currentLogoPath,
    String? vndbId,
    List<String> nameCandidates = const [],
    bool isCustom = false,
  }) {
    return showAppDialog<bool>(
      context: context,
      builder: (_) => CompanyEditorDialog(
        companyKey: companyKey,
        originalName: originalName,
        currentDisplayName: currentDisplayName,
        currentLogoPath: currentLogoPath,
        vndbId: vndbId,
        nameCandidates: nameCandidates,
        isCustom: isCustom,
      ),
    );
  }

  @override
  State<CompanyEditorDialog> createState() => _CompanyEditorDialogState();
}

class _CompanyEditorDialogState extends State<CompanyEditorDialog> {
  late final TextEditingController _nameController;
  String? _logoPath;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentDisplayName);
    _logoPath = widget.currentLogoPath;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _uploadLogo() async {
    if (_busy) return;
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
      );
    } catch (e) {
      if (mounted) AppSnackBar.warning(context, '选择文件失败：$e');
      return;
    }
    final src = res?.files.isNotEmpty == true ? res!.files.first.path : null;
    if (src == null) return;

    setState(() => _busy = true);
    try {
      final ext = _extOfPath(src);
      final fileName =
          '${CompanyLogoService.fileNameKey(widget.companyKey)}.$ext';
      final dir = Directory(CompanyWallStore.logoDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final dest =
          '${CompanyWallStore.logoDir}${Platform.pathSeparator}$fileName';
      await File(src).copy(dest);
      await CompanyWallStore.instance.setLogo(widget.companyKey, fileName);
      if (!mounted) return;
      setState(() => _logoPath = dest);
      AppSnackBar.success(context, '已更新会社图标');
    } catch (e) {
      if (mounted) AppSnackBar.warning(context, '导入图标失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchLogo() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await CompanyLogoService.instance.fetchAndStore(
        companyKey: widget.companyKey,
        vndbId: widget.vndbId,
        nameCandidates: widget.nameCandidates,
      );
      if (!mounted) return;
      if (result.isOk && result.fileName != null) {
        await CompanyWallStore.instance.setLogo(widget.companyKey, result.fileName);
        if (!mounted) return;
        setState(() => _logoPath =
            CompanyWallStore.instance.logoPathOf(widget.companyKey));
        AppSnackBar.success(context, '已抓取会社图标');
      } else {
        AppSnackBar.warning(context, _fetchFailText(result.status));
      }
    } catch (e) {
      if (mounted) AppSnackBar.warning(context, '抓取失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeLogo() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await CompanyWallStore.instance.clearLogo(widget.companyKey);
      if (!mounted) return;
      setState(() => _logoPath = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final original = widget.originalName.trim();
    // 与原展示名不同才写覆盖；等于标准名 = 清除覆盖（回退词典展示）
    await CompanyWallStore.instance.setDisplayName(
      widget.companyKey,
      (name.isEmpty || name == original) ? null : name,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  static String _fetchFailText(CompanyLogoFetchStatus s) {
    switch (s) {
      case CompanyLogoFetchStatus.noMatch:
        return '平台上没有匹配到这家会社的图标';
      case CompanyLogoFetchStatus.noLogo:
        return '平台收录了这家会社，但没有图标';
      case CompanyLogoFetchStatus.downloadFailed:
        return '图标下载失败，请检查网络';
      case CompanyLogoFetchStatus.networkError:
        return '网络异常，抓取失败';
      case CompanyLogoFetchStatus.ok:
        return '已抓取会社图标';
    }
  }

  static String _extOfPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot > 0) {
      final ext = path.substring(dot + 1).toLowerCase();
      if (const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'].contains(ext)) {
        return ext == 'jpeg' ? 'jpg' : ext;
      }
    }
    return 'png';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadowColor.withOpacity(0.18),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '编辑会社信息',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '改名只改变显示名称，会社身份与筛选功能不变。',
                style: TextStyle(
                    fontSize: 11, color: AppColors.placeholderText),
              ),
              const SizedBox(height: 16),

              // 图标区：预览 + 操作
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildLogoPreview(),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _actionButton('上传图标', Icons.upload_outlined,
                            _busy ? null : _uploadLogo),
                        const SizedBox(height: 8),
                        _actionButton('自动抓取', Icons.cloud_download_outlined,
                            _busy ? null : _fetchLogo),
                        if (_logoPath != null) ...[
                          const SizedBox(height: 8),
                          _actionButton('移除图标', Icons.delete_outline,
                              _busy ? null : _removeLogo),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // 会社名
              Text(
                '会社名称',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _nameController,
                autofocus: true,
                enabled: !_busy,
                style: TextStyle(fontSize: 14, color: AppColors.primaryText),
                cursorColor: AppColors.selectedAccent,
                decoration: InputDecoration(
                  hintText: widget.originalName,
                  hintStyle: TextStyle(
                      fontSize: 13, color: AppColors.placeholderText),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.selectedAccent, width: 1.5),
                  ),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 6),
              Text(
                '留空或填回原名即恢复默认显示。',
                style: TextStyle(
                    fontSize: 10.5, color: AppColors.placeholderText),
              ),
              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _actionButton('取消', Icons.close, () {
                    Navigator.of(context).pop(false);
                  }, compact: true),
                  const SizedBox(width: 10),
                  _primaryButton('完成', _busy ? null : _save),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogoPreview() {
    final path = _logoPath;
    const size = 76.0;
    Widget inner;
    if (path != null && File(path).existsSync()) {
      inner = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholderIcon(),
        ),
      );
    } else {
      inner = _placeholderIcon();
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        border: Border.all(color: AppColors.borderLight),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : inner,
    );
  }

  Widget _placeholderIcon() {
    return Icon(Icons.image_outlined,
        size: 26, color: AppColors.placeholderText);
  }

  Widget _actionButton(String label, IconData icon, VoidCallback? onTap,
      {bool compact = false}) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppColors.secondaryText),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                      fontSize: compact ? 13 : 12,
                      color: AppColors.secondaryText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.selectedAccent),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.selectedAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
