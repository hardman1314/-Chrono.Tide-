/// 云存储 Provider 抽象接口 —— 学 LunaBox 七方法模式（方案 §7 Phase 5）。
///
/// 🔴 来源（Q10 拍板）：备份面向全体用户，走**直连 Provider**（WebDAV / S3 兼容），
/// ⛔ 不走 OpenList 聚合层（已按需对接，不再硬内置，不能当全体用户通道）。
///
/// LunaBox 参照：`LunaBox-main/internal/service/cloudprovider/cloud_storage.go:9-17`
/// 的 `UploadFile / DownloadFile / ListObjects / DeleteObject / TestConnection /
/// EnsureDir / GetCloudPath` 七方法；Dart 侧补强 `onProgress` 回调。
/// `GetCloudPath` 在本设计里退化为纯函数（`cloudBackupService.remotePathFor`），
/// 不进接口。
///
/// 约定：
/// - 所有 `remotePath` 以 `/` 分隔，**不以 `/` 开头**（相对备份根），如
///   `gameId/2026-10-03_..._sealed/meta.json`。各 Provider 自行拼 baseUrl。
/// - 失败一律抛异常（[CloudStorageException] 或其子类），调用方据此分类提示。
/// - 实现必须**无 flutter 依赖**（纯 dart:io），dev_probe 可实测。
library;

import 'dart:io';

/// 云端对象（文件或目录）。
class CloudObject {
  final String path; // 相对路径（不含备份根）
  final bool isDir;
  final int size; // 目录恒 0

  const CloudObject({required this.path, required this.isDir, this.size = 0});

  /// 路径最后一段（对象名）。
  String get name {
    final parts = path.split('/')..removeWhere((p) => p.isEmpty);
    return parts.isEmpty ? path : parts.last;
  }
}

/// 云操作失败。
class CloudStorageException implements Exception {
  final String message;
  final int? statusCode; // HTTP 状态码（可空）
  CloudStorageException(this.message, [this.statusCode]);

  @override
  String toString() =>
      'CloudStorageException: $message${statusCode != null ? ' (HTTP $statusCode)' : ''}';
}

abstract class CloudStorageProvider {
  /// 展示名（'WebDAV' / 'S3 兼容' …）。
  String get name;

  /// 连通性 + 鉴权测试。失败抛异常。
  Future<void> testConnection();

  /// 确保目录存在（递归逐级创建，已存在不算错误）。
  Future<void> ensureDir(String remoteDir);

  /// 上传单个文件（覆盖语义）。[onProgress] 参数 (已发送字节, 总字节)。
  Future<void> uploadFile(
    String remotePath,
    File localFile, {
    void Function(int sent, int total)? onProgress,
  });

  /// 下载单个文件（覆盖本地目标）。[onProgress] 参数 (已接收字节, 总字节)。
  Future<void> downloadFile(
    String remotePath,
    File localFile, {
    void Function(int received, int total)? onProgress,
  });

  /// 列出 [remoteDir] 一层内容（Depth:1）。目录不存在返回空列表（不算错误）。
  Future<List<CloudObject>> list(String remoteDir);

  /// 删除文件或目录（目录 = 递归删除，WebDAV DELETE 天然递归）。
  /// 目标不存在不算错误（幂等）。
  Future<void> deleteObject(String remotePath);
}
