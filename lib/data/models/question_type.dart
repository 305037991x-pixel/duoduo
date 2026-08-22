/// 题目类型枚举
enum QuestionType {
  multipleChoice('multiple_choice', '选择题'),
  fillBlank('fill_blank', '填空题'),
  trueFalse('true_false', '判断题'),
  matching('matching', '匹配题'),
  ordering('ordering', '排序题'),
  essay('essay', '问答题');

  final String value;
  final String label;
  const QuestionType(this.value, this.label);

  static QuestionType fromString(String value) {
    return QuestionType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => QuestionType.multipleChoice,
    );
  }
}
