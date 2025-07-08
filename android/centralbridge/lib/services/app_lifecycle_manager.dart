// lib/services/app_lifecycle_manager.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:centralbridge/services/service_manager.dart';

class AppLifecycleManager extends WidgetsBindingObserver {
  static AppLifecycleManager? _instance;
  static AppLifecycleManager get instance => _instance ??= AppLifecycleManager._internal();
  AppLifecycleManager._internal();

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    WidgetsBinding.instance.addObserver(this);

    // Keep screen on when app is active
    await WakelockPlus.enable();

    // Initialize service manager
    await ServiceManager.instance.initialize();

    _isInitialized = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    switch (state) {
      case AppLifecycleState.resumed:
        print('App resumed - requesting status update');
        ServiceManager.instance.requestStatus();
        break;
      case AppLifecycleState.paused:
        print('App paused - background service continues');
        break;
      case AppLifecycleState.detached:
        print('App detached - background service continues');
        break;
      case AppLifecycleState.inactive:
        print('App inactive');
        break;
      case AppLifecycleState.hidden:
        print('App hidden (Flutter 3.22+)');
        break;
    }
  }


  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    ServiceManager.instance.dispose();
    _isInitialized = false;
  }
}