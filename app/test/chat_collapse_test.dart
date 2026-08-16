import 'dart:convert';

import 'package:dsh_remote/screens/chat_screen.dart';
import 'package:dsh_remote/services/dsh_api.dart';
import 'package:dsh_remote/services/dsh_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends DshApi {
  _FakeApi(this.entries) : super(baseUrl: 'http://127.0.0.1:1', token: 'x');

  final List<Map<String, dynamic>> entries;

  @override
  Future<List<Map<String, dynamic>>> history(String sessionId) async => entries;
}

class _FakeStream extends DshStream {
  _FakeStream() : super(baseUrl: 'http://127.0.0.1:1', token: 'x');

  @override
  void connect(void Function(Map<String, dynamic> frame) onFrame) {}
}

Map<String, dynamic> _entry(String type, Map<String, dynamic> data) => {
      'event': {'type': type, 'seq': 1, 'time': 1, 'data': data}
    };

void main() {
  testWidgets('step/tool details are collapsed until expanded', (tester) async {
    final entries = [
      _entry('user/message', {
        'content': [
          {'type': 'text', 'text': '开始干活'}
        ],
      }),
      _entry('step/start', {'turn': 1, 'step': 1}),
      _entry('tool/call', {
        'turn': 1,
        'step': 1,
        'name': 'read',
        'arguments': jsonEncode({'file_path': '/tmp/a.txt'}),
      }),
      _entry('tool/result', {
        'turn': 1,
        'step': 1,
        'message': {
          'content': [
            {
              'type': 'tool-result',
              'toolCallId': 'call-1',
              'content': [
                {'type': 'text', 'text': 'file content'}
              ],
            }
          ]
        },
      }),
      _entry('step/end', {'turn': 1, 'step': 1}),
      _entry('assistant/chunk', {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'text', 'index': 0, 'text': 'Hello'},
      }),
      _entry('assistant/chunk', {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'text', 'index': 0, 'text': ' world'},
      }),
      _entry('assistant/message', {
        'turn': 1,
        'step': 1,
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Hello world'}
          ],
        },
      }),
      _entry('step/start', {'turn': 1, 'step': 2}),
      _entry('tool/call', {
        'turn': 1,
        'step': 2,
        'name': 'bash',
        'arguments': '{"command": "pwd"}',
      }),
      _entry('tool/result', {
        'turn': 1,
        'step': 2,
        'message': {
          'content': [
            {
              'type': 'tool-result',
              'toolCallId': 'call-2',
              'content': [
                {'type': 'text', 'text': '/tmp'}
              ],
            }
          ]
        },
      }),
      _entry('step/end', {'turn': 1, 'step': 2}),
      _entry('assistant/message', {
        'turn': 1,
        'step': 2,
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Done'}
          ],
        },
      }),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          api: _FakeApi(entries),
          baseUrl: 'http://127.0.0.1:1',
          token: 'x',
          sessionId: 's',
          title: '测试会话',
          streamFactory: _FakeStream.new,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Step headers are present, detail lines are not built while collapsed.
    expect(find.text('第 1 轮 · 第 1 步'), findsOneWidget);
    expect(find.text('第 1 轮 · 第 2 步'), findsOneWidget);
    expect(find.textContaining('🔧 read'), findsNothing);
    expect(find.textContaining('file content'), findsNothing);

    // Streaming chunks were replaced by the complete assistant message.
    expect(find.text('Hello world'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);

    // Expanding one step reveals its call and result details.
    await tester.tap(find.text('第 1 轮 · 第 1 步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('🔧 read'), findsOneWidget);
    expect(find.textContaining('file content'), findsOneWidget);

    // The other step stays collapsed.
    expect(find.textContaining('🔧 bash'), findsNothing);
  });

  testWidgets('thousands of assistant chunks fold into one message bubble',
      (tester) async {
    final entries = <Map<String, dynamic>>[
      for (var i = 0; i < 3000; i++)
        _entry('assistant/chunk', {
          'turn': 1,
          'step': 1,
          'chunk': {'type': 'text', 'index': 0, 'text': 'x'},
        }),
      _entry('assistant/message', {
        'turn': 1,
        'step': 1,
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'x' * 3000}
          ],
        },
      }),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          api: _FakeApi(entries),
          baseUrl: 'http://127.0.0.1:1',
          token: 'x',
          sessionId: 's',
          title: '测试会话',
          streamFactory: _FakeStream.new,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One complete assistant bubble, not 3000 one-token bubbles.
    expect(find.textContaining('xxxxxxxxxx'), findsOneWidget);
  });
}
