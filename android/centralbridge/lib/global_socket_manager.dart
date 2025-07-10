import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
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
  Timer? _pingTimer;

  // Message queue for handling high-frequency messages
  final List<Map<String, dynamic>> _messageQueue = [];
  bool _isProcessingQueue = false;

  // Chunk acknowledgment tracking
  final Map<String, Completer<bool>> _chunkAcknowledgments = {};
  final Map<String, Timer> _chunkTimeouts = {};

  // Performance monitoring
  int _messagesSent = 0;
  int _messagesReceived = 0;
  DateTime? _lastMessageTime;

  // Configuration
  static const int MAX_QUEUE_SIZE = 1000;
  static const int CHUNK_TIMEOUT_SECONDS = 30;
  static const int PING_INTERVAL_SECONDS = 30;
  static const int RECONNECT_DELAY_SECONDS = 2;

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

  // Performance stats
  Map<String, dynamic> get performanceStats => {
    'messagesSent': _messagesSent,
    'messagesReceived': _messagesReceived,
    'queueSize': _messageQueue.length,
    'pendingAcks': _chunkAcknowledgments.length,
    'lastMessageTime': _lastMessageTime?.toIso8601String(),
  };

  // Initialize connection with enhanced error handling
  Future<void> connect(String serverUrl) async {
    _serverUrl = serverUrl;

    // Initialize controllers if not already done
    _messageController ??= StreamController<Map<String, dynamic>>.broadcast();
    _connectionController ??= StreamController<String>.broadcast();

    try {
      // Create WebSocket connection with custom headers
      _channel = IOWebSocketChannel.connect(
        serverUrl,
        headers: {
          'User-Agent': 'CentralBridge-Mobile/1.0',
          'Connection': 'Upgrade',
          'Upgrade': 'websocket',
        },
      );

      // Wait for connection to be established
      await _channel!.ready.timeout(
        Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Connection timeout'),
      );

      _isConnected = true;
      _connectionController!.add('Connected');

      // Start periodic ping to keep connection alive
      _startPingTimer();

      // Listen to incoming messages with enhanced error handling
      _channel!.stream.listen(
            (message) async {
          try {
            _messagesReceived++;
            _lastMessageTime = DateTime.now();

            if (message is String) {
              final data = jsonDecode(message) as Map<String, dynamic>;
              await _handleIncomingMessage(data);
            } else if (message is List<int>) {
              // Handle binary messages if needed
              await _handleBinaryMessage(message);
            }
          } catch (e) {
            print('Error parsing message: $e');
            // Continue listening even if one message fails
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

      // Start processing message queue
      _startQueueProcessor();

    } catch (e) {
      print('Connection error: $e');
      _handleDisconnection();
      throw e;
    }
  }

  // Enhanced message handling with acknowledgment tracking
  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {
    // Handle chunk acknowledgments
    if (data['type'] == 'chunk_ack' || data['channel'] == 'file_ack') {
      final chunkId = data['chunk_id'] as String?;
      if (chunkId != null) {
        _handleChunkAcknowledgment(chunkId, data['status'] == 'success');
      }
    }

    // Add to message stream
    _messageController!.add(data);
  }

  // Handle binary messages (for future use)
  Future<void> _handleBinaryMessage(List<int> message) async {
    // Can be used for optimized binary file transfer
    print('Received binary message: ${message.length} bytes');
  }

  // Handle chunk acknowledgment with timeout management
  void _handleChunkAcknowledgment(String chunkId, bool success) {
    final completer = _chunkAcknowledgments.remove(chunkId);
    final timer = _chunkTimeouts.remove(chunkId);

    timer?.cancel();

    if (completer != null && !completer.isCompleted) {
      completer.complete(success);
    }
  }

  // Start ping timer to keep connection alive
  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(Duration(seconds: PING_INTERVAL_SECONDS), (timer) {
      if (_isConnected) {
        _sendPing();
      }
    });
  }

  // Send ping message
  void _sendPing() {
    try {
      final pingMessage = {
        'type': 'ping',
        'timestamp': DateTime.now().toIso8601String(),
      };
      _channel?.sink.add(jsonEncode(pingMessage));
    } catch (e) {
      print('Error sending ping: $e');
    }
  }

  // Start queue processor for high-frequency messages
  void _startQueueProcessor() {
    if (_isProcessingQueue) return;

    _isProcessingQueue = true;
    Timer.periodic(Duration(milliseconds: 10), (timer) {
      if (!_isConnected) {
        timer.cancel();
        _isProcessingQueue = false;
        return;
      }

      _processMessageQueue();
    });
  }

  // Process message queue efficiently
  void _processMessageQueue() {
    if (_messageQueue.isEmpty) return;

    try {
      // Process up to 10 messages at once
      final messagesToProcess = _messageQueue.take(10).toList();
      _messageQueue.removeRange(0, messagesToProcess.length);

      for (final message in messagesToProcess) {
        _channel?.sink.add(jsonEncode(message));
        _messagesSent++;
      }
    } catch (e) {
      print('Error processing message queue: $e');
    }
  }

  // Enhanced message sending with queue management
  void sendMessage(Map<String, dynamic> message) {
    if (!_isConnected) {
      print('Cannot send message: not connected');
      return;
    }

    try {
      // Add timestamp to all messages
      message['timestamp'] = DateTime.now().toIso8601String();

      // Check if queue is full
      if (_messageQueue.length >= MAX_QUEUE_SIZE) {
        print('Message queue full, dropping oldest messages');
        _messageQueue.removeRange(0, _messageQueue.length - MAX_QUEUE_SIZE + 1);
      }

      _messageQueue.add(message);
    } catch (e) {
      print('Error queuing message: $e');
    }
  }

  // Send message with acknowledgment tracking
  Future<bool> sendMessageWithAck(Map<String, dynamic> message, {Duration? timeout}) async {
    if (!_isConnected) {
      print('Cannot send message: not connected');
      return false;
    }

    final chunkId = message['chunk_id'] as String?;
    if (chunkId == null) {
      sendMessage(message);
      return true;
    }

    try {
      // Create completer for acknowledgment
      final completer = Completer<bool>();
      _chunkAcknowledgments[chunkId] = completer;

      // Set timeout for acknowledgment
      final timeoutDuration = timeout ?? Duration(seconds: CHUNK_TIMEOUT_SECONDS);
      _chunkTimeouts[chunkId] = Timer(timeoutDuration, () {
        _chunkAcknowledgments.remove(chunkId);
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      });

      // Send message
      sendMessage(message);

      // Wait for acknowledgment
      return await completer.future;
    } catch (e) {
      print('Error sending message with ack: $e');
      _chunkAcknowledgments.remove(chunkId);
      _chunkTimeouts.remove(chunkId)?.cancel();
      return false;
    }
  }

  // Optimized chunk sending with flow control
  Future<bool> sendChunkWithFlowControl(Map<String, dynamic> chunkMessage) async {
    // Check if we have too many pending acknowledgments
    if (_chunkAcknowledgments.length > 50) {
      // Wait for some acknowledgments to come back
      await Future.delayed(Duration(milliseconds: 100));
    }

    return await sendMessageWithAck(chunkMessage);
  }

  // Handle disconnection and attempt reconnection
  void _handleDisconnection() {
    _isConnected = false;
    _connectionController?.add('Disconnected');

    // Clean up timers
    _pingTimer?.cancel();
    _pingTimer = null;

    // Complete all pending acknowledgments with failure
    for (final completer in _chunkAcknowledgments.values) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    _chunkAcknowledgments.clear();

    for (final timer in _chunkTimeouts.values) {
      timer.cancel();
    }
    _chunkTimeouts.clear();

    // Clear message queue
    _messageQueue.clear();
    _isProcessingQueue = false;

    // Attempt to reconnect
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: RECONNECT_DELAY_SECONDS), () {
      if (_serverUrl != null) {
        print('Attempting to reconnect...');
        _connectionController?.add('Reconnecting...');
        connect(_serverUrl!).catchError((error) {
          print('Reconnection failed: $error');
          // Try again after delay
          _handleDisconnection();
        });
      }
    });
  }

  // Listen to specific message channels
  Stream<Map<String, dynamic>> listenToChannel(String channelName) {
    return messageStream.where((data) => data['channel'] == channelName);
  }

  // Listen to file transfer acknowledgments with enhanced filtering
  Stream<Map<String, dynamic>> listenToFileTransferAcks() {
    return messageStream.where((data) =>
    data['channel'] == 'file_ack' ||
        data['channel'] == 'file_transfer_ack' ||
        data['type'] == 'file_ack' ||
        data['type'] == 'chunk_ack' ||
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

  // Enhanced progress tracking for file transfers
  Stream<Map<String, dynamic>> listenToFileProgress() {
    return messageStream.where((data) =>
    data['type'] == 'file_progress' ||
        data['type'] == 'chunk_progress' ||
        data['channel'] == 'file_progress'
    );
  }

  // Get connection quality metrics
  Map<String, dynamic> getConnectionQuality() {
    final now = DateTime.now();
    final timeSinceLastMessage = _lastMessageTime != null
        ? now.difference(_lastMessageTime!).inSeconds
        : 0;

    String quality = 'good';
    if (timeSinceLastMessage > 30) {
      quality = 'poor';
    } else if (timeSinceLastMessage > 10) {
      quality = 'fair';
    }

    return {
      'quality': quality,
      'timeSinceLastMessage': timeSinceLastMessage,
      'messagesSent': _messagesSent,
      'messagesReceived': _messagesReceived,
      'queueSize': _messageQueue.length,
      'pendingAcks': _chunkAcknowledgments.length,
    };
  }

  // Dispose resources
  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();

    // Complete all pending acknowledgments
    for (final completer in _chunkAcknowledgments.values) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    _chunkAcknowledgments.clear();

    for (final timer in _chunkTimeouts.values) {
      timer.cancel();
    }
    _chunkTimeouts.clear();

    _channel?.sink.close();
    _messageController?.close();
    _connectionController?.close();
    _messageController = null;
    _connectionController = null;
    _messageStream = null;
    _connectionStream = null;
    _messageQueue.clear();
    _isConnected = false;
    _isProcessingQueue = false;
  }
}