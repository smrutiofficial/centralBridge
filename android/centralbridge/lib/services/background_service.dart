// pubspec.yaml dependencies to add:
/*
dependencies:
  flutter_background_service: ^5.0.5
  flutter_local_notifications: ^17.0.0
  permission_handler: ^11.0.1
  wakelock_plus: ^1.1.4
  flutter_foreground_task: ^6.0.0
  workmanager: ^0.5.2
*/

// lib/services/background_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:multicast_dns/multicast_dns.dart';

class BackgroundService {
  static const String _portName = 'background_service_port';
  static const String _notificationChannelId = 'centralbridge_service';
  static const String _notificationChannelName = 'Central Bridge Service';

  static FlutterLocalNotificationsPlugin? _notificationsPlugin;
  static WebSocketChannel? _channel;
  static Timer? _discoveryTimer;
  static Timer? _connectionTimer;
  static bool _isConnected = false;
  static String? _currentServerUrl;
  static Map<String, dynamic>? _deviceInfo;

  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    // Initialize notifications
    _notificationsPlugin = FlutterLocalNotificationsPlugin();

    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
    InitializationSettings(android: initializationSettingsAndroid);

    await _notificationsPlugin!.initialize(initializationSettings);

    // Create notification channel
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _notificationChannelId,
      _notificationChannelName,
      description: 'Central Bridge background service',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    await _notificationsPlugin!
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Configure background service
    await service.configure(
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'Central Bridge',
        initialNotificationContent: 'Connecting to devices...',
        foregroundServiceNotificationId: 888,
        autoStartOnBoot: true,
      ),
    );
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    // Initialize shared preferences
    final prefs = await SharedPreferences.getInstance();

    // Set up IPC with main app
    final receivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(receivePort.sendPort, _portName);

    receivePort.listen((message) {
      if (message is Map<String, dynamic>) {
        _handleMessageFromApp(message);
      }
    });

    // Start device discovery and connection management
    _startDeviceDiscovery();
    _startConnectionMonitoring();

    // Listen for service stop
    service.on('stopService').listen((event) {
      _cleanup();
      service.stopSelf();
    });

    // Update notification periodically
    Timer.periodic(Duration(seconds: 30), (timer) async {
      await _updateNotification();
    });
  }

  static void _startDeviceDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(Duration(seconds: 60), (timer) async {
      if (!_isConnected) {
        await _discoverAndConnect();
      }
    });

    // Initial discovery
    _discoverAndConnect();
  }

  static void _startConnectionMonitoring() {
    _connectionTimer?.cancel();
    _connectionTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
      if (_isConnected && _channel != null) {
        try {
          // Send ping to check connection
          _channel!.sink.add(jsonEncode({
            'type': 'ping',
            'timestamp': DateTime.now().toIso8601String(),
          }));
        } catch (e) {
          print('Connection lost: $e');
          _handleDisconnection();
        }
      }
    });
  }

  static Future<void> _discoverAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final trustedDevices = prefs.getStringList('trusted_devices') ?? [];

    if (trustedDevices.isEmpty) return;

    // Try mDNS discovery first
    final mdnsConnected = await _tryMdnsDiscovery(trustedDevices);
    if (mdnsConnected) return;

    // Fallback to saved devices
    await _connectToSavedDevices(trustedDevices);
  }

  static Future<bool> _tryMdnsDiscovery(List<String> trustedDevices) async {
    final mdns = MDnsClient();
    try {
      await mdns.start();

      await for (final ptr in mdns.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('_chatbridge._tcp.local'))) {
        await for (final srv in mdns.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName))) {
          final ipRecords = await mdns
              .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target))
              .toList();

          final txtRecords = await mdns
              .lookup<TxtResourceRecord>(
              ResourceRecordQuery.text(ptr.domainName))
              .toList();

          if (ipRecords.isNotEmpty) {
            final ip = ipRecords.first.address.address;
            final port = srv.port;

            String? fingerprint;
            for (final txt in txtRecords) {
              final entries = txt.text.split(';');
              for (final entry in entries) {
                if (entry.trim().startsWith('fingerprint=')) {
                  fingerprint = entry.trim().split('=')[1];
                }
              }
            }

            // Check if this device is trusted
            final match = trustedDevices.firstWhere(
                  (deviceJson) {
                final device = jsonDecode(deviceJson);
                return device['fingerprint'] == fingerprint;
              },
              orElse: () => '',
            );

            if (match.isNotEmpty) {
              final device = jsonDecode(match);
              final url = 'ws://$ip:$port';

              final connected = await _connectToDevice(url, device);
              if (connected) {
                mdns.stop();
                return true;
              }
            }
          }
        }
      }
    } catch (e) {
      print("mDNS error: $e");
    } finally {
      mdns.stop();
    }
    return false;
  }

  static Future<void> _connectToSavedDevices(List<String> trustedDevices) async {
    for (final deviceJson in trustedDevices) {
      try {
        final device = jsonDecode(deviceJson);
        final ip = device['ip'];
        final port = device['port'];
        final url = 'ws://$ip:$port';

        final connected = await _connectToDevice(url, device);
        if (connected) break;
      } catch (e) {
        print("Failed to connect to saved device: $e");
      }
    }
  }

  static Future<bool> _connectToDevice(String url, Map<String, dynamic> device) async {
    try {
      _channel = IOWebSocketChannel.connect(url);
      _currentServerUrl = url;
      _deviceInfo = device;

      // Send fingerprint for auto-verification
      final fingerprint = device['fingerprint'];
      if (fingerprint != null) {
        _channel!.sink.add(jsonEncode({
          'fingerprint': fingerprint,
          'text': '[auto-verified]',
          'sender': 'Android',
          'timestamp': DateTime.now().toIso8601String(),
        }));
      }

      // Listen to messages
      _channel!.stream.listen(
            (message) {
          _handleWebSocketMessage(message);
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

      _isConnected = true;
      await _updateNotification();
      _notifyApp({'type': 'connected', 'url': url, 'device': device});

      return true;
    } catch (e) {
      print("Connection error: $e");
      return false;
    }
  }

  static void _handleWebSocketMessage(dynamic message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;

      // Handle system info updates
      if (data['text'] == '[verified]' && data['device_info'] != null) {
        _deviceInfo = Map<String, dynamic>.from(data['device_info']);
        _notifyApp({'type': 'device_info_updated', 'data': _deviceInfo});
      }

      // Handle incoming notifications/messages
      if (data['channel'] == 'notification' || data['type'] == 'notification') {
        _showNotification(
          data['title'] ?? 'Central Bridge',
          data['message'] ?? data['text'] ?? 'New message',
        );
      }

      // Forward all messages to main app
      _notifyApp({'type': 'websocket_message', 'data': data});

    } catch (e) {
      print('Error handling WebSocket message: $e');
    }
  }

  static void _handleDisconnection() {
    _isConnected = false;
    _channel = null;
    _currentServerUrl = null;
    _updateNotification();
    _notifyApp({'type': 'disconnected'});

    // Attempt reconnection after delay
    Timer(Duration(seconds: 5), () {
      _discoverAndConnect();
    });
  }

  static void _handleMessageFromApp(Map<String, dynamic> message) {
    final type = message['type'];

    switch (type) {
      case 'send_websocket_message':
        if (_isConnected && _channel != null) {
          _channel!.sink.add(jsonEncode(message['data']));
        }
        break;
      case 'reconnect':
        _discoverAndConnect();
        break;
      case 'get_status':
        _notifyApp({
          'type': 'status_response',
          'connected': _isConnected,
          'url': _currentServerUrl,
          'device': _deviceInfo,
        });
        break;
    }
  }

  static void _notifyApp(Map<String, dynamic> message) {
    final sendPort = IsolateNameServer.lookupPortByName(_portName);
    sendPort?.send(message);
  }

  static Future<void> _updateNotification() async {
    if (_notificationsPlugin == null) return;

    final title = _isConnected ? 'Central Bridge - Connected' : 'Central Bridge - Disconnected';
    final body = _isConnected && _deviceInfo != null
        ? 'Connected to ${_deviceInfo!['device_name'] ?? 'Unknown'}'
        : 'Searching for devices...';

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: 'Central Bridge background service',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin!.show(888, title, body, details);
  }

  static Future<void> _showNotification(String title, String body) async {
    if (_notificationsPlugin == null) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'centralbridge_messages',
      'Central Bridge Messages',
      channelDescription: 'Notifications from connected devices',
      importance: Importance.high,
      priority: Priority.high,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin!.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  static void _cleanup() {
    _discoveryTimer?.cancel();
    _connectionTimer?.cancel();
    _channel?.sink.close();
    IsolateNameServer.removePortNameMapping(_portName);
  }

  // Public methods for app interaction
  static Future<void> startService() async {
    final service = FlutterBackgroundService();
    await service.startService();
  }

  static Future<void> stopService() async {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  static void sendMessage(Map<String, dynamic> message) {
    final sendPort = IsolateNameServer.lookupPortByName(_portName);
    sendPort?.send({'type': 'send_websocket_message', 'data': message});
  }

  static void requestReconnect() {
    final sendPort = IsolateNameServer.lookupPortByName(_portName);
    sendPort?.send({'type': 'reconnect'});
  }

  static void requestStatus() {
    final sendPort = IsolateNameServer.lookupPortByName(_portName);
    sendPort?.send({'type': 'get_status'});
  }
}