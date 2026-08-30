import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/providers/providers.dart';
import '../../services/bilibili_service.dart';
import '../../services/feedback_service.dart';
import '../../services/openai_service.dart';
import '../../shared/widgets/duo_button.dart';
import 'qr_login_dialog.dart';

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

  // B站登录态
  final _sessdataController = TextEditingController();
  BiliLoginStatus? _biliStatus;
  bool _biliChecking = false;

  // 题目反馈
  int _pendingFeedbackCount = 0;
  List<String> _promptRules = [];
  bool _isOptimizing = false;

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

    // B站登录态 + 反馈数据
    final bili = ref.read(bilibiliServiceProvider);
    final sessdata = await bili.getSessdata();
    final feedback = ref.read(feedbackServiceProvider);
    final pendingCount = await feedback.countPending();
    final rules = await FeedbackService.getPromptRules();

    setState(() {
      _apiKeyController.text = key ?? '';
      _baseUrlController.text = baseUrl;
      _selectedProviderId = providerId;
      _dailyGoal = stats.dailyGoal;
      _sessdataController.text = sessdata ?? '';
      _pendingFeedbackCount = pendingCount;
      _promptRules = rules;

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
    _sessdataController.dispose();
    super.dispose();
  }

  /// 扫码登录：弹二维码，B站APP扫码确认后自动保存 SESSDATA
  Future<void> _qrLogin() async {
    final ok = await QrLoginDialog.show(context);
    if (!ok || !mounted) return;
    setState(() => _biliChecking = true);
    final bili = ref.read(bilibiliServiceProvider);
    final status = await bili.verifyLogin();
    setState(() {
      _biliStatus = status;
      _biliChecking = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status.isLogin ? 'B站登录成功：${status.uname}' : '登录态验证失败：${status.message}'),
        backgroundColor: status.isLogin ? AppColors.green : AppColors.red,
      ));
    }
  }

  /// 保存并校验B站登录态（调用 nav 接口验证 SESSDATA 是否有效）
  Future<void> _saveAndVerifyBilibili() async {
    setState(() => _biliChecking = true);
    final bili = ref.read(bilibiliServiceProvider);
    await bili.setSessdata(_sessdataController.text.trim());
    final status = await bili.verifyLogin();
    setState(() {
      _biliStatus = status;
      _biliChecking = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status.isLogin ? 'B站登录态有效：${status.uname}' : 'B站登录态无效：${status.message}'),
        backgroundColor: status.isLogin ? AppColors.green : AppColors.red,
      ));
    }
  }

  /// 手动触发：AI 根据反馈提炼出题改进规则
  Future<void> _optimizePromptManually() async {
    setState(() => _isOptimizing = true);
    final feedback = ref.read(feedbackServiceProvider);
    final result = await feedback.optimizePrompt(
      ref.read(openaiServiceProvider),
      force: true,
    );
    final rules = await FeedbackService.getPromptRules();
    final pending = await feedback.countPending();
    setState(() {
      _isOptimizing = false;
      _promptRules = rules;
      _pendingFeedbackCount = pending;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result == null ? '没有可提炼的反馈，或提炼失败，请稍后再试' : '已提炼出 ${rules.length} 条出题改进规则，将注入后续出题'),
        backgroundColor: result == null ? AppColors.red : AppColors.green,
      ));
    }
  }

  Future<void> _clearFeedback() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空反馈记录'),
        content: const Text('将删除所有题目反馈记录（已提炼的改进规则会保留）。'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('确定清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(feedbackServiceProvider).clearAll();
      setState(() => _pendingFeedbackCount = 0);
    }
  }

  /// 查看反馈记录与当前规则
  Future<void> _showFeedbackDetail() async {
    final feedback = ref.read(feedbackServiceProvider);
    final all = await feedback.getAll(limit: 30);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('反馈记录（最近30条）', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (all.isEmpty) const Text('暂无反馈记录', style: TextStyle(color: AppColors.textSecondary)),
            ...all.map((f) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(f.reason, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      const Spacer(),
                      Text(f.status == 'pending' ? '待提炼' : '已提炼',
                          style: TextStyle(fontSize: 11, color: f.status == 'pending' ? AppColors.red : AppColors.green)),
                    ]),
                    if (f.comment != null && f.comment!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('备注：${f.comment}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ),
                  ]),
                )),
            const SizedBox(height: 12),
            const Text('当前出题改进规则（已注入出题提示词）', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (_promptRules.isEmpty) const Text('暂无规则，积累反馈后点击「AI提炼改进规则」生成', style: TextStyle(color: AppColors.textSecondary)),
            ..._promptRules.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('· ', style: TextStyle(fontWeight: FontWeight.w800)),
                    Expanded(child: Text(r, style: const TextStyle(fontSize: 13, height: 1.4))),
                  ]),
                )),
          ],
        ),
      ),
    );
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

              // === B站账号（AI字幕登录态） ===
              const Text(
                'B站账号（AI字幕）',
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
                    // 扫码登录（推荐，全自动）
                    DuoButton(
                      label: _biliChecking ? '验证中...' : 'B站APP扫码登录（推荐）',
                      color: const Color(0xFFFB7299),
                      width: double.infinity,
                      height: 48,
                      icon: Icons.qr_code_scanner,
                      fontSize: 15,
                      onPressed: _biliChecking ? null : _qrLogin,
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () async {
                          final s = await ref.read(bilibiliServiceProvider).getSessdata();
                          if (!mounted) return;
                          if (s == null || s.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('尚未登录B站'), backgroundColor: AppColors.red),
                            );
                            return;
                          }
                          await Clipboard.setData(ClipboardData(text: s));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('SESSDATA 已复制。注意：续期请只留给本App，其他软件建议只粘贴 SESSDATA 只读使用'),
                                backgroundColor: AppColors.green,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制 SESSDATA 给其他软件', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      const Expanded(child: Divider(color: AppColors.border)),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text('或手动粘贴', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ),
                      const Expanded(child: Divider(color: AppColors.border)),
                    ]),
                    const SizedBox(height: 12),
                    const Text(
                      'SESSDATA（B站登录凭证）',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _sessdataController,
                      obscureText: true,
                      decoration: InputDecoration(
                        hintText: '粘贴浏览器 Cookie 中的 SESSDATA 值',
                        hintStyle: TextStyle(color: AppColors.textLight),
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: Icon(Icons.smart_display, color: Color(0xFFFB7299)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('如何获取 SESSDATA？'),
                          content: const SingleChildScrollView(
                            child: Text(
                              '方式一（推荐）：点击上方「B站APP扫码登录」，'
                              '用B站APP扫一扫并确认，登录态自动保存，无需手动操作。\n\n'
                              '方式二：手动粘贴 SESSDATA\n'
                              '1. 在浏览器打开 bilibili.com 并登录\n'
                              '2. 按 F12（或右键→检查）打开开发者工具\n'
                              '3. 切换到 Application（应用）→ Cookies → https://www.bilibili.com\n'
                              '4. 找到名为 SESSDATA 的条目，复制它的值\n'
                              '5. 粘贴到上方输入框，点「保存并验证」\n\n'
                              'AI字幕接口必须携带登录态才能返回，登录凭证只保存在你的手机本地。',
                              style: TextStyle(fontSize: 14, height: 1.6),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('知道了', style: TextStyle(fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ),
                      ),
                      child: const Text(
                        '如何获取 SESSDATA？（点击查看步骤）',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFFD6336C),
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    if (_biliStatus != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _biliStatus!.message,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _biliStatus!.isLogin ? AppColors.green : AppColors.red,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DuoButton(
                      label: _biliChecking ? '验证中...' : '保存并验证',
                      color: const Color(0xFFFB7299),
                      width: double.infinity,
                      height: 44,
                      icon: Icons.verified,
                      fontSize: 14,
                      onPressed: _biliChecking ? null : _saveAndVerifyBilibili,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // === 题目反馈优化 ===
              const Text(
                '题目反馈优化',
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
                    Text(
                      '你在答题页反馈的「不行的题目」会记录在本地；'
                      '积累 5 条后 AI 会自动把反馈提炼成出题改进规则并注入后续出题（也可手动触发）。',
                      style: const TextStyle(fontSize: 13, height: 1.5, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Text(
                        '待提炼反馈：$_pendingFeedbackCount 条',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _showFeedbackDetail,
                        icon: const Icon(Icons.list, size: 18),
                        label: const Text('查看记录'),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    DuoButton(
                      label: _isOptimizing ? 'AI 提炼中...' : 'AI 提炼改进规则',
                      color: AppColors.blue,
                      width: double.infinity,
                      height: 44,
                      icon: Icons.auto_fix_high,
                      fontSize: 14,
                      onPressed: _isOptimizing ? null : _optimizePromptManually,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _clearFeedback,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('清空反馈记录'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.red,
                        side: const BorderSide(color: AppColors.red, width: 1.5),
                        minimumSize: const Size(double.infinity, 44),
                      ),
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
