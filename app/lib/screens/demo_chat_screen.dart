import 'package:flutter/material.dart';

import '../main.dart';
import 'chat_screen.dart';

/// 仅用于本地预览 / 截图，正常使用不会进入。
class DemoChatScreen extends StatelessWidget {
  const DemoChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(6)),
              child: Image(image: AssetImage('assets/dsh_logo.png'), width: 22, height: 22),
            ),
            SizedBox(width: 8),
            Expanded(child: Text('DSH 会话')),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        children: const [
          MessageBubble(
            kind: 'user',
            text: '帮我检查一下当前项目的 README 是否完整',
          ),
          MessageBubble(
            kind: 'assistant',
            text: '好的，我先看一下项目结构和 README 内容。',
          ),
          MessageBubble(
            kind: 'tool',
            text: '🔧 read({"file_path": "README.md"})',
          ),
          MessageBubble(
            kind: 'assistant',
            text: 'README 已检查完毕，整体结构完整，建议补充安全提醒部分。',
          ),
          MessageBubble(
            kind: 'system',
            text: '✅ 执行结束',
          ),
        ],
      ),
    );
  }
}
