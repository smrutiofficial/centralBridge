// lib/services/service_manager.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'background_service.dart';

class ServiceManager {
  static ServiceManager? _instance;
  static ServiceManager get instance => _instance ??= ServiceManager._internal();
  ServiceManager._internal();

  StreamController<Map<String, dynamic>>? _messageController;
  ReceivePort? _receivePort;
  bool _isListening = false;

  Stream<Map<String, dynamic>>? _messageStream;

  Stream<Map<String, dynamic>> get messageStream {
    _messageStream ??= _messageController?.stream.asBroadcastStream();
    return _messageStream!;
  }

  Future<void> initialize() async {
    if (_isListening) return;

    _messageController = StreamController<Map<String, dynamic>>.broadcast();
    _receivePort = ReceivePort();

    IsolateNameServer.registerPortWithName(
      _receivePort!.sendPort,
      'main_app_port',
    );

    _receivePort!.listen((message) {
      if (message is Map<String, dynamic>) {
        _messageController?.add(message);
      }
    });

    _isListening = true;

    // Initialize and start background service
    await BackgroundService.initializeService();
    await BackgroundService.startService();

    // Request initial status
    Timer(Duration(seconds: 2), () {
      BackgroundService.requestStatus();
    });
  }

  void sendMessageToDevice(Map<String, dynamic> message) {
    BackgroundService.sendMessage(message);
  }

  void requestReconnect() {
    BackgroundService.requestReconnect();
  }

  void requestStatus() {
    BackgroundService.requestStatus();
  }

  Future<void> stopService() async {
    await BackgroundService.stopService();
  }

  void dispose() {
    _messageController?.close();
    _receivePort?.close();
    IsolateNameServer.removePortNameMapping('main_app_port');
    _isListening = false;
  }
}

