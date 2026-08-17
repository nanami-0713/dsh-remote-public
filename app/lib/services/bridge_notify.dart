import 'dart:async';

import 'dsh_stream.dart';

/// One notification pushed from the PC (dsh-notifier → bridge → this phone).
class BridgeNotify {
  const BridgeNotify({
    required this.kind,
    required this.title,
    required this.message,
    required this.sessionId,
    required this.at,
  });

  /// 'done' | 'approval' | 'question' | 'error'
  final String kind;
  final String title;
  final String message;
  final String sessionId;
  final int at;

  bool get isSticky => kind == 'question';

  factory BridgeNotify.fromJson(Map<String, dynamic> json) {
    return BridgeNotify(
      kind: json['kind'] as String? ?? '',
      title: json['title'] as String? ?? '',
      message: json['message'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      at: json['at'] as int? ?? 0,
    );
  }
}

/// App-wide listener for `bridge/notify` frames.
///
/// The bridge fans PC popup copies out to every connected phone over the
/// events WebSocket; this service keeps its own connection so notifications
/// arrive even when the user is not inside a chat screen. The home screen
/// starts it after a successful connection and restarts it when the PC
/// (server/token) changes.
class BridgeNotifyService {
  BridgeNotifyService._();

  static final BridgeNotifyService instance = BridgeNotifyService._();

  final StreamController<BridgeNotify> _controller =
      StreamController<BridgeNotify>.broadcast();

  DshStream? _stream;
  String? _baseUrl;
  String? _token;

  Stream<BridgeNotify> get stream => _controller.stream;

  bool get active => _stream != null;

  String? get baseUrl => _baseUrl;

  String? get token => _token;

  void start({required String baseUrl, required String token}) {
    if (active && _baseUrl == baseUrl && _token == token) return;
    stop();
    _baseUrl = baseUrl;
    _token = token;
    _stream = DshStream(baseUrl: baseUrl, token: token);
    _stream!.connect((frame) {
      if (frame['type'] != 'bridge/notify') return;
      final payload = frame['payload'];
      if (payload is! Map<String, dynamic>) return;
      _controller.add(BridgeNotify.fromJson(payload));
    });
  }

  void stop() {
    _stream?.disconnect();
    _stream = null;
    _baseUrl = null;
    _token = null;
  }
}
