import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotionAuth {
  static const String _tokenKey = 'notion_token';

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  /// token 的不可逆指纹（SHA-256 前 16 位十六进制）。
  ///
  /// 诊断用：跨设备比对两台设备是否配置了同一个凭据，而不把 token 明文写进日志。
  static Future<String> tokenFingerprint() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return 'none';
    return sha256.convert(utf8.encode(token)).toString().substring(0, 16);
  }

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<void> removeToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}
