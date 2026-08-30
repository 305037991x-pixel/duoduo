import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/providers/providers.dart';
import '../../data/models/question.dart';
import '../../data/models/question_type.dart';

/// 题目管理页 — 查看题包中的所有题目，可删除单道题
class QuestionManagementScreen extends ConsumerWidget {
  final String deckId;
  final String deckTitle;

  const QuestionManagementScreen({
    super.key,
    required this.deckId,
    required this.deckTitle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final questionsAsync = ref.watch(questionsByDeckProvider(deckId));

    return Scaffold(
      appBar: AppBar(
        title: Text(deckTitle),
      ),
      body: SafeArea(
        child: questionsAsync.when(
          data: (questions) {
            if (questions.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.quiz_outlined, size: 64, color: AppColors.textLight),
                    SizedBox(height: 16),
                    Text(
                      '暂无题目',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            }
            return Column(
              children: [
                // 标题栏
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  color: AppColors.blueLight,
                  child: Row(
                    children: [
                      const Icon(Icons.edit, color: AppColors.blue, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '共 ${questions.length} 道题',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.blueDark,
                        ),
                      ),
                    ],
                  ),
                ),
                // 题目列表
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: questions.length,
                    itemBuilder: (context, index) {
                      return _QuestionManageCard(
                        question: questions[index],
                        index: index + 1,
                        onDelete: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('删除题目'),
                              content: const Text('确定删除这道题吗？此操作不可撤销。'),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await ref.read(deckOperationsProvider).deleteQuestion(
                                  questions[index].id,
                                  deckId,
                                );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('题目已删除'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            }
                          }
                        },
                      ).animate().fadeIn(
                            duration: 200.ms,
                            delay: (index * 50).ms,
                          );
                    },
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.green),
          ),
          error: (err, _) => Center(child: Text('加载失败: $err')),
        ),
      ),
    );
  }
}

/// 题目管理卡片（可删除）
class _QuestionManageCard extends StatelessWidget {
  final Question question;
  final int index;
  final VoidCallback onDelete;

  const _QuestionManageCard({
    required this.question,
    required this.index,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：序号 + 题型 + 删除按钮
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.blue,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    '$index',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  question.type.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onDelete,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.redLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.delete_outline, color: AppColors.red, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 题干
          Text(
            question.content,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          // 选项（选择题/判断题/排序题）
          if (question.options.isNotEmpty &&
              question.type != QuestionType.ordering) ...[
            ...question.options.map((option) {
              final isAnswer = option == question.answer;
              return Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isAnswer ? AppColors.greenLight : AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isAnswer ? AppColors.green : AppColors.border,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isAnswer ? Icons.check_circle : Icons.circle_outlined,
                      color: isAnswer ? AppColors.green : AppColors.textLight,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        option,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isAnswer ? FontWeight.w700 : FontWeight.w500,
                          color: isAnswer ? AppColors.greenDark : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
          // 填空题答案
          if (question.options.isEmpty &&
              question.type == QuestionType.fillBlank) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.greenLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.green, width: 1.5),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: AppColors.green, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '答案: ${question.answer}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.greenDark,
                    ),
                  ),
                ],
              ),
            ),
          ],
          // 匹配题
          if (question.type == QuestionType.matching &&
              question.matchLeft != null &&
              question.matchRight != null) ...[
            ...List.generate(question.matchLeft!.length, (i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        question.matchLeft![i],
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_forward, size: 16, color: AppColors.green),
                    const SizedBox(width: 4),
                    Expanded(
                      flex: 2,
                      child: Text(
                        question.matchRight![i],
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.greenDark,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
          // 排序题
          if (question.type == QuestionType.ordering) ...[
            ...question.answer.split('|').asMap().entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: AppColors.green,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text(
                          '${entry.key + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      entry.value,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
          // 解析
          if (question.explanation != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.blueLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.lightbulb, size: 16, color: AppColors.blue),
                      SizedBox(width: 4),
                      Text(
                        '解析',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.blue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    question.explanation!,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
