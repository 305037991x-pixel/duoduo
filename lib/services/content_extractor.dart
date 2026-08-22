import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

/// 轻量内容提取器 - 纯云端方案
/// 本地只做：压缩(仅图片)/读bytes->base64/链接抓正文
/// PDF/Word原文件不做本地文本抽取，直接base64透传给Vision模型
class ExtractedFile {
  final String filename;
  final String mime;
  final String base64;
  ExtractedFile({required this.filename, required this.mime, required this.base64});
}

class LinkExtractResult {
  final String title;
  final String text;
  LinkExtractResult({required this.title, required this.text});
}

class ContentExtractor {
  /// 将本地文件转为 ExtractedFile（不解析内容，直接透传）
  Future<ExtractedFile> fileToExtracted(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    final filename = path.split(Platform.pathSeparator).last;
    // mime探测，fallback按扩展名
    String? mimeType = lookupMimeType(path);
    if (mimeType == null) {
      final ext = filename.split('.').last.toLowerCase();
      mimeType = {
        'pdf': 'application/pdf',
        'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'doc': 'application/msword',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'webp': 'image/webp',
      }[ext] ?? 'application/octet-stream';
    }
    return ExtractedFile(filename: filename, mime: mimeType, base64: base64Encode(bytes));
  }

  /// 抓取链接正文（轻量HTML抽取，不引入html包也能跑；有html包时更准）
  Future<LinkExtractResult> extractFromUrl(String url) async {
    final uri = Uri.parse(url.trim());
    final resp = await http.get(uri, headers: {
      'User-Agent': 'Mozilla/5.0 (Android) duoduo/1.0',
      'Accept': 'text/html,application/xhtml+xml',
    }).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('抓取失败 HTTP ${resp.statusCode}');
    }
    String html = resp.body;
    // 轻量去标签提取
    // 1. 取 title
    String title = '';
    final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
    if (titleMatch != null) title = _stripTags(titleMatch.group(1)!).trim();
    // 2. 去 script/style/nav/header/footer
    html = html.replaceAll(RegExp(r'<(script|style|nav|header|footer)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), ' ');
    // 3. 优先取 article/main
    String body = html;
    final articleMatch = RegExp(r'<article[^>]*>(.*?)</article>', caseSensitive: false, dotAll: true).firstMatch(html);
    if (articleMatch != null) {
      body = articleMatch.group(1)!;
    } else {
      final mainMatch = RegExp(r'<main[^>]*>(.*?)</main>', caseSensitive: false, dotAll: true).firstMatch(html);
      if (mainMatch != null) body = mainMatch.group(1)!;
    }
    String text = _stripTags(body);
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    if (text.length > 8000) text = text.substring(0, 8000);
    if (text.length < 80) {
      // 正文过短，可能是JS渲染站，提示用户用分享
      text = '链接正文较少，可能为动态页面。建议用系统分享功能分享到多多。\n\n$title\n\n$text';
    }
    return LinkExtractResult(title: title, text: text);
  }

  String _stripTags(String html) {
    var t = html.replaceAll(RegExp(r'<[^>]+>'), '\n');
    t = t.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&#39;', "'");
    t = t.replaceAll(RegExp(r'[ \t]+'), ' ');
    t = t.replaceAll(RegExp(r'\n +'), '\n');
    return t;
  }
}
