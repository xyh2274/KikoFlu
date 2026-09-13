import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:io';

import '../../l10n/app_localizations.dart';
import '../models/download_task.dart';
import '../models/sort_options.dart';
import '../models/work.dart';
import '../services/download_service.dart';
import '../services/log_service.dart';
import '../services/storage_service.dart';
import '../utils/string_utils.dart';
import '../utils/snackbar_util.dart';
import '../utils/scroll_optimization.dart';
import '../providers/auth_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../utils/responsive_grid_helper.dart';
import '../widgets/enhanced_work_card.dart';
import '../widgets/sort_dialog.dart';
import 'offline_work_detail_screen.dart';
import '../widgets/privacy_blur_cover.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../widgets/floating_feed_toolbar.dart';
import '../widgets/confirmation_dialog.dart';

final _log = LogService.instance;

/// 本地下载屏幕 - 显示已完成的下载内容
class LocalDownloadsScreen extends ConsumerStatefulWidget {
  const LocalDownloadsScreen({
    super.key,
    this.toolbarTop = 8,
    this.collapsedToolbarTop,
    this.primaryToolbarVisible,
  });

  final double toolbarTop;
  final double? collapsedToolbarTop;
  final ValueListenable<bool>? primaryToolbarVisible;

  @override
  ConsumerState<LocalDownloadsScreen> createState() =>
      _LocalDownloadsScreenState();
}

class _LocalDownloadsScreenState extends ConsumerState<LocalDownloadsScreen>
    with AutomaticKeepAliveClientMixin {
  bool _isSelectionMode = false;
  final Set<int> _selectedWorkIds = {}; // 选中的作品ID
  final VirtualizedCollectionController _collectionController =
      VirtualizedCollectionController();
  int _currentPage = 1;
  static const int _pageSize = 30;

  // 磁盘上存在的作品目录元数据（即使已无任何下载任务，如文件被全部误删）
  Map<int, Map<String, dynamic>> _diskWorks = {};

  // 搜索相关
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isSearchVisible = false;

  // 排序相关
  SortOrder _sortOrder = SortOrder.downloadDate;
  SortDirection _sortDirection = SortDirection.desc;

  void _showSnackBarSafe(SnackBar snackBar) {
    if (!mounted) return;

    SnackBarUtil.showFromSnackBar(
      context,
      snackBar,
      onError: (error, _) {
        _log.captureOutput('[LocalDownloads] 无法显示 SnackBar: $error');
      },
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadDiskWorks();
  }

  // 扫描磁盘上的作品目录（即使无任务也展示，便于误删后补充下载）
  Future<void> _loadDiskWorks() async {
    try {
      final works = await DownloadService.instance.getDiskWorks();
      if (!mounted) return;
      setState(() {
        _diskWorks = works;
      });
      // 后台补全缺失/损坏的作品元数据（标题/封面/标签），
      // 不阻塞首帧渲染；补全完成后自动刷新列表
      unawaited(_upgradeMetadataInBackground());
    } catch (e) {
      _log.captureOutput('[LocalDownloads] 加载磁盘作品失败: $e');
    }
  }

  // 后台补全作品元数据并刷新列表（首次进入/刷新时自动触发一次）
  Future<void> _upgradeMetadataInBackground() async {
    await DownloadService.instance.ensureLocalMetadataCompleteness();
    if (!mounted) return;
    // 补全可能改写了 work_metadata.json，重新加载磁盘作品
    try {
      final works = await DownloadService.instance.getDiskWorks();
      if (!mounted) return;
      setState(() {
        _diskWorks = works;
      });
    } catch (e) {
      _log.captureOutput('[LocalDownloads] 补全后刷新磁盘作品失败: $e');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    _collectionController.scrollToTop(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  void _goToPage(int page) {
    setState(() => _currentPage = page);
    _scrollToTop();
  }

  void _nextPage(int totalPages) {
    if (_currentPage < totalPages) _goToPage(_currentPage + 1);
  }

  void _previousPage() {
    if (_currentPage > 1) _goToPage(_currentPage - 1);
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedWorkIds.clear();
      }
    });
  }

  void _toggleWorkSelection(int workId) {
    setState(() {
      if (_selectedWorkIds.contains(workId)) {
        _selectedWorkIds.remove(workId);
      } else {
        _selectedWorkIds.add(workId);
      }
    });
  }

  void _selectAll(Map<int, List<DownloadTask>> groupedTasks) {
    setState(() {
      _selectedWorkIds.clear();
      _selectedWorkIds.addAll(groupedTasks.keys);
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedWorkIds.clear();
    });
  }

  // 打开本地下载目录
  Future<void> _openDownloadFolder() async {
    try {
      final downloadDir = await DownloadService.instance.getDownloadDirectory();
      final path = downloadDir.path;

      // 检查平台并打开文件夹
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final uri = Uri.file(path);
        final canLaunch = await canLaunchUrl(uri);

        if (canLaunch) {
          await launchUrl(uri);
        } else {
          if (mounted) {
            _showSnackBarSafe(
              SnackBar(
                content: Text(S.of(context).cannotOpenFolder(path)),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnackBarSafe(
          SnackBar(
            content: Text(S.of(context).openFolderFailed(e.toString())),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // 刷新元数据
  Future<void> _refreshMetadata() async {
    if (!mounted) return;

    ScaffoldMessengerState? messenger;

    try {
      // 显示加载提示
      if (mounted) {
        try {
          messenger = ScaffoldMessenger.maybeOf(context);
          messenger?.showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(S.of(context).reloadingFromDisk),
                ],
              ),
              duration: const Duration(seconds: 30), // 设置较长时间，手动清除
            ),
          );
        } catch (e) {
          _log.captureOutput('[LocalDownloads] 无法显示加载提示: $e');
        }
      }

      await DownloadService.instance.reloadMetadataFromDisk();
      await _loadDiskWorks();

      // 在线刮削统一由 DownloadService.ensureLocalMetadataCompleteness
      // 在后台补全（_loadDiskWorks 已触发该流程），此处不再逐个阻塞刮削，
      // 避免服务器响应慢时 UI 长时间无响应、主 isolate 被网络等待占用。
      const scrapedCount = 0;

      // 清除加载提示并显示成功消息
      if (!mounted) return;

      Future.microtask(() {
        if (mounted) {
          try {
            // 清除之前的 SnackBar
            ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
            // 显示完成消息
            _showSnackBarSafe(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        scrapedCount > 0
                            ? S.of(context).scrapeComplete(scrapedCount)
                            : S.of(context).refreshComplete,
                      ),
                    ),
                  ],
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          } catch (e) {
            _log.captureOutput('[LocalDownloads] 无法显示完成提示: $e');
          }
        }
      });
    } catch (e) {
      if (!mounted) return;

      Future.microtask(() {
        if (mounted) {
          try {
            // 清除加载提示
            ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
            // 显示错误消息
            _showSnackBarSafe(
              SnackBar(
                content: Text(S.of(context).refreshFailed(e.toString())),
                duration: const Duration(seconds: 3),
              ),
            );
          } catch (e) {
            _log.captureOutput('[LocalDownloads] 无法显示错误提示: $e');
          }
        }
      });
    }
  }

  // 删除选中的作品
  Future<void> _deleteSelectedWorks(
      Map<int, List<DownloadTask>> groupedTasks) async {
    if (_selectedWorkIds.isEmpty) return;

    final l10n = S.of(context);
    final confirmed = await showCommonConfirmationDialog(
      context: context,
      title: l10n.deletionConfirmTitle,
      content: Text(l10n.deleteSelectedWorksConfirm(_selectedWorkIds.length)),
      confirmLabel: l10n.delete,
      variant: ConfirmationDialogVariant.danger,
    );

    if (confirmed != true) return;

    // 保存 mounted 状态和 context，避免异步后使用失效的引用
    if (!mounted) return;

    String? errorMessage;
    int successCount = 0;
    int totalCount = 0;

    try {
      for (final workId in _selectedWorkIds) {
        final tasks = groupedTasks[workId] ?? [];
        for (final task in tasks) {
          totalCount++;
          try {
            await DownloadService.instance.deleteTask(task.id);
            successCount++;
          } catch (e) {
            errorMessage ??= l10n.partialDeleteFailed(e.toString());
            _log.captureOutput('[LocalDownloads] 删除任务 ${task.id} 失败: $e');
          }
        }
      }

      // 只在 widget 仍然 mounted 时更新状态
      if (!mounted) return;

      setState(() {
        _isSelectionMode = false;
        _selectedWorkIds.clear();
      });

      // 删除可能清空了作品目录，重新扫描磁盘作品
      _loadDiskWorks();

      // 使用 Future.microtask 延迟到下一帧显示 SnackBar
      if (mounted) {
        Future.microtask(() {
          if (mounted) {
            if (errorMessage != null && successCount > 0) {
              _showSnackBarSafe(
                SnackBar(
                    content:
                        Text(l10n.deletedNOfTotal(successCount, totalCount))),
              );
            } else if (errorMessage != null) {
              _showSnackBarSafe(
                SnackBar(content: Text(errorMessage)),
              );
            } else {
              _showSnackBarSafe(
                SnackBar(content: Text(l10n.deleted)),
              );
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        Future.microtask(() {
          if (mounted) {
            _showSnackBarSafe(
              SnackBar(content: Text(l10n.deleteFailedWithError(e.toString()))),
            );
          }
        });
      }
    }
  }

  // 显示排序对话框
  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (context) => CommonSortDialog(
        title: S.of(context).sortOptions,
        currentOption: _sortOrder,
        currentDirection: _sortDirection,
        availableOptions: const [
          SortOrder.downloadDate,
          SortOrder.workId,
        ],
        onSort: (option, direction) {
          setState(() {
            _sortOrder = option;
            _sortDirection = direction;
            _currentPage = 1;
          });
        },
        autoClose: true,
      ),
    );
  }

  // 切换搜索栏可见性
  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (!_isSearchVisible) {
        _searchController.clear();
        _searchQuery = '';
        _currentPage = 1;
      }
    });
  }

  // 过滤作品（根据搜索关键词）
  Map<int, List<DownloadTask>> _filterTasks(
      Map<int, List<DownloadTask>> groupedTasks) {
    if (_searchQuery.isEmpty) return groupedTasks;

    final query = _searchQuery.toLowerCase();
    return Map.fromEntries(
      groupedTasks.entries.where((entry) {
        final workId = entry.key;
        final tasks = entry.value;
        final rjCode = formatRJCode(workId);

        // 无任务记录的作品（仅磁盘目录），用 RJ 号匹配
        if (tasks.isEmpty) {
          if (rjCode.toLowerCase().contains(query)) return true;
          if (workId.toString().contains(query)) return true;
          return false;
        }

        final firstTask = tasks.first;

        // 匹配作品标题
        if (firstTask.workTitle.toLowerCase().contains(query)) return true;

        // 匹配 RJ 号（workId）
        if (rjCode.toLowerCase().contains(query)) return true;
        if (workId.toString().contains(query)) return true;

        return false;
      }),
    );
  }

  // 排序作品
  List<int> _sortWorkIds(Map<int, List<DownloadTask>> groupedTasks) {
    final workIds = groupedTasks.keys.toList();

    workIds.sort((a, b) {
      int result;
      switch (_sortOrder) {
        case SortOrder.downloadDate:
          DateTime dateOf(int workId) {
            final tasks = groupedTasks[workId]!;
            if (tasks.isEmpty) {
              // 无任务记录的作品排在最前（无时间信息）
              return DateTime.fromMillisecondsSinceEpoch(0);
            }
            return tasks
                .map((t) => t.completedAt ?? t.createdAt)
                .reduce((x, y) => x.isAfter(y) ? x : y);
          }

          result = dateOf(a).compareTo(dateOf(b));
          break;
        case SortOrder.workId:
          result = a.compareTo(b);
          break;
        default:
          result = 0;
      }
      return _sortDirection == SortDirection.asc ? result : -result;
    });

    return workIds;
  }

  void _openWorkDetail(int workId, DownloadTask task) async {
    _log.captureOutput(
        '[LocalDownloads] 打开作品详情: workId=$workId, task=${task.id}, '
        'file=${task.fileName}, hasMetadata=${task.workMetadata != null}');

    final loadedMetadata = task.workMetadata ??
        await DownloadService.instance.getWorkMetadata(workId);

    if (!mounted) return;

    if (loadedMetadata == null) {
      _log.captureOutput(
        '[LocalDownloads] 错误：任务没有元数据，磁盘恢复也失败: workId=$workId, task=${task.id}',
      );
      _showSnackBarSafe(
        SnackBar(
          content: Text(S.of(context).noWorkMetadataForOffline),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    try {
      final metadata = _sanitizeMetadata(loadedMetadata);
      final rawChildren = metadata['children'];
      _log.captureOutput(
        '[LocalDownloads] 已获得离线元数据: workId=$workId, '
        'metadataId=${metadata['id']}, sourceId=${metadata['source_id']}, '
        'localDir=${metadata['localWorkDirName']}, '
        'children=${rawChildren is List ? rawChildren.length : 0}',
      );
      final work = Work.fromJson(metadata);

      // 动态构建完整的本地路径
      final workDir = await DownloadService.instance.getWorkDirectory(
        workId,
        metadata: metadata,
      );
      final localCoverPath =
          DownloadService.instance.localCoverPathForMetadata(workDir, metadata);

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => OfflineWorkDetailScreen(
              work: work,
              isOffline: true,
              localCoverPath: localCoverPath,
              localCoverRelativePath: metadata['localCoverPath'] as String?,
              localWorkDirPath: workDir.path,
              fileTree:
                  rawChildren is List ? List<dynamic>.from(rawChildren) : null,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBarSafe(
          SnackBar(
            content: Text(S.of(context).openWorkDetailFailed(e.toString())),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // 补充下载：对比在线音声与本地文件，将缺失文件加入下载队列
  // 从任务或磁盘元数据中获取作品的元数据
  Map<String, dynamic>? _metadataForWork(
    int workId,
    Map<int, List<DownloadTask>> groupedTasks,
  ) {
    final tasks = groupedTasks[workId] ?? const <DownloadTask>[];
    for (final task in tasks) {
      if (task.workMetadata != null) return task.workMetadata;
    }
    return _diskWorks[workId];
  }

  /// 作品封面地址：复用 [Work.getCoverImageUrl] 的 URL 规则，
  /// 但只用一个带 id 的空 Work（不走 fromJson + 深层清洗，
  /// 避免为几百个作品构造封面地址时做无谓的元数据解析）。
  String? _coverUrlForWorkId(int workId, String host, String token) {
    if (host.isEmpty) return null;
    return Work(id: workId, title: '').getCoverImageUrl(host, token: token);
  }

  // 顶部"补充下载"：先多选要对比的音声（支持全选），再对比所选并补充下载
  Future<void> _pickWorksForSupplement(
      Map<int, List<DownloadTask>> groupedTasks) async {
    final l10n = S.of(context);
    final authState = ref.read(authProvider);
    if ((authState.host ?? '').isEmpty) {
      SnackBarUtil.showWarning(context, l10n.supplementDownloadNeedServer);
      return;
    }

    // 汇总所有作品 ID（已完成任务作品 + 磁盘目录作品）
    final workIds = <int>{...groupedTasks.keys, ..._diskWorks.keys}.toList();
    if (workIds.isEmpty) {
      SnackBarUtil.showInfo(context, l10n.noLocalDownloads);
      return;
    }

    final host = authState.host ?? '';
    final token = authState.token ?? '';
    final entries = <_WorkPickEntry>[];
    for (final workId in workIds) {
      final metadata = _metadataForWork(workId, groupedTasks);
      entries.add(_WorkPickEntry(
        workId: workId,
        workTitle: (metadata?['title'] as String?) ?? 'RJ$workId',
        metadata: metadata,
        coverUrl: _coverUrlForWorkId(workId, host, token),
      ));
    }

    final selected = await showDialog<List<int>>(
      context: context,
      builder: (context) => _WorkPickDialog(works: entries),
    );
    if (!mounted || selected == null) return;
    if (selected.isEmpty) {
      SnackBarUtil.showWarning(context, l10n.supplementSelectWorkFirst);
      return;
    }
    await _supplementDownloadSelected(groupedTasks, selected);
  }

  // 多音声差异对比：对比所选音声的在线/本地文件，树形展示并补充下载
  Future<void> _supplementDownloadSelected(
      Map<int, List<DownloadTask>> groupedTasks, List<int> workIds) async {
    final l10n = S.of(context);
    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    if (host.isEmpty) {
      SnackBarUtil.showWarning(context, l10n.supplementDownloadNeedServer);
      return;
    }

    // 显示对比进度对话框
    var dialogOpen = false;
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 16),
                Flexible(child: Text(l10n.supplementComparing)),
              ],
            ),
          ),
        ),
      );
      dialogOpen = true;
    }

    try {
      // 逐个作品对比，汇总有缺失的作品
      final entries = <_WorkSupplementEntry>[];
      for (final workId in workIds) {
        final result = await DownloadService.instance
            .checkSupplementDiff(workId);
        if (result.error != null || result.missing.isEmpty) continue;
        final metadata = _metadataForWork(workId, groupedTasks);
        entries.add(_WorkSupplementEntry(
          workId: workId,
          workTitle: (metadata?['title'] as String?) ?? 'RJ$workId',
          tree: result.tree,
          missingCount: result.missing.length,
          metadata: metadata,
          coverUrl: _coverUrlForWorkId(workId, host, token),
        ));
      }

      if (!mounted) return;
      if (dialogOpen) {
        dialogOpen = false;
        Navigator.of(context).pop(); // 关闭进度对话框
      }

      if (entries.isEmpty) {
        SnackBarUtil.showSuccess(context, l10n.noFilesNeedSupplement);
        return;
      }

      // 树形多选对话框：按作品分组，每棵文件树展示缺失文件
      final selectedMap = await showDialog<Map<int, List<SupplementFile>>>(
        context: context,
        builder: (context) => _SupplementDiffDialog(works: entries),
      );
      if (!mounted || selectedMap == null || selectedMap.isEmpty) return;

      // 按作品执行补充下载（复用对比阶段已取到的元数据与封面地址）
      int totalAdded = 0;
      for (final entry in entries) {
        final files = selectedMap[entry.workId];
        if (files == null || files.isEmpty) continue;
        totalAdded += await DownloadService.instance.supplementDownloads(
          entry.workId,
          files,
          workMetadata: entry.metadata,
          coverUrl: entry.coverUrl,
        );
      }
      if (!mounted) return;
      SnackBarUtil.showSuccess(
        context,
        totalAdded > 0
            ? l10n.addedNFilesToDownloadQueue(totalAdded)
            : l10n.noFilesNeedSupplement,
      );
    } catch (e) {
      if (!mounted) return;
      if (dialogOpen) {
        dialogOpen = false;
        try {
          Navigator.of(context).pop();
        } catch (_) {
          // 对话框可能已关闭，忽略
        }
      }
      SnackBarUtil.showError(
          context, l10n.supplementDownloadFailed(e.toString()));
    }
  }

  Map<String, dynamic> _sanitizeMetadata(Map<String, dynamic> metadata) {
    try {
      return _deepSanitize(metadata) as Map<String, dynamic>;
    } catch (e) {
      _log.captureOutput('[LocalDownloads] 清理元数据时出错: $e');
      rethrow;
    }
  }

  dynamic _deepSanitize(dynamic value) {
    if (value == null) return null;

    if (value is Map) {
      return value
          .map((key, val) => MapEntry(key.toString(), _deepSanitize(val)));
    }

    if (value is List) {
      return value.map(_deepSanitize).toList();
    }

    // 处理特殊类型对象 - 直接调用toJson()方法
    if (value.runtimeType.toString() == 'Va' ||
        value.runtimeType.toString() == 'Tag' ||
        value.runtimeType.toString() == 'AudioFile' ||
        value.runtimeType.toString() == 'RatingDetail' ||
        value.runtimeType.toString() == 'OtherLanguageEdition') {
      try {
        // 尝试调用toJson方法
        final json = (value as dynamic).toJson();
        // 递归处理嵌套的children等字段
        return _deepSanitize(json);
      } catch (e) {
        _log.captureOutput('[LocalDownloads] 对象序列化失败 ${value.runtimeType}: $e');
        return null;
      }
    }

    return value;
  }

  /// 瀑布流间距（与原 grid 的 crossAxisSpacing/mainAxisSpacing 一致）
  static const double _gridSpacing = 12;

  /// 原 grid 的 maxCrossAxisExtent，用于等价推算瀑布流列数
  static const double _targetCardWidth = 210;

  /// 集合左右 padding 之和（fromLTRB 左右各 16）
  static const double _gridHorizontalPadding = 32;

  /// 按原 `SliverGridDelegateWithMaxCrossAxisExtent(210)` 的算法推算瀑布流列数，
  /// 保证切到瀑布流后卡片宽度与改动前一致（1080px 屏 → 5 列）。
  int _masonryColumnsFor(double availableWidth) {
    final usableWidth = (availableWidth - _gridHorizontalPadding)
        .clamp(0.0, double.infinity);
    return (usableWidth / (_targetCardWidth + _gridSpacing)).ceil().clamp(1, 12);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return StreamBuilder<List<DownloadTask>>(
      stream: DownloadService.instance.tasksStream,
      initialData: DownloadService.instance.tasks,
      builder: (context, snapshot) {
        final displaySettings = ref.watch(workCardDisplayProvider);
        final crossAxisCount = displaySettings.applyCardSize(
          ResponsiveGridHelper.getBigGridCrossAxisCount(context),
        );

        final tasks = snapshot.data ?? [];
        final completedTasks =
            tasks.where((t) => t.status == DownloadStatus.completed).toList();

        // 按作品分组
        final Map<int, List<DownloadTask>> allGroupedTasks = {};
        for (final task in completedTasks) {
          allGroupedTasks.putIfAbsent(task.workId, () => []).add(task);
        }

        // 合并磁盘上存在的作品目录（即使已无任何下载任务，
        // 如本地文件被全部误删，仍需展示以提供补充下载入口）
        for (final workId in _diskWorks.keys) {
          allGroupedTasks.putIfAbsent(workId, () => []);
        }

        // 应用搜索过滤
        final groupedTasks = _filterTasks(allGroupedTasks);

        // 应用排序
        final sortedWorkIds = _sortWorkIds(groupedTasks);
        final totalCount = sortedWorkIds.length;
        final totalPages = (totalCount / _pageSize).ceil();
        final currentPage = totalPages == 0 || _currentPage < 1
            ? 1
            : _currentPage > totalPages
                ? totalPages
                : _currentPage;
        final startIndex = (currentPage - 1) * _pageSize;
        final endIndex = (startIndex + _pageSize).clamp(0, totalCount);
        final currentPageWorkIds = sortedWorkIds.sublist(startIndex, endIndex);
        final toolbarTop = widget.toolbarTop;

        return Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 瀑布流：tile 高度由卡片内容决定，标签多/标题长不再被固定高度
                  // 裁剪（原 grid 用 childAspectRatio 写死 tile 高度，内容超出即裁掉）。
                  final masonryColumns =
                      _masonryColumnsFor(constraints.maxWidth);
                  return VirtualizedSliverCollection<int>(
                    collectionController: _collectionController,
                    pageStorageKey:
                        const PageStorageKey('local-downloads-feed'),
                    items: currentPageWorkIds,
                    itemId: (workId) => workId,
                    layout: VirtualizedCollectionLayout.masonry,
                    masonryCrossAxisCount: masonryColumns,
                    masonryCrossAxisSpacing: _gridSpacing,
                    masonryMainAxisSpacing: _gridSpacing,
                    padding: EdgeInsets.fromLTRB(16, toolbarTop + 60, 16, 16),
                    physics: ScrollOptimization.physics,
                    pagination: totalCount == 0
                        ? null
                        : VirtualizedPagination(
                            currentPage: currentPage,
                            pageSize: _pageSize,
                            totalCount: totalCount,
                            hasMore: currentPage < totalPages,
                            isLoading: false,
                            onPreviousPage: _previousPage,
                            onNextPage: () => _nextPage(totalPages),
                            onGoToPage: _goToPage,
                            nextPageOnOverscroll: true,
                            scrollToTop: false,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          ),
                    showEndIndicator: false,
                    emptyBuilder: (context) => Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            allGroupedTasks.isEmpty
                                ? Icons.download_outlined
                                : Icons.search_off,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            allGroupedTasks.isEmpty
                                ? S.of(context).noLocalDownloads
                                : S.of(context).noResults,
                            style: TextStyle(
                              fontSize: 16,
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    itemBuilder: (context, workId, index) {
                      final workTasks = groupedTasks[workId]!;
                      return _buildWorkCard(
                        workId: workId,
                        workTasks: workTasks,
                        firstTask: _displayTask(workId, workTasks),
                        isSelected: _selectedWorkIds.contains(workId),
                        crossAxisCount: crossAxisCount,
                      );
                    },
                  );
                },
              ),
            ),
            if (widget.primaryToolbarVisible == null)
              Positioned(
                top: toolbarTop,
                left: FloatingToolbarLayout.horizontalPadding(context),
                right: FloatingToolbarLayout.horizontalPadding(context),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      fit: FlexFit.loose,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _buildPrimaryToolbar(allGroupedTasks),
                      ),
                    ),
                    _buildSecondaryToolbar(allGroupedTasks),
                  ],
                ),
              )
            else
              FloatingToolbarPositionFollower(
                primaryToolbarVisible: widget.primaryToolbarVisible!,
                visibleTop: toolbarTop,
                hiddenTop: widget.collapsedToolbarTop ?? toolbarTop,
                left: FloatingToolbarLayout.horizontalPadding(context),
                right: FloatingToolbarLayout.horizontalPadding(context),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      fit: FlexFit.loose,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _buildPrimaryToolbar(allGroupedTasks),
                      ),
                    ),
                    _buildSecondaryToolbar(allGroupedTasks),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPrimaryToolbar(Map<int, List<DownloadTask>> groupedTasks) {
    if (_isSelectionMode) {
      return FloatingToolbarSurface(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingToolbarIconButton(
              icon: Icons.close,
              tooltip: S.of(context).exitSelection,
              onPressed: _toggleSelectionMode,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                S.of(context).selectedCount(_selectedWorkIds.length),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            FloatingToolbarIconButton(
              icon: _selectedWorkIds.length == groupedTasks.length &&
                      groupedTasks.isNotEmpty
                  ? Icons.deselect
                  : Icons.select_all,
              tooltip: _selectedWorkIds.length == groupedTasks.length &&
                      groupedTasks.isNotEmpty
                  ? S.of(context).deselectAll
                  : S.of(context).selectAll,
              onPressed: _selectedWorkIds.length == groupedTasks.length &&
                      groupedTasks.isNotEmpty
                  ? _deselectAll
                  : () => _selectAll(groupedTasks),
            ),
            if (_selectedWorkIds.isNotEmpty)
              FloatingToolbarIconButton(
                icon: Icons.cloud_download_outlined,
                tooltip: S.of(context).supplementDownload,
                onPressed: () => _supplementDownloadSelected(
                  groupedTasks,
                  _selectedWorkIds.toList(),
                ),
              ),
            if (_selectedWorkIds.isNotEmpty)
              FloatingToolbarIconButton(
                icon: Icons.delete,
                tooltip: S.of(context).delete,
                onPressed: () => _deleteSelectedWorks(groupedTasks),
              ),
          ],
        ),
      );
    }

    if (_isSearchVisible) {
      return FloatingToolbarSurface(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingToolbarIconButton(
              icon: Icons.arrow_back,
              tooltip: S.of(context).close,
              onPressed: _toggleSearch,
            ),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (value) => setState(() {
                  _searchQuery = value;
                  _currentPage = 1;
                }),
                decoration: InputDecoration(
                  hintText: S.of(context).searchDownloads,
                  border: InputBorder.none,
                  isDense: true,
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchQuery = '';
                              _currentPage = 1;
                            });
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return FloatingToolbarSurface(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingToolbarIconButton(
            icon: Icons.checklist,
            tooltip: S.of(context).select,
            onPressed: _toggleSelectionMode,
          ),
          FloatingToolbarIconButton(
            icon: Icons.search,
            tooltip: S.of(context).search,
            onPressed: _toggleSearch,
          ),
        ],
      ),
    );
  }

  Widget _buildSecondaryToolbar(Map<int, List<DownloadTask>> groupedTasks) {
    return FloatingToolbarSurface(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingToolbarIconButton(
            icon: Icons.cloud_download_outlined,
            tooltip: S.of(context).supplementDownload,
            onPressed: () => _pickWorksForSupplement(groupedTasks),
          ),
          FloatingToolbarIconButton(
            icon: Icons.refresh,
            tooltip: S.of(context).reload,
            onPressed: _refreshMetadata,
          ),
          FloatingToolbarIconButton(
            icon: Icons.sort,
            tooltip: S.of(context).sortOptions,
            onPressed: _showSortDialog,
          ),
          if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            FloatingToolbarIconButton(
              icon: Icons.folder_open,
              tooltip: S.of(context).openFolder,
              onPressed: _openDownloadFolder,
            ),
        ],
      ),
    );
  }

  DownloadTask? _preferredMetadataTask(List<DownloadTask> tasks) {
    for (final task in tasks) {
      if (task.workMetadata != null) return task;
    }
    return tasks.isEmpty ? null : tasks.first;
  }

  // 返回用于展示的下载任务；当作品没有任何任务记录时（如文件被全部误删、
  // 仅剩磁盘目录），根据磁盘元数据构造一个合成任务供详情页与补充下载使用。
  DownloadTask _displayTask(int workId, List<DownloadTask> workTasks) {
    final preferred = _preferredMetadataTask(workTasks);
    if (preferred != null) return preferred;

    final metadata = _diskWorks[workId];
    return DownloadTask(
      id: 'disk_$workId',
      workId: workId,
      workTitle: (metadata?['title'] as String?) ?? 'RJ$workId',
      fileName: '',
      downloadUrl: '',
      status: DownloadStatus.completed,
      createdAt: DateTime.now(),
      completedAt: DateTime.now(),
      workMetadata: metadata,
    );
  }

  Widget _buildWorkCard({
    required int workId,
    required List<DownloadTask> workTasks,
    required DownloadTask firstTask,
    required bool isSelected,
    required int crossAxisCount,
  }) {
    final authState = ref.watch(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    Work? work;
    if (firstTask.workMetadata != null) {
      try {
        final sanitized = _sanitizeMetadata(firstTask.workMetadata!);
        work = Work.fromJson(sanitized);
      } catch (e) {
        work = null;
      }
    }

    // 元数据不可用时构建基础 Work，保证卡片可正常渲染
    final displayWork = work ??
        Work(
          id: workId,
          title: firstTask.workTitle.isEmpty
              ? 'RJ$workId'
              : firstTask.workTitle,
        );

    final cs = Theme.of(context).colorScheme;

    return Container(
      key: ValueKey(workId),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? cs.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: Stack(
        children: [
          EnhancedWorkCard(
            work: displayWork,
            crossAxisCount: crossAxisCount,
            onTap: _isSelectionMode
                ? () => _toggleWorkSelection(workId)
                : () => _openWorkDetail(workId, firstTask),
            // 本地页不涉及在线长按编辑收藏菜单；长按仅用于进入/切换选择模式
            onLongPress: () {
              if (!_isSelectionMode) {
                setState(() => _isSelectionMode = true);
              }
              _toggleWorkSelection(workId);
            },
            localCoverBuilder: () => SizedBox.expand(
              child: _buildCover(workId, work, host, token, firstTask),
            ),
          ),
          // 选择模式的勾选标记
          if (_isSelectionMode)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected
                      ? cs.primary
                      : Colors.white.withValues(alpha: 0.95),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(6),
                child: Icon(
                  isSelected ? Icons.check : Icons.circle_outlined,
                  color: isSelected ? Colors.white : cs.outline,
                  size: 20,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCover(
    int workId,
    Work? work,
    String host,
    String token,
    DownloadTask task,
  ) {
    // 优先使用本地封面
    if (task.workMetadata != null) {
      final relativeCoverPath = task.workMetadata!['localCoverPath'] as String?;
      if (relativeCoverPath != null) {
        return FutureBuilder<Directory>(
          future: DownloadService.instance.getWorkDirectory(
            workId,
            metadata: task.workMetadata,
          ),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              final localCoverPath = DownloadService.instance
                  .localCoverPathForMetadata(snapshot.data!, task.workMetadata);
              if (localCoverPath != null && File(localCoverPath).existsSync()) {
                return Hero(
                  tag: 'offline_work_cover_$workId',
                  child: PrivacyBlurCover(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(localCoverPath),
                      fit: BoxFit.cover,
                      width: double.infinity,
                    ),
                  ),
                );
              }
            }
            return _buildPlaceholder();
          },
        );
      }
    }

    final httpHeaders = StorageService.serverCookieHeaders;

    // 降级使用网络封面
    if (work != null && host.isNotEmpty) {
      return Hero(
        tag: 'offline_work_cover_$workId',
        child: PrivacyBlurCover(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: work.getCoverImageUrl(host, token: token),
            httpHeaders: httpHeaders,
            fit: BoxFit.cover,
            errorWidget: (context, url, error) => _buildPlaceholder(),
          ),
        ),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_not_supported,
        size: 48,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// 作品封面缩略图：优先本地已下载的封面文件（离线可用、无需网络），
/// 否则回退到网络封面（走磁盘缓存），最后回退到占位图标。
///
/// 用于「选择音声 / 差异对比」对话框——那里只有标题和 RJ 号，
/// 同名作品或元数据缺标题时会分不清是哪一个。
class _WorkCoverThumb extends StatefulWidget {
  final int workId;
  final Map<String, dynamic>? metadata;
  final String? coverUrl;
  final double width;
  final double height;

  const _WorkCoverThumb({
    required this.workId,
    this.metadata,
    this.coverUrl,
    this.width = 44,
    this.height = 58,
  });

  @override
  State<_WorkCoverThumb> createState() => _WorkCoverThumbState();
}

class _WorkCoverThumbState extends State<_WorkCoverThumb> {
  String? _localCoverPath;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolveLocalCover();
  }

  Future<void> _resolveLocalCover() async {
    final metadata = widget.metadata;
    final relative = metadata?['localCoverPath'];
    if (metadata == null || relative is! String || relative.isEmpty) {
      _resolved = true;
      return;
    }
    String? path;
    try {
      final dir = await DownloadService.instance
          .getWorkDirectory(widget.workId, metadata: metadata);
      path = DownloadService.instance.localCoverPathForMetadata(dir, metadata);
    } catch (_) {
      path = null; // 本地封面不可用时静默回退到网络封面
    }
    if (!mounted) return;
    setState(() {
      _resolved = true;
      if (path != null && File(path).existsSync()) {
        _localCoverPath = path;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.album_outlined,
        size: widget.width * 0.45,
        color: cs.outline,
      ),
    );

    Widget image;
    if (_localCoverPath != null) {
      image = Image.file(
        File(_localCoverPath!),
        fit: BoxFit.cover,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) => placeholder,
      );
    } else if (_resolved && (widget.coverUrl ?? '').isNotEmpty) {
      image = CachedNetworkImage(
        imageUrl: widget.coverUrl!,
        httpHeaders: StorageService.serverCookieHeaders,
        fit: BoxFit.cover,
        width: widget.width,
        height: widget.height,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      );
    } else {
      // 本地封面尚未解析出来时也先占位，避免布局跳动
      image = placeholder;
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: PrivacyBlurCover(
        borderRadius: BorderRadius.circular(6),
        sigma: 10,
        child: image,
      ),
    );
  }
}

/// 差异对比条目：一个音声作品及其在线完整文件树（含本地存在状态）
/// 可选择的本地音声条目
class _WorkPickEntry {
  final int workId;
  final String workTitle;
  final Map<String, dynamic>? metadata; // 用于取本地封面文件
  final String? coverUrl; // 网络封面兜底地址
  const _WorkPickEntry({
    required this.workId,
    required this.workTitle,
    this.metadata,
    this.coverUrl,
  });
}

/// 选择要对比的音声对话框：多选（默认全选），支持全选/取消全选
class _WorkPickDialog extends StatefulWidget {
  final List<_WorkPickEntry> works;
  const _WorkPickDialog({required this.works});

  @override
  State<_WorkPickDialog> createState() => _WorkPickDialogState();
}

class _WorkPickDialogState extends State<_WorkPickDialog> {
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    // 默认全选，方便一键对比全部
    _selected.addAll(widget.works.map((w) => w.workId));
  }

  bool get _allSelected => _selected.length == widget.works.length;

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.works.map((w) => w.workId));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = S.of(context);
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      // 收紧左右留白（默认 40），给作品标题更多横向空间
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Row(
        children: [
          Expanded(child: Text(l10n.supplementPickWorksTitle)),
          TextButton.icon(
            onPressed: _toggleAll,
            icon: Icon(
              _allSelected ? Icons.deselect : Icons.select_all,
              size: 18,
            ),
            label: Text(_allSelected ? l10n.deselectAll : l10n.selectAll),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        // 用 builder 按需构建：本地作品可能有几百个，每个行都要解析封面，
        // 一次性全建会同时发起几百个文件系统查询。
        child: ListView.builder(
          // 不能复用外层的 PrimaryScrollController，否则会继承
          // 已下载页面的滚动位置，弹窗一打开就停在列表中间
          primary: false,
          itemCount: widget.works.length,
          itemBuilder: (context, index) {
            final w = widget.works[index];
            return CheckboxListTile(
              value: _selected.contains(w.workId),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(w.workId);
                } else {
                  _selected.remove(w.workId);
                }
              }),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                w.workTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                formatRJCode(w.workId),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              secondary: _WorkCoverThumb(
                workId: w.workId,
                metadata: w.metadata,
                coverUrl: w.coverUrl,
                width: 36,
                height: 48,
              ),
            );
          },
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            l10n.selectedCount(_selected.length),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _selected.toList()),
          child: Text(l10n.supplementCompareSelected),
        ),
      ],
    );
  }
}

class _WorkSupplementEntry {
  final int workId;
  final String workTitle;
  final List<SupplementFileNode> tree; // 在线完整文件树（根目录开始）
  final int missingCount; // 缺失文件数
  final Map<String, dynamic>? metadata; // 本地封面 + 后续入队复用
  final String? coverUrl; // 网络封面兜底地址
  const _WorkSupplementEntry({
    required this.workId,
    required this.workTitle,
    required this.tree,
    required this.missingCount,
    this.metadata,
    this.coverUrl,
  });
}

/// 差异对比树形多选对话框：
/// 以网络传来的在线列表为准，从根目录展示完整文件树；
/// 已存在的文件标记"已存在"且不可勾选，缺失的文件可勾选下载；
/// 支持多个音声同时对比。
class _SupplementDiffDialog extends StatefulWidget {
  final List<_WorkSupplementEntry> works;
  const _SupplementDiffDialog({required this.works});

  @override
  State<_SupplementDiffDialog> createState() => _SupplementDiffDialogState();
}

class _SupplementDiffDialogState extends State<_SupplementDiffDialog> {
  /// 行条统一高度
  static const double _rowHeight = 44;

  /// 每层目录的缩进宽度
  static const double _indentPerLevel = 16;

  /// 勾选框槽位宽度（已存在的行也占位，保证列对齐）
  static const double _checkSlotWidth = 26;

  /// 图标槽位宽度
  static const double _iconSlotWidth = 24;

  // 选中的缺失文件集合，key 格式: '$workId::$localRelativePath'
  // 注意：不提供"全选"入口——用户下载时通常只选取部分格式
  // （如 wav 或 mp3、有无音效），必须逐个/按文件夹手动勾选。
  final Set<String> _selected = {};
  // 展开的文件夹集合（默认全部展开）
  final Set<String> _expanded = {};
  // 收起的作品集合（默认全部展开）：点分组头或「全部收起」切换，
  // 收起后只留标题条，一屏能看到更多音声
  final Set<int> _collapsedWorks = {};

  int get _selectedFileCount => _selected.length;

  /// 是否所有作品都处于展开状态（决定标题行按钮显示「全部收起」还是「全部展开」）
  bool get _allWorksExpanded => _collapsedWorks.isEmpty;

  void _toggleWorkCollapsed(int workId) {
    setState(() {
      if (!_collapsedWorks.remove(workId)) _collapsedWorks.add(workId);
    });
  }

  void _toggleAllWorksExpanded() {
    setState(() {
      if (_collapsedWorks.isEmpty) {
        _collapsedWorks.addAll(widget.works.map((w) => w.workId));
      } else {
        _collapsedWorks.clear();
      }
    });
  }

  String _key(int workId, String path) => '$workId::$path';

  @override
  void initState() {
    super.initState();
    // 默认展开所有文件夹，展示完整文件树
    for (final w in widget.works) {
      void walk(List<SupplementFileNode> nodes) {
        for (final n in nodes) {
          if (n.isFolder) {
            _expanded.add(_key(w.workId, n.localRelativePath));
            walk(n.children);
          }
        }
      }

      walk(w.tree);
    }
  }

  // 收集节点下所有缺失文件的路径
  void _collectMissingFilePaths(SupplementFileNode node, List<String> out) {
    if (!node.isFolder) {
      if (!node.exists) out.add(node.localRelativePath);
      return;
    }
    for (final c in node.children) {
      _collectMissingFilePaths(c, out);
    }
  }

  void _toggleFile(String key, bool value) {
    setState(() {
      if (value) {
        _selected.add(key);
      } else {
        _selected.remove(key);
      }
    });
  }

  // 文件夹勾选：一键选中/取消该文件夹下所有缺失文件
  void _toggleFolder(
    _WorkSupplementEntry work,
    SupplementFileNode folder,
    bool value,
  ) {
    final paths = <String>[];
    _collectMissingFilePaths(folder, paths);
    setState(() {
      for (final p in paths) {
        final key = _key(work.workId, p);
        if (value) {
          _selected.add(key);
        } else {
          _selected.remove(key);
        }
      }
    });
  }

  // 文件夹勾选三态（基于其下缺失文件）：全部选中 true、全部未选 false、部分 null
  bool? _folderState(_WorkSupplementEntry work, SupplementFileNode folder) {
    final paths = <String>[];
    _collectMissingFilePaths(folder, paths);
    if (paths.isEmpty) return false;
    var selectedCount = 0;
    for (final p in paths) {
      if (_selected.contains(_key(work.workId, p))) selectedCount++;
    }
    if (selectedCount == paths.length) return true;
    if (selectedCount == 0) return false;
    return null;
  }

  // 切换文件夹展开/收起
  void _toggleExpanded(_TreeRow row) {
    setState(() {
      final key = _key(row.work.workId, row.node.localRelativePath);
      if (!_expanded.remove(key)) _expanded.add(key);
    });
  }

  // 平铺所有可见树行（含分组顺序）
  List<_TreeRow> _buildRows() {
    final rows = <_TreeRow>[];
    for (final w in widget.works) {
      _appendRows(rows, w, w.tree, 0);
    }
    return rows;
  }

  void _appendRows(
    List<_TreeRow> rows,
    _WorkSupplementEntry work,
    List<SupplementFileNode> nodes,
    int depth,
  ) {
    for (final node in nodes) {
      rows.add(_TreeRow(work: work, node: node, depth: depth));
      if (node.isFolder &&
          _expanded.contains(_key(work.workId, node.localRelativePath))) {
        _appendRows(rows, work, node.children, depth + 1);
      }
    }
  }

  // 根据扩展名选择合适的文件图标
  IconData _fileIcon(String title) {
    final t = title.toLowerCase();
    if (t.endsWith('.mp3') ||
        t.endsWith('.wav') ||
        t.endsWith('.flac') ||
        t.endsWith('.m4a') ||
        t.endsWith('.ogg')) {
      return Icons.audio_file;
    }
    if (t.endsWith('.mp4') || t.endsWith('.mkv') || t.endsWith('.webm')) {
      return Icons.movie;
    }
    if (t.endsWith('.jpg') ||
        t.endsWith('.jpeg') ||
        t.endsWith('.png') ||
        t.endsWith('.webp') ||
        t.endsWith('.gif')) {
      return Icons.image;
    }
    if (t.endsWith('.txt') ||
        t.endsWith('.vtt') ||
        t.endsWith('.pdf') ||
        t.endsWith('.md')) {
      return Icons.description;
    }
    return Icons.insert_drive_file;
  }

  // 文件夹下缺失文件数
  int _folderMissingCount(SupplementFileNode folder) {
    final paths = <String>[];
    _collectMissingFilePaths(folder, paths);
    return paths.length;
  }

  // 行标题：扩展名单独拆出来渲染，省略号只截断主干名，
  // 不再把 .wav / .mp3 这类用来区分格式的关键后缀吃掉。
  Widget _buildTitle(SupplementFileNode node) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 13,
      fontWeight: node.isFolder ? FontWeight.w600 : FontWeight.w400,
      color: node.exists && !node.isFolder ? cs.onSurfaceVariant : cs.onSurface,
    );
    final title = node.title;
    final dot = node.isFolder ? -1 : title.lastIndexOf('.');
    // 没有扩展名，或点号在首尾（隐藏文件 / 结尾点）时按普通文本渲染
    if (dot <= 0 || dot >= title.length - 1) {
      return Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Row(
      children: [
        Flexible(
          child: Text(
            title.substring(0, dot),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Text(
          title.substring(dot),
          maxLines: 1,
          style: style.copyWith(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  // 渲染单行条：文件夹 / 已存在文件 / 缺失文件共用同一套列宽，
  // 右侧信息统一右对齐成一列；选中行整条高亮 + 左缘竖条。
  Widget _buildNodeRow(_TreeRow row, {required bool showDivider}) {
    final cs = Theme.of(context).colorScheme;
    final l10n = S.of(context);
    final node = row.node;

    Widget? leading;
    Widget? iconSlot;
    Widget? meta;
    VoidCallback? onTap;
    var selectedRow = false;

    if (node.isFolder) {
      final folderKey = _key(row.work.workId, node.localRelativePath);
      final expanded = _expanded.contains(folderKey);
      final missing = _folderMissingCount(node);
      leading = Checkbox(
        value: _folderState(row.work, node),
        tristate: true,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: (v) => _toggleFolder(row.work, node, v == true),
      );
      iconSlot = Icon(
        expanded ? Icons.folder_open : Icons.folder,
        size: 17,
        color: cs.tertiary,
      );
      meta = Text(
        missing > 0 ? l10n.supplementMissingCount(missing) : '',
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      );
      onTap = () => _toggleExpanded(row);
    } else if (node.exists) {
      // 本地已存在：不可勾选；图标弱化，让"缺失可下载"的行更醒目
      leading = Icon(Icons.check_circle, size: 17, color: cs.outline);
      iconSlot = const SizedBox.shrink();
      meta = Text(
        l10n.supplementAlreadyExists,
        style: TextStyle(fontSize: 11, color: cs.outline),
      );
    } else {
      final fileKey = _key(row.work.workId, node.localRelativePath);
      final selected = _selected.contains(fileKey);
      selectedRow = selected;
      leading = Checkbox(
        value: selected,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: (v) => _toggleFile(fileKey, v ?? false),
      );
      iconSlot = Icon(
        _fileIcon(node.title),
        size: 17,
        color: cs.onSurfaceVariant,
      );
      meta = Text(
        formatBytes(node.file?.size ?? 0),
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      );
      onTap = () => _toggleFile(fileKey, !selected);
    }

    final rowContent = Container(
      height: _rowHeight,
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
              )
            : null,
      ),
      child: Row(
        children: [
          // 选中态左缘竖条：始终占位，避免选中时整行内容位移
          Container(
            width: 2,
            height: _rowHeight,
            color: selectedRow ? cs.primary : Colors.transparent,
          ),
          const SizedBox(width: 8),
          SizedBox(width: _indentPerLevel * row.depth),
          SizedBox(
            width: _checkSlotWidth,
            child: Align(alignment: Alignment.centerLeft, child: leading),
          ),
          SizedBox(
            width: _iconSlotWidth,
            child: Align(alignment: Alignment.centerLeft, child: iconSlot),
          ),
          Expanded(child: _buildTitle(node)),
          const SizedBox(width: 8),
          meta,
          // 文件夹留出展开箭头位，文件行用等宽占位，保证右端对齐
          if (node.isFolder)
            Icon(
              _expanded.contains(_key(row.work.workId, node.localRelativePath))
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 18,
              color: cs.outline,
            )
          else
            const SizedBox(width: 18),
        ],
      ),
    );

    return Material(
      color: selectedRow
          ? cs.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      child: onTap == null
          ? rowContent
          : InkWell(onTap: onTap, child: rowContent),
    );
  }

  // 作品分组头部：标题条（封面 + 序号 + 缺失徽标），点按可收起/展开该音声，
  // 收起后只留这一条，一屏能容纳更多音声
  Widget _buildWorkHeader(_WorkSupplementEntry work, int index) {
    final cs = Theme.of(context).colorScheme;
    final l10n = S.of(context);
    final collapsed = _collapsedWorks.contains(work.workId);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.55),
        border: Border(
          // 收起时没有行条，底边不需要分隔线
          bottom: collapsed
              ? BorderSide.none
              : BorderSide(color: cs.outlineVariant, width: 0.5),
        ),
      ),
      child: InkWell(
        onTap: () => _toggleWorkCollapsed(work.workId),
        child: Row(
          children: [
            _WorkCoverThumb(
              workId: work.workId,
              metadata: work.metadata,
              coverUrl: work.coverUrl,
              width: 32,
              height: 42,
            ),
            const SizedBox(width: 10),
            // 标题 + RJ 号竖排；缺失徽标靠右，不再挤占标题宽度
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${index + 1}. ${work.workTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    formatRJCode(work.workId),
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                l10n.supplementMissingCount(work.missingCount),
                style: TextStyle(fontSize: 11, color: cs.onErrorContainer),
              ),
            ),
            // 展开状态箭头，与文件夹行一致：展开朝上、收起朝下
            Icon(
              collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
              size: 18,
              color: cs.outline,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final rows = _buildRows();
    // 按作品 ID 分组行
    final grouped = <int, List<_TreeRow>>{};
    for (final r in rows) {
      grouped.putIfAbsent(r.work.workId, () => []).add(r);
    }
    final totalMissing =
        widget.works.fold<int>(0, (sum, w) => sum + w.missingCount);
    return AlertDialog(
      // 收紧左右留白（默认 40），行条内能多显示几个字符
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      title: Text(l10n.supplementPickTitle),
      contentPadding: EdgeInsets.zero,
      content: SizedBox(
        width: double.maxFinite,
        height: 520,
        child: Column(
          children: [
            // 摘要条：已选数量 + 缺失总数并成一条，替代原来孤立的一行；
            // 右侧放「全部收起/全部展开」，收起后每音声只剩标题条方便总览
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              child: Row(
                children: [
                  Text(
                    l10n.selectedCount(_selectedFileCount),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(width: 1, height: 12, color: cs.outlineVariant),
                  const SizedBox(width: 10),
                  Text(
                    l10n.supplementMissingCount(totalMissing),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _toggleAllWorksExpanded,
                    icon: Icon(
                      _allWorksExpanded ? Icons.unfold_less : Icons.unfold_more,
                      size: 16,
                    ),
                    label: Text(
                      _allWorksExpanded ? l10n.collapseAll : l10n.expandAll,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              // 按需构建分组卡片：封面解析只发生在可见的分组上
              child: ListView.builder(
                // 独立滚动位置，避免继承外层页面的 PrimaryScrollController
                primary: false,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                itemCount: widget.works.length,
                itemBuilder: (context, i) {
                  final work = widget.works[i];
                  // 收起的作品不渲染行条，只留标题条
                  final collapsed = _collapsedWorks.contains(work.workId);
                  final workRows = collapsed
                      ? const <_TreeRow>[]
                      : (grouped[work.workId] ?? const <_TreeRow>[]);
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: i != widget.works.length - 1 ? 12 : 0,
                    ),
                    // 分组卡片：标题条 + 行条
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildWorkHeader(work, i),
                          for (var r = 0; r < workRows.length; r++)
                            _buildNodeRow(
                              workRows[r],
                              showDivider: r != workRows.length - 1,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l10n.cancel),
        ),
        // 必须手动选择文件后才能补充下载（不提供"全部补全"），
        // 未选中任何文件时禁用
        FilledButton(
          onPressed: _selectedFileCount == 0
              ? null
              : () {
                  // 按作品分组返回选中的缺失文件
                  final result = <int, List<SupplementFile>>{};
                  for (final work in widget.works) {
                    final files = <SupplementFile>[];
                    void collect(SupplementFileNode node) {
                      if (!node.isFolder) {
                        if (!node.exists &&
                            node.file != null &&
                            _selected.contains(
                                _key(work.workId, node.localRelativePath))) {
                          files.add(node.file!);
                        }
                        return;
                      }
                      for (final c in node.children) {
                        collect(c);
                      }
                    }

                    for (final node in work.tree) {
                      collect(node);
                    }
                    if (files.isNotEmpty) result[work.workId] = files;
                  }
                  Navigator.pop(context, result);
                },
          child: Text(
            _selectedFileCount == 0
                ? l10n.download
                : '${l10n.download} ${l10n.nFiles(_selectedFileCount)}',
          ),
        ),
      ],
    );
  }
}

/// 平铺后的树行：记录所在作品、节点与层级深度
class _TreeRow {
  final _WorkSupplementEntry work;
  final SupplementFileNode node;
  final int depth;
  const _TreeRow({
    required this.work,
    required this.node,
    required this.depth,
  });
}
