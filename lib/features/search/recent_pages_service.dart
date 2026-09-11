import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const int _maxPages = 20;

  static Future<List<RecentPage>> getRecentPages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];

    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => RecentPage.fromJson(e as Map<String, dynamic>))
          .toList();
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

    await prefs.setString(_key, jsonEncode(pages.map((p) => p.toJson()).toList()));
  }
}
