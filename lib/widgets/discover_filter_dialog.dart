import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../models/discover_filter_state.dart';
import 'interactive_wrapper.dart';

/// 高级筛选弹窗
///
/// 阶段4.3：按用户设计稿实现，包含 5 个区块：
/// 1. 排序方式（单选，可取消选择回到默认排序）
/// 2. 评分（滑块，≥ 阈值）
/// 3. 年份（范围滑块）
/// 4. 大小（多选复选框）
/// 5. 状态（单选：未入库/已入库）
///
/// 底部显示已激活筛选摘要 + [重置] [应用筛选] 按钮。
///
/// 调用方式：
/// ```dart
/// final result = await DiscoverFilterDialog.show(
///   context: context,
///   initial: currentFilterState,
/// );
/// if (result != null) { /* 应用新状态 */ }
/// ```
class DiscoverFilterDialog extends StatefulWidget {
  final DiscoverFilterState initial;

  const DiscoverFilterDialog({
    super.key,
    required this.initial,
  });

  static Future<DiscoverFilterState?> show({
    required BuildContext context,
    required DiscoverFilterState initial,
  }) {
    return showDialog<DiscoverFilterState?>(
      context: context,
      builder: (ctx) => DiscoverFilterDialog(initial: initial),
    );
  }

  @override
  State<DiscoverFilterDialog> createState() => _DiscoverFilterDialogState();
}

class _DiscoverFilterDialogState extends State<DiscoverFilterDialog> {
  late DiscoverSortOption _sortOption;
  late double _minRating;
  late RangeValues _yearRange;
  late bool _yearFilterEnabled;
  late Set<DiscoverSizeBucket> _sizeBuckets;
  late DiscoverInstallStatus _installStatus;

  /// 年份滑块范围：2000 - 当前年份
  static final int _minYear = 2000;
  static final int _maxYear = DateTime.now().year;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _sortOption = s.sortOption;
    _minRating = s.minRating;
    _sizeBuckets = Set.from(s.sizeBuckets);
    _installStatus = s.installStatus;

    // 年份范围：未设置时默认全范围（但不启用，需用户拖动才激活）
    _yearFilterEnabled = s.yearFrom != null || s.yearTo != null;
    final from = (s.yearFrom ?? _minYear).clamp(_minYear, _maxYear).toDouble();
    final to = (s.yearTo ?? _maxYear).clamp(_minYear, _maxYear).toDouble();
    _yearRange = RangeValues(from, to);
  }

  DiscoverFilterState _buildResult() {
    return DiscoverFilterState(
      sortOption: _sortOption,
      minRating: _minRating,
      yearFrom: _yearFilterEnabled ? _yearRange.start.round() : null,
      yearTo: _yearFilterEnabled ? _yearRange.end.round() : null,
      sizeBuckets: Set.from(_sizeBuckets),
      installStatus: _installStatus,
    );
  }

  void _reset() {
    setState(() {
      _sortOption = DiscoverSortOption.defaultOrder;
      _minRating = 0.0;
      _yearFilterEnabled = false;
      _yearRange = RangeValues(_minYear.toDouble(), _maxYear.toDouble());
      _sizeBuckets.clear();
      _installStatus = DiscoverInstallStatus.any;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _buildResult();
    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border, width: 1.5),
      ),
      child: Container(
        width: 460,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSortSection(),
                    const SizedBox(height: 20),
                    _buildRatingSection(),
                    const SizedBox(height: 20),
                    _buildYearSection(),
                    const SizedBox(height: 20),
                    _buildSizeSection(),
                    const SizedBox(height: 20),
                    _buildStatusSection(),
                    const SizedBox(height: 12),
                    _buildActiveSummary(result),
                  ],
                ),
              ),
            ),
            _buildFooter(result),
          ],
        ),
      ),
    );
  }

  // ==================== Header ====================

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: AppColors.placeholderCover, width: 1)),
      ),
      child: Row(
        children: [
          Icon(Icons.tune_rounded, size: 22, color: AppColors.border),
          const SizedBox(width: 10),
          Text('高级筛选', style: AppStyles.titleLarge.copyWith(fontSize: 20)),
          const Spacer(),
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(null),
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 20, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Section: 排序方式 ====================

  Widget _buildSortSection() {
    return _buildSection(
      title: '排序方式',
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          _buildSortChip('最新发布', DiscoverSortOption.newestRelease),
          _buildSortChip('评分', DiscoverSortOption.rating),
          _buildSortChip('名称 A-Z', DiscoverSortOption.nameAsc),
          _buildSortChip('文件大小', DiscoverSortOption.fileSize),
          _buildSortChip('热度', DiscoverSortOption.popularity),
        ],
      ),
    );
  }

  Widget _buildSortChip(String label, DiscoverSortOption option) {
    final isSelected = _sortOption == option;
    return GestureDetector(
      onTap: () {
        setState(() {
          // 再次点击已选项 → 取消选择，回到默认排序
          _sortOption = isSelected ? DiscoverSortOption.defaultOrder : option;
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.infoBlue.withOpacity(0.12)
                : AppColors.buttonBackground,
            border: Border.all(
              color: isSelected ? AppColors.infoBlue : AppColors.border,
              width: isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 14,
                color: isSelected
                    ? AppColors.infoBlue
                    : AppColors.secondaryText.withOpacity(0.6),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? AppColors.infoBlue
                      : AppColors.primaryText.withOpacity(0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== Section: 评分 ====================

  Widget _buildRatingSection() {
    final enabled = _minRating > 0;
    return _buildSection(
      title: '评分',
      trailing: enabled
          ? Text(
              '≥ ${_minRating.toStringAsFixed(1)}',
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.infoBlue,
              ),
            )
          : Text(
              '不限',
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 13,
                color: AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
      child: Row(
        children: [
          Icon(Icons.star_rounded, size: 16, color: AppColors.starGold),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: AppColors.starGold,
                inactiveTrackColor: AppColors.placeholderCover,
                thumbColor: AppColors.starGold,
              ),
              child: Slider(
                min: 0,
                max: 10,
                divisions: 20, // 0.5 步进
                value: _minRating,
                onChanged: (v) => setState(() => _minRating = v),
              ),
            ),
          ),
          Icon(Icons.star_rounded, size: 16, color: AppColors.starGold),
        ],
      ),
    );
  }

  // ==================== Section: 年份 ====================

  Widget _buildYearSection() {
    return _buildSection(
      title: '年份',
      trailing: _buildYearToggle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_yearRange.start.round()}',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _yearFilterEnabled
                      ? AppColors.infoBlue
                      : AppColors.secondaryText.withOpacity(0.5),
                ),
              ),
              Text(
                '${_yearRange.end.round()}',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _yearFilterEnabled
                      ? AppColors.infoBlue
                      : AppColors.secondaryText.withOpacity(0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Flutter 3.24.3 无 RangeSliderTheme，用 SliderTheme + range* 属性自定义 RangeSlider
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              rangeThumbShape:
                  const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: AppColors.infoBlue,
              inactiveTrackColor: AppColors.placeholderCover,
              thumbColor: AppColors.infoBlue,
              rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
            ),
            child: RangeSlider(
              min: _minYear.toDouble(),
              max: _maxYear.toDouble(),
              divisions: _maxYear - _minYear,
              values: _yearRange,
              onChanged: _yearFilterEnabled
                  ? (v) => setState(() => _yearRange = v)
                  : null,
            ),
          ),
          if (!_yearFilterEnabled)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '点击右侧开关启用年份筛选',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 11,
                  color: AppColors.secondaryText.withOpacity(0.5),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildYearToggle() {
    return GestureDetector(
      onTap: () => setState(() => _yearFilterEnabled = !_yearFilterEnabled),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 36,
          height: 20,
          decoration: BoxDecoration(
            color: _yearFilterEnabled
                ? AppColors.infoBlue
                : AppColors.placeholderCover,
            borderRadius: BorderRadius.circular(10),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            alignment: _yearFilterEnabled
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== Section: 大小 ====================

  Widget _buildSizeSection() {
    return _buildSection(
      title: '大小',
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: DiscoverSizeBucket.values.map((bucket) {
          final isSelected = _sizeBuckets.contains(bucket);
          return _buildSizeCheckbox(bucket, isSelected);
        }).toList(),
      ),
    );
  }

  Widget _buildSizeCheckbox(DiscoverSizeBucket bucket, bool isSelected) {
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _sizeBuckets.remove(bucket);
          } else {
            _sizeBuckets.add(bucket);
          }
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.infoBlue.withOpacity(0.12)
                : AppColors.buttonBackground,
            border: Border.all(
              color: isSelected ? AppColors.infoBlue : AppColors.border,
              width: isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSelected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 15,
                color: isSelected
                    ? AppColors.infoBlue
                    : AppColors.secondaryText.withOpacity(0.6),
              ),
              const SizedBox(width: 6),
              Text(
                bucket.displayLabel,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? AppColors.infoBlue
                      : AppColors.primaryText.withOpacity(0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== Section: 状态 ====================

  Widget _buildStatusSection() {
    return _buildSection(
      title: '状态',
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          _buildStatusChip('未入库', DiscoverInstallStatus.notInstalled),
          _buildStatusChip('已入库', DiscoverInstallStatus.installed),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String label, DiscoverInstallStatus status) {
    final isSelected = _installStatus == status;
    return GestureDetector(
      onTap: () {
        setState(() {
          _installStatus =
              isSelected ? DiscoverInstallStatus.any : status;
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.infoBlue.withOpacity(0.12)
                : AppColors.buttonBackground,
            border: Border.all(
              color: isSelected ? AppColors.infoBlue : AppColors.border,
              width: isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 14,
                color: isSelected
                    ? AppColors.infoBlue
                    : AppColors.secondaryText.withOpacity(0.6),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? AppColors.infoBlue
                      : AppColors.primaryText.withOpacity(0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== 已激活摘要 ====================

  Widget _buildActiveSummary(DiscoverFilterState state) {
    final summary = state.activeSummary;
    if (summary.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.infoBlue.withOpacity(0.06),
        border: Border(
          left: BorderSide(color: AppColors.infoBlue, width: 3),
        ),
      ),
      child: Text(
        '已激活: $summary',
        style: AppStyles.bodyRegular.copyWith(
          fontSize: 12,
          color: AppColors.infoBlue.withOpacity(0.9),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // ==================== Footer ====================

  Widget _buildFooter(DiscoverFilterState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(color: AppColors.placeholderCover, width: 1)),
      ),
      child: Row(
        children: [
          // 重置按钮
          InteractiveWrapper(
            onTap: state.hasActiveFilters ? _reset : null,
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(
                border: Border.all(
                  color: state.hasActiveFilters
                      ? AppColors.border
                      : AppColors.placeholderCover,
                  width: 1.2,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '重置',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: state.hasActiveFilters
                      ? AppColors.primaryText
                      : AppColors.secondaryText.withOpacity(0.4),
                ),
              ),
            ),
          ),
          const Spacer(),
          // 应用筛选按钮
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(state),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.15),
                    offset: const Offset(0, 2),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: Text(
                '应用筛选',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 通用 Section 容器 ====================

  Widget _buildSection({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText,
              ),
            ),
            const Spacer(),
            if (trailing != null) trailing,
          ],
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}
