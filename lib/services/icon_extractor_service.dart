import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 图标提取与转换服务
///
/// 提供两种图标来源：
/// 1. 从 exe 文件提取自带图标（默认）
/// 2. 从封面图片裁剪中心区域并转换为 .ico（自定义）
///
/// 内置缓存机制：
/// - exe 图标提取结果在内存中缓存，避免同一进程内重复提取
/// - 封面转 ico 结果持久化到磁盘，通过文件修改时间判断是否需要重新转换
class IconExtractorService {
  static final IconExtractorService _instance =
      IconExtractorService._internal();
  static IconExtractorService get instance => _instance;

  IconExtractorService._internal();

  /// 内存缓存：已成功提取图标的 exe 路径（进程生命周期内有效）
  final Set<String> _extractedExeCache = {};

  /// 从 exe 文件提取图标并保存为 .ico 文件
  ///
  /// [exePath] 游戏 exe 路径
  /// [outputPath] 输出 .ico 文件路径
  Future<bool> extractIconFromExe({
    required String exePath,
    required String outputPath,
  }) async {
    try {
      if (!File(exePath).existsSync()) {
        debugPrint('[ICON] ❌ exe 文件不存在: $exePath');
        return false;
      }

      // 缓存命中：输出文件已存在且 exe 已提取过 → 直接返回
      final outputFile = File(outputPath);
      if (_extractedExeCache.contains(exePath) && await outputFile.exists()) {
        debugPrint('[ICON] ⏩ 缓存命中，跳过提取: $outputPath');
        return true;
      }

      // 确保输出目录存在
      final outputDir = outputFile.parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // PowerShell 脚本：使用 System.Drawing 提取图标
      final psScript = '''
Add-Type -AssemblyName System.Drawing
\$icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$exePath")
if (\$icon -eq \$null) {
    Write-Output "ERROR:IconNotFound"
    exit 1
}
\$fs = [System.IO.File]::OpenWrite("$outputPath")
\$icon.Save(\$fs)
\$fs.Close()
\$icon.Dispose()
Write-Output "SUCCESS"
''';

      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', psScript],
      );

      if (result.exitCode == 0 &&
          result.stdout.toString().contains('SUCCESS')) {
        debugPrint('[ICON] ✅ 图标已提取: $outputPath');
        _extractedExeCache.add(exePath);
        return true;
      } else {
        debugPrint('[ICON] ❌ 提取失败: ${result.stderr}');
        return false;
      }
    } catch (e) {
      debugPrint('[ICON] ❌ 提取异常: $e');
      return false;
    }
  }

  /// 将封面图片裁剪中心区域并转换为 .ico 文件
  ///
  /// [coverPath] 封面图片路径
  /// [outputPath] 输出 .ico 文件路径
  /// [cropScale] 裁剪比例（0.0-1.0），默认 0.8 表示取中心 80% 区域
  Future<bool> convertCoverToIco({
    required String coverPath,
    required String outputPath,
    double cropScale = 0.8,
  }) async {
    try {
      if (!File(coverPath).existsSync()) {
        debugPrint('[ICON] ❌ 封面图片不存在: $coverPath');
        return false;
      }

      // 磁盘缓存：输出 .ico 已存在且源封面未变更 → 跳过转换
      final coverFile = File(coverPath);
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        final coverMtime = (await coverFile.lastModified());
        final outputMtime = (await outputFile.lastModified());
        if (!coverMtime.isAfter(outputMtime)) {
          debugPrint('[ICON] ⏩ 磁盘缓存命中，跳过封面转换: $outputPath');
          return true;
        }
      }

      // 确保输出目录存在
      final outputDir = outputFile.parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // PowerShell 脚本：裁剪封面中心区域并转换为 ico
      final psScript = '''
Add-Type -AssemblyName System.Drawing
\$src = [System.Drawing.Image]::FromFile("$coverPath")
if (\$src -eq \$null) {
    Write-Output "ERROR:ImageNotFound"
    exit 1
}

\$srcW = \$src.Width
\$srcH = \$src.Height

# 计算裁剪区域（中心正方形）
\$cropSize = [Math]::Min(\$srcW, \$srcH) * $cropScale
\$cropX = (\$srcW - \$cropSize) / 2
\$cropY = (\$srcH - \$cropSize) / 2

# 创建 256x256 的位图
\$bmp = New-Object System.Drawing.Bitmap(256, 256)
\$g = [System.Drawing.Graphics]::FromImage(\$bmp)
\$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
\$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
\$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

\$cropRect = New-Object System.Drawing.Rectangle(\$cropX, \$cropY, \$cropSize, \$cropSize)
\$destRect = New-Object System.Drawing.Rectangle(0, 0, 256, 256)
\$g.DrawImage(\$src, \$destRect, \$cropRect, [System.Drawing.GraphicsUnit]::Pixel)
\$g.Dispose()

# 转换为 ico 格式
\$ms = New-Object System.IO.MemoryStream
\$bmp.Save(\$ms, [System.Drawing.Imaging.ImageFormat]::Png)
\$pngBytes = \$ms.ToArray()
\$ms.Close()

\$fs = [System.IO.File]::OpenWrite("$outputPath")
\$bw = New-Object System.IO.BinaryWriter(\$fs)

# ICO 文件头
\$bw.Write([UInt16]0)       # 保留字段
\$bw.Write([UInt16]1)       # 类型: 1 = ICO
\$bw.Write([UInt16]1)       # 图像数量

# 目录条目
\$bw.Write([Byte]0)         # 宽度 (0 = 256)
\$bw.Write([Byte]0)         # 高度 (0 = 256)
\$bw.Write([Byte]0)         # 颜色数
\$bw.Write([Byte]0)         # 保留
\$bw.Write([UInt16]1)       # 色彩平面数
\$bw.Write([UInt16]32)      # 每像素位数
\$bw.Write([UInt32]\$pngBytes.Length)  # 图像数据大小
\$bw.Write([UInt32]22)      # 图像数据偏移

# 图像数据
\$bw.Write(\$pngBytes)
\$bw.Close()
\$fs.Close()

\$bmp.Dispose()
\$src.Dispose()
Write-Output "SUCCESS"
''';

      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', psScript],
      );

      if (result.exitCode == 0 &&
          result.stdout.toString().contains('SUCCESS')) {
        debugPrint('[ICON] ✅ 封面已转换为 ico: $outputPath');
        return true;
      } else {
        debugPrint('[ICON] ❌ 转换失败: ${result.stderr}');
        return false;
      }
    } catch (e) {
      debugPrint('[ICON] ❌ 转换异常: $e');
      return false;
    }
  }

  /// 获取游戏的自定义图标路径
  ///
  /// 图标存储在游戏元数据目录下，文件名为 desktop_icon.ico
  String getCustomIconPath(String metaDataDir) {
    return p.join(metaDataDir, 'desktop_icon.ico');
  }

  /// 检查游戏是否已有自定义图标
  bool hasCustomIcon(String metaDataDir) {
    return File(getCustomIconPath(metaDataDir)).existsSync();
  }

  /// 删除自定义图标
  Future<bool> deleteCustomIcon(String metaDataDir) async {
    try {
      final iconPath = getCustomIconPath(metaDataDir);
      final file = File(iconPath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[ICON] ✅ 自定义图标已删除: $iconPath');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[ICON] ❌ 删除异常: $e');
      return false;
    }
  }

  /// 清除内存缓存（用于图标被删除或更换时）
  void clearCache() {
    _extractedExeCache.clear();
    debugPrint('[ICON] 内存缓存已清除');
  }
}
