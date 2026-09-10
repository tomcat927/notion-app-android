import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

class NotionPageBrowserScreen extends StatefulWidget {
  const NotionPageBrowserScreen({
    super.key,
    required this.pageId,
    required this.title,
  });

  final String pageId;
  final String title;

  static String pageUrl(String pageId) {
    final compactId = pageId.trim().replaceAll('-', '');
    return 'https://www.notion.so/$compactId';
  }

  @override
  State<NotionPageBrowserScreen> createState() =>
      _NotionPageBrowserScreenState();
}

class _NotionPageBrowserScreenState extends State<NotionPageBrowserScreen> {
  late final WebViewController _controller;
  late String _title;
  double _progress = 0;
  bool _hasError = false;
  String _errorDescription = '';

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Theme.of(context).scaffoldBackgroundColor)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress.toDouble());
          },
          onTitleChanged: (title) {
            final nextTitle = title.trim();
            if (!mounted ||
                nextTitle.isEmpty ||
                nextTitle.toLowerCase() == 'notion') {
              return;
            }
            setState(() => _title = nextTitle);
          },
          onNavigationRequest: _handleNavigation,
          onPageFinished: (_) {
            if (mounted && _hasError) {
              setState(() {
                _hasError = false;
                _errorDescription = '';
              });
            }
          },
          onWebResourceError: (error) {
            if (!error.isForMainFrame || !mounted) return;
            setState(() {
              _hasError = true;
              _errorDescription = error.description;
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(NotionPageBrowserScreen.pageUrl(widget.pageId)));
  }

  NavigationDecision _handleNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;

    if (_isNotionUri(uri)) {
      return NavigationDecision.navigate;
    }

    if (_isExternalUri(uri)) {
      unawaited(_launchExternal(uri));
    }

    return NavigationDecision.prevent;
  }

  bool _isNotionUri(Uri uri) {
    final host = uri.host.toLowerCase();
    return _matchesDomain(host, 'notion.so') ||
        _matchesDomain(host, 'notion.com') ||
        _matchesDomain(host, 'notion.site') ||
        _matchesDomain(host, 'notionusercontent.com');
  }

  bool _matchesDomain(String host, String domain) {
    return host == domain || host.endsWith('.$domain');
  }

  bool _isExternalUri(Uri uri) {
    const schemes = {'http', 'https', 'mailto', 'tel', 'sms'};
    return schemes.contains(uri.scheme.toLowerCase());
  }

  Future<void> _launchExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开链接：${uri.toString()}')),
      );
    }
  }

  Future<void> _goBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _handleSystemBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleSystemBack());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _goBack,
          ),
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _controller.reload,
            ),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(value: _progress / 100),
                )
              : null,
        ),
        body: _hasError
            ? _buildErrorView()
            : WebViewWidget(controller: _controller),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('页面加载失败'),
            if (_errorDescription.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _errorDescription,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _controller.reload,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
