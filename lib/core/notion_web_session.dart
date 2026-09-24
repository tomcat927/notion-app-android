import 'dart:convert';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'app_logger.dart';

class NotionWebSession {
  NotionWebSession._();

  static final NotionWebSession instance = NotionWebSession._();

  static const String _channelName = 'com.notion.app/cookie';
  static const MethodChannel _channel = MethodChannel(_channelName);

  static const String _cookieUrl = 'https://www.notion.so';
  static const String _apiBase = 'https://app.notion.com/api/v3';
  static const Duration _requestTimeout = Duration(seconds: 25);

  static const String _storageKeyTokenV2 = 'notion_web_token_v2';
  static const String _storageKeyUserId = 'notion_web_user_id';
  static const String _storageKeySpaceId = 'notion_web_space_id';
  static const String _storageKeyClientVersion = 'notion_web_client_version';

  static const String _defaultClientVersion = '23.13.20260910.2358';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  String? _cachedTokenV2;
  String? _cachedUserId;
  String? _cachedSpaceId;
  String? _cachedClientVersion;
  bool _refreshing = false;
  Completer<void>? _refreshCompleter;

  String? get tokenV2 => _cachedTokenV2;
  String? get userId => _cachedUserId;
  String? get spaceId => _cachedSpaceId;
  String? get clientVersion => _cachedClientVersion ?? _defaultClientVersion;

  bool get isReady {
    final token = _cachedTokenV2;
    final space = _cachedSpaceId;
    final user = _cachedUserId;
    return token != null && token.isNotEmpty &&
        space != null && space.isNotEmpty &&
        user != null && user.isNotEmpty;
  }

  Future<void> loadFromStorage() async {
    _cachedTokenV2 = await _secureStorage.read(key: _storageKeyTokenV2);
    _cachedUserId = await _secureStorage.read(key: _storageKeyUserId);
    _cachedSpaceId = await _secureStorage.read(key: _storageKeySpaceId);
    _cachedClientVersion =
        await _secureStorage.read(key: _storageKeyClientVersion);
    unawaited(AppLogger.log(
      'WebSession',
      'loaded from storage: token=${_cachedTokenV2 != null} '
      'space=${_cachedSpaceId != null} user=${_cachedUserId != null}',
    ));
  }

  Future<bool> refreshFromCookieManager() async {
    if (_refreshing) {
      await _refreshCompleter?.future;
      return isReady;
    }
    _refreshing = true;
    _refreshCompleter = Completer<void>();

    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod('getCookies', {'url': _cookieUrl});
      if (raw == null) {
        unawaited(AppLogger.log('WebSession', 'getCookies returned null'));
        _completeRefresh();
        return false;
      }

      final cookies = <String, String>{};
      for (final entry in raw.entries) {
        final name = entry.key?.toString() ?? '';
        final value = entry.value?.toString() ?? '';
        if (name.isNotEmpty && value.isNotEmpty) {
          cookies[name] = value;
        }
      }

      final tokenV2 = cookies['token_v2'];
      final userId = cookies['notion_user_id'];
      if (tokenV2 == null || tokenV2.isEmpty) {
        unawaited(AppLogger.log(
          'WebSession',
          'token_v2 missing in cookie manager; '
          'available: ${cookies.keys.join(",")}',
        ));
        _completeRefresh();
        return false;
      }

      _cachedTokenV2 = tokenV2;
      _cachedUserId = userId;
      await _secureStorage.write(key: _storageKeyTokenV2, value: tokenV2);
      if (userId != null && userId.isNotEmpty) {
        await _secureStorage.write(key: _storageKeyUserId, value: userId);
      }

      if (_cachedSpaceId == null || _cachedSpaceId!.isEmpty) {
        await _fetchSpaceId();
      }

      unawaited(AppLogger.log(
        'WebSession',
        'refreshed from cookie manager: token=ok '
        'space=${_cachedSpaceId != null} user=${_cachedUserId != null}',
      ));
      _completeRefresh();
      return isReady;
    } catch (error) {
      unawaited(AppLogger.log('WebSession', 'refresh failed: $error'));
      _completeRefresh();
      return false;
    }
  }

  void _completeRefresh() {
    _refreshing = false;
    final completer = _refreshCompleter;
    _refreshCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  Future<void> _fetchSpaceId() async {
    final token = _cachedTokenV2;
    final user = _cachedUserId;
    if (token == null || token.isEmpty) return;

    try {
      final response = await http.post(
        Uri.parse('$_apiBase/getSpaces'),
        headers: _buildHeaders(spaceId: '', userId: user),
        body: jsonEncode({'userId': user ?? ''}),
      ).timeout(_requestTimeout);

      if (response.statusCode != 200) {
        unawaited(AppLogger.log(
          'WebSession',
          'getSpaces failed: ${response.statusCode}',
        ));
        return;
      }

      final parsed = jsonDecode(response.body);
      String? spaceId;
      if (parsed is Map) {
        final userContent = parsed[user] as Map?;
        if (userContent != null) {
          final spaceMap = userContent['space'] as Map?;
          if (spaceMap != null && spaceMap.isNotEmpty) {
            spaceId = spaceMap.keys.first.toString();
          }
        }
        if (spaceId == null || spaceId.isEmpty) {
          final spaces = parsed['space'] as Map?;
          if (spaces != null && spaces.isNotEmpty) {
            spaceId = spaces.keys.first.toString();
          }
        }
      }

      if (spaceId != null && spaceId.isNotEmpty) {
        _cachedSpaceId = spaceId;
        await _secureStorage.write(key: _storageKeySpaceId, value: spaceId);
        unawaited(AppLogger.log('WebSession', 'spaceId resolved: $spaceId'));
      }
    } catch (error) {
      unawaited(AppLogger.log('WebSession', 'fetchSpaceId failed: $error'));
    }
  }

  Map<String, String> _buildHeaders({
    required String? spaceId,
    required String? userId,
  }) {
    return {
      'content-type': 'application/json',
      'cookie': 'token_v2=${_cachedTokenV2 ?? ""}',
      'x-notion-active-user-header': userId ?? '',
      'x-notion-space-id': spaceId ?? '',
      'x-notion-client-version': clientVersion ?? _defaultClientVersion,
    };
  }

  Future<Map<String, dynamic>> search(
    String query, {
    List<Map<String, dynamic>>? boosting,
  }) async {
    return _withAutoRefresh(() => _doSearch(query, boosting));
  }

  Future<Map<String, dynamic>> _doSearch(
    String query,
    List<Map<String, dynamic>>? boosting,
  ) async {
    final body = jsonEncode({
      'type': 'BlocksInSpace',
      'query': query,
      'limit': 20,
      'source': 'quick_find',
      'filters': {
        'isDeletedOnly': false,
        'excludeTemplates': false,
        'navigableBlockContentOnly': false,
        'requireEditPermissions': false,
        'includePublicPagesWithoutExplicitAccess': false,
        'ancestors': [],
        'createdBy': [],
        'editedBy': [],
        'lastEditedTime': {},
        'createdTime': {},
        'inTeams': [],
        'excludeSurrogateCollections': false,
        'excludedParentCollectionIds': [],
      },
      'sort': {'field': 'relevance'},
      'peopleBlocksToInclude': 'all',
      'excludedBlockIds': [],
      'searchSessionFlowNumber': 1,
      'searchSessionId':
          'flutter-${DateTime.now().microsecondsSinceEpoch}',
      'recentPagesForBoosting': boosting ?? const [],
      'spaceId': _cachedSpaceId ?? '',
    });

    final response = await http.post(
      Uri.parse('$_apiBase/search'),
      headers: _buildHeaders(spaceId: _cachedSpaceId, userId: _cachedUserId),
      body: body,
    ).timeout(_requestTimeout);

    return _parseSearchResponse(response);
  }

  Future<Map<String, dynamic>> _parseSearchResponse(
    http.Response response,
  ) async {
    if (response.statusCode == 401 || response.statusCode == 403) {
      return {
        'status': response.statusCode,
        'error': '未授权（cookie 可能已失效）',
        'needsReauth': true,
      };
    }

    try {
      final parsed = jsonDecode(response.body);
      final results = (parsed['results'] as List? ?? const [])
          .map((item) => _mapSearchHit(item as Map<String, dynamic>))
          .toList();
      return {
        'status': response.statusCode,
        'results': results,
      };
    } catch (error) {
      return {
        'status': response.statusCode,
        'error': '响应解析失败: $error',
      };
    }
  }

  Map<String, dynamic> _mapSearchHit(Map<String, dynamic> item) {
    final highlight = (item['highlight'] as Map?) ?? {};
    final highlights = (item['highlights'] as Map?) ?? {};
    final rankingSignals = (item['rankingSignals'] as Map?) ?? {};
    final textHighlights =
        (highlights['textHighlights'] as List? ?? const [])
            .take(4)
            .map((entry) {
              final map = entry as Map?;
              return {
                'text': map?['highlightedText']?.toString() ?? '',
                'blockId': map?['highlightBlockId']?.toString() ?? '',
              };
            })
            .toList();
    return {
      'pageId': item['id']?.toString() ?? '',
      'title': highlight['title']?.toString() ??
          highlights['titleHighlight']?.toString() ??
          rankingSignals['TITLE']?.toString() ??
          '',
      'pathText': highlight['pathText']?.toString() ??
          highlights['pathTextHighlight']?.toString() ??
          rankingSignals['PATH_TEXT']?.toString() ??
          '',
      'type': item['type']?.toString() ?? item['blockType']?.toString() ?? '',
      'snippet': highlight['text']?.toString() ??
          (textHighlights.isNotEmpty ? textHighlights[0]['text'] : '') ??
          '',
      'highlightBlockId': item['highlightBlockId']?.toString() ??
          (textHighlights.isNotEmpty ? textHighlights[0]['blockId'] : '') ??
          '',
      'score': item['score'] ?? 0,
      'snippets': textHighlights,
    };
  }

  Future<Map<String, dynamic>> loadRecentPages() async {
    return _withAutoRefresh(_doLoadRecentPages);
  }

  Future<Map<String, dynamic>> _doLoadRecentPages() async {
    final body = jsonEncode({
      'spaceId': _cachedSpaceId ?? '',
      'limit': 50,
      'beforeTimestamp': DateTime.now().millisecondsSinceEpoch,
    });

    final response = await http.post(
      Uri.parse('$_apiBase/getRecentPageVisits'),
      headers: _buildHeaders(spaceId: _cachedSpaceId, userId: _cachedUserId),
      body: body,
    ).timeout(_requestTimeout);

    if (response.statusCode == 401 || response.statusCode == 403) {
      return {
        'status': response.statusCode,
        'error': '未授权（cookie 可能已失效）',
        'needsReauth': true,
      };
    }

    try {
      final parsed = jsonDecode(response.body);
      final rawPages = _extractPageList(parsed);
      final hits = <Map<String, dynamic>>[];

      for (final page in rawPages.take(20)) {
        final hit = _mapRecentHit(page as Map<String, dynamic>);
        if (hit['pageId']?.toString().isNotEmpty == true) {
          hits.add(hit);
        }
      }

      return {
        'status': response.statusCode,
        'results': hits,
      };
    } catch (error) {
      return {
        'status': response.statusCode,
        'error': '响应解析失败: $error',
      };
    }
  }

  List<dynamic> _extractPageList(dynamic parsed) {
    if (parsed is! Map) return const [];
    final data = parsed['data'];
    if (data is Map) {
      final pages = data['pages'];
      if (pages is List) return pages;
    }
    final pages = parsed['pages'];
    if (pages is List) return pages;
    final results = parsed['results'];
    if (results is List) return results;
    return const [];
  }

  Map<String, dynamic> _mapRecentHit(Map<String, dynamic> item) {
    final rawId = item['pageId']?.toString() ??
        item['id']?.toString() ??
        item['blockId']?.toString() ??
        (item['pointer']?['id']?.toString() ?? '');
    final visitedAt = _toTimestamp(
      item['visitedAt'] ??
          item['timestamp'] ??
          item['lastVisitedAt'] ??
          item['time'],
    );
    return {
      'pageId': rawId,
      'title': item['name']?.toString() ?? item['title']?.toString() ?? '',
      'pathText': '',
      'type': '',
      'snippet': '',
      'highlightBlockId': '',
      'score': visitedAt,
      'snippets': <Map<String, dynamic>>[],
    };
  }

  int _toTimestamp(dynamic value) {
    if (value is int) return value;
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
      final dt = DateTime.tryParse(value);
      if (dt != null) return dt.millisecondsSinceEpoch;
    }
    return 0;
  }

  Future<Map<String, dynamic>> _withAutoRefresh(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    if (!isReady) {
      await refreshFromCookieManager();
    }
    if (!isReady) {
      return {
        'status': 0,
        'error': 'Notion web 会话未就绪（缺少 cookie）',
        'needsReauth': true,
      };
    }

    var result = await action();
    if (result['needsReauth'] == true) {
      unawaited(AppLogger.log(
        'WebSession',
        'needsReauth, attempting cookie refresh',
      ));
      final refreshed = await refreshFromCookieManager();
      if (refreshed) {
        result = await action();
      }
    }
    return result;
  }

  Future<void> clear() async {
    _cachedTokenV2 = null;
    _cachedUserId = null;
    _cachedSpaceId = null;
    _cachedClientVersion = null;
    await _secureStorage.deleteAll();
  }
}
