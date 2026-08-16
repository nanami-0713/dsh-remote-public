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
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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

  Future<Map<String, dynamic>> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
  }) async {
    return _post('session.create', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (workspaceId != null && workspaceId.isNotEmpty)
        'workspaceId': workspaceId,
      if (agentPreset != null && agentPreset.isNotEmpty)
        'agentPreset': agentPreset,
    });
  }

  /// Read-only list of the workspaces already registered on this PC.
  /// The bridge deliberately does NOT expose `host.listDirectory`: a phone
  /// may pick a work folder, but it may not browse the whole filesystem.
  Future<List<Map<String, dynamic>>> listWorkspaces() async {
    final value = await _post('workspace.list', {});
    final items = (value['items'] as List<dynamic>? ?? []);
    return items.cast<Map<String, dynamic>>();
  }

  /// The global model catalog (provider groups / models) exposed by the host.
  /// Used before a session exists so the phone can offer model selection in
  /// the new-session flow.
  Future<Map<String, dynamic>> listModels() async {
    return _post('llm.models', {});
  }

  Future<List<Map<String, dynamic>>> listAgentPresets() async {
    final value = await _post('agentPreset.list', {});
    final items = (value['presets'] as List<dynamic>? ?? []);
    return items.cast<Map<String, dynamic>>();
  }

  /// Current model selection and catalog for an existing session.
  Future<Map<String, dynamic>> sessionModels(String sessionId) async {
    return _post('session.models', {'sessionId': sessionId});
  }

  Future<Map<String, dynamic>> selectModel({
    required String sessionId,
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    return _post('session.selectModel', {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      if (reasoningEffort != null && reasoningEffort.isNotEmpty)
        'reasoningEffort': reasoningEffort,
    });
  }

  Future<void> prompt(String sessionId, String text) async {
    await promptContent(sessionId, [
      {'type': 'text', 'text': text},
    ]);
  }

  /// [content] follows the DSH wire format:
  ///   {'type': 'text', 'text': ...}
  ///   {'type': 'image', 'mediaType': 'image/png', 'data': '<base64>', 'name': ...}
  Future<void> promptContent(
    String sessionId,
    List<Map<String, dynamic>> content,
  ) async {
    await _post('session.prompt', {
      'sessionId': sessionId,
      'mode': 'steer',
      'content': content,
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

  Future<void> _postClientResponse(
      String rpcId, Map<String, dynamic> value) async {
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
