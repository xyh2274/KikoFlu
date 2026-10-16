import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'log_file_writer.dart';
import 'log_sanitizer.dart';

enum LogLevel { debug, info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? tag;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.tag,
  });

  String get levelLabel {
    switch (level) {
      case LogLevel.debug:
        return 'D';
      case LogLevel.info:
        return 'I';
      case LogLevel.warning:
        return 'W';
      case LogLevel.error:
        return 'E';
    }
  }

  String format() {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${timestamp.millisecond.toString().padLeft(3, '0')}';
    final tagStr = tag != null ? '[$tag] ' : '';
    return '$time [$levelLabel] $tagStr$message';
  }

  /// 落盘格式：在 [format] 基础上**补上日期**。
  ///
  /// 内存里的 [format] 只显示时分秒（同一次运行内够用），但日志要跨会话
  /// 保留，没有日期就无法判断"这行是昨天的还是刚才的"，回放也还原不出时间。
  String formatForFile() {
    final date = '${timestamp.year.toString().padLeft(4, '0')}-'
        '${timestamp.month.toString().padLeft(2, '0')}-'
        '${timestamp.day.toString().padLeft(2, '0')}';
    return '$date ${format()}';
  }

  /// 落盘行格式：`yyyy-MM-dd HH:mm:ss.SSS [L] [tag] message`
  static final RegExp _fileLinePattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T]'
    r'(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s+'
    r'\[([DIWE])\]\s*'
    r'(?:\[([^\]]+)\]\s*)?'
    r'(.*)$',
  );

  /// 解析 [formatForFile] 产生的一行；不认识的行返回 `null`（跳过即可）。
  static LogEntry? tryParse(String line) {
    final m = _fileLinePattern.firstMatch(line);
    if (m == null) return null;
    try {
      return LogEntry(
        timestamp: DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
          int.parse(m.group(7)!),
        ),
        level: switch (m.group(8)!) {
          'D' => LogLevel.debug,
          'I' => LogLevel.info,
          'W' => LogLevel.warning,
          'E' => LogLevel.error,
          _ => LogLevel.debug,
        },
        tag: m.group(9),
        message: m.group(10) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

class LogService {
  static final LogService _instance = LogService._();
  static LogService get instance => _instance;

  LogService._();

  /// Android 原生日志通道。release 模式下 Flutter engine 不转发
  /// Dart stdout/stderr 到 logcat，必须经 MethodChannel 调用
  /// android.util.Log 才能用 adb logcat 查看应用日志。
  static const MethodChannel _logChannel = MethodChannel(
    'com.meteor.kikoeruflutter/app_logs',
  );

  static const String _logcatTag = 'Kikoeru';

  /// LogLevel -> android.util.Log 常量（DEBUG=3 INFO=4 WARN=5 ERROR=6）
  static int _androidLogLevel(LogLevel level) => switch (level) {
        LogLevel.debug => 3,
        LogLevel.info => 4,
        LogLevel.warning => 5,
        LogLevel.error => 6,
      };

  final List<LogEntry> _logs = [];
  static const int _maxLogs = 5000;
  static const int _maxMessageLength = 500;
  final _controller = StreamController<LogEntry>.broadcast();

  Stream<LogEntry> get logStream => _controller.stream;
  List<LogEntry> get logs => List.unmodifiable(_logs);

  bool _initialized = false;

  /// 滚动落盘的写入器；初始化失败时为 `null`（此后行为退化为纯内存）。
  LogFileWriter? _fileWriter;

  /// 启动时最多回放的历史行数（避免一次读入过大的文件拖慢冷启动）。
  static const int _replayMaxLines = 2000;

  /// 落盘目录（`getApplicationSupportDirectory()/logs`），供诊断展示。
  String? get logDirectoryPath => _fileWriter?.directoryPath;

  /// 初始化日志系统：准备落盘目录、回放上次会话的日志。
  ///
  /// 落盘是**锦上添花**：目录不可写、读回出错都只记一笔到 stderr，
  /// 绝不能因此让应用起不来。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final writer = LogFileWriter(
        directoryPath: p.join(supportDir.path, 'logs'),
      );
      await writer.open();
      _fileWriter = writer;
      await _replayHistory(writer);
    } catch (e) {
      _fileWriter = null;
      stderr.writeln('Kikoeru [LogService] 日志落盘初始化失败，退化为纯内存: $e');
    }
  }

  /// 把上次会话（含更早）的日志尾部读回内存，这样重启后打开日志页
  /// 仍能看到上一次的下载记录，而不是空白一片。
  Future<void> _replayHistory(LogFileWriter writer) async {
    final text = await writer.readAll();
    if (text.isEmpty) return;

    final lines = text
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return;

    final start =
        lines.length > _replayMaxLines ? lines.length - _replayMaxLines : 0;
    final replayed = <LogEntry>[];
    for (var i = start; i < lines.length; i++) {
      final entry = LogEntry.tryParse(lines[i]);
      if (entry != null) replayed.add(entry);
    }
    if (replayed.isEmpty) return;

    _logs.addAll(replayed);
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    // 此处不推 _controller：UI 还没订阅，推了也没人收。
    info(
      '===== 已载入 ${replayed.length} 条历史日志（更早的见 ${writer.currentFilePath}） =====',
      tag: 'Log',
    );
  }

  /// 只在文本真的含敏感键名时才跑正则，避免每条日志都付出正则开销。
  static String _sanitize(String message) {
    if (message.isEmpty) return message;
    final lower = message.toLowerCase();
    for (final key in sensitiveLogKeys) {
      if (lower.contains(key)) return sanitizeLogMessage(message);
    }
    return message;
  }

  /// 落盘当前所有日志（进入后台 / 退出前调用）。
  Future<void> flushLogFile() async {
    await _fileWriter?.flush();
  }

  /// 删除全部落盘的日志文件（内存清空由 [clear] 负责）。
  Future<void> clearPersistedLogs() async {
    await _fileWriter?.clearAll();
  }

  void _addEntry(LogEntry entry) {
    // 先脱敏再截断：日志会落盘、也能被导出分享，凭据不能进文件；
    // 而脱敏会把值收缩成 `***`，先做它再截断能避免把凭据截剩半截。
    final sanitizedMessage = _sanitize(entry.message);
    // 截断过长的消息
    final truncated = sanitizedMessage.length > _maxMessageLength
        ? LogEntry(
            timestamp: entry.timestamp,
            level: entry.level,
            message:
                '${sanitizedMessage.substring(0, _maxMessageLength)}... (截断, 原长${sanitizedMessage.length})',
            tag: entry.tag,
          )
        : LogEntry(
            timestamp: entry.timestamp,
            level: entry.level,
            message: sanitizedMessage,
            tag: entry.tag,
          );
    _logs.add(truncated);
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    _controller.add(truncated);
    // 滚动落盘（同步入缓冲，攒够/到点才真正写盘）。
    _fileWriter?.add(truncated.formatForFile());
    // 输出到平台控制台，便于 adb logcat / 桌面终端排查：
    // - Android：经 MethodChannel 调用 android.util.Log（tag: Kikoeru）。
    //   release 模式下 engine 不转发 Dart stderr，必须走原生日志。
    // - 其他平台：写 stderr（不会经过 print，避免被拦截器循环捕获）。
    if (Platform.isAndroid) {
      _logChannel
          .invokeMethod('writeLog', {
            'level': _androidLogLevel(truncated.level),
            'tag': _logcatTag,
            'message': truncated.format(),
          })
          .catchError((_) {});
    } else {
      stderr.writeln('Kikoeru ${truncated.format()}');
    }
  }

  void debug(String message, {String? tag}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.debug,
      message: message,
      tag: tag,
    );
    _addEntry(entry);
  }

  void info(String message, {String? tag}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      message: message,
      tag: tag,
    );
    _addEntry(entry);
  }

  void warning(String message, {String? tag}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.warning,
      message: message,
      tag: tag,
    );
    _addEntry(entry);
  }

  void error(String message, {String? tag}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.error,
      message: message,
      tag: tag,
    );
    _addEntry(entry);
  }

  /// 捕获 print 输出并记录
  void captureOutput(String line) {
    // 解析已有的标签格式如 [Audio], [FloatingLyric] 等
    String? tag;
    String message = line;
    final tagMatch = RegExp(r'^\[([^\]]+)\]\s*(.*)$').firstMatch(line);
    if (tagMatch != null) {
      tag = tagMatch.group(1);
      message = tagMatch.group(2) ?? line;
    }

    LogLevel level = LogLevel.debug;
    final lower = line.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('exception') ||
        lower.contains('failed')) {
      level = LogLevel.error;
    } else if (lower.contains('warning') || lower.contains('warn')) {
      level = LogLevel.warning;
    }

    _addEntry(LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      tag: tag,
    ));
  }

  void clear() {
    _logs.clear();
  }

  String exportAsText() {
    final buffer = StringBuffer();
    buffer.writeln('=== KikoFlu Logs ===');
    buffer.writeln('Exported: ${DateTime.now().toIso8601String()}');
    buffer.writeln(
        'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    buffer.writeln('Entries: ${_logs.length}');
    buffer.writeln('');
    for (final entry in _logs) {
      buffer.writeln(entry.format());
    }
    return buffer.toString();
  }

  Future<String> exportToFile([String? outputPath]) async {
    final timestamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final fileName = 'kikoflu_log_$timestamp.txt';

    if (outputPath != null) {
      final file = File(outputPath);
      await file.writeAsString(exportAsText());
      return file.path;
    }

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsString(exportAsText());
    return file.path;
  }

  /// 生成默认导出文件名
  String get exportFileName {
    final timestamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    return 'kikoflu_log_$timestamp.txt';
  }

  /// 导出用文本：**以落盘文件为准**。
  ///
  /// 内存只有最近 [_maxLogs] 条，而文件覆盖了更早的会话，所以导出走
  /// 「文件全文 + 尚未落盘的缓冲」—— 任何一条日志要么已在文件里、要么还在
  /// 缓冲里，二者不重叠，因此既完整又不重复。落盘不可用时退回内存快照。
  Future<String> exportCombinedText() async {
    final writer = _fileWriter;
    final buffer = StringBuffer();
    buffer.writeln('=== KikoFlu Logs ===');
    buffer.writeln('Exported: ${DateTime.now().toIso8601String()}');
    buffer.writeln(
        'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    buffer.writeln('Entries(memory): ${_logs.length}');
    if (writer != null) {
      buffer.writeln('LogDir: ${writer.directoryPath}');
    }
    buffer.writeln('');

    if (writer == null) {
      for (final entry in _logs) {
        buffer.writeln(entry.format());
      }
      return buffer.toString();
    }

    final fileContent = await writer.readAll();
    buffer.write(fileContent);
    if (fileContent.isNotEmpty && !fileContent.endsWith('\n')) {
      buffer.writeln();
    }
    for (final line in writer.pendingLines) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }
}

/// 初始化日志系统（含滚动落盘）
Future<void> setupLogCapture() async {
  await LogService.instance.initialize();
}

void logOutput(Object? object) {
  LogService.instance.captureOutput(object.toString());
}
