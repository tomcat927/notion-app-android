import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class TokenExpiredException implements Exception {
  final String message;
  TokenExpiredException(this.message);

  @override
  String toString() => message;
}

class NotionClient {
  static const String _apiBase = 'https://api.notion.com/v1';

  static Future<Map<String, String>> _headers() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('notion_token');
    if (token == null) throw TokenExpiredException('Notion token not found');

    return {
      'Authorization': 'Bearer $token',
      'Notion-Version': '2022-06-28',
      'Content-Type': 'application/json',
    };
  }

  static Future<http.Response> _handleResponse(http.Response response) async {
    if (response.statusCode == 401) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('notion_token');
      throw TokenExpiredException('Token 已过期或无效，请重新登录');
    }
    return response;
  }

  static Future<http.Response> get(String endpoint) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final response = await http.get(url, headers: await _headers());
    return _handleResponse(response);
  }

  static Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final response = await http.post(url, headers: await _headers(), body: jsonEncode(body));
    return _handleResponse(response);
  }

  static Future<http.Response> patch(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    final response = await http.patch(url, headers: await _headers(), body: jsonEncode(body));
    return _handleResponse(response);
  }
}
