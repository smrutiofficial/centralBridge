import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:sinergia/screens/dashboard.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Linux Chat Server',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: ChatServerScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChatServerScreen extends StatefulWidget {
  @override
  _ChatServerScreenState createState() => _ChatServerScreenState();
}

class _ChatServerScreenState extends State<ChatServerScreen> {
  HttpServer? _server;
  WebSocketChannel? _clientChannel;
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _receivedFiles = []; // Track received files
  TextEditingController _messageController = TextEditingController();
  String _serverAddress = '';
  int _serverPort = 4074;
  bool _isServerRunning = false;
  String _connectionStatus = 'Not connected';
  final MDnsClient _mdns = MDnsClient();

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      final networkInfo = NetworkInfo();
      final wifiIP = await networkInfo.getWifiIP();
      _serverAddress = wifiIP ?? '127.0.0.1';

      _server = await HttpServer.bind(_serverAddress, _serverPort);
      print('Server started on $_serverAddress:$_serverPort');

      setState(() {
        _isServerRunning = true;
      });

      // Broadcast using mDNS
      await _mdns.start();
      _broadcastMDNS(Platform.localHostname, _serverPort);

      _server!.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then((WebSocket webSocket) {
            print('Client connected');
            _handleWebSocketConnection(webSocket);
          });
        }
      });
    } catch (e) {
      print('Error starting server: $e');
    }
  }

  Future<void> _broadcastMDNS(String deviceName, int port) async {
    final serviceType = '_chatbridge._tcp';
    final serviceName = '$deviceName';
    final fingerprint = _generateFingerprint(deviceName);

    final args = [
      '-s', // short service
      serviceName,
      serviceType,
      port.toString(),
      'fingerprint=$fingerprint',
    ];

    try {
      final process = await Process.start('avahi-publish-service', args);
      print(
        "Started mDNS broadcast using avahi: $serviceName.$serviceType:$port",
      );

      // Optional: Keep reference to kill later if needed
      process.stdout.transform(utf8.decoder).listen((data) {
        print('[mDNS] $data');
      });
    } catch (e) {
      print("Error starting avahi-publish-service: $e");
    }
  }

  void _handleWebSocketConnection(WebSocket webSocket) async {
    final channel = IOWebSocketChannel(webSocket);
    String? storedFingerprint;
    bool paired = false;
    Timer? infoTimer;

    try {
      final prefs = await SharedPreferences.getInstance();
      storedFingerprint = prefs.getString('paired_fingerprint');
    } catch (_) {}

    channel.stream.listen(
      (data) async {
        try {
          final message = jsonDecode(data);
          print("📥 Received message: ${message.toString()}");

          // Handle pairing first
          if (message.containsKey('fingerprint')) {
            final receivedFingerprint = message['fingerprint'];
            print("📥 Received fingerprint: $receivedFingerprint");

            if (storedFingerprint == null ||
                storedFingerprint == receivedFingerprint) {
              if (storedFingerprint == null && receivedFingerprint != null) {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(
                  'paired_fingerprint',
                  receivedFingerprint,
                );
                print("✅ Fingerprint stored: $receivedFingerprint");
              }

              paired = true;
              _clientChannel = channel;
              setState(() {
                _connectionStatus = 'Connected';
              });

              final systemInfo = await getSystemInfo();
              final verificationMessage = jsonEncode({
                'text': '[verified]',
                'status': 'connected',
                'sender': 'Linux',
                'timestamp': DateTime.now().toIso8601String(),
                'device_info': {
                  'device_name': Platform.localHostname,
                  'ip': _serverAddress,
                  ...systemInfo,
                },
              });
              channel.sink.add(verificationMessage);

              infoTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
                final systemInfo = await getSystemInfo();
                final updateMessage = jsonEncode({
                  'channel': 'system_info',
                  'timestamp': DateTime.now().toIso8601String(),
                  'device_info': {
                    'device_name': Platform.localHostname,
                    'ip': _serverAddress,
                    ...systemInfo,
                  },
                });
                channel.sink.add(updateMessage);
              });

              return;
            } else {
              print("⚠️ Received unknown fingerprint: $receivedFingerprint");
              webSocket.close();
              return;
            }
          }

          // Handle file transfer from Android client
          if (message['channel'] == 'file_transfer' && paired) {
            await _handleFileTransfer(message, channel);
            return;
          }

          // Handle regular messages if needed
          if (message.containsKey('text') && !message.containsKey('channel')) {
            setState(() {
              _messages.add({
                'text': message['text'],
                'sender': message['sender'] ?? 'Unknown',
                'timestamp': DateTime.now(),
              });
            });
          }
        } catch (e) {
          print("❌ Error parsing message: $e");
          print("Raw data: $data");
        }
      },
      onDone: () {
        infoTimer?.cancel();
        setState(() {
          _connectionStatus = 'Disconnected';
          _clientChannel = null;
        });
        print('WebSocket disconnected');
      },
      onError: (error) {
        infoTimer?.cancel();
        setState(() {
          _connectionStatus = 'Error: $error';
          _clientChannel = null;
        });
        print('WebSocket error: $error');
      },
    );
  }

  Future<void> _handleFileTransfer(
    Map<String, dynamic> message,
    IOWebSocketChannel channel,
  ) async {
    try {
      final filename = message['filename'];
      final base64Data = message['data'];
      final sender = message['sender'] ?? 'Unknown';
      final timestamp =
          message['timestamp'] ?? DateTime.now().toIso8601String();
      final fileIndex = message['file_index'] ?? 0;

      print("📁 Receiving file: $filename (index: $fileIndex)");

      if (filename == null || base64Data == null) {
        print("❌ Invalid file transfer message - missing filename or data");
        _sendFileAck(
          channel,
          filename ?? 'unknown',
          'error',
          'Missing filename or data',
        );
        return;
      }

      // Decode base64 data
      List<int> bytes;
      try {
        bytes = base64Decode(base64Data);
      } catch (e) {
        print("❌ Failed to decode base64 data: $e");
        _sendFileAck(channel, filename, 'error', 'Failed to decode file data');
        return;
      }

      // Determine save directory
      final homeDir = Platform.environment['HOME'] ?? '/home/username';
      final saveDir = Directory('$homeDir/Downloads');

      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }

      // Handle filename conflicts
      String finalFilename = filename;
      File file = File('${saveDir.path}/$finalFilename');
      int counter = 1;

      while (await file.exists()) {
        final nameParts = filename.split('.');
        if (nameParts.length > 1) {
          final name = nameParts.sublist(0, nameParts.length - 1).join('.');
          final extension = nameParts.last;
          finalFilename = '${name}_$counter.$extension';
        } else {
          finalFilename = '${filename}_$counter';
        }
        file = File('${saveDir.path}/$finalFilename');
        counter++;
      }

      // Save file
      await file.writeAsBytes(bytes);
      final fileSizeKB = (bytes.length / 1024).round();

      print('✅ File saved successfully: ${file.path} (${fileSizeKB}KB)');

      // Update UI with received file info
      setState(() {
        _receivedFiles.add({
          'filename': finalFilename,
          'originalFilename': filename,
          'sender': sender,
          'timestamp': DateTime.parse(timestamp),
          'path': file.path,
          'size': fileSizeKB,
          'fileIndex': fileIndex,
        });
      });

      // Send success acknowledgment
      _sendFileAck(channel, filename, 'success', 'File saved successfully');
      // 🔊 Play sound
      await Process.run('canberra-gtk-play', ['--id=complete', '--volume=1000']);

      // 🔔 Send notification
      await Process.run('notify-send', [
        "File saved successfully",
        filename,
        '--icon=Icon(Icons.compare_arrows, color: Colors.white),', // Optional icon
        '--app-name=Central Bridge',
      ]);
    } catch (e) {
      print("❌ Error handling file transfer: $e");
      _sendFileAck(
        channel,
        message['filename'] ?? 'unknown',
        'error',
        'Server error: $e',
      );
      await Process.run('notify-send', [
        "Error handling file transfer",
        message['filename'],
        '--icon=dialog-information', // Optional icon
        '--app-name=Central Bridge',
      ]);
    }
  }

  void _sendFileAck(
    IOWebSocketChannel channel,
    String filename,
    String status,
    String message,
  ) {
    try {
      final ack = jsonEncode({
        'channel': 'file_ack',
        'filename': filename,
        'status': status,
        'message': message,
        'timestamp': DateTime.now().toIso8601String(),
      });

      channel.sink.add(ack);
      print("📤 Sent file acknowledgment: $filename -> $status");
    } catch (e) {
      print("❌ Error sending file acknowledgment: $e");
    }
  }

  Future<Map<String, String>> getSystemInfo() async {
    // OS
    final osRelease = await Process.run('cat', ['/etc/os-release']);
    final osLines = osRelease.stdout.toString().split('\n');

    final name = osLines.firstWhere(
      (line) => line.startsWith('NAME='),
      orElse: () => 'NAME=Unknown',
    );
    final version = osLines.firstWhere(
      (line) => line.startsWith('VERSION_ID='),
      orElse: () => 'VERSION_ID=Unknown',
    );

    // Clean quotes
    final osName = name.split('=').last.replaceAll('"', '');
    final osVersion = version.split('=').last.replaceAll('"', '');
    final os = "$osName $osVersion";

    // CPU usage
    final cpuResult = await Process.run('sh', ['-c', "top -bn1 | grep '%Cpu'"]);
    final cpuLine = cpuResult.stdout.toString().trim();

    final cpuut = cpuLine
        .split(',')
        .firstWhere((part) => part.contains('us'), orElse: () => '0.0%')
        .replaceAll(RegExp(r'[^0-9.]'), '');
    final cpu = "$cpuut %";

    // RAM usage
    final result = await Process.run('free', ['-b']);
    final lines = result.stdout.toString().split('\n');
    final memLine = lines.firstWhere((line) => line.startsWith('Mem:'));
    final parts = memLine.trim().split(RegExp(r'\s+'));

    final total = int.parse(parts[1]);
    final used = int.parse(parts[2]);

    final percentUsed = (used / total) * 100;
    final ram = "${percentUsed.toStringAsFixed(1)}%";

    // Battery
    String battery = 'N/A';
    try {
      final batteryResult = await Process.run('sh', [
        '-c',
        "upower -i \$(upower -e | grep BAT) | grep percentage | awk '{print \$2}'",
      ]);
      if (batteryResult.stdout.toString().trim().isNotEmpty) {
        battery = batteryResult.stdout.toString().trim();
      }
    } catch (e) {
      // Battery info not available
    }

    return {'os': os, 'cpu': cpu, 'ram': ram, 'battery': battery};
  }

  void _sendMessage() {
    if (_messageController.text.isNotEmpty && _clientChannel != null) {
      final message = {
        'text': _messageController.text,
        'sender': 'Linux',
        'timestamp': DateTime.now().toIso8601String(),
      };

      _clientChannel!.sink.add(jsonEncode(message));

      setState(() {
        _messages.add({
          'text': _messageController.text,
          'sender': 'Linux',
          'timestamp': DateTime.now(),
        });
      });

      _messageController.clear();
    }
  }

  String _generateFingerprint(String deviceName) {
    final id = "$deviceName";
    final bytes = utf8.encode(id);
    return sha256.convert(bytes).toString();
  }

  String _getQRData() {
    final deviceName = Platform.localHostname;
    final fingerprint = _generateFingerprint(deviceName);
    return jsonEncode({
      'ip': _serverAddress,
      'port': _serverPort,
      'protocol': 'ws',
      'devicename': deviceName,
      'fingerprint': fingerprint,
    });
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  String _formatFileSize(int sizeKB) {
    if (sizeKB < 1024) {
      return '${sizeKB}KB';
    } else {
      return '${(sizeKB / 1024).toStringAsFixed(1)}MB';
    }
  }

  @override
  Widget build(BuildContext context) {
    return _connectionStatus != "Connected"
        ? Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                // Left side - QR Code
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Center(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              children: [
                                Text(
                                  'Scan to Connect',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 22,
                                  ),
                                ),
                                SizedBox(height: 20),
                                if (_isServerRunning)
                                  Container(
                                    padding: EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: QrImageView(
                                      data: _getQRData(),
                                      version: QrVersions.auto,
                                      size: 400.0,
                                    ),
                                  ),
                                SizedBox(height: 20),
                                Text('Server: $_serverAddress:$_serverPort'),
                                Text('Status: $_connectionStatus'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        )
        // Dasboard page---------------------------------------------------------------------------------------------
        : DashboardPage();
  }

  @override
  void dispose() {
    _server?.close();
    _clientChannel?.sink.close();
    _messageController.dispose();
    _mdns.stop();
    super.dispose();
  }
}
