import 'dart:convert';
import 'openai_service.dart';
import 'content_extractor.dart';
import '../data/models/question.dart';

/// 分析结果
class AnalysisResult {
  final String title;
  final List<Question> questions;

  AnalysisResult({required this.title, required this.questions});
}

/// 内容拆解引擎 - 将用户输入的文本/图片/文件转化为结构化题目（纯云端）
class ContentAnalyzer {
  final OpenAIService _openai;

  ContentAnalyzer(this._openai);

  static const String _systemPrompt = '''你是一个专业的教育内容分析专家。你的任务是分析用户提供的文本、图片、PDF、Word等内容，提取关键知识点，并生成多种类型的题目。

## 要求：
1. 仔细阅读/分析所有内容（文本+图片+文档原文件），提取 5-10 个核心知识点
2. 为每个知识点生成合适类型的题目
3. 题目类型要多样化：选择题、填空题、判断题、匹配题、排序题、问答题
4. 题目难度适中，能检验对内容的理解
5. 每道题都要有详细的解析说明
6. 若提供了PDF/Word原文件或多张截图，请综合所有材料的信息

## 题型格式说明：

### 选择题 (multiple_choice)
- options: 4个选项 ["选项A", "选项B", "选项C", "选项D"]
- answer: 正确答案的文本，必须与options中的某一项完全一致
- 选项要有迷惑性但不能有歧义

### 填空题 (fill_blank)
- answer: 正确答案的文本
- content 中用 ___ 表示空缺处

### 判断题 (true_false)
- options: ["正确", "错误"]
- answer: "正确" 或 "错误"

### 匹配题 (matching)
- match_left: 左侧条目列表 ["条目1", "条目2", "条目3"]
- match_right: 右侧条目列表（顺序打乱）["匹配A", "匹配B", "匹配C"]
- answer: 正确匹配关系，格式 "条目1-匹配A|条目2-匹配B|条目3-匹配C"
- 左右两侧数量必须相等

### 排序题 (ordering)
- options: 打乱顺序的条目列表
- answer: 正确顺序，用 | 分隔，如 "第一步|第二步|第三步"

### 问答题 (essay)
- content: 开放性提问，如"简述..."、"请解释..."、"分析..."
- answer: 参考答案（100-200字，需包含3-5个得分要点，判分时对照）
- explanation: 评分要点解析，对应answer中的要点
- 问答题适合考察理解、归纳、论述能力，每套题 1-2 道即可

## 输出格式（严格 JSON）：
```json
{
  "title": "题包标题（简短概括内容主题）",
  "questions": [
    {
      "type": "multiple_choice",
      "content": "题干文本",
      "options": ["选项A", "选项B", "选项C", "选项D"],
      "answer": "选项B",
      "explanation": "解析说明"
    },
    {
      "type": "essay",
      "content": "请简述...",
      "answer": "参考答案，包含要点1；要点2；要点3",
      "explanation": "要点1：...；要点2：...；要点3：..."
    }
  ]
}
```

## 注意事项：
- title 要简洁有力，概括内容主题
- 题目数量以用户消息中指定的「出题量」为准；未指定时生成 5-10 道
- 尽量包含至少 3 种题型，可包含 1-2 道问答题
- 解析要清楚说明为什么这个答案是对的
- 如果内容是图片/文档，仔细识别其中的文字和图表信息
- 所有文本使用中文''';

  /// 分析内容并生成题目（纯云端：文本+多图+多文件直传）
  Future<AnalysisResult> analyze({
    required String text,
    String? imageBase64,
    List<String>? imageBase64List,
    List<ExtractedFile>? files,
    int questionCount = 10,
  }) async {
    final userContent = StringBuffer();
    userContent.writeln('请分析以下内容并生成题目：');
    userContent.writeln('出题量：请生成 $questionCount 道题。');
    userContent.writeln();
    if (text.isNotEmpty) {
      userContent.writeln('--- 文本/链接正文 ---');
      userContent.writeln(text);
      userContent.writeln();
    }
    final imgCount = (imageBase64 != null ? 1 : 0) + (imageBase64List?.length ?? 0);
    if (imgCount > 0) {
      userContent.writeln('--- 图片/截图 ($imgCount 张) ---');
      userContent.writeln('请同时分析提供的图片，识别其中的文字和图表信息。');
      userContent.writeln();
    }
    if (files != null && files.isNotEmpty) {
      userContent.writeln('--- 文档原文件 (${files.map((f) => f.filename).join(", ")}) ---');
      userContent.writeln('请直接阅读提供的PDF/Word原文件内容（已作为文件直传），综合所有材料生成题目。');
      userContent.writeln();
    }

    // 归一所有图片
    final allImages = <String>[];
    if (imageBase64 != null) allImages.add(imageBase64);
    if (imageBase64List != null) allImages.addAll(imageBase64List);

    final response = await _openai.chatCompletion(
      systemPrompt: _systemPrompt,
      userContent: userContent.toString(),
      imageBase64List: allImages.isEmpty ? null : allImages,
      files: files,
      temperature: 0.7,
    );

    return _parseResponse(response);
  }

  /// 解析 GPT 返回的 JSON
  AnalysisResult _parseResponse(String response) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(response) as Map<String, dynamic>;
    } catch (e) {
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(response);
      if (jsonMatch != null) {
        json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      } else {
        throw Exception('无法解析 AI 返回的内容: $response');
      }
    }

    final title = json['title'] as String? ?? '未命名题包';
    final questionsJson = json['questions'] as List<dynamic>? ?? [];

    final questions = <Question>[];
    for (final qJson in questionsJson) {
      try {
        final q = Question.fromJson(qJson as Map<String, dynamic>, '');
        questions.add(q);
      } catch (e) {
        continue;
      }
    }

    if (questions.isEmpty) {
      throw Exception('AI 未生成有效题目');
    }

    return AnalysisResult(title: title, questions: questions);
  }
}
