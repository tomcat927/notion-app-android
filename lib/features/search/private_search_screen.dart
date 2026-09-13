import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../core/native_browser.dart';
import '../../core/notion_client.dart';
import '../browser/notion_page_browser_screen.dart';
import 'private_search_bridge.dart';
import 'private_search_models.dart';
import 'recent_pages_service.dart';

class PrivateSearchScreen extends StatefulWidget {
  const PrivateSearchScreen({super.key, this.bridgePageId});

  final String? bridgePageId;

  @override
  State<PrivateSearchScreen> createState() => _PrivateSearchScreenState();
}

class _PrivateSearchScreenState extends State<PrivateSearchScreen> {
  final NotionPrivateSearchBridge _bridge = NotionPrivateSearchBridge.instance;
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  int _searchToken = 0;
  int _bridgeStartToken = 0;
  bool _searching = false;
  bool _showCachedRecentPages = false;
  bool _recentServerLoadFinished = false;
  String? _error;
  List<PrivateSearchHit> _hits = [];
  List<RecentPage> _recentPages = [];

  @override
  void initState() {
    super.initState();
    _bridge.addListener(_onBridgeChanged);
    unawaited(_startBridge());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_bridge.isReady && _searchController.text.trim().isEmpty) {
        unawaited(_loadRecentFromApi());
      }
    });
  }

  @override
  void dispose() {
    _bridgeStartToken++;
    _debounce?.cancel();
    _searchController.dispose();
    _bridge.removeListener(_onBridgeChanged);
    _bridge.reset();
    super.dispose();
  }

  void _onBridgeChanged() {
    if (!mounted) return;
    setState(() {});
    if (_bridge.isReady && _searchController.text.trim().isEmpty && _hits.isEmpty && !_searching) {
      unawaited(_loadRecentFromApi());
    }
  }

  Future<void> _loadRecentPages() async {
    final pages = await RecentPagesService.getRecentPages();
    if (mounted) setState(() => _recentPages = pages);
  }

  Future<void> _loadRecentFromApi() async {
    if (!_bridge.isReady) return;
    _searchToken++;
    final token = _searchToken;
    setState(() {
      _searching = true;
      _showCachedRecentPages = false;
      _recentServerLoadFinished = false;
      _error = null;
    });
    try {
      final raw = await _bridge.loadRecentPages();
      unawaited(AppLogger.log(
        'PrivateSearch',
        'loadRecentPages raw: ${raw.length > 2000 ? raw.substring(0, 2000) : raw}',
      ));
      final response = parsePrivateSearchResponse(raw);
      final hitSummary = response.hits
          .take(5)
          .map((hit) => '${hit.pageId}:${hit.title}')
          .join(', ');
      unawaited(AppLogger.log(
        'PrivateSearch',
        'loadRecentPages parsed: status=${response.status} '
        'error=${response.error} hits=${response.hits.length} '
        'first=$hitSummary',
      ));
      if (!mounted || token != _searchToken) return;
      setState(() {
        if (response.error != null || response.status != 200 || response.hits.isEmpty) {
          unawaited(AppLogger.log(
            'PrivateSearch',
            'loadRecentPages fallback: error=${response.error} '
            'status=${response.status} hitsEmpty=${response.hits.isEmpty}',
          ));
          _hits = [];
          _showCachedRecentPages = true;
          unawaited(_loadRecentPages());
        } else {
          _showCachedRecentPages = false;
          _hits = response.hits;
        }
      });
    } catch (error) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _hits = [];
        _showCachedRecentPages = true;
        unawaited(_loadRecentPages());
      });
      unawaited(AppLogger.log('PrivateSearch', 'loadRecentPages failed: $error'));
    } finally {
      if (mounted && token == _searchToken) {
        setState(() {
          _searching = false;
          _recentServerLoadFinished = true;
        });
      }
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      _debounce = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_loadRecentFromApi()),
      );
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_search(value)),
    );
  }

  Future<void> _search(String rawQuery) async {
    final query = rawQuery.trim();
    if (!_bridge.isReady) {
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
      final raw = await _bridge.search(query);
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

  Future<String?> _resolveBridgeSeedPageId() async {
    final explicitSeed = widget.bridgePageId?.trim();
    if (explicitSeed != null && explicitSeed.isNotEmpty) {
      return explicitSeed;
    }

    final recentPages = await RecentPagesService.getRecentPages();
    String? recentSeed;
    for (final page in recentPages) {
      final pageId = page.pageId.trim();
      if (pageId.isNotEmpty) {
        recentSeed = pageId;
        break;
      }
    }

    if (recentSeed != null) {
      unawaited(
        AppLogger.log(
          'PrivateSearch',
          'bridge seed fallback from recent=$recentSeed',
        ),
      );
      return recentSeed;
    }

    final apiSeed = await _loadSeedPageIdFromApi();
    unawaited(
      AppLogger.log(
        'PrivateSearch',
        'bridge seed fallback from api=${apiSeed ?? ''}',
      ),
    );
    return apiSeed;
  }

  Future<String?> _loadSeedPageIdFromApi() async {
    try {
      final response = await NotionClient.post('/search', body: {
        'filter': {'property': 'object', 'value': 'page'},
        'sort': {
          'direction': 'descending',
          'timestamp': 'last_edited_time',
        },
        'page_size': 1,
      });
      NotionClient.ensureSuccess(response, operation: '获取搜索会话种子页面');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? const [];
      if (results.isEmpty) return null;
      final first = results.first;
      if (first is! Map) return null;
      final pageId = first['id']?.toString().trim();
      return pageId == null || pageId.isEmpty ? null : pageId;
    } catch (error) {
      unawaited(
        AppLogger.log(
          'PrivateSearch',
          'bridge seed api fallback failed: $error',
        ),
      );
      return null;
    }
  }

  Future<void> _startBridge({bool reset = false}) async {
    final token = ++_bridgeStartToken;
    if (reset) _bridge.reset();
    if (!mounted || token != _bridgeStartToken) return;
    final seedPageId = await _resolveBridgeSeedPageId();
    if (!mounted || token != _bridgeStartToken) return;
    _bridge.start(seedPageId: seedPageId);
  }

  void _reloadBridge() {
    setState(() {
      _hits = [];
      _showCachedRecentPages = false;
      _recentServerLoadFinished = false;
    });
    unawaited(_startBridge(reset: true));
  }

  Future<void> _openHit(PrivateSearchHit hit) async {
    await _openPage(hit.pageId, hit.title);
  }

  Future<void> _openRecentPage(RecentPage page) async {
    await _openPage(page.pageId, page.title);
  }

  Future<void> _openPage(String pageId, String title) async {
    unawaited(RecentPagesService.addRecentPage(pageId, title));
    await AppLogger.log('PrivateSearch', '打开笔记前释放隐藏搜索 WebView: $pageId');
    _bridge.reset();
    if (!mounted) return;
    final opened = await NativeBrowser.openPage(pageId: pageId, title: title);
    if (opened || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotionPageBrowserScreen(
          pageId: pageId,
          title: title,
        ),
      ),
    );
    if (mounted) {
      _bridge.start(seedPageId: widget.bridgePageId ?? pageId);
    }
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
          Positioned(
            left: 0,
            top: 0,
            child: _bridge.buildHiddenWebView(),
          ),
          Positioned.fill(
            child: Column(
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.arrow_forward),
                              tooltip: '搜索',
                              onPressed: () => unawaited(
                                _search(_searchController.text),
                              ),
                            ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                if (!_bridge.isReady)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Card(
                      child: ListTile(
                        leading: const Icon(Icons.person_search),
                        title: const Text('Notion 网页会话'),
                        subtitle: Text(_bridge.status),
                        trailing: _bridge.url == null
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
                                        _bridge.url ?? '未获取',
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
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(child: _buildResults()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searching && _hits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final queryIsEmpty = _searchController.text.trim().isEmpty;
    if (queryIsEmpty &&
        !_showCachedRecentPages &&
        (!_bridge.isReady || !_recentServerLoadFinished)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hits.isEmpty) {
      if (queryIsEmpty && _showCachedRecentPages && _recentPages.isNotEmpty) {
        return _buildRecentPages();
      }
      return Center(
        child: Text(
          queryIsEmpty
              ? (_bridge.isReady ? '没有最近访问记录' : 'Notion 会话未就绪')
              : '没有找到相关内容',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    final rows = queryIsEmpty ? _buildGroupedHitRows(_hits) : _hits;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row is _RecentSectionHeader) {
          return _buildSectionHeader(row.label);
        }
        final hit = row as PrivateSearchHit;
        final titleStyle = Theme.of(context).textTheme.titleMedium!;
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => unawaited(_openHit(hit)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    _iconForHit(hit),
                    size: 22,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          queryIsEmpty
                              ? _buildRecentTitleText(hit, titleStyle)
                              : _buildHighlightedText(
                                  hit.title,
                                  _searchController.text.trim(),
                                  titleStyle,
                                ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!queryIsEmpty && hit.pathText.isNotEmpty) ...[
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecentPages() {
    final rows = _buildGroupedRecentRows(_recentPages);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row is _RecentSectionHeader) {
          return _buildSectionHeader(row.label);
        }
        final page = row as RecentPage;
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => unawaited(_openRecentPage(page)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.history, size: 20, color: Colors.grey),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      page.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Colors.grey,
            ),
      ),
    );
  }

  List<Object> _buildGroupedHitRows(List<PrivateSearchHit> hits) {
    final rows = <Object>[];
    String? previousLabel;
    for (final hit in hits) {
      final label = _recentSectionLabel(hit.score);
      if (label != previousLabel) {
        rows.add(_RecentSectionHeader(label));
        previousLabel = label;
      }
      rows.add(hit);
    }
    return rows;
  }

  List<Object> _buildGroupedRecentRows(List<RecentPage> pages) {
    final rows = <Object>[];
    String? previousLabel;
    for (final page in pages) {
      final label = _recentSectionLabel(
        page.visitedAt.millisecondsSinceEpoch.toDouble(),
      );
      if (label != previousLabel) {
        rows.add(_RecentSectionHeader(label));
        previousLabel = label;
      }
      rows.add(page);
    }
    return rows;
  }

  String _recentSectionLabel(double timestamp) {
    if (timestamp <= 0) return '更早';
    final visited = DateTime.fromMillisecondsSinceEpoch(timestamp.round());
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final visitedDate = DateTime(visited.year, visited.month, visited.day);
    final days = today.difference(visitedDate).inDays;
    if (days <= 0) return '今天';
    if (days == 1) return '昨天';
    if (days <= 7) return '上周';
    return '更早';
  }

  IconData _iconForHit(PrivateSearchHit hit) {
    switch (hit.type) {
      case 'collection_view_page':
      case 'collection_view':
      case 'collection':
        return Icons.table_chart_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  TextSpan _buildRecentTitleText(PrivateSearchHit hit, TextStyle baseStyle) {
    if (hit.pathText.isEmpty) {
      return TextSpan(text: hit.title, style: baseStyle);
    }
    return TextSpan(
      style: baseStyle,
      children: [
        TextSpan(text: hit.title),
        TextSpan(
          text: ' - ${hit.pathText}',
          style: baseStyle.copyWith(color: Colors.grey),
        ),
      ],
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

class _RecentSectionHeader {
  const _RecentSectionHeader(this.label);

  final String label;
}
