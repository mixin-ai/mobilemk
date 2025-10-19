import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

class _TouchPadPageState extends State<TouchPadPage> with WidgetsBindingObserver {
  ConnState state = ConnState.disconnected;
  WebSocketChannel? ch;
  String? server;
  Timer? heartbeat;
  final FocusNode _imeFocus = FocusNode();
  final TextEditingController _imeCtrl = TextEditingController();
  final FocusNode _rawFocus = FocusNode();

  // Coalesce
  Offset pendingMove = Offset.zero;
  Timer? flushTimer;

  // Gesture state
  Offset? _lastTapPos;
  Offset? _lastDoubleTapPos;
  double _lastScale = 1.0;
  double _lastRotation = 0.0;
  bool _singleFingerActive = false;
  // Move sensitivity
  final double _moveGain = 1.6;
  List<String> recentServers = [];

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    heartbeat?.cancel();
    flushTimer?.cancel();
    ch?.sink.close();
    _imeCtrl.dispose();
    _imeFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRecentServers() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('recentServers') ?? [];
    setState(() {
      recentServers = list;
    });
  }

  Future<void> _saveRecentServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recentServers', recentServers);
  }

  void _pinRecentServer(String s) {
    setState(() {
      final idx = recentServers.indexOf(s);
      if (idx != -1) recentServers.removeAt(idx);
      recentServers.insert(0, s);
      if (recentServers.length > 5) {
        recentServers = recentServers.sublist(0, 5);
      }
    });
    _saveRecentServers();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadRecentServers();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.resumed) {
      _attemptAutoReconnect();
    }
  }

  void _attemptAutoReconnect() {
    if (this.state == ConnState.connected) return;
    String? target = server;
    if (target == null || target.isEmpty) {
      if (recentServers.isEmpty) return;
      target = recentServers.first;
    }
    if (target == null || target.isEmpty) return;
    server = target;
    setState(() => this.state = ConnState.reconnecting);
    _connect('ws://$target/ws');
  }

  Future<void> connectDialog() async {
      const defaultPrefix = '192.168.';
      const defaultPort = ':8988';
      String mid = '';
      if (server != null && server!.startsWith(defaultPrefix) && server!.endsWith(defaultPort)) {
        mid = server!.substring(defaultPrefix.length, server!.length - defaultPort.length);
      }
      if (mid.isEmpty && recentServers.isNotEmpty) {
        String first = recentServers.first;
        if (first.startsWith(defaultPrefix) && first.endsWith(defaultPort)) {
          mid = first.substring(defaultPrefix.length, first.length - defaultPort.length);
        } else {
          mid = first;
        }
      }
      final ipCtrl = TextEditingController(text: mid);
      bool? ok;
      final prevOrientations = [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight];
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    try {
      ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1B1E24),
            title: const Text('连接到 PC', style: TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ipCtrl,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: '192.168.请输入ip',
                    hintStyle: TextStyle(color: Colors.white54),
                    prefixText: '192.168.',
                    suffixText: ':8988',
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
                const SizedBox(height: 12),
                if (recentServers.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('最近连接', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                if (recentServers.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: recentServers.take(5).map((s) {
                      String midItem = s;
                      const dp = '192.168.';
                      const dport = ':8988';
                      if (midItem.startsWith(dp) && midItem.endsWith(dport)) {
                        midItem = midItem.substring(dp.length, midItem.length - dport.length);
                      }
                      return ActionChip(
                        label: Text(midItem, style: const TextStyle(color: Colors.white)),
                        onPressed: () {
                          ipCtrl.text = midItem;
                        },
                      );
                    }).toList(),
                  ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('连接')),
            ],
          );
        },
      );
    } finally {
      await SystemChrome.setPreferredOrientations(prevOrientations);
    }
    if (ok == true) {
      final midInput = ipCtrl.text.trim();
      if (midInput.isNotEmpty) {
        server = '$defaultPrefix$midInput$defaultPort';
        _pinRecentServer(server!);
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

  // 新增：滚轮累计与节流
  double pendingRoll = 0.0;
  Timer? rollFlushTimer;
  final double _rollGain = 1.0;

  void _enqueueMove(Offset delta) {
    // 应用增益系数后再累计，方便统一节流发送
    pendingMove += Offset(delta.dx * _moveGain, delta.dy * _moveGain);
    flushTimer ??= Timer(const Duration(milliseconds: 40), () {
      final send = pendingMove;
      pendingMove = Offset.zero;
      flushTimer = null;
      if (send.distanceSquared > 0.01) {
        _sendJson({
          'type': 'mouse_move',
          'ts': DateTime.now().millisecondsSinceEpoch,
          'dx': send.dx,
          'dy': send.dy,
          'fingers': 1,
        });
        _sendJson({
          'type': 'touchmove',
          'ts': DateTime.now().millisecondsSinceEpoch,
          'dx': send.dx,
          'dy': send.dy,
        });
      }
    });
  }

  // 新增：滚轮事件累计与节流发送（两指垂直滑动）
  void _enqueueRoll(double dy) {
    pendingRoll += dy * _rollGain;
    rollFlushTimer ??= Timer(const Duration(milliseconds: 40), () {
      final send = pendingRoll;
      pendingRoll = 0.0;
      rollFlushTimer = null;
      if (send.abs() > 0.01) {
        _sendJson({
          'type': 'roll',
          'ts': DateTime.now().millisecondsSinceEpoch,
          'dy': send,
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
                    // 改为节流：累计当前位移，100ms 定时发送合并位移
                    _enqueueMove(details.focalPointDelta);
                  } else {
                    // 两指上下滑动触发滚轮
                    _enqueueRoll(details.focalPointDelta.dy);
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
                onPressed: () async {
                  // 先取消当前焦点，避免被其他节点占用
                  FocusManager.instance.primaryFocus?.unfocus();
                  await Future.delayed(const Duration(milliseconds: 10));
                  // 只请求隐藏输入框的焦点
                  FocusScope.of(context).requestFocus(_imeFocus);
                  // 显式请求显示软键盘（部分设备在恢复后需要）
                  try {
                    await SystemChannels.textInput.invokeMethod('TextInput.show');
                  } catch (_) {}
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


