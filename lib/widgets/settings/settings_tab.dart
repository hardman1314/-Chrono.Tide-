/// 设置窗口的顶层分类。
///
/// 2026-09-08 IA 重构：由 3 个（个人资料 / 偏好设置 / 关于应用）拆分为 6 个。
///
/// 原「偏好设置」页内 9 张卡片按主题域分散到「外观 / 游戏与启动 / 网络与存储 /
/// 内容保护」四个页，偏好设置页本身取消。
///
/// 详见 `docs/DEV/features/settings_preference_ia_redesign_plan.md`。
enum SettingsTab {
  profile,
  appearance,
  gameLaunch,
  bigPicture,
  networkStorage,
  contentSafety,
  about,
}

/// 侧边栏每一项所需的展示元数据。
///
/// 图标复用 `assets/images/` 下既有资源，未新增图标文件；若后续补充专属图标，
/// 只改本文件的 [SettingsTabMeta.items] 即可。
class SettingsTabMeta {
  const SettingsTabMeta({
    required this.tab,
    required this.label,
    required this.iconPath,
  });

  final SettingsTab tab;
  final String label;
  final String iconPath;

  /// 侧边栏展示顺序（即 tab 顺序）。
  static const List<SettingsTabMeta> items = <SettingsTabMeta>[
    SettingsTabMeta(
      tab: SettingsTab.profile,
      label: '个人资料',
      iconPath: 'assets/images/tab_profile_icon.svg',
    ),
    SettingsTabMeta(
      tab: SettingsTab.appearance,
      label: '外观',
      iconPath: 'assets/images/tab_preference_icon.svg',
    ),
    SettingsTabMeta(
      tab: SettingsTab.gameLaunch,
      label: '游戏与启动',
      iconPath: 'assets/images/lightning_icon.svg',
    ),
    SettingsTabMeta(
      tab: SettingsTab.bigPicture,
      label: '大屏模式',
      // 图标复用既有资源（未新增图标文件）；后续如需专属图标只改本行
      iconPath: 'assets/images/library_icon_new.svg',
    ),
    SettingsTabMeta(
      tab: SettingsTab.networkStorage,
      label: '网络与存储',
      iconPath: 'assets/images/download_icon.svg',
    ),
    SettingsTabMeta(
      tab: SettingsTab.contentSafety,
      label: '内容保护',
      iconPath: 'assets/images/lock_icon.svg',
    ),
    SettingsTabMeta(
      tab: SettingsTab.about,
      label: '关于应用',
      iconPath: 'assets/images/tab_about_icon.svg',
    ),
  ];

  /// 取某一 tab 的元数据。
  static SettingsTabMeta of(SettingsTab tab) =>
      items.firstWhere((SettingsTabMeta e) => e.tab == tab);
}
