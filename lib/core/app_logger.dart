import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLogger {
  static const String _debugKey = 'debug_log_enabled';
  static bool _enabled = false;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_debugKey) ?? false;
  }

  static bool get isEnabled => _enabled;

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_debugKey, value);
  }

  static Future<void> log(String tag, String message) async {
    if (!_enabled) return;

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/notion_app_debug.log');

    final timestamp = DateTime.now().toIso8601String();
    final entry = '[$timestamp] [$tag] $message\n';

    await file.writeAsString(entry, mode: FileMode.append);
  }

  static Future<void> clearLogs() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/notion_app_debug.log');
    if (await file.exists()) {
      await file.delete();
    }
  }

  static Future<String> readLogs() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/notion_app_debug.log');
    if (!await file.exists()) return '暂无日志';
    final content = await file.readAsString();
    if (content.isEmpty) return '暂无日志';
    return content;
  }
}
