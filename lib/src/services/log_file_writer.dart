import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 日志的「滚动文件」写入器。
///
/// 设计要点（都是为了「事后可归因」这个目标）：
///
/// - **不常开文件句柄**：每次 flush 用追加模式写一次。避免句柄悬挂，
///   也让「.log 文件已落盘」这件事在任何时刻都成立。
/// - **大小轮转**：`app.log` 超过 [maxFileBytes] 时依次后移
///   （`app.2.log` → `app.3.log` …），最老的被删除，最多保留 [maxFiles] 个文件。
///   这样磁盘占用有硬上限（≈ maxFileBytes × maxFiles）。
/// - **有界缓冲**：写盘失败或目录不可写时，缓冲不会无限增长
///   （[maxBufferedLines] 截断），避免日志本身把内存撑爆。
///
/// 不依赖 Flutter / path_provider，目录由调用方注入，因而可以直接单测。
class LogFileWriter {
  LogFileWriter({
    required this.directoryPath,
    this.baseName = 'app',
    this.maxFileBytes = 2 * 1024 * 1024,
    this.maxFiles = 4,
    this.maxBufferedLines = 5000,
    this.flushInterval = const Duration(milliseconds: 500),
  }) : assert(maxFiles >= 1, '至少保留一个日志文件'),
       assert(maxFileBytes > 0),
       assert(maxBufferedLines > 0);

  /// 日志目录（不存在时由 [open] 创建）。
  final String directoryPath;

  /// 文件名主干，实际文件为 `app.log` / `app.1.log` / …
  final String baseName;

  /// 单个文件的大小上限，超过即轮转。
  final int maxFileBytes;

  /// 最多保留的文件数（含当前文件）。
  final int maxFiles;

  /// 内存缓冲的行数上限。
  final int maxBufferedLines;

  /// 定时 flush 间隔。
  final Duration flushInterval;

  /// 缓冲攒到多少行就立刻 flush。
  static const int _eagerFlushLines = 64;

  final List<String> _buffer = <String>[];
  Timer? _timer;
  bool _closed = false;
  bool _flushing = false;
  bool _writeFailureLogged = false;

  /// 当前正在写的文件：`<dir>/<baseName>.log`
  String get currentFilePath => p.join(directoryPath, '$baseName.log');

  /// 第 [index] 个文件；`0` 是当前文件，`1..` 是依次更老的归档。
  String filePathAt(int index) => index == 0
      ? currentFilePath
      : p.join(directoryPath, '$baseName.$index.log');

  /// 已缓冲但尚未落盘的行数（测试与诊断用）。
  int get pendingLineCount => _buffer.length;

  /// 尚未落盘的行（只读快照）。
  ///
  /// 导出时用「文件全文 + 本列表」就是完整日志：任何时刻的内容
  /// 要么已在文件里，要么还在这里，两者不重叠，因此不会重复输出。
  List<String> get pendingLines => List.unmodifiable(_buffer);

  /// 创建目录并启动定时 flush。
  Future<void> open() async {
    if (_closed) return;
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _timer ??= Timer.periodic(flushInterval, (_) => unawaited(flush()));
  }

  /// 追加一行（同步、非阻塞）。行内的换行会被压平，避免破坏一行的结构。
  void add(String line) {
    if (_closed) return;
    _buffer.add(line.replaceAll('\r', ' ').replaceAll('\n', ' '));
    if (_buffer.length > maxBufferedLines) {
      _buffer.removeRange(0, _buffer.length - maxBufferedLines);
    }
    if (_buffer.length >= _eagerFlushLines) {
      unawaited(flush());
    }
  }

  /// 把缓冲写入磁盘，必要时先轮转。并发调用是安全的（重入直接返回）。
  Future<void> flush() async {
    if (_closed || _flushing || _buffer.isEmpty) return;
    _flushing = true;
    try {
      final chunk = '${_buffer.join('\n')}\n';
      _buffer.clear();
      await _rotateIfNeeded(chunk.length);
      await File(currentFilePath)
          .writeAsString(chunk, mode: FileMode.append, flush: true);
      _writeFailureLogged = false;
    } catch (e) {
      // 磁盘满 / 权限异常等：不能影响主流程，也不能无限重试堆积。
      // 这一批内容丢弃，只在 stderr 提示一次，避免形成日志风暴。
      if (!_writeFailureLogged) {
        _writeFailureLogged = true;
        stderr.writeln('Kikoeru [LogFileWriter] 日志落盘失败: $e');
      }
    } finally {
      _flushing = false;
    }
  }

  /// 停止定时器并把剩余缓冲落盘。
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await flush();
    _closed = true;
  }

  /// 清空缓冲并删除全部日志文件。
  Future<void> clearAll() async {
    _buffer.clear();
    for (var i = 0; i < maxFiles; i++) {
      final f = File(filePathAt(i));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 单个文件删不掉不影响其余文件。
      }
    }
  }

  /// 按「最老 → 最新」顺序读回所有日志文本，供导出/排查使用。
  Future<String> readAll() async {
    final parts = <String>[];
    for (var i = maxFiles - 1; i >= 0; i--) {
      final f = File(filePathAt(i));
      try {
        if (!await f.exists()) continue;
        final text = await f.readAsString();
        if (text.isNotEmpty) parts.add(text);
      } catch (_) {
        // 单个文件读失败就跳过。
      }
    }
    return parts.join();
  }

  Future<void> _rotateIfNeeded(int incomingBytes) async {
    final current = File(currentFilePath);
    final currentSize = await current.exists() ? await current.length() : 0;
    // 空文件（或空目录）不需要轮转：一份超长日志也要能写得下去。
    if (currentSize == 0 || currentSize + incomingBytes <= maxFileBytes) {
      return;
    }

    // 丢掉最老的
    final oldest = File(filePathAt(maxFiles - 1));
    try {
      if (await oldest.exists()) await oldest.delete();
    } catch (_) {}

    // 依次后移：i → i+1
    for (var i = maxFiles - 2; i >= 1; i--) {
      final from = File(filePathAt(i));
      try {
        if (await from.exists()) await from.rename(filePathAt(i + 1));
      } catch (_) {}
    }

    try {
      if (await current.exists()) await current.rename(filePathAt(1));
    } catch (_) {}
  }
}
