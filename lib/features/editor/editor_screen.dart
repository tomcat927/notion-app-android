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
  bool _initialized = false;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (_initialized) setState(() => _loadProgress = progress);
          },
          onPageStarted: (url) {
            if (!_initialized || url.startsWith('about:')) return;
            AppLogger.log('Editor', '加载: $url');
            setState(() {
              _loading = true;
              _loadFailed = false;
            });
          },
          onPageFinished: (url) {
            if (url.startsWith('about:')) return;
            AppLogger.log('Editor', '完成: $url');
            setState(() {
              _loading = false;
              _loadFailed = false;
            });
          },
          onWebResourceError: (error) {
            if (!_initialized) return;
            AppLogger.log('Editor', '加载错误: ${error.description} (${error.errorCode})');
            setState(() => _loadFailed = true);
          },
        ),
      );

    _initWithCleanUserAgent();
  }

  /// 系统 WebView 默认 UA 带 `; wv` 和 `Version/4.0` 标记，
  /// 且内置 WebView 内核版本往往落后多个大版本（如 Chrome/117）。
  /// Notion 服务端要求浏览器版本接近最新，落后太多或带 WebView 标记都会被拒绝。
  /// 先读取真实 UA，清理标记并将 Chrome 版本号提升到最新稳定版，再加载目标页面。
  Future<void> _initWithCleanUserAgent() async {
    try {
      await _controller.loadRequest(Uri.parse('about:blank'));
      await Future.delayed(const Duration(milliseconds: 300));

      final raw = await _controller.runJavaScriptReturningResult('navigator.userAgent');
      final rawUa = raw.toString().replaceAll('"', '');
      final cleanUa = _cleanUserAgent(rawUa);
      AppLogger.log('Editor', '清理后 UA: $cleanUa');

      await _controller.setUserAgent(cleanUa);
      _initialized = true;
    } catch (e) {
      AppLogger.log('Editor', 'UA 初始化失败: $e');
      _initialized = true;
    }

    await _loadPage();
  }

  String _cleanUserAgent(String ua) {
    var result = ua.replaceFirst(RegExp(r'; wv'), '');
    result = result.replaceFirst(RegExp(r'Version/\d+(\.\d+)*\s'), '');
    result = result.replaceFirst(
      RegExp(r'Chrome/\d+(\.\d+)*'),
      'Chrome/151.0.7922.71',
    );
    return result;
  }

  Future<void> _loadPage() async {
    final url = 'https://www.notion.so/${widget.pageId}';
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    await _controller.loadRequest(Uri.parse(url));
  }

  Future<void> _refresh() async {
    if (_initialized) {
      await _controller.reload();
    } else {
      await _loadPage();
    }
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
