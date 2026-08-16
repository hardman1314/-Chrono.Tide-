import 'package:file/file.dart' hide FileSystem;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';

/// flutter_cache_manager 的便携式文件系统实现。
///
/// 官方 [IOFileSystem] 通过 `getTemporaryDirectory()` 将缓存文件写入系统
/// `C:\Users\<u>\AppData\Local\Temp\<cacheKey>\`，本实现改为写入软件安装目录
/// `<安装目录>/data/cache/images/<cacheKey>/`，避免占用系统盘。
///
/// 镜像 [IOFileSystem] 结构，仅替换基础目录来源。
class PortableFileSystem implements FileSystem {
  final String _cacheKey;
  final Future<Directory> _fileDir;

  PortableFileSystem(this._cacheKey) : _fileDir = _createDirectory(_cacheKey);

  static Future<Directory> _createDirectory(String key) async {
    final baseDir = PathHelper.imageCacheDir;
    const fs = LocalFileSystem();
    final directory = fs.directory(p.join(baseDir, key));
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<File> createFile(String name) async {
    final directory = await _fileDir;
    if (!(await directory.exists())) {
      await _createDirectory(_cacheKey);
    }
    return directory.childFile(name);
  }
}
