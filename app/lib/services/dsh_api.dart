import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

class DshApi {
  final String baseUrl;
  final String token;

  DshApi({required this.baseUrl, required this.token});

  Uri _uri(String method) => Uri.parse('$baseUrl/api/$method');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  String _rpcId() {
    final rand = Random().nextInt(0x7fffffff).toRadixString(16);
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-$rand';
  }

  Future<Map<String, dynamic>> _post(
    String method,
    Map<String, dynamic> payload,
  ) async {
    final body = jsonEncode({
      'type': 'client-request',
      'rpcId': _rpcId(),
      'method': method,
      'payload': payload,
    });
    final res = await http
        .post(_uri(method), headers: _headers, body: body)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 401) {
      throw Exception('Unauthorized: 请检查 Token');
    }
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final result = decoded['result'] as Map<String, dynamic>?;
    if (result == null || result['ok'] != true) {
      final error = result?['error'] as Map<String, dynamic>?;
      throw Exception(error?['message'] ?? 'DSH API error');
    }
    return (result['value'] as Map<String, dynamic>?) ?? {};
  }

  Future<List<Map<String, dynamic>>> listSessions() async {
    final value = await _post('session.list', {});
    final items = (value['items'] as List<dynamic>? ?? []);
    return items.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createSession({String? cwd}) async {
    return _post('session.create', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
  }

  Future<void> prompt(String sessionId, String text) async {
    await _post('session.prompt', {
      'sessionId': sessionId,
      'mode': 'steer',
      'content': [
        {'type': 'text', 'text': text},
      ],
    });
  }

  Future<List<Map<String, dynamic>>> history(String sessionId) async {
    final value = await _post('session.history', {
      'sessionId': sessionId,
    });
    final events = (value['events'] as List<dynamic>? ?? []);
    return events.cast<Map<String, dynamic>>();
  }

  Future<void> cancel(String sessionId) async {
    await _post('session.cancel', {'sessionId': sessionId});
  }

  Future<void> respondApproval({
    required String sessionId,
    required String approvalId,
    required String outcome,
    String? rpcId,
  }) async {
    await _postClientResponse(rpcId ?? _rpcId(), {
      'sessionId': sessionId,
      'approvalId': approvalId,
      'outcome': outcome,
    });
  }

  Future<void> respondQuestion({
    required String sessionId,
    required List<Map<String, dynamic>> answers,
    String? rpcId,
  }) async {
    await _postClientResponse(rpcId ?? _rpcId(), {
      'sessionId': sessionId,
      'answer': {'answers': answers},
    });
  }

  Future<void> _postClientResponse(String rpcId, Map<String, dynamic> value) async {
    final body = jsonEncode({
      'type': 'client-response',
      'rpcId': rpcId,
      'result': {'ok': true, 'value': value},
    });
    final res = await http
        .post(_uri('respond'), headers: _headers, body: body)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
  }
}
