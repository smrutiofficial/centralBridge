import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

class WebSocketManager {
  static WebSocketManager? _instance;
  static WebSocketManager get instance => _instance ??= WebSocketManager._internal();

  WebSocketManager._internal();

  WebSocketChannel? _channel;
  StreamController<Map<String, dynamic>>? _messageController;
  StreamController<String>? _connectionController;

  Stream<Map<String, dynamic>>? _messageStream;
  Stream<String>? _connectionStream;

  bool _isConnected = false;
  String? _serverUrl;
  Timer? _reconnectTimer;

  // Getters for broadcast streams
  Stream<Map<String, dynamic>> get messageStream {
    _messageStream ??= _messageController?.stream.asBroadcastStream();
    return _messageStream!;
  }

  Stream<String> get connectionStream {
    _connectionStream ??= _connectionController?.stream.asBroadcastStream();
    return _connectionStream!;
  }

  bool get isConnected => _isConnected;

  // Initialize connection
  Future<void> connect(String serverUrl) async {
    _serverUrl = serverUrl;

    // Initialize controllers if not already done
    _messageController ??= StreamController<Map<String, dynamic>>.broadcast();
    _connectionController ??= StreamController<String>.broadcast();

    try {
      _channel = IOWebSocketChannel.connect(serverUrl);
      _isConnected = true;

      // Notify connection status
      _connectionController!.add('Connected');

      // Listen to incoming messages
      _channel!.stream.listen(
            (message) {
          try {
            final data = jsonDecode(message) as Map<String, dynamic>;
            _messageController!.add(data);
          } catch (e) {
            print('Error parsing message: $e');
          }
        },
        onError: (error) {
          print('WebSocket error: $error');
          _handleDisconnection();
        },
        onDone: () {
          print('WebSocket connection closed');
          _handleDisconnection();
        },
      );

    } catch (e) {
      print('Connection error: $e');
      _handleDisconnection();
    }
  }

  // Handle disconnection and attempt reconnection
  void _handleDisconnection() {
    _isConnected = false;
    _connectionController?.add('Disconnected');

    // Attempt to reconnect after 2 seconds
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: 2), () {
      if (_serverUrl != null) {
        print('Attempting to reconnect...');
        _connectionController?.add('Reconnecting...');
        connect(_serverUrl!);
      }
    });
  }

  // Send message
  void sendMessage(Map<String, dynamic> message) {
    if (_isConnected && _channel != null) {
      try {
        _channel!.sink.add(jsonEncode(message));
      } catch (e) {
        print('Error sending message: $e');
      }
    } else {
      print('Cannot send message: not connected');
    }
  }

  // Listen to specific message channels
  Stream<Map<String, dynamic>> listenToChannel(String channelName) {
    return messageStream.where((data) => data['channel'] == channelName);
  }

  // Listen to file transfer acknowledgments - FIXED
  Stream<Map<String, dynamic>> listenToFileTransferAcks() {
    return messageStream.where((data) =>
    data['channel'] == 'file_ack' ||  // This matches what the server sends
        data['channel'] == 'file_transfer_ack' ||
        data['type'] == 'file_ack' ||
        data['message_type'] == 'file_received'
    );
  }

  // Listen to system info updates
  Stream<Map<String, dynamic>> listenToSystemInfo() {
    return messageStream.where((data) =>
    data['channel'] == 'system_info' ||
        data['text'] == '[verified]'
    );
  }

  // Dispose resources
  void dispose() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _messageController?.close();
    _connectionController?.close();
    _messageController = null;
    _connectionController = null;
    _messageStream = null;
    _connectionStream = null;
    _isConnected = false;
  }
}