import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database/database_helper.dart';
import '../data/models/question.dart';
import 'openai_service.dart';

/// 题目反馈模型
class QuestionFeedback {
  final String id;
  final String questionId;
  final String? deckId;
  final String reason;
  final String? comment;
  final String? questionSnapshot; // 题目JSON快照，便于后台AI还原题目
  final String status; // pending / processed
  final DateTime createdAt;

  QuestionFeedback({
    required this.id,
    required this.questionId,
    this.deckId,
    required this.reason,
    this.comment,
    this.questionSnapshot,
    this.status = 'pending',
    required this.createdAt,
  });

  factory QuestionFeedback.fromMap(Map<String, dynamic> m) => QuestionFeedback(
        id: m['id'] as String,
        questionId: m['question_id'] as String,
        deckId: m['deck_id'] as String?,
        reason: m['reason'] as String,
        comment: m['comment'] as String?,
        questionSnapshot: m['question_snapshot'] as String?,
        status: (m['status'] as String?) ?? 'pending',
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}

/// 题目反馈服务：
/// 1. 用户在答题页反馈「题目不行」→ 入库
/// 2. 反馈积累到阈值后，后台调用 AI 把反馈提炼成「出题改进规则」
/// 3. 提炼出的规则注入到出题系统提示词中，实现提示词自我优化闭环
class FeedbackService {
  static const String _rulesKey = 'ai_prompt_rules_v1';
  static const int _autoOptimizeThreshold = 5;

  final DatabaseHelper _db;
  final OpenAIService _ai;

  FeedbackService(this._db, this._ai);

  // ============ 反馈入库 ============

  /// 提交反馈。若未处理反馈达到阈值，自动触发一次后台规则提炼。
  Future<void> submit({
    required Question question,
    required String reason,
    String? comment,
  }) async {
    final db = await _db.database;
    await db.insert('question_feedback', {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'question_id': question.id,
      'deck_id': question.deckId,
      'reason': reason,
      'comment': (comment == null || comment.trim().isEmpty) ? null : comment.trim(),
      'question_snapshot': jsonEncode({
        'type': question.type.value,
        'content': question.content,
        'options': question.options,
        'answer': question.answer,
        'explanation': question.explanation,
      }),
      'status': 'pending',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    final pending = await countPending();
    if (pending >= _autoOptimizeThreshold) {
      // 后台静默提炼，失败不影响用户操作
      optimizePrompt(_ai).ignore();
    }
  }

  Future<List<QuestionFeedback>> getAll({int limit = 100}) async {
    final db = await _db.database;
    final maps = await db.query('question_feedback',
        orderBy: 'created_at DESC', limit: limit);
    return maps.map(QuestionFeedback.fromMap).toList();
  }

  Future<int> countPending() async {
    final db = await _db.database;
    final r = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM question_feedback WHERE status = 'pending'");
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> countAll() async {
    final db = await _db.database;
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM question_feedback');
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<void> clearAll() async {
    final db = await _db.database;
    await db.delete('question_feedback');
  }

  // ============ AI 提炼改进规则 ============

  /// 把未处理的反馈交给 AI 提炼成出题规则，保存并标记已处理。
  /// 返回本次提炼后的完整规则文本（无反馈时返回 null）。
  Future<String?> optimizePrompt(OpenAIService ai, {bool force = false}) async {
    final pending = await getAll(limit: 30);
    final todo = pending.where((f) => f.status == 'pending' || force).toList();
    if (todo.isEmpty) return null;

    final currentRules = await getPromptRules();
    final sb = StringBuffer();
    if (currentRules.isNotEmpty) {
      sb.writeln('【现有规则】');
      for (final r in currentRules) {
        sb.writeln('- $r');
      }
      sb.writeln();
    }
    sb.writeln('【用户反馈】（每条包含：反馈原因、用户备注、题目快照）');
    for (final f in todo) {
      sb.writeln('- 反馈原因：${f.reason}${f.comment == null ? '' : '；用户备注：${f.comment}'}');
      if (f.questionSnapshot != null) {
        sb.writeln('  题目快照：${f.questionSnapshot}');
      }
    }

    const systemPrompt = '你是出题系统的提示词优化专家。用户会对AI生成的题目提交质量反馈，'
        '你要根据这些反馈，把「现有规则」修订为一份新的、可直接执行的出题规则列表。\n'
        '要求：\n'
        '1. 每条规则一句话，具体、可执行、可验证，禁止空话套话\n'
        '2. 保留仍然有效的旧规则，修正或删除与反馈冲突的规则，针对反馈补充新规则\n'
        '3. 规则总数控制在 3-12 条\n'
        '4. 只输出 JSON，格式：{"rules": ["规则1", "规则2", ...]}，不要输出其他内容';

    try {
      final result = await ai.chatCompletion(
        systemPrompt: systemPrompt,
        userContent: sb.toString(),
        temperature: 0.3,
      );
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(result);
      if (jsonMatch == null) return null;
      final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      final rules = (json['rules'] as List?)?.map((e) => e.toString()).toList() ?? [];
      if (rules.isEmpty) return null;

      await _saveRules(rules);

      // 标记已处理
      final db = await _db.database;
      await db.update(
        'question_feedback',
        {'status': 'processed'},
        where: "status = 'pending'",
      );
      return rules.join('\n');
    } catch (_) {
      // 提炼失败：保留 pending，下次再试
      return null;
    }
  }

  static Future<List<String>> getPromptRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_rulesKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveRules(List<String> rules) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rulesKey, jsonEncode(rules));
  }

  Future<void> clearRules() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rulesKey);
  }
}
