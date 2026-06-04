enum DownloadState {
  idle,
  downloading,
  extracting,
  libraryAdding,
  libraryComplete,
  error,
}

class DownloadTask {
  final String gameId;
  final String gameName;
  final String coverPath;
  DownloadState state;
  double downloadProgress;
  double extractProgress;
  String? errorMessage;
  String totalSize;

  DownloadTask({
    required this.gameId,
    required this.gameName,
    required this.coverPath,
    this.state = DownloadState.idle,
    this.downloadProgress = 0.0,
    this.extractProgress = 0.0,
    this.errorMessage,
    this.totalSize = '2.4 GB',
  });

  DownloadTask copyWith({
    DownloadState? state,
    double? downloadProgress,
    double? extractProgress,
    String? errorMessage,
    String? totalSize,
  }) {
    return DownloadTask(
      gameId: gameId,
      gameName: gameName,
      coverPath: coverPath,
      state: state ?? this.state,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      extractProgress: extractProgress ?? this.extractProgress,
      errorMessage: errorMessage,
      totalSize: totalSize ?? this.totalSize,
    );
  }
}

typedef OnDownloadStart = void Function(String gameId, String url);
typedef OnDownloadComplete = void Function(String gameId, String path);
typedef OnDownloadError = void Function(String gameId, String error);
