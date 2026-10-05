/// PocketBase filter 字符串字面量转义工具
///
/// PocketBase 的 filter 语法中，字符串字面量用单引号包裹，反斜杠 `\` 为转义符。
/// 直接拼接用户输入会导致两类问题：
///
/// 1. **注入**：输入 `x' || (某个字段名 ~ 'a') || '` 之类的载荷可以改写过滤条件，
///    攻击者可据此做布尔盲注，探测集合中其他字段（含关联字段）的取值；
/// 2. **语法错误**：输入以 `\` 结尾时，尾部的反斜杠会转义掉闭合单引号，
///    导致整个 filter 表达式解析失败（旧的只转义单引号的实现存在此问题）。
///
/// 因此必须**先转义反斜杠、再转义单引号**，顺序不可颠倒。
/// 另加控制字符清理、长度截断与空串短路，保证 filter 表达式始终合法且有界。
class PbFilter {
  const PbFilter._();

  /// 字符串字面量的最大原始长度（截断前）
  ///
  /// 用于限制 filter 表达式长度，避免超长输入拖慢服务端或触发请求限制。
  /// 64 字符已覆盖绝大多数游戏标题与用户名，长标题会被截断为前缀匹配。
  static const int maxLiteralLength = 64;

  /// 把任意用户输入转成可以安全放进单引号的字符串字面量内容
  ///
  /// 处理顺序：清理控制字符 → 截断（先截断后转义，避免截断转义序列）
  /// → 转义反斜杠 → 转义单引号。返回空串表示"无有效输入"，调用方应跳过过滤。
  static String escapeLiteral(String value) {
    if (value.isEmpty) return '';

    // 换行/回车/制表符等控制字符会破坏单行 filter 表达式，统一折叠为空格
    var safe = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    if (safe.isEmpty) return '';

    // 先按原始长度截断：若在转义后截断，可能把 `\\` 或 `\'` 截成半截，
    // 反而制造出未闭合的转义序列
    if (safe.length > maxLiteralLength) {
      safe = safe.substring(0, maxLiteralLength);
      // 避免截断代理对（emoji 等）产生半个字符
      final lastUnit = safe.codeUnitAt(safe.length - 1);
      if (safe.length > 1 && lastUnit >= 0xD800 && lastUnit <= 0xDBFF) {
        safe = safe.substring(0, safe.length - 1);
      }
      safe = safe.trimRight();
    }
    if (safe.isEmpty) return '';

    // ★ 顺序不可颠倒：先反斜杠，再单引号
    return safe.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  }

  /// 构造 `field ~ 'keyword'` 的模糊匹配片段
  ///
  /// [keyword] 为空或只含控制字符时返回 null，调用方应理解为"不加过滤条件"。
  static String? containsFilter(String field, String keyword) {
    final escaped = escapeLiteral(keyword);
    if (escaped.isEmpty) return null;
    return "$field ~ '$escaped'";
  }

  /// 构造 CT 探索库游戏名称多字段模糊搜索 filter（2026-10-05）
  ///
  /// 主标题 / 日文原名 / 英文名 / 繁中别名 四字段 OR——仅 title 过滤时
  /// 搜别名（如日文原名「美少女万華鏡」）会 0 命中（实测），别名检索
  /// 是探索库搜索可用的前提。与 SDK 内 CTService._nameSearchFilter 同规则
  /// （SDK 不依赖主程序代码，故两处各自内联）。
  ///
  /// [keyword] 为空或只含控制字符时返回 null，调用方应理解为"不加过滤条件"。
  static String? nameSearchFilter(String keyword) {
    final escaped = escapeLiteral(keyword);
    if (escaped.isEmpty) return null;
    return "(title ~ '$escaped' || originalTitle ~ '$escaped' || "
        "englishTitle ~ '$escaped' || traditionalChineseTitle ~ '$escaped')";
  }

  /// 构造 `field = 'value'` 的精确匹配片段
  ///
  /// [value] 为空时返回 null（空值不应参与精确匹配）。
  static String? equalsFilter(String field, String value) {
    final escaped = escapeLiteral(value);
    if (escaped.isEmpty) return null;
    return "$field='$escaped'";
  }
}
