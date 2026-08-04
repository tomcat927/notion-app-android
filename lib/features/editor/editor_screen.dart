import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_logger.dart';

class EditorScreen extends StatefulWidget {
  final String pageId;
  final String title;

  const EditorScreen({super.key, required this.pageId, required this.title});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final WebViewController _controller;
  int _loadProgress = 0;
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();

    final url = 'https://www.notion.so/${widget.pageId}';

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            setState(() => _loadProgress = progress);
          },
          onPageStarted: (url) {
            AppLogger.log('Editor', '加载: $url');
            setState(() {
              _loading = true;
              _loadFailed = false;
            });
          },
          onPageFinished: (url) {
            AppLogger.log('Editor', '完成: $url');
            setState(() {
              _loading = false;
              _loadFailed = false;
            });
          },
          onWebResourceError: (error) {
            AppLogger.log('Editor', '加载错误: ${error.description} (${error.errorCode})');
            setState(() => _loadFailed = true);
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
  }

  Future<void> _refresh() async {
    _controller.reload();
  }

  Future<void> _goBack() async {
    if (await _controller.canGoBack()) {
      _controller.goBack();
    }
  }

  Future<void> _goForward() async {
    if (await _controller.canGoForward()) {
      _controller.goForward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
            onPressed: _goBack,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            tooltip: '前进',
            onPressed: _goForward,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_loadFailed)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 56),
                    const SizedBox(height: 16),
                    const Text('页面加载失败', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('请检查网络连接后重试', textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          else
            WebViewWidget(controller: _controller),
          if (_loading && !_loadFailed)
            LinearProgressIndicator(value: _loadProgress / 100.0),
        ],
      ),
    );
  }
}
