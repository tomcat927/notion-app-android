import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

class NotionClient {
  static const String _apiBase = 'https://api.notion.com/v1';
  static const Duration _requestTimeout = Duration(seconds: 30);
  static const int _maxRateLimitRetries = 3;
  static const int _maxHandshakeRetries = 3;
  static const int _initialHandshakeRetryDelayMs = 500;

  static Future<Map<String, String>> _headers() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('notion_token');
    if (token == null) throw Exception('Notion token not found');

    return {
      'Authorization': 'Bearer $token',
      'Notion-Version': '2022-06-28',
      'Content-Type': 'application/json',
    };
  }

  static Future<http.Response> get(String endpoint) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final headers = await _headers();
    return _withRetry(
      () => http.get(url, headers: headers),
      url: url,
    );
  }

  static Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final headers = await _headers();
    final encodedBody = jsonEncode(body);
    return _withRetry(
      () => http.post(url, headers: headers, body: encodedBody),
      url: url,
    );
  }

  static Future<http.Response> patch(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final headers = await _headers();
    final encodedBody = jsonEncode(body);
    return _withRetry(
      () => http.patch(url, headers: headers, body: encodedBody),
      url: url,
    );
  }

  static Future<http.Response> _withRetry(
    Future<http.Response> Function() request, {
    required Uri url,
  }) async {
    var rateLimitRetries = 0;
    var handshakeRetries = 0;

    while (true) {
      try {
        final response = await request().timeout(_requestTimeout);
        if (response.statusCode != 429 ||
            rateLimitRetries >= _maxRateLimitRetries) {
          return response;
        }

        final retryAfter =
            double.tryParse(response.headers['retry-after'] ?? '') ??
                (rateLimitRetries + 1).toDouble();
        rateLimitRetries++;
        await Future<void>.delayed(
          Duration(milliseconds: (retryAfter * 1000).ceil()),
        );
      } on HandshakeException catch (error) {
        // A failed TLS handshake happens before the HTTP request is sent, so
        // retrying PATCH requests here cannot duplicate an accepted write.
        if (handshakeRetries >= _maxHandshakeRetries) {
          throw NotionConnectionException(
            host: url.host,
            attempts: handshakeRetries + 1,
            cause: error,
          );
        }

        final delay = Duration(
          milliseconds:
              _initialHandshakeRetryDelayMs * (1 << handshakeRetries),
        );
        handshakeRetries++;
        await _logRetry(
          '${url.host} TLS 握手失败，${delay.inMilliseconds}ms 后进行第 '
          '${handshakeRetries + 1} 次连接: $error',
        );
        await Future<void>.delayed(delay);
      }
    }
  }

  static Future<void> _logRetry(String message) async {
    try {
      await AppLogger.log('HTTP', message);
    } catch (_) {
      // Diagnostics must not interrupt a network retry.
    }
  }

  static void ensureSuccess(
    http.Response response, {
    required String operation,
    Set<int> successStatusCodes = const {200},
  }) {
    if (successStatusCodes.contains(response.statusCode)) return;

    var detail = response.body.trim();
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['message'] != null) {
        detail = data['message'].toString();
      }
    } catch (_) {
      // Keep the response body when Notion returns a non-JSON error.
    }

    if (detail.length > 300) {
      detail = '${detail.substring(0, 300)}...';
    }
    throw NotionApiException(
      operation: operation,
      statusCode: response.statusCode,
      detail: detail,
    );
  }
}

class NotionConnectionException implements Exception {
  final String host;
  final int attempts;
  final Object cause;

  const NotionConnectionException({
    required this.host,
    required this.attempts,
    required this.cause,
  });

  @override
  String toString() {
    return '无法与 $host 建立安全连接，已尝试 $attempts 次。'
        '请切换 Wi-Fi/移动网络，并确认代理或 VPN 对此 App 生效。'
        '原始错误: $cause';
  }
}

class NotionApiException implements Exception {
  final String operation;
  final int statusCode;
  final String detail;

  const NotionApiException({
    required this.operation,
    required this.statusCode,
    required this.detail,
  });

  @override
  String toString() {
    final suffix = detail.isEmpty ? '' : ': $detail';
    return '$operation失败（HTTP $statusCode）$suffix';
  }
}
