/// KUNGAL 发售月历数据模型（探索大厅 · 板块①数据源）
///
/// 字段口径与 KUNGAL 前端 shared/types/galgame.ts 的 GalgameCard 对齐
/// （kun-galgame-forum-master 本地参考仓库），只取月历展示所需子集。
/// 接口为社区公开只读端点，解析全程防御性：字段缺失 / 类型漂移不抛异常，
/// 坏条目降级为空字符串字段而非崩溃。
class KungalCalendarGame {
  final int id;
  final String name; // 中文译名（KUNGAL 主显示名）
  final String nameOriginal; // 日文原名
  final String company;
  final String releaseDate; // 原始 ISO 串，可能为空
  final String releasePrecision; // day / month / year / tba / unknown
  final String contentLimit; // sfw / nsfw
  final String portraitUrl; // 5:7 封面直链（webp）
  final double? rating; // KUNGAL 评分（0-10，可空）
  final int? ratingCount;

  const KungalCalendarGame({
    required this.id,
    required this.name,
    required this.nameOriginal,
    required this.company,
    required this.releaseDate,
    required this.releasePrecision,
    required this.contentLimit,
    required this.portraitUrl,
    this.rating,
    this.ratingCount,
  });

  bool get isNsfw => contentLimit.toLowerCase().trim() != 'sfw';

  /// 主显示名：译名优先，译名缺失回落原名
  String get displayName => name.isNotEmpty ? name : nameOriginal;

  /// KUNGAL 站内详情页（id 无效时为空串，UI 层不展示外跳）
  String get detailUrl => id > 0 ? 'https://www.kungal.com/galgame/$id' : '';

  /// 「day」精度的确切发售日本地日期；month/year/tba/unknown 返回 null
  /// （月历网格只挂 day 精度，其余进「待定」桶）
  DateTime? get exactDate =>
      releasePrecision == 'day' ? parseIsoDate(releaseDate) : null;

  /// 标题规范化：小写 + 全角 ASCII 折叠半角 + 去全部 Unicode 标点与空白
  /// （含全角空格），用于与本地探索库标题的精确匹配
  /// （「谜路2 人鱼传说」==「谜路2人鱼传说」、「ＡＢＣ」==「ABC」）
  static String normalizeTitle(String s) {
    final folded = StringBuffer();
    for (final code in s.runes) {
      // 全角 ASCII 区（U+FF01–U+FF5E，含全角字母/数字/标点）折叠为半角
      if (code >= 0xFF01 && code <= 0xFF5E) {
        folded.writeCharCode(code - 0xFEE0);
      } else {
        folded.writeCharCode(code);
      }
    }
    return folded
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\u3000\p{P}\p{S}]', unicode: true), '');
  }

  /// 与本地库匹配用的规范化键
  String get normalizedKey => normalizeTitle(displayName);
  String get normalizedOriginalKey => normalizeTitle(nameOriginal);

  /// ISO 日期前缀（'YYYY-MM-DD...'）→ 本地零时日期；
  /// 带正则前缀校验 + 回读验证（DateTime.tryParse 会把 '9999-99-99'
  /// 进位解析成合法日期，见 calendar_grid_test 同款用例）
  static DateTime? parseIsoDate(String? iso) {
    if (iso == null || iso.length < 10) return null;
    final head = iso.substring(0, 10);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(head)) return null;
    final parsed = DateTime.tryParse(head);
    if (parsed == null) return null;
    final rebuilt =
        '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
    if (rebuilt != head) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  factory KungalCalendarGame.fromJson(Map<String, dynamic> j) {
    return KungalCalendarGame(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: (j['name'] as String?) ?? '',
      nameOriginal: (j['name_original'] as String?) ?? '',
      company: (j['company'] as String?) ?? '',
      releaseDate: (j['release_date'] as String?) ?? '',
      releasePrecision: (j['release_precision'] as String?) ?? 'unknown',
      contentLimit: (j['content_limit'] as String?) ?? 'sfw',
      portraitUrl: (j['effective_portrait_url'] as String?) ?? '',
      rating: (j['rating'] as num?)?.toDouble(),
      ratingCount: (j['rating_count'] as num?)?.toInt(),
    );
  }
}

/// 单月月历数据（对应 /api/galgame/calendar 的 data）
class KungalMonthData {
  final String month; // 'YYYY-MM'
  final List<KungalCalendarGame> items;
  final String? minMonth; // KUNGAL meta：可回退的最早月份
  final String? maxMonth; // KUNGAL meta：可前进的最晚月份
  final bool hasPrev;
  final bool hasNext;

  const KungalMonthData({
    required this.month,
    required this.items,
    this.minMonth,
    this.maxMonth,
    this.hasPrev = true,
    this.hasNext = true,
  });

  /// day 精度条目按日期分桶（月历网格计数用）
  Map<DateTime, List<KungalCalendarGame>> get byDate {
    final map = <DateTime, List<KungalCalendarGame>>{};
    for (final g in items) {
      final d = g.exactDate;
      if (d != null) map.putIfAbsent(d, () => []).add(g);
    }
    return map;
  }

  /// 本月「待定」桶：精度非 day（month/tba/unknown）或无日期的条目
  List<KungalCalendarGame> get bucket =>
      items.where((g) => g.exactDate == null).toList();

  factory KungalMonthData.fromApi(String fallbackMonth, Map<String, dynamic> d) {
    final items = (d['items'] as List?)
            ?.whereType<Map>()
            .map((m) =>
                KungalCalendarGame.fromJson(Map<String, dynamic>.from(m)))
            .toList() ??
        const <KungalCalendarGame>[];
    final meta = d['meta'];
    String? metaStr(String k) =>
        meta is Map ? (meta[k] as String?) : null;
    bool metaBool(String k) => meta is Map ? (meta[k] == true) : true;
    return KungalMonthData(
      month: (d['month'] as String?) ?? fallbackMonth,
      items: items,
      minMonth: metaStr('min_month'),
      maxMonth: metaStr('max_month'),
      hasPrev: metaBool('has_prev'),
      hasNext: metaBool('has_next'),
    );
  }
}
