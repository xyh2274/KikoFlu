import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/download_file_path_service.dart';
import 'package:kikoeru_flutter/src/services/download_integrity_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('judgeFile —— 服务端没有该文件', () {
    test('本地有、服务端没有 → notOnServer，且不算问题', () {
      final v = DownloadIntegrityService.judgeFile(
        localSize: 1024,
        onlineSize: null,
        headerCorrupt: false,
        foundOnServer: false,
      );
      expect(v, FileIntegrityVerdict.notOnServer);
      // ★ 这条是"消除噪音"的核心：用户没下载过的版本不应被算成问题
      expect(v.isProblem, isFalse);
    });

    test('notOnServer 优先于其它判据（哪怕本地 0 字节）', () {
      expect(
        DownloadIntegrityService.judgeFile(
          localSize: 0,
          onlineSize: null,
          headerCorrupt: true,
          foundOnServer: false,
        ),
        FileIntegrityVerdict.notOnServer,
      );
    });
  });

  group('judgeFile —— 坏文件形态', () {
    test('0 字节 → zeroByte，且优先于"长度偏小"', () {
      final v = DownloadIntegrityService.judgeFile(
        localSize: 0,
        onlineSize: 148550742,
        headerCorrupt: false,
        foundOnServer: true,
      );
      expect(v, FileIntegrityVerdict.zeroByte);
      expect(v.isProblem, isTrue);
    });

    test('比服务端大 → oversize（重复/覆盖写入）', () {
      expect(
        DownloadIntegrityService.judgeFile(
          localSize: 200,
          onlineSize: 100,
          headerCorrupt: false,
          foundOnServer: true,
        ),
        FileIntegrityVerdict.oversize,
      );
    });

    test('比服务端小 → shortSize（缺头/缺中段/只剩尾段）', () {
      // 真实形态：RJ289670 #6 本地 28,881,430 vs 服务端 148,550,742
      expect(
        DownloadIntegrityService.judgeFile(
          localSize: 28881430,
          onlineSize: 148550742,
          headerCorrupt: true,
          foundOnServer: true,
        ),
        FileIntegrityVerdict.shortSize,
      );
    });

    // ★ 最容易被漏掉的一类：长度完全正确，纯长度校验必然放行
    test('长度一致但容器头非法 → headerCorrupt', () {
      // 真实形态：RJ289670 #4 本地与服务端同为 194,857,760，
      // 但前 24–25 MB 被同源数据覆盖，头不是 RIFF
      final v = DownloadIntegrityService.judgeFile(
        localSize: 194857760,
        onlineSize: 194857760,
        headerCorrupt: true,
        foundOnServer: true,
      );
      expect(v, FileIntegrityVerdict.headerCorrupt);
      expect(v.isProblem, isTrue);
    });

    test('长度一致且头合法 → ok', () {
      final v = DownloadIntegrityService.judgeFile(
        localSize: 8623440,
        onlineSize: 8623440,
        headerCorrupt: false,
        foundOnServer: true,
      );
      expect(v, FileIntegrityVerdict.ok);
      expect(v.isProblem, isFalse);
    });

    test('服务端未返回 size 时（onlineSize null）只看头', () {
      expect(
        DownloadIntegrityService.judgeFile(
          localSize: 999,
          onlineSize: null,
          headerCorrupt: false,
          foundOnServer: true,
        ),
        FileIntegrityVerdict.ok,
      );
      expect(
        DownloadIntegrityService.judgeFile(
          localSize: 999,
          onlineSize: null,
          headerCorrupt: true,
          foundOnServer: true,
        ),
        FileIntegrityVerdict.headerCorrupt,
      );
    });
  });

  group('scanLocalMediaFiles', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('kikoflu_integrity_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    File put(String rel, int bytes) {
      final f = File(p.join(tempDir.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(List<int>.filled(bytes, 0x41));
      return f;
    }

    test('只收媒体文件，跳过元数据/封面/隐藏文件', () async {
      put('a.wav', 10);
      put('b.mp3', 20);
      put('sub/c.flac', 30);
      put('notes.txt', 5);
      put('cover.jpg', 4);
      put('work_metadata.json', 6);
      put('.hidden.wav', 7);
      put('x.downloading', 8);

      final found = await DownloadIntegrityService.scanLocalMediaFiles(tempDir.path);

      String norm(String rel) =>
          DownloadFilePathService.normalizeRelativePath(p.join(rel));

      expect(found.keys.toSet(), {
        norm('a.wav'),
        norm('b.mp3'),
        norm(p.join('sub', 'c.flac')),
      });
      expect(found[norm('a.wav')], 10);
      expect(found[norm(p.join('sub', 'c.flac'))], 30);
    });

    test('0 字节媒体文件会被收进来（它正是要报告的对象）', () async {
      put('zero.wav', 0);
      put('ok.wav', 12);

      final found = await DownloadIntegrityService.scanLocalMediaFiles(tempDir.path);
      expect(found.length, 2);
      expect(found.values, contains(0));
    });

    test('目录不存在时返回空表而不是抛异常', () async {
      final found = await DownloadIntegrityService.scanLocalMediaFiles(
        p.join(tempDir.path, 'not-exist'),
      );
      expect(found, isEmpty);
    });
  });

  group('flattenOnlineTree', () {
    test('展平嵌套树并规范化相对路径', () {
      final tree = <dynamic>[
        {
          'type': 'folder',
          'title': '本編',
          'children': [
            {
              'type': 'file',
              'title': '#1.テスト.wav',
              'size': 123,
              'hash': 'abc',
              'mediaDownloadUrl': 'https://x/1',
            },
            {
              'type': 'folder',
              'title': 'mp3',
              'children': [
                {'type': 'file', 'title': 'a.mp3', 'size': 456},
              ],
            },
          ],
        },
        {'type': 'file', 'title': 'readme.txt', 'size': 10},
      ];

      final flat = DownloadIntegrityService.flattenOnlineTree(tree);
      expect(flat.length, 3);
      expect(flat.containsValue(flat.values.firstWhere((f) => f.size == 123)), isTrue);
      expect(flat.values.any((f) => f.size == 456), isTrue);

      // 标题被完整保留（含 # 号，不能被当成路径分隔或注释）
      expect(flat.values.any((f) => f.title == '#1.テスト.wav'), isTrue);
    });

    test('缺 title 或非法节点被跳过，不污染结果', () {
      final tree = <dynamic>[
        {'type': 'file', 'size': 1},
        'not-a-map',
        {'type': 'file', 'title': 'ok.mp3', 'size': 2},
      ];
      final flat = DownloadIntegrityService.flattenOnlineTree(tree);
      expect(flat.length, 1);
      expect(flat.values.first.size, 2);
    });
  });

  group('WorkIntegrityReport', () {
    FileIntegrityFinding make(FileIntegrityVerdict v, {String path = 'x.wav'}) =>
        FileIntegrityFinding(
          relativePath: path,
          fileName: p.basename(path),
          localSize: 1,
          onlineSize: 1,
          verdict: v,
        );

    test('problems / okCount 只统计真正需要重下的', () {
      final report = WorkIntegrityReport(
        workId: 289670,
        workTitle: 't',
        findings: [
          make(FileIntegrityVerdict.ok),
          make(FileIntegrityVerdict.headerCorrupt, path: 'a.wav'),
          make(FileIntegrityVerdict.notOnServer, path: 'b.wav'),
          make(FileIntegrityVerdict.zeroByte, path: 'c.wav'),
        ],
      );

      expect(report.scannedCount, 4);
      expect(report.okCount, 1);
      // notOnServer 不进 problems
      expect(report.problemCount, 2);
      expect(report.hasProblem, isTrue);
      expect(
        report.problems.map((f) => f.fileName).toSet(),
        {'a.wav', 'c.wav'},
      );
    });

    test('全好时 hasProblem 为 false', () {
      final report = WorkIntegrityReport(
        workId: 1,
        workTitle: 't',
        findings: [make(FileIntegrityVerdict.ok)],
      );
      expect(report.hasProblem, isFalse);
      expect(report.problems, isEmpty);
    });
  });

  group('mediaExtensions', () {
    test('覆盖常见音频/视频容器（与 isCorruptMediaFile 口径一致）', () {
      for (final ext in ['wav', 'mp3', 'flac', 'm4a', 'm4b', 'ogg', 'opus']) {
        expect(DownloadIntegrityService.mediaExtensions, contains(ext));
      }
    });
  });
}
