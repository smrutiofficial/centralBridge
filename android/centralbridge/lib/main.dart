import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'DashboardScreen.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android Chat Client',
      theme: ThemeData(primarySwatch: Colors.green),
      home: DeviceDiscoveryScreen(),
    );
  }
}

// Save device info locally
Future<void> saveDevice(Map<String, dynamic> device) async {
  final prefs = await SharedPreferences.getInstance();
  final allDevices = prefs.getStringList('trusted_devices') ?? [];
  final jsonDevice = jsonEncode(device);
  if (!allDevices.contains(jsonDevice)) {
    allDevices.add(jsonDevice);
    await prefs.setStringList('trusted_devices', allDevices);
  }
}

// Get saved devices
Future<List<Map<String, dynamic>>> getTrustedDevices() async {
  final prefs = await SharedPreferences.getInstance();
  final allDevices = prefs.getStringList('trusted_devices') ?? [];
  return allDevices.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
}

// Remove saved device by fingerprint
Future<void> removeDevice(String fingerprint) async {
  final prefs = await SharedPreferences.getInstance();
  final allDevices = prefs.getStringList('trusted_devices') ?? [];
  allDevices.removeWhere((jsonString) {
    final device = jsonDecode(jsonString);
    return device['fingerprint'] == fingerprint;
  });
  await prefs.setStringList('trusted_devices', allDevices);
}

// QR Scanner screen
class QRScannerScreen extends StatefulWidget {
  @override
  _QRScannerScreenState createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool _isScanned = false;

  void _onDetect(BarcodeCapture capture) {
    if (_isScanned) return;
    final barcode = capture.barcodes.first;
    final qrData = barcode.rawValue;

    if (qrData != null) {
      try {
        final serverInfo = jsonDecode(qrData);
        final ip = serverInfo['ip'];
        final port = serverInfo['port'];
        final fingerprint = serverInfo['fingerprint'];
        final deviceName = serverInfo['devicename'];
        final url = 'ws://$ip:$port';

        saveDevice({
          'ip': ip,
          'port': port,
          'fingerprint': fingerprint,
          'device_name': deviceName,
        });

        _isScanned = true;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => DashboardScreen(
              serverUrl: url,
              deviceInfo: {
                'device_name': deviceName,
                'ip': ip,
                'os': 'Unknown',
                'cpu': '-',
                'ram': '-',
                'battery': '-',
              },
            ),
          ),
        );
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid QR code')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Scan QR Code')),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: EdgeInsets.only(top: 24),
              padding: EdgeInsets.all(8),
              color: Colors.black54,
              child: Text(
                'Scan QR from Linux device',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// mDNS device discovery screen
class DeviceDiscoveryScreen extends StatefulWidget {
  @override
  _DeviceDiscoveryScreenState createState() => _DeviceDiscoveryScreenState();
}

class _DeviceDiscoveryScreenState extends State<DeviceDiscoveryScreen> {
  bool _stopLoop = false;

  @override
  void initState() {
    super.initState();
    _startDiscoveryLoop();
  }

  void _startDiscoveryLoop() async {
    while (!_stopLoop) {
      final connected = await _discoverAndConnect();
      if (connected) break;
      print("⛔ mDNS failed. Trying saved device...");
      final fallbackConnected = await _connectToLastSavedDevice();
      if (fallbackConnected) break;
      await Future.delayed(Duration(seconds: 5));
    }
  }

  Future<bool> _discoverAndConnect() async {
    final mdns = MDnsClient();
    try {
      await mdns.start();
      final trustedDevices = await getTrustedDevices();

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

          final match = trustedDevices.firstWhere(
                (d) => d['fingerprint'] == fingerprint,
            orElse: () => {},
          );

          if (match.isNotEmpty) {
            _stopLoop = true;
            mdns.stop();
            final url = 'ws://$ip:$port';
            final deviceName = match['device_name'] ?? 'Unknown';
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => DashboardScreen(
                  serverUrl: url,
                  deviceInfo: {
                    'device_name': deviceName,
                    'ip': ip,
                    'os': 'Unknown',
                    'cpu': '-',
                    'ram': '-',
                    'battery': '-',
                  },
                ),
              ),
            );
            return true;
          }
        }
      }
    } catch (e) {
      print("❌ mDNS error: $e");
    } finally {
      mdns.stop();
    }
    return false;
  }

  Future<bool> _connectToLastSavedDevice() async {
    try {
      final trustedDevices = await getTrustedDevices();
      if (trustedDevices.isNotEmpty) {
        final last = trustedDevices.last;
        final ip = last['ip'];
        final port = last['port'];
        final deviceName = last['device_name'];
        final url = 'ws://$ip:$port';

        _stopLoop = true;
        print("🔁 Fallback to $url");

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => DashboardScreen(
              serverUrl: url,
              deviceInfo: {
                'device_name': deviceName,
                'ip': ip,
                'os': 'Unknown',
                'cpu': '-',
                'ram': '-',
                'battery': '-',
              },
            ),
          ),
        );
        return true;
      }
    } catch (e) {
      print("⚠️ Fallback connection failed: $e");
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Looking for Devices'),
        actions: [
          IconButton(
            icon: Icon(Icons.qr_code),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => QRScannerScreen()),
              );
            },
          ),
        ],
      ),
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
