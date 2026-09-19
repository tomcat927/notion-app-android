import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLogger {
  static const MethodChannel _crashLogChannel = MethodChannel(
    'com.notion.app/crash_logs',
  );
  static const String _debugKey = 'debug_log_enabled';
  static const String _layoutDebugKey = 'layout_debug_log_enabled';
  static bool _enabled = false;
  static bool _layoutEnabled = false;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_debugKey) ?? false;
    _layoutEnabled = prefs.getBool(_layoutDebugKey) ?? false;
  }

  static bool get isEnabled => _enabled;
  static bool get isLayoutDebugEnabled => _layoutEnabled;

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_debugKey, value);
  }

  static Future<void> setLayoutDebugEnabled(bool value) async {
    _layoutEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_layoutDebugKey, value);
  }

  static Future<void> log(String tag, String message) async {
    if (!_enabled) return;

    await _write(tag, message);
  }

  static Future<void> logLayout(String message) async {
    if (!_enabled || !_layoutEnabled) return;

    await _write('Layout', message);
  }

  static Future<void> logBreadcrumb(String tag, String message) async {
    try {
      await _write('Breadcrumb/$tag', message);
    } catch (_) {
      // Breadcrumb logging must never affect app behavior.
    }
  }

  static Future<void> logCrash(
    String source,
    Object error, [
    StackTrace? stackTrace,
  ]) async {
    final buffer = StringBuffer()
      ..writeln(source)
      ..writeln(error);
    if (stackTrace != null) {
      buffer
        ..writeln('--- stack ---')
        ..writeln(stackTrace);
    }

    try {
      await _write('Crash', buffer.toString().trimRight());
    } catch (_) {
      // Crash logging must never crash the app again.
    }
  }

  static Future<void> _write(String tag, String message) async {
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
    try {
      await _crashLogChannel.invokeMethod<void>('clearNativeCrashLog');
    } catch (_) {
      // Native crash log channel is best-effort.
    }
  }

  static Future<String> readLogs() async {
    final sections = <String>[];
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/notion_app_debug.log');
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) sections.add(content.trimRight());
      }
    } catch (error) {
      sections.add('--- Flutter 调试日志读取失败 ---\n$error');
    }

    final nativeLogs = await _readNativeCrashLogs();
    if (nativeLogs.isNotEmpty) {
      sections.add('--- 原生/系统崩溃日志 ---\n$nativeLogs');
    }

    if (sections.isEmpty) return '暂无日志';
    return sections.join('\n\n');
  }

  static Future<String> _readNativeCrashLogs() async {
    try {
      final logs = await _crashLogChannel.invokeMethod<String>(
        'readNativeCrashLog',
      );
      return logs?.trimRight() ?? '';
    } catch (_) {
      return '';
    }
  }
}
