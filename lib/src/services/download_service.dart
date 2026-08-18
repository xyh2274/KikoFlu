import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/download_task.dart';
import '../utils/file_icon_utils.dart';
import 'cache_service.dart';
import 'storage_service.dart';
import 'kikoeru_api_service.dart';
import 'download_path_service.dart';
import 'download_file_path_service.dart';
import 'local_work_metadata_service.dart';
import 'log_service.dart';
import 'storage_space_service.dart';
import 'notification_service.dart';
import 'network_proxy_service.dart';

final _log = LogService.instance;

class DownloadService {
  static DownloadService? _instance;
  static DownloadService get instance => _instance ??= DownloadService._();

  DownloadService._() {
    // 若配置了网络代理（如宿主机 Clash 7897），应用到下载请求
    NetworkProxyService.applyProxy(_dio);
  }

  final Map<String, CancelToken> _cancelTokens = {};
  final StreamController<List<DownloadTask>> _tasksController =
      StreamController<List<DownloadTask>>.broadcast();
  final List<DownloadTask> _tasks = [];
  final Dio _dio = Dio();
  final LocalWorkMetadataService _localMetadataService =
      const LocalWorkMetadataService();

  // 并发下载控制
  static const int _maxConcurrentDownloads = 20;
  // O1 空间检查的安全余量（预留，避免可用空间恰好等于所需时仍失败）
  static const int _spaceMarginBytes = 32 * 1024 * 1024;
  // O3 自动重试参数：最大次数、指数退避基准秒数、退避上限秒数
  static const int _maxRetries = 3;
  static const int _retryBaseSec = 2;
  static const int _retryMaxSec = 30;
  int _activeDownloadCount = 0;
  bool _isProcessingQueue = false;

  // 用于延迟保存任务，避免频繁 I/O 操作
  Timer? _saveTimer;
  bool _needsSave = false;

  Stream<List<DownloadTask>> get tasksStream => _tasksController.stream;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  // 获取正在下载或等待下载的任务数量
  int get activeDownloadCount => _tasks
      .where((task) =>
          task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.pending)
      .length;

  // 检查是否有任务正在下载
  bool get hasActiveDownloads => activeDownloadCount > 0;

  static const String _tasksKey = 'download_tasks';

  Future<void> initialize() async {
    // 初始化通知服务（O5）
    await NotificationService.instance.initialize();
    
    await _loadTasks();
    // 恢复未完成的下载任务
    for (final task in _tasks) {
      if (task.status == DownloadStatus.downloading) {
        _updateTask(task.copyWith(status: DownloadStatus.paused));
      }
    }
    // 注意：启动时不执行 reloadMetadataFromDisk 全量磁盘扫描。
    // 该扫描需遍历整个下载目录（导入大量音声后目录可能极大），
    // 在主 isolate 执行会阻塞 UI 首帧渲染导致启动黑屏。
    // 启动后异步补全缺失/不完整的作品元数据（标题/封面/标签），
    // 不阻塞首帧；"已下载"页进入时也会再次触发（有防重入保护）。

    // O9: 启动时清理孤立的临时文件
    unawaited(_cleanupOrphanedTempFiles());
    unawaited(ensureLocalMetadataCompleteness());
  }

  Future<Directory> _getDownloadDirectory() async {
    // 使用 DownloadPathService 获取下载目录（支持自定义路径）
    return await DownloadPathService.getDownloadDirectory();
  }

  // 公开方法，用于获取下载根目录
  Future<Directory> getDownloadDirectory() async {
    return _getDownloadDirectory();
  }

  Future<String> _getWorkDownloadDirectory(int workId) async {
    final downloadDir = await _getDownloadDirectory();
    final workDir = Directory(p.join(downloadDir.path, workId.toString()));
    if (!await workDir.exists()) {
      await workDir.create(recursive: true);
    }
    return workDir.path;
  }

  File _workMetadataFile(Directory workDir) {
    return File(
      p.join(workDir.path, LocalWorkMetadataService.metadataFileName),
    );
  }

  Directory _workDirectoryForMetadata(
    Directory downloadDir,
    int workId,
    Map<String, dynamic>? metadata,
  ) {
    final localDirName =
        metadata?[LocalWorkMetadataService.localWorkDirNameKey];
    if (localDirName is String && localDirName.trim().isNotEmpty) {
      final relativeDir =
          DownloadFilePathService.normalizeRelativePath(localDirName);
      if (relativeDir.isNotEmpty) {
        return Directory(
          DownloadFilePathService.localPathForRelativePath(
            rootPath: downloadDir.path,
            relativePath: relativeDir,
          ),
        );
      }
    }

    return Directory(p.join(downloadDir.path, workId.toString()));
  }

  Future<Directory> getWorkDirectory(
    int workId, {
    Map<String, dynamic>? metadata,
  }) async {
    final downloadDir = await _getDownloadDirectory();
    if (metadata != null) {
      return _workDirectoryForMetadata(downloadDir, workId, metadata);
    }

    final loadedMetadata = await _loadWorkMetadata(workId);
    return _workDirectoryForMetadata(downloadDir, workId, loadedMetadata);
  }

  String? localCoverPathForMetadata(
    Directory workDir,
    Map<String, dynamic>? metadata,
  ) {
    final relativeCoverPath = metadata?['localCoverPath'];
    if (relativeCoverPath is! String || relativeCoverPath.trim().isEmpty) {
      return null;
    }

    return DownloadFilePathService.localPathForRelativePath(
      rootPath: workDir.path,
      relativePath: relativeCoverPath,
    );
  }

  Future<void> _ensureDirectoryWritable(Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final probe = File(
      p.join(
        directory.path,
        '.kikoflu_write_test_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    } catch (e) {
      throw FileSystemException(
        '无法写入下载目录，请检查外置存储权限或重新选择下载路径',
        directory.path,
        e is FileSystemException ? e.osError : null,
      );
    }
  }

  // 下载封面图片到本地
  Future<String?> _downloadCoverImage(
    int workId,
    String coverUrl, {
    String? workDirPath,
  }) async {
    try {
      final workDir = workDirPath ?? await _getWorkDownloadDirectory(workId);
      final coverFile = File(
        DownloadFilePathService.localPathForRelativePath(
          rootPath: workDir,
          relativePath: 'cover.jpg',
        ),
      );

      // 如果已存在则不重复下载
      if (await coverFile.exists()) {
        return coverFile.path;
      }

      // 下载图片
      _dio.options.headers.addAll(StorageService.serverCookieHeaders);
      await _dio.download(coverUrl, coverFile.path);
      return coverFile.path;
    } catch (e) {
      _log.error('下载封面图片失败: $e', tag: 'Download');
      return null;
    }
  }

  // 保存作品元数据到硬盘。元数据先落盘，封面再后台补齐，避免封面请求影响离线详情。
  Future<void> _saveWorkMetadata(
      int workId, Map<String, dynamic> metadata, String? coverUrl) async {
    try {
      final workDir = Directory(await _getWorkDownloadDirectory(workId));
      final metadataToSave = Map<String, dynamic>.from(metadata);
      if (_metadataIdAsPositiveInt(metadataToSave['id']) == null) {
        metadataToSave['id'] = workId;
      }
      metadataToSave[LocalWorkMetadataService.localWorkDirNameKey] =
          p.basename(workDir.path);

      final metadataFile = _workMetadataFile(workDir);
      await metadataFile.writeAsString(jsonEncode(metadataToSave), flush: true);
      _log.debug(
        '已保存作品元数据: workId=$workId, path=${metadataFile.path}, '
        'children=${(metadataToSave['children'] as List?)?.length ?? 0}',
        tag: 'Download',
      );

      if (coverUrl != null && coverUrl.isNotEmpty) {
        unawaited(_saveCoverForMetadata(
          workId: workId,
          workDir: workDir,
          coverUrl: coverUrl,
          metadata: metadataToSave,
        ));
      }
    } catch (e) {
      _log.error('保存作品元数据失败: $e', tag: 'Download');
    }
  }

  Future<void> _saveCoverForMetadata({
    required int workId,
    required Directory workDir,
    required String coverUrl,
    required Map<String, dynamic> metadata,
  }) async {
    final localCoverPath = await _downloadCoverImage(
      workId,
      coverUrl,
      workDirPath: workDir.path,
    );
    if (localCoverPath == null) return;

    try {
      final updatedMetadata = Map<String, dynamic>.from(metadata)
        ..['localCoverPath'] = 'cover.jpg';
      await _workMetadataFile(workDir).writeAsString(
        jsonEncode(updatedMetadata),
        flush: true,
      );
      _log.debug('已更新作品封面元数据: workId=$workId', tag: 'Download');
    } catch (e) {
      _log.error('更新作品封面元数据失败: $e', tag: 'Download');
    }
  }

  // 从硬盘读取作品元数据
  Future<Map<String, dynamic>?> _loadWorkMetadata(int workId) async {
    try {
      final workDir = await _findExistingWorkDirectory(workId);
      if (workDir == null) {
        _log.warning(
          '未找到作品目录，无法加载元数据: workId=$workId',
          tag: 'Download',
        );
        return null;
      }

      final metadataFile = _workMetadataFile(workDir);

      if (await metadataFile.exists()) {
        final content = await metadataFile.readAsString();
        final metadata = jsonDecode(content) as Map<String, dynamic>;
        if (_metadataIdAsPositiveInt(metadata['id']) == null) {
          metadata['id'] = workId;
        }
        metadata[LocalWorkMetadataService.localWorkDirNameKey] =
            p.basename(workDir.path);
        _log.debug(
          '已从磁盘加载元数据: workId=$workId, dir=${p.basename(workDir.path)}, '
          'metadataId=${metadata['id']}, sourceId=${metadata['source_id']}, '
          'children=${(metadata['children'] as List?)?.length ?? 0}',
          tag: 'Download',
        );

        // 迁移旧的绝对路径为相对路径
        if (metadata.containsKey('localCoverPath')) {
          final coverPath = metadata['localCoverPath'] as String?;
          if (coverPath != null && p.isAbsolute(coverPath)) {
            // 如果包含路径分隔符，说明是绝对路径，转换为相对路径
            metadata['localCoverPath'] = 'cover.jpg';
            // 保存更新后的元数据
            await metadataFile.writeAsString(jsonEncode(metadata));
            _log.info('已迁移作品 $workId 的封面路径为相对路径', tag: 'Download');
          }
        }

        return metadata;
      }
      _log.warning(
        '作品目录存在但缺少 work_metadata.json: workId=$workId, dir=${workDir.path}',
        tag: 'Download',
      );
    } catch (e) {
      _log.error('读取作品元数据失败: $e', tag: 'Download');
    }
    return null;
  }

  Future<Directory?> _findExistingWorkDirectory(int workId) async {
    final downloadDir = await _getDownloadDirectory();
    if (!await downloadDir.exists()) {
      _log.warning('下载根目录不存在: ${downloadDir.path}', tag: 'Download');
      return null;
    }

    Directory? fallback;
    await for (final entity in downloadDir.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final parsed = _localMetadataService.parseWorkFolder(entity);
      if (parsed?.id != workId) continue;

      if (p.basename(entity.path) == workId.toString()) {
        _log.debug(
          '匹配作品目录: workId=$workId, dir=${entity.path}, exact=true',
          tag: 'Download',
        );
        return entity;
      }
      fallback ??= entity;
    }

    if (fallback != null) {
      _log.debug(
        '匹配作品目录: workId=$workId, dir=${fallback.path}, exact=false',
        tag: 'Download',
      );
    }
    return fallback;
  }

  int? _metadataIdAsPositiveInt(dynamic value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  // 获取作品元数据（公共方法，优先从内存读取，否则从硬盘读取）
  Future<Map<String, dynamic>?> getWorkMetadata(int workId) async {
    // 先尝试从任务中获取
    final task = _tasks.firstWhere(
      (t) => t.workId == workId && t.workMetadata != null,
      orElse: () => DownloadTask(
        id: '',
        workId: 0,
        workTitle: '',
        fileName: '',
        downloadUrl: '',
        createdAt: DateTime.now(),
      ),
    );

    if (task.id.isNotEmpty && task.workMetadata != null) {
      _log.debug(
        '从内存任务获取元数据: workId=$workId, task=${task.id}, '
        'metadataId=${task.workMetadata?['id']}, sourceId=${task.workMetadata?['source_id']}',
        tag: 'Download',
      );
      return task.workMetadata;
    }

    // 如果内存中没有，从硬盘读取
    _log.info('内存任务无元数据，尝试从磁盘恢复: workId=$workId', tag: 'Download');
    return await _loadWorkMetadata(workId);
  }

  // 添加下载任务
  Future<DownloadTask> addTask({
    required int workId,
    required String workTitle,
    required String fileName,
    required String downloadUrl,
    required String? hash,
    int? totalBytes,
    Map<String, dynamic>? workMetadata,
    String? coverUrl,
    String? relativePath, // 相对路径，用于按文件树组织
    bool forceRedownload = false, // 补充下载：强制移除旧的已完成记录并重新下载
  }) async {
    final safeFileName = relativePath != null && relativePath.isNotEmpty
        ? '${DownloadFilePathService.safeRelativePath(relativePath)}/'
            '${DownloadFilePathService.safePathSegment(fileName)}'
        : DownloadFilePathService.safeRelativePath(fileName);

    // 检查是否已存在
    final existingTask = _tasks.firstWhere(
      (t) => t.hash == hash && t.workId == workId,
      orElse: () => DownloadTask(
        id: '',
        workId: 0,
        workTitle: '',
        fileName: '',
        downloadUrl: '',
        createdAt: DateTime.now(),
      ),
    );

    if (existingTask.id.isNotEmpty) {
      if (existingTask.status == DownloadStatus.completed) {
        if (forceRedownload) {
          // 补充下载：移除旧的已完成任务记录（文件已缺失），重新加入下载队列
          _tasks.removeWhere((t) => t.id == existingTask.id);
          _log.info(
            '补充下载：移除旧的已完成任务记录: ${existingTask.id} (${existingTask.fileName})',
            tag: 'Download',
          );
        } else {
          // 如果任务已完成但没有元数据，更新元数据
          if (existingTask.workMetadata == null && workMetadata != null) {
            final updatedTask = existingTask.copyWith(workMetadata: workMetadata);
            _updateTask(updatedTask, immediate: true);
            // 保存元数据到硬盘
            await _saveWorkMetadata(workId, workMetadata, coverUrl);
            return updatedTask;
          }
          return existingTask;
        }
      } else if (forceRedownload) {
        // 补充下载：将已失败/暂停的任务重置为等待状态，重新加入下载队列
        if (existingTask.status == DownloadStatus.failed ||
            existingTask.status == DownloadStatus.paused) {
          _updateTask(
            existingTask.copyWith(
              status: DownloadStatus.pending,
              attemptCount: 0,
              error: null,
            ),
            immediate: true,
          );
          unawaited(_processQueue());
          _log.info(
            '补充下载：重置失败任务为等待下载: ${existingTask.id} (${existingTask.fileName})',
            tag: 'Download',
          );
        }
        return existingTask;
      } else {
        // 如果任务存在但未完成，返回现有任务
        return existingTask;
      }
    }

    // 检查缓存中是否已有此文件
    if (hash != null && hash.isNotEmpty) {
      final cachedFile = await CacheService.getCachedAudioFile(hash);
      if (cachedFile != null) {
        // 从缓存移动到下载目录
        final workDir = await _getWorkDownloadDirectory(workId);
        final targetPath = DownloadFilePathService.localPathForRelativePath(
          rootPath: workDir,
          relativePath: safeFileName,
        );
        final targetFile = File(targetPath);

        // 确保目录存在
        await targetFile.parent.create(recursive: true);

        if (!await targetFile.exists()) {
          await File(cachedFile).copy(targetPath);
        }

        final task = DownloadTask(
          id: hash,
          workId: workId,
          workTitle: workTitle,
          fileName: safeFileName, // 使用包含路径的完整文件名
          downloadUrl: downloadUrl,
          hash: hash,
          totalBytes: totalBytes ?? await targetFile.length(),
          downloadedBytes: totalBytes ?? await targetFile.length(),
          status: DownloadStatus.completed,
          createdAt: DateTime.now(),
          completedAt: DateTime.now(),
          workMetadata: workMetadata,
        );

        _tasks.add(task);
        await _saveTasks();
        _tasksController.add(List.from(_tasks));

        // 保存作品元数据到硬盘
        if (workMetadata != null) {
          await _saveWorkMetadata(workId, workMetadata, coverUrl);
        }

        return task;
      }
    }

    final task = DownloadTask(
      id: hash ?? '${workId}_${DateTime.now().millisecondsSinceEpoch}',
      workId: workId,
      workTitle: workTitle,
      fileName: safeFileName,
      downloadUrl: downloadUrl,
      hash: hash,
      totalBytes: totalBytes,
      createdAt: DateTime.now(),
      workMetadata: workMetadata,
    );

    _tasks.add(task);
    _tasksController.add(List.from(_tasks));

    // 添加任务后立即保存
    await _saveTasks();

    // 保存作品元数据到硬盘
    if (workMetadata != null) {
      await _saveWorkMetadata(workId, workMetadata, coverUrl);
    }

    // 自动开始下载（通过队列调度）
    unawaited(_processQueue());

    return task;
  }

  /// 处理下载队列：确保活跃下载数不超过上限
  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    try {
      // 获取所有等待中的任务，按优先级降序、创建时间升序调度（O4）
      final pendingTasks = _tasks
          .where((t) => t.status == DownloadStatus.pending)
          .toList()
        ..sort((a, b) {
          final prioCmp = b.priority.compareTo(a.priority);
          if (prioCmp != 0) return prioCmp;
          return a.createdAt.compareTo(b.createdAt);
        });

      if (pendingTasks.isNotEmpty) {
        _log.debug(
            '调度下载队列: ${pendingTasks.length} 个等待中, $_activeDownloadCount/$_maxConcurrentDownloads 个进行中',
            tag: 'Download');
      }

      for (final task in pendingTasks) {
        if (_activeDownloadCount >= _maxConcurrentDownloads) break;
        _activeDownloadCount++;
        unawaited(_startDownload(task).whenComplete(() {
          _activeDownloadCount--;
          _processQueue(); // 完成后继续调度
        }));
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  Future<void> _startDownload(DownloadTask task) async {
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.completed) {
      return;
    }

    _log.info('开始下载: ${task.fileName} (workId: ${task.workId})',
        tag: 'Download');

    _updateTask(task.copyWith(status: DownloadStatus.downloading),
        immediate: true);

    final workDir = await _getWorkDownloadDirectory(task.workId);
    await _ensureDirectoryWritable(Directory(workDir));
    // 使用fileName中的路径信息（如果包含/）
    final filePath = DownloadFilePathService.localPathForRelativePath(
      rootPath: workDir,
      relativePath: task.fileName,
    );
    final tempFilePath = '$filePath.downloading'; // 临时文件路径
    final file = File(filePath);
    final tempFile = File(tempFilePath);

    _log.debug('下载路径: filePath=$filePath, tempFile=$tempFilePath',
        tag: 'Download');

    // O1: 下载前检查目标磁盘剩余空间（仅当任务声明确切大小且能查询到可用空间时生效）
    if (task.totalBytes != null && task.totalBytes! > 0) {
      final freeBytes =
          await StorageSpaceService.getAvailableBytes(Directory(workDir));
      if (freeBytes != null) {
        int existing = 0;
        if (await tempFile.exists()) {
          existing = await tempFile.length();
        }
        final needed = task.totalBytes! - existing;
        if (needed > 0 && freeBytes < needed + _spaceMarginBytes) {
          _log.warning(
            '存储空间不足: 需要 ${StorageSpaceService.formatBytes(needed + _spaceMarginBytes)}, 可用 ${StorageSpaceService.formatBytes(freeBytes)}, file=${task.fileName}',
            tag: 'Download',
          );
          _updateTask(
            task.copyWith(
              status: DownloadStatus.failed,
              error: '存储空间不足：需要 ${StorageSpaceService.formatBytes(needed + _spaceMarginBytes)}, 可用 ${StorageSpaceService.formatBytes(freeBytes)}',
            ),
            immediate: true,
          );
          _cancelTokens.remove(task.id);
          return;
        }
      }
    }

    // 确保父目录存在
    await file.parent.create(recursive: true);

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    try {
      // 先检查缓存中是否已有此文件
      if (task.hash != null && task.hash!.isNotEmpty) {
        final fileType = task.fileName.split('.').last.toLowerCase();
        final cachedPath = await CacheService.getCachedFileResource(
          workId: task.workId,
          hash: task.hash!,
          fileType: fileType,
        );

        if (cachedPath != null) {
          // 缓存存在,直接复制文件
          _log.info('从缓存复制文件: $cachedPath -> $filePath', tag: 'Download');
          final cachedFile = File(cachedPath);
          if (await cachedFile.exists()) {
            await cachedFile.copy(filePath);

            final completedTask = task.copyWith(
              status: DownloadStatus.completed,
              completedAt: DateTime.now(),
              downloadedBytes: await file.length(),
              totalBytes: await file.length(),
            );
            _updateTask(completedTask, immediate: true);
            _cancelTokens.remove(task.id);
            
            // O5: 发送下载完成通知
            unawaited(NotificationService.instance.showDownloadCompleteNotification(
              title: '下载完成',
              body: task.fileName,
            ));
            return;
          }
        }
      }

      // 缓存不存在,从网络下载
      // 节流：限制进度更新频率
      int lastUpdateTime = 0;
      const updateInterval = 500; // 500ms 更新一次

      _dio.options.headers.addAll(StorageService.serverCookieHeaders);

      // O8: 断点续传 - 检查临时文件是否存在，如果存在则从断点续传
      int downloadedBytes = 0;
      bool isResuming = false;
      if (await tempFile.exists()) {
        downloadedBytes = await tempFile.length();
        if (downloadedBytes > 0) {
          isResuming = true;
          _log.info('发现临时文件，尝试断点续传: ${task.fileName}, 已下载 ${StorageSpaceService.formatBytes(downloadedBytes)}',
              tag: 'Download');
          // 添加 Range 请求头
          _dio.options.headers['Range'] = 'bytes=$downloadedBytes-';
        }
      }

      _log.info('开始网络下载: ${task.fileName}, url=${task.downloadUrl}${isResuming ? " (断点续传)" : ""}',
          tag: 'Download');

      // O8: 使用 ResponseType.stream 支持断点续传
      final response = await _dio.get<ResponseBody>(
        task.downloadUrl,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.stream),
      );

      if (response.data == null) {
        throw Exception('响应数据为空');
      }

      // 检查服务器是否支持断点续传（返回 206 表示支持）
      final statusCode = response.statusCode ?? 0;
      if (isResuming && statusCode != 206) {
        _log.warning('服务器不支持断点续传（状态码: $statusCode），重新开始下载',
            tag: 'Download');
        // 删除临时文件，重新开始下载
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        downloadedBytes = 0;
        isResuming = false;
      }

      // 获取文件总大小
      final contentLengthHeader = response.headers.value('content-length');
      final contentLength = contentLengthHeader != null ? int.tryParse(contentLengthHeader) : null;
      final totalBytes = isResuming && contentLength != null
          ? contentLength + downloadedBytes
          : contentLength;

      // 打开文件（追加或覆盖模式）
      final fileSink = await tempFile.open(
        mode: isResuming ? FileMode.append : FileMode.write,
      );

      try {
        int receivedBytes = downloadedBytes;
        
        await for (final chunk in response.data!.stream) {
          if (cancelToken.isCancelled) {
            break;
          }
          
          await fileSink.writeFrom(chunk);
          receivedBytes += chunk.length;

          // 更新进度
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastUpdateTime > updateInterval || 
              (totalBytes != null && receivedBytes == totalBytes)) {
            lastUpdateTime = now;
            _updateTask(task.copyWith(
              status: DownloadStatus.downloading,
              downloadedBytes: receivedBytes,
              totalBytes: totalBytes,
            ));
          }
        }
      } finally {
        await fileSink.close();
      }

      // O2: 下载文件大小完整性校验（服务器未报告大小或无预期大小则跳过）
      final currentTaskBeforeRename =
          _tasks.firstWhere((t) => t.id == task.id, orElse: () => task);
      final expectedBytes =
          currentTaskBeforeRename.totalBytes ?? task.totalBytes;
      final actualBytes = await tempFile.length();
      if (expectedBytes != null &&
          expectedBytes > 0 &&
          actualBytes < expectedBytes) {
        _log.error(
          '完整性校验失败: ${task.fileName}, 预期 $expectedBytes 字节, 实际 $actualBytes 字节',
          tag: 'Download',
        );
        // 清理损坏的临时文件
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        _updateTask(
          task.copyWith(
            status: DownloadStatus.failed,
            error: '完整性校验失败：下载文件不完整（预期 ${StorageSpaceService.formatBytes(expectedBytes)}, 实际 ${StorageSpaceService.formatBytes(actualBytes)}）',
          ),
          immediate: true,
        );
        _cancelTokens.remove(task.id);
        return;
      }

      // 校验通过，重命名临时文件为最终文件
      await tempFile.rename(filePath);

      _log.info('下载完成: ${task.fileName}', tag: 'Download');

      // 从 _tasks 获取当前版本以保留进度数据
      final currentTask =
          _tasks.firstWhere((t) => t.id == task.id, orElse: () => task);
      final completedTask = currentTask.copyWith(
        status: DownloadStatus.completed,
        completedAt: DateTime.now(),
      );
      _updateTask(completedTask, immediate: true); // 完成时立即保存
      _cancelTokens.remove(task.id);
      
      // O5: 发送下载完成通知
      unawaited(NotificationService.instance.showDownloadCompleteNotification(
        title: '下载完成',
        body: task.fileName,
      ));
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        _log.info('下载已取消: ${task.fileName}', tag: 'Download');
        _updateTask(task.copyWith(status: DownloadStatus.paused),
            immediate: true);
      } else if (e is PathNotFoundException) {
        _log.error('路径不存在: ${task.fileName}, filePath=$filePath, error=$e',
            tag: 'Download');
        _failNoRetry(task, '路径不存在: $e');
      } else if (e is FileSystemException) {
        _log.error('文件系统错误: ${task.fileName}, filePath=$filePath, error=$e',
            tag: 'Download');
        _failNoRetry(task, '文件系统错误: $e');
      } else if (e is DioException) {
        _log.error(
            '网络错误: ${task.fileName}, type=${e.type}, message=${e.message}, url=${task.downloadUrl}',
            tag: 'Download');
        if (_isRetryableDioError(e)) {
          _scheduleRetry(task, e.toString());
        } else {
          _failNoRetry(task, '下载失败: ${e.message}');
        }
      } else {
        _log.error('下载失败: ${task.fileName}, error=$e', tag: 'Download');
        _failNoRetry(task, e.toString());
      }
      _cancelTokens.remove(task.id);
    }
  }

  /// 判断 Dio 错误是否可自动重试（网络类错误可重试，协议/服务器状态类不重试）
  static bool _isRetryableDioError(DioException e) {
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.unknown => true,
      _ => false,
    };
  }

  /// 失败且不自动重试
  void _failNoRetry(DownloadTask task, String error) {
    _updateTask(
      task.copyWith(status: DownloadStatus.failed, error: error),
      immediate: true,
    );
  }

  /// O3: 失败后按指数退避自动重试，超过最大次数则置失败
  void _scheduleRetry(DownloadTask task, String message) {
    final attempt = task.attemptCount + 1;
    if (attempt > _maxRetries) {
      _log.error('达到最大重试次数($_maxRetries): ${task.fileName}', tag: 'Download');
      _failNoRetry(task, '下载失败: $message');
      return;
    }
    var backoffSec = _retryBaseSec * (1 << (attempt - 1));
    if (backoffSec > _retryMaxSec) backoffSec = _retryMaxSec;
    _log.info(
        '${task.fileName} 将在 $backoffSec 秒后自动重试($attempt/$_maxRetries)',
        tag: 'Download');
    _updateTask(
      task.copyWith(
        status: DownloadStatus.failed,
        attemptCount: attempt,
        error: '下载失败，$backoffSec 秒后自动重试($attempt/$_maxRetries)',
      ),
      immediate: true,
    );

    Timer(Duration(seconds: backoffSec), () {
      // 重试仅当任务仍存在且处于失败状态，避免覆盖用户手动操作
      DownloadTask? latest;
      for (final t in _tasks) {
        if (t.id == task.id) {
          latest = t;
          break;
        }
      }
      if (latest != null && latest.status == DownloadStatus.failed) {
        _updateTask(latest.copyWith(status: DownloadStatus.pending),
            immediate: true);
        unawaited(_processQueue());
      }
    });
  }

  /// O4: 调整任务优先级（数值越大越先调度）
  Future<void> setPriority(String taskId, int priority) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;
    _updateTask(_tasks[index].copyWith(priority: priority), immediate: true);
    // 有并发余量时立即重新调度，让高优先级任务尽快开始
    unawaited(_processQueue());
  }

  Future<void> pauseTask(String taskId) async {
    final token = _cancelTokens[taskId];
    if (token != null) {
      token.cancel();
    }
  }

  Future<void> resumeTask(String taskId) async {
    final task = _tasks.firstWhere((t) => t.id == taskId);
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      // 手动重试时重置自动重试次数
      _updateTask(
          task.copyWith(status: DownloadStatus.pending, attemptCount: 0),
          immediate: true);
      unawaited(_processQueue());
    }
  }

  Future<void> deleteTask(String taskId) async {
    final task = _tasks.firstWhere((t) => t.id == taskId);
    final workId = task.workId;

    // 取消下载
    final token = _cancelTokens[taskId];
    if (token != null) {
      token.cancel();
      _cancelTokens.remove(taskId);
    }

    // 删除文件
    if (task.status == DownloadStatus.completed) {
      final workDir = await _getWorkDownloadDirectory(workId);
      final file = File(
        DownloadFilePathService.localPathForRelativePath(
          rootPath: workDir,
          relativePath: task.fileName,
        ),
      );
      if (await file.exists()) {
        await file.delete();
      }
    }

    // 从任务列表中移除
    _tasks.removeWhere((t) => t.id == taskId);

    // 检查该作品是否还有其他任务
    final remainingTasks = _tasks.where((t) => t.workId == workId).toList();
    if (remainingTasks.isEmpty) {
      // 如果没有其他任务了，删除整个作品文件夹
      try {
        final workDir = await _getWorkDownloadDirectory(workId);
        final dir = Directory(workDir);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          _log.info('已删除作品文件夹: $workDir', tag: 'Download');
        }
      } catch (e) {
        _log.error('删除作品文件夹失败: $e', tag: 'Download');
      }
    }

    await _saveTasks();
    _tasksController.add(List.from(_tasks));
  }

  /// 删除单个文件（用于离线详情页）
  /// 删除后会清理空文件夹并同步任务列表
  Future<void> deleteFile(
    int workId,
    String relativePath, {
    String? workDirPath,
  }) async {
    try {
      final workDir = workDirPath ?? await _getWorkDownloadDirectory(workId);
      final file = File(
        DownloadFilePathService.localPathForRelativePath(
          rootPath: workDir,
          relativePath: relativePath,
        ),
      );

      if (!await file.exists()) {
        throw Exception('文件不存在');
      }

      // 删除文件
      await file.delete();
      _log.info('已删除文件: $relativePath', tag: 'Download');

      // 清理空文件夹
      await _cleanEmptyDirectories(file.parent, workDir);

      // 从任务列表中移除对应的任务
      _tasks.removeWhere((t) =>
          t.workId == workId &&
          t.fileName == relativePath &&
          t.status == DownloadStatus.completed);

      // 检查该作品是否还有其他文件
      final workDirObj = Directory(workDir);
      if (await workDirObj.exists()) {
        final contents = await workDirObj.list().toList();
        // 只剩下 metadata 和 cover 文件时，删除整个作品文件夹
        final hasOtherFiles = contents.any((entity) {
          final name = entity.path.split(Platform.pathSeparator).last;
          return !LocalWorkMetadataService.shouldSkipMetadataFile(
            name,
            isRoot: true,
          );
        });

        if (!hasOtherFiles) {
          await workDirObj.delete(recursive: true);
          _log.info('作品文件夹已空，已删除: $workDir', tag: 'Download');
          // 删除所有相关任务
          _tasks.removeWhere((t) => t.workId == workId);
        }
      }

      await _saveTasks();
      _tasksController.add(List.from(_tasks));
    } catch (e) {
      _log.error('删除文件失败: $e', tag: 'Download');
      rethrow;
    }
  }

  /// 递归清理空文件夹
  Future<void> _cleanEmptyDirectories(Directory dir, String workDir) async {
    try {
      // 不要删除作品根目录
      if (dir.path == workDir) {
        return;
      }

      // 检查目录是否为空
      final contents = await dir.list().toList();
      if (contents.isEmpty) {
        _log.debug('清理空文件夹: ${dir.path}', tag: 'Download');
        await dir.delete();

        // 递归检查父目录
        await _cleanEmptyDirectories(dir.parent, workDir);
      }
    } catch (e) {
      _log.error('清理空文件夹失败: $e', tag: 'Download');
    }
  }

  Future<List<DownloadTask>> getWorkTasks(int workId) async {
    return _tasks.where((t) => t.workId == workId).toList();
  }

  Future<String?> getDownloadedFilePath(int workId, String? hash) async {
    if (hash == null) return null;

    final task = _tasks.firstWhere(
      (t) =>
          t.workId == workId &&
          t.hash == hash &&
          t.status == DownloadStatus.completed,
      orElse: () => DownloadTask(
        id: '',
        workId: 0,
        workTitle: '',
        fileName: '',
        downloadUrl: '',
        createdAt: DateTime.now(),
      ),
    );

    if (task.id.isEmpty) return null;

    final workDir = await _getWorkDownloadDirectory(workId);
    final file = File(
      DownloadFilePathService.localPathForRelativePath(
        rootPath: workDir,
        relativePath: task.fileName,
      ),
    );
    if (await file.exists()) {
      return file.path;
    }
    return null;
  }

  void _updateTask(DownloadTask updatedTask, {bool immediate = false}) {
    final index = _tasks.indexWhere((t) => t.id == updatedTask.id);
    if (index != -1) {
      _tasks[index] = updatedTask;
      _tasksController.add(List.from(_tasks));

      // 对于下载进度更新，使用延迟保存避免频繁 I/O
      if (immediate) {
        _saveTasks();
      } else {
        _scheduleDelayedSave();
      }
    }
  }

  // 延迟保存，避免频繁的 I/O 操作
  void _scheduleDelayedSave() {
    _needsSave = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      if (_needsSave) {
        _saveTasks();
        _needsSave = false;
      }
    });
  }

  // 升级旧版本的作品文件夹（尝试从 API 获取元数据）
  Future<void> _upgradeOldWorkFolders(Map<int, Directory> workFolders) async {
    for (final entry in workFolders.entries) {
      final workId = entry.key;
      final workDir = entry.value;

      // 检查是否已有可用的元数据文件（损坏/无效的视为缺失，重新补全）
      final metadataFile = _workMetadataFile(workDir);
      if (await _isUsableMetadataFile(metadataFile)) {
        continue; // 已有有效元数据，跳过
      }

      _log.info('发现本地作品文件夹，尝试补全元数据: RJ$workId', tag: 'Download');

      try {
        // 创建 API 服务实例尝试获取元数据
        final apiService = KikoeruApiService();

        // 获取作品详情
        final workData = await apiService.getWork(workId);

        // 获取文件树
        final tracks = await apiService.getWorkTracks(workId);

        // 将 tracks 转换为 children 格式并添加到 workData
        workData['children'] = tracks;

        // 保存元数据（使用相对路径）
        workData[LocalWorkMetadataService.localWorkDirNameKey] =
            p.basename(workDir.path);
        workData['localCoverPath'] = 'cover.jpg';
        await metadataFile.writeAsString(jsonEncode(workData));
        _log.info('已保存作品元数据: RJ$workId', tag: 'Download');

        // 下载封面（使用高清封面 URL）
        final host = StorageService.getString('server_host') ?? '';
        final token = StorageService.getString('auth_token') ?? '';

        if (host.isNotEmpty) {
          String normalizedHost = host;
          if (!host.startsWith('http://') && !host.startsWith('https://')) {
            normalizedHost = 'https://$host';
          }

          final coverUrl = token.isNotEmpty
              ? '$normalizedHost/api/cover/$workId?token=$token'
              : '$normalizedHost/api/cover/$workId';

          await _downloadCoverImage(workId, coverUrl,
              workDirPath: workDir.path);
          _log.info('已下载作品封面: RJ$workId', tag: 'Download');
        }

        // 尝试组织文件树结构
        await _organizeFilesIntoTree(workId, workDir, tracks);

        _log.info('作品升级成功: RJ$workId', tag: 'Download');
      } catch (e) {
        _log.warning(
          '在线补全作品元数据失败，改用本地基础元数据 RJ$workId: $e',
          tag: 'Download',
        );
        try {
          final importedMetadata =
              await _localMetadataService.loadImportedMetadata(
            workDir: workDir,
            workId: workId,
          );
          final fallbackMetadata =
              await _localMetadataService.buildFallbackMetadata(
            workId: workId,
            workDir: workDir,
            directoryName: p.basename(workDir.path),
            existingMetadata: importedMetadata,
          );
          await metadataFile.writeAsString(jsonEncode(fallbackMetadata));
          _log.info('已生成本地作品基础元数据: RJ$workId', tag: 'Download');
        } catch (fallbackError) {
          _log.error(
            '生成本地作品基础元数据失败 RJ$workId: $fallbackError',
            tag: 'Download',
          );
        }
      }
    }
  }

  // 将扁平的文件结构组织成树形结构
  Future<void> _organizeFilesIntoTree(
      int workId, Directory workDir, List<dynamic> tracks) async {
    try {
      // 构建文件树映射：hash -> 相对路径
      final Map<String, String> hashToPath = {};

      void buildPathMap(List<dynamic> items, String parentPath) {
        for (final item in items) {
          final type = item['type'] as String?;
          final title =
              item['title'] as String? ?? item['name'] as String? ?? '';
          final hash = item['hash'] as String?;

          if (type == 'folder') {
            // 文件夹，递归处理子项
            final folderPath =
                parentPath.isEmpty ? title : '$parentPath/$title';
            final children = item['children'] as List<dynamic>?;
            if (children != null) {
              buildPathMap(children, folderPath);
            }
          } else if (hash != null) {
            // 文件，记录路径映射
            final filePath = parentPath.isEmpty ? title : '$parentPath/$title';
            hashToPath[hash] = filePath;
          }
        }
      }

      buildPathMap(tracks, '');

      // 扫描工作目录中的所有文件
      await for (final entity in workDir.list()) {
        if (entity is File) {
          final fileName = entity.path.split(Platform.pathSeparator).last;

          // 跳过元数据和封面文件
          if (fileName == 'work_metadata.json' || fileName == 'cover.jpg') {
            continue;
          }

          // 尝试从文件树中找到对应的路径
          String? targetPath;
          for (final entry in hashToPath.entries) {
            final expectedFileName = entry.value.split('/').last;
            if (expectedFileName == fileName) {
              targetPath = entry.value;
              break;
            }
          }

          // 如果找到了对应路径且包含目录，则移动文件
          if (targetPath != null && targetPath.contains('/')) {
            final targetFile = File(
              DownloadFilePathService.localPathForRelativePath(
                rootPath: workDir.path,
                relativePath: DownloadFilePathService.safeRelativePath(
                  targetPath,
                ),
              ),
            );

            // 创建目标目录
            await targetFile.parent.create(recursive: true);

            // 移动文件
            try {
              await entity.rename(targetFile.path);
              _log.info('文件已重新组织: $fileName -> $targetPath', tag: 'Download');
            } catch (e) {
              // 如果 rename 失败（跨文件系统），尝试复制后删除
              await entity.copy(targetFile.path);
              await entity.delete();
              _log.info('文件已复制并重新组织: $fileName -> $targetPath',
                  tag: 'Download');
            }
          }
        }
      }

      _log.info('文件树结构组织完成: RJ$workId', tag: 'Download');
    } catch (e) {
      _log.error('组织文件树失败 RJ$workId: $e', tag: 'Download');
      // 失败不影响继续运行
    }
  }

  /// 同步磁盘文件到 work_metadata.json 的 children 文件树
  /// 确保手动添加的文件也能在离线浏览器中正确显示
  Future<void> _syncFileTreeWithDisk(int workId, Directory workDir) async {
    // 1. 收集磁盘上所有实际文件的相对路径
    final diskFiles = <String, File>{};
    // 防御：单作品文件数过多（超大/异常目录）时截断，避免扫描阻塞主 isolate
    const maxFilesPerWork = 10000;

    Future<void> collectFiles(Directory dir, String relativePath) async {
      if (diskFiles.length >= maxFilesPerWork) return;
      await for (final entity in dir.list()) {
        if (entity is File) {
          final fileName = entity.path.split(Platform.pathSeparator).last;
          // 跳过元数据、封面和临时下载文件
          if (LocalWorkMetadataService.shouldSkipMetadataFile(
            fileName,
            isRoot: relativePath.isEmpty,
          )) {
            continue;
          }
          if (diskFiles.length >= maxFilesPerWork) return;
          final fullName =
              relativePath.isEmpty ? fileName : '$relativePath/$fileName';
          diskFiles[fullName] = entity;
        } else if (entity is Directory) {
          final dirName = entity.path.split(Platform.pathSeparator).last;
          final subPath =
              relativePath.isEmpty ? dirName : '$relativePath/$dirName';
          await collectFiles(entity, subPath);
        }
      }
    }

    await collectFiles(workDir, '');
    if (diskFiles.isEmpty) return;

    // 2. 加载现有元数据
    final metadataFile = _workMetadataFile(workDir);
    Map<String, dynamic>? metadata;

    if (await metadataFile.exists()) {
      try {
        metadata = jsonDecode(await metadataFile.readAsString())
            as Map<String, dynamic>;
      } catch (e) {
        _log.error('读取元数据失败: RJ$workId, $e', tag: 'Download');
      }
    }

    bool metadataCreated = false;
    bool metadataChanged = false;
    if (metadata == null) {
      // 没有任何元数据，创建基础元数据
      metadata = await _localMetadataService.buildFallbackMetadata(
        workId: workId,
        workDir: workDir,
        directoryName: p.basename(workDir.path),
      );
      metadataCreated = true;
    } else {
      if (_metadataIdAsPositiveInt(metadata['id']) == null) {
        metadata['id'] = workId;
        metadataChanged = true;
      }
      if (metadata[LocalWorkMetadataService.localWorkDirNameKey] !=
          p.basename(workDir.path)) {
        metadata[LocalWorkMetadataService.localWorkDirNameKey] =
            p.basename(workDir.path);
        metadataChanged = true;
      }

      final detectedCover = await _localMetadataService.detectCoverRelativePath(
        workDir,
        metadata['localCoverPath'],
      );
      if (detectedCover != null &&
          metadata['localCoverPath'] != detectedCover) {
        metadata['localCoverPath'] = detectedCover;
        metadataChanged = true;
      }
    }

    // 3. 收集已有文件树中所有文件的相对路径
    final existingChildren = (metadata['children'] as List<dynamic>?) ?? [];
    final knownPaths = <String>{};

    void collectKnownPaths(List<dynamic> items, String parentPath) {
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        final type = item['type'] as String? ?? '';
        if (type == 'folder') {
          final folderPath = DownloadFilePathService.localRelativePathForItem(
            item,
            parentPath,
          );
          final children = item['children'] as List<dynamic>?;
          if (children != null) {
            collectKnownPaths(children, folderPath);
          }
        } else {
          knownPaths.add(
            DownloadFilePathService.localRelativePathForItem(item, parentPath),
          );
        }
      }
    }

    collectKnownPaths(existingChildren, '');

    // 4. 找出磁盘上有但文件树中没有的文件
    final newFiles = <String, File>{};
    for (final entry in diskFiles.entries) {
      if (!knownPaths.contains(entry.key)) {
        newFiles[entry.key] = entry.value;
      }
    }

    if (newFiles.isEmpty && !metadataCreated && !metadataChanged) return;

    // 5. 将新文件添加到 children 树中的正确位置
    final mutableChildren = List<dynamic>.from(existingChildren);

    for (final entry in newFiles.entries) {
      final relativePath = entry.key;
      final file = entry.value;
      final parts = relativePath.split('/');

      final fileType = FileIconUtils.inferFileType(parts.last);
      final syntheticHash = 'local:$relativePath';

      int? fileSize;
      try {
        fileSize = await file.length();
      } catch (_) {}

      final fileEntry = <String, dynamic>{
        'type': fileType,
        'title': parts.last,
        'hash': syntheticHash,
        'localRelativePath': relativePath,
        'relativePath': relativePath,
        if (fileSize != null) 'size': fileSize,
      };

      if (parts.length == 1) {
        // 根级别文件
        mutableChildren.add(fileEntry);
      } else {
        // 嵌套文件，确保父文件夹存在
        var currentLevel = mutableChildren;
        for (var i = 0; i < parts.length - 1; i++) {
          final folderName = parts[i];
          // 查找或创建文件夹
          Map<String, dynamic>? folder;
          for (final item in currentLevel) {
            if (item is Map<String, dynamic> &&
                item['type'] == 'folder' &&
                item['title'] == folderName) {
              folder = item;
              break;
            }
          }

          if (folder == null) {
            folder = <String, dynamic>{
              'type': 'folder',
              'title': folderName,
              'localRelativePath': parts.take(i + 1).join('/'),
              'children': <dynamic>[],
            };
            currentLevel.add(folder);
          } else if (folder['children'] == null) {
            folder['children'] = <dynamic>[];
          }
          currentLevel = folder['children'] as List<dynamic>;
        }
        currentLevel.add(fileEntry);
      }

      _log.info('添加手动文件到文件树: $relativePath (RJ$workId)', tag: 'Download');
    }

    if (newFiles.isNotEmpty || metadataCreated || metadataChanged) {
      metadata['children'] = mutableChildren;
      await metadataFile.writeAsString(jsonEncode(metadata));
      _log.info('已更新作品文件树: RJ$workId, 新增 ${newFiles.length} 个文件',
          tag: 'Download');
    }
  }

  Future<void> _loadTasks() async {
    try {
      final prefs = await StorageService.getPrefs();
      final tasksJson = prefs.getString(_tasksKey);
      if (tasksJson != null) {
        final List<dynamic> tasksList = jsonDecode(tasksJson);
        _tasks.clear();
        _tasks.addAll(
          tasksList.map((json) => DownloadTask.fromJson(json)).toList(),
        );
      }
    } catch (e) {
      _log.error('加载下载任务失败: $e', tag: 'Download');
    }
  }

  // 从硬盘加载元数据并补充到任务中
  /// 公开方法：从硬盘完全同步下载任务
  /// 扫描硬盘文件系统，删除不存在的任务，添加新发现的文件
  /// 用于手动刷新，确保下载完成界面与硬盘文件完全一致
  Future<void> reloadMetadataFromDisk() async {
    try {
      _log.info('开始从硬盘同步任务...', tag: 'Download');

      // 获取下载目录
      final downloadDir = await _getDownloadDirectory();
      if (!await downloadDir.exists()) {
        _log.warning('下载目录不存在，清空所有已完成任务', tag: 'Download');
        _tasks.removeWhere((t) => t.status == DownloadStatus.completed);
        _tasksController.add(List.from(_tasks));
        await _saveTasks();
        return;
      }

      // 扫描硬盘上所有的作品文件夹
      final workFolders = <int, Directory>{};
      var ignoredDirectoryCount = 0;
      await for (final entity in downloadDir.list()) {
        if (entity is! Directory) continue;

        final folder = _localMetadataService.parseWorkFolder(entity);
        if (folder != null) {
          workFolders[folder.id] = entity;
        } else {
          ignoredDirectoryCount++;
          _log.debug('忽略无法识别为作品的目录: ${entity.path}', tag: 'Download');
        }
      }

      _log.info(
        '发现 ${workFolders.length} 个作品文件夹，忽略 $ignoredDirectoryCount 个目录',
        tag: 'Download',
      );

      // 第一步：删除硬盘上不存在的已完成任务
      final tasksToRemove = <String>[];
      for (final task in _tasks) {
        if (task.status == DownloadStatus.completed) {
          final workDir = workFolders[task.workId];
          if (workDir == null) {
            // 作品文件夹不存在，删除任务
            tasksToRemove.add(task.id);
            _log.warning('作品文件夹不存在，删除任务: ${task.workTitle}', tag: 'Download');
          } else {
            // 检查文件是否存在
            final file = File(
              DownloadFilePathService.localPathForRelativePath(
                rootPath: workDir.path,
                relativePath: task.fileName,
              ),
            );
            if (!await file.exists()) {
              tasksToRemove.add(task.id);
              _log.warning('文件不存在，删除任务: ${task.fileName}', tag: 'Download');
            }
          }
        }
      }

      // 执行删除
      if (tasksToRemove.isNotEmpty) {
        _tasks.removeWhere((t) => tasksToRemove.contains(t.id));
        _log.info('删除了 ${tasksToRemove.length} 个不存在的任务', tag: 'Download');
      }

      // 第二步：检查并升级旧版本文件（没有元数据的文件）
      await _upgradeOldWorkFolders(workFolders);

      // 第三步：同步磁盘文件到文件树（确保手动添加的文件能正确显示）
      for (final entry in workFolders.entries) {
        try {
          await _syncFileTreeWithDisk(entry.key, entry.value);
        } catch (e) {
          _log.error('同步文件树失败 RJ${entry.key}: $e', tag: 'Download');
        }
      }

      // 第四步：扫描硬盘上的所有文件，添加新发现的任务
      final newTasks = <DownloadTask>[];
      // 任务索引（workId:fileName -> task），避免对每个文件线性扫描 _tasks 造成 O(n²)
      final taskIndex = <String, DownloadTask>{
        for (final t in _tasks) '${t.workId}:${t.fileName}': t,
      };
      for (final entry in workFolders.entries) {
        final workId = entry.key;
        final workDir = entry.value;

        // 加载元数据（现在可能已经通过升级创建了）
        final metadata = await _loadWorkMetadata(workId);
        final workTitle = metadata?['title'] as String? ?? 'RJ$workId';
        if (metadata == null) {
          _log.warning(
            '扫描作品文件时未加载到元数据，将创建无详情任务: workId=$workId, dir=${workDir.path}',
            tag: 'Download',
          );
        }

        // 递归扫描文件夹中的所有文件
        // 防御：单个作品文件数超过阈值时停止扫描该作品，
        // 避免超大目录（导入异常/海量文件）阻塞主 isolate
        const maxFilesPerWork = 10000;
        var scannedFileCount = 0;
        Future<void> scanDirectory(Directory dir, String relativePath) async {
          if (scannedFileCount > maxFilesPerWork) return;
          await for (final entity in dir.list()) {
            if (entity is File) {
              final fileName = entity.path.split(Platform.pathSeparator).last;

              // 跳过元数据、封面和临时下载文件
              if (LocalWorkMetadataService.shouldSkipMetadataFile(
                fileName,
                isRoot: relativePath.isEmpty,
              )) {
                continue;
              }

              if (++scannedFileCount > maxFilesPerWork) {
                _log.warning(
                  '作品 RJ$workId 文件数超过 $maxFilesPerWork，停止扫描剩余文件',
                  tag: 'Download',
                );
                return;
              }

              // 构建相对路径下的文件名
              final fullFileName =
                  relativePath.isEmpty ? fileName : '$relativePath/$fileName';

              // 检查该文件是否已有对应的任务（使用索引 O(1) 查询）
              final existingTask = taskIndex['$workId:$fullFileName'];

              if (existingTask == null) {
                // 发现新文件，创建任务
                final newTask = DownloadTask(
                  id: '${workId}_${fullFileName}_${DateTime.now().millisecondsSinceEpoch}',
                  workId: workId,
                  workTitle: workTitle,
                  fileName: fullFileName,
                  downloadUrl: '', // 硬盘扫描的任务没有下载URL
                  status: DownloadStatus.completed,
                  totalBytes: await entity.length(),
                  downloadedBytes: await entity.length(),
                  createdAt: entity.statSync().modified,
                  completedAt: entity.statSync().modified,
                  workMetadata: metadata,
                );
                newTasks.add(newTask);
                _log.info('发现新文件: $fullFileName ($workTitle)', tag: 'Download');
              }
            } else if (entity is Directory) {
              // 递归扫描子目录
              final dirName = entity.path.split(Platform.pathSeparator).last;
              final subPath =
                  relativePath.isEmpty ? dirName : '$relativePath/$dirName';
              await scanDirectory(entity, subPath);
            }
          }
        }

        await scanDirectory(workDir, '');
      }

      // 添加新任务
      if (newTasks.isNotEmpty) {
        _tasks.addAll(newTasks);
        _log.info('添加了 ${newTasks.length} 个新任务', tag: 'Download');
      }

      // 第五步：为所有已完成任务更新元数据（包含新同步的文件树）
      for (var i = 0; i < _tasks.length; i++) {
        final task = _tasks[i];
        if (task.status == DownloadStatus.completed) {
          final metadata = await _loadWorkMetadata(task.workId);
          if (metadata != null) {
            _tasks[i] = task.copyWith(workMetadata: metadata);
          } else {
            _log.warning(
              '完成任务仍缺少元数据: workId=${task.workId}, task=${task.id}, '
              'file=${task.fileName}',
              tag: 'Download',
            );
          }
        }
      }

      // 通知更新并保存
      _tasksController.add(List.from(_tasks));
      await _saveTasks();

      _log.info('同步完成：删除 ${tasksToRemove.length} 个，新增 ${newTasks.length} 个',
          tag: 'Download');
    } catch (e) {
      _log.error('从硬盘同步任务失败: $e', tag: 'Download');
      rethrow;
    }
  }

  /// 扫描下载目录，返回磁盘上存在的作品目录元数据。
  /// 与 [reloadMetadataFromDisk] 不同：即使某个作品已无任何下载任务
  /// （例如本地文件被全部误删、只剩 work_metadata.json），只要目录存在
  /// 也会返回，供"已下载"页展示并提供补充下载入口。
  Future<Map<int, Map<String, dynamic>>> getDiskWorks() async {
    final result = <int, Map<String, dynamic>>{};
    try {
      final downloadDir = await _getDownloadDirectory();
      if (!await downloadDir.exists()) return result;

      var scannedCount = 0;
      await for (final entity in downloadDir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        // 防御：下载目录第一层作品过多（导入异常/海量目录）时截断，
        // 避免扫描耗时过长阻塞主 isolate 导致页面卡死
        if (++scannedCount > 500) break;
        final parsed = _localMetadataService.parseWorkFolder(entity);
        if (parsed == null) continue;

        final metadata = await _loadWorkMetadata(parsed.id);
        if (metadata != null) {
          result[parsed.id] = metadata;
        } else {
          // 目录存在但无 work_metadata.json，尝试生成本地基础元数据
          final fallback = await _localMetadataService.buildFallbackMetadata(
            workId: parsed.id,
            workDir: entity,
            directoryName: p.basename(entity.path),
          );
          result[parsed.id] = fallback;
        }
      }
    } catch (e) {
      _log.error('扫描本地作品目录失败: $e', tag: 'Download');
    }
    return result;
  }

  /// 检查元数据文件是否存在且内容有效（JSON 可解析）。
  /// 导入异常时可能写入半截/损坏的 work_metadata.json，应视为缺失以便重新补全。
  Future<bool> _isUsableMetadataFile(File metadataFile) async {
    if (!await metadataFile.exists()) return false;
    try {
      final decoded = jsonDecode(await metadataFile.readAsString());
      return decoded is Map;
    } catch (_) {
      return false;
    }
  }

  bool _metadataUpgradeInProgress = false;

  /// 后台补全缺失/损坏/不完整的作品元数据（标题/标签/声优/日期/封面），不阻塞调用方。
  /// 对磁盘上无有效 work_metadata.json 的作品先生成本地基础元数据；
  /// 对缺关键字段（标题为纯 RJ 号、无标签等）的作品从在线 API 合并补全；
  /// 对无有效封面的作品下载 cover.jpg。
  /// 供"已下载"页进入时触发：先展示回退元数据，补全完成后通知任务列表刷新。
  Future<void> ensureLocalMetadataCompleteness() async {
    if (_metadataUpgradeInProgress) return;
    _metadataUpgradeInProgress = true;
    try {
      final downloadDir = await _getDownloadDirectory();
      if (!await downloadDir.exists()) {
        _log.warning('下载目录不存在，跳过元数据补全', tag: 'Download');
        return;
      }

      // 收集作品目录（不递归，仅第一层）
      final works = <int, Directory>{};
      await for (final entity in downloadDir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final folder = _localMetadataService.parseWorkFolder(entity);
        if (folder != null) works[folder.id] = entity;
      }
      if (works.isEmpty) return;

      _log.info(
        '开始后台补全 ${works.length} 个作品元数据',
        tag: 'Download',
      );

      var upgradedCount = 0;
      for (final entry in works.entries) {
        final workId = entry.key;
        final workDir = entry.value;
        try {
          // 1) 无有效元数据文件时，先生成本地基础元数据并写盘
          var metadata = await _loadWorkMetadata(workId);
          if (metadata == null) {
            final imported =
                await _localMetadataService.loadImportedMetadata(
              workDir: workDir,
              workId: workId,
            );
            metadata = await _localMetadataService.buildFallbackMetadata(
              workId: workId,
              workDir: workDir,
              directoryName: p.basename(workDir.path),
              existingMetadata: imported,
            );
            await _workMetadataFile(workDir)
                .writeAsString(jsonEncode(metadata), flush: true);
            _log.info('已生成本地基础元数据: RJ$workId', tag: 'Download');
          }

          // 2) 缺关键字段（标题为 RJ 号/无标签/无声优/无日期）时在线合并补全
          if (needsOnlineMetadataScrape(metadata)) {
            await scrapeWorkMetadata(workId);
            metadata = await _loadWorkMetadata(workId) ?? metadata;
          }

          // 3) 本地无有效封面时下载封面
          await _ensureWorkCover(workId, workDir, metadata);
          upgradedCount++;
        } catch (e) {
          _log.warning('补全作品元数据失败 RJ$workId: $e', tag: 'Download');
        }
      }

      // 补全完成后，刷新已完成任务的元数据缓存（磁盘可能已更新标题/封面/标签），
      // 否则 UI 仍显示旧的任务缓存（如纯 RJ 号标题）。
      var refreshedCount = 0;
      for (var i = 0; i < _tasks.length; i++) {
        final task = _tasks[i];
        if (task.status != DownloadStatus.completed) continue;
        final metadata = await _loadWorkMetadata(task.workId);
        if (metadata != null) {
          _tasks[i] = task.copyWith(workMetadata: metadata);
          refreshedCount++;
        }
      }

      // 通知任务列表（触发"已下载"页刷新）并保存到本地
      _tasksController.add(List.from(_tasks));
      await _saveTasks();
      _log.info(
        '作品元数据后台补全完成，处理 $upgradedCount 个作品，刷新任务缓存 $refreshedCount 条',
        tag: 'Download',
      );
    } catch (e) {
      _log.error('作品元数据后台补全失败: $e', tag: 'Download');
    } finally {
      _metadataUpgradeInProgress = false;
    }
  }

  /// 下载缺失的作品封面（cover.jpg）。已有有效封面文件时跳过。
  Future<void> _ensureWorkCover(
    int workId,
    Directory workDir,
    Map<String, dynamic> metadata,
  ) async {
    // 已有有效封面路径且文件存在 → 跳过
    final coverPath = metadata['localCoverPath'] as String?;
    if (coverPath != null && coverPath.trim().isNotEmpty) {
      final existing = File(
        DownloadFilePathService.localPathForRelativePath(
          rootPath: workDir.path,
          relativePath: coverPath,
        ),
      );
      if (await existing.exists()) return;
    }

    final host = StorageService.getString('server_host') ?? '';
    if (host.isEmpty) return;
    String normalizedHost = host;
    if (!host.startsWith('http://') && !host.startsWith('https://')) {
      normalizedHost = 'https://$host';
    }
    final token = StorageService.getString('auth_token') ?? '';

    // 优先使用在线元数据中的封面 URL，否则回退到 API 封面接口
    String? coverUrl;
    final onlineCover = metadata['coverUrl'] as String?;
    if (onlineCover != null && onlineCover.trim().isNotEmpty) {
      coverUrl = onlineCover.startsWith('http')
          ? onlineCover
          : '$normalizedHost$onlineCover';
    } else {
      coverUrl = token.isNotEmpty
          ? '$normalizedHost/api/cover/$workId?token=$token'
          : '$normalizedHost/api/cover/$workId';
    }

    final localCover =
        await _downloadCoverImage(workId, coverUrl, workDirPath: workDir.path);
    if (localCover != null) {
      await _saveWorkMetadata(
        workId,
        {...metadata, 'localCoverPath': 'cover.jpg'},
        null,
      );
      _log.info('已下载作品封面: RJ$workId', tag: 'Download');
    }
  }

  // 判断本地元数据是否缺少可在线补全的关键字段（标签/声优/发布日期/真实标题）
  static bool needsOnlineMetadataScrape(Map<String, dynamic> metadata) {
    if (metadata['tags'] is! List || (metadata['tags'] as List).isEmpty) {
      return true;
    }
    if (metadata['vas'] is! List || (metadata['vas'] as List).isEmpty) {
      return true;
    }
    if (metadata['release'] == null ||
        (metadata['release'] as String? ?? '').trim().isEmpty) {
      return true;
    }
    // 标题为空或仅为纯 RJ 编号（如导入文件夹名就是 RJ 号）时也补全真实标题
    final title = (metadata['title'] as String? ?? '').trim();
    if (title.isEmpty || isPureRjCode(title)) {
      return true;
    }
    return false;
  }

  // 判断标题是否为纯 RJ 编号（如 "RJ01581782"）
  static bool isPureRjCode(String title) {
    return RegExp(r'^RJ\d+$', caseSensitive: false).hasMatch(title.trim());
  }

  /// 保存翻译后的标题：`title` 写翻译结果，原文保存到 `originalTitle`（仅首次），
  /// 返回是否写入成功。不影响下载（下载基于 hash/相对路径/URL）。
  Future<bool> saveTranslatedTitle(int workId, String translatedTitle) async {
    try {
      final translated = translatedTitle.trim();
      if (translated.isEmpty) return false;

      final metadata = await _loadWorkMetadata(workId);
      if (metadata == null) return false;

      final currentTitle = (metadata['title'] as String? ?? '').trim();
      if (currentTitle == translated) return false; // 无变化

      if (metadata['originalTitle'] == null) {
        metadata['originalTitle'] = currentTitle;
      }
      metadata['title'] = translated;
      await _saveWorkMetadata(workId, metadata, null);
      _log.info('已保存翻译标题: workId=$workId', tag: 'Download');
      return true;
    } catch (e) {
      _log.error('保存翻译标题失败: workId=$workId, 错误: $e', tag: 'Download');
      return false;
    }
  }

  // 刮削在线元数据：拉取在线作品详情，合并补全本地缺失字段并写回 work_metadata.json。
  // 本地元数据已完整（tags/声优/日期齐全）时直接跳过，避免无谓请求。
  Future<bool> scrapeWorkMetadata(int workId) async {
    try {
      final localMetadata = await _loadWorkMetadata(workId);
      if (localMetadata == null) return false;
      if (!needsOnlineMetadataScrape(localMetadata)) return false;

      final host = StorageService.getString('server_host') ?? '';
      final token = StorageService.getString('auth_token') ?? '';
      if (host.isEmpty) return false;

      final apiService = KikoeruApiService();
      apiService.init(token, host);
      final online = await apiService.getWork(workId);
      if (online.isEmpty) return false;

      // 合并：以在线详情为基底，保留本地非空字段（本地文件树/封面等不丢失）。
      // 特例：本地标题为纯 RJ 编号（导入时无法推断真实标题）时，使用在线真实标题。
      final merged = Map<String, dynamic>.from(online);
      localMetadata.forEach((key, value) {
        if (value == null) return;
        if (value is String && value.trim().isEmpty) return;
        if (value is List && value.isEmpty) return;
        if (value is Map && value.isEmpty) return;
        if (key == 'title' &&
            value is String &&
            isPureRjCode(value)) {
          return; // 让位给在线真实标题
        }
        merged[key] = value;
      });
      await _saveWorkMetadata(workId, merged, null);
      _log.info('已刮削并补全在线元数据: workId=$workId', tag: 'Download');
      return true;
    } catch (e) {
      _log.error('刮削在线元数据失败: workId=$workId, 错误: $e', tag: 'Download');
      return false;
    }
  }

  Future<void> _saveTasks() async {
    try {
      final prefs = await StorageService.getPrefs();
      final tasksJson = jsonEncode(_tasks.map((t) => t.toJson()).toList());
      await prefs.setString(_tasksKey, tasksJson);
    } catch (e) {
      _log.error('保存下载任务失败: $e', tag: 'Download');
    }
  }

  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _tasksController.close();
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();

    // 确保最后保存一次
    if (_needsSave) {
      _saveTasks();
    }
  }

  // O9: 清理孤立的临时文件（.downloading 文件）
  // 扫描下载目录，删除没有对应下载任务的临时文件
  Future<void> _cleanupOrphanedTempFiles() async {
    try {
      _log.info('开始清理孤立的临时文件...', tag: 'Download');
      
      final downloadDir = await _getDownloadDirectory();
      if (!await downloadDir.exists()) {
        return;
      }

      int deletedCount = 0;
      int deletedSize = 0;

      // 递归扫描下载目录
      await for (final entity in downloadDir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.downloading')) {
          // 检查是否有对应的下载任务
          final hasCorrespondingTask = _tasks.any((task) {
            final workDir = Directory('${downloadDir.path}/${task.workId}');
            final filePath = DownloadFilePathService.localPathForRelativePath(
              rootPath: workDir.path,
              relativePath: task.fileName,
            );
            return '$filePath.downloading' == entity.path;
          });

          if (!hasCorrespondingTask) {
            // 孤立的临时文件，删除它
            try {
              final fileSize = await entity.length();
              await entity.delete();
              deletedCount++;
              deletedSize += fileSize;
              _log.info('已删除孤立临时文件: ${entity.path} (${_formatBytes(fileSize)})', tag: 'Download');
            } catch (e) {
              _log.error('删除临时文件失败: ${entity.path}, 错误: $e', tag: 'Download');
            }
          }
        }
      }

      if (deletedCount > 0) {
        _log.info('临时文件清理完成：删除 $deletedCount 个文件，释放 ${_formatBytes(deletedSize)}', tag: 'Download');
      } else {
        _log.info('没有发现孤立的临时文件', tag: 'Download');
      }
    } catch (e) {
      _log.error('清理临时文件失败: $e', tag: 'Download');
    }
  }

  // 格式化字节大小（辅助方法）
  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  // O10: 清理所有下载文件
  // 删除下载目录中的所有文件，但保留下载任务记录
  Future<void> clearAllDownloads() async {
    try {
      _log.info('开始清理所有下载文件...', tag: 'Download');
      
      final downloadDir = await _getDownloadDirectory();
      if (!await downloadDir.exists()) {
        _log.info('下载目录不存在，无需清理', tag: 'Download');
        return;
      }

      int deletedCount = 0;
      int deletedSize = 0;

      // 递归删除下载目录中的所有文件和子目录
      await for (final entity in downloadDir.list(recursive: false)) {
        try {
          if (entity is File) {
            final fileSize = await entity.length();
            await entity.delete();
            deletedCount++;
            deletedSize += fileSize;
          } else if (entity is Directory) {
            // 递归删除作品目录
            await for (final subEntity in entity.list(recursive: true)) {
              if (subEntity is File) {
                final fileSize = await subEntity.length();
                deletedSize += fileSize;
              }
            }
            await entity.delete(recursive: true);
            deletedCount++;
          }
        } catch (e) {
          _log.error('删除失败: ${entity.path}, 错误: $e', tag: 'Download');
        }
      }

      // 将已完成的任务标记为失败（因为文件已被删除）
      for (var i = 0; i < _tasks.length; i++) {
        final task = _tasks[i];
        if (task.status == DownloadStatus.completed) {
          _tasks[i] = task.copyWith(
            status: DownloadStatus.failed,
            error: '文件已被清理',
          );
        }
      }
      _tasksController.add(List.from(_tasks));
      await _saveTasks();

      if (deletedCount > 0) {
        _log.info('下载文件清理完成：删除 $deletedCount 个文件/目录，释放 ${_formatBytes(deletedSize)}', tag: 'Download');
      } else {
        _log.info('没有发现需要清理的下载文件', tag: 'Download');
      }
    } catch (e) {
      _log.error('清理下载文件失败: $e', tag: 'Download');
      rethrow;
    }
  }

  // ==================== M1: 从原 kikoeru 迁移 ====================

  /// 从原 kikoeru（com.zinhao.kikoeru）导入下载文件。
  ///
  /// 源目录通常是 /sdcard/KikoeruLib/libs_work/，其下子目录以纯数字 workId 命名。
  /// 复制完成后调用 [reloadMetadataFromDisk] 自动补全 work_metadata.json 和任务记录，
  /// 元数据缺失时由 [_upgradeOldWorkFolders] 走 API→本地兜底 三级补全（风险点1）。
  Future<ImportResult> importFromLegacyKikoeru(
    Directory sourceDir, {
    bool moveInsteadOfCopy = false,
    void Function(int done, int total, int bytesCopied)? onProgress,
  }) async {
    final result = ImportResult();
    try {
      debugPrint('[IMPORT] sourceDir=${sourceDir.path}');
      // 风险点2：校验源目录，防止自引用
      final validation = await _validateSourceDir(sourceDir);
      if (!validation.ok) {
        result.error = validation.reason;
        _log.warning('导入校验失败: ${validation.reason}', tag: 'Download');
        return result;
      }

      final downloadDir = await _getDownloadDirectory();
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }

      // 扫描源目录子目录
      final subDirs = <Directory>[];
      await for (final entity in sourceDir.list(followLinks: false)) {
        if (entity is Directory) subDirs.add(entity);
      }

      result.total = subDirs.length;
      _log.info('发现 ${subDirs.length} 个子目录待迁移', tag: 'Download');

      int copiedBytes = 0;
      for (final subDir in subDirs) {
        try {
          // 风险点5：三级识别 workId
          final workId = await _identifyWorkId(subDir);
          debugPrint('[IMPORT] subDir=${subDir.path} workId=$workId');
          if (workId == null) {
            result.skipped.add(ImportSkip(
              path: subDir.path,
              reason: '无法识别为作品目录',
            ));
            continue;
          }

          // 目标目录：KikoFlu 下载目录/<workId>
          final targetDir =
              Directory(p.join(downloadDir.path, workId.toString()));

          // 若目标已存在，跳过避免覆盖（用户可先清理再导入）
          if (await targetDir.exists()) {
            result.skipped.add(ImportSkip(
              path: subDir.path,
              reason: '目标已存在 RJ$workId，跳过',
            ));
            continue;
          }

          await targetDir.create(recursive: true);

          // 风险点3：流式复制，带进度回调
          final bytes = await _copyWorkDirectory(
            subDir,
            targetDir,
            onProgress: (b) {
              copiedBytes += b;
              onProgress?.call(result.done, result.total, copiedBytes);
            },
          );

          result.success++;
          result.totalBytes += bytes;
          _log.info('已迁移 RJ$workId: ${_formatBytes(bytes)}', tag: 'Download');
        } catch (e) {
          result.failed
              .add(ImportSkip(path: subDir.path, reason: e.toString()));
          _log.error('迁移子目录失败: ${subDir.path}, $e', tag: 'Download');
        } finally {
          result.done++;
          onProgress?.call(result.done, result.total, copiedBytes);
        }
      }

      // 复制完成后，调用磁盘同步自动补全元数据和任务记录
      _log.info('文件复制完成，开始同步元数据和任务...', tag: 'Download');
      await reloadMetadataFromDisk();
      _log.info(
        '导入完成：成功 ${result.success}，跳过 ${result.skipped.length}，'
        '失败 ${result.failed.length}，共 ${_formatBytes(result.totalBytes)}',
        tag: 'Download',
      );
    } catch (e) {
      result.error = e.toString();
      _log.error('从原 kikoeru 导入失败: $e', tag: 'Download');
    }
    return result;
  }

  /// 风险点2：校验源目录，防止选到 KikoFlu 自身下载目录或其子目录。
  Future<_DirValidation> _validateSourceDir(Directory sourceDir) async {
    if (!await sourceDir.exists()) {
      return _DirValidation.fail('源目录不存在');
    }
    final downloadDir = await _getDownloadDirectory();
    try {
      final srcReal = sourceDir.resolveSymbolicLinksSync();
      final dstReal = downloadDir.resolveSymbolicLinksSync();
      if (srcReal == dstReal) {
        return _DirValidation.fail('源目录不能是 KikoFlu 当前的下载目录');
      }
      if (srcReal.startsWith('$dstReal${Platform.pathSeparator}')) {
        return _DirValidation.fail('源目录不能位于 KikoFlu 下载目录之内');
      }
      // 源目录是下载目录的祖先（包含下载目录本身）时，复制会递归复制自身导致爆炸
      if (dstReal.startsWith('$srcReal${Platform.pathSeparator}')) {
        return _DirValidation.fail('源目录不能包含 KikoFlu 当前的下载目录');
      }
    } catch (_) {
      // resolveSymbolicLinksSync 可能失败，忽略
    }
    return _DirValidation.ok();
  }

  /// 风险点5：三级识别 workId
  /// 1. 目录名解析（纯数字 / RJxxxxxx）
  /// 2. 目录内 .json 元数据文件的 source_id / workId / id 字段
  /// 3. 目录内文件名匹配 RJxxxxxx
  Future<int?> _identifyWorkId(Directory subDir) async {
    // 一级：目录名解析
    final fromName = LocalWorkMetadataService.parseWorkIdFromName(
      p.basename(subDir.path),
    );
    if (fromName != null) return fromName;

    // 二级：扫描目录内 .json 元数据文件
    try {
      await for (final entity in subDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.endsWith('.json')) continue;
        try {
          final decoded = jsonDecode(await entity.readAsString());
          if (decoded is Map) {
            for (final key in ['source_id', 'workId', 'work_id', 'id']) {
              final parsed = _metadataIdAsPositiveInt(decoded[key]);
              if (parsed != null) return parsed;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}

    // 三级：递归扫描文件名中的 RJxxxxxx
    final rx = RegExp(r'RJ(\d{5,8})', caseSensitive: false);
    try {
      await for (final entity in subDir.list(recursive: true)) {
        if (entity is! File) continue;
        final m = rx.firstMatch(p.basename(entity.path));
        if (m != null) {
          final parsed = int.tryParse(m.group(1)!);
          if (parsed != null && parsed > 0) return parsed;
        }
      }
    } catch (_) {}

    return null;
  }

  /// 风险点3：流式复制作品目录，分块读写避免内存峰值。
  Future<int> _copyWorkDirectory(
    Directory source,
    Directory target, {
    void Function(int bytes)? onProgress,
  }) async {
    int totalBytes = 0;
    try {
      // 第二道防线：目标目录位于源目录之内时中止（防止递归复制自身）
      try {
        final srcReal = source.resolveSymbolicLinksSync();
        final tgtReal = target.resolveSymbolicLinksSync();
        if (srcReal == tgtReal ||
            tgtReal.startsWith('$srcReal${Platform.pathSeparator}')) {
          _log.error(
            '复制目标位于源目录之内，已中止复制: source=$srcReal, target=$tgtReal',
            tag: 'Download',
          );
          return 0;
        }
      } catch (_) {
        // resolveSymbolicLinksSync 失败时忽略，继续尝试
      }

      await for (final entity
          in source.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        // 防御：跳过目标目录内的文件（防止源包含目标时的递归复制）
        if (entity.path.startsWith(
          '${target.path}${Platform.pathSeparator}',
        )) {
          continue;
        }
        final rel = p.relative(entity.path, from: source.path);
        final destPath = p.join(target.path, rel);
        await Directory(p.dirname(destPath)).create(recursive: true);
        final size = await _copyFileWithProgress(entity, File(destPath));
        totalBytes += size;
        onProgress?.call(size);
      }
    } catch (e) {
      debugPrint('[IMPORT] _copyWorkDirectory error: $e (source=${source.path})');
      rethrow;
    }
    debugPrint('[IMPORT] _copyWorkDirectory done: $totalBytes bytes, '
        'source=${source.path} target=${target.path}');
    return totalBytes;
  }

  Future<int> _copyFileWithProgress(File source, File dest) async {
    // openRead() 默认按流分块读取，避免一次性读入大文件
    final input = source.openRead();
    final output = dest.openWrite();
    int total = 0;
    try {
      await for (final chunk in input) {
        output.add(chunk);
        total += chunk.length;
      }
      await output.flush();
      await output.close();
    } catch (e) {
      await output.close();
      rethrow;
    }
    return total;
  }

  // ==================== M2: 目录级删除 ====================

  /// 删除作品内指定目录（含子内容），并清理对应任务。
  /// 删除前应由 UI 层调用确认对话框（风险点4）。
  Future<void> deleteDirectory(int workId, String relativeDirPath) async {
    try {
      final workDir = await _findExistingWorkDirectory(workId);
      if (workDir == null) {
        _log.warning('删除目录失败：未找到作品目录 RJ$workId', tag: 'Download');
        return;
      }
      final dirPath = DownloadFilePathService.localPathForRelativePath(
        rootPath: workDir.path,
        relativePath: relativeDirPath,
      );
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        _log.warning('目录不存在: $dirPath', tag: 'Download');
        return;
      }

      // 收集受影响的任务（fileName 以该目录开头）
      final normalizedDir =
          DownloadFilePathService.normalizeRelativePath(relativeDirPath);
      final affected = _tasks
          .where((t) =>
              t.workId == workId && t.fileName.startsWith('$normalizedDir/'))
          .toList();

      // 删除目录
      await dir.delete(recursive: true);
      _log.info('已删除目录: $normalizedDir (RJ$workId)', tag: 'Download');

      // 移除对应任务
      if (affected.isNotEmpty) {
        final ids = affected.map((t) => t.id).toSet();
        _tasks.removeWhere((t) => ids.contains(t.id));
        _tasksController.add(List.from(_tasks));
        await _saveTasks();
      }

      // 清理空父目录
      await _cleanEmptyDirectories(dir.parent, workDir.path);

      // 若作品目录只剩 metadata/cover，递归删除整个作品
      final remaining = <FileSystemEntity>[];
      await for (final e in workDir.list(followLinks: false)) {
        remaining.add(e);
      }
      final onlyMeta = remaining.isNotEmpty &&
          remaining.every((e) {
            final name = p.basename(e.path);
            return LocalWorkMetadataService.reservedFileNames.contains(name) ||
                LocalWorkMetadataService.shouldSkipMetadataFile(name,
                    isRoot: true);
          });
      if (onlyMeta) {
        await workDir.delete(recursive: true);
        _tasks.removeWhere((t) => t.workId == workId);
        _tasksController.add(List.from(_tasks));
        await _saveTasks();
        _log.info('作品目录已清空，递归删除 RJ$workId', tag: 'Download');
      }
    } catch (e) {
      _log.error('删除目录失败: $e', tag: 'Download');
      rethrow;
    }
  }

  // ==================== M3: 作品级批量操作 ====================

  /// 继续该作品所有失败任务（resumeTask 已含断点续传逻辑 O8）。
  Future<void> retryFailedByWork(int workId) async {
    final failed = _tasks
        .where((t) =>
            t.workId == workId && t.status == DownloadStatus.failed)
        .toList();
    for (final task in failed) {
      await resumeTask(task.id);
    }
    _log.info('已触发 RJ$workId 的 ${failed.length} 个失败任务重试',
        tag: 'Download');
  }

  /// 暂停该作品所有进行中/等待中的任务。
  Future<void> pauseAllByWork(int workId) async {
    final active = _tasks
        .where((t) =>
            t.workId == workId &&
            (t.status == DownloadStatus.downloading ||
                t.status == DownloadStatus.pending))
        .toList();
    for (final task in active) {
      await pauseTask(task.id);
    }
    _log.info('已暂停 RJ$workId 的 ${active.length} 个任务', tag: 'Download');
  }

  /// 清空该作品的已完成任务记录（不删磁盘文件）。
  Future<void> clearCompletedByWork(int workId) async {
    final before = _tasks.length;
    _tasks.removeWhere((t) =>
        t.workId == workId && t.status == DownloadStatus.completed);
    final removed = before - _tasks.length;
    _tasksController.add(List.from(_tasks));
    await _saveTasks();
    _log.info('已清空 RJ$workId 的 $removed 个已完成任务记录',
        tag: 'Download');
  }

  /// 删除该作品全部任务及文件。
  Future<void> deleteAllByWork(int workId) async {
    final tasks = _tasks.where((t) => t.workId == workId).toList();
    for (final task in tasks) {
      await deleteTask(task.id);
    }
    _log.info('已删除 RJ$workId 的全部任务及文件', tag: 'Download');
  }

  // ==================== M4: 补充下载 ====================

  /// 对比在线音声文件与本地磁盘文件，返回需要补充下载的文件列表。
  /// 适用于误删本地文件后的恢复：以在线文件树为准，找出磁盘上缺失的文件。
  /// [workDirPath] 可显式指定作品目录；缺省时按 workId 定位。
  Future<SupplementDiffResult> checkSupplementDiff(
    int workId, {
    String? workDirPath,
  }) async {
    try {
      // 1. 获取在线音轨列表（优先走缓存，未命中则请求网络）
      final apiService = KikoeruApiService();
      final host = StorageService.getString('server_host') ?? '';
      final token = StorageService.getString('auth_token') ?? '';
      if (host.isEmpty) {
        return const SupplementDiffResult(error: '未配置服务器地址');
      }
      apiService.init(token, host);
      final tracks = await apiService.getWorkTracks(workId);

      // 2. 展平在线文件树，并清洗出本地磁盘应有的相对路径
      final onlineFiles = <SupplementFile>[];
      void walk(List<dynamic> items, String parentPath) {
        for (final item in items) {
          if (item is! Map) continue;
          final type = item['type'] as String? ?? '';
          final title = item['title'] as String? ?? '';
          if (title.isEmpty) continue;

          if (type == 'folder') {
            final folderPath =
                parentPath.isEmpty ? title : '$parentPath/$title';
            final children = item['children'];
            if (children is List) walk(children, folderPath);
          } else {
            final rawPath = parentPath.isEmpty ? title : '$parentPath/$title';
            onlineFiles.add(SupplementFile(
              title: title,
              localRelativePath:
                  DownloadFilePathService.safeRelativePath(rawPath),
              hash: item['hash'] as String?,
              size: item['size'] as int?,
              mediaDownloadUrl: item['mediaDownloadUrl'] as String?,
            ));
          }
        }
      }
      walk(tracks, '');

      // 3. 扫描本地磁盘上实际存在的文件（跳过元数据/封面/临时文件）
      final localPaths = <String>{};
      final dirPath = workDirPath ?? (await getWorkDirectory(workId)).path;
      final workDir = Directory(dirPath);
      if (await workDir.exists()) {
        await for (final entity
            in workDir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final fileName = p.basename(entity.path);
          if (LocalWorkMetadataService.shouldSkipMetadataFile(
            fileName,
            isRoot: false,
          )) {
            continue;
          }
          final rel = p.relative(entity.path, from: dirPath);
          localPaths.add(DownloadFilePathService.normalizeRelativePath(rel));
        }
      }

      // 4. 对比得出缺失文件
      final missing = onlineFiles
          .where((f) => !localPaths.contains(f.localRelativePath))
          .toList();

      // 5. 构建完整文件树（以在线列表为准，从根目录开始），
      //    每个文件标记本地是否存在，本地缺失的整个目录也会在树中体现
      final tree = buildSupplementFileTree(onlineFiles, localPaths);

      _log.info(
        '补充下载对比 RJ$workId: 在线 ${onlineFiles.length} 个, '
        '本地 ${localPaths.length} 个, 缺失 ${missing.length} 个',
        tag: 'Download',
      );
      return SupplementDiffResult(
        missing: missing,
        tree: tree,
        onlineCount: onlineFiles.length,
        localCount: localPaths.length,
      );
    } catch (e) {
      _log.error('补充下载对比失败 RJ$workId: $e', tag: 'Download');
      return SupplementDiffResult(error: e.toString());
    }
  }

  /// 为缺失文件创建补充下载任务，返回成功加入队列的数量。
  /// [workMetadata]/[coverUrl] 透传给 [addTask]，保证离线详情可用。
  Future<int> supplementDownloads(
    int workId,
    List<SupplementFile> missing, {
    Map<String, dynamic>? workMetadata,
    String? coverUrl,
  }) async {
    final host = StorageService.getString('server_host') ?? '';
    final token = StorageService.getString('auth_token') ?? '';
    final workTitle = (workMetadata?['title'] as String?) ?? 'RJ$workId';

    int added = 0;
    for (final file in missing) {
      // 构造下载 URL
      String downloadUrl = file.mediaDownloadUrl ?? '';
      if (downloadUrl.isNotEmpty) {
        if (downloadUrl.startsWith('/') && host.isNotEmpty) {
          downloadUrl = '${_normalizeHttpHost(host)}$downloadUrl';
        }
        if (token.isNotEmpty && !downloadUrl.contains('token=')) {
          downloadUrl = downloadUrl.contains('?')
              ? '$downloadUrl&token=$token'
              : '$downloadUrl?token=$token';
        }
      } else if (host.isNotEmpty && file.hash != null) {
        downloadUrl =
            '${_normalizeHttpHost(host)}/api/media/download/${file.hash}/'
            '${Uri.encodeComponent(file.title)}?token=$token';
      }
      if (downloadUrl.isEmpty) {
        _log.warning(
          '补充下载跳过（无下载地址）: ${file.localRelativePath}',
          tag: 'Download',
        );
        continue;
      }

      await addTask(
        workId: workId,
        workTitle: workTitle,
        fileName: file.localRelativePath,
        downloadUrl: downloadUrl,
        hash: file.hash,
        totalBytes: file.size,
        workMetadata: workMetadata,
        coverUrl: coverUrl,
        forceRedownload: true,
      );
      added++;
    }
    return added;
  }

  /// 将 host 规范化为带协议的完整地址（localhost/内网使用 http，其余使用 https）
  static String _normalizeHttpHost(String host) {
    if (host.startsWith('http://') || host.startsWith('https://')) {
      return host;
    }
    if (host.contains('localhost') ||
        host.startsWith('127.0.0.1') ||
        host.startsWith('192.168.')) {
      return 'http://$host';
    }
    return 'https://$host';
  }
}

/// 从原 kikoeru 导入的结果汇总。
class ImportResult {
  int success = 0;
  int done = 0;
  int total = 0;
  int totalBytes = 0;
  final List<ImportSkip> skipped = [];
  final List<ImportSkip> failed = [];
  String? error;

  int get failedCount => failed.length;
  int get skippedCount => skipped.length;
}

class ImportSkip {
  final String path;
  final String reason;
  const ImportSkip({required this.path, required this.reason});
}

/// 在线作品中的单个文件（用于与本地对比的补充下载场景）
class SupplementFile {
  final String title; // 在线文件名
  final String localRelativePath; // 清洗后的本地相对路径
  final String? hash;
  final int? size;
  final String? mediaDownloadUrl;

  const SupplementFile({
    required this.title,
    required this.localRelativePath,
    this.hash,
    this.size,
    this.mediaDownloadUrl,
  });
}

/// 在线文件树节点：以网络传来的列表为准，从根目录开始组织。
/// [exists] 标记该文件本地磁盘上是否已存在（文件夹节点恒为 false，
/// 其子项的 [exists] 表示目录内文件的存在情况）。
class SupplementFileNode {
  final String title; // 文件/文件夹名
  final String localRelativePath; // 相对作品根目录的完整路径
  final bool isFolder;
  final bool exists; // 文件：本地是否已存在
  final SupplementFile? file; // 文件节点对应的在线文件信息
  final List<SupplementFileNode> children;

  const SupplementFileNode({
    required this.title,
    required this.localRelativePath,
    required this.isFolder,
    this.exists = false,
    this.file,
    this.children = const [],
  });
}

/// 根据在线文件列表构建完整文件树（从根目录开始），并标记每个文件的本地存在状态
List<SupplementFileNode> buildSupplementFileTree(
  List<SupplementFile> files,
  Set<String> localPaths,
) {
  final root = <SupplementFileNode>[];
  for (final f in files) {
    final parts = f.localRelativePath.split('/');
    var siblings = root;
    SupplementFileNode? folder;
    for (var i = 0; i < parts.length - 1; i++) {
      final seg = parts[i];
      folder = null;
      for (final c in siblings) {
        if (c.isFolder && c.title == seg) {
          folder = c;
          break;
        }
      }
      if (folder == null) {
        folder = SupplementFileNode(
          title: seg,
          localRelativePath: parts.take(i + 1).join('/'),
          isFolder: true,
          children: <SupplementFileNode>[],
        );
        siblings.add(folder);
      }
      siblings = folder.children;
    }
    siblings.add(SupplementFileNode(
      title: parts.last,
      localRelativePath: f.localRelativePath,
      isFolder: false,
      exists: localPaths.contains(f.localRelativePath),
      file: f,
    ));
  }
  return root;
}

/// 在线与本地文件对比结果
class SupplementDiffResult {
  final List<SupplementFile> missing; // 缺失（需要补充下载）的文件
  final List<SupplementFileNode> tree; // 在线完整文件树（根目录开始，含存在状态）
  final int onlineCount; // 在线文件总数
  final int localCount; // 本地磁盘文件总数
  final String? error; // 对比失败时的错误信息

  const SupplementDiffResult({
    this.missing = const [],
    this.tree = const [],
    this.onlineCount = 0,
    this.localCount = 0,
    this.error,
  });

  bool get isEmpty => missing.isEmpty;

  int get totalBytes => missing.fold(0, (s, f) => s + (f.size ?? 0));
}

class _DirValidation {
  final bool ok;
  final String? reason;
  const _DirValidation._(this.ok, this.reason);
  factory _DirValidation.ok() => const _DirValidation._(true, null);
  factory _DirValidation.fail(String reason) =>
      _DirValidation._(false, reason);
}
