import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/dsh_api.dart';
import '../services/dsh_stream.dart';

class ChatScreen extends StatefulWidget {
  final DshApi api;
  final String baseUrl;
  final String token;
  final String sessionId;
  final String title;

  const ChatScreen({
    super.key,
    required this.api,
    required this.baseUrl,
    required this.token,
    required this.sessionId,
    required this.title,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _LogLine {
  final String kind;
  final String text;

  _LogLine(this.kind, this.text);
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_LogLine> _lines = [];
  DshStream? _stream;
  bool _sending = false;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _connectStream();
  }

  @override
  void dispose() {
    _stream?.disconnect();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final entries = await widget.api.history(widget.sessionId);
      if (!mounted) return;
      for (final entry in entries) {
        final event = entry['event'] as Map<String, dynamic>?;
        if (event == null) continue;
        _appendEvent(event);
      }
      _scrollToBottom();
    } catch (e) {
      _addLine('error', '加载历史失败: $e');
    }
  }

  void _connectStream() {
    _stream = DshStream(baseUrl: widget.baseUrl, token: widget.token);
    _stream!.connect((frame) {
      if (!mounted) return;
      final payload = frame['payload'] as Map<String, dynamic>?;
      if (payload == null) return;
      if (payload['type'] == 'session/event') {
        final event = payload['event'] as Map<String, dynamic>?;
        if (event != null) _appendEvent(event);
      } else if (payload['type'] == 'session/queue') {
        _addLine('system', '📋 队列更新');
      } else if (payload['type'] == 'approval/requested') {
        _handleApprovalRequested(frame, payload);
      } else if (payload['type'] == 'question/requested') {
        _handleQuestionRequested(frame, payload);
      }
      _scrollToBottom();
    });
  }

  void _handleApprovalRequested(Map<String, dynamic> frame, Map<String, dynamic> payload) {
    final sessionId = payload['sessionId'] as String? ?? widget.sessionId;
    final approvalId = payload['approvalId'] as String? ?? '';
    final toolName = payload['toolName'] as String? ?? '';
    final reason = payload['reason'] as String? ?? '';
    final rpcId = frame['rpcId'] as String?;
    _addLine('system', '🔐 需要批准: $toolName${reason.isNotEmpty ? ' ($reason)' : ''}');
    if (_dialogOpen) return;
    _dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('DSH 请求批准'),
        content: Text('工具: $toolName\n原因: $reason'),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              _dialogOpen = false;
              try {
                await widget.api.respondApproval(
                  sessionId: sessionId,
                  approvalId: approvalId,
                  outcome: 'rejected',
                  rpcId: rpcId,
                );
                _addLine('system', '❌ 已拒绝');
              } catch (e) {
                _addLine('error', '拒绝失败: $e');
              }
            },
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              _dialogOpen = false;
              try {
                await widget.api.respondApproval(
                  sessionId: sessionId,
                  approvalId: approvalId,
                  outcome: 'allowed-once',
                  rpcId: rpcId,
                );
                _addLine('system', '✅ 已允许一次');
              } catch (e) {
                _addLine('error', '允许失败: $e');
              }
            },
            child: const Text('允许一次'),
          ),
        ],
      ),
    );
  }

  void _handleQuestionRequested(Map<String, dynamic> frame, Map<String, dynamic> payload) {
    final sessionId = payload['sessionId'] as String? ?? widget.sessionId;
    final questions = (payload['questions'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final rpcId = frame['rpcId'] as String?;
    if (questions.isEmpty) return;
    _addLine('system', '❓ 收到 ${questions.length} 个问题');
    if (_dialogOpen) return;
    _dialogOpen = true;

    final selected = <String, Set<String>>{};
    for (final q in questions) {
      selected[q['id'] as String? ?? ''] = <String>{};
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('DSH 提问'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final q in questions)
                    _QuestionBlock(
                      question: q,
                      selected: selected[q['id'] as String? ?? '']!,
                      onChanged: (id, checked) {
                        setDialogState(() {
                          final set = selected[q['id'] as String? ?? '']!;
                          final multi = q['multiSelect'] == true;
                          if (multi) {
                            if (checked) {
                              set.add(id);
                            } else {
                              set.remove(id);
                            }
                          } else {
                            set
                              ..clear()
                              ..add(id);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _dialogOpen = false;
                },
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  final answers = questions.map((q) {
                    final id = q['id'] as String? ?? '';
                    return <String, dynamic>{
                      'id': id,
                      'selected': selected[id]?.toList() ?? <String>[],
                    };
                  }).toList();
                  Navigator.pop(ctx);
                  _dialogOpen = false;
                  try {
                    await widget.api.respondQuestion(
                      sessionId: sessionId,
                      answers: answers,
                      rpcId: rpcId,
                    );
                    _addLine('system', '✅ 已提交回答');
                  } catch (e) {
                    _addLine('error', '提交回答失败: $e');
                  }
                },
                child: const Text('提交'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _appendEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? 'unknown';
    final data = event['data'] as Map<String, dynamic>? ?? {};
    switch (type) {
      case 'user/message':
        _addLine('user', _textFromContent(data['content']));
        break;
      case 'assistant/message':
        _addLine('assistant', _textFromMessage(data['message']));
        break;
      case 'assistant/chunk':
        final chunk = data['chunk'] as Map<String, dynamic>?;
        if (chunk != null && chunk['type'] == 'text') {
          _addLine('assistant', chunk['text']?.toString() ?? '');
        }
        break;
      case 'tool/call':
        _addLine('tool', '🔧 ${data['name']}(${data['arguments']})');
        break;
      case 'tool/result':
        _addLine('tool', '📦 ${_compact(data['message'])}');
        break;
      case 'turn/start':
        _addLine('system', '▶️ 开始执行');
        break;
      case 'turn/end':
        _addLine('system', '✅ 执行结束');
        break;
      default:
        if (type.startsWith('session/') ||
            type.startsWith('assistant/') ||
            type.startsWith('user/') ||
            type.startsWith('tool/') ||
            type.startsWith('step/') ||
            type.startsWith('turn/')) {
          _addLine('event', '[$type] ${_compact(data)}');
        }
    }
  }

  String _textFromMessage(dynamic message) {
    if (message is! Map<String, dynamic>) return '';
    final content = message['content'];
    return _textFromContent(content);
  }

  String _textFromContent(dynamic content) {
    if (content is! List) return '';
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is Map<String, dynamic>) {
        if (block['type'] == 'text') {
          buffer.write(block['text']?.toString() ?? '');
        } else if (block['type'] == 'image') {
          buffer.write(' [图片] ');
        }
      }
    }
    return buffer.toString();
  }

  String _compact(dynamic value) {
    if (value == null) return '';
    final s = value is String ? value : jsonEncode(value);
    return s.length > 300 ? '${s.substring(0, 300)}...' : s;
  }

  void _addLine(String kind, String text) {
    if (text.isEmpty) return;
    setState(() {
      _lines.add(_LogLine(kind, text));
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _addLine('user', text);
    _inputController.clear();
    try {
      await widget.api.prompt(widget.sessionId, text);
    } catch (e) {
      _addLine('error', '发送失败: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.api.cancel(widget.sessionId);
      _addLine('system', '⏹️ 已发送取消');
    } catch (e) {
      _addLine('error', '取消失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '取消当前任务',
            onPressed: _cancel,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                final line = _lines[index];
                return _LogTile(line: line);
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '输入要发送给 DSH 的指令…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionBlock extends StatelessWidget {
  final Map<String, dynamic> question;
  final Set<String> selected;
  final void Function(String id, bool checked) onChanged;

  const _QuestionBlock({
    required this.question,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final text = question['question'] as String? ?? '';
    final options = (question['options'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final multi = question['multiSelect'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          for (final opt in options)
            CheckboxListTile(
              dense: true,
              title: Text(opt['label']?.toString() ?? ''),
              subtitle: opt['description'] != null
                  ? Text(opt['description'].toString(), style: const TextStyle(fontSize: 12))
                  : null,
              value: selected.contains(opt['label']?.toString() ?? ''),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: multi
                  ? (checked) => onChanged(opt['label']?.toString() ?? '', checked ?? false)
                  : (checked) {
                      if (checked == true) {
                        onChanged(opt['label']?.toString() ?? '', true);
                      }
                    },
            ),
          if (options.isEmpty)
            TextField(
              decoration: const InputDecoration(hintText: '输入回答'),
              onSubmitted: (value) => onChanged(value, true),
            ),
        ],
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final _LogLine line;

  const _LogTile({required this.line});

  @override
  Widget build(BuildContext context) {
    final (background, foreground, icon) = switch (line.kind) {
      'user' => (Colors.blue.shade50, Colors.black87, Icons.person),
      'assistant' => (Colors.green.shade50, Colors.black87, Icons.smart_toy_outlined),
      'tool' => (Colors.orange.shade50, Colors.black87, Icons.build_outlined),
      'error' => (Colors.red.shade50, Colors.red.shade900, Icons.error_outline),
      'system' => (Colors.grey.shade100, Colors.black54, Icons.info_outline),
      _ => (Colors.grey.shade50, Colors.black54, Icons.chevron_right),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              line.text,
              style: TextStyle(color: foreground, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
