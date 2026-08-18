import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'storage_service.dart';
import 'log_service.dart';

/// 网络代理配置服务。
///
/// 用于在服务器需要代理才能访问的场景（如 api.asmr-200.com 被墙时），
/// 让 KikoFlu 的 Dio 请求通过 HTTP 代理（如宿主机 Clash 的 7897 端口）访问。
/// 配置格式为 "host:port"，空表示不启用。
class NetworkProxyService {
  static const String proxySettingKey = 'network_proxy';

  static final _log = LogService.instance;

  /// 读取当前代理配置（"host:port" 或空串）。
  static String get proxyConfig =>
      StorageService.getString(proxySettingKey) ?? '';

  /// 保存代理配置。
  static Future<void> setProxyConfig(String config) async {
    await StorageService.setString(proxySettingKey, config.trim());
  }

  /// 解析 "host:port" 配置，返回 (host, port)，无效返回 null。
  static (String, int)? parseProxy(String config) {
    final trimmed = config.trim();
    if (trimmed.isEmpty) return null;
    final idx = trimmed.lastIndexOf(':');
    if (idx <= 0 || idx == trimmed.length - 1) return null;
    final host = trimmed.substring(0, idx).trim();
    final port = int.tryParse(trimmed.substring(idx + 1).trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      return null;
    }
    return (host, port);
  }

  /// 根据已保存的配置为 Dio 实例应用代理；未配置则跳过。
  static void applyProxy(Dio dio) {
    final proxy = parseProxy(proxyConfig);
    if (proxy == null) return;
    applyProxyToDio(dio, proxy.$1, proxy.$2);
  }

  /// 为 Dio 实例应用指定 HTTP 代理。
  static void applyProxyToDio(Dio dio, String host, int port) {
    final adapter = dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      final CreateHttpClient? createClient = adapter.createHttpClient;
      adapter.createHttpClient = () {
        final client = createClient?.call() ?? HttpClient();
        client.findProxy = (uri) => 'PROXY $host:$port';
        // 允许代理环境下的自签名证书，便于私有节点测试
        client.badCertificateCallback = (cert, h, p) => true;
        return client;
      };
      _log.info('已为 Dio 应用代理: $host:$port', tag: 'Proxy');
    } else {
      _log.warning(
        'Dio 未使用 IOHttpClientAdapter，无法应用代理: ${adapter.runtimeType}',
        tag: 'Proxy',
      );
    }
  }
}
