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
import '../../core/cache_cleanup_service.dart';
import '../../core/native_browser.dart';
import '../../core/remote_log_service.dart';
import '../../core/update_service.dart';
import '../auth/login_screen.dart';
import '../browser/notion_page_browser_screen.dart';
import '../editor/editor_screen.dart';
import '../settings/update_section.dart';
import '../settings/update_dialog.dart';
import '../settings/about_section.dart';
import '../search/private_search_screen.dart';
import '../search/private_search_bridge.dart';
import '../search/recent_pages_service.dart';

class DatabaseView {
  const DatabaseView({
    required this.id,
    required this.label,
    this.isNative = false,
    this.filter,
    this.sorts = const [],
    this.groupBy,
  });

  final String id;
  final String label;
  final bool isNative;
  final Map<String, dynamic>? filter;
  final List<Map<String, dynamic>> sorts;
  final Map<String, dynamic>? groupBy;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
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
  bool _openExternalLinksInApp = false;
  bool _showElementInspector = false;
  bool _cleaningCache = false;
  RemoteLogConfig? _remoteLogConfig;
  bool _remoteLogBusy = false;
  String? _pendingBrowserRefreshPageId;
  bool _monthGroupsAutoExpanded = true;
  bool _loadingAll = false;
  final Map<String, bool> _monthExpansionOverrides = {};
  final Map<String, String> _monthGroupTitles = {};
  final Map<String, GlobalKey> _pageRowKeys = {};
  final Map<String, GlobalKey> _monthRowKeys = {};

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _privateSearchBridge.reset();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    unawaited(_initialize());
    unawaited(_autoCheckForUpdates());
    unawaited(_loadBrowserPreferences());
    unawaited(_loadMonthGroupPreference());
    unawaited(_loadRemoteLogConfig());
  }

  Future<void> _loadRemoteLogConfig() async {
    final config = await RemoteLogService.loadConfig();
    if (!mounted) return;
    setState(() => _remoteLogConfig = config);
  }

  Future<void> _setRemoteLogEnabled(bool value) async {
    await RemoteLogService.setEnabled(value);
    await _loadRemoteLogConfig();
  }

  Future<void> _showRemoteLogSettings() async {
    final config = _remoteLogConfig ?? await RemoteLogService.loadConfig();
    if (!mounted) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final baseUrlController = TextEditingController(text: config.baseUrl);
    final usernameController = TextEditingController(text: config.username);
    final passwordController = TextEditingController();
    final targetPathController = TextEditingController(text: config.targetPath);
    var enabled = config.enabled;
    var busy = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('远程诊断日志'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用手动上传'),
                  subtitle: const Text('默认仅上传经过脱敏的诊断日志'),
                  value: enabled,
                  onChanged: busy
                      ? null
                      : (value) => setDialogState(() => enabled = value),
                ),
                TextField(
                  controller: baseUrlController,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'OpenList 服务地址',
                    hintText: 'https://openlist.example.com',
                  ),
                ),
                TextField(
                  controller: usernameController,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                TextField(
                  controller: passwordController,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    hintText: '留空则保留已保存密码',
                  ),
                ),
                TextField(
                  controller: targetPathController,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: '远程目录',
                    hintText: '/notion-app/logs',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '密码和登录令牌保存在系统安全存储中。日志上传前会移除凭据、Cookie、URL、邮箱、页面 UUID 和本地路径。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      try {
                        await RemoteLogService.testConnection(
                          baseUrl: baseUrlController.text,
                          username: usernameController.text,
                          password: passwordController.text,
                        );
                        if (!dialogContext.mounted) return;
                        scaffoldMessenger.showSnackBar(
                          const SnackBar(content: Text('OpenList 连接成功')),
                        );
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        scaffoldMessenger.showSnackBar(
                          SnackBar(content: Text('连接失败：$error')),
                        );
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() => busy = false);
                        }
                      }
                    },
              child: const Text('测试连接'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      try {
                        await RemoteLogService.saveConfig(
                          enabled: enabled,
                          baseUrl: baseUrlController.text,
                          username: usernameController.text,
                          password: passwordController.text,
                          targetPath: targetPathController.text,
                        );
                        if (!dialogContext.mounted) return;
                        Navigator.pop(dialogContext);
                        await _loadRemoteLogConfig();
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        scaffoldMessenger.showSnackBar(
                          SnackBar(content: Text('保存失败：$error')),
                        );
                        setDialogState(() => busy = false);
                      }
                    },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    baseUrlController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    targetPathController.dispose();
  }

  Future<void> _uploadRemoteDiagnosticLog() async {
    if (_remoteLogBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('上传脱敏诊断日志？'),
        content: const Text(
          '只会手动上传当前诊断快照。凭据、Cookie、URL、邮箱、页面 UUID 和本地路径会在上传前移除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('上传'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _remoteLogBusy = true);
    try {
      final result = await RemoteLogService.uploadDiagnosticLog();
      await _loadRemoteLogConfig();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('诊断日志已上传：${result.remotePath}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _remoteLogBusy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    unawaited(CacheCleanupService.cleanupStartupCaches());

    final pageId = _pendingBrowserRefreshPageId;
    if (pageId == null || pageId.isEmpty) return;

    _pendingBrowserRefreshPageId = null;
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 600), () async {
        if (!mounted) return;
        await _refreshVisiblePage(pageId, reason: 'browser_return');
      }),
    );
  }

  Future<void> _loadBrowserPreferences() async {
    final openExternalLinksInApp = await NativeBrowser.openExternalLinksInApp();
    final showElementInspector = await NativeBrowser.showElementInspector();
    if (!mounted) return;
    setState(() {
      _openExternalLinksInApp = openExternalLinksInApp;
      _showElementInspector = showElementInspector;
    });
  }

  Future<void> _loadMonthGroupPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _monthGroupsAutoExpanded =
          prefs.getBool('month_groups_auto_expand') ?? true;
    });
  }

  Future<void> _setMonthGroupsAutoExpanded(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('month_groups_auto_expand', value);
    if (!mounted) return;
    setState(() {
      _monthGroupsAutoExpanded = value;
      _monthExpansionOverrides.clear();
    });
  }

  Future<void> _setOpenExternalLinksInApp(bool value) async {
    await NativeBrowser.setOpenExternalLinksInApp(value);
    if (!mounted) return;
    setState(() => _openExternalLinksInApp = value);
    unawaited(
      AppLogger.log(
        'Settings',
        '外部网页在 App 内打开: ${value ? 'on' : 'off'}',
      ),
    );
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
    final aGroupBy = a.groupBy == null ? '' : jsonEncode(a.groupBy);
    final bGroupBy = b.groupBy == null ? '' : jsonEncode(b.groupBy);
    if (aGroupBy != bGroupBy) return true;
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
      final format = detail['format'];
      final rawGroupBy = detail['group_by'] ??
          (format is Map ? format['group_by'] : null) ??
          (format is Map ? format['group'] : null);

      return DatabaseView(
        id: viewId,
        label: name.isEmpty ? type : name,
        isNative: true,
        filter: filter is Map<String, dynamic> ? filter : null,
        sorts: sorts is List
            ? List<Map<String, dynamic>>.from(sorts)
            : const [],
        groupBy:
            rawGroupBy is Map<String, dynamic> ? rawGroupBy : null,
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
        _loadingMore = false;
        _loadingAll = false;
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

  Future<void> _loadAllRows() async {
    if (_loading || _loadingAll || !_hasMore || _pages.isEmpty) return;

    final generation = _loadGeneration;
    setState(() => _loadingAll = true);

    try {
      while (mounted &&
          generation == _loadGeneration &&
          _hasMore &&
          _nextCursor != null) {
        final cursorBefore = _nextCursor;
        await _loadMoreRows();
        if (!mounted || generation != _loadGeneration) return;
        if (!_hasMore || _nextCursor == null || _nextCursor == cursorBefore) {
          return;
        }
      }
    } finally {
      if (mounted) {
        setState(() => _loadingAll = false);
      } else {
        _loadingAll = false;
      }
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_loading || _loadingMore || _loadingAll || !_hasMore) return;

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
    setState(() {
      _viewId = id;
      _monthExpansionOverrides.clear();
    });
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

  String? _privateSearchSeedPageId() {
    for (final page in _pages) {
      final pageId = page['id']?.toString().trim();
      if (pageId != null && pageId.isNotEmpty) return pageId;
    }
    return null;
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

  Future<void> _refreshVisiblePage(
    String pageId, {
    required String reason,
  }) async {
    final normalizedPageId = _normalizePageId(pageId);
    if (normalizedPageId.isEmpty) return;

    final existingIndex = _pages.indexWhere(
      (page) => _normalizePageId(page['id']?.toString()) == normalizedPageId,
    );
    final selectedMatches =
        _normalizePageId(_selectedPage?['id']?.toString()) == normalizedPageId;
    if (existingIndex < 0 && !selectedMatches) return;

    try {
      await AppLogger.log(
        'Home',
        '返回后刷新单条记录: reason=$reason pageId=$pageId',
      );
      final response = await NotionClient.get('/pages/$pageId');
      NotionClient.ensureSuccess(response, operation: '刷新页面信息');
      final refreshedPage = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;

      if (_isPageDeleted(refreshedPage)) {
        await _removeDeletedPage(
          normalizedPageId,
          reason: '$reason:page_response',
        );
        return;
      }

      final latestTitle = _pageTitle(refreshedPage);
      setState(() {
        final index = _pages.indexWhere(
          (page) =>
              _normalizePageId(page['id']?.toString()) == normalizedPageId,
        );
        if (index >= 0) {
          final updatedPages = List<Map<String, dynamic>>.from(_pages);
          updatedPages[index] = refreshedPage;
          _pages = updatedPages;
        }
        if (_normalizePageId(_selectedPage?['id']?.toString()) ==
            normalizedPageId) {
          _selectedPage = refreshedPage;
        }
      });
      unawaited(RecentPagesService.addRecentPage(pageId, latestTitle));
      unawaited(
        AppLogger.log(
          'Home',
          '单条记录刷新完成: pageId=$pageId title=$latestTitle',
        ),
      );
    } catch (error) {
      if (error is NotionApiException && error.statusCode == 404) {
        await _removeDeletedPage(
          normalizedPageId,
          reason: '$reason:not_found',
        );
        return;
      }
      unawaited(
        AppLogger.log(
          'Home',
          '单条记录刷新失败: pageId=$pageId error=$error',
        ),
      );
    }
  }

  String _normalizePageId(String? rawPageId) {
    if (rawPageId == null) return '';
    final match = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32}',
    ).firstMatch(rawPageId);
    final compact = (match?.group(0) ?? rawPageId)
        .replaceAll('-', '')
        .toLowerCase()
        .trim();
    return RegExp(r'^[0-9a-f]{32}$').hasMatch(compact) ? compact : '';
  }

  bool _isPageDeleted(Map<String, dynamic> page) {
    bool isTrue(Object? value) =>
        value == true || value?.toString().toLowerCase() == 'true';
    return isTrue(page['archived']) ||
        isTrue(page['in_trash']) ||
        isTrue(page['in_trashed']) ||
        isTrue(page['trashed']);
  }

  GlobalKey? _pageRowKey(String pageId) {
    if (pageId.isEmpty) return null;
    return _pageRowKeys.putIfAbsent(
      pageId,
      () => GlobalKey(debugLabel: 'home-page-row-$pageId'),
    );
  }

  GlobalKey _monthRowKey(String monthKey) {
    return _monthRowKeys.putIfAbsent(
      monthKey,
      () => GlobalKey(debugLabel: 'home-month-row-$monthKey'),
    );
  }

  String? _normalizedPageIdForRow(Object row) {
    final page = switch (row) {
      _PageRow(:final page) => page,
      _GroupedPageRow(:final page) => page,
      _ => null,
    };
    if (page == null) return null;
    return _normalizePageId(page['id']?.toString());
  }

  String? _nearbyVisibleAnchorId(
    List<Object> rows,
    int index, {
    required bool forward,
  }) {
    final step = forward ? 1 : -1;
    for (var i = index + step; i >= 0 && i < rows.length; i += step) {
      final row = rows[i];
      final String? anchor;
      if (row is _MonthGroupHeader) {
        anchor = 'month:${row.key}';
      } else {
        anchor = _normalizedPageIdForRow(row);
      }
      if (anchor == null || _rowTopForAnchor(anchor) == null) continue;
      return anchor;
    }
    return null;
  }

  String? _scrollAnchorForDeletedPage(String pageId) {
    final rows = _buildListRows();
    for (var index = 0; index < rows.length; index++) {
      if (_normalizedPageIdForRow(rows[index]) != pageId) continue;
      return _nearbyVisibleAnchorId(rows, index, forward: true) ??
          _nearbyVisibleAnchorId(rows, index, forward: false);
    }

    // A page hidden in a collapsed group can still make its empty group
    // header disappear, so anchor to the next visible row in that case.
    final pageIndex = _pages.indexWhere(
      (page) => _normalizePageId(page['id']?.toString()) == pageId,
    );
    if (pageIndex < 0) return null;
    final date = _pageGroupDate(_pages[pageIndex]);
    final monthKey =
        '${date.year}-${date.month.toString().padLeft(2, '0')}';
    final headerIndex = rows.indexWhere(
      (row) => row is _MonthGroupHeader && row.key == monthKey,
    );
    if (headerIndex < 0) return null;
    final header = rows[headerIndex];
    if (header is! _MonthGroupHeader || header.count > 1) return null;
    return _nearbyVisibleAnchorId(rows, headerIndex, forward: true) ??
        _nearbyVisibleAnchorId(rows, headerIndex, forward: false);
  }

  GlobalKey? _globalKeyForAnchor(String anchor) {
    if (anchor.startsWith('month:')) {
      return _monthRowKeys[anchor.substring(6)];
    }
    return _pageRowKeys[anchor];
  }

  double? _rowTopForAnchor(String anchor) {
    final key = _globalKeyForAnchor(anchor);
    final context = key?.currentContext;
    if (context == null) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero).dy;
  }

  void _scheduleScrollRestore({
    required String anchor,
    required double previousTop,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final newTop = _rowTopForAnchor(anchor);
      if (newTop == null) return;

      final delta = previousTop - newTop;
      if (delta.abs() < 0.5) return;
      final target = (_scrollController.offset + delta)
          .clamp(0.0, _scrollController.position.maxScrollExtent)
          .toDouble();
      if (target.isFinite) _scrollController.jumpTo(target);
    });
  }

  Future<void> _removeDeletedPage(
    String pageId, {
    required String reason,
  }) async {
    final anchor = _scrollAnchorForDeletedPage(pageId);
    final previousTop = anchor == null ? null : _rowTopForAnchor(anchor);
    if (mounted) {
      setState(() {
        _pages.removeWhere(
          (page) => _normalizePageId(page['id']?.toString()) == pageId,
        );
        _pageRowKeys.remove(pageId);
        if (_normalizePageId(_selectedPage?['id']?.toString()) == pageId) {
          _selectedPage = null;
        }
      });
      if (anchor != null && previousTop != null) {
        _scheduleScrollRestore(anchor: anchor, previousTop: previousTop);
      }
    }

    unawaited(RecentPagesService.removeRecentPage(pageId));
    unawaited(
      AppLogger.log(
        'Home',
        '检测到记录已删除并从列表移除: reason=$reason pageId=$pageId',
      ),
    );
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
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    String logs;
    try {
      logs = await AppLogger.readLogs();
    } catch (error) {
      logs = '读取日志失败：$error';
    }

    if (!mounted) return;
    navigator.pop();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('调试 / 崩溃日志'),
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
              if (mounted) setState(() {});
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

  Future<void> _setShowElementInspector(bool value) async {
    await NativeBrowser.setShowElementInspector(value);
    if (!mounted) return;
    setState(() => _showElementInspector = value);
    unawaited(
      AppLogger.log(
        'Settings',
        '网页控件诊断按钮: ${value ? 'on' : 'off'}',
      ),
    );
  }

  Future<void> _cleanupSafeCaches() async {
    if (_cleaningCache) return;

    setState(() => _cleaningCache = true);
    try {
      final report = await CacheCleanupService.cleanupSafeCaches();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已清理 ${report.readableDeletedSize} 缓存'
            '${report.webViewCacheCleared ? '，并清理 WebView 缓存' : ''}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理缓存失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _cleaningCache = false);
      }
    }
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
                          final seedPageId = _privateSearchSeedPageId();
                          unawaited(
                            AppLogger.log(
                              'Home',
                              '打开全文搜索 seedPageId=${seedPageId ?? ''}',
                            ),
                          );
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PrivateSearchScreen(
                                bridgePageId: seedPageId,
                              ),
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

    final listRows = _buildListRows();
    return RefreshIndicator(
      onRefresh: _loadRows,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          if (_searchActive)
            SliverToBoxAdapter(child: _buildSearchScopeBar())
          else if (_views.length > 1)
            SliverToBoxAdapter(child: _buildViewBar()),
          if (_monthGroupingEnabled)
            SliverToBoxAdapter(child: _buildMonthGroupControls()),
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
              itemCount: listRows.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, index) {
                final row = listRows[index];
                if (row is _LoadMoreRow) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: _loadingMore || _loadingAll
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

                if (row is _MonthGroupHeader) {
                  return ListTile(
                    key: _monthRowKey(row.key),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                    ),
                    leading: Icon(
                      row.expanded
                          ? Icons.expand_more
                          : Icons.chevron_right,
                    ),
                    title: Text(row.title),
                    subtitle: Text('${row.count} 条'),
                    onTap: () {
                      setState(() {
                        _monthExpansionOverrides[row.key] = !row.expanded;
                      });
                    },
                  );
                }

                return _buildPageListTile(
                  row is _PageRow ? row.page : (row as _GroupedPageRow).page,
                );
              },
            ),
        ],
      ),
    );
  }

  bool get _monthGroupingEnabled {
    final view = _activeView;
    if (view == null || _searchActive) return false;
    return view.label.contains('按月');
  }

  Widget _buildMonthGroupControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '自动展开月份',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Switch(
            value: _monthGroupsAutoExpanded,
            onChanged: _setMonthGroupsAutoExpanded,
          ),
          if (_hasMore) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _loadingAll ? null : _loadAllRows,
              icon: _loadingAll
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.done_all, size: 18),
              label: const Text('加载全部'),
            ),
          ],
        ],
      ),
    );
  }

  List<Object> _buildListRows() {
    if (!_monthGroupingEnabled) {
      final rows = <Object>[
        for (final page in _pages) _PageRow(page),
      ];
      if (_hasMore) rows.add(const _LoadMoreRow());
      return rows;
    }

    final groupedPages = <String, List<Map<String, dynamic>>>{};
    for (final page in _pages) {
      final date = _pageGroupDate(page);
      final key = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      final title = '${date.year}年${date.month}月';
      groupedPages.putIfAbsent(key, () => []).add(page);
      _monthGroupTitles[key] = title;
    }

    final rows = <Object>[];
    for (final entry in groupedPages.entries) {
      final key = entry.key;
      final pages = entry.value;
      final expanded = _monthExpansionOverrides.containsKey(key)
          ? _monthExpansionOverrides[key]!
          : _monthGroupsAutoExpanded;
      rows.add(
        _MonthGroupHeader(
          key: key,
          title: _monthGroupTitles[key] ?? key,
          count: pages.length,
          expanded: expanded,
        ),
      );
      if (expanded) {
        rows.addAll(pages.map((page) => _GroupedPageRow(page)));
      }
    }
    if (_hasMore) rows.add(const _LoadMoreRow());
    return rows;
  }

  DateTime _pageGroupDate(Map<String, dynamic> page) {
    final groupBy = _activeView?.groupBy;
    final properties =
        page['properties'] as Map<String, dynamic>? ?? const {};

    final propertyName = _groupByPropertyName(groupBy);
    if (propertyName != null && properties.containsKey(propertyName)) {
      final parsed = _parseDatePropertyValue(properties[propertyName]);
      if (parsed != null) return parsed;
    }

    if (_activeView?.label.contains('按月') == true) {
      for (final property in properties.values) {
        if (property is Map && property['type'] == 'created_time') {
          final parsed = _parseDatePropertyValue(property);
          if (parsed != null) return parsed;
        }
      }
      final pageCreated =
          DateTime.tryParse(page['created_time']?.toString() ?? '');
      if (pageCreated != null) return pageCreated.toLocal();
    }

    return DateTime.tryParse(page['last_edited_time']?.toString() ?? '')
            ?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  String? _groupByPropertyName(Map<String, dynamic>? groupBy) {
    if (groupBy == null) return null;
    final raw = groupBy['property'] ??
        groupBy['field'] ??
        groupBy['sub_property'];
    if (raw == null) return null;
    if (raw is Map) {
      return raw['name']?.toString() ??
          raw['id']?.toString() ??
          raw['property']?.toString();
    }
    return raw.toString();
  }

  DateTime? _parseDatePropertyValue(Object? property) {
    if (property is! Map) return null;
    final dateValue = property['date']?['start']?.toString() ??
        property['created_time']?.toString() ??
        property['last_edited_time']?.toString();
    final parsed = DateTime.tryParse(dateValue ?? '');
    return parsed?.toLocal();
  }

  Widget _buildPageListTile(Map<String, dynamic> page) {
    final pageId = _normalizePageId(page['id']?.toString());
    return ListTile(
      key: _pageRowKey(pageId),
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

    final title = _pageTitle(page);
    unawaited(RecentPagesService.addRecentPage(pageId, title));
    if (_privateSearchBridge.hasController) {
      await AppLogger.log('Home', '打开笔记前释放隐藏搜索 WebView: $pageId');
      _privateSearchBridge.reset();
    }
    await AppLogger.log('Home', '使用内嵌浏览器打开: $pageId');

    _pendingBrowserRefreshPageId = pageId;
    final opened = await NativeBrowser.openPage(pageId: pageId, title: title);
    if (opened || !mounted) return;
    _pendingBrowserRefreshPageId = null;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotionPageBrowserScreen(
          pageId: pageId,
          title: title,
        ),
      ),
    );
    if (mounted) {
      unawaited(_refreshVisiblePage(pageId, reason: 'flutter_browser_return'));
    }
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
            secondary: const Icon(Icons.open_in_browser),
            title: const Text('外部网页在 App 内打开'),
            subtitle: const Text('关闭时使用系统默认浏览器；Notion 页面始终在 App 内打开'),
            value: _openExternalLinksInApp,
            onChanged: (value) =>
                unawaited(_setOpenExternalLinksInApp(value)),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: _cleaningCache
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理缓存'),
            subtitle: const Text('清理更新包、上传临时文件和 WebView 普通缓存，不清登录状态'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_cleaningCache,
            onTap: _cleaningCache
                ? null
                : () => unawaited(_cleanupSafeCaches()),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            title: const Text('调试日志'),
            subtitle: const Text('开启后写入 API 请求和普通调试信息；崩溃日志始终保留'),
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
            title: const Text('查看调试 / 崩溃日志'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showDebugLogs,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.cloud_upload_outlined),
                title: const Text('远程诊断日志'),
                subtitle: const Text('手动上传脱敏日志到你的 OpenList'),
                value: _remoteLogConfig?.enabled ?? false,
                onChanged: _remoteLogBusy
                    ? null
                    : (value) => unawaited(_setRemoteLogEnabled(value)),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('配置 OpenList'),
                subtitle: Text(
                  _remoteLogConfig?.isConfigured == true
                      ? '${_remoteLogConfig!.baseUrl}${_remoteLogConfig!.targetPath}'
                      : '设置服务地址、专用账号和远程目录',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _remoteLogBusy ? null : _showRemoteLogSettings,
              ),
              ListTile(
                leading: _remoteLogBusy
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file_outlined),
                title: const Text('立即上传脱敏日志'),
                subtitle: Text(
                  _remoteLogConfig?.lastUploadAt == null
                      ? '不会自动上传，单次上限 2 MB'
                      : '上次上传：${_remoteLogConfig!.lastUploadAt}',
                ),
                enabled: !_remoteLogBusy &&
                    (_remoteLogConfig?.enabled ?? false) &&
                    (_remoteLogConfig?.isConfigured ?? false),
                onTap: _remoteLogBusy
                    ? null
                    : () => unawaited(_uploadRemoteDiagnosticLog()),
              ),
            ],
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
          child: SwitchListTile(
            title: const Text('网页控件诊断按钮'),
            subtitle: const Text('开启后，笔记页顶部显示“控件”按钮，用于检查网页元素；需先开启调试日志'),
            value: _showElementInspector,
            onChanged: AppLogger.isEnabled
                ? (value) =>
                    unawaited(_setShowElementInspector(value))
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

class _PageRow {
  const _PageRow(this.page);

  final Map<String, dynamic> page;
}

class _GroupedPageRow {
  const _GroupedPageRow(this.page);

  final Map<String, dynamic> page;
}

class _MonthGroupHeader {
  const _MonthGroupHeader({
    required this.key,
    required this.title,
    required this.count,
    required this.expanded,
  });

  final String key;
  final String title;
  final int count;
  final bool expanded;
}

class _LoadMoreRow {
  const _LoadMoreRow();
}
