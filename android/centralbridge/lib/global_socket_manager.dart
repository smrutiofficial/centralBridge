import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Global Socket Manager - Singleton Pattern
class GlobalSocketManager {
  static final GlobalSocketManager _instance = GlobalSocketManager._internal();
  factory GlobalSocketManager() => _instance;
  GlobalSocketManager._internal();

  WebSocketChannel? _channel;
  late StreamController<Map<String, dynamic>> _messageController;
  late StreamController<String> _connectionController;

  String _connectionStatus = "Disconnected";
  Map<String, dynamic> _deviceInfo = {};
  String _lastMessage = "";
  String? _serverUrl;
  bool _isConnected = false;
  Timer? _reconnectTimer;

  // Getters
  bool get isConnected => _isConnected;
  String get connectionStatus => _connectionStatus;
  Map<String, dynamic> get deviceInfo => _deviceInfo;
  String get lastMessage => _lastMessage;

  // Streams for different purposes
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream.asBroadcastStream();
  Stream<String> get connectionStream => _connectionController.stream.asBroadcastStream();

  // Initialize the socket manager
  void initialize() {
    _messageController = StreamController<Map<String, dynamic>>.broadcast();
    _connectionController = StreamController<String>.broadcast();
  }

  // Connect to server
  Future<void> connect(String serverUrl, Map<String, dynamic> deviceInfo) async {
    _serverUrl = serverUrl;
    _deviceInfo = Map<String, dynamic>.from(deviceInfo);
    await _connectToServer();
  }

  // Internal connection method
  Future<void> _connectToServer() async {
    if (_serverUrl == null) return;

    try {
      _channel?.sink.close();
      _channel = IOWebSocketChannel.connect(_serverUrl!);

      _updateConnectionStatus("Connecting...");

      // Listen to messages
      _channel!.stream.listen(
        _handleMessage,
        onDone: _handleDisconnection,
        onError: _handleError,
        cancelOnError: false,
      );

      // Send fingerprint after connection
      await _sendFingerprint();

    } catch (e) {
      print("🔥 Connection error: $e");
      _handleError(e);
    }
  }

  // Handle incoming messages
  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      print("📨 Received: $data");

      // Update device info and connection status
      if (data['text'] == '[verified]' && data['device_info'] != null) {
        _deviceInfo = Map<String, dynamic>.from(data['device_info']);
        _updateConnectionStatus("Connected");
        _updateLastMessage('System info received.');
        _isConnected = true;
      }
      // System info update
      else if (data['channel'] == 'system_info' && data['device_info'] != null) {
        _deviceInfo = Map<String, dynamic>.from(data['device_info']);
        _updateLastMessage('System info updated.');
      }
      // Other messages
      else {
        _updateLastMessage(data['text'] ?? 'Unknown message');
      }

      // Broadcast message to all listeners
      _messageController.add(data);

    } catch (e) {
      print("🔥 Message parsing error: $e");
    }
  }

  // Handle disconnection
  void _handleDisconnection() {
    _isConnected = false;
    _updateConnectionStatus("Disconnected");
    _scheduleReconnection();
  }

  // Handle errors
  void _handleError(dynamic error) {
    print("🔥 WebSocket error: $error");
    _isConnected = false;
    _updateConnectionStatus("Connection Error");
    _scheduleReconnection();
  }

  // Schedule reconnection
  void _scheduleReconnection() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: 3), () {
      print("🔄 Attempting to reconnect...");
      _connectToServer();
    });
  }

  // Send fingerprint for authentication
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
          sendMessage(msg);
          return;
        }
      }
    } catch (e) {
      print("🔥 Error sending fingerprint: $e");
    }
  }

  // Send message through WebSocket
  void sendMessage(Map<String, dynamic> message) {
    if (_channel != null && _isConnected) {
      try {
        _channel!.sink.add(jsonEncode(message));
        print("📤 Sent: $message");
      } catch (e) {
        print("🔥 Error sending message: $e");
      }
    } else {
      print("⚠️ Cannot send message: Socket not connected");
    }
  }

  // Send message to specific channel
  void sendToChannel(String channel, Map<String, dynamic> data) {
    final message = {
      'channel': channel,
      'sender': 'Android',
      'timestamp': DateTime.now().toIso8601String(),
      ...data,
    };
    sendMessage(message);
  }

  // Update connection status
  void _updateConnectionStatus(String status) {
    _connectionStatus = status;
    _connectionController.add(status);
  }

  // Update last message
  void _updateLastMessage(String message) {
    _lastMessage = message;
  }

  // Disconnect
  void disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _isConnected = false;
    _updateConnectionStatus("Disconnected");
  }

  // Dispose resources
  void dispose() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _messageController.close();
    _connectionController.close();
  }
}

// Mixin for easy access to global socket in widgets
mixin GlobalSocketMixin<T extends StatefulWidget> on State<T> {
  late GlobalSocketManager socketManager;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  StreamSubscription<String>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    socketManager = GlobalSocketManager();
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    // Listen to messages
    _messageSubscription = socketManager.messageStream.listen(
      onSocketMessage,
      onError: onSocketError,
    );

    // Listen to connection status
    _connectionSubscription = socketManager.connectionStream.listen(
      onConnectionStatusChanged,
      onError: onSocketError,
    );
  }

  // Override these methods in your widgets
  void onSocketMessage(Map<String, dynamic> message) {
    // Handle incoming messages
  }

  void onConnectionStatusChanged(String status) {
    // Handle connection status changes
  }

  void onSocketError(dynamic error) {
    print("🔥 Socket error in ${widget.runtimeType}: $error");
  }

  // Helper method to send messages
  void sendSocketMessage(Map<String, dynamic> message) {
    socketManager.sendMessage(message);
  }

  // Helper method to send to specific channel
  void sendToSocketChannel(String channel, Map<String, dynamic> data) {
    socketManager.sendToChannel(channel, data);
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}