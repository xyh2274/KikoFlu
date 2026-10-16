import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/log_service.dart';

/// 落盘格式与回放解析必须互逆，否则「重启后回放历史日志」会丢内容。
void main() {
  test('formatForFile / tryParse 互为逆运算（含 tag）', () {
    final entry = LogEntry(
      timestamp: DateTime(2026, 10, 16, 21, 3, 11, 123),
      level: LogLevel.error,
      message: '网页下载失败: SocketException',
      tag: 'Download',
    );

    final line = entry.formatForFile();
    expect(line, '2026-10-16 21:03:11.123 [E] [Download] 网页下载失败: SocketException');

    final back = LogEntry.tryParse(line);
    expect(back, isNotNull);
    expect(back!.timestamp, entry.timestamp);
    expect(back.level, LogLevel.error);
    expect(back.tag, 'Download');
    expect(back.message, entry.message);
  });

  test('无 tag 时也能往返', () {
    final entry = LogEntry(
      timestamp: DateTime(2026, 1, 2, 3, 4, 5, 6),
      level: LogLevel.debug,
      message: 'plain message',
    );

    final back = LogEntry.tryParse(entry.formatForFile());
    expect(back, isNotNull);
    expect(back!.timestamp, entry.timestamp);
    expect(back.level, LogLevel.debug);
    expect(back.tag, isNull);
    expect(back.message, 'plain message');
  });

  test('四种级别标签全部可还原', () {
    const expected = {
      LogLevel.debug: 'D',
      LogLevel.info: 'I',
      LogLevel.warning: 'W',
      LogLevel.error: 'E',
    };
    expected.forEach((level, label) {
      final entry = LogEntry(
        timestamp: DateTime(2026, 5, 6, 7, 8, 9, 10),
        level: level,
        message: 'm',
      );
      expect(entry.formatForFile(), contains('[$label]'));
      expect(LogEntry.tryParse(entry.formatForFile())!.level, level);
    });
  });

  test('format 只有时分秒，formatForFile 额外带日期', () {
    final entry = LogEntry(
      timestamp: DateTime(2026, 10, 16, 21, 3, 11, 123),
      level: LogLevel.info,
      message: 'x',
      tag: 'T',
    );
    expect(entry.format(), '21:03:11.123 [I] [T] x');
    expect(entry.formatForFile(), '2026-10-16 21:03:11.123 [I] [T] x');
  });

  test('message 自身带方括号时内容不丢（tag 会被误判，信息等价）', () {
    final entry = LogEntry(
      timestamp: DateTime(2026, 10, 16, 21, 3, 11, 123),
      level: LogLevel.info,
      message: '[Audio] 初始化完成 [1/3]',
    );
    final back = LogEntry.tryParse(entry.formatForFile());
    expect(back, isNotNull);
    // 原文完整保留在 message 里（或部分前移为 tag），关键是后半段没丢
    expect('${back!.tag ?? ''}${back.message}', contains('[1/3]'));
    expect('${back.tag ?? ''}${back.message}', contains('初始化完成'));
  });

  test('不认识的行返回 null，不会污染回放', () {
    expect(LogEntry.tryParse(''), isNull);
    expect(LogEntry.tryParse('随便一行文本'), isNull);
    expect(LogEntry.tryParse('2026-10-16 21:03:11 [I] 缺毫秒'), isNull);
    expect(LogEntry.tryParse('2026-10-16 21:03:11.123 [X] 非法级别'), isNull);
  });
}
