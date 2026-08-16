import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../services/dsh_api.dart';
import '../services/dsh_stream.dart';

class ChatScreen extends StatefulWidget {
  final DshApi api;
  final String baseUrl;
  final String token;
  final String sessionId;
  final String title;

  /// Test seam: lets widget tests replace the real WebSocket with a no-op.
  final DshStream Function()? streamFactory;

  const ChatScreen({
    super.key,
    required this.api,
    required this.baseUrl,
    required this.token,
    required this.sessionId,
    required this.title,
    this.streamFactory,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _LogLine {
  _LogLine({
    required this.id,
    required this.kind,
    required this.text,
    this.process = false,
    this.stepKey = '',
    this.chunkKey,
  });

  final int id;
  final String kind;
  String text;

  /// True for step/tool detail lines: these are folded into the collapsible
  /// per-step process cards instead of being printed as standalone bubbles.
  final bool process;

  /// `turn:step` identity used to group process lines into one expandable
  /// "step" card.
  final String stepKey;

  /// Identity of the live assistant text stream this line belongs to, so
  /// `assistant/chunk` deltas can update one bubble instead of adding a new
  /// bubble per token.
  final String? chunkKey;
}

class _ProcessGroup {
  _ProcessGroup(this.stepKey, this.lines);

  final String stepKey;
  final List<_LogLine> lines;

  int get toolCallCount => lines.where((l) => l.kind == 'tool-call').length;
  int get toolResultCount => lines.where((l) => l.kind == 'tool-result').length;
}

/// One image queued in the composer, already read into memory as base64-ready
/// bytes with the DSH wire media type resolved.
class _PendingImage {
  final String name;
  final String mediaType;
  final Uint8List bytes;

  _PendingImage({
    required this.name,
    required this.mediaType,
    required this.bytes,
  });
}

class _ChatScreenState extends State<ChatScreen> {
  static const _maxImageBytes = 5 * 1024 * 1024;

  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_LogLine> _lines = [];
  final List<_PendingImage> _pendingImages = [];
  final ImagePicker _picker = ImagePicker();

  /// Live assistant text buffers keyed by `turn:step:blockIndex`. StringBuffer
  /// avoids quadratic string concatenation when a message streams thousands
  /// of one-token deltas.
  final Map<String, _LogLine> _chunkLines = {};
  final Map<String, StringBuffer> _chunkBuffers = {};

  DshStream? _stream;
  Timer? _refreshTimer;
  int _nextLineId = 0;
  bool _sending = false;
  bool _pickingImages = false;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _connectStream();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _stream?.disconnect();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final entries = await widget.api.history(widget.sessionId);
      if (!mounted) return;
      // Append without per-event setState: a single conversation may contain
      // tens of thousands of assistant/chunk events and calling setState for
      // every one of them is what made history loading take forever.
      for (final entry in entries) {
        final event = entry['event'] as Map<String, dynamic>?;
        if (event == null) continue;
        _appendEvent(event, notify: false);
      }
      if (!mounted) return;
      _flushChunkBuffers();
      setState(() {});
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      _addLine('error', '加载历史失败: $e');
    }
  }

  void _connectStream() {
    _stream = widget.streamFactory?.call() ??
        DshStream(baseUrl: widget.baseUrl, token: widget.token);
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

  void _handleApprovalRequested(
      Map<String, dynamic> frame, Map<String, dynamic> payload) {
    final sessionId = payload['sessionId'] as String? ?? widget.sessionId;
    final approvalId = payload['approvalId'] as String? ?? '';
    final toolName = payload['toolName'] as String? ?? '';
    final reason = payload['reason'] as String? ?? '';
    final rpcId = frame['rpcId'] as String?;
    _addLine(
        'system', '🔐 需要批准: $toolName${reason.isNotEmpty ? ' ($reason)' : ''}');
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

  void _handleQuestionRequested(
      Map<String, dynamic> frame, Map<String, dynamic> payload) {
    final sessionId = payload['sessionId'] as String? ?? widget.sessionId;
    final questions = (payload['questions'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
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

  void _appendEvent(Map<String, dynamic> event, {bool notify = true}) {
    final type = event['type'] as String? ?? 'unknown';
    final data = event['data'] as Map<String, dynamic>? ?? {};
    switch (type) {
      case 'user/message':
        _addLine('user', _textFromContent(data['content']), notify: notify);
        break;
      case 'assistant/message':
        _handleAssistantMessage(data['message'], data, notify: notify);
        break;
      case 'assistant/chunk':
        _handleAssistantChunk(data['chunk'], data, notify: notify);
        break;
      case 'tool/call':
        _addLine(
          'tool-call',
          _formatToolCall(data),
          process: true,
          stepKey: _stepKey(data),
          notify: notify,
        );
        break;
      case 'tool/result':
        _addLine(
          'tool-result',
          _formatToolResult(data),
          process: true,
          stepKey: _stepKey(data),
          notify: notify,
        );
        break;
      case 'turn/start':
        _addLine('system', '▶️ 开始执行', notify: notify);
        break;
      case 'turn/end':
        _addLine('system', '✅ 执行结束', notify: notify);
        break;
      default:
        // step/start and step/end carry no content; the per-step card header
        // already identifies each step.
        if (type.startsWith('step/')) break;
        if (type.startsWith('session/') ||
            type.startsWith('assistant/') ||
            type.startsWith('user/') ||
            type.startsWith('tool/') ||
            type.startsWith('turn/')) {
          final process = type.startsWith('tool/');
          _addLine(
            process ? 'event' : 'system',
            '[$type] ${_compact(data)}',
            process: process,
            stepKey: _stepKey(data),
            notify: notify,
          );
        }
    }
  }

  void _handleAssistantMessage(
    dynamic message,
    Map<String, dynamic> data, {
    required bool notify,
  }) {
    final prefix = '${data['turn'] ?? '-'}:${data['step'] ?? '-'}:';
    // Replace any streaming chunk bubble(s) for this message with the final,
    // complete assistant message. This also keeps history free of thousands
    // of one-token bubbles.
    final staleKeys =
        _chunkLines.keys.where((key) => key.startsWith(prefix)).toList();
    for (final key in staleKeys) {
      final line = _chunkLines.remove(key);
      _chunkBuffers.remove(key);
      if (line != null) _lines.remove(line);
    }
    final text = _textFromMessage(message);
    _addLine('assistant', text, notify: notify);
  }

  void _handleAssistantChunk(
    dynamic chunk,
    Map<String, dynamic> data, {
    required bool notify,
  }) {
    if (chunk is! Map<String, dynamic>) return;
    if (chunk['type'] != 'text') return;
    final delta = chunk['text']?.toString() ?? '';
    if (delta.isEmpty) return;
    final key = '${data['turn'] ?? '-'}:${data['step'] ?? '-'}:'
        '${chunk['index'] ?? 0}';
    final buffer = _chunkBuffers[key] ??= StringBuffer();
    final existing = _chunkLines[key];
    buffer.write(delta);
    if (existing == null) {
      final line = _addLine(
        'assistant',
        delta,
        chunkKey: key,
        notify: false,
      );
      if (line != null) _chunkLines[key] = line;
    }
    if (notify) _scheduleRefresh();
  }

  String _stepKey(Map<String, dynamic> data) {
    final turn = data['turn'];
    final step = data['step'];
    if (turn == null && step == null) return 'unknown';
    return '$turn:$step';
  }

  String _formatToolCall(Map<String, dynamic> data) {
    final name = data['name']?.toString() ?? 'unknown';
    final rawArgs = data['arguments'];
    if (rawArgs == null) return '🔧 $name';
    if (rawArgs is String) {
      if (rawArgs.trim().isEmpty) return '🔧 $name';
      try {
        final decoded = jsonDecode(rawArgs);
        return '🔧 $name\n${const JsonEncoder.withIndent('  ').convert(decoded)}';
      } catch (_) {
        return '🔧 $name\n$rawArgs';
      }
    }
    return '🔧 $name\n${jsonEncode(rawArgs)}';
  }

  String _formatToolResult(Map<String, dynamic> data) {
    final message = data['message'];
    // Tool result messages wrap the useful payload in `content`; extracting it
    // keeps call ids / metadata noise out of the expanded detail.
    final text = _deepText(
      message is Map<String, dynamic> ? message['content'] : message,
    );
    if (text.isEmpty) return '📦 ${_compact(message)}';
    const limit = 8000;
    final trimmed = text.length > limit ? text.substring(0, limit) : text;
    return '📦 $trimmed${text.length > limit ? '\n…' : ''}';
  }

  static const _deepTextSkippedKeys = {
    'type',
    'source',
    'role',
    'id',
    'callId',
    'toolCallId',
    'meta',
    'isError',
  };

  String _deepText(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is List) {
      final parts = <String>[];
      for (final item in value) {
        final text = _deepText(item);
        if (text.isNotEmpty) parts.add(text);
      }
      return parts.join('\n');
    }
    if (value is Map<String, dynamic>) {
      if (value['type'] == 'text') {
        return value['text']?.toString().trim() ?? '';
      }
      final content = value['content'];
      if (content != null) {
        final text = _deepText(content);
        if (text.isNotEmpty) return text;
      }
      final parts = <String>[];
      for (final entry in value.entries) {
        if (_deepTextSkippedKeys.contains(entry.key)) continue;
        final text = _deepText(entry.value);
        if (text.isNotEmpty) parts.add(text);
      }
      return parts.join('\n');
    }
    return value.toString().trim();
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

  _LogLine? _addLine(
    String kind,
    String text, {
    bool process = false,
    String stepKey = '',
    String? chunkKey,
    bool notify = true,
  }) {
    if (text.isEmpty) return null;
    final line = _LogLine(
      id: _nextLineId++,
      kind: kind,
      text: text,
      process: process,
      stepKey: stepKey,
      chunkKey: chunkKey,
    );
    _lines.add(line);
    if (notify) _scheduleRefresh(immediate: true);
    return line;
  }

  void _flushChunkBuffers() {
    for (final entry in _chunkBuffers.entries) {
      final line = _chunkLines[entry.key];
      if (line != null) line.text = entry.value.toString();
    }
  }

  /// Chunk deltas are throttled into at most one rebuild per ~80 ms while
  /// other events rebuild immediately.
  void _scheduleRefresh({bool immediate = false}) {
    if (immediate) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      _flushChunkBuffers();
      if (mounted) setState(() {});
      return;
    }
    if (_refreshTimer != null || !mounted) return;
    _refreshTimer = Timer(const Duration(milliseconds: 80), () {
      _refreshTimer = null;
      _flushChunkBuffers();
      if (mounted) setState(() {});
    });
  }

  List<Widget> _buildChatItems() {
    final items = <Widget>[];
    _ProcessGroup? current;

    void flushProcessGroup() {
      if (current == null) return;
      items.add(_ProcessStepCard(group: current!));
      current = null;
    }

    for (final line in _lines) {
      if (line.process) {
        if (current == null || current!.stepKey != line.stepKey) {
          flushProcessGroup();
          current = _ProcessGroup(line.stepKey, [line]);
        } else {
          current!.lines.add(line);
        }
      } else {
        flushProcessGroup();
        items.add(MessageBubble(kind: line.kind, text: line.text));
      }
    }
    flushProcessGroup();
    return items;
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

  String? _mediaTypeFor(XFile file) {
    final known = file.mimeType?.toLowerCase();
    if (known == 'image/png' ||
        known == 'image/jpeg' ||
        known == 'image/webp' ||
        known == 'image/gif') {
      return known;
    }
    final name = file.name.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.gif')) return 'image/gif';
    return null;
  }

  Future<void> _pickImages() async {
    if (_pickingImages || _sending) return;
    setState(() => _pickingImages = true);
    try {
      List<XFile> files;
      try {
        files = await _picker.pickMultiImage(
          imageQuality: 85,
          maxWidth: 2560,
          limit: 9,
        );
      } on UnimplementedError {
        final file = await _picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
          maxWidth: 2560,
        );
        files = file == null ? const [] : [file];
      }

      final loaded = <_PendingImage>[];
      final skipped = <String>[];
      for (final file in files) {
        final mediaType = _mediaTypeFor(file);
        if (mediaType == null) {
          skipped.add('${file.name}：仅支持 PNG / JPEG / WebP / GIF');
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          skipped.add('${file.name}：图片为空');
          continue;
        }
        if (bytes.length > _maxImageBytes) {
          skipped.add('${file.name}：图片超过 5 MB，请压缩后重试');
          continue;
        }
        loaded.add(
          _PendingImage(
            name: file.name,
            mediaType: mediaType,
            bytes: bytes,
          ),
        );
      }

      if (!mounted) return;
      setState(() => _pendingImages.addAll(loaded));
      for (final reason in skipped) {
        _addLine('error', '未添加图片：$reason');
      }
    } catch (e) {
      if (!mounted) return;
      _addLine('error', '选择图片失败: $e');
    } finally {
      if (mounted) setState(() => _pickingImages = false);
    }
  }

  void _removePendingImage(int index) {
    if (index < 0 || index >= _pendingImages.length) return;
    setState(() => _pendingImages.removeAt(index));
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final hasImages = _pendingImages.isNotEmpty;
    if ((text.isEmpty && !hasImages) || _sending) return;

    final content = <Map<String, dynamic>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      for (final image in _pendingImages)
        {
          'type': 'image',
          'mediaType': image.mediaType,
          'data': base64Encode(image.bytes),
          'name': image.name,
        },
    ];

    final bubbleText = switch ((text.isNotEmpty, hasImages)) {
      (true, true) => '$text\n[图片 ×${_pendingImages.length}]',
      (true, false) => text,
      (false, true) => '[图片 ×${_pendingImages.length}]',
      (false, false) => '',
    };

    setState(() => _sending = true);
    _addLine('user', bubbleText);
    try {
      await widget.api.promptContent(widget.sessionId, content);
      if (!mounted) return;
      setState(() {
        _inputController.clear();
        _pendingImages.clear();
      });
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
    final chatItems = _buildChatItems();
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset('assets/dsh_logo.png', width: 22, height: 22),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(widget.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              itemCount: chatItems.length,
              itemBuilder: (context, index) => chatItems[index],
            ),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: const BoxDecoration(
                color: kSurface,
                border: Border(top: BorderSide(color: kBorder)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pendingImages.isNotEmpty) ...[
                    SizedBox(
                      height: 72,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _pendingImages.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final image = _pendingImages[index];
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.memory(
                                  image.bytes,
                                  width: 64,
                                  height: 64,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                ),
                              ),
                              Positioned(
                                top: -6,
                                right: -6,
                                child: InkWell(
                                  onTap: _sending
                                      ? null
                                      : () => _removePendingImage(index),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: kTextPrimary,
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(2),
                                    child: const Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: '添加图片',
                        onPressed:
                            _sending || _pickingImages ? null : _pickImages,
                        icon: _pickingImages
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.add_photo_alternate_outlined),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: '描述你想要让 DSH 做的事…',
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: _sending ? null : _send,
                        icon: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.arrow_upward),
                      ),
                    ],
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

class _ProcessStepCard extends StatelessWidget {
  final _ProcessGroup group;

  const _ProcessStepCard({required this.group});

  String get _label {
    final parts = group.stepKey.split(':');
    if (parts.length == 2) {
      final turn = int.tryParse(parts[0]);
      final step = int.tryParse(parts[1]);
      if (turn != null && step != null) return '第 $turn 轮 · 第 $step 步';
    }
    return '执行过程';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: const Icon(
          Icons.account_tree_outlined,
          color: kDshBlue,
          size: 22,
        ),
        title: Text(
          _label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${group.toolCallCount} 次工具调用 · '
          '${group.toolResultCount} 个结果（点击展开）',
          style: const TextStyle(fontSize: 12, color: kTextSecondary),
        ),
        children: [
          for (final line in group.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ProcessLine(line: line),
            ),
        ],
      ),
    );
  }
}

class _ProcessLine extends StatelessWidget {
  final _LogLine line;

  const _ProcessLine({required this.line});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: SelectableText(
        line.text,
        style: const TextStyle(
          fontSize: 12,
          color: kTextSecondary,
          fontFamily: 'monospace',
          height: 1.4,
        ),
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
    final options = (question['options'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
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
                  ? Text(opt['description'].toString(),
                      style: const TextStyle(fontSize: 12))
                  : null,
              value: selected.contains(opt['label']?.toString() ?? ''),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: multi
                  ? (checked) => onChanged(
                      opt['label']?.toString() ?? '', checked ?? false)
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

class MessageBubble extends StatelessWidget {
  final String kind;
  final String text;

  const MessageBubble({super.key, required this.kind, required this.text});

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 10, left: 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: kDshBlue,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14, height: 1.4),
            ),
          ),
        );
      case 'assistant':
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child:
                    Image.asset('assets/dsh_logo.png', width: 28, height: 28),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: kSurface,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    border: Border.all(color: kBorder),
                  ),
                  child: SelectableText(
                    text,
                    style: const TextStyle(
                        color: kTextPrimary, fontSize: 14, height: 1.4),
                  ),
                ),
              ),
            ],
          ),
        );
      case 'error':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13),
            ),
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kTextSecondary, fontSize: 12),
            ),
          ),
        );
    }
  }
}
