// Integration check: Flutter app service layer -> bridge -> DSH.
// Run from app/ with the bridge already running:
//   dart run tool/bridge_integration_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/services/dsh_api.dart';
import 'package:dsh_remote/services/dsh_stream.dart';

Future<void> main() async {
  final configFile = File('../bridge/config.json');
  if (!await configFile.exists()) {
    stderr.writeln('bridge/config.json not found');
    exitCode = 1;
    return;
  }
  final config = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  final token = config['token'] as String;
  const baseUrl = 'http://127.0.0.1:8787';

  final api = DshApi(baseUrl: baseUrl, token: token);

  final sessions = await api.listSessions();
  stdout.writeln('session.list OK: ${sessions.length} sessions');

  final created = await api.createSession(cwd: '.');
  final sessionId = created['sessionId'] as String;
  stdout.writeln('session.create OK: $sessionId');

  final stream = DshStream(baseUrl: baseUrl, token: token);
  final reply = Completer<String>();
  final timer = Timer(const Duration(seconds: 15), () {
    if (!reply.isCompleted) reply.completeError(TimeoutException('no assistant message'));
  });

  stream.connect((frame) {
    final payload = frame['payload'];
    if (payload is Map<String, dynamic> && payload['type'] == 'session/event') {
      final event = payload['event'];
      if (event is Map<String, dynamic> && event['type'] == 'assistant/message') {
        final data = event['data'] as Map<String, dynamic>? ?? {};
        final message = data['message'] as Map<String, dynamic>? ?? {};
        final content = message['content'] as List<dynamic>? ?? [];
        final text = content
            .whereType<Map<String, dynamic>>()
            .where((b) => b['type'] == 'text')
            .map((b) => b['text']?.toString() ?? '')
            .join();
        if (text.isNotEmpty && !reply.isCompleted) {
          reply.complete(text);
        }
      }
    }
  });

  // Give the WebSocket subscription a moment to attach before prompting.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await api.prompt(sessionId, '只回复OK');
  stdout.writeln('session.prompt OK');

  final text = await reply.future;
  timer.cancel();
  stream.disconnect();
  stdout.writeln('stream assistant reply: $text');
  if (!text.contains('OK')) {
    stderr.writeln('unexpected reply: $text');
    exitCode = 1;
  }
}
