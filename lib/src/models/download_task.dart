import 'package:equatable/equatable.dart';

enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
  paused,
}

class DownloadTask extends Equatable {
  final String id; // 作品内资源身份，用于下载调度和状态更新
  final int workId;
  final String workTitle;
  final String fileName;
  final String downloadUrl;
  final String? hash;
  final int? totalBytes;
  final int downloadedBytes;
  final int priority; // O4 下载优先级，数值越大越先调度
  final int attemptCount; // O3 已尝试下载次数（用于自动重试）
  final DownloadStatus status;
  final String? error;
  final DateTime createdAt;
  final DateTime? completedAt;
  final Map<String, dynamic>? workMetadata; // 作品详情元数据，用于离线预览
  final bool isSupplemental; // 补充下载标记：由"补充下载"创建，便于列表复查管理

  const DownloadTask({
    required this.id,
    required this.workId,
    required this.workTitle,
    required this.fileName,
    required this.downloadUrl,
    this.hash,
    this.totalBytes,
    this.downloadedBytes = 0,
    this.priority = 0,
    this.attemptCount = 0,
    this.status = DownloadStatus.pending,
    this.error,
    required this.createdAt,
    this.completedAt,
    this.workMetadata,
    this.isSupplemental = false,
  });

  static String createId({
    required int workId,
    required String? hash,
    required String fileName,
  }) {
    final normalizedHash = hash?.trim();
    if (normalizedHash != null && normalizedHash.isNotEmpty) {
      return '$workId:hash:$normalizedHash';
    }
    return '$workId:path:$fileName';
  }

  double get progress {
    if (totalBytes == null || totalBytes == 0) return 0.0;
    return downloadedBytes / totalBytes!;
  }

  DownloadTask copyWith({
    String? id,
    int? workId,
    String? workTitle,
    String? fileName,
    String? downloadUrl,
    String? hash,
    int? totalBytes,
    int? downloadedBytes,
    int? priority,
    int? attemptCount,
    DownloadStatus? status,
    String? error,
    DateTime? createdAt,
    DateTime? completedAt,
    Map<String, dynamic>? workMetadata,
    bool? isSupplemental,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      workId: workId ?? this.workId,
      workTitle: workTitle ?? this.workTitle,
      fileName: fileName ?? this.fileName,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      hash: hash ?? this.hash,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      priority: priority ?? this.priority,
      attemptCount: attemptCount ?? this.attemptCount,
      status: status ?? this.status,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      workMetadata: workMetadata ?? this.workMetadata,
      isSupplemental: isSupplemental ?? this.isSupplemental,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'workId': workId,
      'workTitle': workTitle,
      'fileName': fileName,
      'downloadUrl': downloadUrl,
      'hash': hash,
      'totalBytes': totalBytes,
      'downloadedBytes': downloadedBytes,
      'priority': priority,
      'attemptCount': attemptCount,
      'status': status.name,
      'error': error,
      'createdAt': createdAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'isSupplemental': isSupplemental,
      // workMetadata 不序列化到 SharedPreferences，会从硬盘的 work_metadata.json 加载
    };
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final workId = json['workId'] as int;
    final fileName = json['fileName'] as String;
    final hash = json['hash'] as String?;
    return DownloadTask(
      id: createId(workId: workId, hash: hash, fileName: fileName),
      workId: workId,
      workTitle: json['workTitle'] as String,
      fileName: fileName,
      downloadUrl: json['downloadUrl'] as String,
      hash: hash,
      totalBytes: json['totalBytes'] as int?,
      downloadedBytes: json['downloadedBytes'] as int? ?? 0,
      priority: json['priority'] as int? ?? 0,
      attemptCount: json['attemptCount'] as int? ?? 0,
      status: DownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => DownloadStatus.pending,
      ),
      error: json['error'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
      isSupplemental: json['isSupplemental'] as bool? ?? false,
      // workMetadata 不从 SharedPreferences 加载，会在启动时从硬盘同步
      workMetadata: null,
    );
  }

  @override
  List<Object?> get props => [
        id,
        workId,
        workTitle,
        fileName,
        downloadUrl,
        hash,
        totalBytes,
        downloadedBytes,
        priority,
        attemptCount,
        status,
        error,
        createdAt,
        completedAt,
        workMetadata,
        isSupplemental,
      ];
}
