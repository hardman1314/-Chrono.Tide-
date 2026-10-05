import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/website_entry.dart';
import '../../services/website_bookmark_service.dart';
import '../../services/website_icon_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../interactive_wrapper.dart';
import 'hall_section_shell.dart';
import 'hall_visuals.dart';

/// 板块④：网站管理
///
/// 支持添加/编辑/删除网址与站点信息（持久化 data/websites.json），
/// 点击卡片经系统默认浏览器直达（零依赖系统调用 + http/https 白名单）。
class WebsiteSection extends StatefulWidget {
  const WebsiteSection({super.key});

  @override
  State<WebsiteSection> createState() => _WebsiteSectionState();
}

class _WebsiteSectionState extends State<WebsiteSection> {
  WebsiteBookmarkService get _svc => WebsiteBookmarkService.instance;

  @override
  void initState() {
    super.initState();
    // 加载完成后再补图标：条目为空（如测试环境）时 ensureIcons 不会发起
    // 任何网络请求
    _svc.load().then((_) => _svc.ensureIcons());
  }

  Future<void> _openEditDialog([WebsiteEntry? entry]) async {
    final titleCtrl = TextEditingController(text: entry?.title ?? '');
    final urlCtrl = TextEditingController(text: entry?.url ?? '');
    final noteCtrl = TextEditingController(text: entry?.note ?? '');
    // 图标本地路径放在 Notifier 里：StatefulBuilder 每次 rebuild 都会重跑
    // builder，普通局部变量会被重置回初始值（用户选好的图标会丢失）
    final iconPath = ValueNotifier<String>(entry?.iconPath ?? '');
    final fetching = ValueNotifier<bool>(false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          String? errorText;
          return AlertDialog(
            backgroundColor: AppColors.background,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              side: BorderSide(color: AppColors.border),
            ),
            title: Text(entry == null ? '添加站点' : '编辑站点',
                style: AppStyles.titleSmall),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 图标区：预览 + 自动获取 / 上传 / 清除
                  Row(
                    children: [
                      ValueListenableBuilder<String>(
                        valueListenable: iconPath,
                        builder: (_, path, __) => _SiteIcon(
                          path: path,
                          title: titleCtrl.text.isNotEmpty
                              ? titleCtrl.text
                              : (entry?.title ?? '?'),
                          size: 34,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('站点图标', style: AppStyles.microCaption),
                            const SizedBox(height: 4),
                            ValueListenableBuilder<bool>(
                              valueListenable: fetching,
                              builder: (_, busy, __) => Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  _IconAction(
                                    label: busy ? '获取中…' : '自动获取',
                                    icon: Icons.auto_awesome_rounded,
                                    onTap: busy
                                        ? null
                                        : () async {
                                            final url =
                                                WebsiteBookmarkService
                                                    .normalizeUrl(
                                                        urlCtrl.text);
                                            if (url == null) {
                                              setDialogState(() => errorText =
                                                  '先填有效网址再获取图标');
                                              return;
                                            }
                                            fetching.value = true;
                                            // 手动点按 = 允许重试（清失败标记）
                                            WebsiteIconService.instance
                                                .clearFailure(url);
                                            final got =
                                                await WebsiteIconService
                                                    .instance
                                                    .fetchSiteIcon(url);
                                            fetching.value = false;
                                            if (got != null) {
                                              iconPath.value = got;
                                            } else {
                                              setDialogState(() => errorText =
                                                  '未识别到可用图标，可手动上传');
                                            }
                                          },
                                  ),
                                  _IconAction(
                                    label: '上传图片',
                                    icon: Icons.image_rounded,
                                    onTap: () async {
                                      final got = await WebsiteIconService
                                          .instance
                                          .pickAndSaveLocalIcon();
                                      if (got != null) iconPath.value = got;
                                    },
                                  ),
                                  _IconAction(
                                    label: '清除',
                                    icon: Icons.clear_rounded,
                                    onTap: () => iconPath.value = '',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: titleCtrl,
                    style: AppStyles.bodyMedium,
                    decoration: const InputDecoration(
                      labelText: '站点名称',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: urlCtrl,
                    style: AppStyles.bodyMedium,
                    decoration: InputDecoration(
                      labelText: '网址（http/https）',
                      isDense: true,
                      errorText: errorText,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: noteCtrl,
                    style: AppStyles.bodyMedium,
                    decoration: const InputDecoration(
                      labelText: '备注（可选）',
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              if (entry != null)
                TextButton(
                  onPressed: () async {
                    await _svc.remove(entry.id);
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: Text('删除',
                      style: AppStyles.labelMedium
                          .copyWith(color: AppColors.dangerRed)),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('取消', style: AppStyles.labelMedium),
              ),
              TextButton(
                onPressed: () {
                  final normalized =
                      WebsiteBookmarkService.normalizeUrl(urlCtrl.text);
                  if (normalized == null) {
                    setDialogState(
                        () => errorText = '网址无效，仅支持 http/https');
                    return;
                  }
                  if (entry == null) {
                    _svc.add(
                        title: titleCtrl.text,
                        url: urlCtrl.text,
                        note: noteCtrl.text,
                        iconPath: iconPath.value);
                  } else {
                    _svc.update(entry,
                        title: titleCtrl.text,
                        url: urlCtrl.text,
                        note: noteCtrl.text,
                        iconPath: iconPath.value);
                  }
                  Navigator.of(ctx).pop();
                },
                child: Text('保存',
                    style: AppStyles.labelMedium
                        .copyWith(color: AppColors.brandBlue)),
              ),
            ],
          );
        },
      ),
    );
    titleCtrl.dispose();
    urlCtrl.dispose();
    noteCtrl.dispose();
    iconPath.dispose();
    fetching.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _svc,
      builder: (context, _) {
        final entries = _svc.entries;
        return HallSectionShell(
          title: '常用站点',
          subtitle: '点击直达浏览器',
          icon: Icons.public_rounded,
          iconAccent: AppColors.successGreen,
          engCaption: 'QUICK LINKS',
          trailing: InteractiveWrapper(
            onTap: () => _openEditDialog(),
            hoverScale: 1.06,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: AppColors.border),
                color: AppColors.buttonBackground,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded,
                      size: 13, color: AppColors.primaryText),
                  const SizedBox(width: 2),
                  Text('添加', style: AppStyles.microCaption),
                ],
              ),
            ),
          ),
          child: entries.isEmpty
              ? const HallEmptyHint(
                  text: '还没有收藏站点，点右上角「添加」',
                  icon: Icons.public_rounded,
                )
              : HallHScroll(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.zero,
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) =>
                        _SiteCard(entry: entries[i], onEdit: _openEditDialog),
                  ),
                ),
        );
      },
    );
  }
}

/// 单个站点卡片：点击直达浏览器，角落菜单可编辑/删除
class _SiteCard extends StatelessWidget {
  final WebsiteEntry entry;
  final void Function(WebsiteEntry) onEdit;

  const _SiteCard({required this.entry, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    // 简介 hover 显示完整内容（与设置页超分预设卡片同款 Tooltip 参数）
    final card = InteractiveWrapper(
      onTap: () => WebsiteBookmarkService.openExternal(entry.url),
      child: Container(
        width: 152,
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          color: AppColors.isDark
              ? Colors.white.withOpacity(0.035)
              : Colors.white.withOpacity(0.5),
          borderRadius: BorderRadius.circular(AppRadius.md + 2),
          border: Border.all(
            color: AppColors.isDark
                ? Colors.white.withOpacity(0.07)
                : AppColors.titleBrown.withOpacity(0.12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                _SiteIcon(path: entry.iconPath, title: entry.title, size: 20),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    entry.title,
                    style: AppStyles.titleSmall.copyWith(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _CardMenu(entry: entry, onEdit: onEdit),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 27),
              child: Text(
                entry.note.isNotEmpty ? entry.note : entry.host,
                style: AppStyles.microCaption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
    // 有简介时：鼠标停留显示完整内容（超分预设卡片同款 Tooltip）
    final note = entry.note.trim();
    if (note.isEmpty) return card;
    return Tooltip(
      message: note,
      preferBelow: true,
      waitDuration: const Duration(milliseconds: 500),
      textStyle: const TextStyle(fontSize: 12, color: Colors.white),
      decoration: BoxDecoration(
        color: AppColors.primaryText,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: card,
    );
  }
}

/// 编辑弹窗里的图标操作按钮（自动获取 / 上传 / 清除）
class _IconAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _IconAction({
    required this.label,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InteractiveWrapper(
      onTap: onTap,
      hoverScale: 1.04,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: enabled ? AppColors.border : AppColors.borderLight,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 11,
                color: enabled
                    ? AppColors.primaryText
                    : AppColors.placeholderText),
            const SizedBox(width: 3),
            Text(
              label,
              style: AppStyles.microCaption.copyWith(
                color:
                    enabled ? AppColors.primaryText : AppColors.placeholderText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 站点图标：有图标文件用图标（自动识别缓存或用户上传），
/// 缺失/损坏时回落首字母渐变徽章（[HallLetterAvatar]）。
///
/// ⚠️ 图标统一是本地路径（[WebsiteEntry.iconPath]）：面板展示不依赖网络，
/// 也规避站点防盗链。
class _SiteIcon extends StatelessWidget {
  final String path;

  /// 图标缺失时用于生成首字母徽章的标题
  final String title;
  final double size;

  const _SiteIcon({
    required this.path,
    required this.title,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    final file = path.isEmpty ? null : File(path);
    if (file != null && file.existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.3),
        child: Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) =>
              HallLetterAvatar(title: title, size: size),
        ),
      );
    }
    return HallLetterAvatar(title: title, size: size);
  }
}

class _CardMenu extends StatelessWidget {
  final WebsiteEntry entry;
  final void Function(WebsiteEntry) onEdit;

  const _CardMenu({required this.entry, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz_rounded,
          size: 14, color: AppColors.secondaryText),
      padding: EdgeInsets.zero,
      splashRadius: 12,
      color: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: AppColors.border),
      ),
      onSelected: (value) {
        if (value == 'open') {
          WebsiteBookmarkService.openExternal(entry.url);
        } else if (value == 'edit') {
          onEdit(entry);
        } else if (value == 'remove') {
          WebsiteBookmarkService.instance.remove(entry.id);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'open',
          height: 34,
          child: Text('打开', style: AppStyles.labelMedium),
        ),
        PopupMenuItem(
          value: 'edit',
          height: 34,
          child: Text('编辑', style: AppStyles.labelMedium),
        ),
        PopupMenuItem(
          value: 'remove',
          height: 34,
          child: Text('删除',
              style:
                  AppStyles.labelMedium.copyWith(color: AppColors.dangerRed)),
        ),
      ],
    );
  }
}
