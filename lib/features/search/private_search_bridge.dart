import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_logger.dart';
import 'recent_pages_service.dart';

class NotionPrivateSearchBridge extends ChangeNotifier {
  NotionPrivateSearchBridge._();

  static final NotionPrivateSearchBridge instance =
      NotionPrivateSearchBridge._();

  static const String _searchUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/152.0.0.0 Mobile Safari/537.36';

  WebViewController? _controller;
  final Map<String, Completer<String>> _searchCompleters = {};
  int _probeRetryCount = 0;
  int _searchToken = 0;
  bool _started = false;
  bool _ready = false;
  String _status = '正在连接 Notion';
  String? _url;

  bool get hasController => _controller != null;
  bool get isReady => _ready;
  String get status => _status;
  String? get url => _url;

  void start({String? seedPageId}) {
    if (_started) return;

    _started = true;
    _ready = false;
    _probeRetryCount = 0;
    _status = '正在连接 Notion';
    final seedId = seedPageId?.trim().replaceAll('-', '') ?? '';
    final initialUrl = seedId.isEmpty
        ? 'https://www.notion.so/'
        : 'https://www.notion.so/$seedId';
    unawaited(AppLogger.log('PrivateSearch', 'bridge start: $initialUrl'));
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_searchUserAgent)
      ..addJavaScriptChannel(
        'NotionPrivateSearchBridge',
        onMessageReceived: _handleBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _url = url;
            _ready = false;
            _status = '正在加载 Notion 页面';
            notifyListeners();
            unawaited(AppLogger.log('PrivateSearch', 'page started: $url'));
          },
          onPageFinished: (_) => unawaited(_probeBridge()),
          onUrlChange: (change) {
            final url = change.url ?? '';
            if (url.isEmpty) return;
            final uri = Uri.tryParse(url);
            final isLogin = uri != null &&
                (uri.pathSegments.contains('login') ||
                    uri.path.contains('/login'));
            _url = url;
            _status = isLogin ? '需要登录 Notion' : '正在连接 Notion';
            notifyListeners();
            unawaited(AppLogger.log('PrivateSearch', 'url changed: $url'));
          },
          onHttpError: (error) {
            final statusCode = error.response?.statusCode;
            final requestUrl = error.request?.uri.toString() ?? '未知请求';
            if (statusCode == null) return;
            unawaited(
              AppLogger.log(
                'PrivateSearch',
                'http error: $statusCode url=$requestUrl',
              ),
            );
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true) return;
            _ready = false;
            _status = 'Notion 页面加载失败：${error.description}';
            notifyListeners();
            unawaited(
              AppLogger.log('PrivateSearch', 'web error: ${error.description}'),
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));
    notifyListeners();
  }

  Widget buildHiddenWebView() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();

    return Offstage(
      offstage: true,
      child: SizedBox(
        width: 1,
        height: 1,
        child: WebViewWidget(controller: controller),
      ),
    );
  }

  void reload() {
    final controller = _controller;
    if (controller == null) return;

    _ready = false;
    _probeRetryCount = 0;
    _status = '正在重新连接 Notion';
    notifyListeners();
    controller.reload();
  }

  void reset() {
    _started = false;
    _ready = false;
    _controller = null;
    _url = null;
    _status = '正在连接 Notion';
    _probeRetryCount = 0;
    for (final completer in _searchCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('搜索桥接已重置'));
      }
    }
    _searchCompleters.clear();
    notifyListeners();
  }

  Future<String> search(String query) async {
    final controller = _controller;
    if (controller == null || !_ready) {
      throw StateError('Notion 会话未就绪');
    }

    final recentPages = await RecentPagesService.getRecentPages();
    final boosting = recentPages
        .map((p) => {
              'visitedAt': p.visitedAt.millisecondsSinceEpoch,
              'pageId': p.pageId,
            })
        .toList();

    _searchToken++;
    final requestId =
        'search-${DateTime.now().microsecondsSinceEpoch}-$_searchToken';
    final completer = Completer<String>();
    _searchCompleters[requestId] = completer;
    const searchUserAgent = _searchUserAgent;
    final payload = {
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
      'searchSessionId': 'flutter-${DateTime.now().microsecondsSinceEpoch}',
      'recentPagesForBoosting': boosting,
    };

    final script = '''
(() => {
  const requestId = '$requestId';
  const payload = ${jsonEncode(payload)};
  function post(value) {
    window.NotionPrivateSearchBridge.postMessage(JSON.stringify(value));
  }
  const boot = window.__notion_boot_data || {};
  const html = document.documentElement?.outerHTML || '';
  const spaceMatch = html.match(/"spaceId":"([0-9a-f-]{36})"/i);
  const userMatch = html.match(/"userId":"([0-9a-f-]{36})"/i);
  const spaceId = boot.spaceId || spaceMatch?.[1] || '';
  const userId = boot.userId || userMatch?.[1] || '';
  const notionVersion =
    document.documentElement?.getAttribute('data-notion-version') ||
    boot.version ||
    '23.13.20260910.2358';
  if (!spaceId) {
    post({requestId, error: '未读取到当前工作区 ID'});
    return;
  }
  payload.spaceId = spaceId;
  fetch('https://app.notion.com/api/v3/search', {
    method: 'POST',
    credentials: 'include',
    headers: {
      'content-type': 'application/json',
      'x-notion-active-user-header': userId,
      'x-notion-space-id': spaceId,
      'x-notion-client-version': notionVersion,
      'user-agent': '$searchUserAgent'
    },
    body: JSON.stringify(payload)
  }).then(async response => {
    const bodyText = await response.text();
    let result;
    try {
      const parsed = JSON.parse(bodyText);
      const hits = (parsed.results || []).map(item => {
        const highlight = item.highlight || {};
        const highlights = item.highlights || {};
        const rankingSignals = item.rankingSignals || {};
        const snippets = (highlights.textHighlights || []).slice(0, 4).map(
          entry => ({
            text: entry.highlightedText || '',
            blockId: entry.highlightBlockId || ''
          })
        );
        return {
          pageId: item.id || '',
          title: highlight.title || highlights.titleHighlight || rankingSignals.TITLE || '',
          pathText: highlight.pathText || highlights.pathTextHighlight || rankingSignals.PATH_TEXT || '',
          snippet: highlight.text || snippets[0]?.text || '',
          highlightBlockId:
            item.highlightBlockId || snippets[0]?.blockId || '',
          score: item.score || 0,
          snippets
        };
      });
      result = {requestId, status: response.status, results: hits};
    } catch (error) {
      result = {requestId, status: response.status, error: '响应解析失败'};
    }
    post(result);
  }).catch(error => {
    post({requestId, error: String(error)});
  });
})();
''';

    try {
      unawaited(AppLogger.log('PrivateSearch', 'search request: $requestId'));
      await controller.runJavaScript(script);
      return await completer.future.timeout(const Duration(seconds: 25));
    } catch (_) {
      _searchCompleters.remove(requestId);
      rethrow;
    }
  }

  /// Loads server-side recently visited pages via Notion's internal API.
  Future<String> loadRecentPages() async {
    final controller = _controller;
    if (controller == null || !_ready) {
      throw StateError('Notion 会话未就绪');
    }

    _searchToken++;
    final requestId =
        'recents-${DateTime.now().microsecondsSinceEpoch}-$_searchToken';
    final completer = Completer<String>();
    _searchCompleters[requestId] = completer;
    const searchUserAgent = _searchUserAgent;

    final script = '''
(() => {
  const requestId = '$requestId';
  function post(value) {
    window.NotionPrivateSearchBridge.postMessage(JSON.stringify(value));
  }
  const boot = window.__notion_boot_data || {};
  const html = document.documentElement?.outerHTML || '';
  const spaceMatch = html.match(/"spaceId":"([0-9a-f-]{36})"/i);
  const userMatch = html.match(/"userId":"([0-9a-f-]{36})"/i);
  const spaceId = boot.spaceId || spaceMatch?.[1] || '';
  const userId = boot.userId || userMatch?.[1] || '';
  const notionVersion =
    document.documentElement?.getAttribute('data-notion-version') ||
    boot.version ||
    '23.13.20260910.2358';
  if (!spaceId) {
    post({requestId, error: '未读取到当前工作区 ID'});
    return;
  }

  const normalizePageId = id => {
    const text = String(id || '');
    const match = text.match(
      /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32}/i
    );
    const compact = (match?.[0] || text).replace(/-/g, '').toLowerCase();
    return compact.length === 32 && !/[^0-9a-f]/.test(compact) ? compact : '';
  };
  const hyphenatePageId = id => {
    const compact = normalizePageId(id);
    if (!compact) return String(id || '');
    return compact.substring(0, 8) + '-' +
      compact.substring(8, 12) + '-' +
      compact.substring(12, 16) + '-' +
      compact.substring(16, 20) + '-' +
      compact.substring(20);
  };
  const toTimestamp = value => {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string') {
      const numberValue = Number(value);
      if (Number.isFinite(numberValue)) return numberValue;
      const parsed = Date.parse(value);
      if (Number.isFinite(parsed)) return parsed;
    }
    return 0;
  };
  const currentPath = window.location.pathname || '';
  const currentMatches = currentPath.match(
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32}/ig
  ) || [];
  const currentPageKey = normalizePageId(
    currentMatches.length > 0 ? currentMatches[currentMatches.length - 1] : ''
  );

  fetch('https://app.notion.com/api/v3/getRecentPageVisits', {
    method: 'POST',
    credentials: 'include',
    headers: {
      'content-type': 'application/json',
      'x-notion-active-user-header': userId,
      'x-notion-space-id': spaceId,
      'x-notion-client-version': notionVersion,
      'user-agent': '$searchUserAgent'
    },
    body: JSON.stringify({
      spaceId: spaceId,
      limit: 50,
      beforeTimestamp: Date.now()
    })
  }).then(async response => {
    const bodyText = await response.text();
    let result;
    try {
      const parsed = JSON.parse(bodyText);
      const rawPages = Array.isArray(parsed?.data?.pages)
        ? parsed.data.pages
        : Array.isArray(parsed?.pages)
          ? parsed.pages
          : Array.isArray(parsed?.results)
            ? parsed.results
            : [];
      const recordMap = new Map();
      rawPages.forEach(item => {
        const rawId = item?.pageId || item?.id || item?.blockId ||
          item?.pointer?.id || item?.value?.id || '';
        const key = normalizePageId(rawId);
        if (!key) return;
        const visitedAt = toTimestamp(
          item?.visitedAt ?? item?.timestamp ?? item?.lastVisitedAt ?? item?.time
        );
        const pageId = hyphenatePageId(rawId);
        const existing = recordMap.get(key);
        if (!existing || visitedAt > existing.visitedAt) {
          recordMap.set(key, {pageId, visitedAt, raw: item});
        }
      });
      const records = Array.from(recordMap.values()).sort((a, b) =>
        b.visitedAt - a.visitedAt || a.pageId.localeCompare(b.pageId)
      );
      const candidateRecords = records.slice(0, 30);
      let syncStatus = 0;
      let syncBodyText = '';
      let syncError = '';
      let blockMap = {};
      if (candidateRecords.length > 0) {
        try {
          const syncResponse = await fetch(
            'https://app.notion.com/api/v3/syncRecordValues',
            {
              method: 'POST',
              credentials: 'include',
              headers: {
                'content-type': 'application/json',
                'x-notion-active-user-header': userId,
                'x-notion-space-id': spaceId,
                'x-notion-client-version': notionVersion
              },
              body: JSON.stringify({
                requests: candidateRecords.map(item => ({
                  pointer: {
                    table: 'block',
                    id: item.pageId
                  },
                  version: -1
                }))
              })
            }
          );
          syncStatus = syncResponse.status;
          syncBodyText = await syncResponse.text();
          const syncParsed = JSON.parse(syncBodyText);
          blockMap = syncParsed?.recordMap?.block || {};
        } catch (error) {
          syncError = String(error);
        }
      }
      const blockValueFor = id => {
        const compact = normalizePageId(id);
        const hyphenated = hyphenatePageId(id);
        const direct = blockMap[id] || blockMap[hyphenated] || blockMap[compact];
        if (direct) return direct?.value?.value ?? direct?.value ?? direct;
        for (const key of Object.keys(blockMap)) {
          if (normalizePageId(key) === compact) {
            const record = blockMap[key];
            return record?.value?.value ?? record?.value ?? record;
          }
        }
        return null;
      };
      const plainText = value => {
        if (Array.isArray(value)) {
          return value.map(part => {
            if (Array.isArray(part)) return part[0] || '';
            if (part && typeof part === 'object') {
              return part.plain_text || part.text?.content || part.content || '';
            }
            return part || '';
          }).join('');
        }
        if (value && typeof value === 'object') {
          return value.plain_text || value.text?.content || value.content || '';
        }
        return typeof value === 'string' ? value : '';
      };
      const rawNameFor = item => plainText(
        item?.raw?.name ?? item?.raw?.title ?? item?.raw?.text ?? ''
      ).trim();
      const titleFor = (item, value) => {
        const titleValue = value?.properties?.title ??
          value?.properties?.Name ??
          item.raw?.title ??
          item.raw?.name;
        return plainText(titleValue).trim();
      };
      const isSyntheticHomeRecord = (item, value, title) => {
        const rawName = rawNameFor(item);
        if (!rawName || !title || rawName === title) return false;
        if (rawName !== '首页' && rawName.toLowerCase() !== 'home') return false;
        return value?.parent_table === 'space' || value?.type === 'collection_view_page';
      };
      const mappedCandidates = candidateRecords.map(item => {
        const value = blockValueFor(item.pageId);
        const title = titleFor(item, value);
        const rawName = rawNameFor(item);
        return {
          item,
          value,
          rawName,
          title,
          filtered: isSyntheticHomeRecord(item, value, title)
        };
      });
      const hits = mappedCandidates
        .filter(entry => !entry.filtered)
        .slice(0, 20)
        .map(entry => ({
          pageId: entry.item.pageId,
          title: entry.title || entry.rawName,
          pathText: '',
          snippet: '',
          highlightBlockId: '',
          score: entry.item.visitedAt || 0,
          snippets: []
        }));
      const previewEntry = entry => ({
        id: entry.item.pageId,
        rawName: entry.rawName,
        title: entry.title,
        visitedAt: entry.item.visitedAt,
        type: entry.value?.type || '',
        parentTable: entry.value?.parent_table || '',
        parentId: entry.value?.parent_id || '',
        filtered: entry.filtered
      });
      const debug = {
        spaceId,
        userId,
        notionVersion,
        apiType: parsed?.type || '',
        rawBodyLength: bodyText.length,
        rawPageCount: rawPages.length,
        currentPageKey,
        recordCount: records.length,
        candidateCount: candidateRecords.length,
        visibleCount: hits.length,
        syncStatus,
        syncError,
        titledCount: hits.filter(hit => hit.title.length > 0).length,
        rawRecentPreview: rawPages.slice(0, 12).map(item => ({
          id: item?.pageId || item?.id || item?.blockId || item?.pointer?.id || '',
          name: item?.name || item?.title || '',
          visitedAt: item?.visitedAt ?? item?.timestamp ?? item?.lastVisitedAt ?? item?.time ?? ''
        })),
        mappedRecentPreview: mappedCandidates.slice(0, 12).map(previewEntry),
        shownRecentPreview: hits.slice(0, 12).map(hit => ({
          id: hit.pageId,
          title: hit.title,
          visitedAt: hit.score
        })),
        rawBodyPreview: response.ok ? '' : bodyText.substring(0, 1000),
        syncBodyPreview: syncStatus === 200 ? '' : syncBodyText.substring(0, 1000)
      };
      result = {
        requestId,
        status: response.status,
        results: hits,
        error: response.ok ? undefined : bodyText.substring(0, 500),
        debug
      };
    } catch (error) {
      result = {
        requestId,
        status: response.status,
        error: bodyText.substring(0, 500),
        debug: {spaceId, userId, rawBodyPreview: bodyText.substring(0, 1000)}
      };
    }
    post(result);
  }).catch(error => {
    post({requestId, error: String(error)});
  });
})();
''';

    try {
      unawaited(AppLogger.log('PrivateSearch', 'loadRecentPages request: $requestId'));
      await controller.runJavaScript(script);
      return await completer.future.timeout(const Duration(seconds: 25));
    } catch (_) {
      _searchCompleters.remove(requestId);
      rethrow;
    }
  }

  void _handleBridgeMessage(JavaScriptMessage message) {
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final requestId = data['requestId']?.toString() ?? '';
    final status = data['status'];
    final results = data['results'];
    final isRecents = requestId.startsWith('recents-');
    final debug = data['debug'];
    if (isRecents) {
      unawaited(
        AppLogger.log(
          'PrivateSearch',
          'loadRecentPages response: id=$requestId status=$status '
          'count=${results is List ? results.length : 0} debug=$debug',
        ),
      );
    } else {
      unawaited(
        AppLogger.log(
          'PrivateSearch',
          'search response: id=$requestId status=$status '
          'count=${results is List ? results.length : 0}',
        ),
      );
    }
    final completer = _searchCompleters.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(message.message);
    }
  }

  Future<void> _probeBridge() async {
    final controller = _controller;
    if (controller == null || _ready) return;

    try {
      final result = await controller.runJavaScriptReturningResult('''
(() => {
  const boot = window.__notion_boot_data || {};
  const html = document.documentElement?.outerHTML || '';
  if (boot.spaceId) return 'ready';
  return /"spaceId":"[0-9a-f-]{36}"/i.test(html) ? 'html' : 'pending';
})()
''');
      final value = result.toString().replaceAll('"', '').trim();
      await AppLogger.log(
        'PrivateSearch',
        'bridge probe: url=$_url result=$value retry=$_probeRetryCount',
      );
      if (value == 'ready' || value == 'html') {
        _ready = true;
        notifyListeners();
        return;
      }

      if (_probeRetryCount >= 10) {
        _status = _url?.contains('/login') == true
            ? '等待 Notion 登录'
            : '页面未提供工作区数据';
        notifyListeners();
        return;
      }

      _probeRetryCount++;
      await Future<void>.delayed(const Duration(seconds: 1));
      await _probeBridge();
    } catch (error) {
      await AppLogger.log('PrivateSearch', 'bridge probe failed: $error');
      if (_probeRetryCount >= 10) return;
      _probeRetryCount++;
      await Future<void>.delayed(const Duration(seconds: 1));
      await _probeBridge();
    }
  }
}
