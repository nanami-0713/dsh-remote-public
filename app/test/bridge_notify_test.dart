import 'package:dsh_remote/services/bridge_notify.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeNotify.fromJson', () {
    test('parses a done frame payload', () {
      final notify = BridgeNotify.fromJson(const {
        'kind': 'done',
        'title': 'DSH 任务完成',
        'message': '会话已运行结束，可以查看结果了',
        'sessionId': 'sess-123',
        'at': 1700000000000,
      });
      expect(notify.kind, 'done');
      expect(notify.title, 'DSH 任务完成');
      expect(notify.message, contains('运行结束'));
      expect(notify.sessionId, 'sess-123');
      expect(notify.at, 1700000000000);
      expect(notify.isSticky, isFalse);
    });

    test('question frames are sticky and tolerate missing fields', () {
      final notify = BridgeNotify.fromJson(const {
        'kind': 'question',
        'title': 'DSH 需要你回答',
      });
      expect(notify.kind, 'question');
      expect(notify.isSticky, isTrue);
      expect(notify.message, isEmpty);
      expect(notify.sessionId, isEmpty);
      expect(notify.at, 0);
    });
  });
}
