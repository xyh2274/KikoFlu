import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/log_file_writer.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('kikoflu_log_writer_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  LogFileWriter buildWriter({
    int maxFileBytes = 2 * 1024 * 1024,
    int maxFiles = 4,
    int maxBufferedLines = 5000,
  }) {
    return LogFileWriter(
      directoryPath: tempDir.path,
      baseName: 'app',
      maxFileBytes: maxFileBytes,
      maxFiles: maxFiles,
      maxBufferedLines: maxBufferedLines,
      // 定时器周期拉长，避免测试里被后台 flush 干扰；用例都显式调 flush()。
      flushInterval: const Duration(hours: 1),
    );
  }

  String readCurrent(LogFileWriter w) => File(w.currentFilePath).readAsStringSync();

  test('open 会创建目录，flush 后内容落盘', () async {
    final dir = Directory(p.join(tempDir.path, 'nested', 'logs'));
    final writer = LogFileWriter(
      directoryPath: dir.path,
      flushInterval: const Duration(hours: 1),
    );

    await writer.open();
    expect(dir.existsSync(), isTrue);

    writer.add('line-1');
    writer.add('line-2');
    expect(writer.pendingLineCount, 2);
    // 还没 flush，文件应当不存在（有界缓冲，不常开句柄）
    expect(File(writer.currentFilePath).existsSync(), isFalse);

    await writer.flush();
    expect(writer.pendingLineCount, 0);
    expect(readCurrent(writer), 'line-1\nline-2\n');

    await writer.close();
  });

  test('行内换行被压平，保证一行一条记录', () async {
    final writer = buildWriter();
    await writer.open();

    writer.add('first\nsecond\r\nthird');
    await writer.flush();

    expect(readCurrent(writer), 'first second  third\n');

    await writer.close();
  });

  test('缓冲有上限，超出时丢弃最老的（不会撑爆内存）', () async {
    final writer = buildWriter(maxBufferedLines: 3);
    await writer.open();

    // 用超长定时器 + 显式不 flush，观察缓冲上限行为。
    writer.add('a');
    writer.add('b');
    writer.add('c');
    writer.add('d');
    writer.add('e');

    expect(writer.pendingLineCount, 3);
    expect(writer.pendingLines, ['c', 'd', 'e']);

    await writer.close();
  });

  test('超过 maxFileBytes 触发轮转，且保留的文件数不超过 maxFiles', () async {
    final writer = buildWriter(maxFileBytes: 20, maxFiles: 3);
    await writer.open();

    // 每批约 14 字节，写 4 批必然触发多次轮转
    for (var i = 0; i < 4; i++) {
      writer.add('batch-$i-payload');
      await writer.flush();
    }

    final existing = <String>[];
    for (var i = 0; i < 5; i++) {
      final f = File(writer.filePathAt(i));
      if (f.existsSync()) existing.add(p.basename(f.path));
    }
    expect(existing.length, lessThanOrEqualTo(3));
    // 当前文件一定是 app.log
    expect(File(writer.currentFilePath).existsSync(), isTrue);

    await writer.close();
  });

  test('轮转后 readAll 按最老 → 最新拼接，内容不丢不重', () async {
    final writer = buildWriter(maxFileBytes: 30, maxFiles: 4);
    await writer.open();

    for (var i = 0; i < 3; i++) {
      writer.add('chunk-$i-xxxxxxxxxx');
      await writer.flush();
    }

    final all = await writer.readAll();
    // 三条记录都还在（只是可能分散在不同文件里），且各出现一次
    for (var i = 0; i < 3; i++) {
      expect('chunk-$i-xxxxxxxxxx'.allMatches(all).length, 1,
          reason: 'chunk-$i 应恰好出现一次');
    }
    // 最老的应排在最前
    expect(all.indexOf('chunk-0'), lessThan(all.indexOf('chunk-2')));

    await writer.close();
  });

  test('空文件不轮转：单条超长内容也写得下去（防死循环）', () async {
    final writer = buildWriter(maxFileBytes: 16, maxFiles: 3);
    await writer.open();

    writer.add('x' * 100); // 远超 maxFileBytes
    await writer.flush();

    expect(File(writer.currentFilePath).existsSync(), isTrue);
    expect(readCurrent(writer).length, greaterThan(100));
    // 不该产生归档文件
    expect(File(writer.filePathAt(1)).existsSync(), isFalse);

    await writer.close();
  });

  test('clearAll 删除全部文件并清空缓冲', () async {
    final writer = buildWriter(maxFileBytes: 20, maxFiles: 3);
    await writer.open();

    for (var i = 0; i < 3; i++) {
      writer.add('data-$i-xxxxxxxxx');
      await writer.flush();
    }
    writer.add('pending');

    await writer.clearAll();

    expect(writer.pendingLineCount, 0);
    for (var i = 0; i < 3; i++) {
      expect(File(writer.filePathAt(i)).existsSync(), isFalse);
    }

    await writer.close();
  });

  test('pendingLines 与文件内容互不重叠（导出完整性的前提）', () async {
    final writer = buildWriter();
    await writer.open();

    writer.add('flushed');
    await writer.flush();
    writer.add('still-buffered');

    final fileText = readCurrent(writer);
    final pending = writer.pendingLines;

    expect(fileText, 'flushed\n');
    expect(pending, ['still-buffered']);
    expect(fileText.contains(pending.first), isFalse);

    await writer.close();
  });

  test('close 之后 add 不再生效', () async {
    final writer = buildWriter();
    await writer.open();

    writer.add('before');
    await writer.close();

    writer.add('after');
    expect(writer.pendingLineCount, 0);
    expect(readCurrent(writer), 'before\n');
  });

  test('目录不可写时不抛异常（静默降级）', () async {
    // 用一个「父级是文件」的路径，create 必然失败
    final blocker = File(p.join(tempDir.path, 'blocker'));
    blocker.writeAsStringSync('x');
    final writer = LogFileWriter(
      directoryPath: p.join(blocker.path, 'logs'),
      flushInterval: const Duration(hours: 1),
    );

    await expectLater(writer.open(), throwsA(isA<Exception>()));
    // 但 flush 本身不应把异常抛给调用方
    writer.add('line');
    await expectLater(writer.flush(), completes);
  });
}
