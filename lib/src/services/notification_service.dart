import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'log_service.dart';

/// 通知服务 - 用于下载完成等系统通知
///
/// Android / iOS 通过 flutter_local_notifications 发出真实系统通知；
/// 其余平台（Windows/macOS/Linux 桌面端）暂无通知能力，仅记录日志兜底。
/// 所有通知相关异常一律吞掉并写日志，绝不影响下载主流程。
class NotificationService {
  static final _log = LogService.instance;
  static NotificationService? _instance;
  static NotificationService get instance => _instance ??= NotificationService._();

  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Android 通知渠道（在系统设置里可见的名字/描述）
  static const String _channelId = 'download_channel';
  static const String _channelName = '下载通知';
  static const String _channelDescription = '下载任务完成通知';

  /// 初始化通知服务
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // 注意：本应用图标是 flutter_launcher_icons 生成的 launcher_icon，
        // 不是 Flutter 模板默认的 ic_launcher，引用错图标会导致通知不显示
        const androidInit = AndroidInitializationSettings('@mipmap/launcher_icon');
        const iosInit = DarwinInitializationSettings();
        const settings = InitializationSettings(
          android: androidInit,
          iOS: iosInit,
        );
        final ok = await _plugin.initialize(settings: settings);
        if (ok != true) {
          _log.error('通知插件初始化失败', tag: 'Notification');
          return;
        }

        // Android 13+ 需要运行时请求 POST_NOTIFICATIONS 权限
        await requestNotificationPermission();

        // Android 8+ 通知渠道需显式创建（重复创建无副作用）
        if (Platform.isAndroid) {
          final android = _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
          await android?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.defaultImportance,
            ),
          );
        }
      }

      _initialized = true;
      _log.info('通知服务初始化完成', tag: 'Notification');
    } catch (e) {
      _log.error('通知服务初始化失败: $e', tag: 'Notification');
    }
  }

  /// 发送下载完成通知
  Future<void> showDownloadCompleteNotification({
    required String title,
    required String body,
  }) async {
    if (!_initialized) {
      _log.warning('通知服务未初始化，跳过通知', tag: 'Notification');
      return;
    }

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        const androidDetails = AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        );
        const iosDetails = DarwinNotificationDetails();
        const details = NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        );

        // 用毫秒时间戳截断成 int32 作为通知 id，避免连续通知互相覆盖
        final id = DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
        );
        _log.info('已发送通知: $title', tag: 'Notification');
      } else {
        // 桌面端暂无通知能力，仅记录日志
        _log.info('通知(桌面端仅记录): $title - $body', tag: 'Notification');
      }
    } catch (e) {
      _log.error('发送通知失败: $e', tag: 'Notification');
    }
  }

  /// 发送批量下载完成通知
  Future<void> showBatchDownloadCompleteNotification({
    required int completedCount,
    required int totalCount,
  }) async {
    const title = '批量下载完成';
    final body = '已完成 $completedCount/$totalCount 个文件';

    await showDownloadCompleteNotification(title: title, body: body);
  }

  /// 请求通知权限（Android 13+ 需要）
  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;

    try {
      final status = await Permission.notification.request();
      final granted = status.isGranted || status.isProvisional;
      if (!granted) {
        _log.warning('通知权限未授予: $status（不影响下载，仅无系统通知）',
            tag: 'Notification');
      }
      return granted;
    } catch (e) {
      _log.error('请求通知权限失败: $e', tag: 'Notification');
      return false;
    }
  }
}
