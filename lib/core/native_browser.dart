import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NativeBrowser {
  static const openExternalLinksInAppPreferenceKey =
      'browser.open_external_links_in_app';
  static const showElementInspectorPreferenceKey =
      'browser.show_element_inspector';
  static const MethodChannel _channel = MethodChannel('com.notion.app/browser');

  static Future<bool> openExternalLinksInApp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(openExternalLinksInAppPreferenceKey) ?? false;
  }

  static Future<void> setOpenExternalLinksInApp(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(openExternalLinksInAppPreferenceKey, value);
  }

  static Future<bool> showElementInspector() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(showElementInspectorPreferenceKey) ?? false;
  }

  static Future<void> setShowElementInspector(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(showElementInspectorPreferenceKey, value);
  }

  static Future<void> prewarmWebView() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('prewarm');
    } catch (_) {}
  }

  /// 通知原生清空内嵌浏览器的历史栈，使后续返回直接退出而不是 goBack。
  ///
  /// 用于「笔记被删除」场景：SPA 会在删除后自动 pushState 到列表视图，历史栈里
  /// 仍留着那篇已删笔记，导致返回时钻回已删页面（见 BrowserWebViewHolder.resetHistoryToCurrent）。
  static Future<void> resetPageHistory() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('resetPageHistory');
    } catch (_) {}
  }

  static Future<bool> openPage({
   required String pageId,
   required String title,
    String? blockId,
    String? snippet,
 }) async {
   if (!Platform.isAndroid) return false;

   try {
     final openExternalInApp = await openExternalLinksInApp();
     final showInspector = await showElementInspector();
     final opened = await _channel.invokeMethod<bool>('openPage', {
       'pageId': pageId,
       'title': title,
       'openExternalLinksInApp': openExternalInApp,
       'showElementInspector': showInspector,
        'blockId': blockId ?? '',
        'snippet': snippet ?? '',
     });
     return opened == true;
    } catch (_) {
      return false;
    }
  }
}
