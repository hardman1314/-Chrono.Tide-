class VersionInfo {
  final String latestVersion;
  final String updateLog;
  final String downloadUrl;

  const VersionInfo({
    required this.latestVersion,
    required this.updateLog,
    required this.downloadUrl,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    // 增强的容错解析，提供默认值
    return VersionInfo(
      latestVersion: (json['latestVersion'] as String?)?.trim() ?? '',
      updateLog: (json['updateLog'] as String?) ?? '',
      downloadUrl: (json['downloadUrl'] as String?)?.trim() ?? '',
    );
  }

  /// 验证版本信息是否有效
  bool get isValid => latestVersion.isNotEmpty && downloadUrl.isNotEmpty;

  @override
  String toString() =>
      'VersionInfo(v$latestVersion, url: ${downloadUrl.isNotEmpty ? "有" : "无"})';
}

enum UpdateResult { updateAvailable, alreadyLatest, error, skipped }

class UpdateCheckResult {
  final UpdateResult result;
  final VersionInfo? versionInfo;
  final String? localVersion;
  final String? errorMessage;

  const UpdateCheckResult({
    required this.result,
    this.versionInfo,
    this.localVersion,
    this.errorMessage,
  });

  /// 获取用户友好的错误消息
  String get userFriendlyError {
    if (errorMessage == null) return '未知错误';

    if (errorMessage!.contains('FormatException')) {
      return '服务器返回的数据格式有误，请稍后重试';
    }

    if (errorMessage!.contains('SocketException') ||
        errorMessage!.contains('Connection')) {
      return '网络连接失败，请检查网络后重试';
    }

    if (errorMessage!.contains('Timeout')) {
      return '请求超时，服务器响应过慢，请稍后重试';
    }

    if (errorMessage!.length > 100) {
      return '${errorMessage!.substring(0, 97)}...';
    }

    return errorMessage!;
  }

  @override
  String toString() =>
      'UpdateCheckResult(result: $result, local: $localVersion, server: ${versionInfo?.latestVersion ?? "无"}, error: $errorMessage)';
}
