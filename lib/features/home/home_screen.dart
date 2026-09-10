import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/notion_auth.dart';
import '../../core/notion_client.dart';
import '../../core/app_logger.dart';
import '../../core/update_service.dart';
import '../auth/login_screen.dart';
import '../browser/notion_page_browser_screen.dart';
import '../editor/editor_screen.dart';
import '../settings/update_section.dart';

class DatabaseView {
  const DatabaseView({
    required this.id,
    required this.label,
    this.isNative = false,
    this.filter,
    this.sorts = const [],
  });

  final String id;
  final String label;
  final bool isNative;
  final Map<String, dynamic>? filter;
  final List<Map<String, dynamic>> sorts;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentNavIndex = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  List<Map<String, dynamic>> _databases = [];
  String _sourceId = '__recent__';
  String _sourceTitle = '最近页面';
  List<DatabaseView> _views = const [];
  String _viewId = 'all';

  List<Map<String, dynamic>> _pages = [];
  String? _nextCursor;
  bool _hasMore = false;
  String? _viewQueryId;
  Map<String, dynamic>? _selectedPage;
  List<dynamic>? _pageBlocks;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
    unawaited(_autoCheckForUpdates());
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _loadDatabases();
      if (_sourceId != '__recent__') {
        await _loadViews();
      }
      await _loadRows();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadDatabases() async {
    final response = await NotionClient.post('/search', body: {
      'filter': {'property': 'object', 'value': 'data_source'},
      'sort': {'direction': 'descending', 'timestamp': 'last_edited_time'},
      'page_size': 100,
    });
    NotionClient.ensureSuccess(response, operation: '获取数据库');

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final results = List<Map<String, dynamic>>.from(data['results'] ?? []);
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('selected_data_source_id');
    final savedExists = results.any((db) => db['id'] == savedId);
    final selected = savedExists
        ? results.firstWhere((db) => db['id'] == savedId)
        : results.isNotEmpty
            ? results.first
            : null;
    final sourceId = selected?['id']?.toString() ?? '__recent__';

    setState(() {
      _databases = results;
      _sourceId = sourceId;
      _sourceTitle = selected == null ? '最近页面' : _databaseTitle(selected);
      _views = const <DatabaseView>[];
      _viewId = 'all';
    });

    await prefs.setString('selected_data_source_id', _sourceId);
  }

  Future<void> _loadViews() async {
    final encodedSourceId = Uri.encodeQueryComponent(_sourceId);
    final response = await NotionClient.get(
      '/views?data_source_id=$encodedSourceId&page_size=100',
    );
    NotionClient.ensureSuccess(response, operation: '获取视图');

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final references = List<Map<String, dynamic>>.from(data['results'] ?? []);
    final views = <DatabaseView>[];

    for (final reference in references) {
      final viewId = reference['id']?.toString();
      if (viewId == null || viewId.isEmpty) continue;

      final detailResponse = await NotionClient.get('/views/$viewId');
      NotionClient.ensureSuccess(detailResponse, operation: '读取视图详情');
      final detail =
          jsonDecode(detailResponse.body) as Map<String, dynamic>;
      final name = detail['name']?.toString() ?? '';
      final type = detail['type']?.toString() ?? 'view';
      final filter = detail['filter'];
      final sorts = detail['sorts'];

      views.add(DatabaseView(
        id: viewId,
        label: name.isEmpty ? type : name,
        isNative: true,
        filter: filter is Map<String, dynamic> ? filter : null,
        sorts: sorts is List
            ? List<Map<String, dynamic>>.from(sorts)
            : const [],
      ));
    }

    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final savedViewId = prefs.getString('selected_view_id:$_sourceId');
    setState(() {
      _views = views.isEmpty
          ? const [
              DatabaseView(id: 'all', label: '全部', sorts: [
                {'direction': 'descending', 'timestamp': 'last_edited_time'}
              ])
            ]
          : views;
      _viewId = _views.any((view) => view.id == savedViewId)
          ? savedViewId!
          : _views.first.id;
    });
  }

  Future<void> _loadRows() async {
    setState(() {
      _loading = true;
      _error = null;
      _pages = [];
      _nextCursor = null;
      _hasMore = false;
    });

    try {
      final view = _activeView;
      final Map<String, dynamic> data;
      final List<Map<String, dynamic>> results;

      if (_sourceId == '__recent__') {
        final response = await NotionClient.post('/search', body: {
          'filter': {'property': 'object', 'value': 'page'},
          'sort': {
            'direction': 'descending',
            'timestamp': 'last_edited_time',
          },
          'page_size': 100,
        });
        NotionClient.ensureSuccess(response, operation: '加载记录');
        data = jsonDecode(response.body) as Map<String, dynamic>;
        results = List<Map<String, dynamic>>.from(data['results'] ?? []);
        _viewQueryId = null;
      } else if (view.isNative) {
        try {
          final response = await NotionClient.post(
            '/views/${view.id}/queries',
            body: {'page_size': 100},
          );
          NotionClient.ensureSuccess(response, operation: '加载视图记录');
          data = jsonDecode(response.body) as Map<String, dynamic>;
          _viewQueryId = data['id']?.toString();
          results = await _hydrateViewResults(data['results']);
        } catch (error) {
          await AppLogger.log('Home', '视图查询失败，降级到数据源查询: $error');
          _viewQueryId = null;
          data = await _queryDataSourceRows();
          results = List<Map<String, dynamic>>.from(data['results'] ?? []);
        }
      } else {
        data = await _queryDataSourceRows(cursor: null);
        results = List<Map<String, dynamic>>.from(data['results'] ?? []);
      }

      if (!mounted) return;
      setState(() {
        _pages = results;
        _nextCursor = data['next_cursor'] as String?;
        _hasMore = data['has_more'] == true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      await AppLogger.log('Home', '加载记录失败: $error');
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadMoreRows() async {
    final cursor = _nextCursor;
    if (_loadingMore || !_hasMore || cursor == null) return;

    setState(() => _loadingMore = true);

    try {
      final view = _activeView;
      final Map<String, dynamic> data;
      final List<Map<String, dynamic>> results;

      if (_sourceId == '__recent__') {
        final response = await NotionClient.post('/search', body: {
          'filter': {'property': 'object', 'value': 'page'},
          'sort': {
            'direction': 'descending',
            'timestamp': 'last_edited_time',
          },
          'page_size': 100,
          'start_cursor': cursor,
        });
        NotionClient.ensureSuccess(response, operation: '加载更多记录');
        data = jsonDecode(response.body) as Map<String, dynamic>;
        results = List<Map<String, dynamic>>.from(data['results'] ?? []);
      } else if (view.isNative && _viewQueryId != null) {
        final encodedQueryId = Uri.encodeQueryComponent(_viewQueryId!);
        final encodedCursor = Uri.encodeQueryComponent(cursor);
        final response = await NotionClient.get(
          '/views/${view.id}/queries/$encodedQueryId'
          '?page_size=100&start_cursor=$encodedCursor',
        );
        NotionClient.ensureSuccess(response, operation: '加载更多视图记录');
        data = jsonDecode(response.body) as Map<String, dynamic>;
        results = await _hydrateViewResults(data['results']);
      } else {
        data = await _queryDataSourceRows(cursor: cursor);
        results = List<Map<String, dynamic>>.from(data['results'] ?? []);
      }

      if (!mounted) return;
      setState(() {
        _pages = [..._pages, ...results];
        _nextCursor = data['next_cursor'] as String?;
        _hasMore = data['has_more'] == true;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      await AppLogger.log('Home', '加载更多记录失败: $error');
      setState(() {
        _loadingMore = false;
        _error = error.toString();
      });
    }
  }

  DatabaseView get _activeView => _views.firstWhere(
        (view) => view.id == _viewId,
        orElse: () => const DatabaseView(id: 'all', label: '全部'),
      );

  Future<Map<String, dynamic>> _queryDataSourceRows({String? cursor}) async {
    final view = _activeView;
    if (view.filter != null) {
      final response = await NotionClient.post(
        '/data_sources/$_sourceId/query',
        body: {
          'page_size': 100,
          if (cursor != null) 'start_cursor': cursor,
          'filter': view.filter,
        },
      );
      if (response.statusCode == 400) {
        await AppLogger.log(
          'Home',
          '视图筛选不可用，改为查询全部记录: ${response.body}',
        );
      } else {
        NotionClient.ensureSuccess(response, operation: '加载数据源记录');
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    }

    final response = await NotionClient.post(
      '/data_sources/$_sourceId/query',
      body: {
        'page_size': 100,
        if (cursor != null) 'start_cursor': cursor,
        'sorts': [
          {'direction': 'descending', 'timestamp': 'last_edited_time'}
        ],
      },
    );
    NotionClient.ensureSuccess(response, operation: '加载数据源记录');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> _hydrateViewResults(Object? results) async {
    if (results is! List) return const [];

    final orderedIds = results
        .whereType<Map>()
        .map((item) => item['id']?.toString())
        .whereType<String>()
        .toList();
    final pages = List<Map<String, dynamic>>.filled(
      orderedIds.length,
      const {},
      growable: false,
    );
    final missingIds = orderedIds.toSet();
    final pagesById = <String, Map<String, dynamic>>{};

    try {
      String? cursor;
      var requestCount = 0;
      while (missingIds.isNotEmpty && requestCount < 50) {
        final response = await NotionClient.post(
          '/data_sources/$_sourceId/query',
          body: {
            'page_size': 100,
            if (cursor != null) 'start_cursor': cursor,
          },
        );
        NotionClient.ensureSuccess(response, operation: '读取页面详情');
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final sourcePages =
            List<Map<String, dynamic>>.from(data['results'] ?? []);

        for (final page in sourcePages) {
          final pageId = page['id']?.toString();
          if (pageId == null || !missingIds.contains(pageId)) continue;
          pagesById[pageId] = page;
          missingIds.remove(pageId);
        }

        cursor = data['next_cursor'] as String?;
        requestCount++;
        if (cursor == null) break;
      }
    } catch (_) {
      // Fall through and fetch any still-missing rows individually.
    }

    for (var index = 0; index < orderedIds.length; index++) {
      final pageId = orderedIds[index];
      var page = pagesById[pageId];
      if (page == null) {
        try {
          final response = await NotionClient.get('/pages/$pageId');
          NotionClient.ensureSuccess(response, operation: '读取页面');
          page = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          page = {'object': 'page', 'id': pageId};
        }
      }
      pages[index] = page;
    }

    return pages;
  }

  String _richText(List value) {
    return value
        .map((item) => item is Map ? item['plain_text']?.toString() ?? '' : '')
        .join('');
  }

  String _databaseTitle(Map<String, dynamic> database) {
    final title = database['title'];
    if (title is List && title.isNotEmpty) {
      final value = _richText(title).trim();
      if (value.isNotEmpty) return value;
    }
    return '未命名数据库';
  }

  Future<void> _selectSource(Map<String, dynamic> database) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'selected_data_source_id',
      database['id'].toString(),
    );
    if (!mounted) return;
    setState(() {
      _sourceId = database['id'].toString();
      _sourceTitle = _databaseTitle(database);
      _viewId = 'all';
    });
    await _loadViews();
    await _loadRows();
  }

  Future<void> _selectRecent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_data_source_id', '__recent__');
    if (!mounted) return;
    setState(() {
      _sourceId = '__recent__';
      _sourceTitle = '最近页面';
      _views = const [];
      _viewId = 'all';
    });
    await _loadRows();
  }

  Future<void> _selectView(String id) async {
    if (id == _viewId) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_view_id:$_sourceId', id);
    if (!mounted) return;
    setState(() => _viewId = id);
    await _loadRows();
  }

  Future<void> _loadPageContent(String pageId) async {
    setState(() {
      _loading = true;
    });

    try {
      await AppLogger.log('Home', '加载页面内容: $pageId');

      final response = await NotionClient.get('/blocks/$pageId/children?page_size=100');
      await AppLogger.log('Home', '页面内容响应: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _pageBlocks = data['results'] as List? ?? [];
          _loading = false;
        });
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      await AppLogger.log('Home', '加载页面内容失败: $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _pageTitle(Map<String, dynamic> page) {
    try {
      final props = page['properties'] as Map<String, dynamic>? ?? {};
      for (final entry in props.entries) {
        final value = entry.value as Map<String, dynamic>?;
        if (value?['type'] == 'title') {
          final titleList = value?['title'] as List? ?? [];
          if (titleList.isNotEmpty) {
            return titleList.map((t) => t['plain_text'] ?? '').join('');
          }
        }
      }
    } catch (_) {}
    return page['id']?.toString().substring(0, 8) ?? '无标题';
  }

  String _blocksToMarkdown(List<dynamic> blocks) {
    final buffer = StringBuffer();
    for (final block in blocks) {
      final type = block['type'] as String? ?? '';
      final content = block[type] as Map<String, dynamic>? ?? {};
      final richText = content['rich_text'] as List? ?? [];

      switch (type) {
        case 'heading_1':
          buffer.writeln('# ${_richTextToPlain(richText)}');
          break;
        case 'heading_2':
          buffer.writeln('## ${_richTextToPlain(richText)}');
          break;
        case 'heading_3':
          buffer.writeln('### ${_richTextToPlain(richText)}');
          break;
        case 'paragraph':
          buffer.writeln(_richTextToPlain(richText));
          break;
        case 'bulleted_list_item':
          buffer.writeln('- ${_richTextToPlain(richText)}');
          break;
        case 'numbered_list_item':
          buffer.writeln('1. ${_richTextToPlain(richText)}');
          break;
        case 'to_do':
          final checked = content['checked'] == true;
          buffer.writeln('- [${checked ? 'x' : ' '}] ${_richTextToPlain(richText)}');
          break;
        case 'code':
          buffer.writeln('```');
          buffer.writeln(_richTextToPlain(richText));
          buffer.writeln('```');
          break;
        case 'divider':
          buffer.writeln('---');
          break;
        default:
          buffer.writeln(_richTextToPlain(richText));
      }
      buffer.writeln();
    }
    return buffer.toString().isEmpty ? '（空页面）' : buffer.toString();
  }

  String _richTextToPlain(List richText) {
    return richText.map((t) => t['plain_text'] ?? '').join('');
  }

  Future<void> _showDebugLogs() async {
    final logs = await AppLogger.readLogs();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('调试日志'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(logs, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await AppLogger.clearLogs();
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: logs)),
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    await NotionAuth.removeToken();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final showPage = _selectedPage != null;
    return Scaffold(
      appBar: showPage
          ? AppBar(
              title: Text(_pageTitle(_selectedPage!)),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _selectedPage = null;
                  _pageBlocks = null;
                }),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: '编辑页面',
                  onPressed: _openEditor,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _loadPageContent(_selectedPage!['id']),
                ),
              ],
            )
          : AppBar(
              title: const Text('Notion App'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: _loadRows,
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'logout') _logout();
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'logout', child: Text('退出登录')),
                  ],
                ),
              ],
            ),
      body: _buildContent(),
      bottomNavigationBar: showPage
          ? null
          : NavigationBar(
              selectedIndex: _currentNavIndex,
              onDestinationSelected: (index) =>
                  setState(() => _currentNavIndex = index),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.article_outlined),
                  selectedIcon: Icon(Icons.article),
                  label: '页面',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
    );
  }

  Widget _buildContent() {
    if (_currentNavIndex == 1) return _buildSettings();

    if (_selectedPage != null) {
      return _buildPageContent();
    }

    return RefreshIndicator(
      onRefresh: _loadRows,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildDatabaseHeader()),
          if (_views.length > 1) SliverToBoxAdapter(child: _buildViewBar()),
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 16),
                    Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _loadRows, child: const Text('重试')),
                  ],
                ),
              ),
            )
          else if (_pages.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('这个视图里没有记录'),
                    SizedBox(height: 8),
                    Text(
                      '请确认集成已关联到当前数据库',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverList.separated(
              itemCount: _pages.length + (_hasMore ? 1 : 0),
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, index) {
                if (index >= _pages.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: _loadingMore
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : OutlinedButton.icon(
                              onPressed: _loadMoreRows,
                              icon: const Icon(Icons.expand_more),
                              label: const Text('加载更多'),
                            ),
                    ),
                  );
                }

                final page = _pages[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: Text(
                    _pageTitle(page),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '最后编辑 ${_formatDateTime(page['last_edited_time']?.toString())}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => _openPageInBrowser(page),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildDatabaseHeader() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _showDatabasePicker,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.dataset_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _sourceTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildViewBar() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _views.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final view = _views[index];
          return ChoiceChip(
            label: Text(view.label),
            selected: _viewId == view.id,
            onSelected: (_) => _selectView(view.id),
          );
        },
      ),
    );
  }

  void _showDatabasePicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('选择数据源'),
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('最近页面'),
                trailing: _sourceId == '__recent__'
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_selectRecent());
                },
              ),
              ..._databases.map((database) {
                final id = database['id']?.toString() ?? '';
                return ListTile(
                  leading: const Icon(Icons.dataset_outlined),
                  title: Text(
                    _databaseTitle(database),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '最后编辑 ${_formatDateTime(database['last_edited_time']?.toString())}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _sourceId == id ? const Icon(Icons.check) : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_selectSource(database));
                  },
                );
              }),
              if (_databases.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('没有找到可用的数据库'),
                ),
            ],
          ),
        );
      },
    );
  }

  String _formatDateTime(String? value) {
    final time = DateTime.tryParse(value ?? '')?.toLocal();
    if (time == null) return '未知';
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '${time.year}-$month-$day $hour:$minute';
  }

  Widget _buildPageContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => _loadPageContent(_selectedPage!['id']), child: const Text('重试')),
          ],
        ),
      );
    }

    final blocks = _pageBlocks ?? [];
    final markdown = _blocksToMarkdown(blocks);
    return Column(
      children: [
        Expanded(
          child: Markdown(data: markdown, padding: const EdgeInsets.all(24), selectable: true),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.edit),
                label: const Text('编辑此页面'),
                onPressed: _openEditor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor() async {
    final pageId = _selectedPage?['id']?.toString();
    if (pageId == null || pageId.isEmpty) return;

    await AppLogger.log('Home', '打开编辑器: $pageId');

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          pageId: pageId,
          title: _pageTitle(_selectedPage!),
        ),
      ),
    );

    await _loadPageContent(pageId);
  }

  Future<void> _openPageInBrowser(Map<String, dynamic> page) async {
    final pageId = page['id']?.toString();
    if (pageId == null || pageId.isEmpty) return;

    await AppLogger.log('Home', '使用内嵌浏览器打开: $pageId');

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotionPageBrowserScreen(
          pageId: pageId,
          title: _pageTitle(page),
        ),
      ),
    );
  }

  Future<void> _autoCheckForUpdates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(UpdateService.autoUpdatePreferenceKey) ?? true)) {
      return;
    }

    try {
      final updateInfo = await UpdateService.checkForUpdate();
      if (updateInfo == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发现新版本：${updateInfo.tagName}，可在设置中更新')),
      );
    } catch (_) {
      // A failed background update check must not interrupt normal startup.
    }
  }

  Widget _buildSettings() {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const UpdateSection(),
          const SizedBox(height: 8),
          Card(
          child: SwitchListTile(
            title: const Text('调试日志'),
            subtitle: const Text('开启后将 API 请求和错误写入设备日志文件'),
            value: AppLogger.isEnabled,
            onChanged: (value) async {
              await AppLogger.setEnabled(value);
              setState(() {});
            },
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.article),
            title: const Text('查看调试日志'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showDebugLogs,
          ),
        ),
      ],
    );
  }
}
