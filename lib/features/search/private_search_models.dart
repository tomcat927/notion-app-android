import 'dart:convert';

class PrivateSearchSnippet {
  const PrivateSearchSnippet({
    required this.text,
    required this.blockId,
  });

  final String text;
  final String blockId;

  Map<String, dynamic> toJson() => {
        'text': text,
        'blockId': blockId,
      };

  factory PrivateSearchSnippet.fromJson(Map<String, dynamic> json) {
    return PrivateSearchSnippet(
      text: json['text']?.toString() ?? '',
      blockId: json['blockId']?.toString() ?? '',
    );
  }
}

class PrivateSearchHit {
  const PrivateSearchHit({
    required this.pageId,
    required this.title,
    required this.pathText,
    required this.type,
    required this.primarySnippet,
    required this.primaryBlockId,
    required this.score,
    required this.snippets,
  });

  final String pageId;
  final String title;
  final String pathText;
  final String type;
  final String primarySnippet;
  final String primaryBlockId;
  final double score;
  final List<PrivateSearchSnippet> snippets;

  Map<String, dynamic> toJson() => {
        'pageId': pageId,
        'title': title,
        'pathText': pathText,
        'type': type,
        'primarySnippet': primarySnippet,
        'primaryBlockId': primaryBlockId,
        'score': score,
        'snippets': snippets.map((snippet) => snippet.toJson()).toList(),
      };

  factory PrivateSearchHit.fromJson(Map<String, dynamic> json) {
    final rawSnippets = json['snippets'];
    final snippets = <PrivateSearchSnippet>[];
    if (rawSnippets is List) {
      for (final rawSnippet in rawSnippets) {
        if (rawSnippet is Map) {
          snippets.add(
            PrivateSearchSnippet.fromJson(
              Map<String, dynamic>.from(rawSnippet),
            ),
          );
        }
      }
    }

    return PrivateSearchHit(
      pageId: json['pageId']?.toString() ?? '',
      title: json['title']?.toString() ?? '无标题页面',
      pathText: json['pathText']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      primarySnippet: json['primarySnippet']?.toString() ?? '',
      primaryBlockId: json['primaryBlockId']?.toString() ?? '',
      score: num.tryParse(json['score']?.toString() ?? '')?.toDouble() ?? 0,
      snippets: snippets,
    );
  }
}

class PrivateSearchResponse {
  const PrivateSearchResponse({
    required this.status,
    required this.hits,
    this.error,
  });

  final int status;
  final List<PrivateSearchHit> hits;
  final String? error;
}

PrivateSearchResponse parsePrivateSearchResponse(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('搜索响应不是有效对象');
  }

  final status = int.tryParse(decoded['status']?.toString() ?? '') ?? 0;
  final error = decoded['error']?.toString();
  final rawResults = decoded['results'];
  final hits = <PrivateSearchHit>[];

  if (rawResults is List) {
    for (final rawResult in rawResults) {
      if (rawResult is! Map) continue;

      final rawSnippets = rawResult['snippets'];
      final snippets = <PrivateSearchSnippet>[];
      if (rawSnippets is List) {
        for (final rawSnippet in rawSnippets) {
          if (rawSnippet is! Map) continue;
          final text = _cleanText(rawSnippet['text']);
          if (text.isEmpty) continue;
          snippets.add(
            PrivateSearchSnippet(
              text: text,
              blockId: rawSnippet['blockId']?.toString() ?? '',
            ),
          );
        }
      }

      final pageId = rawResult['pageId']?.toString() ?? '';
      if (pageId.isEmpty) continue;

      final title = _cleanText(rawResult['title']);
      final pathText = _cleanText(rawResult['pathText']);
      final cleanedSnippet = _cleanText(rawResult['snippet']);
      final primarySnippet = cleanedSnippet.isNotEmpty
          ? cleanedSnippet
          : (snippets.isEmpty ? '' : snippets.first.text);

      hits.add(
        PrivateSearchHit(
          pageId: pageId,
          title: title.isEmpty ? '无标题页面' : title,
          pathText: pathText,
          type: rawResult['type']?.toString() ?? '',
          primarySnippet: primarySnippet,
          primaryBlockId: rawResult['highlightBlockId']?.toString() ??
              (snippets.isEmpty ? '' : snippets.first.blockId),
          score: num.tryParse(rawResult['score']?.toString() ?? '')
                  ?.toDouble() ??
              0,
          snippets: snippets,
        ),
      );
    }
  }

  return PrivateSearchResponse(status: status, hits: hits, error: error);
}

String _cleanText(Object? value) {
  return (value?.toString() ?? '')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
