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
  static final Uri _notionLoginUri = Uri.parse('https://www.notion.com/login');
  static final Uri _notionWorkspaceUri = Uri.parse('https://www.notion.com');

  late final WebViewController _controller;
  bool _loading = true;
  int _loadProgress = 0;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            AppLogger.log('WebView', '加载: $url');
            setState(() => _loading = true);
          },
          onPageFinished: (url) {
            AppLogger.log('WebView', '完成: $url');
            setState(() => _loading = false);
          },
          onProgress: (progress) => setState(() => _loadProgress = progress),
          onWebResourceError: (error) {
            AppLogger.log('WebView', '错误: ${error.description} (${error.errorCode})');
          },
          onNavigationRequest: (request) {
            final host = Uri.tryParse(request.url)?.host;
            if (host == 'www.notion.so' ||
                host == 'notion.so' ||
                host == 'www.notion.com' ||
                host == 'notion.com') {
              return NavigationDecision.navigate;
            }
            launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(_notionLoginUri);
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
                  _controller.loadRequest(_notionWorkspaceUri);
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('刷新'),
                onTap: () { Navigator.pop(context); _refresh(); },
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
}
