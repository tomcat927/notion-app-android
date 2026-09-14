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

  static Future<bool> openPage({
    required String pageId,
    required String title,
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
      });
      return opened == true;
    } catch (_) {
      return false;
    }
  }
}
