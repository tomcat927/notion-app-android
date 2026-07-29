import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/notion_auth.dart';
import '../../core/notion_client.dart';
import '../../core/app_logger.dart';
import '../auth/login_screen.dart';

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
  Map<String, dynamic>? _selectedDb;

  List<Map<String, dynamic>> _pages = [];
  Map<String, dynamic>? _selectedPage;
  List<dynamic>? _pageBlocks;
  bool _editing = false;
  final Map<String, TextEditingController> _controllers = {};
  String? _nextCursor;
  bool _hasMore = false;
  String _titleProperty = 'Name';
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchDatabases();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (_hasMore && !_loadingMore && _selectedDb != null) {
        _fetchMorePages();
      }
    }
  }

  Future<void> _fetchDatabases() async {
    setState(() => _loading = true);
    try {
      final response = await NotionClient.post('/search', body: {
        'filter': {'property': 'object', 'value': 'database'},
        'page_size': 100,
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final dbs = List<Map<String, dynamic>>.from(data['results'] ?? []);

        setState(() {
          _databases = dbs;
          _loading = false;
        });

        if (dbs.isNotEmpty) {
          _selectDatabase(dbs.first);
        }
      }
    } catch (e) {
      await AppLogger.log('Home', '获取数据库失败: $e');
      if (_handleTokenExpired(e)) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _selectDatabase(Map<String, dynamic> db) async {
    setState(() {
      _selectedDb = db;
      _pages = [];
      _pageBlocks = null;
      _selectedPage = null;
    });

    final titleProp = _findTitleProperty(db);
    _titleProperty = titleProp;

    await _fetchPages(db['id']);
  }

  String _findTitleProperty(Map<String, dynamic> db) {
    final props = db['properties'] as Map<String, dynamic>? ?? {};
    for (final entry in props.entries) {
      if ((entry.value as Map)['type'] == 'title') {
        return entry.key;
      }
    }
    return 'Name';
  }

  Future<void> _fetchPages(String dbId, {String? cursor}) async {
    setState(() { _loading = true; _error = null; });

    try {
      final body = <String, dynamic>{
        'sorts': [{'timestamp': 'last_edited_time', 'direction': 'descending'}],
        'page_size': 50,
      };
      if (cursor != null) body['start_cursor'] = cursor;

      final response = await NotionClient.post('/databases/$dbId/query', body: body);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = List<Map<String, dynamic>>.from(data['results'] ?? []);

        if (cursor == null) {
          setState(() {
            _pages = results;
            _nextCursor = data['next_cursor'];
            _hasMore = data['has_more'] == true;
            _loading = false;
          });
        } else {
          setState(() {
            _pages.addAll(results);
            _nextCursor = data['next_cursor'];
            _hasMore = data['has_more'] == true;
            _loadingMore = false;
          });
        }
      }
    } catch (e) {
      await AppLogger.log('Home', '获取页面失败: $e');
      if (_handleTokenExpired(e)) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _fetchMorePages() async {
    if (_nextCursor == null || _selectedDb == null) return;
    setState(() => _loadingMore = true);
    await _fetchPages(_selectedDb!['id'], cursor: _nextCursor);
  }

  bool _handleTokenExpired(Object e) {
    if (e is TokenExpiredException && mounted) {
      NotionAuth.removeToken();
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
      return true;
    }
    return false;
  }

  Future<void> _createPage() async {
    if (_selectedDb == null) return;

    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建页面'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '页面标题', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('创建')),
        ],
      ),
    );

    if (result == null || result.trim().isEmpty) return;

    try {
      final body = {
        'parent': {'database_id': _selectedDb!['id']},
        'properties': {
          _titleProperty: {
            'title': [{'text': {'content': result.trim()}}]
          }
        }
      };

      final response = await NotionClient.post('/pages', body: body);
      if (response.statusCode == 200) {
        _fetchPages(_selectedDb!['id']);
      }
    } catch (e) {
      await AppLogger.log('Home', '创建页面失败: $e');
    }
  }

  Future<void> _loadPageContent(Map<String, dynamic> page) async {
    setState(() { _selectedPage = page; _pageBlocks = null; _loading = true; });

    try {
      final pageId = page['id'];
      final response = await NotionClient.get('/blocks/$pageId/children?page_size=100');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _pageBlocks = data['results'] as List? ?? [];
          _loading = false;
        });
      }
    } catch (e) {
      await AppLogger.log('Home', '加载内容失败: $e');
      if (_handleTokenExpired(e)) return;
      setState(() { _error = e.toString(); _loading = false; });
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
    return '无标题';
  }

  String _dbTitle(Map<String, dynamic> db) {
    try {
      final title = db['title'] as List? ?? [];
      return title.map((t) => t['plain_text'] ?? '').join('');
    } catch (_) {}
    return '数据库';
  }

  String _blocksToMarkdown(List<dynamic> blocks) {
    final buffer = StringBuffer();
    for (final block in blocks) {
      final type = block['type'] as String? ?? '';
      final content = block[type] as Map<String, dynamic>? ?? {};
      final richText = content['rich_text'] as List? ?? [];

      switch (type) {
        case 'heading_1': buffer.writeln('# ${_plain(richText)}'); break;
        case 'heading_2': buffer.writeln('## ${_plain(richText)}'); break;
        case 'heading_3': buffer.writeln('### ${_plain(richText)}'); break;
        case 'paragraph': buffer.writeln(_plain(richText)); break;
        case 'bulleted_list_item': buffer.writeln('- ${_plain(richText)}'); break;
        case 'numbered_list_item': buffer.writeln('1. ${_plain(richText)}'); break;
        case 'to_do': buffer.writeln('- [${content['checked'] == true ? 'x' : ' '}] ${_plain(richText)}'); break;
        case 'code': buffer.writeln('```\n${_plain(richText)}\n```'); break;
        case 'divider': buffer.writeln('---'); break;
        default: buffer.writeln(_plain(richText));
      }
      buffer.writeln();
    }
    return buffer.toString().isEmpty ? '（空页面）' : buffer.toString();
  }

  String _plain(List richText) => richText.map((t) => t['plain_text'] ?? '').join('');

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
            onPressed: () async { await AppLogger.clearLogs(); if (ctx.mounted) Navigator.pop(ctx); setState(() {}); },
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
    return Scaffold(
      appBar: _selectedPage != null
          ? AppBar(
              title: Text(_pageTitle(_selectedPage!)),
              leading: _editing
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() { _editing = false; _loadPageContent(_selectedPage!); }),
                    )
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() => _selectedPage = null),
                    ),
              actions: [
                if (_editing)
                  IconButton(
                    icon: const Icon(Icons.check),
                    onPressed: _saveEdits,
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () {
                      _controllers.clear();
                      if (_pageBlocks != null) {
                        for (final block in _pageBlocks!) {
                          if (!_isEditable(block)) continue;
                          _controllers[block['id']] = TextEditingController(text: _blockPlainText(block));
                        }
                      }
                      setState(() => _editing = true);
                    },
                  ),
              ],
            )
          : null,
      body: _currentNavIndex == 1
          ? Scaffold(
              appBar: AppBar(
                title: const Text('设置'),
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _currentNavIndex = 0),
                ),
              ),
              body: _buildSettings(),
            )
          : _selectedPage != null
              ? _buildPageContent()
              : _selectedDb != null
                  ? _buildPageList()
                  : _buildDbList(),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('数据库', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: _loading && _databases.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _databases.length,
                        itemBuilder: (context, index) {
                          final db = _databases[index];
                          final isSelected = _selectedDb?['id'] == db['id'];
                          return ListTile(
                            title: Text(_dbTitle(db), maxLines: 1, overflow: TextOverflow.ellipsis),
                            selected: isSelected,
                            selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
                            onTap: () {
                              Navigator.pop(context);
                              _selectDatabase(db);
                            },
                          );
                        },
                      ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text('设置'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _currentNavIndex = 1);
                },
              ),
              ListTile(
                leading: const Icon(Icons.bug_report),
                title: const Text('调试日志'),
                onTap: () {
                  Navigator.pop(context);
                  _showDebugLogs();
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('退出登录'),
                onTap: () {
                  Navigator.pop(context);
                  _logout();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDbList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('从左侧选择数据库', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('刷新'),
          onPressed: _fetchDatabases,
        ),
      ]),
    );
  }

  Widget _buildPageList() {
    return Scaffold(
      appBar: AppBar(
        title: Text(_dbTitle(_selectedDb!)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _fetchPages(_selectedDb!['id'])),
          IconButton(icon: const Icon(Icons.bug_report), onPressed: _showDebugLogs),
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 'logout') _logout(); },
            itemBuilder: (_) => [const PopupMenuItem(value: 'logout', child: Text('退出登录'))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createPage,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(_error!, style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: () => _fetchPages(_selectedDb!['id']), child: const Text('重试')),
                ]))
              : _pages.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text('该数据库暂无页面'),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('创建第一个页面'),
                        onPressed: _createPage,
                      ),
                    ]))
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: _pages.length + (_hasMore || _loadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= _pages.length) {
                          return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                        }
                        final page = _pages[index];
                        return Card(
                          child: ListTile(
                            title: Text(_pageTitle(page), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(page['last_edited_time']?.toString() ?? '', style: const TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _loadPageContent(page),
                          ),
                        );
                      },
                    ),
    );
  }

  Widget _buildSettings() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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

  bool _isEditable(dynamic block) {
    final type = block['type'] as String? ?? '';
    return ['paragraph', 'heading_1', 'heading_2', 'heading_3', 'bulleted_list_item', 'numbered_list_item', 'to_do'].contains(type);
  }

  String _blockPlainText(dynamic block) {
    final type = block['type'] as String? ?? '';
    final content = block[type] as Map<String, dynamic>? ?? {};
    final richText = content['rich_text'] as List? ?? [];
    return richText.map((t) => t['plain_text'] ?? '').join('');
  }

  Future<void> _saveEdits() async {
    if (_pageBlocks == null) return;

    setState(() => _loading = true);

    try {
      await AppLogger.log('Edit', '开始保存编辑');
      for (final block in _pageBlocks!) {
        if (!_isEditable(block)) continue;
        final id = block['id'] as String;
        final controller = _controllers[id];
        if (controller == null) continue;

        final type = block['type'] as String;
        final body = {
          type: {'rich_text': [{'type': 'text', 'text': {'content': controller.text}}]}
        };

        await AppLogger.log('Edit', '更新块 $id: $type -> ${controller.text}');
        await NotionClient.patch('/blocks/$id', body: body);
      }

      await AppLogger.log('Home', '保存编辑完成');

      setState(() { _editing = false; });
      await _loadPageContent(_selectedPage!);
    } catch (e) {
      await AppLogger.log('Home', '保存编辑失败: $e');
      setState(() => _loading = false);
    }
  }

  Widget _buildPageContent() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_editing && _pageBlocks != null) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _pageBlocks!.length,
        itemBuilder: (context, index) {
          final block = _pageBlocks![index];
          final type = block['type'] as String? ?? 'paragraph';
          final id = block['id'] as String;

          if (!_isEditable(block)) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(type, style: const TextStyle(color: Colors.grey, fontSize: 11)),
            );
          }

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: TextField(
              autofocus: index == 0,
              controller: _controllers[id],
              decoration: InputDecoration(
                labelText: _editLabel(type),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: type.startsWith('heading') ? 1 : null,
              style: TextStyle(
                fontSize: type == 'heading_1' ? 24 : type == 'heading_2' ? 20 : type == 'heading_3' ? 16 : 14,
                fontWeight: type.startsWith('heading') ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        },
      );
    }

    final markdown = _pageBlocks != null ? _blocksToMarkdown(_pageBlocks!) : '';
    return Markdown(data: markdown, padding: const EdgeInsets.all(24), selectable: true);
  }

  String _editLabel(String type) {
    switch (type) {
      case 'heading_1': return '标题1';
      case 'heading_2': return '标题2';
      case 'heading_3': return '标题3';
      case 'paragraph': return '段落';
      case 'bulleted_list_item': return '列表';
      case 'numbered_list_item': return '编号';
      case 'to_do': return '待办';
      default: return type;
    }
  }
}
