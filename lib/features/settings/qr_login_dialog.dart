import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/constants/app_colors.dart';
import '../../core/providers/providers.dart';
import '../../services/bilibili_service.dart';

/// B站扫码登录弹窗：展示二维码 + 每2秒轮询登录状态，
/// 用户用B站APP扫码确认后自动提取 SESSDATA 保存并关闭（pop(true)）。
class QrLoginDialog extends ConsumerStatefulWidget {
  const QrLoginDialog({super.key});

  /// 打开弹窗，返回 true 表示登录成功
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const QrLoginDialog(),
    );
    return result == true;
  }

  @override
  ConsumerState<QrLoginDialog> createState() => _QrLoginDialogState();
}

class _QrLoginDialogState extends ConsumerState<QrLoginDialog> {
  BiliQrCode? _qr;
  String _status = '正在生成二维码...';
  String? _error;
  Timer? _timer;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _createQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _createQr() async {
    _timer?.cancel();
    if (mounted) {
      setState(() {
        _qr = null;
        _error = null;
        _status = '正在生成二维码...';
      });
    }
    try {
      final qr = await ref.read(bilibiliServiceProvider).createQrLogin();
      if (!mounted) return;
      setState(() {
        _qr = qr;
        _status = '打开B站APP扫一扫';
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        _status = '二维码生成失败';
      });
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling || _qr == null || !mounted) return;
    _polling = true;
    try {
      final state = await ref.read(bilibiliServiceProvider).pollQrLogin(_qr!.qrcodeKey);
      if (!mounted) return;
      switch (state.code) {
        case BiliQrPollState.success:
          _timer?.cancel();
          Navigator.of(context).pop(true);
          return;
        case BiliQrPollState.scannedNotConfirmed:
          setState(() => _status = '已扫码，请在手机上确认登录');
        case BiliQrPollState.expired:
          await _createQr();
        case BiliQrPollState.notScanned:
          setState(() => _status = '打开B站APP扫一扫');
        default:
          setState(() => _status = state.message);
      }
    } catch (_) {
      if (mounted) setState(() => _status = '网络波动，重试中...');
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const Icon(Icons.smart_display, color: Color(0xFFFB7299), size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('B站扫码登录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ]),
            const SizedBox(height: 8),
            Container(
              width: 220,
              height: 220,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border, width: 2),
              ),
              child: _qr == null
                  ? Center(
                      child: _error != null
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.error_outline, color: AppColors.red, size: 36),
                                const SizedBox(height: 8),
                                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: AppColors.red)),
                              ],
                            )
                          : const CircularProgressIndicator(color: AppColors.green),
                    )
                  : QrImageView(
                      data: _qr!.qrUrl,
                      version: QrVersions.auto,
                      size: 200,
                      backgroundColor: Colors.white,
                    ),
            ),
            const SizedBox(height: 14),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            const Text(
              '二维码仅用于登录B站，SESSDATA 只保存在本机',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _createQr,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新二维码'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('取消'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.red, foregroundColor: Colors.white),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
