import 'package:flutter/material.dart';

import '../services/dsh_api.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _serverController = TextEditingController(text: 'http://<your-mac-ip>:8787');
  final _tokenController = TextEditingController();
  final _cwdController = TextEditingController(text: '/path/to/workspace');

  DshApi? _api;
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    _cwdController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final server = _serverController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final token = _tokenController.text.trim();
    if (server.isEmpty || token.isEmpty) {
      setState(() => _error = '请填写服务器地址和 Token');
      return;
    }
    setState(() {
      _api = DshApi(baseUrl: server, token: token);
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await _api!.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _createSession() async {
    final api = _api;
    if (api == null) return;
    setState(() => _loading = true);
    try {
      final created = await api.createSession(cwd: _cwdController.text.trim());
      if (!mounted) return;
      final sessionId = created['sessionId'] as String?;
      if (sessionId != null) {
        await _connect();
        if (!mounted) return;
        _openChat(sessionId, '新会话');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _openChat(String sessionId, String title) {
    final api = _api;
    if (api == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          api: api,
          baseUrl: _serverController.text.trim().replaceAll(RegExp(r'/+$'), ''),
          token: _tokenController.text.trim(),
          sessionId: sessionId,
          title: title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DSH Remote')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _serverController,
            decoration: const InputDecoration(
              labelText: '桥接服务地址',
              hintText: 'http://192.168.1.100:8787',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Token',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loading ? null : _connect,
                  icon: const Icon(Icons.cloud_sync),
                  label: const Text('连接 / 刷新'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '新建会话',
                onPressed: _loading ? null : _createSession,
                icon: const Icon(Icons.add_circle),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 16),
          Text('会话列表', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else if (_sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('暂无会话，点击右上角 + 新建。'),
            )
          else
            ..._sessions.map((s) {
              final id = s['sessionId'] as String? ?? '';
              final running = s['running'] == true;
              final projections = s['projections'] as Map<String, dynamic>?;
              final values = projections?['values'] as Map<String, dynamic>?;
              final title = values?['title'] as String? ?? '未命名会话';
              final cwd = s['cwd'] as String? ?? '';
              return Card(
                child: ListTile(
                  leading: running
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chat_bubble_outline),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('$cwd\n$id', maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => _openChat(id, title),
                ),
              );
            }),
        ],
      ),
    );
  }
}
