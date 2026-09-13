import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NativeBrowser {
  static const openExternalLinksInAppPreferenceKey =
      'browser.open_external_links_in_app';
  static const MethodChannel _channel = MethodChannel('com.notion.app/browser');

  static Future<bool> openExternalLinksInApp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(openExternalLinksInAppPreferenceKey) ?? false;
  }

  static Future<void> setOpenExternalLinksInApp(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(openExternalLinksInAppPreferenceKey, value);
  }

  static Future<bool> openPage({
    required String pageId,
    required String title,
  }) async {
    if (!Platform.isAndroid) return false;

    try {
      final openExternalInApp = await openExternalLinksInApp();
      final opened = await _channel.invokeMethod<bool>('openPage', {
        'pageId': pageId,
        'title': title,
        'openExternalLinksInApp': openExternalInApp,
      });
      return opened == true;
    } catch (_) {
      return false;
    }
  }
}
