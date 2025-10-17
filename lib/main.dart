import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  runApp(const MobileMouseApp());
}

class MobileMouseApp extends StatelessWidget {
  const MobileMouseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: const TouchPadPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

enum ConnState { disconnected, connecting, connected, reconnecting }

class TouchPadPage extends StatefulWidget {
  const TouchPadPage({super.key});

  @override
  State<TouchPadPage> createState() => _TouchPadPageState();
}

class _TouchPadPageState extends State<TouchPadPage> {
  ConnState state = ConnState.disconnected;
  WebSocketChannel? ch;
  String? server;
  Timer? heartbeat;
  final FocusNode _imeFocus = FocusNode();
  final TextEditingController _imeCtrl = TextEditingController();

  // Coalesce
  Offset pendingMove = Offset.zero;
  Timer? flushTimer;

  // Gesture state
  Offset? _lastTapPos;
  Offset? _lastDoubleTapPos;
  double _lastScale = 1.0;
  double _lastRotation = 0.0;
  bool _singleFingerActive = false;

  @override
  void dispose() {
    heartbeat?.cancel();
    flushTimer?.cancel();
    ch?.sink.close();
    _imeCtrl.dispose();
    _imeFocus.dispose();
    super.dispose();
  }

  Future<void> connectDialog() async {
    final ipCtrl = TextEditingController(text: server ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1B1E24),
          title: const Text('连接到 PC', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: ipCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: '示例: 192.168.1.10:8988', hintStyle: TextStyle(color: Colors.white54)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('连接')),
          ],
        );
      },
    );
    if (ok == true) {
      server = ipCtrl.text.trim();
      if (server != null && server!.isNotEmpty) {
        await _connect('ws://$server/ws');
      }
    }
  }

  Future<void> _connect(String url) async {
    setState(() => state = ConnState.connecting);
    try {
      ch?.sink.close();
      ch = WebSocketChannel.connect(Uri.parse(url));
      setState(() => state = ConnState.connected);
      // send client hello
      _sendJson({
        'type': 'hello',
        'clientVersion': '1.0.0',
        'device': 'Flutter',
        'dpi': 440,
        'surface': {'w': 2400, 'h': 1080},
        'locale': 'zh-CN',
      });
      // heartbeat
      heartbeat?.cancel();
      heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        _sendJson({'type': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
      });

      ch!.stream.listen((event) {
        // handle server messages if needed
      }, onDone: _onDisconnected, onError: (_) => _onDisconnected());
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onDisconnected() {
    setState(() => state = ConnState.disconnected);
    heartbeat?.cancel();
  }

  void _sendJson(Map<String, Object?> m) {
    final c = ch;
    if (c == null) return;
    try {
      c.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void _enqueueMove(Offset delta) {
    pendingMove += delta;
    flushTimer ??= Timer(const Duration(milliseconds: 12), () {
      final send = pendingMove;
      pendingMove = Offset.zero;
      flushTimer = null;
      if (send.distanceSquared > 0.2) {
        _sendJson({
          'type': 'mouse_move',
          'ts': DateTime.now().millisecondsSinceEpoch,
          'dx': send.dx,
          'dy': send.dy,
          'fingers': 1,
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final connected = state == ConnState.connected;
    return Scaffold(
      backgroundColor: const Color(0xFF111318),
      body: SafeArea(
        child: Stack(
          children: [
            // Touch area
            Positioned.fill(
              child: GestureDetector(
                onTapDown: (details) {
                  _lastTapPos = details.localPosition;
                },
                onTap: () {
                  if (!connected) return;
                  final p = _lastTapPos ?? const Offset(0, 0);
                  _sendJson({'type': 'tap', 'ts': DateTime.now().millisecondsSinceEpoch, 'x': p.dx, 'y': p.dy});
                },
                onDoubleTapDown: (details) {
                  _lastDoubleTapPos = details.localPosition;
                },
                onDoubleTap: () {
                  if (!connected) return;
                  final p = _lastDoubleTapPos ?? const Offset(0, 0);
                  _sendJson({'type': 'doubletap', 'ts': DateTime.now().millisecondsSinceEpoch, 'x': p.dx, 'y': p.dy});
                },
                onLongPressStart: (details) {
                  if (!connected) return;
                  _sendJson({
                    'type': 'longpress',
                    'ts': DateTime.now().millisecondsSinceEpoch,
                    'x': details.localPosition.dx,
                    'y': details.localPosition.dy,
                  });
                },
                onScaleStart: (details) {
                  if (!connected) return;
                  _singleFingerActive = details.pointerCount == 1;
                  _lastScale = 1.0;
                  _lastRotation = 0.0;
                  final fp = details.localFocalPoint;
                  if (_singleFingerActive) {
                    _sendJson({'type': 'touchstart', 'ts': DateTime.now().millisecondsSinceEpoch, 'x': fp.dx, 'y': fp.dy});
                  } else {
                    _sendJson({'type': 'gesture_start', 'ts': DateTime.now().millisecondsSinceEpoch, 'cx': fp.dx, 'cy': fp.dy});
                  }
                },
                onScaleUpdate: (details) {
                  if (!connected) return;
                  if (details.pointerCount == 1) {
                    final d = details.focalPointDelta;
                    // 保留原鼠标移动协议，同时发送 touchmove
                    _enqueueMove(d);
                    _sendJson({'type': 'touchmove', 'ts': DateTime.now().millisecondsSinceEpoch, 'dx': d.dx, 'dy': d.dy});
                  } else {
                    final fp = details.localFocalPoint;
                    // Pinch
                    final scale = details.scale;
                    final ds = scale - _lastScale;
                    _lastScale = scale;
                    if (ds.abs() > 0.001) {
                      _sendJson({
                        'type': 'pinch',
                        'ts': DateTime.now().millisecondsSinceEpoch,
                        'scale': scale,
                        'dscale': ds,
                        'cx': fp.dx,
                        'cy': fp.dy,
                      });
                    }
                    // Rotate
                    final rot = details.rotation; // radians
                    final dr = rot - _lastRotation;
                    _lastRotation = rot;
                    if (dr.abs() > 0.0001) {
                      _sendJson({
                        'type': 'rotate',
                        'ts': DateTime.now().millisecondsSinceEpoch,
                        'radians': rot,
                        'dr': dr,
                        'cx': fp.dx,
                        'cy': fp.dy,
                      });
                    }
                  }
                },
                onScaleEnd: (details) {
                  if (!connected) return;
                  final v = details.velocity.pixelsPerSecond;
                  if (_singleFingerActive) {
                    _sendJson({'type': 'touchend', 'ts': DateTime.now().millisecondsSinceEpoch, 'vx': v.dx, 'vy': v.dy});
                  } else {
                    _sendJson({'type': 'gesture_end', 'ts': DateTime.now().millisecondsSinceEpoch, 'vx': v.dx, 'vy': v.dy});
                  }
                  _singleFingerActive = false;
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1E24),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2A2F3A)),
                  ),
                ),
              ),
            ),

            // Connect button
            Positioned(
              left: 24,
              top: 16,
              child: FilledButton.tonal(
                style: ButtonStyle(backgroundColor: WidgetStatePropertyAll(connected ? Colors.green.shade600 : Colors.grey.shade700)),
                onPressed: connectDialog,
                child: Row(children: [const Icon(Icons.link), const SizedBox(width: 8), Text(connected ? '已连接' : '连接')]),
              ),
            ),

            // Keyboard button
            Positioned(
              right: 24,
              top: 16,
              child: FilledButton(
                onPressed: () {
                  FocusScope.of(context).requestFocus(_imeFocus);
                },
                child: const Icon(Icons.keyboard_alt_rounded),
              ),
            ),

            // Hidden TextField
            Positioned(
              right: -1000,
              bottom: -1000,
              child: SizedBox(
                width: 1,
                height: 1,
                child: TextField(
                  focusNode: _imeFocus,
                  controller: _imeCtrl,
                  onChanged: (v) {
                    // MVP：直接按提交文本发送；后续改为 diff
                    if (v.isNotEmpty) {
                      _sendJson({'type': 'text_input', 'ts': DateTime.now().millisecondsSinceEpoch, 'text': v, 'commit': true});
                      _imeCtrl.clear();
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


