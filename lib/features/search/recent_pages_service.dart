import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'private_search_models.dart';

class RecentPage {
  const RecentPage({
    required this.pageId,
    required this.title,
    required this.visitedAt,
  });

  final String pageId;
  final String title;
  final DateTime visitedAt;

  Map<String, dynamic> toJson() => {
        'pageId': pageId,
        'title': title,
        'visitedAt': visitedAt.toIso8601String(),
      };

  factory RecentPage.fromJson(Map<String, dynamic> json) {
    return RecentPage(
      pageId: json['pageId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      visitedAt:
          DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}

class RecentPagesService {
  static const String _key = 'recent_visited_pages';
  static const String _officialRecentHitsKey = 'official_recent_search_hits';
  static const String _privateSearchSeedPageIdKey =
      'private_search_seed_page_id';
  static const int _maxPages = 20;
  static const int _maxOfficialRecentHits = 50;

  static Future<List<RecentPage>> getRecentPages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];

    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) {
        if (e is Map) {
          return RecentPage.fromJson(Map<String, dynamic>.from(e));
        }
        return null;
      }).whereType<RecentPage>().toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> addRecentPage(String pageId, String title) async {
    if (pageId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final pages = await getRecentPages();

    pages.removeWhere((p) => p.pageId == pageId);

    pages.insert(
      0,
      RecentPage(
        pageId: pageId,
        title: title.isEmpty ? '无标题页面' : title,
        visitedAt: DateTime.now(),
      ),
    );

    if (pages.length > _maxPages) {
      pages.removeRange(_maxPages, pages.length);
    }

    await prefs.setString(
      _key,
      jsonEncode(pages.map((p) => p.toJson()).toList()),
    );
  }

  static Future<void> removeRecentPage(String pageId) async {
    if (pageId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final pages = await getRecentPages();
    pages.removeWhere((page) => page.pageId == pageId);
    await prefs.setString(
      _key,
      jsonEncode(pages.map((page) => page.toJson()).toList()),
    );
  }

  static Future<String?> getCachedPrivateSearchSeedPageId() async {
    final prefs = await SharedPreferences.getInstance();
    final pageId = _normalizePageId(
      prefs.getString(_privateSearchSeedPageIdKey) ?? '',
    );
    return pageId.isEmpty ? null : pageId;
  }

  static Future<void> cachePrivateSearchSeedPageId(String pageId) async {
    final normalized = _normalizePageId(pageId);
    if (normalized.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_privateSearchSeedPageIdKey, normalized);
  }

  static Future<List<PrivateSearchHit>> getCachedOfficialRecentHits() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_officialRecentHitsKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) {
        if (e is Map) {
          return PrivateSearchHit.fromJson(Map<String, dynamic>.from(e));
        }
        return null;
      }).whereType<PrivateSearchHit>().where((hit) {
        return hit.pageId.trim().isNotEmpty;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> cacheOfficialRecentHits(
    List<PrivateSearchHit> hits,
  ) async {
    if (hits.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final unique = <String, PrivateSearchHit>{};
    for (final hit in hits) {
      final pageId = hit.pageId.trim();
      if (pageId.isEmpty || unique.containsKey(pageId)) continue;
      unique[pageId] = hit;
      if (unique.length >= _maxOfficialRecentHits) break;
    }
    await prefs.setString(
      _officialRecentHitsKey,
      jsonEncode(unique.values.map((hit) => hit.toJson()).toList()),
    );
  }

  static String _normalizePageId(String rawPageId) {
    final match = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32}',
    ).firstMatch(rawPageId);
    final compact = (match?.group(0) ?? rawPageId)
        .replaceAll('-', '')
        .toLowerCase()
        .trim();
    return RegExp(r'^[0-9a-f]{32}$').hasMatch(compact) ? compact : '';
  }
}
