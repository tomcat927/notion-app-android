import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/notion_auth.dart';
import '../../core/notion_client.dart';
import '../../core/app_logger.dart';
import '../../core/update_service.dart';
import '../auth/login_screen.dart';
import '../browser/notion_page_browser_screen.dart';
import '../editor/editor_screen.dart';
import '../settings/update_section.dart';
import '../settings/update_dialog.dart';
import '../settings/about_section.dart';
import '../search/private_search_screen.dart';
import '../search/private_search_bridge.dart';

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
  static const int _firstPageSize = 15;
  static const int _loadMorePageSize = 30;
  static const int _initialViewDetailCount = 8;
  static const int _viewDetailBatchSize = 5;

  int _currentNavIndex = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  bool _creatingPage = false;
  bool _searchActive = false;
  String _searchQuery = '';
  String _searchScope = 'current';
  Timer? _searchDebounce;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  int _loadGeneration = 0;
  int _viewsGeneration = 0;
  Future<void>? _databasesFuture;

  List<Map<String, dynamic>> _databases = [];
  Map<String, dynamic>? _selectedSource;
  String _sourceId = '__recent__';
  String _sourceTitle = '最近页面';
  List<DatabaseView> _views = const [];
  String _viewId = 'all';
  DatabaseView? _startupView;

  DatabaseView? get _activeView {
    if (_searchActive) return null;
    for (final view in _views) {
      if (view.id == _viewId) return view;
    }
    return _startupView;
  }

  Map<String, dynamic>? get _dataSourceFilter {
    if (_searchActive) return _searchTitleFilter();
    return _activeView?.filter;
  }

  List<Map<String, dynamic>> get _dataSourceSorts {
    final viewSorts = _activeView?.sorts;
    if (viewSorts != null && viewSorts.isNotEmpty) return viewSorts;
    return [
      {'direction': 'descending', 'timestamp': 'last_edited_time'}
    ];
  }

  List<Map<String, dynamic>> _pages = [];
  String? _nextCursor;
  bool _hasMore = false;
  Map<String, dynamic>? _selectedPage;
  List<dynamic>? _pageBlocks;
  final NotionPrivateSearchBridge _privateSearchBridge =
      NotionPrivateSearchBridge.instance;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    _privateSearchBridge.reset();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_initialize());
    unawaited(_autoCheckForUpdates());
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _restoreSelectedSource();
      await _restoreStartupView();
      await _loadRows();
      if (_sourceId != '__recent__') {
        unawaited(_loadViews());
        unawaited(_refreshSelectedSource());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _restoreSelectedSource() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('selected_data_source_id');

    if (savedId == '__recent__') {
      _applyRecentSource();
      return;
    }

    // 首选：从本地缓存恢复完整数据源对象，跳过 HTTP 请求。
    final cachedSource = prefs.getString('selected_data_source');
    if (cachedSource != null && cachedSource.isNotEmpty) {
      try {
        final source = jsonDecode(cachedSource) as Map<String, dynamic>;
        final cachedId = source['id']?.toString() ?? '';
        if (cachedId.isNotEmpty && (savedId == null || cachedId == savedId)) {
          _applySource(source);
          return;
        }
      } catch (_) {
        // 缓存损坏时回退到 HTTP 获取。
      }
    }

    // 次选：仅有 ID 缓存时走 HTTP 获取。
    if (savedId != null && savedId.isNotEmpty) {
      try {
        final response = await NotionClient.get('/data_sources/$savedId');
        NotionClient.ensureSuccess(response, operation: '获取数据源');
        final source = jsonDecode(response.body) as Map<String, dynamic>;
        _applySource(source);
        return;
      } catch (error) {
        await AppLogger.log('Home', '恢复已选数据源失败，回退搜索: $error');
      }
    }

    final firstSource = await _findFirstSource();
    if (firstSource == null) {
      _applyRecentSource();
      return;
    }

    _applySource(firstSource);
    await prefs.setString('selected_data_source_id', _sourceId);
    await prefs.setString('selected_data_source', jsonEncode(firstSource));
  }

  Future<void> _refreshSelectedSource() async {
    if (_sourceId == '__recent__') return;

    try {
      final response = await NotionClient.get('/data_sources/$_sourceId');
      NotionClient.ensureSuccess(response, operation: '刷新数据源');
      final source = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;

      final title = _databaseTitle(source);
      setState(() {
        _selectedSource = source;
        _sourceTitle = title;
        final index = _databases.indexWhere(
          (db) => db['id']?.toString() == _sourceId,
        );
        if (index >= 0) {
          _databases[index] = source;
        } else {
          _databases = [source, ..._databases];
        }
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_data_source', jsonEncode(source));
    } catch (error) {
      await AppLogger.log('Home', '刷新数据源信息失败: $error');
    }
  }

  Future<void> _restoreStartupView() async {
    if (_sourceId == '__recent__') return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('startup_view:$_sourceId');
      if (cached == null || cached.isEmpty) return;

      final data = jsonDecode(cached) as Map<String, dynamic>;
      final filter = data['filter'];
      final sorts = data['sorts'];
      _startupView = DatabaseView(
        id: data['id']?.toString() ?? '',
        label: '',
        filter: filter is Map<String, dynamic> ? filter : null,
        sorts: sorts is List
            ? List<Map<String, dynamic>>.from(sorts)
            : const [],
      );
    } catch (_) {
      // 缓存损坏时静默忽略，首屏退化为默认排序。
    }
  }

  Future<void> _cacheStartupView(DatabaseView view) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'startup_view:$_sourceId',
        jsonEncode({
          'id': view.id,
          'filter': view.filter,
          'sorts': view.sorts,
        }),
      );
    } catch (_) {
      // 缓存写入失败不影响运行。
    }
  }

  bool _viewConditionsDiffer(DatabaseView a, DatabaseView b) {
    final aFilter = a.filter == null ? '' : jsonEncode(a.filter);
    final bFilter = b.filter == null ? '' : jsonEncode(b.filter);
    if (aFilter != bFilter) return true;
    return jsonEncode(a.sorts) != jsonEncode(b.sorts);
  }

  Future<Map<String, dynamic>?> _findFirstSource() async {
    final response = await NotionClient.post('/search', body: {
      'filter': {'property': 'object', 'value': 'data_source'},
      'sort': {'direction': 'descending', 'timestamp': 'last_edited_time'},
      'page_size': 1,
    });
    NotionClient.ensureSuccess(response, operation: '获取数据库');

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final results = List<Map<String, dynamic>>.from(data['results'] ?? []);
    return results.isEmpty ? null : results.first;
  }

  void _applySource(Map<String, dynamic> source) {
    final sourceId = source['id']?.toString() ?? '';
    if (sourceId.isEmpty || !mounted) return;

    setState(() {
      _databases = [source];
      _selectedSource = source;
      _sourceId = sourceId;
      _sourceTitle = _databaseTitle(source);
      _views = const <DatabaseView>[];
      _viewId = 'all';
    });
  }

  void _applyRecentSource() {
    if (!mounted) return;

    setState(() {
      _databases = const <Map<String, dynamic>>[];
      _selectedSource = null;
      _sourceId = '__recent__';
      _sourceTitle = '最近页面';
      _views = const <DatabaseView>[];
      _viewId = 'all';
    });
  }

  Future<void> _ensureDatabasesLoaded() {
    return _databasesFuture ??= _loadAllDatabases();
  }

  Future<void> _loadAllDatabases() async {
    try {
      final response = await NotionClient.post('/search', body: {
        'filter': {'property': 'object', 'value': 'data_source'},
        'sort': {'direction': 'descending', 'timestamp': 'last_edited_time'},
        'page_size': 100,
      });
      NotionClient.ensureSuccess(response, operation: '获取数据库');

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = List<Map<String, dynamic>>.from(data['results'] ?? []);
      final merged = <String, Map<String, dynamic>>{};
      for (final database in [..._databases, ...results]) {
        final id = database['id']?.toString();
        if (id == null || id.isEmpty) continue;
        merged[id] = database;
      }

      if (!mounted) return;
      setState(() => _databases = merged.values.toList());
    } catch (error) {
      _databasesFuture = null;
      await AppLogger.log('Home', '加载数据库列表失败: $error');
      rethrow;
    }
  }

  Future<void> _loadViews() async {
    final requestId = ++_viewsGeneration;
    try {
      final encodedSourceId = Uri.encodeQueryComponent(_sourceId);
      final response = await NotionClient.get(
        '/views?data_source_id=$encodedSourceId&page_size=100',
      );
      if (requestId != _viewsGeneration || !mounted) return;
      NotionClient.ensureSuccess(response, operation: '获取视图');

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final references = List<Map<String, dynamic>>.from(data['results'] ?? []);
      if (references.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final savedViewId = prefs.getString('selected_view_id:$_sourceId');
      if (savedViewId != null) {
        final savedIndex = references
            .indexWhere((ref) => ref['id']?.toString() == savedViewId);
        if (savedIndex > 0) {
          final savedRef = references.removeAt(savedIndex);
          references.insert(0, savedRef);
        }
      }

      final initialCount = references.length < _initialViewDetailCount
          ? references.length
          : _initialViewDetailCount;
      final initialViews = await _fetchViewDetails(
        references.sublist(0, initialCount),
        requestId: requestId,
      );
      if (requestId != _viewsGeneration || !mounted) return;
      if (initialViews.isEmpty) return;

      final selectedId = initialViews.any((view) => view.id == savedViewId)
          ? savedViewId!
          : initialViews.first.id;
      final previousViewId = _viewId;
      setState(() {
        _views = initialViews;
        _viewId = selectedId;
      });

      if (previousViewId != selectedId) {
        DatabaseView? selectedView;
        for (final view in initialViews) {
          if (view.id == selectedId) {
            selectedView = view;
            break;
          }
        }
        if (selectedView != null) {
          await _cacheStartupView(selectedView);
          final cachedView = _startupView;
          _startupView = null;
          final needsReload = cachedView == null
              ? (selectedView.filter != null ||
                  selectedView.sorts.isNotEmpty)
              : cachedView.id != selectedView.id ||
                  _viewConditionsDiffer(cachedView, selectedView);
          if (needsReload) {
            unawaited(_loadRows(silent: true));
          }
        } else {
          _startupView = null;
        }
      }

      if (references.length <= initialCount) return;
      final remainingViews = await _fetchViewDetails(
        references.sublist(initialCount),
        requestId: requestId,
      );
      if (requestId != _viewsGeneration || !mounted) return;
      if (remainingViews.isEmpty) return;
      setState(() => _views = [..._views, ...remainingViews]);
    } catch (error) {
      if (requestId != _viewsGeneration || !mounted) return;
      await AppLogger.log('Home', '加载视图失败: $error');
    }
  }

  Future<List<DatabaseView>> _fetchViewDetails(
    List<Map<String, dynamic>> references, {
    required int requestId,
  }) async {
    final views = <DatabaseView>[];

    for (var start = 0; start < references.length; start += _viewDetailBatchSize) {
      final rawEnd = start + _viewDetailBatchSize;
      final end = rawEnd > references.length ? references.length : rawEnd;
      final batch = references.sublist(start, end);
      final batchViews = await Future.wait(
        batch.map(_fetchViewDetail),
      );
      if (requestId != _viewsGeneration) return views;
      views.addAll(batchViews.whereType<DatabaseView>());
    }

    return views;
  }

  Future<DatabaseView?> _fetchViewDetail(
    Map<String, dynamic> reference,
  ) async {
    final viewId = reference['id']?.toString();
    if (viewId == null || viewId.isEmpty) return null;

    try {
      final detailResponse = await NotionClient.get('/views/$viewId');
      NotionClient.ensureSuccess(detailResponse, operation: '读取视图详情');
      final detail = jsonDecode(detailResponse.body) as Map<String, dynamic>;
      final name = detail['name']?.toString() ?? '';
      final type = detail['type']?.toString() ?? 'view';
      final filter = detail['filter'];
      final sorts = detail['sorts'];

      return DatabaseView(
        id: viewId,
        label: name.isEmpty ? type : name,
        isNative: true,
        filter: filter is Map<String, dynamic> ? filter : null,
        sorts: sorts is List
            ? List<Map<String, dynamic>>.from(sorts)
            : const [],
      );
    } catch (error) {
      await AppLogger.log('Home', '读取视图详情失败 $viewId: $error');
      return null;
    }
  }

  Future<void> _loadRows({bool silent = false}) async {
    final generation = ++_loadGeneration;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
        _pages = [];
        _nextCursor = null;
        _hasMore = false;
      });
    }

    try {
      final data = await _loadRowsPage();
      if (generation != _loadGeneration) return;
      final results = List<Map<String, dynamic>>.from(data['results'] ?? []);
      if (!mounted) return;
      setState(() {
        _pages = results;
        _nextCursor = data['next_cursor'] as String?;
        _hasMore = data['has_more'] == true;
        _loading = false;
      });
      if (results.isNotEmpty) {
        _privateSearchBridge.start(
          seedPageId: results.first['id']?.toString(),
        );
      }
    } catch (error) {
      if (generation != _loadGeneration || !mounted) return;
      await AppLogger.log('Home', '加载记录失败: $error');
      setState(() {
        _loading = false;
        if (!silent) _error = error.toString();
      });
    }
  }

  Future<void> _loadMoreRows() async {
    final cursor = _nextCursor;
    if (_loading ||
        _loadingMore ||
        !_hasMore ||
        cursor == null ||
        _pages.isEmpty) {
      return;
    }
    final generation = _loadGeneration;

    setState(() => _loadingMore = true);

    try {
      final data = await _loadRowsPage(
        cursor: cursor,
        pageSize: _loadMorePageSize,
      );
      if (generation != _loadGeneration || !mounted) return;
      final results = List<Map<String, dynamic>>.from(data['results'] ?? []);
      if (!mounted) return;
      setState(() {
        _pages = [..._pages, ...results];
        _nextCursor = data['next_cursor'] as String?;
        _hasMore = data['has_more'] == true;
        _loadingMore = false;
      });
    } catch (error) {
      if (generation != _loadGeneration || !mounted) return;
      await AppLogger.log('Home', '加载更多记录失败: $error');
      setState(() {
        _loadingMore = false;
      });
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_loading || _loadingMore || !_hasMore) return;

    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels < 240) {
      unawaited(_loadMoreRows());
    }
  }

  Future<Map<String, dynamic>> _loadRowsPage({
    String? cursor,
    int pageSize = _firstPageSize,
  }) async {
    final query = _searchQuery.trim();
    if (_sourceId == '__recent__' || (_searchActive && _searchScope == 'all')) {
      final response = await NotionClient.post('/search', body: {
        if (query.isNotEmpty) 'query': query,
        'filter': {'property': 'object', 'value': 'page'},
        'sort': {
          'direction': 'descending',
          'timestamp': 'last_edited_time',
        },
        'page_size': pageSize,
        if (cursor != null) 'start_cursor': cursor,
      });
      NotionClient.ensureSuccess(response, operation: '搜索页面');
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    return _queryDataSourceRows(cursor: cursor, pageSize: pageSize);
  }

  String _sourceLabelForPage(Map<String, dynamic> page) {
    final parent = page['parent'];
    if (parent is! Map) return 'Notion';

    final type = parent['type']?.toString();
    final id = switch (type) {
      'data_source_id' => parent['data_source_id']?.toString(),
      'database_id' => parent['database_id']?.toString(),
      _ => null,
    };

    if (id != null) {
      for (final database in _databases) {
        if (database['id']?.toString() == id) {
          return _databaseTitle(database);
        }
      }
    }

    return switch (type) {
      'page_id' => '子页面',
      'workspace' => '工作区',
      _ => '未识别来源',
    };
  }

  Widget _buildSearchScopeBar() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          ChoiceChip(
            label: const Text('当前库'),
            selected: _searchScope == 'current',
            onSelected: _sourceId == '__recent__'
                ? null
                : (_) => _selectSearchScope('current'),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('全部库'),
            selected: _searchScope == 'all',
            onSelected: (_) => _selectSearchScope('all'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectSearchScope(String scope) async {
    if (_searchScope == scope) return;
    setState(() => _searchScope = scope);
    if (scope == 'all') {
      unawaited(_preloadDatabases());
    }
    await _loadRows();
  }

  Future<void> _preloadDatabases() async {
    try {
      await _ensureDatabasesLoaded();
    } catch (_) {
      // _loadAllDatabases 已记录日志，来源标签会回退为通用文案。
    }
  }

  Map<String, dynamic>? _searchTitleFilter() {
    final query = _searchQuery.trim();
    if (query.isEmpty) return null;

    final source = _selectedSource;
    final titleProperty = source == null ? null : _titlePropertyName(source);
    if (titleProperty == null) return null;

    return {
      'property': titleProperty,
      'title': {'contains': query},
    };
  }

  Future<Map<String, dynamic>> _queryDataSourceRows({
    String? cursor,
    int pageSize = _firstPageSize,
  }) async {
    final filter = _dataSourceFilter;
    final sorts = _dataSourceSorts;
    final fallbackSorts = [
      {'direction': 'descending', 'timestamp': 'last_edited_time'}
    ];

    Future<Map<String, dynamic>?> request({
      required bool useFilter,
      required bool useSorts,
    }) async {
      final effectiveSorts = useSorts ? sorts : fallbackSorts;
      final response = await NotionClient.post(
        '/data_sources/$_sourceId/query',
        body: {
          'page_size': pageSize,
          if (cursor != null) 'start_cursor': cursor,
          if (useFilter && filter != null) 'filter': filter,
          'sorts': effectiveSorts,
        },
      );

      if (response.statusCode == 400) {
        await AppLogger.log(
          'Home',
          '数据源查询参数不可用，自动降级: ${response.body}',
        );
        return null;
      }

      NotionClient.ensureSuccess(response, operation: '加载数据源记录');
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    final rows = await request(useFilter: true, useSorts: true);
    if (rows != null) return rows;

    final allRows = await request(useFilter: false, useSorts: false);
    return allRows!;
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
    await prefs.setString(
      'selected_data_source',
      jsonEncode(database),
    );
    if (!mounted) return;
    setState(() {
      _sourceId = database['id'].toString();
      _selectedSource = database;
      _sourceTitle = _databaseTitle(database);
      _views = const [];
      _viewId = 'all';
      _startupView = null;
      _searchScope = 'current';
      _clearSearch(immediate: true);
    });
    unawaited(_loadRows());
    unawaited(_loadViews());
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
      _startupView = null;
      _searchScope = 'all';
      _clearSearch(immediate: true);
    });
    unawaited(_loadRows());
  }

  Future<void> _selectView(String id) async {
    if (id == _viewId) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_view_id:$_sourceId', id);
    if (!mounted) return;
    setState(() => _viewId = id);
    await _loadRows();
  }

  void _clearSearch({bool immediate = false}) {
    _searchDebounce?.cancel();
    _searchController.clear();
    _searchQuery = '';
    if (immediate) return;
    unawaited(_loadRows());
  }

  void _openSearch() {
    if (_sourceId == '__recent__') _searchScope = 'all';
    setState(() => _searchActive = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() => _searchActive = false);
    _searchFocus.unfocus();
    if (_searchQuery.isNotEmpty) _clearSearch();
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      final query = value.trim();
      if (query == _searchQuery) return;
      _searchQuery = query;
      unawaited(_loadRows());
    });
  }

  void _submitSearch() {
    _searchDebounce?.cancel();
    final query = _searchController.text.trim();
    if (query == _searchQuery) return;
    _searchQuery = query;
    unawaited(_loadRows());
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
                  icon: const Icon(Icons.open_in_new),
                  tooltip: '在浏览器打开',
                  onPressed: _openPageInExternalBrowser,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _loadPageContent(_selectedPage!['id']),
                ),
              ],
            )
          : AppBar(
              titleSpacing: 0,
              title: _searchActive
                  ? TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      onChanged: _onSearchChanged,
                      onSubmitted: (_) => _submitSearch(),
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: '搜索当前数据库',
                        border: InputBorder.none,
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                    )
                  : InkWell(
                      onTap: _showDatabasePicker,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.dataset_outlined, size: 18),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _sourceTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.expand_more, size: 20),
                          ],
                        ),
                      ),
                    ),
              actions: _searchActive
                  ? [
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: '清空搜索',
                          onPressed: () {
                            _searchController.clear();
                            _clearSearch();
                          },
                        ),
                      IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        tooltip: '退出搜索',
                        onPressed: _closeSearch,
                      ),
                    ]
                  : [
                      IconButton(
                        icon: const Icon(Icons.travel_explore),
                        tooltip: '全文搜索',
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const PrivateSearchScreen(),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: '搜索',
                        onPressed: _openSearch,
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: '刷新',
                        onPressed: _loadRows,
                      ),
                    ],
            ),
      body: Stack(
        children: [
          _privateSearchBridge.buildHiddenWebView(),
          Positioned.fill(child: _buildContent()),
        ],
      ),
      floatingActionButton: _currentNavIndex == 0 &&
              _selectedPage == null &&
              _sourceId != '__recent__' &&
              !_searchActive
          ? FloatingActionButton.extended(
              onPressed: _creatingPage ? null : _createPage,
              icon: _creatingPage
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.note_add_outlined),
              label: Text(_creatingPage ? '创建中' : '新建页面'),
            )
          : null,
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
        controller: _scrollController,
        slivers: [
          if (_searchActive)
            SliverToBoxAdapter(child: _buildSearchScopeBar())
          else if (_views.length > 1)
            SliverToBoxAdapter(child: _buildViewBar()),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
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
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text(
                      _searchQuery.isEmpty
                          ? '这里还没有页面'
                          : _searchScope == 'all'
                              ? '全部库中没有匹配页面'
                              : '当前库中没有匹配页面',
                    ),
                    const SizedBox(height: 8),
                    const Text(
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
                    _searchActive && _searchScope == 'all'
                        ? '${_sourceLabelForPage(page)} · 最后编辑 ${_formatDateTime(page['last_edited_time']?.toString())}'
                        : '最后编辑 ${_formatDateTime(page['last_edited_time']?.toString())}',
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
    var databasesFuture = _ensureDatabasesLoaded();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return SafeArea(
              child: FutureBuilder<void>(
                future: databasesFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('数据库列表加载失败'),
                          const SizedBox(height: 8),
                          Text(
                            '${snapshot.error}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () {
                              setSheetState(() {
                                databasesFuture = _ensureDatabasesLoaded();
                              });
                            },
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    );
                  }

                  return _buildDatabasePickerList(sheetContext);
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDatabasePickerList(BuildContext sheetContext) {
    return ListView(
      shrinkWrap: true,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('选择数据源'),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('最近页面'),
          trailing: _sourceId == '__recent__' ? const Icon(Icons.check) : null,
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

  Future<void> _openPageInExternalBrowser() async {
    final pageId = _selectedPage?['id']?.toString();
    if (pageId == null || pageId.isEmpty) return;

    final pagePath = pageId.replaceAll('-', '');
    final url = Uri.parse('https://www.notion.so/$pagePath');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (error) {
      await AppLogger.log('Home', '打开外部浏览器失败: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开浏览器')),
        );
      }
    }
  }

  Future<void> _confirmLogout() async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入 Token 才能访问你的 Notion。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _logout();
  }

  String? _titlePropertyName(Map<String, dynamic> source) {
    final properties = source['properties'];
    if (properties is! Map) return null;

    for (final entry in properties.entries) {
      final property = entry.value;
      if (property is Map && property['type'] == 'title') {
        return entry.key.toString();
      }
    }
    return null;
  }

  Future<void> _createPage() async {
    final source = _selectedSource;
    if (source == null || _sourceId == '__recent__') return;

    final titleProperty = _titlePropertyName(source);
    if (titleProperty == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前数据源没有标题属性')),
      );
      return;
    }

    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('新建页面 · $_sourceTitle'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '页面标题',
              hintText: '输入标题',
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (title == null || !mounted) return;
    final trimmedTitle = title.trim();

    setState(() => _creatingPage = true);
    try {
      final response = await NotionClient.post('/pages', body: {
        'parent': {'data_source_id': _sourceId},
        'properties': {
          titleProperty: {
            'title': [
              {
                'type': 'text',
                'text': {'content': trimmedTitle.isEmpty ? '无标题' : trimmedTitle},
              }
            ],
          },
        },
      });
      NotionClient.ensureSuccess(response, operation: '创建页面');

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final page = Map<String, dynamic>.from(data);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已创建：${_pageTitle(page)}')),
      );
      await _openPageInBrowser(page);
      if (mounted) unawaited(_loadRows());
    } catch (error) {
      await AppLogger.log('Home', '创建页面失败: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建页面失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _creatingPage = false);
    }
  }

  Future<void> _autoCheckForUpdates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(UpdateService.autoUpdatePreferenceKey) ?? true)) {
      return;
    }

    try {
      final updateInfo = await UpdateService.checkForUpdate();
      if (updateInfo == null || !mounted) return;
      await showUpdatePrompt(context, updateInfo);
    } catch (_) {
      // A failed background update check must not interrupt normal startup.
    }
  }

  Widget _buildSettings() {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AboutSection(),
          const SizedBox(height: 8),
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
        Card(
          child: SwitchListTile(
            title: const Text('页面布局宽度调试日志'),
            subtitle: const Text('开启后记录 Notion 页面宽度修复过程，需先开启调试日志'),
            value: AppLogger.isLayoutDebugEnabled,
            onChanged: AppLogger.isEnabled
                ? (value) async {
                    await AppLogger.setLayoutDebugEnabled(value);
                    setState(() {});
                  }
                : null,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('退出登录', style: TextStyle(color: Colors.red)),
            onTap: _confirmLogout,
          ),
        ),
      ],
    );
  }
}
