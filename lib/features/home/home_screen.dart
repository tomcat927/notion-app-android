import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_logger.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static final Uri _notionLoginUri = Uri.parse('https://app.notion.com/login');
  static final Uri _notionWorkspaceUri = Uri.parse('https://app.notion.com');
  static const MethodChannel _browserChannel = MethodChannel('com.notion.app/browser');
  static const String _desktopChromeUserAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  late final WebViewController _controller;
  bool _loading = true;
  bool _showUnsupportedBrowser = false;
  int _loadProgress = 0;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopChromeUserAgent)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            AppLogger.log('WebView', '加载: $url');
            setState(() {
              _loading = !_isUnsupportedBrowserUrl(url);
              _showUnsupportedBrowser = _isUnsupportedBrowserUrl(url);
            });
          },
          onPageFinished: (url) {
            AppLogger.log('WebView', '完成: $url');
            setState(() {
              _loading = false;
              _showUnsupportedBrowser = _isUnsupportedBrowserUrl(url);
            });
            _logWebViewDiagnostics();
          },
          onProgress: (progress) => setState(() => _loadProgress = progress),
          onWebResourceError: (error) {
            AppLogger.log('WebView', '错误: ${error.description} (${error.errorCode})');
          },
          onNavigationRequest: (request) {
            if (_isUnsupportedBrowserUrl(request.url)) {
              AppLogger.log('WebView', '检测到 Notion 不兼容浏览器页面');
              setState(() {
                _loading = false;
                _showUnsupportedBrowser = true;
              });
              return NavigationDecision.prevent;
            }

            final host = Uri.tryParse(request.url)?.host;
            if (_isNotionHost(host)) {
              return NavigationDecision.navigate;
            }
            launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(_notionLoginUri);
  }

  bool _isNotionHost(String? host) {
    return host == 'notion.com' ||
        host == 'notion.so' ||
        (host?.endsWith('.notion.com') ?? false) ||
        (host?.endsWith('.notion.so') ?? false);
  }

  bool _isUnsupportedBrowserUrl(String url) {
    final uri = Uri.tryParse(url);
    return _isNotionHost(uri?.host) && uri?.path.endsWith('/unsupported-browser.html') == true;
  }

  Future<void> _refresh() async {
    _controller.reload();
  }

  Future<void> _logWebViewDiagnostics() async {
    try {
      final diagnostics = await _controller.runJavaScriptReturningResult('''
        JSON.stringify({
          userAgent: navigator.userAgent,
          platform: navigator.platform,
          cookieEnabled: navigator.cookieEnabled,
          localStorage: typeof localStorage !== 'undefined',
          indexedDB: typeof indexedDB !== 'undefined',
          serviceWorker: 'serviceWorker' in navigator,
          webAssembly: typeof WebAssembly !== 'undefined',
          crypto: !!(window.crypto && window.crypto.subtle),
          crossOriginIsolated: window.crossOriginIsolated === true
        })
      ''');
      AppLogger.log('WebView', '诊断: $diagnostics');
    } catch (error) {
      AppLogger.log('WebView', '诊断失败: $error');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notion App'),
        actions: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack),
          IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _goForward),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
          IconButton(icon: const Icon(Icons.open_in_browser), onPressed: _openNotionInBrowserView),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Notion App', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.home),
                title: const Text('笔记首页'),
                onTap: () {
                  Navigator.pop(context);
                  AppLogger.log('WebView', '打开笔记首页');
                  setState(() => _showUnsupportedBrowser = false);
                  _controller.loadRequest(_notionWorkspaceUri);
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('刷新'),
                onTap: () { Navigator.pop(context); _refresh(); },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_browser),
                title: const Text('兼容浏览器打开'),
                subtitle: const Text('使用已安装的兼容浏览器访问 Notion'),
                onTap: () {
                  Navigator.pop(context);
                  _openNotionInBrowserView();
                },
              ),
              ListTile(
                leading: const Icon(Icons.bug_report),
                title: const Text('调试日志'),
                onTap: () { Navigator.pop(context); _showDebugLogs(); },
              ),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text('设置'),
                onTap: () { Navigator.pop(context); _showSettings(); },
              ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          if (_showUnsupportedBrowser)
            _UnsupportedBrowserView(onOpenBrowser: _openNotionInBrowserView)
          else
            WebViewWidget(controller: _controller),
          if (_loading)
            LinearProgressIndicator(value: _loadProgress / 100.0),
        ],
      ),
    );
  }

  void _showSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: SwitchListTile(
                  title: const Text('调试日志'),
                  subtitle: const Text('开启后将 WebView 事件写入设备日志'),
                  value: AppLogger.isEnabled,
                  onChanged: (value) async {
                    await AppLogger.setEnabled(value);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.article),
                  title: const Text('查看调试日志'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () { Navigator.pop(context); _showDebugLogs(); },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openNotionInBrowserView() async {
    AppLogger.log('WebView', '使用兼容浏览器打开 Notion: ${_notionWorkspaceUri.toString()}');
    try {
      final opened = await _browserChannel.invokeMethod<bool>(
        'openInBrowser',
        {'url': _notionWorkspaceUri.toString()},
      );
      if (opened == true) {
        AppLogger.log('WebView', '已使用首选浏览器打开 Notion');
        return;
      }
      AppLogger.log('WebView', '未找到首选浏览器，回退到系统浏览器');
    } catch (error) {
      AppLogger.log('WebView', '首选浏览器打开失败: $error');
    }

    await launchUrl(_notionWorkspaceUri, mode: LaunchMode.externalApplication);
  }
}

class _UnsupportedBrowserView extends StatelessWidget {
  const _UnsupportedBrowserView({required this.onOpenBrowser});

  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off, size: 56),
            const SizedBox(height: 16),
            const Text(
              '当前系统 WebView 无法打开 Notion',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'Notion 已将当前 WebView 跳转到不兼容浏览器页面。请使用兼容浏览器入口继续登录和编辑。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onOpenBrowser,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('用兼容浏览器打开 Notion'),
            ),
          ],
        ),
      ),
    );
  }
}
