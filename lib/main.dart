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
              child: Listener(
                onPointerMove: (e) {
                  if (!connected) return;
                  _enqueueMove(e.delta);
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


