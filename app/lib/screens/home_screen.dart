import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/credential_store.dart';
import '../services/deep_link.dart';
import '../services/dsh_api.dart';
import '../services/pairing.dart';
import 'chat_screen.dart';
import 'new_session_sheet.dart';
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

  /// All PCs this phone has paired with. The list is sorted by
  /// `lastConnectedAt` descending (most recently used first).
  List<SavedEndpoint> _endpoints = [];
  String? _selectedServer;
  bool _endpointsLoaded = false;

  /// Privacy guard: IP addresses, filesystem paths and session ids stay
  /// masked until the user taps the small eye icon.
  bool _sensitiveVisible = false;

  @override
  void initState() {
    super.initState();
    // Web fallback: the QR code is a plain URL with ?code=..., so a system
    // camera scan lands here directly and can pair without typing anything.
    final scheme = Uri.base.scheme;
    final launchCode = Uri.base.queryParameters['code']?.trim() ?? '';
    if ((kIsWeb || scheme == 'http' || scheme == 'https') &&
        launchCode.isNotEmpty) {
      _pairFromLaunchCode(launchCode);
      return;
    }
    // Native app is the primary path: a dshremote:// QR can open the app
    // directly (cold start via initial link, warm start via the channel).
    DeepLinkService.listen(_pairFromRawLink);
    _initializeFromDeepLink();
  }

  SavedEndpoint? get _selectedEndpoint {
    final server = _selectedServer;
    if (server == null) return null;
    for (final endpoint in _endpoints) {
      if (endpoint.server == server) return endpoint;
    }
    return null;
  }

  /// Default-private rendering helpers. Sensitive values render as fixed
  /// bullets until [_sensitiveVisible] is toggled on.
  String _maskServer(String server) {
    final uri = Uri.tryParse(server);
    if (uri == null || !uri.hasAuthority) return '••••••••';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://••••••$port';
  }

  String _serverText(String server) =>
      _sensitiveVisible ? server : _maskServer(server);

  String _sensitiveText(String value) => _sensitiveVisible ? value : '••••••••';

  Widget _buildPrivacyToggle() {
    return IconButton(
      tooltip: _sensitiveVisible ? '隐藏隐私信息' : '显示隐私信息',
      visualDensity: VisualDensity.compact,
      onPressed: () => setState(() => _sensitiveVisible = !_sensitiveVisible),
      icon: Icon(
        _sensitiveVisible
            ? Icons.visibility_off_outlined
            : Icons.visibility_outlined,
        size: 20,
        color: kTextSecondary,
      ),
    );
  }

  Future<void> _ensureEndpointsLoaded() async {
    if (_endpointsLoaded) return;
    final endpoints = await _store.loadEndpoints();
    final savedSelected = await _store.loadSelectedServer();
    if (!mounted) return;
    _endpointsLoaded = true;
    _endpoints = endpoints;
    if (endpoints.isEmpty) {
      _selectedServer = null;
      return;
    }
    final wanted =
        savedSelected == null ? null : normalizeServer(savedSelected);
    _selectedServer = endpoints.any((e) => e.server == wanted)
        ? wanted
        : endpoints.first.server;
  }

  Future<void> _initializeFromDeepLink() async {
    final link = await DeepLinkService.initialLink();
    if (!mounted) return;
    if (link != null &&
        link.isNotEmpty &&
        PairingInvite.tryParse(link) != null) {
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
    // Load the existing PC list before pairing so a new QR code adds to it
    // instead of replacing it.
    await _ensureEndpointsLoaded();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result =
          await PairingService().pair(invite, deviceName: deviceName);
      if (!mounted) return;
      await _persistAndSelect(
        SavedEndpoint(
          server: normalizeServer(result.baseUrl),
          token: result.token,
          label: result.bridgeName,
          deviceName: result.deviceName,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          lastConnectedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (!mounted) return;
      await _connect();
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
    await _ensureEndpointsLoaded();
    if (!mounted) return;
    if (_endpoints.isEmpty) {
      setState(() {});
      return;
    }
    final endpoint = _selectedEndpoint ?? _endpoints.first;
    setState(() {
      _selectedServer = endpoint.server;
      _serverController.text = endpoint.server;
      _tokenController.text = endpoint.token;
      _pairedDeviceName = endpoint.deviceName;
    });
    await _connect(touchOnSuccess: true);
  }

  /// Adds (or updates, when re-pairing the same PC) one endpoint and makes it
  /// the selected PC. Existing PC entries are never removed here.
  Future<void> _persistAndSelect(SavedEndpoint candidate) async {
    await _ensureEndpointsLoaded();
    final server = normalizeServer(candidate.server);
    SavedEndpoint? existing;
    for (final endpoint in _endpoints) {
      if (endpoint.server == server) {
        existing = endpoint;
        break;
      }
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final merged = SavedEndpoint(
      server: server,
      token: candidate.token,
      label: candidate.label.trim().isNotEmpty
          ? candidate.label
          : (existing?.label ?? ''),
      deviceName: candidate.deviceName.trim().isNotEmpty
          ? candidate.deviceName
          : (existing?.deviceName ?? ''),
      addedAt: existing?.addedAt ??
          (candidate.addedAt > 0 ? candidate.addedAt : nowMs),
      lastConnectedAt: nowMs,
    );
    final next = [
      for (final endpoint in _endpoints)
        if (endpoint.server != server) endpoint,
      merged,
    ]..sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
    if (!mounted) return;
    setState(() {
      _endpoints = next;
      _selectedServer = server;
      _serverController.text = server;
      _tokenController.text = merged.token;
      _pairedDeviceName = merged.deviceName;
      _error = null;
      _sensitiveVisible = false;
    });
    await _store.saveEndpoints(next, selectedServer: server);
  }

  Future<void> _markSelectedActive() async {
    final server = _selectedServer;
    if (server == null) return;
    await _ensureEndpointsLoaded();
    final index = _endpoints.indexWhere((e) => e.server == server);
    if (index < 0) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final next = List<SavedEndpoint>.of(_endpoints);
    next[index] = next[index].copyWith(lastConnectedAt: nowMs);
    next.sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
    if (!mounted) return;
    setState(() => _endpoints = next);
    await _store.saveEndpoints(next, selectedServer: server);
  }

  Future<void> _connect({
    bool saveOnSuccess = false,
    bool touchOnSuccess = false,
  }) async {
    final server = normalizeServer(_serverController.text);
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
        await _persistAndSelect(
          SavedEndpoint(
            server: server,
            token: token,
            label: '',
            deviceName: _pairedDeviceName,
            addedAt: 0,
            lastConnectedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else if (touchOnSuccess) {
        await _markSelectedActive();
      }
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

  Future<void> _scanAndPair() async {
    final result = await Navigator.of(context).push<PairingResult>(
      MaterialPageRoute(builder: (_) => const ScanPairPage()),
    );
    if (result == null || !mounted) return;
    await _persistAndSelect(
      SavedEndpoint(
        server: normalizeServer(result.baseUrl),
        token: result.token,
        label: result.bridgeName,
        deviceName: result.deviceName,
        addedAt: DateTime.now().millisecondsSinceEpoch,
        lastConnectedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!mounted) return;
    setState(() => _error = null);
    await _connect();
  }

  Future<void> _selectEndpoint(SavedEndpoint endpoint) async {
    if (_loading || endpoint.server == _selectedServer) return;
    setState(() {
      _api = null;
      _sessions = [];
      _selectedServer = endpoint.server;
      _serverController.text = endpoint.server;
      _tokenController.text = endpoint.token;
      _pairedDeviceName = endpoint.deviceName;
      _error = null;
      _sensitiveVisible = false;
    });
    await _store.setSelected(endpoint.server);
    await _connect(touchOnSuccess: true);
  }

  Future<void> _forgetEndpoint(SavedEndpoint endpoint) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('忘记这台电脑'),
        content: Text(
          '确定从手机移除「${endpoint.displayName}」'
          '（${_serverText(endpoint.server)}）？\n'
          '移除后如要再次控制这台电脑，需要重新扫码绑定。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('忘记'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _ensureEndpointsLoaded();
    final server = normalizeServer(endpoint.server);
    final wasSelected = _selectedServer == server;
    final next = [
      for (final e in _endpoints)
        if (e.server != server) e,
    ];
    final nextSelected = next.isNotEmpty ? next.first.server : null;
    if (!mounted) return;
    setState(() {
      _endpoints = next;
      _error = null;
      _sensitiveVisible = false;
      if (wasSelected) {
        _api = null;
        _sessions = [];
        _selectedServer = nextSelected;
        if (nextSelected == null) {
          _serverController.clear();
          _tokenController.clear();
          _pairedDeviceName = '';
        } else {
          final fallback = next.first;
          _serverController.text = fallback.server;
          _tokenController.text = fallback.token;
          _pairedDeviceName = fallback.deviceName;
        }
      }
    });
    if (next.isEmpty) {
      await _store.clearAll();
    } else {
      await _store.saveEndpoints(
        next,
        selectedServer: _selectedServer ?? next.first.server,
      );
    }
    if (!mounted) return;
    if (wasSelected && nextSelected != null) {
      await _connect(touchOnSuccess: true);
    }
  }

  Future<void> _createSession() async {
    final api = _api;
    if (api == null) return;

    final config = await showModalBottomSheet<NewSessionConfig>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => NewSessionSheet(
        api: api,
        initialCwd: _cwdController.text.trim(),
      ),
    );
    if (config == null || !mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    String? modelError;
    try {
      final created = await api.createSession(
        workspaceId: config.workspaceId,
        cwd: config.workspaceId == null && config.cwd.isNotEmpty
            ? config.cwd
            : null,
        agentPreset: config.agentPreset,
      );
      if (!mounted) return;
      final sessionId = created['sessionId'] as String?;
      if (sessionId == null) {
        setState(() {
          _loading = false;
          _error = 'DSH 没有返回新会话 ID';
        });
        return;
      }

      if (config.provider != null && config.model != null) {
        try {
          await api.selectModel(
            sessionId: sessionId,
            provider: config.provider!,
            model: config.model!,
            reasoningEffort: config.reasoningEffort,
          );
        } catch (e) {
          modelError = '会话已创建，但设置模型失败：$e';
        }
      }

      await _connect();
      if (!mounted) return;
      _openChat(sessionId, '新会话');
      if (modelError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(modelError)),
        );
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
          baseUrl: normalizeServer(_serverController.text),
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
    final selected = _selectedEndpoint;
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
                  Row(
                    children: [
                      const Text(
                        '连接 DSH',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      _buildPrivacyToggle(),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    selected == null
                        ? '电脑端打开 http://127.0.0.1:8787/pair/qr，手机扫码即可绑定'
                        : '当前电脑：${selected.displayName}\n'
                            '${_serverText(selected.server)}\n'
                            '手机在这台电脑上的名称：${selected.deviceLabel}',
                    style: const TextStyle(fontSize: 13, color: kTextSecondary),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _scanAndPair,
                      icon: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.qr_code_scanner, size: 18),
                      label: Text(
                        _endpoints.isEmpty ? '扫码绑定电脑' : '扫码绑定另一台电脑',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _loading
                              ? null
                              : () => _connect(saveOnSuccess: true),
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
                  if (selected != null) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed:
                            _loading ? null : () => _forgetEndpoint(selected),
                        child: const Text(
                          '忘记这台电脑',
                          style: TextStyle(color: kTextSecondary, fontSize: 13),
                        ),
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
                        style: const TextStyle(
                            color: Color(0xFFB91C1C), fontSize: 13),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_endpoints.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '电脑列表',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${_endpoints.length}',
                          style: const TextStyle(
                              fontSize: 13, color: kTextSecondary),
                        ),
                        _buildPrivacyToggle(),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (final endpoint in _endpoints)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        selected: endpoint.server == _selectedServer,
                        selectedTileColor: const Color(0xFFEEF2FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.computer_outlined,
                            color: kDshBlue,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          endpoint.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_serverText(endpoint.server)}\n手机在此电脑的名称：${endpoint.deviceLabel}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (endpoint.server == _selectedServer)
                              const Icon(Icons.check_circle,
                                  color: kDshBlue, size: 20),
                            IconButton(
                              tooltip: '忘记这台电脑',
                              onPressed: _loading
                                  ? null
                                  : () => _forgetEndpoint(endpoint),
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: kTextSecondary,
                              ),
                            ),
                          ],
                        ),
                        onTap:
                            _loading ? null : () => _selectEndpoint(endpoint),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              title: const Text(
                '手动配置（高级）',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                '不推荐；优先使用扫码绑定',
                style: TextStyle(fontSize: 12, color: kTextSecondary),
              ),
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
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: kTextPrimary),
              ),
              const Spacer(),
              if (_sessions.isNotEmpty)
                Text(
                  '${_sessions.length}',
                  style: const TextStyle(fontSize: 13, color: kTextSecondary),
                ),
              _buildPrivacyToggle(),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            )
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
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  leading: running
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.chat_bubble_outline,
                              color: kDshBlue, size: 20),
                        ),
                  title:
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${_sensitiveText(cwd.isEmpty ? '默认工作目录' : cwd)}\n${_sensitiveText(id)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  trailing:
                      const Icon(Icons.chevron_right, color: kTextSecondary),
                  onTap: () => _openChat(id, title),
                ),
              );
            }),
        ],
      ),
    );
  }
}
