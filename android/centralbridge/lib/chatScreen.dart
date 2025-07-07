import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ChatScreen extends StatefulWidget {
  final String serverUrl;
  ChatScreen({required this.serverUrl});

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late WebSocketChannel channel;
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];

  @override
  void initState() {
    super.initState();
    _connectToServer();
  }

  // void _connectToServer() {
  //   channel = IOWebSocketChannel.connect(widget.serverUrl);
  //
  //   channel.stream.listen((message) {
  //     final data = jsonDecode(message);
  //     setState(() {
  //       _messages.add({
  //         'text': data['text'],
  //         'sender': data['sender'],
  //         'timestamp': DateTime.now(),
  //       });
  //     });
  //   }, onDone: _reconnect, onError: (e) => _reconnect());
  //
  //   // ✅ Send fingerprint AFTER 1st frame so socket is fully ready
  //   WidgetsBinding.instance.addPostFrameCallback((_) {
  //     _sendFingerprint(); // ⬅️ call without delay here
  //   });
  // }
  void _connectToServer() {
    channel = IOWebSocketChannel.connect(widget.serverUrl);

    channel.stream.listen((message) {
      final data = jsonDecode(message);

      // ✅ Check for real device info from Linux
      if (data['text'] == '[verified]' && data.containsKey('device_info')) {
        final deviceInfo = Map<String, dynamic>.from(data['device_info']);
        print("✅ Real system info from Linux: $deviceInfo");

        // OPTIONAL: If you want to update the UI with this info:
        setState(() {
          _messages.add({
            'text': '🔍 Connected to ${deviceInfo['device_name']}',
            'sender': 'System',
            'timestamp': DateTime.now(),
          });

          _messages.add({
            'text': '🖥 OS: ${deviceInfo['os']}\n⚙️ CPU: ${deviceInfo['cpu']}\n💾 RAM: ${deviceInfo['ram']}\n🔋 Battery: ${deviceInfo['battery']}',
            'sender': 'System',
            'timestamp': DateTime.now(),
          });
        });
        return;
      }

      // ✅ Normal message handling
      setState(() {
        _messages.add({
          'text': data['text'],
          'sender': data['sender'],
          'timestamp': DateTime.now(),
        });
      });
    }, onDone: _reconnect, onError: (e) => _reconnect());

    // ✅ Send fingerprint AFTER WebSocket is connected
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendFingerprint();
    });
  }


  void _reconnect() async {
    await Future.delayed(Duration(seconds: 5));
    _connectToServer();
  }

  Future<void> _sendFingerprint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trusted = prefs.getStringList('trusted_devices') ?? [];

      for (final item in trusted) {
        final device = jsonDecode(item);
        final fingerprint = device['fingerprint'];

        if (fingerprint != null && fingerprint.isNotEmpty) {
          final msg = {
            'fingerprint': fingerprint,
            'text': '[auto-verified]',
            'sender': 'Android',
            'timestamp': DateTime.now().toIso8601String(),
          };
          print("✅ Sending fingerprint: $fingerprint");
          channel.sink.add(jsonEncode(msg));
          return;
        }
      }

      print("❌ No trusted fingerprint found to send");
    } catch (e) {
      print("🔥 Error sending fingerprint: $e");
    }
  }


  void _sendMessage() {
    if (_controller.text.trim().isEmpty) return;
    final msg = {
      'text': _controller.text,
      'sender': 'Android',
      'timestamp': DateTime.now().toIso8601String(),
    };
    channel.sink.add(jsonEncode(msg));
    setState(() {
      _messages.add({
        'text': _controller.text,
        'sender': 'Android',
        'timestamp': DateTime.now(),
      });
    });
    _controller.clear();
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    channel.sink.close();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Connected to Server')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.all(8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isFromAndroid = message['sender'] == 'Android';
                return Align(
                  alignment: isFromAndroid
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: EdgeInsets.symmetric(vertical: 4),
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isFromAndroid
                          ? Colors.green.shade100
                          : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(message['text'], style: TextStyle(fontSize: 16)),
                        SizedBox(height: 4),
                        Text(
                          '${message['sender']} • ${_formatTime(message['timestamp'])}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Type your message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _sendMessage,
                  child: Icon(Icons.send),
                  style: ElevatedButton.styleFrom(
                    shape: CircleBorder(),
                    padding: EdgeInsets.all(12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
