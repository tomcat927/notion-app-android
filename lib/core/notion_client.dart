import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class NotionClient {
  static const String _apiBase = 'https://api.notion.com/v1';

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
    return http.get(url, headers: await _headers());
  }

  static Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    return http.post(url, headers: await _headers(), body: jsonEncode(body));
  }

  static Future<http.Response> patch(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$_apiBase$endpoint');
    return http.patch(url, headers: await _headers(), body: jsonEncode(body));
  }
}
