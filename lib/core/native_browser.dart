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

  /// 打开内嵌浏览器并进入「正在创建笔记」加载态。
  ///
  /// 页面此时尚未创建（没有 pageId），先让浏览器就位并预热，
  /// 待后台创建拿到 id 后再调用 [navigatePage] 导航过去。
  static Future<bool> openCreatingPage({required String title}) async {
    if (!Platform.isAndroid) return false;

    try {
      final openExternalInApp = await openExternalLinksInApp();
      final showInspector = await showElementInspector();
      final opened = await _channel.invokeMethod<bool>('openCreatingPage', {
        'title': title,
        'openExternalLinksInApp': openExternalInApp,
        'showElementInspector': showInspector,
      });
      return opened == true;
    } catch (_) {
      return false;
    }
  }

  /// 让已打开的内嵌浏览器导航到目标页面（触发 `BrowserActivity.onNewIntent`）。
  static Future<bool> navigatePage({
    required String pageId,
    required String title,
  }) async {
    if (!Platform.isAndroid) return false;

    try {
      final opened = await _channel.invokeMethod<bool>('navigatePage', {
        'pageId': pageId,
        'title': title,
      });
      return opened == true;
    } catch (_) {
      return false;
    }
  }

  /// 通知内嵌浏览器：后台创建失败，切换为错误提示态。
  static Future<bool> failPendingCreate({required String message}) async {
    if (!Platform.isAndroid) return false;

    try {
      final handled = await _channel.invokeMethod<bool>('failPendingCreate', {
        'message': message,
      });
      return handled == true;
    } catch (_) {
      return false;
    }
  }
}
