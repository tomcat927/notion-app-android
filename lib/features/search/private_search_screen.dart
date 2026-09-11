import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../browser/notion_page_browser_screen.dart';
import 'private_search_bridge.dart';
import 'private_search_models.dart';

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
  bool _searching = false;
  String? _error;
  List<PrivateSearchHit> _hits = [];

  @override
  void initState() {
    super.initState();
    _bridge.addListener(_onBridgeChanged);
    unawaited(_bridge.start(seedPageId: widget.bridgePageId));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _bridge.removeListener(_onBridgeChanged);
    super.dispose();
  }

  void _onBridgeChanged() {
    if (mounted) setState(() {});
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

  void _reloadBridge() {
    _bridge.reload();
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
      body: Column(
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(child: _buildResults()),
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
