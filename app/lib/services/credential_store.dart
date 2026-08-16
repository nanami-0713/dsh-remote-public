import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Normalizes a bridge base URL so the same PC always maps to the same
/// storage entry regardless of trailing slashes or surrounding whitespace.
String normalizeServer(String raw) {
  var server = raw.trim();
  while (server.endsWith('/')) {
    server = server.substring(0, server.length - 1);
  }
  return server;
}

/// One PC (bridge endpoint) saved on this phone.
class SavedEndpoint {
  const SavedEndpoint({
    required this.server,
    required this.token,
    this.label = '',
    this.deviceName = '',
    this.addedAt = 0,
    this.lastConnectedAt = 0,
  });

  final String server;
  final String token;

  /// Human-friendly PC name (e.g. bridge hostname). Falls back to [server].
  final String label;

  /// Name this phone used when it paired with the PC.
  final String deviceName;
  final int addedAt;
  final int lastConnectedAt;

  String get displayName {
    final trimmed = label.trim();
    return trimmed.isEmpty ? server : trimmed;
  }

  String get deviceLabel {
    final trimmed = deviceName.trim();
    return trimmed.isEmpty ? '未命名设备' : trimmed;
  }

  bool matches(String candidate) => server == normalizeServer(candidate);

  Map<String, dynamic> toJson() => {
        'server': server,
        'token': token,
        'label': label,
        'deviceName': deviceName,
        'addedAt': addedAt,
        'lastConnectedAt': lastConnectedAt,
      };

  static SavedEndpoint? tryFromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final server = normalizeServer(raw['server'] as String? ?? '');
    final token = raw['token'] as String? ?? '';
    if (server.isEmpty || token.isEmpty) return null;
    return SavedEndpoint(
      server: server,
      token: token,
      label: raw['label'] as String? ?? '',
      deviceName: raw['deviceName'] as String? ?? '',
      addedAt: (raw['addedAt'] as num?)?.toInt() ?? 0,
      lastConnectedAt: (raw['lastConnectedAt'] as num?)?.toInt() ?? 0,
    );
  }

  SavedEndpoint copyWith({
    String? server,
    String? token,
    String? label,
    String? deviceName,
    int? addedAt,
    int? lastConnectedAt,
  }) {
    return SavedEndpoint(
      server: server ?? this.server,
      token: token ?? this.token,
      label: label ?? this.label,
      deviceName: deviceName ?? this.deviceName,
      addedAt: addedAt ?? this.addedAt,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }
}

/// Persists the list of paired PCs and which one was last selected.
///
/// Native platforms store them in Keychain / Android Keystore. On web this
/// falls back to platform storage; pairing still works over HTTPS, while the
/// app warns about persistence limitations over plain HTTP.
///
/// The endpoints are kept in one JSON document under `dsh_remote_endpoints`.
/// Legacy installations (<=0.3.x) stored a single PC under
/// `dsh_remote_server` / `dsh_remote_token`; those keys are migrated on load
/// and mirrored on save so downgrading never loses the currently selected PC.
class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _storage;

  static const _keyEndpoints = 'dsh_remote_endpoints';
  static const _keySelected = 'dsh_remote_selected';

  static const _keyServer = 'dsh_remote_server';
  static const _keyToken = 'dsh_remote_token';
  static const _keyDeviceName = 'dsh_remote_device_name';

  Future<List<SavedEndpoint>> loadEndpoints() async {
    try {
      final raw = await _storage.read(key: _keyEndpoints);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final endpoints = decoded
              .map(SavedEndpoint.tryFromJson)
              .whereType<SavedEndpoint>()
              .toList();
          // Keep determinism even if an old writer saved them unsorted.
          _sortByRecent(endpoints);
          return endpoints;
        }
      }
    } catch (_) {
      // Fall through to legacy keys if the multi-endpoint document is broken.
    }
    return _loadLegacyEndpoints();
  }

  Future<List<SavedEndpoint>> _loadLegacyEndpoints() async {
    try {
      final server =
          normalizeServer(await _storage.read(key: _keyServer) ?? '');
      final token = await _storage.read(key: _keyToken) ?? '';
      if (server.isEmpty || token.isEmpty) return [];
      final deviceName = await _storage.read(key: _keyDeviceName) ?? '';
      return [
        SavedEndpoint(
          server: server,
          token: token,
          deviceName: deviceName,
          addedAt: 0,
          lastConnectedAt: 0,
        ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<String?> loadSelectedServer() async {
    try {
      return await _storage.read(key: _keySelected);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveEndpoints(
    List<SavedEndpoint> endpoints, {
    String? selectedServer,
  }) async {
    final normalized = endpoints
        .map(
          (e) => SavedEndpoint(
            server: normalizeServer(e.server),
            token: e.token,
            label: e.label,
            deviceName: e.deviceName,
            addedAt: e.addedAt,
            lastConnectedAt: e.lastConnectedAt,
          ),
        )
        .toList();
    _sortByRecent(normalized);
    final selected =
        selectedServer == null ? null : normalizeServer(selectedServer);
    try {
      await _storage.write(
        key: _keyEndpoints,
        value: jsonEncode(normalized.map((e) => e.toJson()).toList()),
      );
      if (selected != null) {
        await _storage.write(key: _keySelected, value: selected);
      }
      await _writeLegacyMirror(
        normalized.where((e) => e.server == selected).firstOrNull,
      );
    } catch (_) {
      // Persistence is best-effort: the session keeps working, the next launch
      // just asks for pairing again.
    }
  }

  Future<void> setSelected(String server) async {
    final normalized = normalizeServer(server);
    try {
      await _storage.write(key: _keySelected, value: normalized);
      final endpoints = await loadEndpoints();
      await _writeLegacyMirror(
        endpoints.where((e) => e.server == normalized).firstOrNull,
      );
    } catch (_) {}
  }

  Future<void> clearAll() async {
    try {
      await _storage.delete(key: _keyEndpoints);
      await _storage.delete(key: _keySelected);
      await _storage.delete(key: _keyServer);
      await _storage.delete(key: _keyToken);
      await _storage.delete(key: _keyDeviceName);
    } catch (_) {}
  }

  Future<void> _writeLegacyMirror(SavedEndpoint? selected) async {
    if (selected == null) return;
    try {
      await _storage.write(key: _keyServer, value: selected.server);
      await _storage.write(key: _keyToken, value: selected.token);
      await _storage.write(key: _keyDeviceName, value: selected.deviceName);
    } catch (_) {}
  }

  static void _sortByRecent(List<SavedEndpoint> endpoints) {
    endpoints.sort((a, b) {
      final byTime = b.lastConnectedAt.compareTo(a.lastConnectedAt);
      if (byTime != 0) return byTime;
      return a.server.compareTo(b.server);
    });
  }
}
