import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../main.dart';
import '../services/pairing.dart';

class ScanPairPage extends StatefulWidget {
  const ScanPairPage({super.key});

  @override
  State<ScanPairPage> createState() => _ScanPairPageState();
}

class _ScanPairPageState extends State<ScanPairPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final PairingService _pairing = PairingService();

  bool _busy = false;
  String _status = '将电脑上生成的配对二维码放入取景框';
  bool _failed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleRaw(String raw) async {
    if (_busy) return;
    final invite = PairingInvite.tryParse(raw);
    if (invite == null) {
      if (!_failed) {
        setState(() {
          _failed = true;
          _status = '这不是 DSH-Remote 的配对二维码，请使用电脑上 http://127.0.0.1:8787/pair/qr 页面生成';
        });
      }
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
      _status = '正在向 ${invite.baseUrl} 发起配对…\n请到电脑上点击「允许」';
    });
    try {
      final deviceName = Platform.isIOS ? 'iOS 手机' : 'Android 手机';
      final result = await _pairing.pair(invite, deviceName: deviceName);
      if (!mounted) return;
      setState(() => _status = '配对成功，正在返回…');
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _status = e is PairingException ? e.message : '配对失败: $e';
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted && !_busy) {
        setState(() => _failed = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫码绑定', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kDshBlue),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: (capture) {
                    for (final barcode in capture.barcodes) {
                      final raw = barcode.rawValue;
                      if (raw != null && raw.isNotEmpty) {
                        _handleRaw(raw);
                        break;
                      }
                    }
                  },
                  errorBuilder: (context, error) {
                    return Center(
                      child: Container(
                        margin: const EdgeInsets.all(24),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '无法打开相机，请检查相机权限后重试。\n$error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.black87),
                        ),
                      ),
                    );
                  },
                ),
                Center(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      border: Border.all(color: kDshBlue, width: 3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: kSurface,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: _failed ? const Color(0xFFB91C1C) : kTextPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
