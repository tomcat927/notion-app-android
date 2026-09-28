import 'dart:convert';

/// 页面内搜索的单条匹配结果。
class InPageSearchMatch {
  const InPageSearchMatch({
    required this.index,
    required this.context,
    required this.blockId,
    required this.matchText,
  });

  final int index;
  final String context;
  final String blockId;
  final String matchText;

  factory InPageSearchMatch.fromJson(Map<String, dynamic> json) {
    return InPageSearchMatch(
      index: (json['index'] as num?)?.toInt() ?? 0,
      context: json['context']?.toString() ?? '',
      blockId: json['blockId']?.toString() ?? '',
      matchText: json['matchText']?.toString() ?? '',
    );
  }
}

/// 页面内搜索的完整结果集。
class InPageSearchResult {
  const InPageSearchResult({
    required this.matches,
    required this.total,
    this.error,
  });

  final List<InPageSearchMatch> matches;
  final int total;
  final String? error;

  factory InPageSearchResult.fromJson(Map<String, dynamic> json) {
    final rawMatches = json['matches'] as List? ?? const [];
    return InPageSearchResult(
      matches: rawMatches
          .whereType<Map>()
          .map((m) => InPageSearchMatch.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString(),
    );
  }

  static InPageSearchResult parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return InPageSearchResult.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return const InPageSearchResult(matches: [], total: 0);
  }
}

// ---------------------------------------------------------------------------
//  JavaScript 脚本生成器
//
//  以下函数生成注入到 WebView 中的 JS 代码。两组脚本共用同一套高亮
//  CSS 动画基础设施（pulse 动画），确保需求一（搜索跳转）和需求二
//  （页面内检索）的视觉表现一致。
// ---------------------------------------------------------------------------

/// 高亮 CSS 样式的注入脚本，只需注入一次。
const String kHighlightStyleScript = r'''
(function() {
  if (document.getElementById('notion-search-highlight-style')) return;
  var style = document.createElement('style');
  style.id = 'notion-search-highlight-style';
  style.textContent = [
    '@keyframes notion-highlight-pulse {',
    '  0% { background-color: rgba(255, 213, 79, 0.8); }',
    '  30% { background-color: rgba(255, 213, 79, 0.45); }',
    '  100% { background-color: transparent; }',
    '}',
    '.notion-search-highlight-pulse {',
    '  animation: notion-highlight-pulse 3s ease-out forwards;',
    '  border-radius: 4px;',
    '}',
    '.notion-search-overlay {',
    '  position: fixed;',
    '  background: rgba(255, 213, 79, 0.5);',
    '  border: 2px solid rgba(255, 193, 7, 0.8);',
    '  border-radius: 3px;',
    '  pointer-events: none;',
    '  z-index: 99999;',
    '  transition: opacity 0.4s ease-out;',
    '}'
  ].join('\n');
  document.head.appendChild(style);
})();
''';

/// 生成定位到指定 block 的 JS 脚本（需求一）。
///
/// 优先通过 [data-block-id] 精确定位；若找不到则用 snippet 文本兜底搜索。
String buildHighlightBlockScript({
  required String blockId,
  String? snippet,
}) {
  final escapedBlockId = _jsEscape(blockId);
  final escapedSnippet = _jsEscape(snippet ?? '');
  return '''
(function() {
  var blockId = "$escapedBlockId";
  var snippet = "$escapedSnippet";

  function highlightElement(el) {
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    el.classList.add('notion-search-highlight-pulse');
    setTimeout(function() {
      el.classList.remove('notion-search-highlight-pulse');
    }, 3000);
  }

  function expandToggles(block) {
    var toggle = block.closest('.notion-toggle-block');
    if (!toggle) return;
    var btn = toggle.querySelector('.notion-toggle');
    if (btn) {
      var children = toggle.querySelector('.notion-toggle-block__children');
      if (children && children.offsetParent === null) {
        btn.click();
      }
    }
  }

  var attempts = 0;
  function tryHighlight() {
    attempts++;
    if (blockId) {
      var block = document.querySelector('[data-block-id="' + blockId + '"]');
      if (block) {
        expandToggles(block);
        setTimeout(function() { highlightElement(block); }, 150);
        return;
      }
    }
    if (snippet && snippet.length > 2) {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode: function(node) {
          var parent = node.parentElement;
          if (!parent) return NodeFilter.FILTER_REJECT;
          var tag = parent.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
          if (node.textContent.indexOf(snippet) < 0) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      while (walker.nextNode()) {
        highlightElement(walker.currentNode.parentElement);
        return;
      }
    }
    if (attempts < 12) {
      setTimeout(tryHighlight, 500);
    }
  }
  tryHighlight();
})();
''';
}

/// 生成页面内搜索的 JS 脚本（需求二）。
///
/// 使用 TreeWalker 遍历文本节点，收集所有匹配项的上下文、block ID
/// 和 Range 对象（存储在 window.__notionInPageSearchRanges 中）。
/// 结果通过 JS Channel 回传给 Flutter。
String buildInPageSearchScript({
  required String query,
  required String channelName,
}) {
  final escapedQuery = _jsEscape(query);
  return '''
(function() {
  var query = "$escapedQuery";
  var channelName = "$channelName";
  if (!query || query.length < 1) {
    if (window[channelName]) {
      window[channelName].postMessage(JSON.stringify({ matches: [], total: 0 }));
    }
    return;
  }

  var lowerQuery = query.toLowerCase();
  var ranges = [];
  var results = [];
  var maxResults = 100;

  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode: function(node) {
      var parent = node.parentElement;
      if (!parent) return NodeFilter.FILTER_REJECT;
      var tag = parent.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
      var text = node.textContent;
      if (!text || text.trim().length < 1) return NodeFilter.FILTER_REJECT;
      if (text.toLowerCase().indexOf(lowerQuery) < 0) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }
  });

  while (walker.nextNode() && results.length < maxResults) {
    var text = walker.currentNode.textContent;
    var lowerText = text.toLowerCase();
    var pos = 0;
    while ((pos = lowerText.indexOf(lowerQuery, pos)) >= 0) {
      if (results.length >= maxResults) break;
      var contextStart = Math.max(0, pos - 40);
      var contextEnd = Math.min(text.length, pos + query.length + 40);
      var prefix = contextStart > 0 ? '\\u2026' : '';
      var suffix = contextEnd < text.length ? '\\u2026' : '';
      var context = prefix + text.substring(contextStart, contextEnd) + suffix;

      var range = document.createRange();
      range.setStart(walker.currentNode, pos);
      range.setEnd(walker.currentNode, pos + query.length);
      ranges.push(range);

      var el = walker.currentNode.parentElement;
      var blockEl = el ? el.closest('[data-block-id]') : null;

      results.push({
        index: results.length,
        context: context,
        blockId: blockEl ? blockEl.getAttribute('data-block-id') : '',
        matchText: text.substring(pos, pos + query.length)
      });

      pos += query.length;
    }
  }

  window.__notionInPageSearchRanges = ranges;
  if (window[channelName]) {
    window[channelName].postMessage(JSON.stringify({ matches: results, total: results.length }));
  }
})();
''';
}

/// 生成滚动到指定匹配项并高亮的 JS 脚本（需求二）。
///
/// 通过 Range 对象获取匹配文本的像素坐标，创建临时 overlay 高亮层，
/// 不修改 Notion 的 DOM 结构。
String buildScrollToMatchScript(int matchIndex) {
  return '''
(function() {
  var ranges = window.__notionInPageSearchRanges || [];
  var range = ranges[$matchIndex];
  if (!range) return;

  var el = range.startContainer;
  if (el.nodeType === Node.TEXT_NODE) {
    el = el.parentElement;
  }
  if (el) {
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  var existing = document.querySelectorAll('.notion-search-overlay');
  existing.forEach(function(el) { el.remove(); });

  setTimeout(function() {
    var newRect = range.getBoundingClientRect();
    var overlay = document.createElement('div');
    overlay.className = 'notion-search-overlay';
    overlay.style.position = 'fixed';
    overlay.style.left = newRect.left + 'px';
    overlay.style.top = newRect.top + 'px';
    overlay.style.width = newRect.width + 'px';
    overlay.style.height = Math.max(newRect.height, 4) + 'px';
    document.body.appendChild(overlay);
    setTimeout(function() {
      overlay.style.opacity = '0';
      setTimeout(function() { overlay.remove(); }, 500);
    }, 2000);
  }, 400);
})();
''';
}

/// 生成清除页面内搜索状态的 JS 脚本。
const String kClearInPageSearchScript = r'''
(function() {
  window.__notionInPageSearchRanges = [];
  var overlays = document.querySelectorAll('.notion-search-overlay');
  overlays.forEach(function(el) { el.remove(); });
})();
''';

String _jsEscape(String value) {
  return value
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r')
      .replaceAll('\t', '\\t');
}
