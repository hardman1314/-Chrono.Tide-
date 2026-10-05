import 'package:flutter/material.dart';

/// 看板娘身份常量。
///
/// 「时之 汐乃」是 ChronoTide 的官方虚拟形象，**官方来源资源（`kind=official`）
/// 的分享者恒为看板娘**——PB 侧把官方资源的 `owner` 指向看板娘的 users 记录
/// （见 `docs/DEV/features/explore_resource_sources_plan.md` §2.4、
/// `.workbuddy/pb_tmp/pb_kanban_02_create.py`、`.workbuddy/pb_tmp/kanban_manifest.json`）。
///
/// 头像策略（**离线优先**，2026-10-01 定案）：
/// - 客户端一律用内置资源 [assetPath]（由 `图层 14.png` 裁方 512×512 而来，
///   与 PB `users.avatar` 同一张图）；
/// - 不在客户端拉取 PB 头像，原因：
///   ① `users.listRule = id = @request.auth.id` ⟹ **普通用户查不到看板娘记录**；
///   ② PB 上传会给文件名加随机后缀（`kanban_shino_xxxxxxxxxx.png`），
///      硬编码直链在换头像后会静默失效。
/// - [pbUserId] / [pbAvatarFile] 仅作**后台与运维留档**，客户端不依赖它们。
class KanbanIdentity {
  const KanbanIdentity._();

  /// 看板娘名字（与 PB users.name 一致，勿单方面改动）
  static const String name = '时之 汐乃';

  /// 内置头像资源路径
  static const String assetPath = 'assets/images/kanban_shino.png';

  /// PB `users` 记录 id（看板娘；官方资源 `owner` 指向它）
  ///
  /// 建号记录见 `.workbuddy/pb_tmp/kanban_manifest.json`。
  static const String pbUserId = '0fw0trcd3dbmqow';

  /// PB `users.avatar` 现存文件名（换头像后会变，客户端**不**依赖）
  static const String pbAvatarFile = 'kanban_shino_oq9qmeubp0.png';

  /// 是否为看板娘本人（按昵称判定，供展示层兜底）
  static bool isKanban(String? ownerName) =>
      ownerName != null && ownerName.trim() == name;
}

/// 圆形头像：网络优先 + 内置资源兜底。
class AvatarCircle extends StatelessWidget {
  const AvatarCircle({
    super.key,
    this.imageUrl,
    this.fallbackAsset,
    this.size = 44,
    this.borderColor,
    this.borderWidth = 0,
  });

  /// 网络头像地址（可为空）
  final String? imageUrl;

  /// 内置兜底资源（可为空；为空则显示首字母占位）
  final String? fallbackAsset;

  final double size;
  final Color? borderColor;
  final double borderWidth;

  /// 看板娘专用头像（网络优先 → 内置资源兜底）
  factory AvatarCircle.kanban({
    Key? key,
    String? imageUrl,
    double size = 24,
    Color? borderColor,
    double borderWidth = 0,
  }) =>
      AvatarCircle(
        key: key,
        imageUrl: imageUrl,
        fallbackAsset: KanbanIdentity.assetPath,
        size: size,
        borderColor: borderColor,
        borderWidth: borderWidth,
      );

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF2A2A31),
        border: borderWidth > 0 && borderColor != null
            ? Border.all(color: borderColor!, width: borderWidth)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isNotEmpty
          ? Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fallback(),
              loadingBuilder: (ctx, child, progress) =>
                  progress == null ? child : _fallback(),
            )
          : _fallback(),
    );
  }

  Widget _fallback() {
    final asset = fallbackAsset;
    if (asset != null && asset.isNotEmpty) {
      return Image.asset(
        asset,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _initial(),
      );
    }
    return _initial();
  }

  Widget _initial() {
    return Center(
      child: Text(
        '汐',
        style: TextStyle(
          fontSize: size * 0.42,
          color: Colors.white70,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
