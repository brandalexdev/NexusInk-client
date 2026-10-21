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
  Socket? _stylusTcpSocket;
  Socket? _videoSocket;
  InternetAddress? _serverAddress;

  bool _isConnected = false;
  bool _isUsbMode = false;
  bool _usbDetected = false;
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

  bool _isLoopback(InternetAddress ip) {
    return ip.isLoopback || ip.address == '127.0.0.1' || ip.host == 'localhost';
  }

  Future<void> _initSocketAndDiscover() async {
    setState(() {
      _isConnected = false;
      _usbDetected = false;
    });

    _stylusTcpSocket?.destroy();
    _stylusTcpSocket = null;
    _videoSocket?.destroy();
    _videoSocket = null;

    _udpSocket?.close();
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = _udpSocket!.receive();
          if (dg != null) {
            final msg = String.fromCharCodes(dg.data);
            if (msg.contains("NEXUS_INK_SERVER_OK") ||
                msg.contains("MATEPAD_INK_SERVER_OK")) {
              // Discovered via Wi-Fi UDP. If not already connected via USB, connect
              if (!_isConnected && !_isUsbMode) {
                _connectToServer(dg.address, forceUsb: false);
              }
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
    } catch (e) {
      debugPrint("UDP bind error: $e");
    }

    // Simultaneously probe USB connection over TCP 127.0.0.1:5001
    final isUsbAvailable = await _probeUsbDiscovery();
    if (isUsbAvailable && mounted) {
      setState(() => _usbDetected = true);
      if (!_isConnected) {
        // USB Direct Cable is available and preferred: connect immediately!
        _connectToServer(InternetAddress.loopbackIPv4, forceUsb: true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.usb, color: Colors.cyanAccent, size: 18),
                SizedBox(width: 8),
                Text("⚡ USB Cable connected (Direct 127.0.0.1 mode)"),
              ],
            ),
            backgroundColor: Color(0xFF181824),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<bool> _probeUsbDiscovery() async {
    Socket? probeSocket;
    try {
      probeSocket = await Socket.connect(
        '127.0.0.1',
        5001,
        timeout: const Duration(milliseconds: 1200),
      );
      probeSocket.setOption(SocketOption.tcpNoDelay, true);

      // Send pulse query in case server waits for discovery ping
      probeSocket.add("DISCOVER_NEXUS_SERVER\n".codeUnits);
      probeSocket.add("DISCOVER_MATEPAD_SERVER\n".codeUnits);
      await probeSocket.flush();

      final completer = Completer<bool>();
      Timer? timer;
      timer = Timer(const Duration(milliseconds: 1500), () {
        if (!completer.isCompleted) completer.complete(false);
      });

      probeSocket.listen(
        (data) {
          final msg = String.fromCharCodes(data);
          if (msg.contains("MATEPAD_INK_SERVER_OK") ||
              msg.contains("NEXUS_INK_SERVER_OK")) {
            if (!completer.isCompleted) completer.complete(true);
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        cancelOnError: true,
      );

      final success = await completer.future;
      timer.cancel();
      probeSocket.destroy();
      return success;
    } catch (_) {
      probeSocket?.destroy();
      return false;
    }
  }

  Future<void> _connectToServer(InternetAddress ip, {bool? forceUsb}) async {
    final isUsb = forceUsb ?? _isLoopback(ip);

    // Clean up previous connections
    _stylusTcpSocket?.destroy();
    _stylusTcpSocket = null;
    _videoSocket?.destroy();
    _videoSocket = null;

    setState(() {
      _serverAddress = ip;
      _isUsbMode = isUsb;
      _isConnected = !isUsb; // Wi-Fi connects immediately; USB waits for TCP connect
    });

    if (isUsb) {
      try {
        final socket = await Socket.connect(
          ip.address,
          5000,
          timeout: const Duration(seconds: 3),
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
        _stylusTcpSocket = socket;

        socket.listen(
          (_) {},
          onError: (e) {
            _onStylusSocketDisconnected();
          },
          onDone: () {
            _onStylusSocketDisconnected();
          },
          cancelOnError: true,
        );

        if (mounted) {
          setState(() {
            _isConnected = true;
            _usbDetected = true;
          });
        }
      } catch (e) {
        _stylusTcpSocket?.destroy();
        _stylusTcpSocket = null;
        if (mounted) {
          setState(() => _isConnected = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "USB Stylus connection failed (127.0.0.1:5000). Ensure ADB Reverse is active on PC: $e",
              ),
              backgroundColor: const Color(0xFFC0392B),
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }
    }

    if (_showScreenStream) {
      _startVideoStream(ip.address);
    }
  }

  void _onStylusSocketDisconnected() {
    _stylusTcpSocket?.destroy();
    _stylusTcpSocket = null;
    if (mounted && _isUsbMode) {
      setState(() {
        _isConnected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.usb_off, color: Colors.amberAccent, size: 18),
              SizedBox(width: 8),
              Text("USB Cable disconnected."),
            ],
          ),
          backgroundColor: Color(0xFF232330),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _connectViaUsb() {
    setState(() => _showScreenStream = true);
    _connectToServer(InternetAddress.loopbackIPv4, forceUsb: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.usb, color: Colors.cyanAccent, size: 18),
              SizedBox(width: 8),
              Text("Connecting via USB Cable (127.0.0.1)..."),
            ],
          ),
          backgroundColor: Color(0xFF181824),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _startVideoStream(String ip) async {
    _videoSocket?.destroy();
    _videoSocket = null;
    if (!_showScreenStream) return;

    try {
      final s = await Socket.connect(
        ip,
        5002,
        timeout: const Duration(seconds: 3),
      );
      s.setOption(SocketOption.tcpNoDelay, true);
      _videoSocket = s;

      final BytesBuilder buffer = BytesBuilder(copy: false);
      int? expectedLen;

      s.listen(
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
        onError: (_) {
          _videoSocket?.destroy();
          _videoSocket = null;
        },
        onDone: () {
          _videoSocket?.destroy();
          _videoSocket = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      _videoSocket?.destroy();
      _videoSocket = null;
    }
  }

  void _toggleScreenStream() {
    setState(() {
      _showScreenStream = !_showScreenStream;
      if (!_showScreenStream) {
        _videoSocket?.destroy();
        _videoSocket = null;
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

    if (_serverAddress == null) return;

    final byteData = ByteData(28);
    byteData.setInt32(0, action, Endian.big);
    byteData.setFloat32(4, normX, Endian.big);
    byteData.setFloat32(8, normY, Endian.big);
    byteData.setFloat32(12, adjustedPressure, Endian.big);
    byteData.setFloat32(16, event.tilt, Endian.big);
    byteData.setFloat32(20, event.orientation, Endian.big);
    byteData.setInt32(24, isEraser, Endian.big);

    final bytes = byteData.buffer.asUint8List();

    if (_isUsbMode) {
      if (_stylusTcpSocket != null) {
        try {
          _stylusTcpSocket!.add(bytes);
        } catch (_) {}
      }
    } else {
      if (_udpSocket != null) {
        try {
          _udpSocket!.send(bytes, _serverAddress!, 5000);
        } catch (_) {}
      }
    }
  }

  void _sendShortcut(int cmdCode) {
    if (_serverAddress == null) return;
    HapticFeedback.lightImpact();
    final byteData = ByteData(4)..setInt32(0, cmdCode, Endian.big);
    final bytes = byteData.buffer.asUint8List();

    if (_isUsbMode) {
      if (_stylusTcpSocket != null) {
        try {
          _stylusTcpSocket!.add(bytes);
        } catch (_) {}
      }
    } else {
      if (_udpSocket != null) {
        try {
          _udpSocket!.send(bytes, _serverAddress!, 5000);
        } catch (_) {}
      }
    }
  }

  void _openConfigModal() {
    final ctrl = TextEditingController(
      text: _serverAddress != null
          ? (_isUsbMode ? "127.0.0.1" : _serverAddress!.address)
          : "192.168.1.",
    );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF14141E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: _isConnected
                  ? (_isUsbMode
                      ? Colors.cyanAccent.withOpacity(0.5)
                      : Colors.greenAccent.withOpacity(0.4))
                  : Colors.white12,
              width: 1.2,
            ),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.cyanAccent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child:
                    const Icon(Icons.draw, color: Colors.cyanAccent, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  "NexusInk Connection",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _isConnected
                      ? (_isUsbMode
                          ? Colors.cyanAccent.withOpacity(0.2)
                          : Colors.greenAccent.withOpacity(0.2))
                      : Colors.amber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isConnected
                        ? (_isUsbMode ? Colors.cyanAccent : Colors.greenAccent)
                        : Colors.amber,
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isConnected
                          ? (_isUsbMode ? Icons.usb : Icons.wifi)
                          : Icons.sensors_off,
                      size: 11,
                      color: _isConnected
                          ? (_isUsbMode
                              ? Colors.cyanAccent
                              : Colors.greenAccent)
                          : Colors.amber,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isConnected
                          ? (_isUsbMode ? "USB Mode" : "Wi-Fi Mode")
                          : "Offline",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: _isConnected
                            ? (_isUsbMode
                                ? Colors.cyanAccent
                                : Colors.greenAccent)
                            : Colors.amber,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Dedicated "⚡ Connect via USB Cable" card
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _usbDetected
                            ? [
                                const Color(0xFF0D3344),
                                const Color(0xFF145455),
                              ]
                            : [
                                const Color(0xFF1A1A2A),
                                const Color(0xFF1E2638),
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _usbDetected
                            ? Colors.greenAccent.withOpacity(0.7)
                            : Colors.cyanAccent.withOpacity(0.35),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (_usbDetected
                                  ? Colors.greenAccent
                                  : Colors.cyanAccent)
                              .withOpacity(0.08),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          Navigator.pop(ctx);
                          _connectViaUsb();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(9),
                                decoration: BoxDecoration(
                                  color: (_usbDetected
                                          ? Colors.greenAccent
                                          : Colors.cyanAccent)
                                      .withOpacity(0.18),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.usb,
                                  color: _usbDetected
                                      ? Colors.greenAccent
                                      : Colors.cyanAccent,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Text(
                                          "⚡ Connect via USB Cable",
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: (_usbDetected
                                                    ? Colors.greenAccent
                                                    : Colors.cyanAccent)
                                                .withOpacity(0.2),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            border: Border.all(
                                              color: _usbDetected
                                                  ? Colors.greenAccent
                                                  : Colors.cyanAccent
                                                      .withOpacity(0.6),
                                              width: 0.8,
                                            ),
                                          ),
                                          child: Text(
                                            _usbDetected
                                                ? "READY"
                                                : "DIRECT 127.0.0.1",
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                              color: _usbDetected
                                                  ? Colors.greenAccent
                                                  : Colors.cyanAccent,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    const Text(
                                      "ADB Reverse • Sub-1ms TCP stylus & 60 FPS mirror",
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right,
                                color: Colors.white54,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Row(
                    children: [
                      Expanded(child: Divider(color: Colors.white12)),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          "OR WI-FI CONNECTION",
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white38,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: Colors.white12)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: ctrl,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      labelText: "PC Server IP Address",
                      hintText: "e.g., 192.168.1.100 or 127.0.0.1",
                      prefixIcon: const Icon(Icons.wifi, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
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
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white54),
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
            ),
          ),
          actionsPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          actions: [
            TextButton.icon(
              onPressed: () {
                _initSocketAndDiscover();
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text("Auto-Discover"),
            ),
            FilledButton.icon(
              onPressed: () {
                final input = ctrl.text.trim();
                final ip = (input == 'localhost' || input == '127.0.0.1')
                    ? InternetAddress.loopbackIPv4
                    : InternetAddress.tryParse(input);
                if (ip != null) {
                  final isUsb = _isLoopback(ip);
                  if (!isUsb) {
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
                  }
                  _connectToServer(ip, forceUsb: isUsb);
                }
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.link, size: 16),
              label: const Text("Connect IP"),
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
                                  if (!_isConnected) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      _usbDetected
                                          ? "⚡ USB Cable Ready • Tap dock USB icon to connect"
                                          : "Searching for NexusInk-Server (USB / Wi-Fi)...",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w400,
                                        letterSpacing: 1,
                                        color: Colors.white.withOpacity(0.18),
                                      ),
                                    ),
                                  ],
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
                            isUsbMode: _isUsbMode,
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
                            ? (_isUsbMode
                                ? Colors.cyanAccent.withOpacity(0.45)
                                : Colors.greenAccent.withOpacity(0.35))
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
                              ? (_isUsbMode
                                  ? Colors.cyanAccent
                                  : Colors.greenAccent)
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
                            icon: Icons.usb,
                            color: (_isConnected && _isUsbMode)
                                ? Colors.cyanAccent
                                : (_usbDetected
                                    ? Colors.greenAccent
                                    : Colors.white54),
                            onTap: _connectViaUsb,
                          ),
                          _FlushIconBtn(
                            icon: Icons.tune,
                            color: _isConnected
                                ? (_isUsbMode
                                    ? Colors.cyanAccent
                                    : Colors.greenAccent)
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
    _stylusTcpSocket?.destroy();
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
  final bool isUsbMode;

  _WorkspacePainter({
    required this.pos,
    required this.pressure,
    required this.trail,
    required this.showGrid,
    required this.isConnected,
    this.isUsbMode = false,
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
        ..color = (isConnected
                ? (isUsbMode ? Colors.cyanAccent : Colors.greenAccent)
                : Colors.amber)
            .withOpacity(0.18)
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
      old.isConnected != isConnected ||
      old.isUsbMode != isUsbMode;
}
