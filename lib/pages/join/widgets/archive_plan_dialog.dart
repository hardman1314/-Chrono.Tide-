import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/archive_inspector.dart';
import '../../../services/extract_manager.dart';
import '../../../services/unpack_plan.dart';
import '../../../services/unpack_store.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/app_dialog.dart';
import '../../../widgets/interactive_wrapper.dart';

/// 解压计划确认弹窗 —— 两板块结构（2026-10-05 需求重构：去层级化）
///
/// 板块一「设定」（仅预设配置，供系统自动执行使用）：
///   ① 密码组预设：选择/保存/删除（组为整体，保留组内密码关联性）
///   ② 密码库入口：全量浏览 + 自行增删（预设组 ∪ 历史组汇总保底）
/// 板块二「后缀」：
///   ① 内置改名链展示（遇到某后缀时的试解顺序）
///   ② 自定义改名规则入口（覆盖内置链，持久化）
///
/// 实际解压区（showExtractStartDialog）：密码组填写（可选用预设组）
/// + 解压位置选择，交由用户操作。底部「下一步」进入。
///
/// 执行中 `waiting_for_input` 暂停态（Phase 3）复用底部密码补输弹窗。
class ArchivePlanConfirmation {
  const ArchivePlanConfirmation({
    required this.plan,
    this.extractLocation,
  });

  /// 确认后的计划（passwordSequence 已带上用户按层填写的密码）
  final UnpackPlan plan;

  /// 非空 = 解压到该目录（默认 = 源文件所在文件夹）；null = 安装偏好
  final String? extractLocation;
}

/// 入口：探测 → 弹窗 → 返回确认结果（取消返回 null）
/// [archivePath] 为 null 时进入「纯设置模式」（2026-10-05 需求 #2：单文件
/// 导入页「打开解压计划窗口」按钮随时进入）：跳过压缩包探测，仅展示
/// 「设定/后缀」两板块预设配置，底部「保存」即关闭——配置即时写入
/// UnpackStore，解压时自动应用。
Future<ArchivePlanConfirmation?> showArchivePlanDialog(
  BuildContext context, {
  String? archivePath,
}) {
  return showAppDialog<ArchivePlanConfirmation>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ArchivePlanDialog(archivePath: archivePath),
  );
}

class _ArchivePlanDialog extends StatefulWidget {
  const _ArchivePlanDialog({this.archivePath});

  /// null = 纯设置模式（无具体压缩包，只改预设）
  final String? archivePath;

  @override
  State<_ArchivePlanDialog> createState() => _ArchivePlanDialogState();
}

class _ArchivePlanDialogState extends State<_ArchivePlanDialog> {
  /// 自定义改名规则可选格式（链序 = 勾选顺序，简化为固定序列选择）
  static const List<String> _chainFormats = ['zip', 'rar', '7z', 'enc'];

  /// 纯设置模式：无具体压缩包，只改预设配置
  bool get _settingsOnly => widget.archivePath == null;

  UnpackPlan? _plan;
  String? _error;
  String? _selectedGroupName;

  @override
  void initState() {
    super.initState();
    _buildPlan();
  }

  Future<void> _buildPlan() async {
    // 纯设置模式：跳过压缩包探测，直接以空计划进入两板块配置界面
    if (_settingsOnly) {
      setState(() {
        _plan = const UnpackPlan(sourcePath: '', layers: []);
      });
      return;
    }
    try {
      final plan = await ArchiveInspector.buildPlan(widget.archivePath!);
      if (!mounted) return;
      setState(() => _plan = plan);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 500,
          constraints: const BoxConstraints(maxHeight: 640),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 2),
            boxShadow: const [
              BoxShadow(offset: Offset(4, 5), blurRadius: 0, color: Colors.black26),
            ],
          ),
          child: _plan == null && _error == null
              ? _buildLoading()
              : _error != null
                  ? _buildError()
                  : _buildBody(),
        ),
      ),
    );
  }

  // ---------- 加载 / 错误 ----------

  Widget _buildLoading() {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 16),
          Text('正在扫描压缩包结构...',
              style: TextStyle(fontSize: 13, color: AppColors.secondaryText)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 36, color: AppColors.dangerRed),
          const SizedBox(height: 12),
          Text('扫描失败',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(_error ?? '',
              style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          _buildCancelButton(),
        ],
      ),
    );
  }

  // ---------- 主体 ----------

  Widget _buildBody() {
    final plan = _plan!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(plan),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (plan.warnings.isNotEmpty) _buildWarnings(plan),
                _buildBoardTitle('设定', '密码组预设与密码库（供系统自动执行使用）'),
                _buildPasswordGroupSection(),
                const SizedBox(height: 10),
                _buildBoardDivider(),
                _buildBoardTitle('后缀', '伪装后缀自动改名链（按顺序试解）'),
                _buildSuffixSection(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        _buildFooter(plan),
      ],
    );
  }

  Widget _buildHeader(UnpackPlan plan) {
    final fileName =
        plan.sourcePath.split('/').last.split('\\').last;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border, width: 1.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_settingsOnly ? '解压计划设置' : '解压计划',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              _settingsOnly
                  ? '预设配置，解压时自动应用（此处无需选择压缩包）'
                  : fileName,
              style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildWarnings(UnpackPlan plan) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.infoBlue.withOpacity(0.08),
        border: Border.all(color: AppColors.infoBlue.withOpacity(0.4), width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final w in plan.warnings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 13, color: AppColors.infoBlue),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(w,
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.secondaryText)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 板块标题 ----------

  Widget _buildBoardTitle(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(subtitle,
                style:
                    TextStyle(fontSize: 10.5, color: AppColors.placeholderText)),
          ),
        ],
      ),
    );
  }

  Widget _buildBoardDivider() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: 1,
      color: AppColors.border.withOpacity(0.6),
    );
  }

  // ---------- 板块①「设定」：密码组预设 + 密码库入口 ----------

  /// 密码组选择/保存/删除 + 密码库入口（组为整体管理，保留组内关联性）
  Widget _buildPasswordGroupSection() {
    final groups = UnpackStore.instance.passwordGroups;
    // 下拉值防悬空（选中组被删后）
    final validNames = groups.map((g) => g.name).toSet();
    if (_selectedGroupName != null && !validNames.contains(_selectedGroupName)) {
      _selectedGroupName = null;
    }
    final selected = _selectedGroupName == null
        ? null
        : groups.firstWhere((g) => g.name == _selectedGroupName);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bookmark_border_rounded,
                  size: 14, color: AppColors.infoBlue),
              const SizedBox(width: 6),
              Expanded(
                child: DropdownButton<String>(
                  value: _selectedGroupName,
                  isExpanded: true,
                  hint: Text(
                      groups.isEmpty ? '暂无预设，可先保存一组' : '选择密码组…',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.placeholderText)),
                  items: [
                    for (final g in groups)
                      DropdownMenuItem(
                        value: g.name,
                        child: Text(
                          '${g.auto ? "🕘 " : ""}${g.name}（${g.passwords.length} 个密码）',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (name) =>
                      setState(() => _selectedGroupName = name),
                  underline: const SizedBox.shrink(),
                ),
              ),
              _presetActionButton('存为预设', _saveAsPreset),
              if (selected != null) ...[
                const SizedBox(width: 4),
                _presetActionButton('删除', _deleteSelectedPreset,
                    danger: true),
              ],
            ],
          ),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '组内 ${selected.passwords.length} 个密码按序整体尝试（不可拆散）',
                style: TextStyle(
                    fontSize: 10.5, color: AppColors.placeholderText),
              ),
            ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: _presetActionButton('密码库管理', _openPasswordLibrary),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAsPreset() async {
    final nameCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存密码组', style: TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  hintText: '组名（如：某某分享者的资源）', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pwCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  hintText: '密码，多个用空格分隔', isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtrl.text.trim();
    final passwords = pwCtrl.text
        .trim()
        .split(RegExp(r'[\s,，]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (name.isEmpty || passwords.isEmpty) return;
    UnpackStore.instance.savePasswordGroup(PasswordGroup(
      name: name,
      passwords: passwords,
      lastUsedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (!mounted) return;
    setState(() => _selectedGroupName = name);
  }

  void _deleteSelectedPreset() {
    final name = _selectedGroupName;
    if (name == null) return;
    UnpackStore.instance.deletePasswordGroup(name);
    setState(() => _selectedGroupName = null);
  }

  /// 密码库管理：全量浏览（预设组 + 历史组），支持删组、加组
  Future<void> _openPasswordLibrary() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => const _PasswordLibraryDialog(),
    );
    if (mounted) setState(() {});
  }

  Widget _presetActionButton(String label, VoidCallback onTap,
      {bool danger = false}) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(
              color: danger
                  ? AppColors.dangerRed.withOpacity(0.5)
                  : AppColors.border,
              width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10.5,
                color: danger ? AppColors.dangerRed : null)),
      ),
    );
  }

  // ---------- 板块②「后缀」：内置改名链展示 + 自定义规则 ----------

  /// 内置链重点展示（需求方点名的五条）+ 摘要；自定义规则覆盖同后缀内置链
  static const List<String> _featuredChainExts = [
    '.mp4', '.mov', '.exe', '.txt', '',
  ];

  Widget _buildSuffixSection() {
    final defaults = UnpackStore.defaultAutoTryChains;
    final customs = UnpackStore.instance.customAutoTryChains;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('内置改名链（遇到该后缀时的自动试解顺序，逻辑改名不碰盘上文件）',
              style: TextStyle(fontSize: 10.5, color: AppColors.placeholderText)),
          const SizedBox(height: 6),
          for (final ext in _featuredChainExts)
            _chainRow(ext, defaults[ext] ?? const []),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '其他常见后缀（视频/音频/图片等）已内置默认链；表外后缀不自动试解。',
              style: TextStyle(fontSize: 10.5, color: AppColors.placeholderText)),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text('自定义规则',
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              _presetActionButton('添加规则', _addCustomChain),
            ],
          ),
          if (customs == null || customs.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('暂无自定义规则，全部按内置链执行。',
                  style: TextStyle(
                      fontSize: 10.5, color: AppColors.placeholderText)),
            )
          else
            for (final e in customs.entries)
              _customChainRow(e.key, e.value),
        ],
      ),
    );
  }

  Widget _chainRow(String ext, List<String> chain) {
    final label = ext.isEmpty ? '（空后缀）' : ext;
    final chainText =
        chain.map((f) => f.toUpperCase()).join(' → ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Text('$label  →  $chainText',
          style: TextStyle(fontSize: 11, color: AppColors.secondaryText)),
    );
  }

  Widget _customChainRow(String ext, List<String> chain) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: _chainRow(ext, chain)),
          InteractiveWrapper(
            onTap: () {
              // 传空表 = 删除覆盖、恢复内置默认链
              UnpackStore.instance.setAutoTryChain(ext, const []);
              setState(() {});
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 13, color: AppColors.dangerRed.withOpacity(0.7)),
            ),
          ),
        ],
      ),
    );
  }

  /// 添加自定义改名规则：后缀 + 格式序列（简化交互——按勾选顺序组链）
  Future<void> _addCustomChain() async {
    final extCtrl = TextEditingController();
    final picks = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('添加改名规则', style: TextStyle(fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: extCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                    hintText: '后缀（如 .xyz；空 = 空后缀文件）', isDense: true),
              ),
              const SizedBox(height: 10),
              const Text('按勾选顺序组链：',
                  style: TextStyle(fontSize: 12)),
              for (final f in _chainFormats)
                CheckboxListTile(
                  value: picks.contains(f),
                  onChanged: (v) => setDialogState(() {
                    v == true ? picks.add(f) : picks.remove(f);
                  }),
                  title: Text(f.toUpperCase(), style: const TextStyle(fontSize: 12.5)),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    var ext = extCtrl.text.trim().toLowerCase();
    if (ext.isNotEmpty && !ext.startsWith('.')) ext = '.$ext';
    if (picks.isEmpty) return;
    // 链序 = 内置格式表顺序（勾选集合按固定优先级排序）
    final chain = _chainFormats.where(picks.contains).toList();
    UnpackStore.instance.setAutoTryChain(ext, chain);
    if (mounted) setState(() {});
  }

  // ---------- 底部 ----------

  Widget _buildFooter(UnpackPlan plan) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border, width: 1.4)),
      ),
      child: Row(
        children: [
          Expanded(child: _buildCancelButton()),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: InteractiveWrapper(
              onTap: () => _confirm(plan),
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  border: Border.all(color: AppColors.border, width: 2),
                  boxShadow: const [
                    BoxShadow(offset: Offset(2, 3), blurRadius: 0, color: Colors.black26),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(_settingsOnly ? '保存' : '下一步',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryText)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirm(UnpackPlan plan) {
    // 纯设置模式：两板块配置在操作时已即时写入 UnpackStore，「保存」直接关闭
    if (_settingsOnly) {
      Navigator.of(context).pop();
      return;
    }
    // ★ 去层级化（2026-10-05）：计划窗只做预设配置（设定/后缀两板块），
    //   点「下一步」进入实际解压区（密码组填写 + 解压位置），由用户操作。
    final result = showExtractStartDialog(context, plan: plan);
    result.then((confirmation) {
      if (!mounted || confirmation == null) return;
      Navigator.of(context).pop(confirmation);
    });
  }

  Widget _buildCancelButton() {
    return InteractiveWrapper(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.4),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text('取消',
            style: TextStyle(
                fontSize: 12.5, color: AppColors.secondaryText)),
      ),
    );
  }
}

/// 实际解压区（2026-10-05 需求 #5）：密码组填写（可选用预设密码组）
/// + 解压位置选择，交由用户操作。返回与计划窗同构的确认结果。
Future<ArchivePlanConfirmation?> showExtractStartDialog(
  BuildContext context, {
  required UnpackPlan plan,
}) {
  return showDialog<ArchivePlanConfirmation>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExtractStartDialog(plan: plan),
  );
}

class _ExtractStartDialog extends StatefulWidget {
  const _ExtractStartDialog({required this.plan});

  final UnpackPlan plan;

  @override
  State<_ExtractStartDialog> createState() => _ExtractStartDialogState();
}

class _ExtractStartDialogState extends State<_ExtractStartDialog> {
  final TextEditingController _pwGroupCtrl = TextEditingController();
  String? _selectedGroupName;
  bool _extractToSourceFolder = true;

  @override
  void dispose() {
    _pwGroupCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final sourceDir = File(plan.sourcePath).parent.path;
    final groups = UnpackStore.instance.passwordGroups;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 440,
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 2),
            boxShadow: const [
              BoxShadow(offset: Offset(4, 5), blurRadius: 0, color: Colors.black26),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- 标题 ----
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                      bottom:
                          BorderSide(color: AppColors.border, width: 1.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('开始解压',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                        plan.sourcePath.split('/').last.split('\\').last,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.secondaryText),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              // ---- 实际解压区 ----
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel('密码组'),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 30,
                            child: TextField(
                              controller: _pwGroupCtrl,
                              style: const TextStyle(fontSize: 12),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '多个密码用空格分隔；未加密可留空',
                                hintStyle: TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.placeholderText),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 7),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(4),
                                  borderSide: BorderSide(
                                      color: AppColors.border, width: 1),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 118,
                          height: 30,
                          child: DropdownButton<String>(
                            value: _selectedGroupName,
                            isExpanded: true,
                            hint: Text('用预设组',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.placeholderText)),
                            items: [
                              for (final g in groups)
                                DropdownMenuItem(
                                  value: g.name,
                                  child: Text(
                                      '${g.auto ? "🕘 " : ""}${g.name}',
                                      style: const TextStyle(fontSize: 11.5),
                                      overflow: TextOverflow.ellipsis),
                                ),
                            ],
                            onChanged: (name) {
                              if (name == null) return;
                              final hit = UnpackStore.instance.passwordGroups
                                  .firstWhere((g) => g.name == name);
                              setState(() {
                                _selectedGroupName = name;
                                _pwGroupCtrl.text = hit.passwords.join(' ');
                              });
                            },
                            underline: const SizedBox.shrink(),
                            isDense: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _sectionLabel('解压位置'),
                    _locationRow(
                      value: true,
                      title: '解压到源文件所在文件夹（推荐）',
                      subtitle: sourceDir,
                    ),
                    const SizedBox(height: 4),
                    _locationRow(
                      value: false,
                      title: '解压到默认安装位置',
                      subtitle: '按软件安装路径偏好设置',
                    ),
                    const SizedBox(height: 4),
                    Text('密码候选顺序：本次输入 → 预设组 → 历史组 → 密码库保底。',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: AppColors.placeholderText)),
                  ],
                ),
              ),
              // ---- 底部按钮 ----
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                      top:
                          BorderSide(color: AppColors.border, width: 1.4)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InteractiveWrapper(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          height: 34,
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: AppColors.border, width: 1.4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          alignment: Alignment.center,
                          child: Text('返回修改',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.secondaryText)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: InteractiveWrapper(
                        onTap: () => _start(plan),
                        child: Container(
                          height: 34,
                          decoration: BoxDecoration(
                            color: AppColors.buttonBackground,
                            border: Border.all(
                                color: AppColors.border, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                  offset: Offset(2, 3),
                                  blurRadius: 0,
                                  color: Colors.black26),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text('开始解压',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primaryText)),
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
    );
  }

  Widget _sectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Text(title,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryText)),
    );
  }

  Widget _locationRow({
    required bool value,
    required String title,
    required String subtitle,
  }) {
    final selected = value == _extractToSourceFolder;
    return InteractiveWrapper(
      onTap: () => setState(() => _extractToSourceFolder = value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_off_rounded,
            size: 15,
            color: selected ? AppColors.infoBlue : AppColors.border,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 12.5)),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 10.5, color: AppColors.placeholderText),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _start(UnpackPlan plan) {
    final passwords = _pwGroupCtrl.text
        .trim()
        .split(RegExp(r'[\s,，]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    final confirmed = UnpackPlan(
      sourcePath: plan.sourcePath,
      firstVolumePath: plan.firstVolumePath,
      layers: plan.layers,
      // ★ 去层级化：passwordSequence = 用户本次输入的扁平密码组
      suffixMappings: plan.suffixMappings,
      passwordSequence: passwords,
      warnings: plan.warnings,
    );
    Navigator.of(context).pop(ArchivePlanConfirmation(
      plan: confirmed,
      extractLocation: _extractToSourceFolder
          ? File(plan.sourcePath).parent.path
          : null,
    ));
  }
}

/// 密码库管理弹窗（2026-10-05 需求 #2）：预设组 + 历史组全量浏览，
/// 支持删除组、新增组。组为整体管理，不做组内单密码拆散编辑。
class _PasswordLibraryDialog extends StatefulWidget {
  const _PasswordLibraryDialog();

  @override
  State<_PasswordLibraryDialog> createState() =>
      _PasswordLibraryDialogState();
}

class _PasswordLibraryDialogState extends State<_PasswordLibraryDialog> {
  @override
  Widget build(BuildContext context) {
    final groups = UnpackStore.instance.passwordGroups;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 420,
          constraints: const BoxConstraints(maxHeight: 480),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 2),
            boxShadow: const [
              BoxShadow(offset: Offset(4, 5), blurRadius: 0, color: Colors.black26),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                      bottom:
                          BorderSide(color: AppColors.border, width: 1.4)),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('密码库',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                    InteractiveWrapper(
                      onTap: _addGroup,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: AppColors.border, width: 1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('新增密码组',
                            style: TextStyle(
                                fontSize: 10.5, color: AppColors.infoBlue)),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: groups.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text('库为空。解压成功后系统会自动记录历史密码组，\n也可手动新增常用密码组。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.secondaryText)),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final g in groups)
                              _groupTile(g),
                          ],
                        ),
                      ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                      top:
                          BorderSide(color: AppColors.border, width: 1.4)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '历史组（🕘）为解压成功后自动记录，上限 10 组。',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: AppColors.placeholderText),
                      ),
                    ),
                    InteractiveWrapper(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: AppColors.border, width: 1.4),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('关闭',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.secondaryText)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupTile(PasswordGroup g) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${g.auto ? "🕘 " : ""}${g.name}（${g.passwords.length} 个密码）',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  g.passwords.map((p) => '•••').join(' '),
                  style: TextStyle(
                      fontSize: 10.5, color: AppColors.placeholderText),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          InteractiveWrapper(
            onTap: () {
              UnpackStore.instance.deletePasswordGroup(g.name);
              setState(() {});
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 13, color: AppColors.dangerRed.withOpacity(0.7)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addGroup() async {
    final nameCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新增密码组', style: TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  hintText: '组名', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pwCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                  hintText: '密码，多个用空格分隔', isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final passwords = pwCtrl.text
        .trim()
        .split(RegExp(r'[\s,，]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (name.isEmpty || passwords.isEmpty) return;
    UnpackStore.instance.savePasswordGroup(PasswordGroup(
      name: name,
      passwords: passwords,
      lastUsedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (mounted) setState(() {});
  }
}

/// 解压完成确认结果（方案 §4.7 最终文件夹名确认 + §4.7b 删源包显式确认）
class ExtractFinishDecision {
  const ExtractFinishDecision({
    this.finalDirName,
    required this.deleteSourceArchive,
  });

  /// null / 空 = 保持原目录名；非空 = 用户编辑后的游戏本体文件夹名
  final String? finalDirName;

  /// 是否删除源压缩包（默认 false = 保留）
  final bool deleteSourceArchive;
}

/// `waiting_for_input` 暂停补输弹窗（方案 §4.5）：
/// 某层密码候选队列全败时解压暂停，等用户补输密码后继续。
/// 返回 null = 用户放弃（解压走既有失败路径）。
Future<String?> showPasswordInputDialog(
  BuildContext context, {
  required int layerIndex,
  required String archiveName,
  required String format,
  required int triedCount,
}) {
  final ctrl = TextEditingController();
  return showAppDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      void submit(String? value) {
        final v = value?.trim() ?? '';
        Navigator.of(dialogContext).pop(v.isEmpty ? null : v);
      }

      return AlertDialog(
        title: Text('需要密码（第${layerIndex + 1}层 · $format）',
            style: const TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已自动尝试 $triedCount 个候选密码（含内置密码表），均失败。',
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.secondaryText)),
            const SizedBox(height: 6),
            Text(archiveName,
                style: const TextStyle(fontSize: 11.5),
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: '输入该压缩包的密码',
                isDense: true,
              ),
              onSubmitted: submit,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('放弃'),
          ),
          TextButton(
            onPressed: () => submit(ctrl.text),
            child: const Text('继续解压'),
          ),
        ],
      );
    },
  );
}

/// ★ Phase A/B（join_unpack_scenarios_v2.md §1.4）：`waiting_for_strategy`
/// 「后缀映射决策窗」——嵌套文件魔数与文件名双未命中时解压挂起询问。
/// 动作：手动指定格式 / 自动尝试候选链（仅当 request.tryFormats 非空，
/// Phase B）/ 终止解压。返回 null = 用户放弃（解压走取消清理路径）。
Future<ExtractDecisionResult?> showStrategyDecisionDialog(
  BuildContext context, {
  required ExtractDecisionRequest request,
}) {
  // 与 extract_manager `_extractSingleFormat` 的 switch 支持面对齐
  const formats = [
    'zip', 'rar', '7z', 'lz4', 'tar', 'gz', 'bz2', 'xz',
    'zst', 'lzma', 'iso', 'cab', 'arj', 'enc',
  ];
  final canAutoTry = request.tryFormats.isNotEmpty;
  String? picked;
  return showAppDialog<ExtractDecisionResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: Text('无法识别的嵌套文件（第${request.layerIndex + 1}层）',
              style: const TextStyle(fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(request.message,
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.secondaryText)),
              const SizedBox(height: 6),
              Text(
                request.archiveFile.split('/').last.split('\\').last,
                style: const TextStyle(fontSize: 11.5),
                overflow: TextOverflow.ellipsis,
              ),
              if (canAutoTry) ...[
                const SizedBox(height: 6),
                Text(
                  '自动尝试顺序: ${request.tryFormats.map((f) => '.$f').join(' → ')}，'
                  '每种失败后清层再试下一种',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.secondaryText),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: picked,
                hint: const Text('手动指定该文件的压缩格式',
                    style: TextStyle(fontSize: 12.5)),
                isExpanded: true,
                items: [
                  for (final f in formats)
                    DropdownMenuItem(
                        value: f,
                        child:
                            Text('.$f', style: const TextStyle(fontSize: 13))),
                ],
                onChanged: (v) => setDialogState(() => picked = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('终止解压'),
            ),
            if (canAutoTry)
              TextButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(const ExtractDecisionResult(
                  proceed: true,
                  autoTry: true,
                )),
                child: Text('自动尝试（${request.tryFormats.length} 种）'),
              ),
            TextButton(
              onPressed: picked == null
                  ? null
                  : () => Navigator.of(dialogContext).pop(
                      ExtractDecisionResult(proceed: true, format: picked)),
              child: const Text('按指定格式继续'),
            ),
          ],
        );
      });
    },
  );
}

/// ★ Phase D（join_unpack_scenarios_v2.md §1.2）：多文件歧义「目标文件
/// 选择框」——≥2 候选时解压挂起，用户单选游戏本体，其余视为诱饵（随
/// 临时层自动清理）。候选展示格式判定（魔数/后缀映射/链候选）与体积；
/// 推荐本体带「推荐」标记（引擎见 extract_manager._recommendCandidate，
/// 可经 UnpackStore.setAmbiguityRuleEnabled 关闭）。
/// 返回 null = 用户取消解压（走取消清理路径）。
Future<ExtractDecisionResult?> showAmbiguityDecisionDialog(
  BuildContext context, {
  required ExtractDecisionRequest request,
}) {
  String? picked = request.recommendPath;
  String sizeLabel(int b) => b >= 1024 * 1024 * 1024
      ? '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB'
      : b >= 1024 * 1024
          ? '${(b / 1024 / 1024).toStringAsFixed(1)} MB'
          : '${(b / 1024).toStringAsFixed(0)} KB';
  String fmtLabel(ExtractCandidate c) {
    if (c.magicFormat != null) return '魔数判定: ${c.magicFormat}';
    if (c.nameFormat != null) return '后缀推断: ${c.nameFormat}';
    return '未识别（候选链）';
  }

  return showAppDialog<ExtractDecisionResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: Text('指定游戏本体（第${request.layerIndex + 1}层）',
              style: const TextStyle(fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(request.message,
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.secondaryText)),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in request.candidates)
                        InkWell(
                          onTap: () => setDialogState(() => picked = c.path),
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: picked == c.path
                                    ? AppColors.accentInk
                                    : AppColors.border,
                                width: picked == c.path ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  picked == c.path
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                  size: 15,
                                  color: picked == c.path
                                      ? AppColors.accentInk
                                      : AppColors.secondaryText,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              c.path
                                                  .split('/')
                                                  .last
                                                  .split('\\')
                                                  .last,
                                              style: const TextStyle(
                                                  fontSize: 12.5),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (c.path ==
                                              request.recommendPath) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets
                                                  .symmetric(
                                                  horizontal: 4,
                                                  vertical: 1),
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                    color: AppColors
                                                        .accentInk),
                                              ),
                                              child: Text('推荐',
                                                  style: TextStyle(
                                                      fontSize: 10,
                                                      color: AppColors
                                                          .accentInk)),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${fmtLabel(c)} · ${sizeLabel(c.sizeBytes)}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.secondaryText),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消解压'),
            ),
            TextButton(
              onPressed: picked == null
                  ? null
                  : () => Navigator.of(dialogContext).pop(
                      ExtractDecisionResult(
                          proceed: true, chosenPath: picked)),
              child: const Text('确定本体'),
            ),
          ],
        );
      });
    },
  );
}

/// ★ Phase E（scenarios_v2 §1.3）：「未找到本体」弹窗——解压结果无目录
/// 结构也无可用压缩层时，让用户确认：仍以当前结果收尾 / 取消解压。
/// 返回 proceed=true = 仍以此收尾；null = 用户取消（走取消清理路径）。
Future<ExtractDecisionResult?> showBodyNotFoundDialog(
  BuildContext context, {
  required ExtractDecisionRequest request,
}) {
  return showAppDialog<ExtractDecisionResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('未找到游戏本体', style: TextStyle(fontSize: 15)),
        content: Text(request.message,
            style: TextStyle(
                fontSize: 12.5, color: AppColors.secondaryText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消解压'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext)
                .pop(const ExtractDecisionResult(proceed: true)),
            child: const Text('仍以此收尾'),
          ),
        ],
      );
    },
  );
}

/// ★ Phase F（scenarios_v2 §1.5）：损坏/不支持分类弹窗——解压失败时按
/// 分类报因（缺卷/CRC/不支持/通用，分类器见 extract_manager._corruptMessage），
/// 统一「继续重试 / 取消解压」两动作。重试适用补齐缺卷等场景。
/// 返回 proceed=true = 重试本层；null = 用户取消（走取消清理路径）。
Future<ExtractDecisionResult?> showCorruptDecisionDialog(
  BuildContext context, {
  required ExtractDecisionRequest request,
}) {
  return showAppDialog<ExtractDecisionResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text('解压失败（第${request.layerIndex + 1}层）',
            style: const TextStyle(fontSize: 15)),
        content: Text(request.message,
            style: TextStyle(
                fontSize: 12.5, color: AppColors.secondaryText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消解压'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext)
                .pop(const ExtractDecisionResult(proceed: true)),
            child: const Text('继续重试'),
          ),
        ],
      );
    },
  );
}

/// 解压完成确认弹窗（方案 §4.7 最终文件夹名确认 + §4.7b 删源包确认）。
/// 展示游戏本体目录名供编辑；关闭/取消 = 保持原名 + 保留源包。
Future<ExtractFinishDecision?> showExtractFinishDialog(
  BuildContext context, {
  required String extractedDir,
  required String sourceArchivePath,
}) {
  final dirName =
      extractedDir.split('/').last.split('\\').last;
  final ctrl = TextEditingController(text: dirName);
  var deleteSource = false;
  return showAppDialog<ExtractFinishDecision>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      void submit() {
        final v = ctrl.text.trim();
        Navigator.of(dialogContext).pop(ExtractFinishDecision(
          finalDirName: (v.isEmpty || v == dirName) ? null : v,
          deleteSourceArchive: deleteSource,
        ));
      }

      return StatefulBuilder(builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: const Text('解压完成', style: TextStyle(fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('确认游戏文件夹名（可编辑）：',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.secondaryText)),
              Text(extractedDir,
                  style: const TextStyle(fontSize: 11),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => submit(),
              ),
              if (sourceArchivePath.isNotEmpty) ...[
                const SizedBox(height: 10),
                InkWell(
                  onTap: () =>
                      setDialogState(() => deleteSource = !deleteSource),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: Checkbox(
                          value: deleteSource,
                          onChanged: (v) => setDialogState(
                              () => deleteSource = v ?? false),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text('删除源压缩包（默认保留）',
                          style: TextStyle(fontSize: 12.5)),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: submit,
              child: const Text('完成'),
            ),
          ],
        );
      });
    },
  );
}
