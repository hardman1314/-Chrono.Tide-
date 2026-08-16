import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../pages/join/join_controller.dart';
import '../../widgets/app_snack_bar.dart';
import '../big_picture_theme.dart';
import '../widgets/bpm_file_drop_zone.dart';
import '../widgets/bpm_metadata_section.dart';
import '../widgets/bpm_interactive_wrapper.dart';

/// BPM 入库页 (简化版)
///
/// 适配大屏触控操作,提供拖拽导入游戏的功能。
/// 复用桌面模式的 [FileDropZone] + [JoinController] 基础设施。
///
/// 简化策略 (相对桌面模式):
/// - 不显示元数据编辑表单 (名称/标签/描述/封面等)
/// - 拖入文件后自动填充游戏名,用户仅需点击"开始导入"
/// - 导入完成后提示用户切换到桌面模式进行元数据编辑
/// - 仍支持进度展示与错误反馈
class BigPictureJoin extends StatefulWidget {
  /// 入库成功回调 (通常触发库刷新)
  final VoidCallback? onGameAdded;

  const BigPictureJoin({super.key, this.onGameAdded});

  @override
  State<BigPictureJoin> createState() => _BigPictureJoinState();
}

class _BigPictureJoinState extends State<BigPictureJoin> {
  late final JoinController _controller;

  @override
  void initState() {
    super.initState();
    _controller = JoinController(
      onGameAdded: () {
        if (mounted) {
          AppSnackBar.success(context, '入库成功!可切换到桌面模式编辑元数据');
          widget.onGameAdded?.call();
        }
      },
      onError: (message) {
        if (mounted) AppSnackBar.error(context, message);
      },
      onSuccess: (message) {
        if (mounted) AppSnackBar.success(context, message);
      },
      onWarning: (message) {
        if (mounted) AppSnackBar.warning(context, message);
      },
      onInfo: (message) {
        if (mounted) AppSnackBar.info(context, message);
      },
    );
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startImport() async {
    // 确保游戏名已填充 (FileDropZone 拖入时已自动填充)
    if (_controller.selectedFilePath == null) {
      AppSnackBar.warning(context, '请先选择游戏文件或文件夹');
      return;
    }
    if (_controller.nameController.text.trim().isEmpty) {
      // 用文件名兜底
      final name = _controller.selectedFileName ?? '';
      if (name.isNotEmpty) {
        _controller.nameController.text = name;
      } else {
        AppSnackBar.warning(context, '请输入游戏名称');
        return;
      }
    }
    await _controller.submitAddGame();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.pageBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部标题区
          Padding(
            padding: const EdgeInsets.all(BigPictureTheme.pagePadding),
            child: Row(
              children: [
                Text(
                  '入库',
                  style: TextStyle(
                    fontFamily: 'ZhiMangXing',
                    fontSize: BigPictureTheme.displayFontSize,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '拖入游戏文件或文件夹即可导入',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.bodyFontSize,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          // 主体内容
          Expanded(
            child: _controller.isSubmitting
                ? _buildProgressView()
                : _buildDropView(),
          ),
        ],
      ),
    );
  }

  /// 拖拽视图 (默认状态)
  ///
  /// v1.2: 用 FocusTraversalGroup 包裹主体,BpmFileDropZone 替换桌面 FileDropZone
  Widget _buildDropView() {
    final hasFile = _controller.selectedFilePath != null;
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(BigPictureTheme.pagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // v1.2: 拖拽区改用 BPM 风格 BpmFileDropZone
            SizedBox(
              height: 320,
              child: BpmFileDropZone(controller: _controller),
            ),
            const SizedBox(height: BigPictureTheme.sectionSpacing),
            // 已选文件信息 + 导入按钮
            if (hasFile) ...[
              _buildSelectedFileInfo(),
              const SizedBox(height: BigPictureTheme.sectionSpacing),
            ] else ...[
              _buildHintCard(),
              const SizedBox(height: BigPictureTheme.sectionSpacing),
            ],
            // 元数据编辑板块 (数据抓取)
            _buildMetadataEditSection(),
            const SizedBox(height: BigPictureTheme.sectionSpacing),
            // 导入按钮 (始终显示, 提交当前表单)
            if (hasFile) _buildImportButton(),
            // 错误提示
            if (_controller.errorMessage != null) ...[
              const SizedBox(height: BigPictureTheme.sectionSpacing),
              _buildErrorCard(),
            ],
          ],
        ),
      ),
    );
  }

  /// 元数据编辑板块 (数据抓取 + 表单字段)
  ///
  /// 复用桌面 [MetadataSection] 抓取结果展示 + 自定义 BPM 风格的输入字段。
  /// 用户可输入游戏名 → 点击抓取 → 选择抓取结果 → 编辑标签/开发者/简介 → 导入。
  Widget _buildMetadataEditSection() {
    return Container(
      padding: const EdgeInsets.all(BigPictureTheme.widgetPadding),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 板块标题
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded,
                  size: 24, color: AppColors.selectedAccent),
              const SizedBox(width: 8),
              Text(
                '元数据编辑',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: BigPictureTheme.subtitleFontSize,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText,
                ),
              ),
              const Spacer(),
              // 一键抓取按钮
              _buildScrapeButton(),
            ],
          ),
          const SizedBox(height: 16),
          // 游戏名输入
          _buildLabeledInput(
            label: '游戏名称',
            controller: _controller.nameController,
            hint: '输入游戏名称后可一键抓取',
          ),
          const SizedBox(height: 12),
          // 抓取结果展示 (复用桌面 MetadataSection)
          if (_controller.scrapeResults.isNotEmpty ||
              _controller.isScraping) ...[
            _buildScrapeResultsSection(),
            const SizedBox(height: 12),
          ],
          // 标签输入
          _buildLabeledInput(
            label: '标签 (逗号分隔)',
            controller: _controller.tagsController,
            hint: 'GAL, ADV, 汉化',
          ),
          const SizedBox(height: 12),
          // 开发者输入
          _buildLabeledInput(
            label: '开发者',
            controller: _controller.developerController,
            hint: '游戏开发公司',
          ),
          const SizedBox(height: 12),
          // 简介输入
          _buildLabeledInput(
            label: '简介',
            controller: _controller.descController,
            hint: '游戏简介 (可选)',
            maxLines: 3,
          ),
        ],
      ),
    );
  }

  /// 一键抓取按钮
  Widget _buildScrapeButton() {
    return BpmInteractiveWrapper(
      onTap: _controller.isScraping
          ? null
          : () async {
              if (_controller.nameController.text.trim().isEmpty) {
                AppSnackBar.warning(context, '请先输入游戏名称');
                return;
              }
              await _controller.fetchScrapeData();
            },
      semanticsLabel: '一键抓取',
      borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: _controller.isScraping
              ? AppColors.buttonBackground
              : AppColors.selectedAccent,
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
          border: Border.all(
            color: _controller.isScraping
                ? AppColors.border
                : AppColors.selectedAccent,
            width: 1.5,
          ),
        ),
        child: _controller.isScraping
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      // v1.2: 进度环颜色改为白色,提升对比度
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '抓取中...',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: BigPictureTheme.labelFontSize,
                      color: Colors.white,
                    ),
                  ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.search_rounded,
                      size: 18, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    '一键抓取',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: BigPictureTheme.labelFontSize,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// v1.2: 抓取结果展示 (改用 BPM 风格 BpmMetadataSection)
  Widget _buildScrapeResultsSection() {
    return BpmMetadataSection(
      controller: _controller,
      height: 320,
    );
  }

  /// 带标签的输入框
  Widget _buildLabeledInput({
    required String label,
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: BigPictureTheme.labelFontSize,
            fontWeight: FontWeight.w600,
            color: AppColors.secondaryText,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: BigPictureTheme.bodyFontSize,
            color: AppColors.primaryText,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.bodyFontSize,
              color: AppColors.placeholderText,
            ),
            filled: true,
            fillColor: AppColors.pageBackground,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              borderSide: BorderSide(color: AppColors.border, width: 1),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              borderSide: BorderSide(color: AppColors.border, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              borderSide:
                  BorderSide(color: AppColors.selectedAccent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  /// 进度视图 (导入中)
  Widget _buildProgressView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(BigPictureTheme.pagePadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度环
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: _controller.progressValue > 0
                        ? _controller.progressValue
                        : null,
                    strokeWidth: 8,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
                  ),
                  Center(
                    child: Text(
                      _controller.progressValue > 0
                          ? '${(_controller.progressValue * 100).toInt()}%'
                          : '...',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // 进度消息
            Text(
              _controller.progressMessage.isNotEmpty
                  ? _controller.progressMessage
                  : '正在导入...',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.bodyFontSize,
                color: AppColors.secondaryText,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _controller.selectedFileName ?? '',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.subtitleFontSize,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 已选文件信息卡片
  Widget _buildSelectedFileInfo() {
    return Container(
      padding: const EdgeInsets.all(BigPictureTheme.widgetPadding),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(Icons.file_present_rounded,
              size: 40, color: AppColors.selectedAccent),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _controller.selectedFileName ?? '未知文件',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.bodyFontSize,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _controller.selectedFilePath ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.labelFontSize,
                    color: AppColors.placeholderText,
                  ),
                ),
              ],
            ),
          ),
          // 清除按钮
          BpmInteractiveWrapper(
            onTap: () => _controller.clearFileSelection(),
            semanticsLabel: '清除选择',
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.buttonBackground,
                borderRadius:
                    BorderRadius.circular(BigPictureTheme.buttonRadius),
                border: Border.all(color: AppColors.border, width: 1),
              ),
              child: Icon(Icons.close_rounded,
                  size: 20, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  /// 导入按钮 (v1.2: 移除 autofocus,避免与 TextField/BpmFileDropZone 焦点冲突)
  Widget _buildImportButton() {
    return BpmInteractiveWrapper(
      onTap: _startImport,
      semanticsLabel: '开始导入',
      borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
      child: Container(
        height: BigPictureTheme.launchButtonHeight,
        decoration: BoxDecoration(
          color: AppColors.selectedAccent,
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
          boxShadow: [
            BoxShadow(
              color: AppColors.selectedAccent.withOpacity(0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.download_for_offline_rounded,
                size: 32, color: Colors.white),
            SizedBox(width: 12),
            Text(
              '开始导入',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 提示卡片 (未选择文件时)
  Widget _buildHintCard() {
    return Container(
      padding: const EdgeInsets.all(BigPictureTheme.sectionSpacing),
      decoration: BoxDecoration(
        color: AppColors.background.withOpacity(0.5),
        borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Column(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 48, color: AppColors.secondaryText.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(
            '支持的文件类型',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.subtitleFontSize,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '.ctgame 压缩包 · .zip 压缩包 · 游戏文件夹',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.bodyFontSize,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '导入完成后,可切换到桌面模式编辑游戏元数据 (封面/标签/描述等)',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.labelFontSize,
              color: AppColors.placeholderText,
            ),
          ),
        ],
      ),
    );
  }

  /// 错误信息卡片
  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(BigPictureTheme.widgetPadding),
      decoration: BoxDecoration(
        color: AppColors.dangerRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
        border: Border.all(color: AppColors.dangerRed, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 24, color: AppColors.dangerRed),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _controller.errorMessage!,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.bodyFontSize,
                // v1.2: 文字改用 primaryText 提升对比度；图标/边框/底色保持 dangerRed 保留错误语义
                color: AppColors.primaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
