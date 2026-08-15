import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/credential_store.dart';
import '../services/deep_link.dart';
import '../services/dsh_api.dart';
import '../services/pairing.dart';
import 'chat_screen.dart';
import 'scan_pair_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _serverController = TextEditingController();
  final _tokenController = TextEditingController();
  final _cwdController = TextEditingController();

  final CredentialStore _store = CredentialStore();

  DshApi? _api;
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = false;
  String? _error;
  String _pairedDeviceName = '';

  @override
  void initState() {
    super.initState();
    // Web fallback: the QR code is a plain URL with ?code=..., so a system
    // camera scan lands here directly and can pair without typing anything.
    final scheme = Uri.base.scheme;
    final launchCode = Uri.base.queryParameters['code']?.trim() ?? '';
    if ((kIsWeb || scheme == 'http' || scheme == 'https') && launchCode.isNotEmpty) {
      _pairFromLaunchCode(launchCode);
      return;
    }
    // Native app is the primary path: a dshremote:// QR can open the app
    // directly (cold start via initial link, warm start via the channel).
    DeepLinkService.listen(_pairFromRawLink);
    _initializeFromDeepLink();
  }

  Future<void> _initializeFromDeepLink() async {
    final link = await DeepLinkService.initialLink();
    if (!mounted) return;
    if (link != null && link.isNotEmpty && PairingInvite.tryParse(link) != null) {
      _pairFromRawLink(link);
      return;
    }
    _restoreSavedConnection();
  }

  Future<void> _pairFromRawLink(String raw) async {
    final invite = PairingInvite.tryParse(raw);
    if (invite == null) return;
    await _pairWithInvite(invite, deviceName: '手机');
  }

  Future<void> _pairFromLaunchCode(String code) async {
    final uri = Uri.base;
    final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final invite = PairingInvite(
      baseUrl: '${uri.scheme}://$authority',
      code: code,
      version: 1,
    );
    await _pairWithInvite(invite, deviceName: '手机浏览器');
  }

  Future<void> _pairWithInvite(
    PairingInvite invite, {
    required String deviceName,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await PairingService().pair(invite, deviceName: deviceName);
      if (!mounted) return;
      setState(() {
        _serverController.text = result.baseUrl;
        _tokenController.text = result.token;
        _pairedDeviceName = result.deviceName.isEmpty ? result.deviceId : result.deviceName;
        _loading = false;
      });
      await _connect(saveOnSuccess: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is PairingException ? e.message : '配对失败: $e';
      });
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    _cwdController.dispose();
    super.dispose();
  }

  Future<void> _restoreSavedConnection() async {
    final saved = await _store.load();
    if (saved == null || !mounted) return;
    setState(() {
      _serverController.text = saved.server;
      _tokenController.text = saved.token;
      _pairedDeviceName = saved.deviceName;
    });
    await _connect(saveOnSuccess: false);
  }

  Future<void> _connect({bool saveOnSuccess = false}) async {
    final server = _serverController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final token = _tokenController.text.trim();
    if (server.isEmpty || token.isEmpty) {
      setState(() => _error = '请先扫码绑定，或展开手动配置填写地址和 Token');
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
      if (saveOnSuccess) {
        await _store.save(
          server: server,
          token: token,
          deviceName: _pairedDeviceName,
        );
      }
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

  Future<void> _scanAndPair() async {
    final result = await Navigator.of(context).push<PairingResult>(
      MaterialPageRoute(builder: (_) => const ScanPairPage()),
    );
    if (result == null || !mounted) return;
    setState(() {
      _serverController.text = result.baseUrl;
      _tokenController.text = result.token;
      _pairedDeviceName = result.deviceName.isEmpty ? result.deviceId : result.deviceName;
      _error = null;
    });
    await _connect(saveOnSuccess: true);
  }

  Future<void> _forgetDevice() async {
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _api = null;
      _sessions = [];
      _serverController.clear();
      _tokenController.clear();
      _pairedDeviceName = '';
      _error = null;
    });
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
    final connected = _api != null && !_loading;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/dsh_logo.png', width: 28, height: 28),
            ),
            const SizedBox(width: 10),
            const Text(
              'DSH-Remote',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                connected ? '已连接' : '待连接',
                style: const TextStyle(fontSize: 11, color: kDshBlue),
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '连接 DSH',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _pairedDeviceName.isEmpty
                        ? '电脑端打开 http://127.0.0.1:8787/pair/qr，手机扫码即可绑定'
                        : '已绑定设备：$_pairedDeviceName',
                    style: const TextStyle(fontSize: 13, color: kTextSecondary),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _scanAndPair,
                      icon: _loading
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.qr_code_scanner, size: 18),
                      label: Text(_pairedDeviceName.isEmpty ? '扫码绑定设备' : '重新扫码绑定'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _loading ? null : () => _connect(saveOnSuccess: true),
                          icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                          label: Text(connected ? '连接 / 刷新' : '连接'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: '新建会话',
                        onPressed: _loading ? null : _createSession,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  if (_pairedDeviceName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _loading ? null : _forgetDevice,
                        child: const Text('忘记此设备', style: TextStyle(color: kTextSecondary, fontSize: 13)),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              title: const Text('手动配置（高级）', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              subtitle: const Text('不推荐；优先使用扫码绑定', style: TextStyle(fontSize: 12, color: kTextSecondary)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _serverController,
                  decoration: const InputDecoration(
                    labelText: '桥接服务地址',
                    hintText: 'http://100.x.x.x:8787',
                    prefixIcon: Icon(Icons.dns_outlined, size: 20),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Token',
                    prefixIcon: Icon(Icons.key_outlined, size: 20),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _cwdController,
                  decoration: const InputDecoration(
                    labelText: '默认工作目录（可选）',
                    hintText: '/path/to/workspace',
                    prefixIcon: Icon(Icons.folder_outlined, size: 20),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const Text(
                '会话',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: kTextPrimary),
              ),
              const Spacer(),
              if (_sessions.isNotEmpty)
                Text(
                  '${_sessions.length}',
                  style: const TextStyle(fontSize: 13, color: kTextSecondary),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
          else if (_sessions.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kBorder),
              ),
              child: const Center(
                child: Text(
                  '暂无会话，先连接后新建',
                  style: TextStyle(color: kTextSecondary),
                ),
              ),
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
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  leading: running
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.chat_bubble_outline, color: kDshBlue, size: 20),
                        ),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('$cwd\n$id', maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right, color: kTextSecondary),
                  onTap: () => _openChat(id, title),
                ),
              );
            }),
        ],
      ),
    );
  }
}
