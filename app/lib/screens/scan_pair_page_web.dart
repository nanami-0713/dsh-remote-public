import 'package:flutter/material.dart';

import '../main.dart';
import '../services/pairing.dart';

/// Web fallback: the browser cannot use the native camera scanner yet, so the
/// user pastes the pairing URL (or its code) copied from the desktop page.
/// The Phase 2 web app will read the code directly from the QR link.
class ScanPairPage extends StatefulWidget {
  const ScanPairPage({super.key});

  @override
  State<ScanPairPage> createState() => _ScanPairPageState();
}

class _ScanPairPageState extends State<ScanPairPage> {
  final _urlController = TextEditingController();
  final PairingService _pairing = PairingService();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pairFromUrl() async {
    final invite = PairingInvite.tryParse(_urlController.text);
    if (invite == null) {
      setState(() => _error = '请输入完整的 dshremote://pair?... 配对链接');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _pairing.pair(invite, deviceName: '手机浏览器');
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is PairingException ? e.message : '配对失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('绑定设备', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '网页版暂不支持调用相机。请在电脑配对页点击「复制配对链接」，粘贴到这里。',
            style: TextStyle(color: kTextSecondary, fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '配对链接',
              hintText: 'http://100.x.x.x:8787/app/?code=...',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _pairFromUrl,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.link, size: 18),
            label: Text(_busy ? '正在配对，请到电脑上确认…' : '绑定'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
