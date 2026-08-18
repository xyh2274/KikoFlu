import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
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
import '../providers/auth_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../utils/responsive_grid_helper.dart';
import '../widgets/enhanced_work_card.dart';
import '../widgets/pagination_bar.dart';
import '../widgets/sort_dialog.dart';
import 'offline_work_detail_screen.dart';
import '../widgets/overscroll_next_page_detector.dart';
import '../widgets/privacy_blur_cover.dart';
import '../utils/scroll_optimization.dart';

final _log = LogService.instance;

/// 本地下载屏幕 - 显示已完成的下载内容
class LocalDownloadsScreen extends ConsumerStatefulWidget {
  const LocalDownloadsScreen({super.key});

  @override
  ConsumerState<LocalDownloadsScreen> createState() =>
      _LocalDownloadsScreenState();
}

class _LocalDownloadsScreenState extends ConsumerState<LocalDownloadsScreen>
    with AutomaticKeepAliveClientMixin {
  bool _isSelectionMode = false;
  final Set<int> _selectedWorkIds = {}; // 选中的作品ID
  final ScrollController _scrollController = ScrollController();
  int _currentPage = 1;
  final int _pageSize = 30;

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
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPage(int page) {
    setState(() {
      _currentPage = page;
    });
    _scrollToTop();
  }

  void _nextPage(int totalPages) {
    if (_currentPage < totalPages) {
      _goToPage(_currentPage + 1);
    }
  }

  void _previousPage() {
    if (_currentPage > 1) {
      _goToPage(_currentPage - 1);
    }
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

      // 在线刮削：本地元数据不完整的作品联网补全（需已配置服务器）
      var scrapedCount = 0;
      final authState = ref.read(authProvider);
      if ((authState.host ?? '').isNotEmpty) {
        for (final workId in _diskWorks.keys.toList()) {
          final meta = _diskWorks[workId];
          if (meta == null) continue;
          if (!DownloadService.needsOnlineMetadataScrape(meta)) continue;
          if (await DownloadService.instance.scrapeWorkMetadata(workId)) {
            scrapedCount++;
          }
        }
        if (scrapedCount > 0) await _loadDiskWorks();
      }

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deletionConfirmTitle),
        content: Text(l10n.deleteSelectedWorksConfirm(_selectedWorkIds.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
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
      barrierDismissible: !Platform.isIOS,
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
        final rjCode = 'RJ${workId.toString().padLeft(6, '0')}';

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

    final entries = [
      for (final workId in workIds)
        _WorkPickEntry(
          workId: workId,
          workTitle: (() {
            final meta = _metadataForWork(workId, groupedTasks);
            return (meta?['title'] as String?) ?? 'RJ$workId';
          })(),
        ),
    ];

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

      // 按作品执行补充下载
      int totalAdded = 0;
      for (final entry in selectedMap.entries) {
        final metadata = _metadataForWork(entry.key, groupedTasks);
        final work = metadata != null
            ? Work.fromJson(_sanitizeMetadata(metadata))
            : null;
        final coverUrl = work?.getCoverImageUrl(host, token: token);
        totalAdded += await DownloadService.instance.supplementDownloads(
          entry.key,
          entry.value,
          workMetadata: metadata,
          coverUrl: coverUrl,
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
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final gridSpacing = isLandscape ? 24.0 : 8.0;
        final gridPadding = isLandscape ? 24.0 : 8.0;

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

        // 计算分页
        final totalCount = sortedWorkIds.length;
        final totalPages = (totalCount / _pageSize).ceil();
        final startIndex = (_currentPage - 1) * _pageSize;
        final endIndex = (startIndex + _pageSize).clamp(0, totalCount);

        // 获取当前页的作品
        final currentPageWorkIds = sortedWorkIds.sublist(
          startIndex,
          endIndex,
        );
        final currentPageTasks = Map<int, List<DownloadTask>>.fromEntries(
          currentPageWorkIds.map((id) => MapEntry(id, groupedTasks[id]!)),
        );

        return Column(
          children: [
            // 顶部工具栏
            _buildTopBar(allGroupedTasks),
            // 搜索栏
            if (_isSearchVisible) _buildSearchBar(),
            // 内容区域
            Expanded(
              child: allGroupedTasks.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.download_outlined,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            S.of(context).noLocalDownloads,
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : groupedTasks.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.search_off,
                                size: 64,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                S.of(context).noResults,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      : OverscrollNextPageDetector(
                          hasNextPage: _currentPage < totalPages,
                          isLoading: false,
                          onNextPage: () async {
                            _nextPage(totalPages);
                            // 等待一帧后滚动到顶部，确保内容已加载
                            await Future.delayed(
                                const Duration(milliseconds: 50));
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _scrollToTop();
                            });
                          },
                          child: CustomScrollView(
                            controller: _scrollController,
                            cacheExtent: ScrollOptimization.cacheExtent,
                            physics: ScrollOptimization.physics,
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                    gridPadding, 8, gridPadding, gridPadding),
                                sliver: SliverMasonryGrid.count(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: gridSpacing,
                                  mainAxisSpacing: gridSpacing,
                                  childCount: currentPageTasks.length,
                                  itemBuilder: (context, index) {
                                    final workId = currentPageWorkIds[index];
                                    final workTasks =
                                        currentPageTasks[workId]!;
                                    final firstTask =
                                        _displayTask(workId, workTasks);
                                    final isSelected =
                                        _selectedWorkIds.contains(workId);

                                    return _buildWorkCard(
                                      workId: workId,
                                      workTasks: workTasks,
                                      firstTask: firstTask,
                                      isSelected: isSelected,
                                      crossAxisCount: crossAxisCount,
                                    );
                                  },
                                ),
                              ),
                              // 分页控件
                              SliverPadding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 24),
                                sliver: SliverToBoxAdapter(
                                  child: PaginationBar(
                                    currentPage: _currentPage,
                                    totalCount: totalCount,
                                    pageSize: _pageSize,
                                    hasMore: _currentPage < totalPages,
                                    isLoading: false,
                                    onPreviousPage: _previousPage,
                                    onNextPage: () => _nextPage(totalPages),
                                    onGoToPage: _goToPage,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTopBar(Map<int, List<DownloadTask>> groupedTasks) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final horizontalPadding = isLandscape ? 24.0 : 8.0;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(vertical: 4),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      child: _isSelectionMode
          ? Row(
              children: [
                // 退出选择按钮
                Padding(
                  padding: EdgeInsets.only(left: horizontalPadding - 8),
                  child: IconButton(
                    icon: const Icon(Icons.close),
                    iconSize: 22,
                    padding: const EdgeInsets.all(8),
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    onPressed: _toggleSelectionMode,
                    tooltip: S.of(context).exitSelection,
                  ),
                ),
                // 选中数量显示
                Text(
                  S.of(context).selectedCount(_selectedWorkIds.length),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                // 全选/取消全选按钮
                IconButton(
                  icon: Icon(
                    _selectedWorkIds.length == groupedTasks.length
                        ? Icons.deselect
                        : Icons.select_all,
                  ),
                  iconSize: 22,
                  padding: const EdgeInsets.all(8),
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: _selectedWorkIds.length == groupedTasks.length
                      ? _deselectAll
                      : () => _selectAll(groupedTasks),
                  tooltip: _selectedWorkIds.length == groupedTasks.length
                      ? S.of(context).deselectAll
                      : S.of(context).selectAll,
                ),
                // 补充下载按钮（对选中的作品执行差异对比与补充下载）
                if (_selectedWorkIds.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.cloud_download_outlined),
                    iconSize: 22,
                    padding: const EdgeInsets.all(8),
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    onPressed: () => _supplementDownloadSelected(
                      groupedTasks,
                      _selectedWorkIds.toList(),
                    ),
                    tooltip: S.of(context).supplementDownload,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                // 删除按钮
                if (_selectedWorkIds.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete),
                    iconSize: 22,
                    padding: const EdgeInsets.all(8),
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    onPressed: () => _deleteSelectedWorks(groupedTasks),
                    tooltip:
                        '${S.of(context).delete} (${_selectedWorkIds.length})',
                    color: Theme.of(context).colorScheme.error,
                  ),
                SizedBox(width: horizontalPadding - 8),
              ],
            )
          : Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 选择按钮
                    Padding(
                      padding: const EdgeInsets.only(left: 20, right: 8),
                      child: TextButton.icon(
                        icon: const Icon(Icons.checklist, size: 20),
                        label: Text(S.of(context).select),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.5),
                        ),
                        onPressed: _toggleSelectionMode,
                      ),
                    ),
                    // 补充下载（全部）按钮
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TextButton.icon(
                        icon: const Icon(Icons.cloud_download_outlined,
                            size: 20),
                        label: Text(S.of(context).supplementDownload),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.5),
                        ),
                        onPressed: () =>
                            _pickWorksForSupplement(groupedTasks),
                      ),
                    ),
                    // 刷新按钮
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 20),
                        label: Text(S.of(context).reload),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.5),
                        ),
                        onPressed: _refreshMetadata,
                      ),
                    ),
                    // 打开文件夹按钮（仅 Windows 和 macOS）
                    if (Platform.isWindows ||
                        Platform.isMacOS ||
                        Platform.isLinux)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TextButton.icon(
                          icon: const Icon(Icons.folder_open, size: 20),
                          label: Text(S.of(context).openFolder),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .primaryContainer
                                .withValues(alpha: 0.5),
                          ),
                          onPressed: _openDownloadFolder,
                        ),
                      ),
                    // 搜索按钮
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        icon: Icon(
                          _isSearchVisible ? Icons.search_off : Icons.search,
                          size: 22,
                        ),
                        padding: const EdgeInsets.all(8),
                        constraints:
                            const BoxConstraints(minWidth: 40, minHeight: 40),
                        onPressed: _toggleSearch,
                        tooltip: S.of(context).search,
                      ),
                    ),
                    // 排序按钮
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        icon: const Icon(Icons.sort, size: 22),
                        padding: const EdgeInsets.all(8),
                        constraints:
                            const BoxConstraints(minWidth: 40, minHeight: 40),
                        onPressed: _showSortDialog,
                        tooltip: S.of(context).sortOptions,
                      ),
                    ),
                  ],
                ),
              ),
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

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.3),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        decoration: InputDecoration(
          hintText: S.of(context).searchDownloads,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 20),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                      _currentPage = 1;
                    });
                  },
                )
              : null,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        onChanged: (value) {
          setState(() {
            _searchQuery = value;
            _currentPage = 1;
          });
        },
      ),
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

/// 差异对比条目：一个音声作品及其在线完整文件树（含本地存在状态）
/// 可选择的本地音声条目
class _WorkPickEntry {
  final int workId;
  final String workTitle;
  const _WorkPickEntry({required this.workId, required this.workTitle});
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
        child: ListView(
          children: [
            for (final w in widget.works)
              CheckboxListTile(
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'RJ${w.workId.toString().padLeft(6, '0')}',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                secondary: Icon(Icons.album_outlined, color: cs.primary),
              ),
          ],
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
  const _WorkSupplementEntry({
    required this.workId,
    required this.workTitle,
    required this.tree,
    required this.missingCount,
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
  // 选中的缺失文件集合，key 格式: '$workId::$localRelativePath'
  final Set<String> _selected = {};
  // 展开的文件夹集合（默认全部展开）
  final Set<String> _expanded = {};

  int get _totalMissingCount =>
      widget.works.fold(0, (sum, w) => sum + w.missingCount);

  int get _selectedFileCount => _selected.length;

  bool get _allSelected => _selectedFileCount == _totalMissingCount;

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

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        for (final w in widget.works) {
          for (final node in w.tree) {
            final paths = <String>[];
            _collectMissingFilePaths(node, paths);
            for (final p in paths) {
              _selected.add(_key(w.workId, p));
            }
          }
        }
      }
    });
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
      _appendRows(rows, w, w.tree, const []);
    }
    return rows;
  }

  void _appendRows(
    List<_TreeRow> rows,
    _WorkSupplementEntry work,
    List<SupplementFileNode> nodes,
    List<bool> chain,
  ) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final isLast = i == nodes.length - 1;
      final lastChain = [...chain, isLast];
      rows.add(_TreeRow(
        work: work,
        node: node,
        depth: chain.length,
        lastChain: lastChain,
      ));
      if (node.isFolder &&
          _expanded.contains(_key(work.workId, node.localRelativePath))) {
        _appendRows(rows, work, node.children, lastChain);
      }
    }
  }

  // 层级引导线：每级缩进 20px，绘制竖线/拐角标明从属关系
  Widget _buildGuides(_TreeRow row, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < row.depth; i++)
          SizedBox(
            width: 20,
            height: 40,
            child: CustomPaint(
              painter: _TreeGuidePainter(
                hasSibling: !row.lastChain[i],
                isCurrent: i == row.depth - 1,
                color: color,
              ),
            ),
          ),
      ],
    );
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

  // 渲染单行树节点（文件夹 / 已存在文件 / 缺失文件）
  Widget _buildNodeRow(_TreeRow row) {
    final cs = Theme.of(context).colorScheme;
    final node = row.node;
    final guides = _buildGuides(row, cs.outlineVariant);

    if (node.isFolder) {
      final key = _key(row.work.workId, node.localRelativePath);
      final expanded = _expanded.contains(key);
      final state = _folderState(row.work, node);
      final missing = _folderMissingCount(node);
      return InkWell(
        onTap: () => _toggleExpanded(row),
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              guides,
              const SizedBox(width: 2),
              Checkbox(
                value: state,
                tristate: true,
                onChanged: (v) => _toggleFolder(row.work, node, v == true),
              ),
              const SizedBox(width: 2),
              Icon(
                expanded ? Icons.folder_open : Icons.folder,
                size: 18,
                color: cs.tertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  node.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                missing > 0 ? S.of(context).supplementMissingCount(missing) : '',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              Icon(
                expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 18,
                color: cs.outline,
              ),
            ],
          ),
        ),
      );
    }

    if (node.exists) {
      // 本地已存在：不可勾选，标记"已存在"
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            guides,
            const SizedBox(width: 2),
            const SizedBox(width: 40), // checkbox 占位
            Icon(Icons.check_circle, size: 17, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                S.of(context).supplementAlreadyExists,
                style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      );
    }

    // 缺失文件：可勾选
    final key = _key(row.work.workId, node.localRelativePath);
    final selected = _selected.contains(key);
    return InkWell(
      onTap: () => _toggleFile(key, !selected),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            guides,
            const SizedBox(width: 2),
            Checkbox(
              value: selected,
              onChanged: (v) => _toggleFile(key, v ?? false),
            ),
            const SizedBox(width: 2),
            Icon(_fileIcon(node.title), size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatBytes(node.file?.size ?? 0),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  // 作品分组头部：渐变底色 + 序号 + 缺失徽标，强化多音声区分
  Widget _buildWorkHeader(_WorkSupplementEntry work, int index) {
    final cs = Theme.of(context).colorScheme;
    final l10n = S.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            cs.primaryContainer.withValues(alpha: 0.85),
            cs.surfaceContainerHighest.withValues(alpha: 0.5),
          ],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: cs.primary,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: cs.onPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Icon(Icons.album_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${work.workTitle} (RJ${work.workId.toString().padLeft(6, '0')})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              l10n.supplementMissingCount(work.missingCount),
              style: TextStyle(fontSize: 11, color: cs.onErrorContainer),
            ),
          ),
        ],
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
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(l10n.supplementPickTitle)),
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
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.selectedCount(_selectedFileCount),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            const Divider(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (var i = 0; i < widget.works.length; i++) ...[
                    // 分组卡片：头部 + 树行
                    Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildWorkHeader(widget.works[i], i),
                          const Divider(height: 1),
                          ...(grouped[widget.works[i].workId] ?? [])
                              .map(_buildNodeRow),
                        ],
                      ),
                    ),
                    if (i != widget.works.length - 1)
                      const SizedBox(height: 12),
                  ],
                ],
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
        TextButton(
          onPressed: () {
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
          child: Text(l10n.download),
        ),
      ],
    );
  }
}

/// 平铺后的树行：记录所在作品、节点、层级深度与"是否最后子节点"链
class _TreeRow {
  final _WorkSupplementEntry work;
  final SupplementFileNode node;
  final int depth;
  final List<bool> lastChain;
  const _TreeRow({
    required this.work,
    required this.node,
    required this.depth,
    required this.lastChain,
  });
}

/// 树形引导线画笔：竖线 + 拐角横线，标明目录层级从属关系
class _TreeGuidePainter extends CustomPainter {
  final bool hasSibling; // 该层级之后是否还有兄弟节点（竖线需贯穿）
  final bool isCurrent; // 是否为当前节点所在层级（需绘制横线拐角）
  final Color color;
  const _TreeGuidePainter({
    required this.hasSibling,
    required this.isCurrent,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    final midY = size.height / 2;
    final x = size.width / 2;
    canvas.drawLine(Offset(x, 0), Offset(x, midY), paint);
    if (hasSibling) {
      canvas.drawLine(Offset(x, midY), Offset(x, size.height), paint);
    }
    if (isCurrent) {
      canvas.drawLine(Offset(x, midY), Offset(size.width, midY), paint);
    }
  }

  @override
  bool shouldRepaint(_TreeGuidePainter oldDelegate) =>
      oldDelegate.hasSibling != hasSibling ||
      oldDelegate.isCurrent != isCurrent ||
      oldDelegate.color != color;
}
