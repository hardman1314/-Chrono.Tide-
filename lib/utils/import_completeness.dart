import 'dart:io';

/// 导入数据完整性判定（2026-10-03）
///
/// 产品定义：每个游戏的**封面 / 简介**两项必须齐全，
/// 任一缺失即判定为「数据不全」，入库确认时拦截并保留在导入板块，
/// 由用户自行处理（表单补全，或点重试重新抓取）。
/// （会社不参与判定：2026-10-03 晚间开发者调整——会社数据源覆盖不稳定，
///  不作必填。）
///
/// 判定时机 = 点「批量入库 / 全部入库」那一刻**实时评估**（不是处理完定死）：
/// 用户补全后再次点击确认即通过，无需任何额外操作。
///
/// 封面判定：本地临时封面文件存在，或元数据带 http 封面 URL
///（入库时 `GameDataFormat.writeGameDir` 会用 URL 自动下载兜底）——
/// 不要求临时文件已落地，避免封面仍在下载中被误判为缺失。
List<String> missingCoreDataFields({
  String? coverFilePath,
  String? coverUrl,
  required String description,
}) {
  final missing = <String>[];

  final hasUrlCover = coverUrl != null && coverUrl.startsWith('http');
  final hasLocalCover = coverFilePath != null &&
      coverFilePath.isNotEmpty &&
      File(coverFilePath).existsSync();
  if (!hasUrlCover && !hasLocalCover) {
    missing.add('封面');
  }

  if (description.trim().isEmpty) {
    missing.add('简介');
  }

  return missing;
}
