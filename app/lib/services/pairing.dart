import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class PairingInvite {
  const PairingInvite({
    required this.baseUrl,
    required this.code,
    required this.version,
  });

  final String baseUrl;
  final String code;
  final int version;

  /// Parses both pairing formats:
  ///  - `http(s)://host:port/app/?code=...` (system camera opens the web app)
  ///  - legacy `dshremote://pair?base=...&code=...&v=1` (in-app scan)
  static PairingInvite? tryParse(String raw) {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final code = uri.queryParameters['code']?.trim() ?? '';
    if (code.length < 20 || code.length > 256) return null;

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      if (uri.path != '/app' && !uri.path.startsWith('/app/')) return null;
      final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      final base = '$scheme://$authority';
      return PairingInvite(baseUrl: base, code: code, version: 1);
    }

    if (scheme == 'dshremote' && uri.host.toLowerCase() == 'pair') {
      final base = uri.queryParameters['base']?.trim() ?? '';
      final version = int.tryParse(uri.queryParameters['v'] ?? '') ?? 0;
      if (!base.startsWith('http://') && !base.startsWith('https://')) {
        return null;
      }
      return PairingInvite(baseUrl: base, code: code, version: version);
    }
    return null;
  }
}

class PairingResult {
  const PairingResult({
    required this.baseUrl,
    required this.token,
    required this.deviceId,
    required this.deviceName,
    this.bridgeName = '',
  });

  final String baseUrl;
  final String token;
  final String deviceId;
  final String deviceName;

  /// Human-friendly name of the PC (bridge hostname), used to label the
  /// endpoint in the multi-PC list. Empty when talking to an older bridge.
  final String bridgeName;
}

class PairingException implements Exception {
  const PairingException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

class PairingService {
  PairingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _pollInterval = Duration(seconds: 1);
  static const _requestTimeout = Duration(seconds: 10);

  Future<PairingResult> pair(PairingInvite invite,
      {required String deviceName}) async {
    final base = invite.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final claim = await _postJson(
      Uri.parse('$base/pair/claim'),
      {'code': invite.code, 'deviceName': deviceName},
    );
    final status = claim['status'] as String?;
    if (status == 'approved') {
      return _resultFrom(base, claim);
    }
    if (status != 'pending') {
      final error = claim['error'] as String? ?? '配对码无效或已使用';
      throw PairingException(error, retryable: false);
    }

    final pairId = claim['pairId'] as String?;
    if (pairId == null || pairId.isEmpty) {
      throw const PairingException('服务端未返回配对请求 ID');
    }
    final expiresAt = (claim['expiresAt'] as num?)?.toInt() ?? 0;

    while (true) {
      if (expiresAt > 0 && DateTime.now().millisecondsSinceEpoch > expiresAt) {
        throw const PairingException('配对确认超时，请在电脑上重新生成二维码', retryable: true);
      }
      await Future<void>.delayed(_pollInterval);
      final poll = await _getJson(Uri.parse(
          '$base/pair/status?id=${Uri.encodeQueryComponent(pairId)}'));
      final pollStatus = poll['status'] as String?;
      if (pollStatus == 'approved') {
        final token = poll['token'] as String?;
        if (token == null || token.isEmpty) {
          throw const PairingException('配对已通过，但设备令牌已失效，请重新扫码', retryable: true);
        }
        return _resultFrom(base, poll);
      }
      if (pollStatus == 'rejected' || pollStatus == 'denied') {
        throw const PairingException('配对被电脑端拒绝', retryable: true);
      }
      // still pending: keep polling
    }
  }

  PairingResult _resultFrom(String base, Map<String, dynamic> json) {
    final token = json['token'] as String?;
    final device = json['device'] as Map<String, dynamic>?;
    if (token == null || token.isEmpty) {
      throw const PairingException('配对成功但未返回设备令牌', retryable: true);
    }
    return PairingResult(
      baseUrl: base,
      token: token,
      deviceId: device?['id'] as String? ?? '',
      deviceName: device?['name'] as String? ?? '',
      bridgeName: json['bridgeName'] as String? ?? '',
    );
  }

  Future<Map<String, dynamic>> _postJson(
      Uri uri, Map<String, dynamic> body) async {
    final res = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_requestTimeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final res = await _client.get(uri).timeout(_requestTimeout);
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode == 401) {
      throw const PairingException('未授权，请重新扫码');
    }
    if (res.statusCode == 404) {
      throw const PairingException('配对码无效或已使用，请重新生成二维码', retryable: true);
    }
    if (res.statusCode == 410) {
      throw const PairingException('配对码已过期，请重新生成二维码', retryable: true);
    }
    if (res.statusCode == 429) {
      throw const PairingException('尝试过于频繁，请稍后再试', retryable: true);
    }
    if (res.statusCode != 200) {
      throw PairingException('配对服务异常 (HTTP ${res.statusCode})',
          retryable: true);
    }
    try {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const PairingException('配对服务返回了无法解析的数据', retryable: true);
    }
  }
}
