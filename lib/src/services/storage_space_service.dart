import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Windows：GetDiskFreeSpaceExW
// ---------------------------------------------------------------------------
typedef _GetDiskFreeSpaceExWNative = Int32 Function(
  Pointer<Utf16> lpDirectoryName,
  Pointer<Uint64> lpFreeBytesAvailableToCaller,
  Pointer<Uint64> lpTotalNumberOfBytes,
  Pointer<Uint64> lpTotalNumberOfFreeBytes,
);

typedef _GetDiskFreeSpaceExWDart = int Function(
  Pointer<Utf16> lpDirectoryName,
  Pointer<Uint64> lpFreeBytesAvailableToCaller,
  Pointer<Uint64> lpTotalNumberOfBytes,
  Pointer<Uint64> lpTotalNumberOfFreeBytes,
);

// ---------------------------------------------------------------------------
// POSIX：statvfs
// ---------------------------------------------------------------------------
/// `struct statvfs`（LP64 布局，字段全为 8 字节 `unsigned long`）
final class _StatVfs extends Struct {
  @Uint64()
  external int f_bsize;

  @Uint64()
  external int f_frsize;

  @Uint64()
  external int f_blocks;

  @Uint64()
  external int f_bfree;

  @Uint64()
  external int f_bavail;

  @Uint64()
  external int f_files;

  @Uint64()
  external int f_ffree;

  @Uint64()
  external int f_favail;

  @Uint64()
  external int f_fsid;

  @Uint64()
  external int f_flag;

  @Uint64()
  external int f_namemax;
}

typedef _StatVfsNative = Int32 Function(
  Pointer<Utf8> path,
  Pointer<_StatVfs> buf,
);

typedef _StatVfsDart = int Function(
  Pointer<Utf8> path,
  Pointer<_StatVfs> buf,
);

/// 存储空间查询服务
///
/// 使用 dart:ffi 直连平台系统调用获取目标目录所在磁盘的剩余可用空间，
/// 避免为 O1 引入额外原生插件，保证构建零风险、零新增依赖。
///
/// 支持平台：
/// - Windows：`GetDiskFreeSpaceExW`（kernel32.dll，必定已加载）
/// - Android / Linux / macOS / iOS：`statvfs`（libc / libSystem）
///
/// 任一步失败或平台未知时返回 [null]，由调用方决定放行，不影响既有流程。
/// 当前实现按 64 位 LP64 布局解析 `struct statvfs`（现代主流设备均为 LP64）。
class StorageSpaceService {
  StorageSpaceService._();

  static _GetDiskFreeSpaceExWDart? _getDiskFreeSpaceExW;

  /// 获取目标目录所在磁盘的剩余可用字节数；无法获取时返回 [null]。
  static Future<int?> getAvailableBytes(Directory directory) async {
    final path = directory.path;
    try {
      return switch (Platform.operatingSystem) {
        'windows' => _availableBytesWindows(path),
        'android' || 'linux' || 'macos' || 'ios' =>
          _availableBytesPosix(path),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  /// Windows 实现：GetDiskFreeSpaceExW
  static int? _availableBytesWindows(String path) {
    final fn = _getDiskFreeSpaceExW ??= DynamicLibrary.process()
        .lookupFunction<_GetDiskFreeSpaceExWNative, _GetDiskFreeSpaceExWDart>(
      'GetDiskFreeSpaceExW',
    );

    final dir = path.toNativeUtf16();
    final available = calloc<Uint64>();
    final total = calloc<Uint64>();
    final free = calloc<Uint64>();
    try {
      final result = fn(dir, available, total, free);
      return result != 0 ? available.value : null;
    } finally {
      calloc.free(dir);
      calloc.free(available);
      calloc.free(total);
      calloc.free(free);
    }
  }

  /// POSIX 实现：statvfs
  static int? _availableBytesPosix(String path) {
    // 仅支持 64 位布局（LP64）
    if (sizeOf<IntPtr>() != 8) return null;

    final statvfs = _resolveStatVfs();
    if (statvfs == null) return null;

    final cPath = path.toNativeUtf8();
    final buf = calloc<_StatVfs>();
    try {
      final result = statvfs(cPath, buf);
      if (result != 0 || buf.ref.f_frsize <= 0) return null;
      return buf.ref.f_bavail * buf.ref.f_frsize;
    } finally {
      calloc.free(cPath);
      calloc.free(buf);
    }
  }

  /// 解析 `statvfs` 符号，按平台加载对应动态库；失败返回 [null]。
  static _StatVfsDart? _resolveStatVfs() {
    final os = Platform.operatingSystem;
    DynamicLibrary lib;
    try {
      lib = switch (os) {
        'android' => DynamicLibrary.open('libc.so'),
        'linux' => DynamicLibrary.open('libc.so.6'),
        // macOS / iOS：POSIX 符号通常在进程已加载的动态库中
        _ => DynamicLibrary.process(),
      };
    } catch (_) {
      return null;
    }
    try {
      return lib.lookupFunction<_StatVfsNative, _StatVfsDart>('statvfs');
    } catch (_) {
      return null;
    }
  }

  /// 格式化字节数（用于日志与错误提示）
  static String formatBytes(num bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
