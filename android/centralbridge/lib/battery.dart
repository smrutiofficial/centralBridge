import 'dart:async';
import 'package:flutter/material.dart';
import 'package:battery_plus/battery_plus.dart';

class BatteryLevelWidget extends StatefulWidget {
  @override
  _BatteryLevelWidgetState createState() => _BatteryLevelWidgetState();
}

class _BatteryLevelWidgetState extends State<BatteryLevelWidget> {
  final Battery _battery = Battery();
  int _batteryLevel = -1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _getBatteryLevel(); // Get initial value
    _startBatteryMonitoring(); // Start polling
  }

  void _startBatteryMonitoring() {
    _timer = Timer.periodic(Duration(seconds: 10), (timer) {
      _getBatteryLevel();
    });
  }

  Future<void> _getBatteryLevel() async {
    final level = await _battery.batteryLevel;
    if (mounted) {
      setState(() {
        _batteryLevel = level;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel(); // Cancel the timer when widget is removed
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _batteryLevel == -1 ? 'Loading...' : '$_batteryLevel%',
    );
  }
}
