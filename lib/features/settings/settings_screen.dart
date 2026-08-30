import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/providers/providers.dart';
import '../../services/openai_service.dart';
import '../../shared/widgets/duo_button.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _customModelController = TextEditingController();

  String _selectedProviderId = 'openai';
  String _selectedModel = 'gpt-4o-mini';
  bool _useCustomModel = false;
  int _dailyGoal = 50;
  bool _isLoading = true;
  bool _isSaving = false;

  // 连通测试状态
  bool _isTesting = false;
  String? _testSuccess;
  String? _testError;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final openai = ref.read(openaiServiceProvider);
    final key = await openai.getApiKey();
    final model = await openai.getModel();
    final baseUrl = await openai.getBaseUrl();
    final providerId = await openai.getProviderId();
    final stats = await ref.read(gamificationServiceProvider).getStats();

    setState(() {
      _apiKeyController.text = key ?? '';
      _baseUrlController.text = baseUrl;
      _selectedProviderId = providerId;
      _dailyGoal = stats.dailyGoal;

      // 检查模型是否在当前厂商的预设列表中
      final provider = AIProviders.getById(providerId);
      if (provider != null && provider.models.contains(model)) {
        _selectedModel = model;
        _useCustomModel = false;
      } else {
        // 不在预设列表中，使用自定义模型
        _useCustomModel = true;
        _customModelController.text = model;
      }

      _isLoading = false;
    });
  }

  /// 选择厂商时自动填充 base URL 和默认模型
  void _onProviderChanged(String? providerId) {
    if (providerId == null) return;
    final provider = AIProviders.getById(providerId);
    if (provider == null) return;

    setState(() {
      _selectedProviderId = providerId;
      // 自动填充 base URL（非自定义厂商）
      if (provider.baseUrl.isNotEmpty) {
        _baseUrlController.text = provider.baseUrl;
      }
      // 自动选择第一个模型
      if (provider.models.isNotEmpty) {
        _selectedModel = provider.models.first;
        _useCustomModel = false;
      } else {
        _useCustomModel = true;
      }
    });
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    final openai = ref.read(openaiServiceProvider);
    await openai.setApiKey(_apiKeyController.text.trim());
    await openai.setBaseUrl(_baseUrlController.text.trim());
    await openai.setProviderId(_selectedProviderId);

    final model = _useCustomModel
        ? _customModelController.text.trim()
        : _selectedModel;
    await openai.setModel(model);

    await ref.read(userStatsProvider.notifier).setDailyGoal(_dailyGoal);
    setState(() => _isSaving = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('设置已保存'),
          backgroundColor: AppColors.green,
        ),
      );
    }
  }

  /// 连通测试：先保存当前表单配置（确保测试的就是正在编辑的配置），
  /// 再用最小请求实际调用一次 AI 接口，展示模型回复与耗时。
  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testSuccess = null;
      _testError = null;
    });

    final openai = ref.read(openaiServiceProvider);
    await openai.setApiKey(_apiKeyController.text.trim());
    await openai.setBaseUrl(_baseUrlController.text.trim());
    await openai.setProviderId(_selectedProviderId);
    await openai.setModel(
      _useCustomModel ? _customModelController.text.trim() : _selectedModel,
    );

    final stopwatch = Stopwatch()..start();
    try {
      final reply = await openai.chatCompletion(
        systemPrompt: '你是接口连通性测试助手',
        userContent: '连通测试，请只回复：OK',
        temperature: 0,
      );
      stopwatch.stop();
      final seconds = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      final preview = reply.trim();
      final replyPreview = preview.isEmpty
          ? '(空回复)'
          : preview.substring(0, preview.length.clamp(0, 60));
      if (!mounted) return;
      setState(() {
        _testSuccess = '连接成功（${seconds}s）· 模型回复：$replyPreview';
        _isTesting = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 去掉 Dart 异常的 "Exception: " 前缀，直接展示可读信息
      final message = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      setState(() {
        _testError = '连接失败：$message';
        _isTesting = false;
      });
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _customModelController.dispose();
    super.dispose();
  }

  AIProviderPreset get _currentProvider =>
      AIProviders.getById(_selectedProviderId) ?? AIProviders.builtin.first;

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppColors.green)),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // === AI 配置 ===
              const Text(
                'AI 接口配置',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 厂商选择
                    const Text(
                      'AI 厂商',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedProviderId,
                          isExpanded: true,
                          items: AIProviders.builtin.map((p) {
                            return DropdownMenuItem(
                              value: p.id,
                              child: Text(
                                p.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: _onProviderChanged,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // API Key
                    const Text(
                      'API Key',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _apiKeyController,
                      obscureText: true,
                      decoration: InputDecoration(
                        hintText: _currentProvider.keyHint,
                        hintStyle: const TextStyle(color: AppColors.textLight),
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.key, color: AppColors.textLight),
                      ),
                    ),
                    if (_currentProvider.keyHelpUrl.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () {
                          // 显示获取 Key 的提示
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('前往 ${_currentProvider.keyHelpUrl} 获取 API Key'),
                              backgroundColor: AppColors.blue,
                            ),
                          );
                        },
                        child: Text(
                          '在 ${_currentProvider.keyHelpUrl} 获取 API Key',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.blue,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Base URL
                    const Text(
                      'API Base URL',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _baseUrlController,
                      decoration: InputDecoration(
                        hintText: 'https://api.example.com/v1',
                        hintStyle: const TextStyle(color: AppColors.textLight),
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.link, color: AppColors.textLight),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 模型选择
                    const Text(
                      '模型',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_currentProvider.models.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _useCustomModel ? '__custom__' : _selectedModel,
                            isExpanded: true,
                            items: [
                              ..._currentProvider.models.map((m) => DropdownMenuItem(
                                value: m,
                                child: Text(m, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                              )),
                              const DropdownMenuItem(
                                value: '__custom__',
                                child: Text('自定义模型...', style: TextStyle(fontSize: 15, color: AppColors.blue)),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == '__custom__') {
                                setState(() => _useCustomModel = true);
                              } else if (value != null) {
                                setState(() {
                                  _selectedModel = value;
                                  _useCustomModel = false;
                                });
                              }
                            },
                          ),
                        ),
                      )
                    else
                      // 自定义厂商没有预设模型，直接显示输入框
                      TextField(
                        controller: _customModelController,
                        decoration: InputDecoration(
                          hintText: '输入模型名称',
                          hintStyle: const TextStyle(color: AppColors.textLight),
                          filled: true,
                          fillColor: AppColors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    if (_useCustomModel && _currentProvider.models.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _customModelController,
                        decoration: InputDecoration(
                          hintText: '输入模型名称',
                          hintStyle: const TextStyle(color: AppColors.textLight),
                          filled: true,
                          fillColor: AppColors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // === 连通测试 ===
              DuoButton(
                label: _isTesting ? '测试中...' : '连通测试',
                color: AppColors.blue,
                width: double.infinity,
                height: 48,
                icon: Icons.network_check,
                fontSize: 15,
                onPressed: _isTesting ? null : _testConnection,
              ),
              if (_testSuccess != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.greenLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle, color: AppColors.green, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _testSuccess!,
                          style: const TextStyle(fontSize: 13, color: AppColors.greenDark, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_testError != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.redLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error, color: AppColors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _testError!,
                          style: const TextStyle(fontSize: 13, color: AppColors.redDark, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // === 学习目标 ===
              const Text(
                '学习目标',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '每日 XP 目标',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [10, 20, 30, 50, 100].map((goal) {
                        final isSelected = _dailyGoal == goal;
                        return GestureDetector(
                          onTap: () => setState(() => _dailyGoal = goal),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? AppColors.green : AppColors.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? AppColors.green : AppColors.border,
                                width: 2,
                              ),
                            ),
                            child: Text(
                              '$goal XP',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: isSelected ? Colors.white : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // === 保存按钮 ===
              DuoButton(
                label: _isSaving ? '保存中...' : '保存设置',
                color: AppColors.green,
                width: double.infinity,
                height: 56,
                icon: Icons.check,
                onPressed: _isSaving ? null : _saveSettings,
              ),
              const SizedBox(height: 16),

              // === 数据管理 ===
              const Text(
                '数据管理',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              _SettingItem(
                icon: Icons.delete_forever,
                title: '清除所有数据',
                color: AppColors.red,
                onTap: () => _showClearDataDialog(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showClearDataDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除所有数据'),
        content: const Text('这将删除所有题包、题目和学习记录。此操作不可撤销。'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('确定清除'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final db = ref.read(databaseProvider);
      final decks = await db.getAllDecks();
      for (final deck in decks) {
        await db.deleteDeck(deck.id);
      }
      ref.invalidate(deckListProvider);
      ref.invalidate(userStatsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('数据已清除'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }
}

class _SettingItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  const _SettingItem({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border, width: 2),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textLight),
            ],
          ),
        ),
      ),
    );
  }
}
