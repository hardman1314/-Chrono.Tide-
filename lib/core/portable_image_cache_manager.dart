import 'dart:io' show File;

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import 'portable_file_system.dart';

/// 便携式网络图片缓存管理器。
///
/// 替代 [DefaultCacheManager]，将网络图片缓存（游戏封面、截图、元数据图片等）
/// 从系统盘 `Temp` 与 `AppData\Roaming` 重定向到软件安装目录：
/// - 缓存文件：`<安装目录>/data/cache/images/libCachedImageData/`
/// - 缓存元数据：`<安装目录>/data/cache/images/libCachedImageData.json`
///
/// cacheKey 沿用 `libCachedImageData`（与 DefaultCacheManager 一致），
/// 便于迁移时识别旧缓存目录。使用单例避免重复构造 Config。
///
/// 缓存策略（沿用默认值）：
/// - 最多 200 个缓存对象
/// - 30 天过期清理
class PortableImageCacheManager extends CacheManager with ImageCacheManager {
  static const String key = 'libCachedImageData';

  static final PortableImageCacheManager _instance =
      PortableImageCacheManager._();

  factory PortableImageCacheManager() => _instance;

  PortableImageCacheManager._()
      : super(
          Config(
            key,
            fileSystem: PortableFileSystem(key),
            repo: JsonCacheInfoRepository.withFile(
              File(p.join(PathHelper.imageCacheDir, '$key.json')),
            ),
          ),
        );
}
