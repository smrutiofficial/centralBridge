import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'services/app_lifecycle_manager.dart';
import 'services/service_manager.dart';
import 'services/permission_manager.dart';
import 'DashboardScreen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize app lifecycle manager
  await AppLifecycleManager.instance.initialize();

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Central Bridge',
      theme: ThemeData(
        primarySwatch: Colors.green,
        brightness: Brightness.light,
      ),
      debugShowCheckedModeBanner: false,
      home: SplashScreen(),
    );
  }
}

// Splash screen that handles permissions and initialization
class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _statusMessage = 'Initializing...';

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      // Step 1: Request permissions
      setState(() {
        _statusMessage = 'Requesting permissions...';
      });

      final permissionsGranted = await PermissionManager.requestAllPermissions(context);
      if (!permissionsGranted) {
        setState(() {
          _statusMessage = 'Some permissions denied. App may not work properly.';
        });
        await Future.delayed(Duration(seconds: 2));
      }

      // Step 2: Check for existing trusted devices
      setState(() {
        _statusMessage = 'Checking for saved devices...';
      });

      final trustedDevices = await getTrustedDevices();

      if (trustedDevices.isNotEmpty) {
        // Try to connect to saved devices
        setState(() {
          _statusMessage = 'Connecting to saved devices...';
        });

        // Start background service
        await ServiceManager.instance.initialize();

        // Listen for connection status from background service
        _listenForBackgroundServiceConnection();

        // Try direct connection first
        final connected = await _tryDirectConnection(trustedDevices);

        if (!connected) {
          // If direct connection fails, start mDNS discovery
          await Future.delayed(Duration(seconds: 2));
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => DeviceDiscoveryScreen()),
            );
          }
        }
      } else {
        // No saved devices, go to discovery
        setState(() {
          _statusMessage = 'No saved devices found. Starting discovery...';
        });

        await Future.delayed(Duration(seconds: 1));

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => DeviceDiscoveryScreen()),
          );
        }
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Initialization failed: $e';
      });

      // Still proceed to discovery after error
      await Future.delayed(Duration(seconds: 2));
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => DeviceDiscoveryScreen()),
        );
      }
    }
  }

  Future<bool> _tryDirectConnection(List<Map<String, dynamic>> trustedDevices) async {
    for (final device in trustedDevices.reversed) {
      try {
        final ip = device['ip'];
        final port = device['port'];
        final deviceName = device['device_name'];
        final url = 'ws://$ip:$port';

        setState(() {
          _statusMessage = 'Connecting to $deviceName...';
        });

        // Test connection by trying to establish WebSocket
        try {
          final testChannel = IOWebSocketChannel.connect(url);

          // Wait for connection or timeout
          await Future.any([
            testChannel.ready,
            Future.delayed(Duration(seconds: 3)),
          ]);

          testChannel.sink.close();

          // Connection successful, navigate to dashboard
          if (mounted) {
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
          print('Connection test failed for $deviceName: $e');
        }
      } catch (e) {
        print('Direct connection to ${device['device_name']} failed: $e');
      }
    }
    return false;
  }

  void _listenForBackgroundServiceConnection() {
    ServiceManager.instance.messageStream.listen((message) {
      if (message['type'] == 'connected' && mounted) {
        final deviceInfo = message['device'] as Map<String, dynamic>;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => DashboardScreen(
              serverUrl: message['url'],
              deviceInfo: {
                'device_name': deviceInfo['device_name'] ?? 'Unknown',
                'ip': deviceInfo['ip'] ?? 'Unknown',
                'os': 'Unknown',
                'cpu': '-',
                'ram': '-',
                'battery': '-',
              },
            ),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.devices,
              size: 80,
              color: Colors.green,
            ),
            SizedBox(height: 20),
            Text(
              'Central Bridge',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 40),
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
            ),
            SizedBox(height: 20),
            Text(
              _statusMessage,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
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

        final deviceInfo = {
          'ip': ip,
          'port': port,
          'fingerprint': fingerprint,
          'device_name': deviceName,
        };

        // Save device
        saveDevice(deviceInfo);

        _isScanned = true;

        // Navigate directly to dashboard
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

      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid QR code'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Scan QR Code'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: EdgeInsets.only(top: 24),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Scan QR code from your Linux device',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Device discovery screen with improved auto-connection
class DeviceDiscoveryScreen extends StatefulWidget {
  @override
  _DeviceDiscoveryScreenState createState() => _DeviceDiscoveryScreenState();
}

class _DeviceDiscoveryScreenState extends State<DeviceDiscoveryScreen> {
  String _statusMessage = 'Searching for devices...';
  bool _isConnecting = false;
  List<Map<String, dynamic>> _trustedDevices = [];
  bool _stopDiscovery = false;

  @override
  void initState() {
    super.initState();
    _initializeDiscovery();
  }

  Future<void> _initializeDiscovery() async {
    // Load trusted devices
    _trustedDevices = await getTrustedDevices();

    // Try background service first
    await ServiceManager.instance.initialize();
    _listenToBackgroundService();

    // Start discovery loop
    _startDiscoveryLoop();
  }

  void _listenToBackgroundService() {
    ServiceManager.instance.messageStream.listen((message) {
      if (!mounted || _stopDiscovery) return;

      switch (message['type']) {
        case 'connected':
          _stopDiscovery = true;
          final deviceInfo = message['device'] as Map<String, dynamic>;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => DashboardScreen(
                serverUrl: message['url'],
                deviceInfo: {
                  'device_name': deviceInfo['device_name'] ?? 'Unknown',
                  'ip': deviceInfo['ip'] ?? 'Unknown',
                  'os': 'Unknown',
                  'cpu': '-',
                  'ram': '-',
                  'battery': '-',
                },
              ),
            ),
          );
          break;

        case 'disconnected':
          setState(() {
            _statusMessage = 'Connection lost. Searching...';
            _isConnecting = false;
          });
          break;

        case 'status_response':
          final connected = message['connected'] as bool;
          // if (connected) {
          //   final deviceInfo = message['device'] as Map<String, dynamic>?;
            // if (deviceInfo != null) {
              // _stopDiscovery = true;
              // Navigator.pushReplacement(
                // context,
                // MaterialPageRoute(
                //   builder: (context) => DashboardScreen(
                //     serverUrl: message['url'],
                //     deviceInfo: {
                //       'device_name': deviceInfo['device_name'] ?? 'Unknown',
                //       'ip': deviceInfo['ip'] ?? 'Unknown',
                //       'os': 'Unknown',
                //       'cpu': '-',
                //       'ram': '-',
                //       'battery': '-',
                //     },
                //   ),
                // ),
              // );
            // }
          // }
          // break;
      }
    });
  }

  void _startDiscoveryLoop() async {
    while (!_stopDiscovery && mounted) {
      setState(() {
        _statusMessage = 'Discovering devices...';
        _isConnecting = true;
      });

      // Request status from background service
      ServiceManager.instance.requestStatus();

      // Try mDNS discovery
      final connected = await _discoverViaMDNS();
      if (connected) break;

      // Try direct connection to saved devices
      final fallbackConnected = await _connectToSavedDevices();
      if (fallbackConnected) break;

      // Wait before next iteration
      await Future.delayed(Duration(seconds: 5));
    }
  }

  Future<bool> _discoverViaMDNS() async {
    if (_trustedDevices.isEmpty) {
      setState(() {
        _statusMessage = 'No trusted devices found. Please scan QR code.';
      });
      return false;
    }

    final mdns = MDnsClient();
    bool found = false;

    try {
      await mdns.start();

      setState(() {
        _statusMessage = 'Discovering devices on network...';
      });

      await for (final ptr in mdns.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('_chatbridge._tcp.local'))) {
        if (found || _stopDiscovery) break;

        await for (final srv in mdns.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName))) {
          if (found || _stopDiscovery) break;

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
                  break;
                }
              }
            }

            // Check if this device is trusted
            final match = _trustedDevices.firstWhere(
                  (d) => d['fingerprint'] == fingerprint,
              orElse: () => {},
            );

            if (match.isNotEmpty) {
              found = true;
              _stopDiscovery = true;

              setState(() {
                _statusMessage = 'Found ${match['device_name']}! Connecting...';
              });

              // Update device info with current IP
              final updatedDevice = Map<String, dynamic>.from(match);
              updatedDevice['ip'] = ip;
              updatedDevice['port'] = port;
              await saveDevice(updatedDevice);

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
              break;
            }
          }
        }
      }
    } catch (e) {
      print("mDNS discovery error: $e");
    } finally {
      mdns.stop();
    }

    return found;
  }

  Future<bool> _connectToSavedDevices() async {
    if (_trustedDevices.isEmpty) return false;

    for (final device in _trustedDevices.reversed) {
      if (_stopDiscovery) break;

      try {
        final ip = device['ip'];
        final port = device['port'];
        final deviceName = device['device_name'];
        final url = 'ws://$ip:$port';

        setState(() {
          _statusMessage = 'Trying to connect to $deviceName...';
        });

        print("🔁 Trying direct connection to $url");

        // Test connection
        try {
          final testChannel = IOWebSocketChannel.connect(url);

          await Future.any([
            testChannel.ready,
            Future.delayed(Duration(seconds: 3)),
          ]);

          testChannel.sink.close();

          _stopDiscovery = true;

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
        } catch (e) {
          print('Connection to ${device['device_name']} failed: $e');
        }
      } catch (e) {
        print('Connection to ${device['device_name']} failed: $e');
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Central Bridge'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(Icons.qr_code_scanner),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => QRScannerScreen()),
              );
            },
            tooltip: 'Scan QR Code',
          ),
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              _stopDiscovery = false;
              _startDiscoveryLoop();
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 80,
              color: Colors.green,
            ),
            SizedBox(height: 20),
            if (_isConnecting)
              CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
              ),
            SizedBox(height: 20),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _statusMessage,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(height: 40),
            if (_trustedDevices.isNotEmpty) ...[
              Text(
                'Trusted Devices:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 10),
              ..._trustedDevices.map((device) => Card(
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ListTile(
                  leading: Icon(Icons.computer, color: Colors.green),
                  title: Text(device['device_name'] ?? 'Unknown'),
                  subtitle: Text('${device['ip']}:${device['port']}'),
                  trailing: IconButton(
                    icon: Icon(Icons.delete, color: Colors.red),
                    onPressed: () async {
                      await removeDevice(device['fingerprint']);
                      setState(() {
                        _trustedDevices.removeWhere(
                                (d) => d['fingerprint'] == device['fingerprint']
                        );
                      });
                    },
                  ),
                ),
              )).toList(),
            ],
            SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => QRScannerScreen()),
                );
              },
              icon: Icon(Icons.qr_code_scanner),
              label: Text('Scan QR Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopDiscovery = true;
    super.dispose();
  }
}