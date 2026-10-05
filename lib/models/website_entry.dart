/// 网址收藏条目（探索大厅 · 板块④网站管理）
///
/// 持久化于 `data/websites.json`（见 [WebsiteBookmarkService]）。
class WebsiteEntry {
  final String id;
  String title;
  String url;
  String note;

  /// 创建时间（毫秒时间戳，仅用于排序留痕）
  final int createdAtMs;

  /// 站点图标（本地文件路径）
  ///
  /// 来源二选一：①自动识别网址 favicon 后缓存到本地；②用户上传图片。
  /// 空串 = 未设置（UI 回落首字母渐变徽章）；文件不存在时同样回落。
  /// ⚠️ 存本地路径而非远程 URL：面板展示不依赖网络，也避免站点防盗链。
  String iconPath;

  WebsiteEntry({
    required this.id,
    required this.title,
    required this.url,
    this.note = '',
    this.iconPath = '',
    required this.createdAtMs,
  });

  factory WebsiteEntry.fromJson(Map<String, dynamic> json) {
    return WebsiteEntry(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '未命名站点',
      url: json['url'] as String? ?? '',
      note: json['note'] as String? ?? '',
      iconPath: json['icon_path'] as String? ?? '',
      createdAtMs: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'note': note,
        'icon_path': iconPath,
        'created_at': createdAtMs,
      };

  /// 主机名显示（url → host），解析失败回退原串
  String get host {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    return host.isNotEmpty ? host : url;
  }
}
