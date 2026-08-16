import 'dart:convert';

import 'package:dsh_remote/services/credential_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage();

  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

void main() {
  test('normalizeServer strips trailing slashes and whitespace', () {
    expect(normalizeServer('  http://100.1.2.3:8787///  '),
        'http://100.1.2.3:8787');
    expect(normalizeServer('http://100.1.2.3:8787'), 'http://100.1.2.3:8787');
  });

  test('SavedEndpoint survives a JSON round trip', () {
    const endpoint = SavedEndpoint(
      server: 'http://100.1.2.3:8787/',
      token: 'secret-token',
      label: '工作 Mac',
      deviceName: 'Android 手机',
      addedAt: 111,
      lastConnectedAt: 222,
    );
    final decoded =
        jsonDecode(jsonEncode([endpoint.toJson()])) as List<dynamic>;
    final restored = SavedEndpoint.tryFromJson(decoded.single);
    expect(restored, isNotNull);
    expect(restored!.server, 'http://100.1.2.3:8787');
    expect(restored.token, 'secret-token');
    expect(restored.displayName, '工作 Mac');
    expect(restored.deviceLabel, 'Android 手机');
    expect(restored.addedAt, 111);
    expect(restored.lastConnectedAt, 222);
  });

  test('SavedEndpoint.tryFromJson rejects entries without server or token', () {
    expect(SavedEndpoint.tryFromJson(null), isNull);
    expect(SavedEndpoint.tryFromJson({'server': '', 'token': 'x'}), isNull);
    expect(
        SavedEndpoint.tryFromJson({'server': 'http://x', 'token': ''}), isNull);
  });

  test('migrates legacy single credentials and stores multiple endpoints',
      () async {
    final storage = _FakeSecureStorage();
    storage.values['dsh_remote_server'] = 'http://pc-a:8787/';
    storage.values['dsh_remote_token'] = 'token-a';
    storage.values['dsh_remote_device_name'] = 'Android 手机';

    final store = CredentialStore(storage: storage);
    final legacy = await store.loadEndpoints();
    expect(legacy, hasLength(1));
    expect(legacy.single.server, 'http://pc-a:8787');

    await store.saveEndpoints(
      [
        legacy.single,
        const SavedEndpoint(
          server: 'http://pc-b:8787',
          token: 'token-b',
          label: '工作机',
          deviceName: 'Android 手机',
        ),
      ],
      selectedServer: 'http://pc-b:8787',
    );

    final loaded = await store.loadEndpoints();
    expect(loaded, hasLength(2));
    expect(loaded.map((e) => e.server),
        containsAll(['http://pc-a:8787', 'http://pc-b:8787']));
    expect(await store.loadSelectedServer(), 'http://pc-b:8787');
    // Legacy mirror keeps pointing at the selected PC for downgrade safety.
    expect(storage.values['dsh_remote_server'], 'http://pc-b:8787');
    expect(storage.values['dsh_remote_token'], 'token-b');
  });
}
