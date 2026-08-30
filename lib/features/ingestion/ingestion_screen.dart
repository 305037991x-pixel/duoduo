import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_colors.dart';
import '../../core/providers/providers.dart';
import '../../services/content_extractor.dart';
import '../../shared/widgets/duo_button.dart';
import 'deck_preview_screen.dart';

class IngestionScreen extends ConsumerStatefulWidget {
  final String? sharedText;
  final String? sharedImagePath;

  const IngestionScreen({
    super.key,
    this.sharedText,
    this.sharedImagePath,
  });

  @override
  ConsumerState<IngestionScreen> createState() => _IngestionScreenState();
}

class _IngestionScreenState extends ConsumerState<IngestionScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _textController = TextEditingController();
  final _linkController = TextEditingController();
  final _extractor = ContentExtractor();

  // 多图
  List<XFile> _pickedImages = [];
  List<String> _imageBase64List = [];
  // 文件（PDF/Word）直传
  List<ExtractedFile> _pickedFiles = [];
  // 链接抓取结果
  String? _linkExtractedText;
  bool _linkLoading = false;

  String? _sharedImagePath;
  String? _sharedImageBase64;
  bool _isAnalyzing = false;
  String _statusText = '';
  String? _errorMessage;
  int _tabIndex = 0;

  /// 出题量：文字/截图/文件/链接 四种类型各自独立，持久化到 SharedPreferences
  static const String _qCountPrefPrefix = 'ingestion_question_count_';
  static const int _defaultQuestionCount = 10;
  static const int _minQuestionCount = 3;
  static const int _maxQuestionCount = 30;
  List<int> _questionCounts = const [
    _defaultQuestionCount,
    _defaultQuestionCount,
    _defaultQuestionCount,
    _defaultQuestionCount,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      setState(() => _tabIndex = _tabController.index);
    });
    _loadQuestionCounts();
    if (widget.sharedText != null && widget.sharedText!.isNotEmpty) {
      _textController.text = widget.sharedText!;
    }
    if (widget.sharedImagePath != null) {
      _sharedImagePath = widget.sharedImagePath;
      _loadSharedImage();
    }
  }

  Future<void> _loadQuestionCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final counts = [
        for (int i = 0; i < 4; i++)
          prefs.getInt('$_qCountPrefPrefix$i') ?? _defaultQuestionCount,
      ];
      setState(() => _questionCounts = counts);
    } catch (_) {}
  }

  Future<void> _setQuestionCount(int value) async {
    final clamped = value.clamp(_minQuestionCount, _maxQuestionCount);
    if (clamped == _questionCounts[_tabIndex]) return;
    setState(() {
      final counts = List<int>.from(_questionCounts);
      counts[_tabIndex] = clamped;
      _questionCounts = counts;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$_qCountPrefPrefix$_tabIndex', clamped);
    } catch (_) {}
  }

  Future<void> _loadSharedImage() async {
    if (_sharedImagePath == null) return;
    try {
      final bytes = await File(_sharedImagePath!).readAsBytes();
      setState(() => _sharedImageBase64 = base64Encode(bytes));
    } catch (_) {}
  }

  Future<void> _pasteFromClipboard() async {
    final clipData = await Clipboard.getData('text/plain');
    if (clipData?.text != null && clipData!.text!.isNotEmpty) {
      setState(() => _textController.text = clipData.text!);
    }
  }

  Future<void> _pickImages() async {
    try {
      final picker = ImagePicker();
      final images = await picker.pickMultiImage(imageQuality: 85, maxWidth: 2048, maxHeight: 2048);
      if (images.isEmpty) return;
      final b64List = <String>[];
      for (final x in images) {
        final bytes = await x.readAsBytes();
        b64List.add(base64Encode(bytes));
      }
      setState(() {
        _pickedImages = images;
        _imageBase64List = b64List;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() => _errorMessage = '选择图片失败: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final picker = ImagePicker();
      final photo = await picker.pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2048);
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      setState(() {
        _pickedImages = [photo];
        _imageBase64List = [base64Encode(bytes)];
        _errorMessage = null;
      });
    } catch (e) {
      setState(() => _errorMessage = '拍照失败: $e');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.custom,
        allowedExtensions: ['pdf', 'docx', 'doc', 'png', 'jpg', 'jpeg', 'webp'],
      );
      if (result == null || result.files.isEmpty) return;
      final list = <ExtractedFile>[];
      for (final f in result.files) {
        final bytes = f.bytes;
        if (bytes == null) continue;
        // 10MB 限流
        if (bytes.length > 10 * 1024 * 1024) {
          setState(() => _errorMessage = '文件 ${f.name} 超过10MB，已跳过');
          continue;
        }
        String mime = 'application/octet-stream';
        final ext = (f.extension ?? '').toLowerCase();
        if (ext == 'pdf') mime = 'application/pdf';
        if (ext == 'docx') mime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
        if (ext == 'doc') mime = 'application/msword';
        if (ext == 'png') mime = 'image/png';
        if (ext == 'jpg' || ext == 'jpeg') mime = 'image/jpeg';
        if (ext == 'webp') mime = 'image/webp';
        list.add(ExtractedFile(filename: f.name, mime: mime, base64: base64Encode(bytes)));
      }
      if (list.isEmpty) return;
      setState(() {
        _pickedFiles = list;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() => _errorMessage = '选择文件失败: $e');
    }
  }

  Future<void> _fetchLink() async {
    final url = _linkController.text.trim();
    if (url.isEmpty) {
      setState(() => _errorMessage = '请输入链接');
      return;
    }
    if (!url.startsWith('http')) {
      setState(() => _errorMessage = '请输入以 http 开头的完整链接');
      return;
    }
    setState(() {
      _linkLoading = true;
      _errorMessage = null;
    });
    try {
      final r = await _extractor.extractFromUrl(url);
      setState(() {
        _linkExtractedText = r.text;
        _linkLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已提取约 ${r.text.length} 字'), backgroundColor: AppColors.green));
      }
    } catch (e) {
      setState(() {
        _linkLoading = false;
        _errorMessage = '抓取失败: $e，请尝试用系统分享到多多';
      });
    }
  }

  Future<void> _analyze() async {
    String text = _textController.text.trim();
    // 链接Tab的文本优先用抓取结果
    if (_tabIndex == 3 && _linkExtractedText != null && _linkExtractedText!.isNotEmpty) {
      text = _linkExtractedText!;
      if (_linkController.text.trim().isNotEmpty) {
        text = '${_linkController.text.trim()}\n\n$text';
      }
    }

    final hasImages = _imageBase64List.isNotEmpty || _sharedImageBase64 != null;
    final hasFiles = _pickedFiles.isNotEmpty;
    if (text.isEmpty && !hasImages && !hasFiles) {
      setState(() => _errorMessage = '请添加文字、截图或文件');
      return;
    }

    final openai = ref.read(openaiServiceProvider);
    final hasKey = await openai.hasApiKey();
    if (!hasKey) {
      setState(() => _errorMessage = '请先在设置中配置 API Key（已为你预设小米 MiMo-V2.5）');
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
      _statusText = '正在分析内容...';
    });

    try {
      final analyzer = ref.read(contentAnalyzerProvider);
      setState(() => _statusText = 'AI 正在拆解知识点...');
      // 合并所有图片
      final allImages = <String>[];
      if (_sharedImageBase64 != null) allImages.add(_sharedImageBase64!);
      allImages.addAll(_imageBase64List);

      final result = await analyzer.analyze(
        text: text,
        imageBase64List: allImages.isEmpty ? null : allImages,
        files: hasFiles ? _pickedFiles : null,
        questionCount: _questionCounts[_tabIndex],
      );

      setState(() => _statusText = '正在生成题目...');
      await Future.delayed(const Duration(milliseconds: 500));

      if (mounted) {
        setState(() => _isAnalyzing = false);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DeckPreviewScreen(
              result: result,
              sourceText: text,
              sourceImage: _sharedImagePath,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _errorMessage = '分析失败: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _linkController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('添加内容'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.green,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.green,
          tabs: const [
            Tab(icon: Icon(Icons.text_fields, size: 20), text: '文字'),
            Tab(icon: Icon(Icons.photo_camera, size: 20), text: '截图'),
            Tab(icon: Icon(Icons.picture_as_pdf, size: 20), text: '文件'),
            Tab(icon: Icon(Icons.link, size: 20), text: '链接'),
          ],
        ),
      ),
      body: SafeArea(child: _isAnalyzing ? _buildLoadingView() : _buildTabView()),
    );
  }

  Widget _buildTabView() {
    return Column(
      children: [
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildTextTab(),
              _buildImageTab(),
              _buildFileTab(),
              _buildLinkTab(),
            ],
          ),
        ),
        // 错误信息
        if (_errorMessage != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.redLight, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.error, color: AppColors.red, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(_errorMessage!, style: const TextStyle(color: AppColors.redDark, fontSize: 14))),
            ]),
          ),
        // 出题量选择（随 tab 切换显示对应类型各自的题量）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.quiz, color: AppColors.green, size: 20),
              const SizedBox(width: 8),
              const Text('出题量', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const Spacer(),
              _buildCountStepperButton(Icons.remove, () => _setQuestionCount(_questionCounts[_tabIndex] - 1)),
              SizedBox(
                width: 64,
                child: Text(
                  '${_questionCounts[_tabIndex]} 道',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.textPrimary),
                ),
              ),
              _buildCountStepperButton(Icons.add, () => _setQuestionCount(_questionCounts[_tabIndex] + 1)),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: DuoButton(
            label: 'AI 拆解为题目',
            color: AppColors.green,
            width: double.infinity,
            height: 56,
            icon: Icons.auto_awesome,
            fontSize: 18,
            onPressed: _analyze,
          ),
        ),
      ],
    );
  }

  Widget _buildTextTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.blueLight, borderRadius: BorderRadius.circular(16)),
          child: const Row(children: [
            Icon(Icons.lightbulb, color: AppColors.blue, size: 24),
            SizedBox(width: 12),
            Expanded(child: Text('粘贴知乎、小红书等知识内容，AI自动拆题（新增问答题）', style: TextStyle(fontSize: 14, color: AppColors.blueDark, fontWeight: FontWeight.w600))),
          ]),
        ),
        const SizedBox(height: 16),
        if (_sharedImagePath != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(File(_sharedImagePath!), height: 160, width: double.infinity, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(height: 120, color: AppColors.surface, child: const Center(child: Icon(Icons.broken_image)))),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _textController,
          maxLines: 10,
          decoration: InputDecoration(
            hintText: '在此粘贴或输入要学习的内容...\n\n支持长文，AI会自动分块',
            hintStyle: const TextStyle(color: AppColors.textLight, height: 1.8),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.blue, width: 2)),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _pasteFromClipboard,
          icon: const Icon(Icons.content_paste, size: 20),
          label: const Text('从粘贴板粘贴'),
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.blue, side: const BorderSide(color: AppColors.blue, width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        ),
      ]),
    );
  }

  Widget _buildImageTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.greenLight, borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.info_outline, color: AppColors.green, size: 20),
            SizedBox(width: 8),
            Expanded(child: Text('截图/拍照 多选直传云端，无需本地OCR。支持图文混排', style: TextStyle(fontSize: 13, color: AppColors.greenDark, fontWeight: FontWeight.w600))),
          ]),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: _pickImages, icon: const Icon(Icons.photo_library), label: const Text('选图片(多选)'))),
          const SizedBox(width: 12),
          Expanded(child: OutlinedButton.icon(onPressed: _takePhoto, icon: const Icon(Icons.photo_camera), label: const Text('拍照'))),
        ]),
        if (_pickedImages.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('已选 ${_pickedImages.length} 张', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
            itemCount: _pickedImages.length,
            itemBuilder: (_, i) => ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(_pickedImages[i].path), fit: BoxFit.cover)),
          ),
          TextButton.icon(onPressed: () => setState(() { _pickedImages = []; _imageBase64List = []; }), icon: const Icon(Icons.clear), label: const Text('清空')),
        ],
        if (_sharedImagePath != null) ...[
          const SizedBox(height: 8),
          const Text('分享传入图片', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(_sharedImagePath!), height: 160, width: double.infinity, fit: BoxFit.cover)),
        ],
      ]),
    );
  }

  Widget _buildFileTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.cloud_upload, color: Color(0xFFE65100), size: 20),
            SizedBox(width: 8),
            Expanded(child: Text('PDF / Word 原文件直传云端（每文件≤10MB），模型原生读文档', style: TextStyle(fontSize: 13, color: Color(0xFFBF360C), fontWeight: FontWeight.w600))),
          ]),
        ),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _pickFiles, icon: const Icon(Icons.upload_file), label: const Text('选择 PDF / Word / 图片文件'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)))),
        if (_pickedFiles.isNotEmpty) ...[
          const SizedBox(height: 16),
          ..._pickedFiles.map((f) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
                child: Row(children: [
                  Icon(f.mime.contains('pdf') ? Icons.picture_as_pdf : Icons.description, color: AppColors.blue),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(f.filename, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(f.mime, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ])),
                  Text('${(f.base64.length * 3 / 4 / 1024).toStringAsFixed(0)} KB', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              )),
          TextButton.icon(onPressed: () => setState(() => _pickedFiles = []), icon: const Icon(Icons.clear), label: const Text('清空文件')),
        ],
      ]),
    );
  }

  Widget _buildLinkTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.blueLight, borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.language, color: AppColors.blue, size: 20),
            SizedBox(width: 8),
            Expanded(child: Text('粘贴文章链接，自动抓取正文（JS重型站建议用系统分享）', style: TextStyle(fontSize: 13, color: AppColors.blueDark, fontWeight: FontWeight.w600))),
          ]),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _linkController,
          decoration: InputDecoration(
            hintText: 'https://...',
            prefixIcon: const Icon(Icons.link),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            suffixIcon: _linkLoading
                ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : null,
          ),
          onSubmitted: (_) => _fetchLink(),
        ),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _linkLoading ? null : _fetchLink, icon: const Icon(Icons.download), label: Text(_linkLoading ? '抓取中...' : '抓取正文'))),
        if (_linkExtractedText != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.greenLight, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.check_circle, color: AppColors.green, size: 18),
                const SizedBox(width: 6),
                Text('已提取 ${_linkExtractedText!.length} 字', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.greenDark)),
              ]),
              const SizedBox(height: 8),
              Text(_linkExtractedText!.substring(0, _linkExtractedText!.length.clamp(0, 400)), style: const TextStyle(fontSize: 13, height: 1.5, color: AppColors.textPrimary)),
              if (_linkExtractedText!.length > 400) const Text('...', style: TextStyle(color: AppColors.textSecondary)),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _buildCountStepperButton(IconData icon, VoidCallback onPressed) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: const BoxDecoration(color: AppColors.greenLight, shape: BoxShape.circle),
        child: Icon(icon, color: AppColors.green, size: 20),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 80, height: 80, decoration: const BoxDecoration(color: AppColors.greenLight, shape: BoxShape.circle), child: const Icon(Icons.auto_awesome, color: AppColors.green, size: 40))
              .animate(onPlay: (c) => c.repeat()).shimmer(duration: 1500.ms),
          const SizedBox(height: 24),
          Text(_statusText, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          const Text('AI 正在分析内容并生成题目，请稍候...', style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
          const SizedBox(height: 32),
          const SizedBox(width: 200, child: LinearProgressIndicator(backgroundColor: AppColors.surface, color: AppColors.green, minHeight: 8, borderRadius: BorderRadius.all(Radius.circular(4)))),
        ]),
      ),
    );
  }
}
