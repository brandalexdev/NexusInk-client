import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  // Full true edge-to-edge mode without status or navigation bars
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );
  runApp(const NexusInkClientApp());
}

class NexusInkClientApp extends StatelessWidget {
  const NexusInkClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexusInk-Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const TabletWorkspace(),
    );
  }
}

class TabletWorkspace extends StatefulWidget {
  const TabletWorkspace({super.key});

  @override
  State<TabletWorkspace> createState() => _TabletWorkspaceState();
}

class _TabletWorkspaceState extends State<TabletWorkspace> {
  RawDatagramSocket? _udpSocket;
  Socket? _videoSocket;
  InternetAddress? _serverAddress;

  bool _isConnected = false;
  bool _showScreenStream = true;
  bool _isToolbarCollapsed = false;
  bool _stretchFullScreen =
      true; // True = 100% full screen, False = 16:9 letterboxed

  Uint8List? _currentFrame;
  Offset? _cursorPos;
  double _currentPressure = 0.0;
  double _pressureCurve = 1.0;

  // Keeps a short local trail for ultra-responsive visual feedback
  final List<Offset> _liveTrail = [];

  @override
  void initState() {
    super.initState();
    _initSocketAndDiscover();
  }

  Future<void> _initSocketAndDiscover() async {
    setState(() => _isConnected = false);

    _udpSocket?.close();
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _udpSocket!.broadcastEnabled = true;

    _udpSocket!.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final dg = _udpSocket!.receive();
        if (dg != null) {
          final msg = String.fromCharCodes(dg.data);
          if (msg == "NEXUS_INK_SERVER_OK" || msg == "MATEPAD_INK_SERVER_OK") {
            _connectToServerIp(dg.address);
          }
        }
      }
    });

    // Broadcast discovery pulse for NexusInk Server (and legacy fallback)
    _udpSocket!.send(
      "DISCOVER_NEXUS_SERVER".codeUnits,
      InternetAddress("255.255.255.255"),
      5001,
    );
    _udpSocket!.send(
      "DISCOVER_MATEPAD_SERVER".codeUnits,
      InternetAddress("255.255.255.255"),
      5001,
    );
  }

  void _connectToServerIp(InternetAddress ip) {
    setState(() {
      _serverAddress = ip;
      _isConnected = true;
    });
    if (_showScreenStream) {
      _startVideoStream(ip.address);
    }
  }

  Future<void> _startVideoStream(String ip) async {
    _videoSocket?.destroy();
    if (!_showScreenStream) return;

    try {
      _videoSocket = await Socket.connect(
        ip,
        5002,
        timeout: const Duration(seconds: 3),
      );
      _videoSocket!.setOption(SocketOption.tcpNoDelay, true);

      final BytesBuilder buffer = BytesBuilder(copy: false);
      int? expectedLen;

      _videoSocket!.listen(
        (Uint8List chunk) {
          buffer.add(chunk);
          while (true) {
            final currentBytes = buffer.toBytes();
            if (expectedLen == null) {
              if (currentBytes.length >= 4) {
                final bd = ByteData.sublistView(currentBytes, 0, 4);
                expectedLen = bd.getInt32(0, Endian.big);
                buffer.clear();
                buffer.add(currentBytes.sublist(4));
              } else {
                break;
              }
            }

            final remainingBytes = buffer.toBytes();
            if (expectedLen != null && remainingBytes.length >= expectedLen!) {
              final frameBytes = remainingBytes.sublist(0, expectedLen!);
              final leftover = remainingBytes.sublist(expectedLen!);
              buffer.clear();
              buffer.add(leftover);
              expectedLen = null;

              if (mounted && _showScreenStream) {
                setState(() => _currentFrame = frameBytes);
              }
            } else {
              break;
            }
          }
        },
        onError: (_) => _videoSocket?.destroy(),
        onDone: () => _videoSocket?.destroy(),
      );
    } catch (_) {}
  }

  void _toggleScreenStream() {
    setState(() {
      _showScreenStream = !_showScreenStream;
      if (!_showScreenStream) {
        _videoSocket?.destroy();
        _currentFrame = null;
      } else if (_serverAddress != null) {
        _startVideoStream(_serverAddress!.address);
      }
    });
  }

  void _sendStylusPacket(
    int action,
    Offset localPos,
    Size canvasSize,
    PointerEvent event,
  ) {
    // Strict palm rejection: Only process Huawei M-Pencil / Active Stylus
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }

    // Calculate active drawing area depending on Fullscreen Stretch vs 16:9 Fit
    Rect activeRect = Offset.zero & canvasSize;
    if (!_stretchFullScreen) {
      final double targetH = canvasSize.width * (9.0 / 16.0);
      if (targetH <= canvasSize.height) {
        final double topOffset = (canvasSize.height - targetH) / 2.0;
        activeRect = Rect.fromLTWH(0, topOffset, canvasSize.width, targetH);
      } else {
        final double targetW = canvasSize.height * (16.0 / 9.0);
        final double leftOffset = (canvasSize.width - targetW) / 2.0;
        activeRect = Rect.fromLTWH(leftOffset, 0, targetW, canvasSize.height);
      }
    }

    final normX = ((localPos.dx - activeRect.left) / activeRect.width).clamp(
      0.0,
      1.0,
    );
    final normY = ((localPos.dy - activeRect.top) / activeRect.height).clamp(
      0.0,
      1.0,
    );

    double rawPressure = (action == 1 || action == 2)
        ? event.pressure.clamp(0.0, 1.0)
        : 0.0;
    double adjustedPressure = math
        .pow(rawPressure, _pressureCurve)
        .toDouble()
        .clamp(0.0, 1.0);

    final isEraser =
        (event.kind == PointerDeviceKind.invertedStylus ||
            (event.buttons & kPrimaryStylusButton != 0))
        ? 1
        : 0;

    setState(() {
      if (action == 0) {
        _cursorPos = null;
        _liveTrail.clear();
      } else {
        _cursorPos = localPos;
        if (action == 1 || action == 2) {
          _liveTrail.add(localPos);
          if (_liveTrail.length > 10) _liveTrail.removeAt(0);
        } else {
          _liveTrail.clear();
        }
      }
      _currentPressure = adjustedPressure;
    });

    if (_serverAddress == null || _udpSocket == null) return;

    final byteData = ByteData(28);
    byteData.setInt32(0, action, Endian.big);
    byteData.setFloat32(4, normX, Endian.big);
    byteData.setFloat32(8, normY, Endian.big);
    byteData.setFloat32(12, adjustedPressure, Endian.big);
    byteData.setFloat32(16, event.tilt, Endian.big);
    byteData.setFloat32(20, event.orientation, Endian.big);
    byteData.setInt32(24, isEraser, Endian.big);

    _udpSocket!.send(byteData.buffer.asUint8List(), _serverAddress!, 5000);
  }

  void _sendShortcut(int cmdCode) {
    if (_serverAddress == null || _udpSocket == null) return;
    HapticFeedback.lightImpact();
    final byteData = ByteData(4)..setInt32(0, cmdCode, Endian.big);
    _udpSocket!.send(byteData.buffer.asUint8List(), _serverAddress!, 5000);
  }

  void _openConfigModal() {
    final ctrl = TextEditingController(
      text: _serverAddress?.address ?? "192.168.1.",
    );
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF181820),
          title: const Row(
            children: [
              Icon(Icons.draw, color: Colors.cyanAccent, size: 20),
              SizedBox(width: 8),
              Text(
                "NexusInk-Client Settings",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: "PC Server IP Address",
                  hintText: "e.g., 192.168.1.100",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  "Stretch to 100% Full Screen",
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  _stretchFullScreen
                      ? "Fills every pixel of the tablet screen"
                      : "Locks 16:9 aspect ratio (prevents oval circles)",
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
                value: _stretchFullScreen,
                onChanged: (v) {
                  setModalState(() => _stretchFullScreen = v);
                  setState(() => _stretchFullScreen = v);
                },
              ),
              const SizedBox(height: 8),
              Text(
                "Pressure Sensitivity Curve: ${_pressureCurve.toStringAsFixed(2)}",
                style: const TextStyle(fontSize: 13),
              ),
              Slider(
                value: _pressureCurve,
                min: 0.5,
                max: 2.0,
                divisions: 6,
                onChanged: (v) {
                  setModalState(() => _pressureCurve = v);
                  setState(() => _pressureCurve = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _initSocketAndDiscover();
                Navigator.pop(ctx);
              },
              child: const Text("Auto-Discover"),
            ),
            FilledButton(
              onPressed: () {
                final ip = InternetAddress.tryParse(ctrl.text.trim());
                if (ip != null) {
                  _udpSocket?.send(
                    "DISCOVER_NEXUS_SERVER".codeUnits,
                    ip,
                    5001,
                  );
                  _udpSocket?.send(
                    "DISCOVER_MATEPAD_SERVER".codeUnits,
                    ip,
                    5001,
                  );
                  _connectToServerIp(ip);
                }
                Navigator.pop(ctx);
              },
              child: const Text("Connect IP"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Remove all system paddings so the canvas covers 100% of physical pixels
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: Scaffold(
        backgroundColor: const Color(0xFF070709),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. TRUE 100% EDGE-TO-EDGE DRAWING SURFACE
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final canvasSize = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  return Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) =>
                        _sendStylusPacket(1, e.localPosition, canvasSize, e),
                    onPointerMove: (e) =>
                        _sendStylusPacket(2, e.localPosition, canvasSize, e),
                    onPointerUp: (e) =>
                        _sendStylusPacket(0, e.localPosition, canvasSize, e),
                    onPointerCancel: (e) =>
                        _sendStylusPacket(0, e.localPosition, canvasSize, e),
                    onPointerHover: (e) =>
                        _sendStylusPacket(3, e.localPosition, canvasSize, e),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_showScreenStream && _currentFrame != null)
                          Image.memory(
                            _currentFrame!,
                            fit: _stretchFullScreen
                                ? BoxFit.fill
                                : BoxFit.contain,
                            width: double.infinity,
                            height: double.infinity,
                            gaplessPlayback: true,
                            // Medium filter quality provides crisp text & lines on 2200x1440 screen
                            filterQuality: FilterQuality.medium,
                          ),
                        if (!_showScreenStream || _currentFrame == null)
                          IgnorePointer(
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.draw_rounded,
                                    size: 42,
                                    color: Colors.white.withOpacity(0.06),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    "NexusInk-Client",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 3,
                                      color: Colors.white.withOpacity(0.09),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        CustomPaint(
                          size: Size.infinite,
                          painter: _WorkspacePainter(
                            pos: _cursorPos,
                            pressure: _currentPressure,
                            trail: List.of(_liveTrail),
                            showGrid:
                                !_showScreenStream || _currentFrame == null,
                            isConnected: _isConnected,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // 2. ULTRA-SLIM FLUSH EDGE DOCK (38px wide, pinned to x = 0)
            Align(
              alignment: Alignment.centerLeft,
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 38,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xAA101016),
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      ),
                      border: Border.all(
                        color: _isConnected
                            ? Colors.greenAccent.withOpacity(0.35)
                            : Colors.amber.withOpacity(0.35),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Collapse / Expand toggle button
                        _FlushIconBtn(
                          icon: _isToolbarCollapsed
                              ? Icons.chevron_right
                              : Icons.chevron_left,
                          color: _isConnected
                              ? Colors.greenAccent
                              : Colors.amber,
                          onTap: () => setState(
                            () => _isToolbarCollapsed = !_isToolbarCollapsed,
                          ),
                        ),
                        if (!_isToolbarCollapsed) ...[
                          const SizedBox(height: 4),
                          _FlushIconBtn(
                            icon: Icons.undo,
                            onTap: () => _sendShortcut(1),
                          ),
                          _FlushIconBtn(
                            icon: Icons.redo,
                            onTap: () => _sendShortcut(2),
                          ),
                          _FlushIconBtn(
                            icon: Icons.pan_tool_alt_outlined,
                            onTap: () => _sendShortcut(3),
                          ),
                          _FlushIconBtn(
                            icon: Icons.colorize,
                            onTap: () => _sendShortcut(4),
                          ),
                          _FlushIconBtn(
                            icon: Icons.brush,
                            onTap: () => _sendShortcut(5),
                          ),
                          _FlushIconBtn(
                            icon: Icons.auto_fix_normal,
                            onTap: () => _sendShortcut(6),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: 4,
                              horizontal: 6,
                            ),
                            child: Divider(color: Colors.white24, height: 1),
                          ),
                          _FlushIconBtn(
                            icon: _stretchFullScreen
                                ? Icons.aspect_ratio
                                : Icons.fit_screen,
                            color: _stretchFullScreen
                                ? Colors.white70
                                : Colors.amberAccent,
                            onTap: () => setState(
                              () => _stretchFullScreen = !_stretchFullScreen,
                            ),
                          ),
                          _FlushIconBtn(
                            icon: _showScreenStream
                                ? Icons.visibility
                                : Icons.visibility_off,
                            color: _showScreenStream
                                ? Colors.cyanAccent
                                : Colors.white38,
                            onTap: _toggleScreenStream,
                          ),
                          _FlushIconBtn(
                            icon: Icons.tune,
                            color: _isConnected
                                ? Colors.greenAccent
                                : Colors.amber,
                            onTap: _openConfigModal,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _udpSocket?.close();
    _videoSocket?.destroy();
    super.dispose();
  }
}

class _FlushIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const _FlushIconBtn({
    required this.icon,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, color: color, size: 18),
        ),
      ),
    );
  }
}

class _WorkspacePainter extends CustomPainter {
  final Offset? pos;
  final double pressure;
  final List<Offset> trail;
  final bool showGrid;
  final bool isConnected;

  _WorkspacePainter({
    required this.pos,
    required this.pressure,
    required this.trail,
    required this.showGrid,
    required this.isConnected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) {
      final gridPaint = Paint()
        ..color = Colors.white.withOpacity(0.05)
        ..strokeWidth = 1.0;

      // Subtle rule-of-thirds and center crosshair when screen stream is off
      for (int i = 1; i < 3; i++) {
        canvas.drawLine(
          Offset(size.width * (i / 3), 0),
          Offset(size.width * (i / 3), size.height),
          gridPaint,
        );
        canvas.drawLine(
          Offset(0, size.height * (i / 3)),
          Offset(size.width, size.height * (i / 3)),
          gridPaint,
        );
      }

      // Outer border indicator
      final borderPaint = Paint()
        ..color = (isConnected ? Colors.cyanAccent : Colors.amber).withOpacity(
          0.18,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(Offset.zero & size, borderPaint);
    }

    // Draw instant local ink feedback trail so the stylus feels 0ms latency
    if (trail.length > 1) {
      final trailPaint = Paint()
        ..color = Colors.cyanAccent.withOpacity(0.55)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.5 + (pressure * 6.0)
        ..style = PaintingStyle.stroke;

      final path = Path()..moveTo(trail.first.dx, trail.first.dy);
      for (int i = 1; i < trail.length; i++) {
        path.lineTo(trail[i].dx, trail[i].dy);
      }
      canvas.drawPath(path, trailPaint);
    }

    // Precision stylus crosshair & dynamic pressure ring
    if (pos != null) {
      final ringPaint = Paint()
        ..color = pressure > 0 ? Colors.cyanAccent : Colors.amberAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 + (pressure * 3.5);
      canvas.drawCircle(pos!, 4.0 + (pressure * 11.0), ringPaint);

      final crossPaint = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1.0;
      canvas.drawLine(
        Offset(pos!.dx - 4, pos!.dy),
        Offset(pos!.dx + 4, pos!.dy),
        crossPaint,
      );
      canvas.drawLine(
        Offset(pos!.dx, pos!.dy - 4),
        Offset(pos!.dx, pos!.dy + 4),
        crossPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WorkspacePainter old) =>
      old.pos != pos ||
      old.pressure != pressure ||
      old.showGrid != showGrid ||
      old.isConnected != isConnected;
}
