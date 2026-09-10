import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/app_logger.dart';

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

  static const String _mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/141.0.0.0 Mobile Safari/537.36';

  @override
  State<NotionPageBrowserScreen> createState() =>
      _NotionPageBrowserScreenState();
}

class _NotionPageBrowserScreenState extends State<NotionPageBrowserScreen> {
  late final WebViewController _controller;
  double _progress = 0;
  bool _hasError = false;
  String _errorDescription = '';

  @override
  void initState() {
    super.initState();
      _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(NotionPageBrowserScreen._mobileUserAgent)
      ..enableZoom(true)
      ..setBackgroundColor(Theme.of(context).scaffoldBackgroundColor)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress.toDouble());
          },
          onNavigationRequest: _handleNavigation,
          onPageFinished: (_) {
            unawaited(_applyAppShell());
            if (mounted && _hasError) {
              setState(() {
                _hasError = false;
                _errorDescription = '';
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true || !mounted) return;
            setState(() {
              _hasError = true;
              _errorDescription = error.description;
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(NotionPageBrowserScreen.pageUrl(widget.pageId)));

    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController)
          .setOnShowFileSelector(_onShowFileSelector);
    }
  }

  Future<List<String>> _onShowFileSelector(FileSelectorParams params) async {
    final hasImage = params.acceptTypes.any(
      (type) => type.startsWith('image/'),
    );

    if (hasImage) {
      try {
        final picker = ImagePicker();
        if (params.mode == FileSelectorMode.openMultiple) {
          final images = await picker.pickMultiImage();
          return images.map((image) => image.path).toList();
        }
        final image = await picker.pickImage(source: ImageSource.gallery);
        if (image == null) return const [];
        return [image.path];
      } catch (error) {
        await AppLogger.log('Browser', '图片选择失败: $error');
        return const [];
      }
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
      );
      if (result == null) return const [];
      return result.files
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();
    } catch (error) {
      await AppLogger.log('Browser', '文件选择失败: $error');
      return const [];
    }
  }

  Future<void> _applyAppShell() async {
    await _controller.runJavaScript('''
(() => {
  const styleId = 'notion-app-shell-style';
  let style = document.getElementById(styleId);
  if (!style) {
    style = document.createElement('style');
    style.id = styleId;
    document.head.appendChild(style);
  }

  style.textContent = `
    html, body {
      width: 100% !important;
      max-width: 100vw !important;
      overflow-x: hidden !important;
    }
    .notion-sidebar-container,
    .notion-sidebar {
      display: none !important;
    }
    .notion-frame,
    .notion-scroller.vertical,
    .notion-page-content {
      width: 100% !important;
      max-width: 100vw !important;
      margin-left: 0 !important;
      margin-right: 0 !important;
      padding-left: 16px !important;
      padding-right: 16px !important;
    }
  `;
})();
''');
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
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
