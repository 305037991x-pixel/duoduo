import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/database/database_helper.dart';
import '../../data/models/deck.dart';
import '../../data/models/question.dart';
import '../../data/models/study_record.dart';
import '../../data/models/user_stats.dart';
import '../../services/bilibili_service.dart';
import '../../services/content_analyzer.dart';
import '../../services/feedback_service.dart';
import '../../services/gamification_service.dart';
import '../../services/openai_service.dart';

// ============ 基础服务 Provider ============

final databaseProvider = Provider<DatabaseHelper>((ref) {
  return DatabaseHelper();
});

final openaiServiceProvider = Provider<OpenAIService>((ref) {
  return OpenAIService();
});

final contentAnalyzerProvider = Provider<ContentAnalyzer>((ref) {
  return ContentAnalyzer(ref.read(openaiServiceProvider));
});

final bilibiliServiceProvider = Provider<BilibiliService>((ref) {
  return BilibiliService(ref.read(databaseProvider));
});

final feedbackServiceProvider = Provider<FeedbackService>((ref) {
  return FeedbackService(ref.read(databaseProvider), ref.read(openaiServiceProvider));
});

final gamificationServiceProvider = Provider<GamificationService>((ref) {
  return GamificationService(ref.read(databaseProvider));
});

// ============ 数据 Provider ============

/// 所有题包列表
final deckListProvider = FutureProvider<List<Deck>>((ref) async {
  final db = ref.read(databaseProvider);
  return db.getAllDecks();
});

/// 用户统计
final userStatsProvider = StateNotifierProvider<UserStatsNotifier, AsyncValue<UserStats>>((ref) {
  return UserStatsNotifier(ref.read(gamificationServiceProvider));
});

class UserStatsNotifier extends StateNotifier<AsyncValue<UserStats>> {
  final GamificationService _service;

  UserStatsNotifier(this._service) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final stats = await _service.getStats();
      state = AsyncValue.data(stats);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> onCorrect() async {
    final stats = await _service.onCorrectAnswer();
    state = AsyncValue.data(stats);
  }

  Future<void> onWrong() async {
    final stats = await _service.onWrongAnswer();
    state = AsyncValue.data(stats);
  }

  Future<void> onDeckComplete({required bool allCorrect}) async {
    final stats = await _service.onDeckComplete(allCorrect: allCorrect);
    state = AsyncValue.data(stats);
  }

  /// 完美完成答题，恢复一颗心
  Future<void> onPerfectQuiz() async {
    final stats = await _service.onPerfectQuiz();
    state = AsyncValue.data(stats);
  }

  Future<void> setDailyGoal(int goal) async {
    await _service.setDailyGoal(goal);
    await _load();
  }

  Future<void> refresh() async {
    await _load();
  }
}

/// 某题包的题目列表
final deckQuestionsProvider = FutureProvider.family<List<Question>, String>((ref, deckId) async {
  final db = ref.read(databaseProvider);
  return db.getQuestionsByDeck(deckId);
});

/// 某题包的学习记录
final studyRecordProvider = FutureProvider.family<StudyRecord?, String>((ref, deckId) async {
  final db = ref.read(databaseProvider);
  return db.getStudyRecord(deckId);
});

// ============ 操作 Provider ============

/// 题包操作
final deckOperationsProvider = Provider<DeckOperations>((ref) {
  return DeckOperations(ref);
});

class DeckOperations {
  final Ref _ref;
  DeckOperations(this._ref);

  /// 保存分析结果为题包
  Future<String> saveAnalysisResult(AnalysisResult result, {String? sourceText, String? sourceImage}) async {
    final db = _ref.read(databaseProvider);
    final now = DateTime.now();
    final deckId = now.microsecondsSinceEpoch.toString();

    final deck = Deck(
      id: deckId,
      title: result.title,
      sourceText: sourceText,
      sourceImage: sourceImage,
      questionCount: result.questions.length,
      createdAt: now,
      updatedAt: now,
    );
    await db.insertDeck(deck);

    for (final question in result.questions) {
      await db.insertQuestion(Question(
        id: '',
        deckId: deckId,
        type: question.type,
        content: question.content,
        options: question.options,
        answer: question.answer,
        explanation: question.explanation,
        matchLeft: question.matchLeft,
        matchRight: question.matchRight,
      ));
    }

    // 刷新题包列表
    _ref.invalidate(deckListProvider);

    return deckId;
  }

  /// 删除题包
  Future<void> deleteDeck(String deckId) async {
    final db = _ref.read(databaseProvider);
    await db.deleteDeck(deckId);
    _ref.invalidate(deckListProvider);
  }

  /// 删除单道题目
  Future<void> deleteQuestion(String questionId, String deckId) async {
    final db = _ref.read(databaseProvider);
    await db.deleteQuestion(questionId);
    // 更新题包的题目数量
    final deck = await db.getDeck(deckId);
    if (deck != null) {
      await db.updateDeck(deck.copyWith(
        questionCount: deck.questionCount - 1,
        updatedAt: DateTime.now(),
      ));
    }
    _ref.invalidate(deckListProvider);
    _ref.invalidate(questionsByDeckProvider(deckId));
  }

  /// 更新题包掌握度
  Future<void> updateMastery(String deckId, int masteryLevel) async {
    final db = _ref.read(databaseProvider);
    final deck = await db.getDeck(deckId);
    if (deck != null) {
      await db.updateDeck(deck.copyWith(masteryLevel: masteryLevel, updatedAt: DateTime.now()));
      _ref.invalidate(deckListProvider);
    }
  }

  /// 保存学习记录
  Future<void> saveStudyRecord(String deckId, int correctCount, int totalCount) async {
    final db = _ref.read(databaseProvider);
    final record = StudyRecord(
      id: '${deckId}_record',
      deckId: deckId,
      correctCount: correctCount,
      totalCount: totalCount,
      lastStudiedAt: DateTime.now(),
    );
    await db.upsertStudyRecord(record);

    // 更新掌握度
    final gamification = _ref.read(gamificationServiceProvider);
    final mastery = gamification.calculateMasteryLevel(correctCount, totalCount);
    await updateMastery(deckId, mastery);
  }
}

// ============ 学习模式 ============

/// 学习模式
enum LearningMode { random, knowledgePoint }

/// 学习模式 Provider（持久化到 SharedPreferences）
final learningModeProvider =
    StateNotifierProvider<LearningModeNotifier, LearningMode>((ref) {
  return LearningModeNotifier();
});

class LearningModeNotifier extends StateNotifier<LearningMode> {
  LearningModeNotifier() : super(LearningMode.random) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt('learning_mode') ?? 0;
    state = LearningMode.values[index];
  }

  Future<void> setMode(LearningMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('learning_mode', mode.index);
  }
}

// ============ 随机关卡进度 ============

/// 随机模式已通关数（持久化）
final randomLevelProgressProvider =
    StateNotifierProvider<RandomLevelNotifier, int>((ref) {
  return RandomLevelNotifier();
});

class RandomLevelNotifier extends StateNotifier<int> {
  RandomLevelNotifier() : super(0) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt('random_level_progress') ?? 0;
  }

  /// 标记某关为已完成（只增不减）
  Future<void> completeLevel(int level) async {
    if (level > state) {
      state = level;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('random_level_progress', level);
    }
  }
}

// ============ 所有题目（随机模式用） ============

final allQuestionsProvider = FutureProvider<List<Question>>((ref) async {
  final db = ref.read(databaseProvider);
  return db.getAllQuestions();
});

/// 某个题包的题目列表
final questionsByDeckProvider = FutureProvider.family<List<Question>, String>((ref, deckId) async {
  final db = ref.read(databaseProvider);
  return db.getQuestionsByDeck(deckId);
});

// ============ 月度打卡 & 答题统计 ============

/// 当月打卡日期列表（key 格式: "2026_6"）
final monthlyCheckInProvider = FutureProvider.family<List<String>, String>((ref, yearMonth) async {
  final parts = yearMonth.split('_');
  return ref.read(gamificationServiceProvider)
      .getMonthlyCheckInDates(int.parse(parts[0]), int.parse(parts[1]));
});

/// 已获得的月度勋章
final earnedMedalsProvider = FutureProvider<List<({int year, int month})>>((ref) async {
  return ref.read(gamificationServiceProvider).getEarnedMedals();
});

/// 总答对题数
final totalCorrectProvider = FutureProvider<int>((ref) async {
  return ref.read(gamificationServiceProvider).getTotalCorrect();
});

/// 完美通关次数
final perfectCountProvider = FutureProvider<int>((ref) async {
  return ref.read(gamificationServiceProvider).getPerfectCount();
});
