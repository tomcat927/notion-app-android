import 'dart:io';

import 'package:flutter/services.dart';

class NativeBrowser {
  static const MethodChannel _channel = MethodChannel('com.notion.app/browser');

  static Future<bool> openPage({
    required String pageId,
    required String title,
  }) async {
    if (!Platform.isAndroid) return false;

    try {
      final opened = await _channel.invokeMethod<bool>('openPage', {
        'pageId': pageId,
        'title': title,
      });
      return opened == true;
    } catch (_) {
      return false;
    }
  }
}
