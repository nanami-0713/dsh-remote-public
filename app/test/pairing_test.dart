import 'package:dsh_remote/services/pairing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses dshremote:// app QR payload', () {
    const raw =
        'dshremote://pair?base=http%3A%2F%2F198.51.100.10%3A8787&code=abcdefghijklmnopqrstuvwxyz123456&v=1';
    final invite = PairingInvite.tryParse(raw);
    expect(invite, isNotNull);
    expect(invite!.baseUrl, 'http://198.51.100.10:8787');
    expect(invite.code, 'abcdefghijklmnopqrstuvwxyz123456');
  });

  test('parses web fallback /app/?code= payload', () {
    const raw =
        'http://198.51.100.10:8787/app/?code=abcdefghijklmnopqrstuvwxyz123456';
    final invite = PairingInvite.tryParse(raw);
    expect(invite, isNotNull);
    expect(invite!.baseUrl, 'http://198.51.100.10:8787');
    expect(invite.code, 'abcdefghijklmnopqrstuvwxyz123456');
  });

  test('rejects unrelated payloads and short codes', () {
    expect(PairingInvite.tryParse('https://example.com/'), isNull);
    expect(
      PairingInvite.tryParse('dshremote://pair?base=http%3A%2F%2Fx&code=short'),
      isNull,
    );
  });
}
