import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the bridge URL and the per-device token issued by pairing.
///
/// Native platforms store them in Keychain / Android Keystore. On web this
/// falls back to platform storage; pairing still works over HTTPS, while the
/// app warns about persistence limitations over plain HTTP.
class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(
          aOptions: AndroidOptions(),
        );

  final FlutterSecureStorage _storage;

  static const _keyServer = 'dsh_remote_server';
  static const _keyToken = 'dsh_remote_token';
  static const _keyDeviceName = 'dsh_remote_device_name';

  Future<SavedCredentials?> load() async {
    try {
      final server = await _storage.read(key: _keyServer);
      final token = await _storage.read(key: _keyToken);
      if (server == null || server.isEmpty || token == null || token.isEmpty) {
        return null;
      }
      return SavedCredentials(
        server: server,
        token: token,
        deviceName: await _storage.read(key: _keyDeviceName) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save({
    required String server,
    required String token,
    required String deviceName,
  }) async {
    try {
      await _storage.write(key: _keyServer, value: server);
      await _storage.write(key: _keyToken, value: token);
      await _storage.write(key: _keyDeviceName, value: deviceName);
    } catch (_) {
      // Persistence is best-effort: the session keeps working, the next launch
      // just asks for pairing again.
    }
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _keyServer);
      await _storage.delete(key: _keyToken);
      await _storage.delete(key: _keyDeviceName);
    } catch (_) {}
  }
}

class SavedCredentials {
  const SavedCredentials({
    required this.server,
    required this.token,
    this.deviceName = '',
  });

  final String server;
  final String token;
  final String deviceName;
}
