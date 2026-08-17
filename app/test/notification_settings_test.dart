import 'package:dsh_remote/services/notification_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationSettings', () {
    test('defaults: all alerts on', () {
      const s = NotificationSettings.defaults;
      expect(s.enabled, isTrue);
      expect(s.done, isTrue);
      expect(s.question, isTrue);
      expect(s.systemAlerts, isTrue);
    });

    test('kindEnabled honors master and per-kind switches', () {
      const allOn = NotificationSettings.defaults;
      expect(allOn.kindEnabled('done'), isTrue);
      expect(allOn.kindEnabled('question'), isTrue);
      expect(allOn.kindEnabled('approval'), isFalse);

      final masterOff = allOn.copyWith(enabled: false);
      expect(masterOff.kindEnabled('done'), isFalse);

      final noDone = allOn.copyWith(done: false);
      expect(noDone.kindEnabled('done'), isFalse);
      expect(noDone.kindEnabled('question'), isTrue);
    });

    test('json round-trip tolerates missing keys', () {
      final parsed = NotificationSettings.fromJson(const {
        'enabled': false,
        'done': true,
      });
      expect(parsed.enabled, isFalse);
      expect(parsed.done, isTrue);
      expect(parsed.question, isTrue);
      expect(parsed.systemAlerts, isTrue);

      final roundTrip = NotificationSettings.fromJson(parsed.toJson());
      expect(roundTrip.enabled, parsed.enabled);
      expect(roundTrip.done, parsed.done);
      expect(roundTrip.question, parsed.question);
      expect(roundTrip.systemAlerts, parsed.systemAlerts);
    });
  });
}
