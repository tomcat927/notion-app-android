import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 页面 block 数据的本地缓存，实现「先读缓存秒开，后台再同步」模式。
///
/// 数据存储在 SharedPreferences 中，格式为 JSON：
/// {"title": "...", "blocks": [...], "cachedAt": "..."}
/// 每个 block 是精简格式：{id, type, depth, text, checked, hasFormatting, displayText}
class CachedPageData {
  const CachedPageData({
    required this.title,
    required this.blocks,
    required this.cachedAt,
  });

  final String title;
  final List<Map<String, dynamic>> blocks;
  final DateTime cachedAt;

  bool get isStale {
    final age = DateTime.now().difference(cachedAt);
    return age.inHours > 24;
  }
}

class PageCacheService {
  static const String _prefix = 'page_cache_';
  static const String _indexKey = 'page_cache_index';
  static const int _maxCachedPages = 50;

  static Future<void> cachePage(
    String pageId,
    String title,
    List<Map<String, dynamic>> blocks,
  ) async {
    if (pageId.isEmpty || blocks.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'title': title,
      'blocks': blocks,
      'cachedAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('$_prefix$pageId', payload);
    await _addToIndex(pageId);
  }

  static Future<CachedPageData?> getCachedPage(String pageId) async {
    if (pageId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$pageId');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final blocks = (decoded['blocks'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      return CachedPageData(
        title: decoded['title']?.toString() ?? '',
        blocks: (decoded['blocks'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList(),
        cachedAt: DateTime.tryParse(decoded['cachedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> hasCache(String pageId) async {
    if (pageId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_prefix$pageId');
  }

  static Future<void> clearCache(String pageId) async {
    if (pageId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$pageId');
    await _removeFromIndex(pageId);
  }

  static Future<void> clearAllCache() async {
    final prefs = await SharedPreferences.getInstance();
    final index = await _getIndex();
    for (final pageId in index) {
      await prefs.remove('$_prefix$pageId');
    }
    await prefs.remove(_indexKey);
  }

  static Future<List<String>> _getIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _addToIndex(String pageId) async {
    final index = await _getIndex();
    index.remove(pageId);
    index.insert(0, pageId);
    while (index.length > _maxCachedPages) {
      final evicted = index.removeLast();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$evicted');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_indexKey, jsonEncode(index));
  }

  static Future<void> _removeFromIndex(String pageId) async {
    final index = await _getIndex();
    index.remove(pageId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_indexKey, jsonEncode(index));
  }
}
