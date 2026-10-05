import 'package:flutter/material.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../services/metadata_fetcher.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_styles.dart';
import '../../../widgets/app_dialog.dart';
import '../../../widgets/interactive_wrapper.dart';

/// 元数据抓取数据源设定弹窗
///
/// 在添加页"一键抓取"按钮旁的齿轮按钮点击后弹出，
/// 列出所有可抓取平台供用户勾选/取消勾选。
/// 选择偏好通过 [MetadataFetcher.setEnabledSources] 持久化保存，
/// [MetadataFetcher.fetchGame] 会读取该偏好决定抓取哪些数据源。
///
/// 约束：
/// - 至少保留一个数据源（最后一个不可取消）
/// - TouchGal 需配置 Token 才能生效，未配置时显示警告
/// - Bangumi 可选填入个人访问令牌以提升速率限额，未填入时匿名访问
class MetadataSourceSettingsDialog extends StatefulWidget {
  const MetadataSourceSettingsDialog({super.key});

  @override
  State<MetadataSourceSettingsDialog> createState() =>
      _MetadataSourceSettingsDialogState();
}

class _MetadataSourceSettingsDialogState
    extends State<MetadataSourceSettingsDialog> {
  late final Set<SourceType> _selected;
  late final bool _hasTouchGalToken;
  late final TextEditingController _bangumiTokenController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected = MetadataFetcher.getEnabledSources().toSet();
    _hasTouchGalToken = (MetadataFetcher.touchGalToken ?? '').trim().isNotEmpty;
    _bangumiTokenController = TextEditingController();
    _loadBangumiToken();
  }

  @override
  void dispose() {
    _bangumiTokenController.dispose();
    super.dispose();
  }

  /// 异步加载已存储的 Bangumi 个人访问令牌并回填到输入框
  Future<void> _loadBangumiToken() async {
    final token = await BangumiTokenStore.loadToken();
    if (!mounted) return;
    if (token != null && token.isNotEmpty) {
      _bangumiTokenController.text = token;
    }
  }

  /// 数据源描述
  String _sourceDescription(SourceType source) {
    switch (source) {
      case SourceType.bangumi:
        return '日本 ACG 资料库 · 标签为中文';
      case SourceType.vndb:
        return '视觉小说数据库 · 标签为英文，自动翻译为中文';
      case SourceType.ymgal:
        return '中文 GALGAME 社区 · 标签为中文';
      case SourceType.steam:
        return 'Valve 游戏平台 · 标签为中文';
      case SourceType.dlsite:
        return '日本同人作品销售平台 · 标签为日文，自动翻译为中文';
      case SourceType.erogamescape:
        return '日本美少女游戏数据库 · 标签为日文，自动翻译为中文';
      case SourceType.touchgal:
        return '中文 Galgame 数据库 · 国内需代理';
      case SourceType.hikarinagi:
        return '光凪日向 Galgame 数据库 · 标签为中文，内置开发者 Token';
      case SourceType.kun:
        return 'KunGal 中文社区 · 标签为中文，公开 API 免认证';
      case SourceType.nextmoe:
        return 'NextMoe 六源对齐目录 · 中英文标题/简介/标签齐全，最高优先级';
      case SourceType.ct:
        return 'CT 探索库（自有平台）· 社区共建中文元数据，优先级次于 NextMoe';
      case SourceType.mix:
        return '智能整合源 · 按字段优先级整合 NextMoe/CT/VNDB/KunGal/Hikarinagi/Steam/月幕GAL';
      default:
        return '';
    }
  }

  /// 数据源主色调
  Color _sourceAccentColor(SourceType source) {
    switch (source) {
      case SourceType.bangumi:
        return AppColors.dangerRed.withOpacity(0.7);
      case SourceType.vndb:
        return const Color(0xFF4A72A5);
      case SourceType.ymgal:
        return AppColors.successGreen;
      case SourceType.steam:
        return const Color(0xFF1b2838);
      case SourceType.dlsite:
        return const Color(0xFF7AB8C0);
      case SourceType.erogamescape:
        return const Color(0xFFB8860B);
      case SourceType.touchgal:
        return const Color(0xFF9C6ADE);
      case SourceType.hikarinagi:
        return const Color(0xFF6EC6E6);
      case SourceType.kun:
        return const Color(0xFFFF9E80);
      case SourceType.nextmoe:
        return const Color(0xFFE85D9E);
      case SourceType.ct:
        return const Color(0xFFC9506B);
      case SourceType.mix:
        return const Color(0xFF8E6CD9);
      default:
        return AppColors.border;
    }
  }

  void _toggle(SourceType source) {
    setState(() {
      if (_selected.contains(source)) {
        // 至少保留一个数据源
        if (_selected.length > 1) {
          _selected.remove(source);
        }
      } else {
        _selected.add(source);
      }
    });
  }

  Future<void> _save() async {
    if (_selected.isEmpty) return;
    setState(() => _saving = true);
    try {
      final ordered = MetadataFetcher.getAvailableSources()
          .where((s) => _selected.contains(s))
          .toList();
      await MetadataFetcher.setEnabledSources(ordered);

      // 保存 Bangumi 个人访问令牌（为空则清除）
      final token = _bangumiTokenController.text.trim();
      if (token.isNotEmpty) {
        await BangumiTokenStore.saveToken(token);
      } else {
        await BangumiTokenStore.clearToken();
      }

      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = MetadataFetcher.getAvailableSources();

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 440,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 2),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 5),
                blurRadius: 0,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题栏
              _buildHeader(),
              // 顺序说明
              _buildOrderHint(available),
              // 数据源列表
              Flexible(
                child: SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: Column(
                    children: available
                        .expand((source) => [
                              _buildSourceRow(source),
                              // Bangumi 行后插入个人访问令牌输入框
                              if (source == SourceType.bangumi)
                                _buildBangumiTokenInput(),
                            ])
                        .toList(),
                  ),
                ),
              ),
              // 底部按钮
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.shadowColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.tune, size: 18, color: AppColors.border),
          const SizedBox(width: 8),
          Text(
            '抓取数据源设定',
            style: TextStyle(
              fontSize: 18,
              letterSpacing: 2.0,
              color: AppColors.border,
            ),
          ),
          const Spacer(),
          // 关闭按钮
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(false),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child:
                  Icon(Icons.close, size: 18, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  /// 列表顺序说明：告诉用户勾选顺序即抓取结果的展示顺序
  Widget _buildOrderHint(List<SourceType> available) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline,
                size: 13, color: AppColors.secondaryText),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '按推荐优先级排列（${available.length} 个可选源）：'
              'MIX源为多平台整合结果，置于首位；其余平台自左向右、由上到下按优先级递减。'
              '勾选的源将按此顺序返回候选条目。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: AppColors.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceRow(SourceType source) {
    final isSelected = _selected.contains(source);
    final isLastSelected = isSelected && _selected.length == 1;
    final accentColor = _sourceAccentColor(source);

    final isTouchGalWithoutToken =
        source == SourceType.touchgal && !_hasTouchGalToken;

    return Opacity(
      opacity: isLastSelected ? 0.6 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InteractiveWrapper(
          onTap: isLastSelected ? null : () => _toggle(source),
          cursor: isLastSelected
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? accentColor.withOpacity(0.08)
                  : AppColors.background,
              border: Border.all(
                color: isSelected ? accentColor : AppColors.border,
                width: isSelected ? 1.8 : 1.4,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                // 自定义复选框
                _buildCheckbox(isSelected, accentColor, isLastSelected),
                const SizedBox(width: 12),
                // 平台徽章
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    source.displayName,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                // 整合源标记：提示该条目为多平台字段级整合结果
                if (source == SourceType.mix)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: accentColor, width: 1),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '整合',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 10),
                // 描述
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _sourceDescription(source),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppColors.secondaryText,
                          height: 1.4,
                        ),
                      ),
                      if (isTouchGalWithoutToken)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  size: 13, color: AppColors.dangerRed),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  'API Token 尚未接入，勾选后该源不会返回结果',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.dangerRed,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (isLastSelected)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '至少需保留一个数据源',
                            style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Bangumi 个人访问令牌输入框
  ///
  /// 紧跟在 Bangumi 数据源行之后，用户可从 bgm.tv 个人设置页创建令牌后粘贴。
  /// 填入后可获得更高的速率限额；留空则匿名访问。
  Widget _buildBangumiTokenInput() {
    final accentColor = _sourceAccentColor(SourceType.bangumi);
    return Padding(
      padding: const EdgeInsets.only(left: 30, bottom: 10, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.vpn_key_outlined, size: 13, color: accentColor),
              const SizedBox(width: 4),
              Text(
                '个人访问令牌（可选，提升速率限额）',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.4),
              borderRadius: BorderRadius.circular(4),
            ),
            child: TextField(
              controller: _bangumiTokenController,
              obscureText: true,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.primaryText,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                hintText: '粘贴从 bgm.tv 个人设置创建的令牌',
                hintStyle: TextStyle(
                  fontSize: 11,
                  color: AppColors.inputHint,
                ),
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckbox(
      bool isSelected, Color accentColor, bool isLastSelected) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: isSelected ? accentColor : Colors.transparent,
        border: Border.all(
          color: isSelected ? accentColor : AppColors.border,
          width: 1.8,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      child: isSelected
          ? const Icon(Icons.check, size: 13, color: Colors.white)
          : null,
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.shadowColor, width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(false),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1.4),
              ),
              child: Text(
                '取消',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          InteractiveWrapper(
            onTap: _saving ? null : _save,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.buttonBackground,
                border: Border.all(color: AppColors.borderLight, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border,
                    offset: const Offset(2, 3),
                    blurRadius: 0,
                  ),
                ],
              ),
              child: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      '保存',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 显示元数据数据源设定弹窗
///
/// 返回 true 表示用户保存了设置（数据源可能已变更，需清空抓取缓存），
/// 返回 false / null 表示用户取消。
Future<bool?> showMetadataSourceSettingsDialog(BuildContext context) {
  return showAppDialog<bool>(
    context: context,
    builder: (context) => const MetadataSourceSettingsDialog(),
  );
}
