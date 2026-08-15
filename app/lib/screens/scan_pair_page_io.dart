import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../main.dart';
import '../services/pairing.dart';

class ScanPairPage extends StatefulWidget {
  const ScanPairPage({super.key});

  @override
  State<ScanPairPage> createState() => _ScanPairPageState();
}

class _ScanPairPageState extends State<ScanPairPage> {
  final PairingService _pairing = PairingService();

  bool _busy = false;
  bool _failed = false;
  int _misses = 0;
  String _status = '将电脑上生成的配对二维码放入扫描框';

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

  void _onMiss(Code code) {
    if (!mounted || _busy) return;
    _misses += 1;
    final detail = code.error?.trim() ?? '';
    if (_failed) return;
    if (_misses > 20) {
      setState(() {
        _status = '持续识别不到？点击左下角相册图标，选择二维码截图也能绑定；'
            '或让二维码占满整个扫描框、避免反光。\n$detail';
      });
    } else if (_misses > 8) {
      setState(() {
        _status = '正在识别…请让二维码位于扫描框中央，保持手机稳定';
      });
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
            child: ReaderWidget(
              onScan: (code) {
                _misses = 0;
                final raw = code.text?.trim() ?? '';
                if (raw.isNotEmpty) _handleRaw(raw);
              },
              onScanFailure: _onMiss,
              resolution: ResolutionPreset.high,
              lensDirection: CameraLensDirection.back,
              cropPercent: 0.6,
              scanDelay: const Duration(milliseconds: 500),
              tryHarder: true,
              tryRotate: true,
              tryInverted: true,
              tryDownscale: true,
              showScannerOverlay: true,
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
