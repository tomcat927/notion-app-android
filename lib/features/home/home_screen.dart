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

  List<Map<String, dynamic>> _pages = [];
  Map<String, dynamic>? _selectedPage;
  List<dynamic>? _pageBlocks;
  String? _nextCursor;
  bool _hasMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchPages();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (_hasMore && !_loadingMore) {
        _fetchMorePages();
      }
    }
  }

  Future<void> _fetchPages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AppLogger.log('Home', '开始获取页面列表（首页）');

      final response = await NotionClient.post('/search', body: {
        'filter': {'property': 'object', 'value': 'page'},
        'sort': {'direction': 'descending', 'timestamp': 'last_edited_time'},
        'page_size': 50,
      });

      await AppLogger.log('Home', 'API 响应状态: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = List<Map<String, dynamic>>.from(data['results'] ?? []);
        await AppLogger.log('Home', '获取到 ${results.length} 个页面, has_more: ${data['has_more']}');

        setState(() {
          _pages = results;
          _nextCursor = data['next_cursor'];
          _hasMore = data['has_more'] == true;
          _loading = false;
        });
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      await AppLogger.log('Home', '获取页面失败: $e');
      if (e is TokenExpiredException && mounted) {
        await NotionAuth.removeToken();
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (_) => false,
        );
        return;
      }
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _fetchMorePages() async {
    if (_nextCursor == null) return;

    setState(() => _loadingMore = true);

    try {
      await AppLogger.log('Home', '加载更多页面: cursor=$_nextCursor');

      final response = await NotionClient.post('/search', body: {
        'filter': {'property': 'object', 'value': 'page'},
        'sort': {'direction': 'descending', 'timestamp': 'last_edited_time'},
        'start_cursor': _nextCursor,
        'page_size': 50,
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = List<Map<String, dynamic>>.from(data['results'] ?? []);
        await AppLogger.log('Home', '追加 ${results.length} 个页面');

        setState(() {
          _pages.addAll(results);
          _nextCursor = data['next_cursor'];
          _hasMore = data['has_more'] == true;
          _loadingMore = false;
        });
      }
    } catch (e) {
      await AppLogger.log('Home', '加载更多失败: $e');
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadPageContent(Map<String, dynamic> page) async {
    setState(() {
      _selectedPage = page;
      _pageBlocks = null;
      _loading = true;
    });

    try {
      final pageId = page['id'];
      await AppLogger.log('Home', '加载页面内容: $pageId');

      final response = await NotionClient.get('/blocks/$pageId/children?page_size=100');
      await AppLogger.log('Home', '页面内容响应: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final blocks = data['results'] as List? ?? [];

        setState(() {
          _pageBlocks = blocks;
          _loading = false;
        });
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      await AppLogger.log('Home', '加载页面内容失败: $e');
      if (e is TokenExpiredException && mounted) {
        await NotionAuth.removeToken();
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (_) => false,
        );
        return;
      }
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
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedPage != null ? _pageTitle(_selectedPage!) : 'Notion App'),
        leading: _selectedPage != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selectedPage = null),
              )
            : null,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchPages),
          IconButton(icon: const Icon(Icons.bug_report), onPressed: _showDebugLogs),
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
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _currentNavIndex,
            onDestinationSelected: (index) {
              setState(() => _currentNavIndex = index);
              if (index == 0) _fetchPages();
            },
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.article_outlined), selectedIcon: Icon(Icons.article), label: Text('页面')),
              NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('设置')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_selectedPage != null) return _buildPageContent();
    if (_currentNavIndex == 1) return _buildSettings();

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
            Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _fetchPages, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_pages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('没有找到页面'),
            const SizedBox(height: 8),
            const Text('请确保集成已关联到你的 Notion 页面', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _pages.length + (_hasMore || _loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _pages.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final page = _pages[index];
        final title = _pageTitle(page);
        final lastEdited = page['last_edited_time']?.toString() ?? '';

        return Card(
          child: ListTile(
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('最后编辑: $lastEdited', style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _loadPageContent(page),
          ),
        );
      },
    );
  }

  Widget _buildPageContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final markdown = _pageBlocks != null ? _blocksToMarkdown(_pageBlocks!) : '（加载中...）';

    return Markdown(
      data: markdown,
      padding: const EdgeInsets.all(24),
      selectable: true,
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
}
