import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

class RemoteLogConfig {
  const RemoteLogConfig({
    required this.enabled,
    required this.baseUrl,
    required this.username,
    required this.targetPath,
    required this.lastUploadAt,
    required this.lastUploadPath,
  });

  final bool enabled;
  final String baseUrl;
  final String username;
  final String targetPath;
  final String? lastUploadAt;
  final String? lastUploadPath;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      targetPath.trim().isNotEmpty;
}

class RemoteLogUploadResult {
  const RemoteLogUploadResult({
    required this.remotePath,
    required this.bytes,
  });

  final String remotePath;
  final int bytes;
}

class RemoteLogService {
  static const _enabledKey = 'remote_log.enabled';
  static const _baseUrlKey = 'remote_log.base_url';
  static const _usernameKey = 'remote_log.username';
  static const _targetPathKey = 'remote_log.target_path';
  static const _lastUploadAtKey = 'remote_log.last_upload_at';
  static const _lastUploadPathKey = 'remote_log.last_upload_path';
  static const _passwordKey = 'remote_log.password';
  static const _tokenKey = 'remote_log.token';
  static const _installIdKey = 'remote_log.install_id';
  static const _defaultTargetPath = '/notion-app/logs';
  static const _maxSnapshotBytes = 2 * 1024 * 1024;
  static const _alistSalt = 'https://github.com/alist-org/alist';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static Future<RemoteLogConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return RemoteLogConfig(
      enabled: prefs.getBool(_enabledKey) ?? false,
      baseUrl: prefs.getString(_baseUrlKey) ?? '',
      username: prefs.getString(_usernameKey) ?? '',
      targetPath: prefs.getString(_targetPathKey) ?? _defaultTargetPath,
      lastUploadAt: prefs.getString(_lastUploadAtKey),
      lastUploadPath: prefs.getString(_lastUploadPathKey),
    );
  }

  static Future<void> saveConfig({
    required bool enabled,
    required String baseUrl,
    required String username,
    required String password,
    required String targetPath,
  }) async {
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    final normalizedTargetPath = _normalizeTargetPath(targetPath);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setString(_baseUrlKey, normalizedBaseUrl);
    await prefs.setString(_usernameKey, username.trim());
    await prefs.setString(_targetPathKey, normalizedTargetPath);
    if (password.isNotEmpty) {
      await _secureStorage.write(key: _passwordKey, value: password);
      await _secureStorage.delete(key: _tokenKey);
    }
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  static Future<bool> hasPassword() async {
    return (await _secureStorage.read(key: _passwordKey))?.isNotEmpty == true;
  }

  static Future<void> testConnection({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    final effectivePassword = password.isNotEmpty
        ? password
        : await _secureStorage.read(key: _passwordKey) ?? '';
    if (username.trim().isEmpty || effectivePassword.isEmpty) {
      throw const FormatException('请填写 OpenList 用户名和密码');
    }
    await _login(
      baseUrl: normalizedBaseUrl,
      username: username.trim(),
      password: effectivePassword,
    );
  }

  static Future<RemoteLogUploadResult> uploadDiagnosticLog() async {
    final config = await loadConfig();
    if (!config.enabled) {
      throw StateError('远程诊断日志尚未启用');
    }
    if (!config.isConfigured) {
      throw const FormatException('请先完成 OpenList 配置');
    }

    final password = await _secureStorage.read(key: _passwordKey) ?? '';
    var token = await _secureStorage.read(key: _tokenKey) ?? '';
    if (token.isEmpty) {
      if (password.isEmpty) throw StateError('OpenList 密码未保存');
      token = await _login(
        baseUrl: config.baseUrl,
        username: config.username,
        password: password,
      );
      await _secureStorage.write(key: _tokenKey, value: token);
    }

    final snapshot = await _buildRedactedSnapshot();
    final bytes = utf8.encode(snapshot);
    if (bytes.length > _maxSnapshotBytes) {
      throw StateError('脱敏日志超过 2 MB，请先清理本地日志后重试');
    }

    final installId = await _loadInstallId();
    final now = DateTime.now();
    final fileName = 'diagnostic-${_fileTimestamp(now)}.txt';
    final remoteDirectory = '${config.targetPath}/install-$installId';
    final remotePath = '$remoteDirectory/$fileName';

    await _ensureDirectory(config.baseUrl, token, config.targetPath);
    await _ensureDirectory(config.baseUrl, token, remoteDirectory);
    try {
      await _upload(config.baseUrl, token, remotePath, bytes);
    } on _AuthenticationException {
      if (password.isEmpty) rethrow;
      token = await _login(
        baseUrl: config.baseUrl,
        username: config.username,
        password: password,
      );
      await _secureStorage.write(key: _tokenKey, value: token);
      await _upload(config.baseUrl, token, remotePath, bytes);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUploadAtKey, now.toIso8601String());
    await prefs.setString(_lastUploadPathKey, remotePath);
    return RemoteLogUploadResult(remotePath: remotePath, bytes: bytes.length);
  }

  static Future<String> _buildRedactedSnapshot() async {
    final logs = await AppLogger.readLogs();
    final redacted = _redact(logs);
    return [
      'Notion App diagnostic log',
      'Generated: ${DateTime.now().toIso8601String()}',
      'Privacy: redacted snapshot; credentials and personal content removed',
      '',
      redacted,
    ].join('\n');
  }

  static String _redact(String input) {
    var value = input;
    value = value.replaceAll(
      RegExp(
        r'(?i)(authorization|cookie|set-cookie|password|access[_-]?token|token)\s*[:=]\s*[^\s,;]+',
      ),
      r'$1=[REDACTED]',
    );
    value = value.replaceAll(
      RegExp(r'(?i)bearer\s+[a-z0-9._~+/-]+=*'),
      'Bearer [REDACTED]',
    );
    value = value.replaceAll(
      RegExp(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'),
      '[UUID]',
    );
    value = value.replaceAll(
      RegExp(r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', caseSensitive: false),
      '[EMAIL]',
    );
    value = value.replaceAll(
      RegExp(r'https?://[^\s]+'),
      '[URL]',
    );
    value = value.replaceAll(
      RegExp(r'(?i)([a-z]:\\|/storage/|/data/)[^\r\n\s]+'),
      '[LOCAL_PATH]',
    );
    return value;
  }

  static Future<String> _login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final digest = sha256.convert(utf8.encode('$password-$_alistSalt')).toString();
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/auth/login/hash'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'password': digest,
            'otp_code': '',
          }),
        )
        .timeout(const Duration(seconds: 15));
    final payload = _decodeResponse(response);
    final data = payload['data'];
    final token = data is Map ? data['token']?.toString() ?? '' : '';
    if (payload['code'] != 200 || token.isEmpty) {
      throw StateError(payload['message']?.toString() ?? 'OpenList 登录失败');
    }
    return token;
  }

  static Future<void> _ensureDirectory(
    String baseUrl,
    String token,
    String path,
  ) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/api/fs/mkdir'),
          headers: {
            'Authorization': token,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'path': path}),
        )
        .timeout(const Duration(seconds: 15));
    final payload = _decodeResponse(response);
    final code = payload['code'];
    final message = payload['message']?.toString().toLowerCase() ?? '';
    if (code == 401 || response.statusCode == 401) {
      throw const _AuthenticationException();
    }
    if (code != 200 && !message.contains('exist')) {
      throw StateError(payload['message']?.toString() ?? '无法创建远程日志目录');
    }
  }

  static Future<void> _upload(
    String baseUrl,
    String token,
    String remotePath,
    List<int> bytes,
  ) async {
    final response = await http
        .put(
          Uri.parse('$baseUrl/api/fs/put'),
          headers: {
            'Authorization': token,
            'File-Path': Uri.encodeComponent(remotePath),
            'Content-Type': 'application/octet-stream',
            'Content-Length': bytes.length.toString(),
          },
          body: bytes,
        )
        .timeout(const Duration(seconds: 60));
    final payload = _decodeResponse(response);
    if (payload['code'] == 401 || response.statusCode == 401) {
      throw const _AuthenticationException();
    }
    if (payload['code'] != 200) {
      throw StateError(payload['message']?.toString() ?? '上传诊断日志失败');
    }
  }

  static Map<String, dynamic> _decodeResponse(http.Response response) {
    try {
      final value = jsonDecode(response.body);
      if (value is Map) return Map<String, dynamic>.from(value);
    } catch (_) {
      // Fall through to a concise HTTP error without exposing response data.
    }
    throw StateError('OpenList 请求失败（HTTP ${response.statusCode}）');
  }

  static String _normalizeBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('请输入有效的 OpenList 服务地址');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('OpenList 地址只支持 HTTP 或 HTTPS');
    }
    return value.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  static String _normalizeTargetPath(String value) {
    var path = value.trim();
    if (path.isEmpty) path = _defaultTargetPath;
    if (!path.startsWith('/')) path = '/$path';
    path = path.replaceAll(RegExp(r'/+'), '/');
    if (path == '/') throw const FormatException('远程日志不能上传到根目录');
    return path.replaceFirst(RegExp(r'/+$'), '');
  }

  static Future<String> _loadInstallId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final id = List.generate(6, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(_installIdKey, id);
    return id;
  }

  static String _fileTimestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }
}

class _AuthenticationException implements Exception {
  const _AuthenticationException();
}
