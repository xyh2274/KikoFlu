import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/add_to_playlist_dialog.dart';

/// 锁定「添加到播放列表」弹层的页数覆盖逻辑。
///
/// 背景：旧实现把每个播放列表的检查页数写死为 `maxPages = 5`，
/// 覆盖上限 = 5 × 96 = 480 个作品；而真机上存在 601 / 633 个作品的播放列表，
/// 尾部作品因此被误判为「不在列表里」，UI 错误显示为可添加。
void main() {
  group('playlistPagesToScan', () {
    test('一页装得下时不再翻页', () {
      expect(
        playlistPagesToScan(totalCount: 25, effectivePageSize: 96, maxPages: 20),
        isEmpty,
      );
      // 正好一整页，也不应再多翻一页
      expect(
        playlistPagesToScan(totalCount: 96, effectivePageSize: 96, maxPages: 20),
        isEmpty,
      );
    });

    test('大播放列表覆盖到最后一页（633 个 / 每页 96）', () {
      // 633 / 96 = 6.59 → 共 7 页；旧实现只扫 5 页，第 6、7 页漏检
      expect(
        playlistPagesToScan(
          totalCount: 633,
          effectivePageSize: 96,
          maxPages: 20,
        ),
        [2, 3, 4, 5, 6, 7],
      );
    });

    test('601 个作品同样覆盖到最后（真机实测值）', () {
      expect(
        playlistPagesToScan(
          totalCount: 601,
          effectivePageSize: 96,
          maxPages: 20,
        ),
        [2, 3, 4, 5, 6, 7],
      );
    });

    test('末页不满时按实际条数收敛', () {
      expect(
        playlistPagesToScan(
          totalCount: 193,
          effectivePageSize: 96,
          maxPages: 20,
        ),
        [2, 3],
      );
      // 恰好多一个作品 → 多一页
      expect(
        playlistPagesToScan(
          totalCount: 97,
          effectivePageSize: 96,
          maxPages: 20,
        ),
        [2],
      );
    });

    test('服务端页长被截断时以实际页长换算', () {
      // 请求 96，服务端只给 50：633 / 50 = 12.66 → 13 页
      expect(
        playlistPagesToScan(
          totalCount: 633,
          effectivePageSize: 50,
          maxPages: 20,
        ),
        [for (var page = 2; page <= 13; page++) page],
      );
    });

    test('异常巨大的播放列表被 maxPages 兜住', () {
      expect(
        playlistPagesToScan(
          totalCount: 5000,
          effectivePageSize: 96,
          maxPages: 20,
        ),
        [for (var page = 2; page <= 20; page++) page],
      );
    });

    test('页长非法时不做任何请求', () {
      expect(
        playlistPagesToScan(
          totalCount: 100,
          effectivePageSize: 0,
          maxPages: 20,
        ),
        isEmpty,
      );
    });
  });
}
