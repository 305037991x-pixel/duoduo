import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_extractor.dart';

/// AI 厂商预设
class AIProviderPreset {
  final String id;
  final String name;
  final String baseUrl;
  final List<String> models;
  final String keyHelpUrl;
  final String keyHint;

  const AIProviderPreset({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.models,
    required this.keyHelpUrl,
    required this.keyHint,
  });
}

/// 内置 AI 厂商列表
class AIProviders {
  static const List<AIProviderPreset> builtin = [
    AIProviderPreset(
      id: 'opencode-go',
      name: 'OpenCode Go · MiMo-V2.5 (推荐)',
      baseUrl: 'https://api.xiaomimimo.com/v1',
      models: ['mimo-v2.5', 'mimo-v2.5-flash', 'mimo-v2-flash'],
      keyHelpUrl: 'https://platform.xiaomimimo.com',
      keyHint: 'sk-...',
    ),
    AIProviderPreset(
      id: 'mimo',
      name: '小米 MiMo 官方',
      baseUrl: 'https://api.xiaomimimo.com/v1',
      models: ['mimo-v2.5', 'mimo-v2.5-flash'],
      keyHelpUrl: 'https://platform.xiaomimimo.com',
      keyHint: 'sk-...',
    ),
    AIProviderPreset(
      id: 'openai',
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      models: ['gpt-4o-mini', 'gpt-4o', 'gpt-4-turbo'],
      keyHelpUrl: 'https://platform.openai.com/api-keys',
      keyHint: 'sk-...',
    ),
    AIProviderPreset(
      id: 'deepseek',
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      models: ['deepseek-chat', 'deepseek-reasoner'],
      keyHelpUrl: 'https://platform.deepseek.com/api_keys',
      keyHint: 'sk-...',
    ),
    AIProviderPreset(
      id: 'qwen',
      name: '通义千问 (百炼)',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      models: ['qwen-turbo', 'qwen-plus', 'qwen-max', 'qwen-vl-max'],
      keyHelpUrl: 'https://bailian.console.aliyun.com/?apiKey=1',
      keyHint: 'sk-...',
    ),
    AIProviderPreset(
      id: 'moonshot',
      name: '月之暗面 (Kimi)',
      baseUrl: 'https://api.moonshot.cn/v1',
      models: ['moonshot-v1-8k', 'moonshot-v1-32k', 'moonshot-v1-128k'],
      keyHelpUrl: 'https://platform.moonshot.cn/console/api-keys',
      keyHint: 'sk-...',
    ),
    AIProviderPreset(
      id: 'zhipu',
      name: '智谱 AI',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      models: ['glm-4-flash', 'glm-4-air', 'glm-4-plus', 'glm-4v-plus'],
      keyHelpUrl: 'https://open.bigmodel.cn/usercenter/apikeys',
      keyHint: '...',
    ),
    AIProviderPreset(
      id: 'gemini',
      name: 'Google Gemini',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      models: ['gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash'],
      keyHelpUrl: 'https://aistudio.google.com/apikey',
      keyHint: 'AIza...',
    ),
    AIProviderPreset(
      id: 'custom',
      name: '自定义',
      baseUrl: '',
      models: [],
      keyHelpUrl: '',
      keyHint: '',
    ),
  ];

  static AIProviderPreset? getById(String id) {
    for (final p in builtin) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// AI 服务（兼容 OpenAI 接口格式）
class OpenAIService {
  static const String _apiKeyKey = 'ai_api_key';
  static const String _modelKey = 'ai_model';
  static const String _baseUrlKey = 'ai_base_url';
  static const String _providerIdKey = 'ai_provider_id';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 120),
  ));

  Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_apiKeyKey);
    if (key != null) return key;
    final oldKey = prefs.getString('openai_api_key');
    if (oldKey != null) {
      await prefs.setString(_apiKeyKey, oldKey);
      await prefs.remove('openai_api_key');
      return oldKey;
    }
    return null;
  }

  Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyKey, key);
  }

  Future<String> getModel() async {
    final prefs = await SharedPreferences.getInstance();
    final model = prefs.getString(_modelKey);
    if (model != null) return model;
    final oldModel = prefs.getString('openai_model');
    if (oldModel != null) {
      await prefs.setString(_modelKey, oldModel);
      await prefs.remove('openai_model');
      return oldModel;
    }
    return 'mimo-v2.5-flash';
  }

  Future<void> setModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelKey, model);
  }

  Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_baseUrlKey) ?? 'https://api.xiaomimimo.com/v1';
  }

  Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, url);
  }

  Future<String> getProviderId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_providerIdKey) ?? 'opencode-go';
  }

  Future<void> setProviderId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerIdKey, id);
  }

  Future<bool> hasApiKey() async {
    final key = await getApiKey();
    return key != null && key.isNotEmpty;
  }

  /// 调用 AI Chat Completions API（OpenAI 兼容格式）
  /// 支持多图 + 多文件(PDF/Word原文件)纯云端直传
  Future<String> chatCompletion({
    required String systemPrompt,
    required String userContent,
    String? imageBase64,
    List<String>? imageBase64List,
    List<ExtractedFile>? files,
    double? temperature,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('未设置 API Key，请先在设置中配置');
    }

    final model = await getModel();
    final baseUrl = await getBaseUrl();

    // 归一化图片列表
    final allImages = <String>[];
    if (imageBase64 != null && imageBase64.isNotEmpty) allImages.add(imageBase64);
    if (imageBase64List != null) allImages.addAll(imageBase64List.where((e) => e.isNotEmpty));

    final hasMultimodal = allImages.isNotEmpty || (files != null && files.isNotEmpty);

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
    ];

    if (hasMultimodal) {
      final contentParts = <Map<String, dynamic>>[
        {'type': 'text', 'text': userContent},
      ];
      for (final b64 in allImages) {
        contentParts.add({
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$b64'},
        });
      }
      if (files != null) {
        for (final f in files) {
          final isImage = f.mime.startsWith('image/');
          if (isImage) {
            contentParts.add({
              'type': 'image_url',
              'image_url': {'url': 'data:${f.mime};base64,${f.base64}'},
            });
          } else {
            // 优先用 OpenAI file 规范；若厂商不支持会自动回退为 image_url 兼容
            contentParts.add({
              'type': 'file',
              'file': {
                'filename': f.filename,
                'file_data': 'data:${f.mime};base64,${f.base64}',
              },
            });
          }
        }
      }
      messages.add({'role': 'user', 'content': contentParts});
    } else {
      messages.add({'role': 'user', 'content': userContent});
    }

    final response = await _dio.post(
      '$baseUrl/chat/completions',
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
      ),
      data: jsonEncode({
        'model': model,
        'messages': messages,
        'temperature': temperature ?? 0.7,
        'max_tokens': 4096,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('API 请求失败: ${response.statusCode} ${response.data}');
    }

    final data = response.data as Map<String, dynamic>;
    final choices = data['choices'] as List;
    if (choices.isEmpty) {
      throw Exception('API 返回空结果');
    }

    return choices[0]['message']['content'] as String;
  }

  /// AI 判断填空题答案是否正确
  Future<bool> judgeFillBlankAnswer({
    required String question,
    required String userAnswer,
    required String correctAnswer,
  }) async {
    const systemPrompt = '你是一个判题助手。你的任务是判断用户的填空题答案是否与标准答案在语义上等价。'
        '允许的情况包括但不限于：同义词、近义词、不同的表述方式、大小写差异、标点差异、简称与全称。'
        '你只需要回答 JSON 格式：{"correct": true} 或 {"correct": false}，不要输出其他内容。';

    final userContent = '题目：$question\n'
        '标准答案：$correctAnswer\n'
        '用户答案：$userAnswer\n'
        '请判断用户答案是否正确。';

    try {
      final result = await chatCompletion(
        systemPrompt: systemPrompt,
        userContent: userContent,
        temperature: 0.0,
      );
      final cleaned = result.trim();
      final jsonMatch = RegExp(r'\{[^}]*\}').firstMatch(cleaned);
      if (jsonMatch != null) {
        final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
        return json['correct'] == true;
      }
      return cleaned.toLowerCase().contains('true');
    } catch (e) {
      return false;
    }
  }

  /// AI 判断问答题（开放作答）— 只给对错+点评，不打分
  /// 返回 {"correct": bool, "feedback": "点评解析 50-150字"}
  Future<Map<String, dynamic>> judgeEssayAnswer({
    required String question,
    required String userAnswer,
    required String referenceAnswer,
  }) async {
    const systemPrompt = '你是一个问答题判分助手。用户需要用一段文字回答问题，你要对照参考答案的要点判断是否正确。'
        '判断标准：覆盖核心要点、逻辑正确、无关键错误即算正确；允许不同表述、补充合理信息。'
        '只返回JSON，不要其他内容。格式：{"correct": true/false, "feedback": "50-150字点评，说明对/错原因并给出要点解析"}';

    final userContent = '题目：$question\n'
        '参考答案：$referenceAnswer\n'
        '用户答案：$userAnswer\n'
        '请判断并给出点评。';

    try {
      final result = await chatCompletion(
        systemPrompt: systemPrompt,
        userContent: userContent,
        temperature: 0.0,
      );
      final cleaned = result.trim();
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(cleaned);
      if (jsonMatch != null) {
        final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
        final correct = json['correct'] == true;
        final feedback = (json['feedback'] ?? json['explanation'] ?? json['reason'] ?? '').toString();
        return {
          'correct': correct,
          'feedback': feedback.isEmpty ? (correct ? '回答正确，覆盖了核心要点。' : '回答不完整或有关键错误，请对照参考答案补充要点。') : feedback,
        };
      }
      final isCorrect = cleaned.toLowerCase().contains('"correct": true') || cleaned.toLowerCase().contains('"correct":true');
      return {'correct': isCorrect, 'feedback': cleaned.substring(0, cleaned.length.clamp(0, 200))};
    } catch (e) {
      return {'correct': false, 'feedback': 'AI 判分暂不可用，请对照参考答案自评。'};
    }
  }
}
