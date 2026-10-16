import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'download_file_path_service.dart';
import 'download_service.dart';
import 'kikoeru_api_service.dart';
import 'local_work_metadata_service.dart';
import 'log_service.dart';
import 'storage_service.dart';

/// 单个文件的体检结论。
///
/// 判定口径来自服务端逐字节比对得出的结论（见《下载完整性服务端对比验证
/// 报告》）：真正需要重下的只有下面这几种，且**用「长度 + 容器头」两个本地
/// 就能拿到的证据足以区分**，不必对每个文件再发 Range 请求。
enum FileIntegrityVerdict {
  /// 长度与服务端一致、容器头合法。
  ok,

  /// 0 字节。历史上"服务器不返回 size 时完整性校验被跳过"的产物。
  zeroByte,

  /// 比服务端还大 —— 重复 / 覆盖写入。
  oversize,

  /// 比服务端小 —— 缺头 / 缺中段 / 只剩尾段（`本地 size == 服务端 size - Δ`）。
  shortSize,

  /// 长度正确但容器头非法 —— 典型是"头部被同源数据覆盖"，
  /// **这类文件能完美骗过纯长度校验**，只能靠头校验抓出来。
  headerCorrupt,

  /// 本地有，但在服务端文件树里找不到（服务端已删 / 改版）。不算坏，只做提示。
  notOnServer,
}

extension FileIntegrityVerdictX on FileIntegrityVerdict {
  /// 是否需要重下。
  bool get isProblem =>
      this != FileIntegrityVerdict.ok && this != FileIntegrityVerdict.notOnServer;
}

/// 一个文件的体检明细。
class FileIntegrityFinding {
  final String relativePath;
  final String fileName;
  final int localSize;
  final int? onlineSize;
  final FileIntegrityVerdict verdict;

  /// 命中的在线文件（用于构造重下任务）。[FileIntegrityVerdict.notOnServer] 时为 null。
  final SupplementFile? online;

  const FileIntegrityFinding({
    required this.relativePath,
    required this.fileName,
    required this.localSize,
    required this.onlineSize,
    required this.verdict,
    this.online,
  });

  bool get isProblem => verdict.isProblem;
}

/// 一个作品的体检报告。
class WorkIntegrityReport {
  final int workId;
  final String workTitle;
  final List<FileIntegrityFinding> findings;
  final String? error;

  /// 本地实际存在的媒体文件总数（= 体检覆盖面）。
  int get scannedCount => findings.length;

  List<FileIntegrityFinding> get problems =>
      findings.where((f) => f.isProblem).toList(growable: false);

  int get problemCount => problems.length;

  int get okCount =>
      findings.where((f) => f.verdict == FileIntegrityVerdict.ok).length;

  bool get hasProblem => problemCount > 0;

  const WorkIntegrityReport({
    required this.workId,
    required this.workTitle,
    this.findings = const [],
    this.error,
  });
}

/// 本地下载的完整性体检。
///
/// **与「补充下载对比」的根本区别**：后者以**在线文件树**为基准，于是
/// 「本地从来没下载过的版本」也会被算成缺失 —— 对"为了省空间只下 mp3"
/// 的用户，服务端整套 WAV 都会变成噪音（实测 147 个作品里满屏"缺失 65 个"）。
/// 本服务**以本地实际存在的文件为基准**逐个回查在线树，因此
/// **只会报告"你已经下载过的、而且坏了"的文件**，不会引导你下载任何
/// 从未下载过的版本。
class DownloadIntegrityService {
  DownloadIntegrityService._();

  static final DownloadIntegrityService instance = DownloadIntegrityService._();

  static final LogService _log = LogService.instance;

  /// 参与体检的媒体扩展名（与 [DownloadService.isCorruptMediaFile] 保持一致）。
  static const Set<String> mediaExtensions = {
    'wav', 'mp3', 'flac', 'm4a', 'm4b', 'ogg', 'opus',
    'mp4', 'mkv', 'webm', 'mov', 'avi',
  };

  /// 纯判定：**不碰磁盘与网络**，可直接单测。
  ///
  /// 判定顺序有讲究：
  /// 1. 服务端没有这个文件 → `notOnServer`（不算坏）；
  /// 2. 0 字节 → `zeroByte`（比"长度偏小"更有诊断价值）；
  /// 3. 与服务端长度不符 → `oversize` / `shortSize`；
  /// 4. 长度一致但头非法 → `headerCorrupt`（**纯长度校验抓不到这类**）。
  static FileIntegrityVerdict judgeFile({
    required int localSize,
    required int? onlineSize,
    required bool headerCorrupt,
    required bool foundOnServer,
  }) {
    if (!foundOnServer) return FileIntegrityVerdict.notOnServer;
    if (localSize <= 0) return FileIntegrityVerdict.zeroByte;
    if (onlineSize != null && onlineSize > 0) {
      if (localSize > onlineSize) return FileIntegrityVerdict.oversize;
      if (localSize < onlineSize) return FileIntegrityVerdict.shortSize;
    }
    if (headerCorrupt) return FileIntegrityVerdict.headerCorrupt;
    return FileIntegrityVerdict.ok;
  }

  /// 扫描作品目录下**实际存在**的媒体文件 → `{规范化相对路径: 字节数}`。
  ///
  /// 与补充下载的扫描口径一致：跳过元数据 / 封面 / `.downloading` 临时文件。
  /// **0 字节文件不会被跳过** —— 它本身就是体检要报告的对象。
  static Future<Map<String, int>> scanLocalMediaFiles(String dirPath) async {
    final result = <String, int>{};
    final dir = Directory(dirPath);
    if (!await dir.exists()) return result;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (LocalWorkMetadataService.shouldSkipMetadataFile(name, isRoot: false)) {
        continue;
      }
      final dot = name.lastIndexOf('.');
      if (dot < 0) continue;
      if (!mediaExtensions.contains(name.substring(dot + 1).toLowerCase())) {
        continue;
      }
      final rel = p.relative(entity.path, from: dirPath);
      result[DownloadFilePathService.normalizeRelativePath(rel)] =
          await entity.length();
    }
    return result;
  }

  /// 把在线 tracks 树展平成 `{规范化相对路径: SupplementFile}`。
  static Map<String, SupplementFile> flattenOnlineTree(List<dynamic> tracks) {
    final out = <String, SupplementFile>{};
    void walk(List<dynamic> items, String parentPath) {
      for (final item in items) {
        if (item is! Map) continue;
        final title = item['title'] as String? ?? '';
        if (title.isEmpty) continue;
        final rawPath = parentPath.isEmpty ? title : '$parentPath/$title';
        if ((item['type'] as String? ?? '') == 'folder') {
          final children = item['children'];
          if (children is List) walk(children, rawPath);
        } else {
          out[DownloadFilePathService.safeRelativePath(rawPath)] = SupplementFile(
            title: title,
            localRelativePath: DownloadFilePathService.safeRelativePath(rawPath),
            hash: item['hash'] as String?,
            size: item['size'] as int?,
            mediaDownloadUrl: item['mediaDownloadUrl'] as String?,
          );
        }
      }
    }

    walk(tracks, '');
    return out;
  }

  /// 体检单个作品。
  Future<WorkIntegrityReport> checkWork(
    int workId, {
    String? workTitle,
    String? workDirPath,
  }) async {
    final title = workTitle ?? 'RJ$workId';
    try {
      final host = StorageService.getString('server_host') ?? '';
      final token = StorageService.getString('auth_token') ?? '';
      if (host.isEmpty) {
        return WorkIntegrityReport(
          workId: workId,
          workTitle: title,
          error: '未配置服务器地址',
        );
      }

      final api = KikoeruApiService();
      api.init(token, host);
      final tracks = await api.getWorkTracks(workId);
      final onlineByPath = flattenOnlineTree(tracks);

      final dirPath =
          workDirPath ?? (await DownloadService.instance.getWorkDirectory(workId)).path;
      final localFiles = await scanLocalMediaFiles(dirPath);

      final findings = <FileIntegrityFinding>[];
      for (final entry in localFiles.entries) {
        final rel = entry.key;
        final size = entry.value;
        final online = onlineByPath[rel];
        final name = p.basename(rel);
        // 0 字节不必读盘，直接判损坏。
        final corrupt = size > 0 &&
            await DownloadService.isCorruptMediaFile(
              File(p.join(dirPath, rel)),
              name,
            );
        findings.add(FileIntegrityFinding(
          relativePath: rel,
          fileName: name,
          localSize: size,
          onlineSize: online?.size,
          verdict: judgeFile(
            localSize: size,
            onlineSize: online?.size,
            headerCorrupt: corrupt,
            foundOnServer: online != null,
          ),
          online: online,
        ));
      }

      // 有问题的排前面，其余按路径稳定排序。
      findings.sort((a, b) {
        if (a.isProblem != b.isProblem) return a.isProblem ? -1 : 1;
        return a.relativePath.compareTo(b.relativePath);
      });

      return WorkIntegrityReport(
        workId: workId,
        workTitle: title,
        findings: findings,
      );
    } catch (e) {
      _log.warning('体检失败 RJ$workId: $e', tag: 'Integrity');
      return WorkIntegrityReport(
        workId: workId,
        workTitle: title,
        error: e.toString(),
      );
    }
  }

  /// 批量体检。每批 [concurrency] 个作品并发（与补充下载同样的并发策略），
  /// 每批结束回调 [onProgress]，并可随时通过 [isCancelled] 中止。
  Future<List<WorkIntegrityReport>> checkAll(
    List<int> workIds, {
    Map<int, String> titles = const {},
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 4,
  }) async {
    final reports = <WorkIntegrityReport>[];
    for (var i = 0; i < workIds.length; i += concurrency) {
      if (isCancelled?.call() ?? false) break;
      final batch = workIds.sublist(i, (i + concurrency).clamp(0, workIds.length));
      final results = await Future.wait(batch.map(
        (id) => checkWork(id, workTitle: titles[id]),
      ));
      if (isCancelled?.call() ?? false) break;
      reports.addAll(results);
      onProgress?.call((i + batch.length).clamp(0, workIds.length), workIds.length);
    }
    return reports;
  }
}
