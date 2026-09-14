import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

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

  /// 初始化日志系统，拦截 print 输出
  void initialize() {
    if (_initialized) return;
    _initialized = true;
  }

  void _addEntry(LogEntry entry) {
    // 截断过长的消息
    final truncated = entry.message.length > _maxMessageLength
        ? LogEntry(
            timestamp: entry.timestamp,
            level: entry.level,
            message:
                '${entry.message.substring(0, _maxMessageLength)}... (截断, 原长${entry.message.length})',
            tag: entry.tag,
          )
        : entry;
    _logs.add(truncated);
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    _controller.add(truncated);
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
}

/// 初始化日志系统
void setupLogCapture() {
  LogService.instance.initialize();
}

void logOutput(Object? object) {
  LogService.instance.captureOutput(object.toString());
}
