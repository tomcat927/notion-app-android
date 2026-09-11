import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
  static const MethodChannel _webViewChannel = MethodChannel(
    'com.notion.app/webview',
  );

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
      ..setOnConsoleMessage((message) {
        if (message.message.contains('[NOTION-LAYOUT]')) {
          unawaited(AppLogger.log('Browser', message.message));
        }
      })
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
    await AppLogger.log(
      'Browser',
      '文件选择器: mode=${params.mode}, acceptTypes=${params.acceptTypes}, hasImage=$hasImage',
    );

    if (hasImage) {
      try {
        final picker = ImagePicker();
        if (params.mode == FileSelectorMode.openMultiple) {
          final images = await picker.pickMultiImage();
          final paths = <String>[];
          for (final image in images) {
            final copied = await _copyToWebViewTemp(image.path);
            if (copied != null) paths.add(copied);
          }
          await AppLogger.log('Browser', '即将返回给 WebView: $paths');
          _scheduleFileInputDiagnostic();
          return paths;
        }
        final image = await picker.pickImage(source: ImageSource.gallery);
        if (image == null) {
          await AppLogger.log('Browser', '图片选择取消');
          return const [];
        }
        final copied = await _copyToWebViewTemp(image.path);
        if (copied == null) return const [];
        await AppLogger.log('Browser', '即将返回给 WebView: [$copied]');
        _scheduleFileInputDiagnostic();
        return [copied];
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
      final paths = result.files
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();
      final contentUris = <String>[];
      for (final path in paths) {
        final uri = await _toContentUri(path);
        contentUris.add(uri ?? path);
      }
      await AppLogger.log('Browser', '选中文件: $paths');
      await AppLogger.log('Browser', 'content URIs: $contentUris');
      _scheduleFileInputDiagnostic();
      return contentUris;
    } catch (error) {
      await AppLogger.log('Browser', '文件选择失败: $error');
      return const [];
    }
  }

  /// 延迟检查 file input 是否真的收到了文件，用于排查上传失败原因。
  void _scheduleFileInputDiagnostic() {
    unawaited(AppLogger.log('Browser', '诊断已调度: 2 秒后检查 file input'));
    Future.delayed(const Duration(seconds: 2), () async {
      await AppLogger.log('Browser', '诊断执行中: mounted=$mounted');
      if (!mounted) return;
      try {
        final count = await _controller.runJavaScriptReturningResult(
          'document.querySelectorAll("input[type=file]").length',
        ).timeout(const Duration(seconds: 3));
        await AppLogger.log('Browser', '诊断: file input 数量 = $count');

        final detail = await _controller.runJavaScriptReturningResult('''
(function() {
  var inputs = document.querySelectorAll('input[type=file]');
  var result = [];
  for (var i = 0; i < inputs.length; i++) {
    var names = [];
    for (var j = 0; j < inputs[i].files.length; j++) {
      names.push(inputs[i].files[j].name + ':' + inputs[i].files[j].size);
    }
    result.push({count: inputs[i].files.length, names: names});
  }
  return JSON.stringify(result);
})()
''').timeout(const Duration(seconds: 3));
        await AppLogger.log('Browser', '诊断: file input 详情 = $detail');
      } catch (error) {
        await AppLogger.log('Browser', '诊断: JS 执行失败 $error');
      }
    });
  }

  /// image_picker 会把文件复制到 cache 的 UUID 子目录里，
  /// Android WebView 沙箱可能无权读取，统一复制到 cache 根目录。
  Future<String?> _copyToWebViewTemp(String sourcePath) async {
    try {
      final sourceFile = File(sourcePath);
      if (!sourceFile.existsSync()) {
        await AppLogger.log('Browser', '源文件不存在: $sourcePath');
        return null;
      }
      final size = sourceFile.lengthSync();
      if (size == 0) {
        await AppLogger.log('Browser', '源文件为空: $sourcePath');
        return null;
      }

      final tempDir = await getTemporaryDirectory();
      final fileName =
          'webview_upload_${DateTime.now().millisecondsSinceEpoch}'
          '${p.extension(sourcePath)}';
      final newPath = p.join(tempDir.path, fileName);
      await sourceFile.copy(newPath);

      try {
        final chmod = await Process.run('chmod', ['644', newPath]);
        await AppLogger.log(
          'Browser',
          'chmod 644: exit=${chmod.exitCode}, stderr=${chmod.stderr}',
        );
      } catch (error) {
        await AppLogger.log('Browser', 'chmod 失败: $error');
      }

      final copiedFile = File(newPath);
      await AppLogger.log(
        'Browser',
        '文件已复制: $newPath, 大小: ${copiedFile.lengthSync()}',
      );
      return await _toContentUri(newPath) ?? newPath;
    } catch (error) {
      await AppLogger.log('Browser', '复制文件失败: $error');
      return null;
    }
  }

  /// 将文件路径转为 content:// URI，绕过 WebView 的 file:// 访问限制。
  Future<String?> _toContentUri(String filePath) async {
    try {
      final uri = await _webViewChannel.invokeMethod<String>(
        'getFileUri',
        {'path': filePath},
      );
      if (uri != null && uri.isNotEmpty) {
        await AppLogger.log('Browser', 'content URI: $uri');
        return uri;
      }
    } catch (error) {
      await AppLogger.log('Browser', '获取 content URI 失败: $error');
    }
    return null;
  }

  Future<void> _applyAppShell() async {
    await _controller.runJavaScript('''
(() => {
  if (window.__notionWidthFix) return;
  window.__notionWidthFix = true;

  // CSS 基础层：隐藏侧边栏
  const styleId = 'notion-app-shell-style';
  let style = document.getElementById(styleId);
  if (!style) {
    style = document.createElement('style');
    style.id = styleId;
    document.head.appendChild(style);
  }

  style.textContent = `
    .notion-sidebar-container,
    .notion-sidebar {
      display: none !important;
    }
  `;

  // JS 层：直接修改内联样式，绕过 Notion 的 React 重渲染约束
  function fixContentWidth() {
    var content = document.querySelector('.notion-page-content');
    if (!content) return;

    // 诊断日志：记录 content 及其子元素的布局信息
    var vw = window.innerWidth;
    var cs = window.getComputedStyle(content);
    var rect = content.getBoundingClientRect();
    var log = 'vw=' + vw + ' content: rect.left=' + Math.round(rect.left) +
      ' width=' + Math.round(rect.width) +
      ' maxW=' + cs.maxWidth +
      ' padL=' + cs.paddingLeft +
      ' padR=' + cs.paddingRight +
      ' marL=' + cs.marginLeft +
      ' marR=' + cs.marginRight;
    var kids = content.querySelectorAll(':scope > div, :scope > section');
    for (var k = 0; k < kids.length && k < 3; k++) {
      var kcs = window.getComputedStyle(kids[k]);
      var krect = kids[k].getBoundingClientRect();
      log += ' | child' + k + ': rect.left=' + Math.round(krect.left) +
        ' width=' + Math.round(krect.width) +
        ' maxW=' + kcs.maxWidth +
        ' padL=' + kcs.paddingLeft +
        ' padR=' + kcs.paddingRight +
        ' marL=' + kcs.marginLeft +
        ' marR=' + kcs.marginRight;
    }
    console.log('[NOTION-LAYOUT] ' + log);

    // 诊断：记录父容器链的布局信息
    var pEl = content;
    var pLog = [];
    while (pEl && pEl !== document.body) {
      var pcs = window.getComputedStyle(pEl);
      pLog.push({
        tag: pEl.tagName,
        cls: (pEl.className || '').toString().split(' ')[0].substring(0, 25),
        rectL: Math.round(pEl.getBoundingClientRect().left),
        padL: pcs.paddingLeft,
        padR: pcs.paddingRight,
        marL: pcs.marginLeft,
        marR: pcs.marginRight
      });
      pEl = pEl.parentElement;
    }
    log += ' | parents: ' + JSON.stringify(pLog);
    // 从 content 向上遍历所有父容器，移除宽度约束
    var el = content;
    while (el && el !== document.body) {
      var pelCs = window.getComputedStyle(el);
      if (parseFloat(pelCs.paddingLeft || 0) > 0) el.style.paddingLeft = '0px';
      if (parseFloat(pelCs.paddingRight || 0) > 0) el.style.paddingRight = '0px';
      if (parseFloat(pelCs.marginLeft || 0) > 0) el.style.marginLeft = '0px';
      if (parseFloat(pelCs.marginRight || 0) > 0) el.style.marginRight = '0px';
      if (pelCs.maxWidth !== 'none' && pelCs.maxWidth !== '100%') {
        el.style.maxWidth = '100%';
      }
      el = el.parentElement;
    }

    // content 本身
    content.style.maxWidth = '100%';
    content.style.paddingLeft = '12px';
    content.style.paddingRight = '12px';
    content.style.marginLeft = '0px';
    content.style.marginRight = '0px';

    // content 的直接子元素：移除 Notion 设的内联 max-width/margin
    var children = content.querySelectorAll(':scope > div, :scope > section');
    for (var i = 0; i < children.length; i++) {
      var child = children[i];
      if (child.style) {
        if (child.style.maxWidth && child.style.maxWidth !== '100%') {
          child.style.maxWidth = '100%';
        }
        if (child.style.marginLeft && child.style.marginLeft !== '0px' && child.style.marginLeft !== 'auto') {
          child.style.marginLeft = '0px';
        }
        if (child.style.marginRight && child.style.marginRight !== '0px' && child.style.marginRight !== 'auto') {
          child.style.marginRight = '0px';
        }
        if (parseFloat(child.style.paddingLeft || 0) > 24) child.style.paddingLeft = '0px';
        if (parseFloat(child.style.paddingRight || 0) > 24) child.style.paddingRight = '0px';
      }
    }

    // 遍历 content 内所有非媒体元素，移除小于 90vw 的 max-width
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT);
    var node;
    while (node = walker.nextNode()) {
      if (node.tagName === 'IMG' || node.tagName === 'VIDEO' ||
          node.tagName === 'IFRAME' || node.tagName === 'SVG' ||
          node.tagName === 'CANVAS') continue;
      if (node.closest('.notion-asset-wrapper')) continue;

      var cs = window.getComputedStyle(node);
      var mw = cs.maxWidth;
      if (mw && mw !== 'none' && mw.endsWith('px')) {
        var px = parseFloat(mw);
        if (px > 0 && px < window.innerWidth * 0.9) {
          node.style.maxWidth = '100%';
        }
      }
    }
  }

  // 立即执行一次
  fixContentWidth();

  // 每 2 秒重新应用，应对 React 重渲染
  setInterval(fixContentWidth, 2000);
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
