import 'dart:io';

import 'package:flutter/services.dart';

class NetworkProxy {
  static const MethodChannel _channel = MethodChannel(
    'com.notion.app/proxy',
  );

  static String? _host;
  static String? _port;

  static bool get isEnabled => _host != null && _port != null;

  static String get description {
    if (!isEnabled) return '未检测到系统代理';
    return '$_host:$_port';
  }

  static Future<void> initialize() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getSystemProxy');
      if (result is! Map) return;

      final host = result['host']?.toString();
      final port = result['port']?.toString();
      if (host == null ||
          host.isEmpty ||
          port == null ||
          port == '0') {
        return;
      }

      _host = host;
      _port = port;
      HttpOverrides.global = _ProxiedHttpOverrides(host, port);
    } catch (_) {
      // Devices without system proxy support must continue working directly.
    }
  }
}

class _ProxiedHttpOverrides extends HttpOverrides {
  _ProxiedHttpOverrides(this.host, this.port);

  final String host;
  final String port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => 'PROXY $host:$port';
    return client;
  }
}
