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
      // process.stderr.transform(utf8.decoder).listen((data) {
      //   print('[mDNS ERROR] $data');
      // });
    } catch (e) {
      print("Error starting avahi-publish-service: $e");
    }
  }

  void _handleWebSocketConnection(WebSocket webSocket) async {
    final channel = IOWebSocketChannel(webSocket);
    String? storedFingerprint;
    bool paired = false;
    Timer? infoTimer; // 🕒 Timer for auto system info sending

    try {
      final prefs = await SharedPreferences.getInstance();
      storedFingerprint = prefs.getString('paired_fingerprint');
    } catch (_) {}

    channel.stream.listen(
      (data) async {
        final message = jsonDecode(data);

        // Handle pairing first
        if (message.containsKey('fingerprint')) {
          final receivedFingerprint = message['fingerprint'];
          print("📥 Received fingerprint: $receivedFingerprint");

          if (storedFingerprint == null ||
              storedFingerprint == receivedFingerprint) {
            if (storedFingerprint == null && receivedFingerprint != null) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('paired_fingerprint', receivedFingerprint);
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
            webSocket.close(); // reject untrusted client
            return;
          }
        }

        // ✅ Now, after pairing: Handle file transfer (any message with channel)
        if (message['channel'] == 'file_transfer') {
          final filename = message['filename'];
          final base64Data = message['data'];
          final bytes = base64Decode(base64Data);

          final homeDir = Platform.environment['HOME'] ?? '/home/username';
          final saveDir = Directory('$homeDir/Downloads');

          if (!await saveDir.exists()) {
            await saveDir.create(recursive: true);
          }

          final file = File('${saveDir.path}/$filename');
          await file.writeAsBytes(bytes);
          print('📁 File received and saved: ${file.path}');

          // ✅ Send acknowledgment
          final ack = jsonEncode({
            'channel': 'file_ack',
            'filename': filename,
            'status': 'saved',
          });
          channel.sink.add(ack);
          return;
        }
      },
      onDone: () {
        infoTimer?.cancel();
        print('WebSocket disconnected');
      },
      onError: (error) {
        infoTimer?.cancel();
        print('WebSocket error: $error');
      },
    );
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
    // print('OS: $osName $osVersion'); // Ubuntu 24.04
    print(os);
    // CPU usage (top -bn1)
    // final cpuResult = await Process.run('sh', ['-c', "top -bn1 | grep '%Cpu'"]);
    // final cpu = cpuResult.stdout.toString().split('\n').first.trim();

    final cpuResult = await Process.run('sh', ['-c', "top -bn1 | grep '%Cpu'"]);
    final cpuLine = cpuResult.stdout.toString().trim();

    final cpuut = cpuLine
        .split(',')
        .firstWhere((part) => part.contains('us'))
        .replaceAll(RegExp(r'[^0-9.]'), ''); // Removes non-numeric characters
    final cpu = "$cpuut %";
    // print('CPU Usage: $cpuUsage%');

    print(cpu);
    // RAM usage (free -h)
    // final ramResult = await Process.run('sh', ['-c', "free -h | grep Mem"]);
    // final ramParts = ramResult.stdout.toString().split(RegExp(r'\s+'));
    // final ram = '${ramParts[2]}/${ramParts[1]}';

    final result = await Process.run('free', ['-b']);
    final lines = result.stdout.toString().split('\n');
    final memLine = lines.firstWhere((line) => line.startsWith('Mem:'));
    final parts = memLine.trim().split(RegExp(r'\s+'));

    final total = int.parse(parts[1]);
    final used = int.parse(parts[2]);

    final percentUsed = (used / total) * 100;
    final ram = "${percentUsed.toStringAsFixed(1)}%";
    // print('RAM: ${percentUsed.toStringAsFixed(1)}%');
    print(ram);
    // Battery (upower)
    String battery = 'N/A';
    final batteryResult = await Process.run('sh', [
      '-c',
      "upower -i \$(upower -e | grep BAT) | grep percentage | awk '{print \$2}'",
    ]);
    if (batteryResult.stdout.toString().trim().isNotEmpty) {
      battery = batteryResult.stdout.toString().trim();
    }

    return {'os': os, 'cpu': cpu, 'ram': ram, 'battery': battery};
  }

  // ------------------------------------
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
    final id = "$deviceName"; // Optionally add MAC
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // appBar: AppBar(
      //   title: Text('Linux Chat Server'),
      //   backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      // ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Text(
                            'Scan QR Code to Connect',
                            style: Theme.of(context).textTheme.headlineSmall,
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
                                size: 200.0,
                              ),
                            ),
                          SizedBox(height: 20),
                          Text('Server: $_serverAddress:$_serverPort'),
                          Text('Status: $_connectionStatus'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            //chat app for testing websocket is working or not
            // Expanded(
            //   flex: 2,
            //   child: Column(
            //     children: [
            //       Expanded(
            //         child: Card(
            //           child: ListView.builder(
            //             padding: EdgeInsets.all(8),
            //             itemCount: _messages.length,
            //             itemBuilder: (context, index) {
            //               final message = _messages[index];
            //               final isFromLinux = message['sender'] == 'Linux';

            //               return Align(
            //                 alignment:
            //                     isFromLinux
            //                         ? Alignment.centerRight
            //                         : Alignment.centerLeft,
            //                 child: Container(
            //                   margin: EdgeInsets.symmetric(vertical: 4),
            //                   padding: EdgeInsets.all(12),
            //                   decoration: BoxDecoration(
            //                     color:
            //                         isFromLinux
            //                             ? Colors.blue.shade100
            //                             : Colors.grey.shade200,
            //                     borderRadius: BorderRadius.circular(12),
            //                   ),
            //                   child: Column(
            //                     crossAxisAlignment: CrossAxisAlignment.start,
            //                     children: [
            //                       Text(
            //                         message['text'],
            //                         style: TextStyle(fontSize: 16),
            //                       ),
            //                       SizedBox(height: 4),
            //                       Text(
            //                         '${message['sender']} • ${_formatTime(message['timestamp'])}',
            //                         style: TextStyle(
            //                           fontSize: 12,
            //                           color: Colors.grey.shade600,
            //                         ),
            //                       ),
            //                     ],
            //                   ),
            //                 ),
            //               );
            //             },
            //           ),
            //         ),
            //       ),
            //       Card(
            //         child: Padding(
            //           padding: const EdgeInsets.all(8.0),
            //           child: Row(
            //             children: [
            //               Expanded(
            //                 child: TextField(
            //                   controller: _messageController,
            //                   decoration: InputDecoration(
            //                     hintText: 'Type your message...',
            //                     border: OutlineInputBorder(
            //                       borderRadius: BorderRadius.circular(20),
            //                     ),
            //                     contentPadding: EdgeInsets.symmetric(
            //                       horizontal: 16,
            //                       vertical: 8,
            //                     ),
            //                   ),
            //                   onSubmitted: (_) => _sendMessage(),
            //                 ),
            //               ),
            //               SizedBox(width: 8),
            //               ElevatedButton(
            //                 onPressed: _sendMessage,
            //                 child: Icon(Icons.send),
            //                 style: ElevatedButton.styleFrom(
            //                   shape: CircleBorder(),
            //                   padding: EdgeInsets.all(12),
            //                 ),
            //               ),
            //             ],
            //           ),
            //         ),
            //       ),
            //     ],
            //   ),
            // ),
          ],
        ),
      ),
    );
  }

  // String _formatTime(DateTime time) {
  //   return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  // }

  @override
  void dispose() {
    _server?.close();
    _clientChannel?.sink.close();
    _messageController.dispose();
    _mdns.stop();
    super.dispose();
  }
}
