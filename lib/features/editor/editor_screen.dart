import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/app_logger.dart';
import '../../core/notion_client.dart';

List<Map<String, dynamic>> _plainRichTextPayload(String text) {
  if (text.isEmpty) return const [];

  const maxChunkLength = 2000;
  final chunks = <String>[];
  var current = StringBuffer();
  var currentLength = 0;

  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    if (currentLength + character.length > maxChunkLength) {
      chunks.add(current.toString());
      current = StringBuffer();
      currentLength = 0;
    }
    current.write(character);
    currentLength += character.length;
  }
  if (currentLength > 0) chunks.add(current.toString());
  if (chunks.length > 100) {
    throw const FormatException('单个块的文本不能超过 200000 个字符');
  }

  return chunks
      .map(
        (chunk) => <String, dynamic>{
          'type': 'text',
          'text': {'content': chunk},
        },
      )
      .toList();
}

class EditorScreen extends StatefulWidget {
  final String pageId;
  final String title;

  const EditorScreen({super.key, required this.pageId, required this.title});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  static const int _maxNestedDepth = 12;

  final List<_BlockDraft> _blocks = [];
  bool _loading = true;
  bool _saving = false;
  bool _discardConfirmed = false;
  String? _loadError;
  String? _saveError;

  bool get _hasChanges => _blocks.any((block) => block.hasChanges);
  bool get _willReplaceFormatting =>
      _blocks.any((block) => block.hasFormatting && block.textChanged);

  @override
  void initState() {
    super.initState();
    _loadBlocks();
  }

  @override
  void dispose() {
    _disposeBlocks(_blocks);
    super.dispose();
  }

  Future<void> _loadBlocks() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
        _saveError = null;
      });
    }

    final loaded = <_BlockDraft>[];
    try {
      await AppLogger.log('Editor', '通过 API 加载页面块: ${widget.pageId}');
      await _loadChildren(widget.pageId, 0, loaded);

      if (!mounted) {
        _disposeBlocks(loaded);
        return;
      }

      _disposeBlocks(_blocks);
      _blocks
        ..clear()
        ..addAll(loaded);
      for (final block in _blocks) {
        block.controller?.addListener(_onDraftChanged);
      }

      setState(() => _loading = false);
      await AppLogger.log('Editor', '页面块加载完成，共 ${_blocks.length} 块');
    } catch (error) {
      _disposeBlocks(loaded);
      await AppLogger.log('Editor', '页面块加载失败: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> _loadChildren(
    String parentId,
    int depth,
    List<_BlockDraft> target,
  ) async {
    String? cursor;

    do {
      final endpoint = Uri(
        path: '/blocks/$parentId/children',
        queryParameters: {
          'page_size': '100',
          if (cursor != null) 'start_cursor': cursor,
        },
      ).toString();
      final response = await NotionClient.get(endpoint);
      NotionClient.ensureSuccess(response, operation: '加载页面内容');

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? const [];
      for (final value in results) {
        if (value is! Map) continue;
        final raw = Map<String, dynamic>.from(value);
        final block = _BlockDraft.fromJson(raw, depth: depth);
        target.add(block);

        final hasChildren = raw['has_children'] == true;
        if (hasChildren &&
            depth < _maxNestedDepth &&
            _shouldLoadChildren(block.type)) {
          await _loadChildren(block.id!, depth + 1, target);
        }
      }

      cursor = data['has_more'] == true ? data['next_cursor'] as String? : null;
    } while (cursor != null);
  }

  bool _shouldLoadChildren(String type) {
    return type != 'child_page' && type != 'child_database';
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  void _addParagraph() {
    final block = _BlockDraft.newParagraph();
    block.controller!.addListener(_onDraftChanged);
    setState(() => _blocks.add(block));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) block.focusNode?.requestFocus();
    });
  }

  void _removeNewBlock(_BlockDraft block) {
    if (!block.isNew) return;
    setState(() => _blocks.remove(block));
    block.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_hasChanges) return;
    if (_willReplaceFormatting && !await _confirmFormattingReplacement()) {
      return;
    }
    if (!mounted) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _saveError = null;
    });

    var savedCount = 0;
    try {
      for (final block in _blocks.where((item) => !item.isNew)) {
        if (!block.hasChanges) continue;

        final content = <String, dynamic>{};
        if (block.textChanged) {
          content['rich_text'] = _plainRichTextPayload(block.text);
        }
        if (block.type == 'to_do' && block.checkedChanged) {
          content['checked'] = block.checked;
        }

        final response = await NotionClient.patch(
          '/blocks/${block.id}',
          body: {block.type: content},
        );
        NotionClient.ensureSuccess(
          response,
          operation: '保存${block.label}',
        );
        block.acceptChanges();
        savedCount++;
      }

      final newBlocks = _blocks.where((block) => block.isNew).toList();
      for (var offset = 0; offset < newBlocks.length; offset += 100) {
        final end = offset + 100 < newBlocks.length
            ? offset + 100
            : newBlocks.length;
        final batch = newBlocks.sublist(offset, end);
        final response = await NotionClient.patch(
          '/blocks/${widget.pageId}/children',
          body: {
            'children': batch.map((block) => block.toNewBlockJson()).toList(),
          },
        );
        NotionClient.ensureSuccess(response, operation: '新增页面块');

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List? ?? const [];
        if (results.length != batch.length) {
          throw const FormatException('Notion 返回的新增块数量不一致');
        }
        for (var index = 0; index < batch.length; index++) {
          final result = results[index] as Map;
          batch[index].markCreated(result['id'] as String);
          savedCount++;
        }
      }

      await AppLogger.log('Editor', '保存完成，共更新 $savedCount 块');
      await _loadBlocks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存到 Notion')),
      );
    } catch (error) {
      await AppLogger.log('Editor', '保存失败: $error');
      if (!mounted) return;
      setState(() => _saveError = error.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败，请检查错误后重试')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmClose() async {
    if (_saving) return false;
    if (!_hasChanges) return true;

    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('返回后，本次修改不会保存到 Notion。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<bool> _confirmFormattingReplacement() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('部分行内格式将被移除'),
        content: const Text(
          '你修改的块包含加粗、链接或 mention 等行内格式。'
          '通过 API 保存文本后，这些块会转换为纯文本。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续保存'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _discardConfirmed || (!_saving && !_hasChanges),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _saving) return;
        if (!await _confirmClose() || !mounted) return;

        setState(() => _discardConfirmed = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop(result);
        });
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.check),
                tooltip: '保存',
                onPressed: _hasChanges ? _save : null,
              ),
          ],
        ),
        body: _buildBody(),
        bottomNavigationBar: _loading || _loadError != null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _addParagraph,
                    icon: const Icon(Icons.add),
                    label: const Text('添加段落'),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 48),
              const SizedBox(height: 16),
              Text(
                '无法加载页面内容',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _loadBlocks,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (_saveError != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _saveError!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _saveError = null),
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: _blocks.isEmpty
              ? Center(
                  child: Text(
                    '空页面',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _blocks.length,
                  itemBuilder: (context, index) {
                    final block = _blocks[index];
                    return block.isEditable
                        ? _buildEditableBlock(block)
                        : _buildReadOnlyBlock(block);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEditableBlock(_BlockDraft block) {
    final colorScheme = Theme.of(context).colorScheme;
    final visibleDepth = block.depth > 6 ? 6 : block.depth;
    final indent = 12.0 + visibleDepth * 16.0;

    return Padding(
      padding: EdgeInsets.only(left: indent, right: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              height: 48,
              child: block.type == 'to_do'
                  ? Checkbox(
                      value: block.checked,
                      onChanged: _saving
                          ? null
                          : (value) {
                              setState(() => block.checked = value ?? false);
                            },
                    )
                  : Icon(block.icon, size: 20, color: colorScheme.outline),
            ),
            Expanded(
              child: TextField(
                controller: block.controller,
                focusNode: block.focusNode,
                enabled: !_saving,
                minLines: block.type == 'code' ? 3 : 1,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: block.textStyle(Theme.of(context).textTheme),
                decoration: InputDecoration(
                  hintText: block.label,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
            if (block.hasFormatting && block.textChanged)
              IconButton(
                onPressed: null,
                icon: const Icon(Icons.format_clear, size: 19),
                tooltip: '保存后此块的行内格式将转为纯文本',
              ),
            if (block.isNew)
              IconButton(
                onPressed: _saving ? null : () => _removeNewBlock(block),
                icon: const Icon(Icons.close, size: 20),
                tooltip: '移除',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadOnlyBlock(_BlockDraft block) {
    final visibleDepth = block.depth > 6 ? 6 : block.depth;
    final indent = 12.0 + visibleDepth * 16.0;
    final text = block.displayText;

    return Padding(
      padding: EdgeInsets.only(left: indent, right: 12),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: Icon(block.icon, size: 20),
        title: Text(text.isEmpty ? block.label : text),
        subtitle: Text('${block.label} · 只读'),
      ),
    );
  }

  void _disposeBlocks(Iterable<_BlockDraft> blocks) {
    for (final block in blocks) {
      block.dispose();
    }
  }
}

class _BlockDraft {
  static const Set<String> _editableTypes = {
    'paragraph',
    'heading_1',
    'heading_2',
    'heading_3',
    'bulleted_list_item',
    'numbered_list_item',
    'to_do',
    'toggle',
    'quote',
    'callout',
    'code',
  };

  String? id;
  final String type;
  final int depth;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  String originalText;
  bool originalChecked;
  bool checked;
  bool hasFormatting;
  final String displayText;

  _BlockDraft._({
    required this.id,
    required this.type,
    required this.depth,
    required this.controller,
    required this.focusNode,
    required this.originalText,
    required this.originalChecked,
    required this.checked,
    required this.hasFormatting,
    required this.displayText,
  });

  factory _BlockDraft.fromJson(
    Map<String, dynamic> block, {
    required int depth,
  }) {
    final type = block['type'] as String? ?? 'unsupported';
    final content = block[type] is Map
        ? Map<String, dynamic>.from(block[type] as Map)
        : <String, dynamic>{};
    final richText = content['rich_text'] as List? ?? const [];
    final text = _richTextToPlain(richText);
    final editable = _editableTypes.contains(type);
    final id = block['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Notion 返回了缺少 ID 的页面块');
    }

    return _BlockDraft._(
      id: id,
      type: type,
      depth: depth,
      controller: editable ? TextEditingController(text: text) : null,
      focusNode: editable ? FocusNode() : null,
      originalText: text,
      originalChecked: content['checked'] == true,
      checked: content['checked'] == true,
      hasFormatting: _hasFormatting(richText),
      displayText: text.isNotEmpty ? text : _fallbackText(type, content),
    );
  }

  factory _BlockDraft.newParagraph() {
    return _BlockDraft._(
      id: null,
      type: 'paragraph',
      depth: 0,
      controller: TextEditingController(),
      focusNode: FocusNode(),
      originalText: '',
      originalChecked: false,
      checked: false,
      hasFormatting: false,
      displayText: '',
    );
  }

  bool get isNew => id == null;
  bool get isEditable => controller != null;
  String get text => controller?.text ?? displayText;
  bool get textChanged => isEditable && text != originalText;
  bool get checkedChanged => type == 'to_do' && checked != originalChecked;
  bool get hasChanges => isNew || textChanged || checkedChanged;

  String get label {
    switch (type) {
      case 'paragraph':
        return '段落';
      case 'heading_1':
        return '一级标题';
      case 'heading_2':
        return '二级标题';
      case 'heading_3':
        return '三级标题';
      case 'bulleted_list_item':
        return '项目符号列表';
      case 'numbered_list_item':
        return '编号列表';
      case 'to_do':
        return '待办';
      case 'toggle':
        return '折叠块';
      case 'quote':
        return '引用';
      case 'callout':
        return '标注';
      case 'code':
        return '代码';
      case 'divider':
        return '分隔线';
      case 'image':
        return '图片';
      case 'video':
        return '视频';
      case 'file':
        return '文件';
      case 'bookmark':
        return '书签';
      case 'child_page':
        return '子页面';
      case 'child_database':
        return '子数据库';
      case 'column_list':
        return '分栏';
      case 'column':
        return '栏';
      default:
        return type;
    }
  }

  IconData get icon {
    switch (type) {
      case 'heading_1':
      case 'heading_2':
      case 'heading_3':
        return Icons.title;
      case 'bulleted_list_item':
        return Icons.format_list_bulleted;
      case 'numbered_list_item':
        return Icons.format_list_numbered;
      case 'toggle':
        return Icons.expand_more;
      case 'quote':
        return Icons.format_quote;
      case 'callout':
        return Icons.campaign_outlined;
      case 'code':
        return Icons.code;
      case 'divider':
        return Icons.horizontal_rule;
      case 'image':
        return Icons.image_outlined;
      case 'video':
        return Icons.videocam_outlined;
      case 'file':
        return Icons.attach_file;
      case 'bookmark':
        return Icons.bookmark_border;
      case 'child_page':
        return Icons.description_outlined;
      case 'child_database':
        return Icons.table_chart_outlined;
      case 'column_list':
      case 'column':
        return Icons.view_column_outlined;
      default:
        return Icons.notes;
    }
  }

  TextStyle? textStyle(TextTheme textTheme) {
    switch (type) {
      case 'heading_1':
        return textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold);
      case 'heading_2':
        return textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold);
      case 'heading_3':
        return textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold);
      case 'code':
        return textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
      case 'quote':
        return textTheme.bodyLarge?.copyWith(fontStyle: FontStyle.italic);
      default:
        return textTheme.bodyLarge;
    }
  }

  Map<String, dynamic> toNewBlockJson() {
    return {
      'object': 'block',
      'type': 'paragraph',
      'paragraph': {
        'rich_text': _plainRichTextPayload(text),
      },
    };
  }

  void acceptChanges() {
    final formattingWasReplaced = textChanged;
    originalText = text;
    originalChecked = checked;
    if (formattingWasReplaced) hasFormatting = false;
  }

  void markCreated(String blockId) {
    id = blockId;
    originalText = text;
    originalChecked = checked;
  }

  void dispose() {
    controller?.dispose();
    focusNode?.dispose();
  }

  static String _richTextToPlain(List richText) {
    return richText.map((item) {
      if (item is! Map) return '';
      return item['plain_text']?.toString() ?? '';
    }).join();
  }

  static bool _hasFormatting(List richText) {
    for (final item in richText) {
      if (item is! Map) continue;
      if (item['type'] != 'text' || item['href'] != null) return true;
      final annotations = item['annotations'];
      if (annotations is Map &&
          (annotations['bold'] == true ||
              annotations['italic'] == true ||
              annotations['strikethrough'] == true ||
              annotations['underline'] == true ||
              annotations['code'] == true ||
              (annotations['color'] != null &&
                  annotations['color'] != 'default'))) {
        return true;
      }
    }
    return false;
  }

  static String _fallbackText(String type, Map<String, dynamic> content) {
    if (type == 'child_page' || type == 'child_database') {
      return content['title']?.toString() ?? '';
    }
    if (type == 'equation') {
      return content['expression']?.toString() ?? '';
    }
    if (type == 'bookmark' || type == 'embed' || type == 'link_preview') {
      return content['url']?.toString() ?? '';
    }
    return '';
  }
}
