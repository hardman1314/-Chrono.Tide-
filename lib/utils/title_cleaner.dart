import 'package:path/path.dart' as p;

/// 游戏标题清洗工具
///
/// 从文件夹名中提取干净的游戏标题，移除汉化组前缀、版本号、语言标记等干扰字符。
/// 提取自 auto_import_pipeline._inferTitle，供批量导入复用。
///
/// 清洗规则（按优先级）：
/// 1. 移除前缀方括号 [汉化组名] / 【汉化组名】
/// 2. 移除末尾括号内容 (xxx) / （xxx） / [xxx] / 【xxx】
/// 3. 移除版本号后缀 v1.2.3 / Ver1.23
/// 4. 移除常见后缀标记 chs/cht/cn/en/jp/汉化/中文/简体/繁体/破解/重制/remake/hd
/// 5. 移除末尾下划线/点/空格/横线
class TitleCleaner {
  TitleCleaner._();

  /// 从目录路径中提取并清洗游戏标题
  ///
  /// [dirPath] 游戏目录的完整路径
  /// 返回清洗后的标题（若清洗后为空则返回原始 basename）
  static String cleanFromDirPath(String dirPath) {
    final basename = p.basename(dirPath);
    return clean(basename);
  }

  /// 清洗游戏标题字符串
  ///
  /// [name] 原始标题（文件夹名或文件名）
  /// 返回清洗后的标题（若清洗后为空则返回原始名称）
  static String clean(String name) {
    String cleaned = name;

    // 1. 移除前缀方括号 [xxx] 或 【xxx】
    // 匹配开头的 [非]或【非】 后跟实际标题
    cleaned = cleaned.replaceFirst(RegExp(r'^[\[【][^\]】]*[\]】]\s*'), '');

    // 2. 移除末尾括号内容（支持中文括号）
    // 末尾 (xxx) 或 （xxx）
    var parenMatch = RegExp(r'[\(（][^\)）]*[\)）]\s*$').firstMatch(cleaned);
    if (parenMatch != null) {
      cleaned = cleaned.substring(0, parenMatch.start).trim();
    }
    // 末尾 [xxx] 或 【xxx】
    var bracketMatch = RegExp(r'[\[【][^\]】]*[\]】]\s*$').firstMatch(cleaned);
    if (bracketMatch != null) {
      cleaned = cleaned.substring(0, bracketMatch.start).trim();
    }

    // 3. 移除版本号后缀：v1.2.3 / Ver1.23 / v1.23 / Ver.1.23
    cleaned = cleaned.replaceFirst(
        RegExp(r'\s*[Vv]er?\.?\s*\d+(\.\d+)*\s*$', caseSensitive: false), '');

    // 4. 移除常见后缀标记
    cleaned = cleaned.replaceFirst(
        RegExp(
            r'\s*[_\-]?\s*(chs|cht|cn|en|jp|汉化|中文|简体|繁体|破解|重制|remake|hd)\s*$',
            caseSensitive: false),
        '');

    // 5. 移除末尾下划线/点/空格
    while (cleaned.isNotEmpty &&
        (cleaned.endsWith('_') ||
            cleaned.endsWith('.') ||
            cleaned.endsWith(' ') ||
            cleaned.endsWith('-'))) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }

    return cleaned.isEmpty ? name : cleaned;
  }
}
