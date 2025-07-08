// lib/services/permission_manager.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

class PermissionManager {
  static Future<bool> requestAllPermissions(BuildContext context) async {
    final permissions = <Permission>[
      Permission.notification,
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.photos,
      Permission.manageExternalStorage,
    ];

    // Add Android-specific permissions
    if (Platform.isAndroid) {
      permissions.addAll([
        Permission.systemAlertWindow,
        Permission.ignoreBatteryOptimizations,
        Permission.scheduleExactAlarm,
      ]);
    }

    bool allGranted = true;

    for (final permission in permissions) {
      final status = await permission.request();
      if (!status.isGranted) {
        allGranted = false;
        print('Permission ${permission.toString()} not granted');
      }
    }

    // Request battery optimization exemption
    if (Platform.isAndroid) {
      await _requestBatteryOptimizationExemption(context);
    }

    return allGranted;
  }

  static Future<void> _requestBatteryOptimizationExemption(BuildContext context) async {
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;

    if (!batteryStatus.isGranted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Battery Optimization'),
          content: Text(
            'To keep Central Bridge running in the background, please disable battery optimization for this app.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await Permission.ignoreBatteryOptimizations.request();
              },
              child: Text('Settings'),
            ),
          ],
        ),
      );
    }
  }

  static Future<bool> checkPermissions() async {
    final permissions = <Permission>[
      Permission.notification,
      Permission.camera,
      Permission.microphone,
      Permission.storage,
    ];

    for (final permission in permissions) {
      final status = await permission.status;
      if (!status.isGranted) {
        return false;
      }
    }

    return true;
  }
}

