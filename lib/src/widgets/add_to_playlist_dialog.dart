import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/playlist.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_detail_provider.dart';
import '../providers/playlists_provider.dart';
import '../services/log_service.dart';
import '../utils/snackbar_util.dart';
import '../../l10n/app_localizations.dart';
import 'responsive_dialog.dart';

/// 为覆盖播放列表里全部 [totalCount] 个作品，第 1 页之后仍需抓取的页码列表。
///
/// [effectivePageSize] 传**服务端第 1 页实际返回的条数**（可能小于请求值），
/// [maxPages] 为页数安全上限（防御作品数异常巨大的播放列表）。
/// 返回空列表表示第 1 页已经覆盖全部作品。
///
/// 抽成纯函数是为了让"页数覆盖"这个曾经的 bug 点可被回归测试锁住。
@visibleForTesting
List<int> playlistPagesToScan({
  required int totalCount,
  required int effectivePageSize,
  required int maxPages,
}) {
  if (effectivePageSize <= 0) return const [];
  if (totalCount <= effectivePageSize) return const [];

  var totalPages = (totalCount + effectivePageSize - 1) ~/ effectivePageSize;
  if (totalPages > maxPages) totalPages = maxPages;
  return [for (var page = 2; page <= totalPages; page++) page];
}

/// 会话级缓存：同一登录会话内反复打开弹窗时，播放列表清单与
/// 成员检查结果直接复用，避免每次打开都全量重拉（播放列表最多
/// 5 页、成员检查每列表还要翻页，是最耗时的两步）。
///
/// 失效策略：TTL 过期、登录 host 变化、增/删成功后增量同步
/// （只改对应 (workId, playlistId) 的成员标记，不整体丢弃）。
class _PlaylistDialogCache {
  _PlaylistDialogCache._();
  static final _PlaylistDialogCache instance = _PlaylistDialogCache._();

  static const Duration _ttl = Duration(minutes: 5);

  String? _host;
  List<Playlist>? _playlists;
  DateTime? _playlistsAt;

  /// workId -> (playlistId -> 是否包含该作品)
  final Map<int, Map<String, bool>> _membership = {};
  final Map<int, DateTime> _membershipAt = {};

  List<Playlist>? playlistsFor(String host) {
    if (_host != host) return null;
    final list = _playlists;
    final at = _playlistsAt;
    if (list == null || at == null) return null;
    if (DateTime.now().difference(at) > _ttl) return null;
    return List.of(list);
  }

  void storePlaylists(String host, List<Playlist> playlists) {
    if (_host != host) {
      _host = host;
      _membership.clear();
      _membershipAt.clear();
    }
    _playlists = List.of(playlists);
    _playlistsAt = DateTime.now();
  }

  Map<String, bool>? membershipFor(String host, int workId) {
    if (_host != host) return null;
    final at = _membershipAt[workId];
    if (at == null) return null;
    if (DateTime.now().difference(at) > _ttl) {
      _membership.remove(workId);
      _membershipAt.remove(workId);
      return null;
    }
    final result = _membership[workId];
    return result == null ? null : Map.of(result);
  }

  void storeMembership(String host, int workId, Map<String, bool> result) {
    if (_host != host) return;
    _membership[workId] = Map.of(result);
    _membershipAt[workId] = DateTime.now();
  }

  /// 增/删成功后增量同步对应成员标记
  void updateMembership(
    String host,
    int workId,
    String playlistId,
    bool inPlaylist,
  ) {
    if (_host != host) return;
    _membership.putIfAbsent(workId, () => {})[playlistId] = inPlaylist;
    _membershipAt[workId] = DateTime.now();
  }
}

/// 添加作品到播放列表的对话框
class AddToPlaylistDialog extends ConsumerStatefulWidget {
  final int workId;
  final String workTitle;

  const AddToPlaylistDialog({
    super.key,
    required this.workId,
    required this.workTitle,
  });

  static Future<bool?> show({
    required BuildContext context,
    required int workId,
    required String workTitle,
  }) {
    return showResponsiveBottomSheet<bool>(
      context: context,
      builder: (context) => AddToPlaylistDialog(
        workId: workId,
        workTitle: workTitle,
      ),
    );
  }

  @override
  ConsumerState<AddToPlaylistDialog> createState() =>
      _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends ConsumerState<AddToPlaylistDialog> {
  static final _log = LogService.instance;

  /// API 单页最大数量
  static const int _pageSize = 96;

  /// 检查成员关系时的安全页数上限（20 * 96 = 1920 个作品）
  static const int _maxPages = 20;

  /// 单个播放列表同时抓取的页数
  static const int _pageConcurrency = 6;

  bool _isAdding = false;
  bool _isLoadingPlaylists = true;
  String? _loadError;

  /// 仍在检查成员关系的播放列表 id（逐条消失，不再整表一起转圈）
  final Set<String> _checking = {};

  /// 本地加载的全部播放列表（不依赖分页 provider）
  List<Playlist> _allPlaylists = [];

  /// 记录作品已存在于哪些播放列表（playlistId -> true）
  final Set<String> _inPlaylists = {};

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadAllPlaylists());
  }

  /// 加载全部播放列表（遍历所有分页）
  ///
  /// 命中会话级缓存时直接复用，不再请求网络。
  Future<void> _loadAllPlaylists() async {
    final host = ref.read(authProvider).host ?? '';
    final cached = _PlaylistDialogCache.instance.playlistsFor(host);
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _allPlaylists = cached;
        _isLoadingPlaylists = false;
        _loadError = null;
      });
      _checkWorkMembership();
      return;
    }

    setState(() {
      _isLoadingPlaylists = true;
      _loadError = null;
    });

    try {
      final apiService = ref.read(kikoeruApiServiceProvider);
      final allPlaylists = <Playlist>[];
      int page = 1;
      const maxPages = 5; // 播放列表本身的页数上限（每页 _pageSize 个）

      while (page <= maxPages) {
        final result = await apiService.getUserPlaylists(
          page: page,
          pageSize: _pageSize,
          filterBy: 'all',
        );

        final List<dynamic> rawList = result['playlists'] as List? ?? [];
        final playlists = rawList
            .map((item) => Playlist.fromJson(item as Map<String, dynamic>))
            .toList();
        allPlaylists.addAll(playlists);

        if (playlists.isEmpty) break;
        // 优先用服务端给的总数判断是否取完（服务端可能截断 pageSize）
        final total = _totalCountOf(result);
        if (total != null) {
          if (allPlaylists.length >= total) break;
        } else if (playlists.length < _pageSize) {
          break;
        }
        page++;
      }

      if (mounted) {
        _PlaylistDialogCache.instance.storePlaylists(host, allPlaylists);
        setState(() {
          _allPlaylists = allPlaylists;
          _isLoadingPlaylists = false;
        });
        _checkWorkMembership();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingPlaylists = false;
          _loadError = e.toString();
        });
      }
    }
  }

  /// 从分页信息里取作品总数（服务端字段缺失时返回 null）
  int? _totalCountOf(Map<String, dynamic> response) {
    final pagination = response['pagination'];
    if (pagination is Map && pagination['totalCount'] is int) {
      return pagination['totalCount'] as int;
    }
    return null;
  }

  /// 检查作品在哪些播放列表中
  ///
  /// 逐条完成、逐条回填：每个播放列表查完就更新自己的那一行，
  /// 不再让每一行都挂着转圈直到整套检查结束。
  Future<void> _checkWorkMembership() async {
    if (_allPlaylists.isEmpty) return;

    // 命中会话级缓存：直接回填，不再逐列表翻页检查
    final host = ref.read(authProvider).host ?? '';
    final cached =
        _PlaylistDialogCache.instance.membershipFor(host, widget.workId);
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _checking.clear();
        _inPlaylists
          ..clear()
          ..addAll(
              cached.entries.where((e) => e.value).map((e) => e.key));
      });
      return;
    }

    setState(() {
      _inPlaylists.clear();
      _checking
        ..clear()
        ..addAll(_allPlaylists.map((playlist) => playlist.id));
    });

    final results = <String, bool>{};
    await Future.wait(_allPlaylists.map((playlist) async {
      bool found = false;
      try {
        found = await _isWorkInPlaylist(playlist);
      } catch (e) {
        _log.debug('检查播放列表成员失败: ${playlist.displayName}, $e',
            tag: 'Playlist');
      }
      results[playlist.id] = found;
      if (!mounted) return;
      setState(() {
        _checking.remove(playlist.id);
        if (found) {
          _inPlaylists.add(playlist.id);
        }
      });
    }));
    _PlaylistDialogCache.instance.storeMembership(host, widget.workId, results);
  }

  /// 检查作品是否已在指定播放列表中
  ///
  /// 旧实现逐页 `await`，几百个作品的播放列表要串行跑完 5 个来回，
  /// 而且被 maxPages 截断后还会漏检尾部的作品（误显示为"未收藏"）。
  /// 现在：先取第 1 页拿分页信息 `totalCount`，再把剩余页按
  /// [_pageConcurrency] 并发取回，既把 N 个串行来回压成一批，
  /// 也能覆盖播放列表的全部作品。
  Future<bool> _isWorkInPlaylist(Playlist playlist) async {
    final apiService = ref.read(kikoeruApiServiceProvider);

    final firstResponse = await apiService.getPlaylistWorks(
      playlistId: playlist.id,
      page: 1,
      pageSize: _pageSize,
    );
    final firstWorks = (firstResponse['works'] as List?) ?? const [];
    if (firstWorks.any((work) => work['id'] == widget.workId)) return true;
    if (firstWorks.isEmpty) return false;

    // 以服务端实际生效的页长为准（可能小于请求值）
    final effectivePageSize = firstWorks.length;
    final totalCount = _totalCountOf(firstResponse) ?? playlist.worksCount;
    if (totalCount <= effectivePageSize) return false; // 一页就取完了

    final pagesToScan = playlistPagesToScan(
      totalCount: totalCount,
      effectivePageSize: effectivePageSize,
      maxPages: _maxPages,
    );
    if (pagesToScan.isNotEmpty && pagesToScan.last >= _maxPages) {
      _log.debug(
          '播放列表 ${playlist.displayName} 作品过多，仅检查前 ${_maxPages * effectivePageSize} 个',
          tag: 'Playlist');
    }

    for (var offset = 0;
        offset < pagesToScan.length;
        offset += _pageConcurrency) {
      final end = offset + _pageConcurrency <= pagesToScan.length
          ? offset + _pageConcurrency
          : pagesToScan.length;
      final pages = pagesToScan.sublist(offset, end);

      final responses = await Future.wait(pages.map((page) async {
        try {
          return await apiService.getPlaylistWorks(
            playlistId: playlist.id,
            page: page,
            pageSize: effectivePageSize,
          );
        } catch (e) {
          _log.debug(
              '检查播放列表成员失败: ${playlist.displayName} 第 $page 页, $e',
              tag: 'Playlist');
          return const <String, dynamic>{};
        }
      }));

      for (final response in responses) {
        final works = (response['works'] as List?) ?? const [];
        if (works.any((work) => work['id'] == widget.workId)) return true;
      }
    }
    return false;
  }

  Future<void> _addToPlaylist(Playlist playlist) async {
    if (_isAdding) return;

    setState(() => _isAdding = true);

    try {
      final apiService = ref.read(kikoeruApiServiceProvider);
      await apiService.addWorksToPlaylist(
        playlistId: playlist.id,
        works: ['RJ${widget.workId}'],
      );

      if (mounted) {
        // 刷新播放列表详情（如果正在查看该播放列表）
        ref.invalidate(playlistDetailProvider(playlist.id));

        // 刷新播放列表列表（更新作品数量等信息）
        ref.read(playlistsProvider.notifier).refresh();

        // 同步会话级缓存，避免下次打开仍显示"未收藏"
        _PlaylistDialogCache.instance.updateMembership(
          ref.read(authProvider).host ?? '',
          widget.workId,
          playlist.id,
          true,
        );

        // 更新本地状态
        setState(() {
          _inPlaylists.add(playlist.id);
        });

        SnackBarUtil.showSuccess(
          context,
          S.of(context).addedToPlaylist(playlist.displayName),
        );
      }
    } catch (e) {
      if (mounted) {
        SnackBarUtil.showError(
            context, S.of(context).addFailedWithError(e.toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _isAdding = false);
      }
    }
  }

  /// 从播放列表中移除作品
  Future<void> _removeFromPlaylist(Playlist playlist) async {
    if (_isAdding) return;

    setState(() => _isAdding = true);

    try {
      final apiService = ref.read(kikoeruApiServiceProvider);
      await apiService.removeWorksFromPlaylist(
        playlistId: playlist.id,
        works: [widget.workId],
      );

      if (mounted) {
        // 刷新播放列表详情
        ref.invalidate(playlistDetailProvider(playlist.id));

        // 刷新播放列表列表
        ref.read(playlistsProvider.notifier).refresh();

        // 同步会话级缓存，避免下次打开仍显示"已收藏"
        _PlaylistDialogCache.instance.updateMembership(
          ref.read(authProvider).host ?? '',
          widget.workId,
          playlist.id,
          false,
        );

        // 更新本地状态
        setState(() {
          _inPlaylists.remove(playlist.id);
        });

        SnackBarUtil.showSuccess(
          context,
          S.of(context).removedFromPlaylist(playlist.displayName),
        );
      }
    } catch (e) {
      if (mounted) {
        SnackBarUtil.showError(
            context, S.of(context).removeFailedWithError(e.toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _isAdding = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BottomSheetHeader(
          title: S.of(context).addToPlaylist,
          subtitle: widget.workTitle,
          showCloseButton: isLandscape,
          trailing: [
            if (_isAdding)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        const Divider(height: 1),
        // 播放列表
        if (_isLoadingPlaylists)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_loadError != null)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Text(
                  S.of(context).loadFailedWithError(_loadError!),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _loadAllPlaylists,
                  icon: const Icon(Icons.refresh),
                  label: Text(S.of(context).retry),
                ),
              ],
            ),
          )
        else if (_allPlaylists.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Icon(
                  Icons.playlist_add,
                  size: 48,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  S.of(context).noPlaylists,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _allPlaylists.length,
              itemBuilder: (context, index) {
                final playlist = _allPlaylists[index];
                final isInPlaylist = _inPlaylists.contains(playlist.id);

                return ListTile(
                  leading: Stack(
                    children: [
                      CircleAvatar(
                        backgroundColor: isInPlaylist
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        child: Icon(
                          playlist.privacy == PlaylistPrivacy.private.value
                              ? Icons.lock
                              : playlist.privacy ==
                                      PlaylistPrivacy.unlisted.value
                                  ? Icons.link
                                  : Icons.public,
                          color: isInPlaylist
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                      if (isInPlaylist)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.check,
                              size: 10,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          ),
                        ),
                    ],
                  ),
                  title: Text(
                    playlist.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Row(
                    children: [
                      Text(
                        S.of(context).nWorksCount(playlist.worksCount),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (isInPlaylist) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            S.of(context).alreadyFavorited,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  trailing: _checking.contains(playlist.id)
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : isInPlaylist
                          ? IconButton(
                              icon: Icon(
                                Icons.remove_circle_outline,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              onPressed: _isAdding
                                  ? null
                                  : () => _removeFromPlaylist(playlist),
                              tooltip: S.of(context).removeFromPlaylist,
                            )
                          : IconButton(
                              icon: Icon(
                                Icons.add_circle_outline,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              onPressed: _isAdding
                                  ? null
                                  : () => _addToPlaylist(playlist),
                              tooltip: S.of(context).addToPlaylist,
                            ),
                  enabled: !_isAdding,
                  onTap: _isAdding
                      ? null
                      : isInPlaylist
                          ? () => _removeFromPlaylist(playlist)
                          : () => _addToPlaylist(playlist),
                );
              },
            ),
          ),
        // 底部按钮（竖屏模式）
        if (!isLandscape) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(S.of(context).cancel),
              ),
            ),
          ),
        ],
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: content,
    );
  }
}
