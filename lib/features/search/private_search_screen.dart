import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_logger.dart';
import '../browser/notion_page_browser_screen.dart';
import 'private_search_models.dart';

class PrivateSearchScreen extends StatefulWidget {
  const PrivateSearchScreen({super.key, this.bridgePageId});

  final String? bridgePageId;

  @override
  State<PrivateSearchScreen> createState() => _PrivateSearchScreenState();
}

class _PrivateSearchScreenState extends State<PrivateSearchScreen> {
  static const String _searchUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/152.0.0.0 Mobile Safari/537.36';

  late final WebViewController _controller;
  final TextEditingController _searchController = TextEditingController();
  final Map<String, Completer<String>> _searchCompleters = {};
  Timer? _debounce;
  int _searchToken = 0;
  int _probeRetryCount = 0;
  bool _bridgeReady = false;
  bool _searching = false;
  String _bridgeStatus = '正在连接 Notion';
  String? _bridgeUrl;
  String? _error;
  List<PrivateSearchHit> _hits = [];

  @override
  void initState() {
    super.initState();
    final seedPageId = widget.bridgePageId?.trim().replaceAll('-', '') ?? '';
    final initialUrl = seedPageId.isEmpty
        ? 'https://www.notion.so/'
        : 'https://www.notion.so/$seedPageId';
    unawaited(
      AppLogger.log('PrivateSearch', 'bridge start: $initialUrl'),
    );
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
            if (!mounted) return;
            setState(() {
              _bridgeReady = false;
              _bridgeStatus = '正在加载 Notion 页面';
              _bridgeUrl = url;
            });
            unawaited(AppLogger.log('PrivateSearch', 'page started: $url'));
          },
          onPageFinished: (_) => unawaited(_probeBridge()),
          onUrlChange: (change) {
            final url = change.url ?? '';
            if (!mounted || url.isEmpty) return;
            final uri = Uri.tryParse(url);
            final isLogin = uri != null &&
                (uri.pathSegments.contains('login') ||
                    uri.path.contains('/login'));
            setState(() {
              _bridgeUrl = url;
              _bridgeStatus = isLogin ? '需要登录 Notion' : '正在连接 Notion';
            });
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
            if (error.isForMainFrame != true || !mounted) return;
            setState(() {
              _bridgeReady = false;
              _bridgeStatus = 'Notion 页面加载失败：${error.description}';
            });
            unawaited(
              AppLogger.log('PrivateSearch', 'web error: ${error.description}'),
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    for (final completer in _searchCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('搜索页面已关闭'));
      }
    }
    _searchCompleters.clear();
    super.dispose();
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
    unawaited(
      AppLogger.log(
        'PrivateSearch',
        'search response: id=$requestId status=$status '
        'count=${results is List ? results.length : 0}',
      ),
    );
    final completer = _searchCompleters.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(message.message);
    }
  }

  Future<void> _probeBridge() async {
    if (!mounted || _bridgeReady) return;

    try {
      final result = await _controller.runJavaScriptReturningResult('''
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
        'bridge probe: url=$_bridgeUrl result=$value retry=$_probeRetryCount',
      );
      if (value == 'ready' || value == 'html') {
        if (!mounted) return;
        setState(() => _bridgeReady = true);
        return;
      }

      if (_probeRetryCount >= 10) {
        if (!mounted) return;
        setState(
          () => _bridgeStatus = _bridgeUrl?.contains('/login') == true
              ? '等待 Notion 登录'
              : '页面未提供工作区数据',
        );
        return;
      }

      _probeRetryCount++;
      await Future<void>.delayed(const Duration(seconds: 1));
      await _probeBridge();
    } catch (error) {
      await AppLogger.log('PrivateSearch', 'bridge probe failed: $error');
      if (!mounted || _probeRetryCount >= 10) return;
      _probeRetryCount++;
      await Future<void>.delayed(const Duration(seconds: 1));
      await _probeBridge();
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _hits = [];
        _error = null;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_search(value)),
    );
  }

  Future<void> _search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return;
    if (!_bridgeReady) {
      setState(() => _error = 'Notion 会话未就绪');
      return;
    }

    _searchToken++;
    final token = _searchToken;
    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final raw = await _runSearch(query);
      final response = parsePrivateSearchResponse(raw);
      if (!mounted || token != _searchToken) return;

      setState(() {
        if (response.error != null) {
          _error = response.error;
          _hits = [];
        } else if (response.status != 200) {
          _error = '搜索失败（HTTP ${response.status}）';
          _hits = [];
        } else {
          _hits = response.hits;
        }
      });
    } catch (error) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _error = '搜索失败：$error';
        _hits = [];
      });
      unawaited(AppLogger.log('PrivateSearch', 'search failed: $error'));
    } finally {
      if (mounted && token == _searchToken) {
        setState(() => _searching = false);
      }
    }
  }

  Future<String> _runSearch(String query) async {
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
      'x-notion-client-version': '23.13.20260910.2358',
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
        const snippets = (highlights.textHighlights || []).slice(0, 4).map(
          entry => ({
            text: entry.highlightedText || '',
            blockId: entry.highlightBlockId || ''
          })
        );
        return {
          pageId: item.id || '',
          title: highlight.title || highlights.titleHighlight || '',
          pathText: highlight.pathText || highlights.pathTextHighlight || '',
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
      await _controller.runJavaScript(script);
      return await completer.future.timeout(const Duration(seconds: 25));
    } catch (_) {
      _searchCompleters.remove(requestId);
      rethrow;
    }
  }

  void _reloadBridge() {
    setState(() {
      _bridgeReady = false;
      _probeRetryCount = 0;
      _bridgeStatus = '正在重新连接 Notion';
    });
    _controller.reload();
  }

  void _openHit(PrivateSearchHit hit) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotionPageBrowserScreen(
          pageId: hit.pageId,
          title: hit.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('全文搜索'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新连接',
            onPressed: _reloadBridge,
          ),
        ],
      ),
      body: Stack(
        children: [
          Offstage(
            offstage: true,
            child: SizedBox(
              width: 1,
              height: 1,
              child: WebViewWidget(controller: _controller),
            ),
          ),
          Column(
            children: [
              Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _onSearchChanged,
              onSubmitted: (value) {
                _debounce?.cancel();
                unawaited(_search(value));
              },
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索全部笔记内容',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        tooltip: '搜索',
                        onPressed: () =>
                            unawaited(_search(_searchController.text)),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (!_bridgeReady)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_search),
                      title: const Text('Notion 网页会话'),
                      subtitle: Text(_bridgeStatus),
                      trailing: _bridgeUrl == null
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.link),
                              tooltip: '查看会话地址',
                              onPressed: () {
                                showDialog<void>(
                                  context: context,
                                  builder: (dialogContext) => AlertDialog(
                                    title: const Text('会话地址'),
                                    content: SelectableText(
                                      _bridgeUrl ?? '未获取',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dialogContext).pop(),
                                        child: const Text('关闭'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            Expanded(child: _buildResults()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searching && _hits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          _searchController.text.trim().isEmpty ? '' : '没有找到相关内容',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _hits.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final hit = _hits[index];
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _openHit(hit),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    _buildHighlightedText(
                      hit.title,
                      _searchController.text.trim(),
                      Theme.of(context).textTheme.titleMedium!,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hit.pathText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      hit.pathText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (hit.primarySnippet.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text.rich(
                      _buildHighlightedText(
                        hit.primarySnippet,
                        _searchController.text.trim(),
                        Theme.of(context).textTheme.bodyMedium!,
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  TextSpan _buildHighlightedText(
    String rawText,
    String query,
    TextStyle baseStyle,
  ) {
    final text = rawText.replaceAll(RegExp(r'<[^>]*>'), '');
    if (query.isEmpty) return TextSpan(text: text, style: baseStyle);

    final lowercaseText = text.toLowerCase();
    final lowercaseQuery = query.toLowerCase();
    final highlightStyle = baseStyle.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final index = lowercaseText.indexOf(lowercaseQuery, start);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(start), style: baseStyle));
        break;
      }
      if (index > start) {
        spans.add(
          TextSpan(text: text.substring(start, index), style: baseStyle),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: highlightStyle,
        ),
      );
      start = index + query.length;
    }
    return TextSpan(children: spans);
  }
}
