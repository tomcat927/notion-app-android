import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class NotionClient {
  static const String _apiBase = 'https://api.notion.com/v1';
  static const Duration _requestTimeout = Duration(seconds: 30);
  static const int _maxRateLimitRetries = 3;

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
    return _withRateLimitRetry(() => http.get(url, headers: headers));
  }

  static Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final headers = await _headers();
    final encodedBody = jsonEncode(body);
    return _withRateLimitRetry(
      () => http.post(url, headers: headers, body: encodedBody),
    );
  }

  static Future<http.Response> patch(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final headers = await _headers();
    final encodedBody = jsonEncode(body);
    return _withRateLimitRetry(
      () => http.patch(url, headers: headers, body: encodedBody),
    );
  }

  static Future<http.Response> _withRateLimitRetry(
    Future<http.Response> Function() request,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final response = await request().timeout(_requestTimeout);
      if (response.statusCode != 429 || attempt >= _maxRateLimitRetries) {
        return response;
      }

      final retryAfter =
          double.tryParse(response.headers['retry-after'] ?? '') ??
              (attempt + 1).toDouble();
      await Future<void>.delayed(
        Duration(milliseconds: (retryAfter * 1000).ceil()),
      );
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
