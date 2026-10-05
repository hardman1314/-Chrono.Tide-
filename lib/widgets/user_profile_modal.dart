import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../modules/auth/user_model.dart';
import 'openlist/openlist_pair_dialog.dart';
import '../services/openlist_provision.dart';
import '../services/user_cache_service.dart';
import '../services/nsfw/nsfw_settings.dart';
import 'nsfw/nsfw_mode_switch.dart';
import 'interactive_wrapper.dart';

class UserProfileModal extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onLogout;

  /// ★ 本地账号体系：本地账户态显示【登录】按钮（需求 5），点击打开
  /// 登录浮层（由 main_container 注入）。在线态为 null，显示【退出登录】。
  final VoidCallback? onLogin;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onCharge;
  final VoidCallback? onOpenBigPicture;

  /// 「对接 / 更新对接」入口（2026-10-03 层级修复）：本组件是 root Overlay
  /// 顶层 entry，恒在一切路由之上——组件内直接 showDialog 的对接窗口会被
  /// 本窗口完全遮挡。改为交宿主（main_container）编排：关用户窗口 → 弹
  /// 对接窗口 → 结束后重开。参数 = isUpdate（组件内探测的对接状态）。
  final ValueChanged<bool>? onOpenPair;
  final UserModel? user;
  const UserProfileModal(
      {super.key,
      required this.onClose,
      required this.onLogout,
      this.onLogin,
      this.onOpenSettings,
      this.onCharge,
      this.onOpenBigPicture,
      this.onOpenPair,
      this.user});

  @override
  State<UserProfileModal> createState() => _UserProfileModalState();
}

class _UserProfileModalState extends State<UserProfileModal> {
  /// NSFW 设置是磁盘持久化的，首次读取前 `enabled` 只是内存默认值。
  /// `load()` 幂等（内部 `_loaded` 守卫），这里先跑一次，保证快捷开关
  /// 打开面板时显示的就是真实配置；后续变化通过 ChangeNotifier 同步。
  @override
  void initState() {
    super.initState();
    NsfwSettings.instance.load();
    // OpenList 半移植化：在线态才需要「对接」按钮，异步探测是否已对接。
    // ⚠️ 本组件是 Overlay 快照（不随外部状态重建），任何状态变化都必须
    //    组件内 setState 自刷新（v1.4 教训）。
    _loadPairState();
  }

  /// null = 探测中（不显示对接按钮，避免闪现）
  bool? _olPaired;

  Future<void> _loadPairState() async {
    final paired = await OpenListProvision.isPaired();
    if (mounted) setState(() => _olPaired = paired);
  }

  Future<void> _openPair() async {
    // 已对接时是「更新对接」语义，弹窗文案随之切换
    // 2026-10-03：宿主注入了编排回调 → 走「关用户窗口→弹窗→重开」路径
    //（本窗口钉顶，组件内 showDialog 会被遮挡）；未注入则兜底旧行为。
    if (widget.onOpenPair != null) {
      widget.onOpenPair!(_olPaired == true);
      return;
    }
    final result = await OpenListPairDialog.show(context, isUpdate: _olPaired == true);
    if (result == OpenListPairResult.paired && mounted) {
      setState(() => _olPaired = true);
    }
  }

  String get _displayName => widget.user?.name ?? 'Kiyoko';

  /// 本地账号体系：本地账户态的 UID 行显示「本地用户」+ 登录引导
  /// （推荐默认：UI 显示用户自填名字，「匿名」仅描述云端视角）。
  bool get _isLocal => widget.user?.isLocalAccount ?? false;

  String get _displayUid {
    if (_isLocal) return '本地用户 · 登录后可获取与分享资源';
    return widget.user?.id.isNotEmpty == true
        ? 'UID: ${widget.user!.id}'
        : 'UID: --';
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
        '[USER_PROFILE] 加载用户信息：昵称=${_displayName}，UID=${_displayUid}，头像状态=${widget.user?.hasAvatar == true ? "已加载" : "无头像"}');

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 500,
          // v2.5: 600 → 480 —— 原 77/56 的巨型空隙让窗口十分空旷，压缩为
          // 统一 28 间距 + 底部留白 49 → 24，窗口高度随内容收紧（组件
          // 间距仍保持呼吸感，但不再大片留白）。
          height: 480,
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 1.6),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 22, 22, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              const SizedBox(height: 28),
              _buildChargeSection(),
              const SizedBox(height: 28),
              _buildBottomButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      width: 449,
      // v2.2: 80 → 96，为按钮下方的 NSFW 快捷开关腾出竖向空间
      // （下方 77 的间距同步改为 61，总高不变）
      height: 96,
      // v1.4：扁平 flex 结构 —— 原为「Row(spaceBetween)[Row(min)[头像,
      // Expanded(名字列)], 右列]」，内层 Row 被 Expanded 撑满 449 后外层
      // 总宽必然溢出，spaceBetween 负间隙把右列拉回，与本地态长 UID 文案
      // 叠字（真机报告）。扁平化后 Expanded 自动让位于右列，永不重叠。
      child: Row(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.placeholderCover,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border, width: 1.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowColor,
                  offset: Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
            ),
            padding: const EdgeInsets.all(3.5),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sidebarBackground,
                border: Border.all(color: AppColors.border, width: 1),
              ),
              alignment: Alignment.center,
              child: ClipOval(
                child: SizedBox(
                  width: 71,
                  height: 71,
                  child: UserCacheService.buildUserAvatar(
                    size: 71,
                    defaultAvatar: _buildDefaultAvatar(),
                    avatarBytes: widget.user?.avatarBytes,
                    avatarUrl: widget.user?.avatarUrl,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 36,
                    height: 40 / 36,
                    letterSpacing: 1.99,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _displayUid,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    height: 20 / 14,
                    letterSpacing: 0.7,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 右上角竖排：第一行窗口按钮（大屏入口 + 关闭），
          // 第二行 NSFW 三档快捷开关（关闭 / 纯净 / 工作，v2.1.15）。
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // v2.5: 对接入口从底栏胶囊移到右上角图标行（大屏模式左侧），
                  //       同款 32x32 小图标按钮。仅在线账号显示（本地账户与
                  //       云端服务无关）；探测中不显示，避免闪现。
                  //       未对接 = 链接图标「对接」；已对接 = 同步图标
                  //       「更新对接」（后续服务更新入口，语义见 pair 弹窗）。
                  if (!_isLocal && _olPaired != null) ...[
                    _HeaderIconButton(
                      icon: _olPaired == true
                          ? Icons.sync_rounded
                          : Icons.link_rounded,
                      onTap: _openPair,
                      tooltip: _olPaired == true ? '更新对接' : '对接',
                    ),
                    const SizedBox(width: 8),
                  ],
                  // v1.2: 大屏模式入口改为右上角小图标按钮,与关闭按钮并列
                  //       不再作为底部第三按钮挤压原布局
                  if (widget.onOpenBigPicture != null) ...[
                    _HeaderIconButton(
                      icon: Icons.fullscreen_rounded,
                      onTap: widget.onOpenBigPicture!,
                      tooltip: '大屏模式 (F11)',
                    ),
                    const SizedBox(width: 8),
                  ],
                  _HeaderIconButton(
                    icon: Icons.close,
                    onTap: widget.onClose,
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const _NsfwQuickToggle(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChargeSection() {
    return Container(
      width: 450,
      // v2.5: minHeight 186 → 200 —— 窗口高 480 下 charge 吃满剩余空间
      // （≈227），Expanded 文字区自然形成 ≈23px 呼吸空隙，卡片饱满不空旷
      constraints: const BoxConstraints(minHeight: 200),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowColor,
            offset: const Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SvgPicture.asset('assets/images/lightning_icon.svg',
                  width: 18, height: 18),
              const SizedBox(width: 8),
              Text(
                '为小站充电',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  height: 27 / 18,
                  color: AppColors.dangerRed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Text(
              '如果 Chrono Tide 给你带来了快乐，请不要吝啬地用零花钱喂饱开发者吧！您的支持是我们持续为纯爱发光发热的动力～（´,,•ω•,,）♡',
              style: TextStyle(
                fontSize: 14,
                height: 22.75 / 14,
                color: AppColors.primaryText,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildChargeButton(),
        ],
      ),
    );
  }

  Widget _buildChargeButton() {
    return InteractiveWrapper(
      onTap: widget.onCharge ?? () {},
      child: Container(
        width: 414,
        height: 55,
        decoration: BoxDecoration(
          color: const Color(0xFFFFE6EA),
          border: Border.all(color: AppColors.dangerRed, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.dangerRed,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset('assets/images/charge_lightning_icon.svg',
                width: 18, height: 18),
            const SizedBox(width: 8),
            Text(
              '立刻为服务器充能',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                height: 28 / 18,
                color: AppColors.dangerRed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomButtons() {
    // v1.2: 大屏模式入口已移至右上角图标按钮,底部恢复原两按钮布局
    // v1.3: 本地账号体系双态 —— 本地账户显示【登录】（accent 强调，引导
    //       注册登录，需求 5）；在线账号保持【退出登录】。
    // v2.5: 对接入口移到右上角图标行（大屏模式左侧），底栏保持恒定双按钮。
    return SizedBox(
      width: 449,
      height: 55,
      child: Row(
        children: [
          Expanded(
            child: _ProfileButton(
              label: '个人设置',
              onTap: widget.onOpenSettings ?? () {},
              baseColor: AppColors.selectedAccent,
              textColor: AppColors.primaryText,
              shadowColor: AppColors.primaryText,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _isLocal
                ? _ProfileButton(
                    label: '登录',
                    onTap: widget.onLogin ?? () {},
                    baseColor: AppColors.infoBlue,
                    textColor: AppColors.primaryText,
                    shadowColor: AppColors.primaryText,
                  )
                : _ProfileButton(
                    label: '退出登录',
                    onTap: widget.onLogout,
                    baseColor: AppColors.background,
                    textColor: AppColors.border,
                    shadowColor: AppColors.border,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Center(
      child: SvgPicture.asset(
        'assets/images/user_avatar_icon.svg',
        width: 28,
        height: 28,
        colorFilter: ColorFilter.mode(AppColors.secondaryText, BlendMode.srcIn),
      ),
    );
  }
}

/// NSFW 快捷开关（v2.1.15 三档版：关闭 / 纯净 / 工作）。
///
/// 渲染与交互全部下沉到 [NsfwModeSwitch]，这里只负责把它挂到右上角。
/// 数据源与设置页是同一个 `NsfwSettings.instance`（ChangeNotifier），
/// 任一侧改动都会即时同步到另一侧——不存在两份状态。
class _NsfwQuickToggle extends StatelessWidget {
  const _NsfwQuickToggle();

  @override
  Widget build(BuildContext context) => const NsfwModeSwitch();
}

class _ProfileButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final Color baseColor;
  final Color textColor;
  final Color shadowColor;

  const _ProfileButton({
    required this.label,
    required this.onTap,
    required this.baseColor,
    required this.textColor,
    required this.shadowColor,
  });

  @override
  State<_ProfileButton> createState() => _ProfileButtonState();
}

class _ProfileButtonState extends State<_ProfileButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _hovered = true),
        onTapUp: (_) => setState(() => _hovered = false),
        onTapCancel: () => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 55,
          decoration: BoxDecoration(
            color: _hovered ? AppColors.cardHoverBg : widget.baseColor,
            border: Border.all(
              color: _hovered ? AppColors.border : AppColors.borderLight,
              width: _hovered ? 2.0 : 1.6,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: AppColors.shadowColor,
                      offset: const Offset(0, 2),
                      blurRadius: 8,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: widget.shadowColor,
                      offset: const Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 18,
              height: 28 / 18,
              color: widget.textColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 用户窗口右上角小图标按钮 (v1.2)
///
/// 32x32 带悬停态的工具图标按钮,用于关闭按钮与大屏模式入口,
/// 复用同一视觉规范避免重复代码。
class _HeaderIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _hovered
                  ? AppColors.primaryText.withOpacity(0.1)
                  : AppColors.background,
              border: Border.all(
                color: _hovered
                    ? AppColors.border
                    : AppColors.border.withOpacity(0.5),
                width: _hovered ? 2 : 1.6,
              ),
              borderRadius: BorderRadius.circular(5),
              boxShadow: [
                BoxShadow(
                  color: AppColors.border,
                  offset: _hovered ? const Offset(1, 2) : const Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 18,
              color: _hovered ? AppColors.primaryText : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}
