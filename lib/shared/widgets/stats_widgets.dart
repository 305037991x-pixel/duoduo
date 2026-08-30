import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../data/models/user_stats.dart';

/// 顶部状态栏 - 显示连续天数、心数、XP
class TopStatsBar extends StatelessWidget {
  final UserStats stats;

  const TopStatsBar({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // 连续打卡天数
          _StatChip(
            icon: Icons.local_fire_department,
            iconColor: AppColors.streakOrange,
            value: stats.streak.toString(),
          ),
          const SizedBox(width: 12),
          // 宝石(XP)
          _StatChip(
            icon: Icons.diamond,
            iconColor: AppColors.blue,
            value: stats.xp.toString(),
          ),
          const SizedBox(width: 12),
          // 心数
          _StatChip(
            icon: Icons.favorite,
            iconColor: AppColors.heartRed,
            value: '${stats.hearts}/${stats.maxHearts}',
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;

  const _StatChip({
    required this.icon,
    required this.iconColor,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// 答题进度条
class QuizProgressBar extends StatelessWidget {
  final double progress; // 0.0 - 1.0
  final int hearts;

  const QuizProgressBar({
    super.key,
    required this.progress,
    required this.hearts,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 关闭按钮
          IconButton(
            icon: const Icon(Icons.close, color: AppColors.textLight),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          // 进度条
          Expanded(
            child: Container(
              height: 16,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.green,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 心数
          Row(
            children: [
              const Icon(Icons.favorite, color: AppColors.heartRed, size: 22),
              const SizedBox(width: 4),
              Text(
                hearts.toString(),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
