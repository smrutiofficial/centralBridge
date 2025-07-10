import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:collection'; // Added for Queue
import 'package:network_info_plus/network_info_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:sinergia/screens/dashboard.dart';
import 'package:path/path.dart' as path;

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Linux Chat Server',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: ChatServerScreen(),
      debugShowCheckedModeBanner: true,
    );
  }
}

class ChatServerScreen extends StatefulWidget {
  @override
  _ChatServerScreenState createState() => _ChatServerScreenState();
}

class _ChatServerScreenState extends State<ChatServerScreen> {
  HttpServer? _server;
  WebSocketChannel? _clientChannel;
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _receivedFiles = [];
  List<FileReceiveStatus> _fileReceiveStatus = [];
  TextEditingController _messageController = TextEditingController();
  String _serverAddress = '';
  int _serverPort = 4074;
  bool _isServerRunning = false;
  String _connectionStatus = 'Not connected';
  final MDnsClient _mdns = MDnsClient();
  // =====================================================================================================
  // ===================================File transfer management==========================================
  // =====================================================================================================
  Map<String, ChunkedFileReceiver> _activeReceives = {};
  Timer? _cleanupTimer;

  @override
  void initState() {
    super.initState();
    _startServer();
    _startCleanupTimer();
  }

  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(Duration(minutes: 2), (timer) {
      _cleanupStaleTransfers();
    });
  }

  void _cleanupStaleTransfers() {
    final now = DateTime.now();
    final staleTransfers =
        _activeReceives.entries.where((entry) {
          final timeSinceLastChunk = now.difference(entry.value.lastChunkTime);
          return timeSinceLastChunk.inMinutes > 5; // 5 minutes timeout
        }).toList();

    for (final entry in staleTransfers) {
      print('🧹 Cleaning up stale transfer: ${entry.key}');
      _cleanupFailedTransfer(entry.key, 'Transfer timeout');
    }
  }
  // =====================================================================================================
  // ===========================Start the server with port======192.234.1.67:3466=========================
  // =====================================================================================================

  Future<void> _startServer() async {
    try {
      final networkInfo = NetworkInfo();
      final wifiIP = await networkInfo.getWifiIP();
      _serverAddress = wifiIP ?? '127.0.0.1';

      _server = await HttpServer.bind(_serverAddress, _serverPort);
      print('Server started on $_serverAddress:$_serverPort');

      setState(() {
        _isServerRunning = true;
      });

      // Broadcast using mDNS
      await _iniMDNS();
      _broadcastMDNS(Platform.localHostname, _serverPort);

      _server!.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then((WebSocket webSocket) {
            print('Client connected');
            _handleWebSocketConnection(webSocket);
          });
        }
      });
    } catch (e) {
      print('Error starting server: $e');
    }
  }
  // =====================================================================================================
  // =============================Starts an mDNS (Multicast DNS) responder================================
  // =====================================================================================================

  Future<void> _iniMDNS() async {
    try {
      await _mdns.start();
    } catch (e) {
      print('Error starting mDNS: $e');
    }
  }
  // =====================================================================================================
  /* Announces your device on the local network using the avahi-publish-service Linux command.
     - Broadcasts a service named deviceName on the port port, with service type _chatbridge._tcp.
     - Includes a custom fingerprint as service metadata.
     - Starts the Avahi process and listens to its output (for debug/logging).
     - If something goes wrong, it prints the error. */
  // =====================================================================================================

  Future<void> _broadcastMDNS(String deviceName, int port) async {
    final serviceType = '_chatbridge._tcp';
    final serviceName = deviceName;
    final fingerprint = _generateFingerprint(deviceName);

    final args = [
      '-s',
      serviceName,
      serviceType,
      port.toString(),
      'fingerprint=$fingerprint',
    ];

    try {
      final process = await Process.start('avahi-publish-service', args);
      print(
        "Started mDNS broadcast using avahi: $serviceName.$serviceType:$port",
      );

      process.stdout.transform(utf8.decoder).listen((data) {
        print('[mDNS] $data');
      });
    } catch (e) {
      print("Error starting avahi-publish-service: $e");
    }
  }
  // =====================================================================================================
  /*   Handles a new WebSocket connection from a client (e.g., Android device).
  
   - Wraps the raw WebSocket in an IOWebSocketChannel for easier stream handling.
   - Attempts to retrieve a previously stored paired fingerprint from SharedPreferences.
   - Listens for incoming messages and responds based on the message type.
  
   Main responsibilities:
   1. **Pairing Verification**: Checks if the client's fingerprint matches the stored one.
      - If not previously paired, stores the new fingerprint.
      - Marks the client as paired and updates connection status.
   2. **System Info Broadcasting**:
      - Once paired, sends a verification message to the client with device/system info.
      - Starts a timer to send system info updates every 1 second.
   3. **File Transfer Handling**:
      - If a file transfer message is received (`channel == 'file_transfer'`),
        calls `_handleChunkedFileTransfer`.
   4. **Message Handling**:
      - If a regular text message is received (no `channel`), adds it to `_messages`.
   5. **Connection Lifecycle Management**:
      - On disconnect (`onDone`), cleans up timers and file transfers, updates status.
      - On error (`onError`), does the same and prints the error.
  
   Notes:
   - Uses `setState()` to update UI reactively (status/messages).
   - All communication is JSON-encoded.
   - Ensures only paired clients can proceed beyond the fingerprint check.
   - Sends device info such as hostname and IP to the client. */

  // =====================================================================================================

  void _handleWebSocketConnection(WebSocket webSocket) async {
    final channel = IOWebSocketChannel(webSocket);
    String? storedFingerprint;
    bool paired = false;
    Timer? infoTimer;

    try {
      final prefs = await SharedPreferences.getInstance();
      storedFingerprint = prefs.getString('paired_fingerprint');
    } catch (_) {}

    channel.stream.listen(
      (data) async {
        try {
          final message = jsonDecode(data);
          print("📥 Received message: ${message['type'] ?? 'unknown type'}");

          // Handle pairing first
          if (message.containsKey('fingerprint')) {
            final receivedFingerprint = message['fingerprint'];
            print("📥 Received fingerprint: $receivedFingerprint");

            if (storedFingerprint == null ||
                storedFingerprint == receivedFingerprint) {
              if (storedFingerprint == null && receivedFingerprint != null) {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(
                  'paired_fingerprint',
                  receivedFingerprint,
                );
                print("✅ Fingerprint stored: $receivedFingerprint");
              }

              paired = true;
              _clientChannel = channel;
              setState(() {
                _connectionStatus = 'Connected';
              });

              final systemInfo = await getSystemInfo();
              final verificationMessage = jsonEncode({
                'text': '[verified]',
                'status': 'connected',
                'sender': 'Linux',
                'timestamp': DateTime.now().toIso8601String(),
                'device_info': {
                  'device_name': Platform.localHostname,
                  'ip': _serverAddress,
                  ...systemInfo,
                },
              });
              channel.sink.add(verificationMessage);

              infoTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
                final systemInfo = await getSystemInfo();
                final updateMessage = jsonEncode({
                  'channel': 'system_info',
                  'timestamp': DateTime.now().toIso8601String(),
                  'device_info': {
                    'device_name': Platform.localHostname,
                    'ip': _serverAddress,
                    ...systemInfo,
                  },
                });
                channel.sink.add(updateMessage);
              });

              return;
            } else {
              print("⚠️ Received unknown fingerprint: $receivedFingerprint");
              webSocket.close();
              return;
            }
          }

          // Handle file transfer from Android client
          if (message['channel'] == 'file_transfer' && paired) {
            await _handleChunkedFileTransfer(message, channel);
            return;
          }

          // Handle regular messages
          if (message.containsKey('text') && !message.containsKey('channel')) {
            setState(() {
              _messages.add({
                'text': message['text'],
                'sender': message['sender'] ?? 'Unknown',
                'timestamp': DateTime.now(),
              });
            });
          }
        } catch (e) {
          print("❌ Error parsing message: $e");
          print("Raw data: ${data.toString().substring(0, 100)}...");
        }
      },
      onDone: () {
        infoTimer?.cancel();
        _cleanupAllActiveTransfers();
        setState(() {
          _connectionStatus = 'Disconnected';
          _clientChannel = null;
        });
        print('WebSocket disconnected');
      },
      onError: (error) {
        infoTimer?.cancel();
        _cleanupAllActiveTransfers();
        setState(() {
          _connectionStatus = 'Error: $error';
          _clientChannel = null;
        });
        print('WebSocket error: $error');
      },
    );
  }

  Future<void> _handleChunkedFileTransfer(
    Map<String, dynamic> message,
    IOWebSocketChannel channel,
  ) async {
    try {
      final type = message['type'];
      final filename = message['filename'];

      if (filename == null) {
        print("❌ Missing filename in file transfer message");
        return;
      }

      switch (type) {
        case 'metadata':
          await _handleFileMetadata(message, channel);
          break;
        case 'chunk':
          await _handleFileChunk(message, channel);
          break;
        default:
          print("❌ Unknown file transfer type: $type");
      }
    } catch (e) {
      print("❌ Error handling chunked file transfer: $e");
      final filename = message['filename'];
      if (filename != null) {
        _sendFileAck(channel, filename, 'error', 'Server error: $e');
      }
    }
  }
  // =====================================================================================================
  /*
  This function handles incoming file transfer messages that arrive in parts (chunks).
  It's used when a client (like an Android device) is sending a file over WebSocket in pieces.

  Steps:
  - Extracts the `type` and `filename` from the message.
  - If no filename is provided, it stops and logs an error.

  Then, based on the message type:
  - If the type is 'metadata', it handles file info like name, size, etc. using `_handleFileMetadata`.
  - If the type is 'chunk', it processes a part of the file's content using `_handleFileChunk`.
  - If the type is something else, it prints an error.

  If any unexpected error occurs during this process:
  - It logs the error.
  - And sends an error acknowledgment back to the client (if a filename was included).

  This helps in transferring large files safely by breaking them into chunks and processing them step-by-step.
*/
  // =====================================================================================================

  Future<void> _handleFileMetadata(
    Map<String, dynamic> message,
    IOWebSocketChannel channel,
  ) async {
    final filename = message['filename'];
    final fileSize = message['file_size'];
    final fileHash = message['file_hash'];
    final totalChunks = message['total_chunks'];
    final chunkSize = message['chunk_size'];
    final sender = message['sender'] ?? 'Unknown';

    print(
      "📁 Receiving file metadata: $filename (${_formatFileSize(fileSize)}, $totalChunks chunks)",
    );

    try {
      // Determine save directory
      final homeDir = Platform.environment['HOME'] ?? '/home/username';
      final saveDir = Directory('$homeDir/Downloads');
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }

      // Handle filename conflicts
      String finalFilename = filename;
      File targetFile = File(path.join(saveDir.path, finalFilename));
      int counter = 1;

      while (await targetFile.exists()) {
        final extension = path.extension(filename);
        final baseName = path.basenameWithoutExtension(filename);
        finalFilename = '${baseName}_$counter$extension';
        targetFile = File(path.join(saveDir.path, finalFilename));
        counter++;
      }

      // Create chunked file receiver
      final receiver = ChunkedFileReceiver(
        filename: filename,
        finalFilename: finalFilename,
        targetFile: targetFile,
        fileSize: fileSize,
        fileHash: fileHash,
        totalChunks: totalChunks,
        chunkSize: chunkSize,
        sender: sender,
      );

      _activeReceives[filename] = receiver;

      // Add to UI
      setState(() {
        final status = FileReceiveStatus(
          filename: filename,
          finalFilename: finalFilename,
          status: ReceiveStatus.receiving,
          progress: 0.0,
          fileSize: fileSize,
          bytesReceived: 0,
          totalChunks: totalChunks,
          receivedChunks: 0,
          sender: sender,
          startTime: DateTime.now(),
        );
        _fileReceiveStatus.add(status);
      });

      // Send metadata acknowledgment
      _sendFileAck(
        channel,
        filename,
        'metadata_received',
        'Ready to receive chunks',
      );
    } catch (e) {
      print("❌ Error handling file metadata: $e");
      _sendFileAck(channel, filename, 'error', 'Failed to prepare file: $e');
    }
  }
  // =====================================================================================================
  /*
  This function handles **a single chunk of a file** sent from a client (like an Android device)
  during a chunked file transfer over WebSocket.

  Here's what it does step-by-step:

  1. Extracts necessary data from the incoming message:
     - `filename`: the name of the file being transferred.
     - `chunkIndex`: position of this chunk in the full file.
     - `chunkId`: unique ID of the chunk (used for acknowledgment).
     - `data`: the actual file content (Base64 encoded).
     - `chunkSize`: size of this chunk.
     - `isLastChunk`: whether this is the final chunk.

  2. Checks if a receiver (handler) for this file exists in `_activeReceives`.
     - If not, it sends an error acknowledgment back to the client.

  3. If a receiver is found:
     - Decodes the `data` from Base64 format into raw bytes.
     - Writes the decoded chunk to disk or memory using `receiver.writeChunk(...)`.
     - Updates the UI or internal state to reflect current progress.
     - Sends a "success" acknowledgment for this chunk back to the client.

  4. If this is the last chunk and the file is now complete:
     - Finalizes the file (e.g., closes the file, verifies integrity).
     - Optionally notifies the client that the file was fully received.

  5. If an error happens during any of this:
     - It logs the error and sends an error acknowledgment for that specific chunk.

  This function ensures that large files can be safely and reliably transferred
  over the network by processing and acknowledging each piece individually.
*/
  // =====================================================================================================

  Future<void> _handleFileChunk(
    Map<String, dynamic> message,
    IOWebSocketChannel channel,
  ) async {
    final filename = message['filename'];
    final chunkIndex = message['chunk_index'];
    final chunkId = message['chunk_id'];
    final data = message['data'];
    final chunkSize = message['chunk_size'];
    final isLastChunk = message['is_last_chunk'] ?? false;

    final receiver = _activeReceives[filename];
    if (receiver == null) {
      print("❌ No receiver found for file: $filename");
      _sendChunkAck(
        channel,
        filename,
        chunkIndex,
        chunkId,
        'error',
        'No receiver found',
      );
      return;
    }

    try {
      // Decode and write chunk
      final chunkData = base64Decode(data);
      await receiver.writeChunk(chunkIndex, chunkData);

      // Update progress
      _updateReceiveProgress(filename, receiver);

      // Send chunk acknowledgment
      _sendChunkAck(
        channel,
        filename,
        chunkIndex,
        chunkId,
        'success',
        'Chunk received',
      );

      // Check if file is complete
      if (receiver.isComplete()) {
        await _finalizeFileReceive(filename, receiver, channel);
      }
    } catch (e) {
      print("❌ Error processing chunk $chunkIndex for $filename: $e");
      _sendChunkAck(
        channel,
        filename,
        chunkIndex,
        chunkId,
        'error',
        'Failed to process chunk: $e',
      );
    }
  }
  // =====================================================================================================
  /*
  _updateReceiveProgress:
  - Called whenever a new chunk of a file is received.
  - It finds the matching file in `_fileReceiveStatus`.
  - Then updates:
    • how much of the file has been received (`progress`),
    • how many bytes have been received,
    • how many chunks have been received.
  - Uses `setState()` so the UI reflects the updated progress.
*/
  // =====================================================================================================

  void _updateReceiveProgress(String filename, ChunkedFileReceiver receiver) {
    setState(() {
      final statusIndex = _fileReceiveStatus.indexWhere(
        (s) => s.filename == filename,
      );
      if (statusIndex >= 0) {
        _fileReceiveStatus[statusIndex].progress = receiver.getProgress();
        _fileReceiveStatus[statusIndex].bytesReceived =
            receiver.getBytesReceived();
        _fileReceiveStatus[statusIndex].receivedChunks =
            receiver.getReceivedChunks();
      }
    });
  }

  // =====================================================================================================
  /*
  _finalizeFileReceive:
  - Called when all chunks of a file have been received.
  - It verifies that the full file is complete and correct (integrity check).
  - If valid:
    • Updates the UI to show "completed"
    • Adds file info to `_receivedFiles` list (for history/viewing)
    • Removes it from active receiving list
    • Sends final success acknowledgment to the sender
    • Shows a notification with a sound
  - If an error happens, it triggers cleanup and sends an error acknowledgment.
*/
  // =====================================================================================================
  Future<void> _finalizeFileReceive(
    String filename,
    ChunkedFileReceiver receiver,
    IOWebSocketChannel channel,
  ) async {
    try {
      // Verify file integrity
      final isValid = await receiver.verifyFile();
      if (!isValid) {
        throw Exception('File integrity verification failed');
      }

      // Update UI
      setState(() {
        final statusIndex = _fileReceiveStatus.indexWhere(
          (s) => s.filename == filename,
        );
        if (statusIndex >= 0) {
          _fileReceiveStatus[statusIndex].status = ReceiveStatus.completed;
          _fileReceiveStatus[statusIndex].progress = 1.0;

          // Move to completed files
          _receivedFiles.add({
            'filename': receiver.finalFilename,
            'originalFilename': receiver.filename,
            'sender': receiver.sender,
            'timestamp': DateTime.now(),
            'path': receiver.targetFile.path,
            'size': (receiver.fileSize / 1024).round(),
          });

          // Remove from active transfers
          _fileReceiveStatus.removeAt(statusIndex);
        }
      });

      // Cleanup
      _activeReceives.remove(filename);

      // Send final acknowledgment
      _sendFileAck(
        channel,
        filename,
        'success',
        'File received and verified successfully',
      );

      // Notification and sound
      await _showSuccessNotification(receiver.finalFilename);

      print("✅ File received successfully: ${receiver.targetFile.path}");
    } catch (e) {
      print("❌ Error finalizing file receive: $e");
      _cleanupFailedTransfer(filename, 'Finalization failed: $e');
      _sendFileAck(channel, filename, 'error', 'Failed to finalize file: $e');
    }
  }

  // =====================================================================================================
  /*
  _showSuccessNotification:
  - Plays a system sound using `canberra-gtk-play`.
  - Shows a desktop notification using `notify-send`.
  - This is called after a file is received successfully.
*/
  // =====================================================================================================
  Future<void> _showSuccessNotification(String filename) async {
    try {
      await Process.run('canberra-gtk-play', [
        '--id=complete',
        '--volume=1000',
      ]);
      await Process.run('notify-send', [
        'File received successfully',
        filename,
        '--icon=document-save',
        '--app-name=Central Bridge',
      ]);
    } catch (e) {
      print('Error showing notification: $e');
    }
  }
  // =====================================================================================================
  /*
  _cleanupFailedTransfer:
  - Called when a file transfer fails (e.g., error, broken file).
  - Updates the UI status for the file to "error" and stores the error message.
  - Calls `receiver.cleanup()` to delete any temporary/incomplete data.
  - Removes the receiver from active transfers.
*/
  // =====================================================================================================

  void _cleanupFailedTransfer(String filename, String reason) {
    setState(() {
      final statusIndex = _fileReceiveStatus.indexWhere(
        (s) => s.filename == filename,
      );
      if (statusIndex >= 0) {
        _fileReceiveStatus[statusIndex].status = ReceiveStatus.error;
        _fileReceiveStatus[statusIndex].error = reason;
      }
    });

    final receiver = _activeReceives[filename];
    if (receiver != null) {
      receiver.cleanup();
      _activeReceives.remove(filename);
    }
  }
  // =====================================================================================================
  /*
  _cleanupAllActiveTransfers:
  - Called when all transfers should be stopped (e.g., connection lost).
  - Cleans up all active receivers.
  - Updates all receiving files in the UI as "error" with reason "Connection lost".
*/
  // =====================================================================================================

  void _cleanupAllActiveTransfers() {
    for (final receiver in _activeReceives.values) {
      receiver.cleanup();
    }
    _activeReceives.clear();

    setState(() {
      for (int i = 0; i < _fileReceiveStatus.length; i++) {
        if (_fileReceiveStatus[i].status == ReceiveStatus.receiving) {
          _fileReceiveStatus[i].status = ReceiveStatus.error;
          _fileReceiveStatus[i].error = 'Connection lost';
        }
      }
    });
  }

  // =====================================================================================================
  // =====================================================================================================
  void _sendChunkAck(
    IOWebSocketChannel channel,
    String filename,
    int chunkIndex,
    String chunkId,
    String status,
    String message,
  ) {
    try {
      final ack = jsonEncode({
        'channel': 'file_transfer',
        'type': 'chunk_ack',
        'filename': filename,
        'chunk_index': chunkIndex,
        'chunk_id': chunkId,
        'status': status,
        'message': message,
        'timestamp': DateTime.now().toIso8601String(),
      });

      channel.sink.add(ack);
    } catch (e) {
      print("❌ Error sending chunk acknowledgment: $e");
    }
  }

  // =====================================================================================================
  /*
  _sendChunkAck:
  - This function sends an acknowledgment (ack) message for a received file chunk
    back to the sender (like an Android device) over the WebSocket channel.

  Parameters:
    - `channel`: the active WebSocket connection to the sender.
    - `filename`: name of the file being received.
    - `chunkIndex`: index (position) of the chunk just received.
    - `chunkId`: unique ID for the chunk (used by sender to track it).
    - `status`: status string (like 'success' or 'error').
    - `message`: optional human-readable message describing the result.

  What it does:
    - Creates a JSON object with all the relevant chunk info.
    - Adds a timestamp for logging or syncing purposes.
    - Encodes it to a string with `jsonEncode`.
    - Sends it to the client via the WebSocket channel.

  Purpose:
    - Let the sender know whether the chunk was received successfully
      or if there was an error, so it can retry or continue.
*/
  // =====================================================================================================
  void _sendFileAck(
    IOWebSocketChannel channel,
    String filename,
    String status,
    String message,
  ) {
    try {
      final ack = jsonEncode({
        'channel': 'file_transfer',
        'type': 'file_ack',
        'filename': filename,
        'status': status,
        'message': message,
        'timestamp': DateTime.now().toIso8601String(),
      });

      channel.sink.add(ack);
      print("📤 Sent file acknowledgment: $filename -> $status");
    } catch (e) {
      print("❌ Error sending file acknowledgment: $e");
    }
  }

  // =====================================================================================================
  /*
  getSystemInfo:

  This function gathers basic system information from a Linux machine
  and returns it as a map with four keys: `os`, `cpu`, `ram`, and `battery`.

  Steps:
  1. OS Information:
     - Runs `cat /etc/os-release` to get the OS name and version.
     - Extracts values like `NAME=Ubuntu` and `VERSION_ID=20.04`.
     - Formats them into a string like "Ubuntu 20.04".

  2. CPU Usage:
     - Executes `top -bn1 | grep '%Cpu'` to get live CPU usage.
     - Extracts the `%us` (user space) value (e.g., "5.3%").
     - Formats and returns this as CPU usage.

  3. RAM Usage:
     - Runs `free -b` to get RAM usage in bytes.
     - Extracts total and used memory from the `Mem:` line.
     - Calculates the usage percentage (e.g., "42.7%").

  4. Battery Level:
     - Uses `upower` to get the current battery percentage.
     - If it fails (e.g., no battery on desktop), sets battery as "N/A".

  Returns:
     A map of the gathered information:
     {
       'os': 'Ubuntu 20.04',
       'cpu': '5.3%',
       'ram': '42.7%',
       'battery': '86%'
     }

  This data can be sent to clients to display device status in real-time.
*/
  // =====================================================================================================

  Future<Map<String, String>> getSystemInfo() async {
    // OS information
    final osRelease = await Process.run('cat', ['/etc/os-release']);
    final osLines = osRelease.stdout.toString().split('\n');

    final name = osLines.firstWhere(
      (line) => line.startsWith('NAME='),
      orElse: () => 'NAME=Unknown',
    );
    final version = osLines.firstWhere(
      (line) => line.startsWith('VERSION_ID='),
      orElse: () => 'VERSION_ID=Unknown',
    );

    final osName = name.split('=').last.replaceAll('"', '');
    final osVersion = version.split('=').last.replaceAll('"', '');
    final os = "$osName $osVersion";

    // CPU usage
    final cpuResult = await Process.run('sh', ['-c', "top -bn1 | grep '%Cpu'"]);
    final cpuLine = cpuResult.stdout.toString().trim();

    final cpuut = cpuLine
        .split(',')
        .firstWhere((part) => part.contains('us'), orElse: () => '0.0%')
        .replaceAll(RegExp(r'[^0-9.]'), '');
    final cpu = "$cpuut %";

    // RAM usage
    final result = await Process.run('free', ['-b']);
    final lines = result.stdout.toString().split('\n');
    final memLine = lines.firstWhere((line) => line.startsWith('Mem:'));
    final parts = memLine.trim().split(RegExp(r'\s+'));

    final total = int.parse(parts[1]);
    final used = int.parse(parts[2]);

    final percentUsed = (used / total) * 100;
    final ram = "${percentUsed.toStringAsFixed(1)}%";

    // Battery
    String battery = 'N/A';
    try {
      final batteryResult = await Process.run('sh', [
        '-c',
        "upower -i \$(upower -e | grep BAT) | grep percentage | awk '{print \$2}'",
      ]);
      if (batteryResult.stdout.toString().trim().isNotEmpty) {
        battery = batteryResult.stdout.toString().trim();
      }
    } catch (e) {
      // Battery info not available
    }

    return {'os': os, 'cpu': cpu, 'ram': ram, 'battery': battery};
  }

  // =====================================================================================================
  /*
  _generateFingerprint:

  - This function generates a unique fingerprint (hash) for a device using its name.
  - Steps:
    1. Takes the device name as input (e.g., "Galaxy S24").
    2. Converts the device name into a UTF-8 byte array.
    3. Uses the SHA-256 algorithm to hash those bytes.
    4. Returns the hash as a string (a long hexadecimal value).

  - Purpose:
    This fingerprint is used to uniquely identify a device during pairing
    without exposing the actual device name directly.

  Example:
    Input: "Galaxy S24"
    Output: "8b99a38f3c3c84b08d7f6e94bce8..." (a long SHA-256 hash)
*/
  // =====================================================================================================
  String _generateFingerprint(String deviceName) {
    final id = deviceName;
    final bytes = utf8.encode(id);
    return sha256.convert(bytes).toString();
  }

  // =====================================================================================================
  /*
  _getQRData:

  - This function creates a JSON string containing the necessary data for another
    device to connect to this device over WebSocket.

  - Steps:
    1. Gets the local device name using `Platform.localHostname`.
    2. Generates a unique fingerprint for the device using `_generateFingerprint(...)`.
    3. Builds a map with the following data:
       • `ip` – the device's IP address (from `_serverAddress`)
       • `port` – the WebSocket server port (from `_serverPort`)
       • `protocol` – hardcoded as 'ws' (WebSocket)
       • `devicename` – the device's name
       • `fingerprint` – the unique hash of the device name
    4. Converts the map into a JSON string using `jsonEncode(...)`.

  - Purpose:
    This JSON string is used as the content of a **QR code** that can be scanned
    by another device to automatically connect and pair with this one.

  Example output:
    {
      "ip": "192.168.1.5",
      "port": 5050,
      "protocol": "ws",
      "devicename": "ubuntu-pc",
      "fingerprint": "e4b8ab03cf..."
    }
*/
  // =====================================================================================================
  String _getQRData() {
    final deviceName = Platform.localHostname;
    final fingerprint = _generateFingerprint(deviceName);
    return jsonEncode({
      'ip': _serverAddress,
      'port': _serverPort,
      'protocol': 'ws',
      'devicename': deviceName,
      'fingerprint': fingerprint,
    });
  }

  // =====================================================================================================
  /*
  _formatFileSize:

  - This function takes a file size in bytes and returns a readable string,
    like "2.4 MB" or "512 KB".

  - Steps:
    1. If the size is less than 1 KB, show it in **bytes** (e.g., "900 B").
    2. If less than 1 MB, show it in **kilobytes** (KB) with 1 decimal (e.g., "2.5 KB").
    3. If less than 1 GB, show it in **megabytes** (MB) (e.g., "14.2 MB").
    4. Otherwise, show it in **gigabytes** (GB) (e.g., "1.1 GB").

  - Purpose:
    Makes raw byte counts easier for users to read in file transfer UIs.

  Example:
    Input: 1048576
    Output: "1.0 MB"
*/
  // =====================================================================================================
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return _connectionStatus != "Connected"
        ? Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Center(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              children: [
                                Text(
                                  'Scan to Connect',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 22,
                                  ),
                                ),
                                SizedBox(height: 20),
                                if (_isServerRunning)
                                  Container(
                                    padding: EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: QrImageView(
                                      data: _getQRData(),
                                      version: QrVersions.auto,
                                      size: 400.0,
                                    ),
                                  ),
                                SizedBox(height: 20),
                                Text('Server: $_serverAddress:$_serverPort'),
                                Text('Status: $_connectionStatus'),
                                if (_fileReceiveStatus.isNotEmpty) ...[
                                  SizedBox(height: 20),
                                  Text(
                                    'Receiving Files: ${_fileReceiveStatus.length}',
                                  ),
                                  for (final status in _fileReceiveStatus)
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${status.filename} - ${(status.progress * 100).toStringAsFixed(1)}%',
                                        ),
                                        LinearProgressIndicator(
                                          value: status.progress,
                                          backgroundColor: Colors.grey[300],
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                status.status ==
                                                        ReceiveStatus.error
                                                    ? Colors.red
                                                    : Colors.blue,
                                              ),
                                        ),
                                        SizedBox(height: 10),
                                      ],
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        )
        : DashboardPage();
  }

  // =====================================================================================================
  /*
  dispose:

  - This method is called when the widget (or screen) is being removed
    from memory — typically when the user navigates away or the app is closing.

  - Purpose: Clean up all background tasks, open sockets, and resources
    to avoid memory leaks and unexpected behavior.

  Steps:
    1. Cancels any periodic timer that was running (`_cleanupTimer`).
    2. Cleans up all active file transfers using `_cleanupAllActiveTransfers()`.
    3. Closes the WebSocket server if it's running (`_server?.close()`).
    4. Closes the WebSocket connection to the client (`_clientChannel?.sink.close()`).
    5. Disposes the text editing controller (`_messageController.dispose()`).
    6. Stops mDNS discovery/broadcasting (`_mdns.stop()`).
    7. Calls `super.dispose()` to let the parent class clean up as well.

  This is good practice in Flutter to prevent background activity
  from continuing after the widget is gone.
*/
  // =====================================================================================================
  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupAllActiveTransfers();
    _server?.close();
    _clientChannel?.sink.close();
    _messageController.dispose();
    _mdns.stop();
    super.dispose();
  }
}

// =====================================================================================================
/*
  FileReceiveStatus:

  - Represents the current status of a file being received in chunks.

  Fields:
    - `filename`: original file name sent by sender.
    - `finalFilename`: sanitized or renamed version used for saving locally.
    - `status`: current status of the transfer (receiving, completed, or error).
    - `progress`: a value between 0 and 1 indicating how much of the file is received.
    - `fileSize`: total size of the file in bytes.
    - `bytesReceived`: how many bytes have been received so far.
    - `totalChunks`: total number of chunks expected.
    - `receivedChunks`: how many chunks have actually been received.
    - `sender`: identifier for who sent the file (e.g., device name).
    - `startTime`: when the transfer started.
    - `error`: optional error message if something went wrong.

  - This class is useful for tracking progress and updating the UI.
*/
// =====================================================================================================
class FileReceiveStatus {
  final String filename;
  final String finalFilename;
  ReceiveStatus status;
  double progress;
  final int fileSize;
  int bytesReceived;
  final int totalChunks;
  int receivedChunks;
  final String sender;
  final DateTime startTime;
  String? error;

  FileReceiveStatus({
    required this.filename,
    required this.finalFilename,
    required this.status,
    required this.progress,
    required this.fileSize,
    required this.bytesReceived,
    required this.totalChunks,
    required this.receivedChunks,
    required this.sender,
    required this.startTime,
    this.error,
  });
}

enum ReceiveStatus { receiving, completed, error }

// =====================================================================================================
/*
  ChunkedFileReceiver:

  - This class manages receiving a file in small pieces (chunks) over a network (like WebSocket).
  - It handles writing those chunks to a local file, tracks progress, and verifies file integrity.

  Key Features:
    ✅ Duplicate chunk detection and skipping
    ✅ Synchronized (safe) file writing using a queue as a mutex
    ✅ Progress tracking and completion detection
    ✅ SHA-256 hash verification to confirm the file is intact
    ✅ Safe cleanup of resources

  Constructor Parameters:
    - filename: original file name received
    - finalFilename: local name to save the file as
    - targetFile: the local `File` object
    - fileSize: total file size in bytes
    - fileHash: expected final hash (used for verification)
    - totalChunks: how many pieces to expect
    - chunkSize: size of each chunk
    - sender: who sent the file

  Fields:
    - _receivedChunks: tracks which chunks have been written
    - _writeFile: the open file stream for writing
    - _operationQueue: ensures one chunk write at a time (like a mutex)
    - _isFileOpen: helps avoid opening the file multiple times
*/
// =====================================================================================================
class ChunkedFileReceiver {
  final String filename;
  final String finalFilename;
  final File targetFile;
  final int fileSize;
  final String fileHash;
  final int totalChunks;
  final int chunkSize;
  final String sender;

  final Set<int> _receivedChunks = {};
  DateTime lastChunkTime = DateTime.now();
  RandomAccessFile? _writeFile;

  // **CRITICAL FIX**: Use a proper semaphore for file operations
  final Queue<Completer<void>> _operationQueue = Queue<Completer<void>>();
  bool _isFileOpen = false;

  ChunkedFileReceiver({
    required this.filename,
    required this.finalFilename,
    required this.targetFile,
    required this.fileSize,
    required this.fileHash,
    required this.totalChunks,
    required this.chunkSize,
    required this.sender,
  });

  /*
    writeChunk:

    - Receives a chunk index and raw byte data.
    - Skips duplicate chunks.
    - Uses a queue as a mutex to ensure one chunk is written at a time.
    - Calls `_performChunkWrite` to do the actual file writing.
  */
  Future<void> writeChunk(int chunkIndex, Uint8List data) async {
    if (_receivedChunks.contains(chunkIndex)) {
      return; // Skip duplicate chunks
    }

    // **CRITICAL FIX**: Use a proper mutex pattern
    final completer = Completer<void>();
    _operationQueue.add(completer);

    // Wait for our turn
    while (_operationQueue.isNotEmpty && _operationQueue.first != completer) {
      await Future.delayed(Duration(milliseconds: 1));
    }

    try {
      await _performChunkWrite(chunkIndex, data);
    } catch (e) {
      print('❌ Error writing chunk $chunkIndex: $e');
      rethrow;
    } finally {
      _operationQueue.removeFirst();
      completer.complete();
    }
  }

   /*
    _performChunkWrite:

    - Opens the file for writing if it's not already open.
    - Calculates the correct position to write the chunk (offset).
    - Writes and flushes the data to disk.
    - Adds the chunk index to `_receivedChunks`.
  */
  Future<void> _performChunkWrite(int chunkIndex, Uint8List data) async {
    try {
      // **FIXED**: Ensure file is opened only once
      if (_writeFile == null && !_isFileOpen) {
        _isFileOpen = true;
        _writeFile = await targetFile.open(mode: FileMode.write);
      }

      if (_writeFile != null) {
        final offset = chunkIndex * chunkSize;
        await _writeFile!.setPosition(offset);
        await _writeFile!.writeFrom(data);
        await _writeFile!.flush();

        _receivedChunks.add(chunkIndex);
        lastChunkTime = DateTime.now();
      }
    } catch (e) {
      print('❌ Error in chunk write operation $chunkIndex: $e');
      rethrow;
    }
  }
  /*
    getProgress:
    - Returns progress as a double (0.0 to 1.0).
  */
  double getProgress() {
    if (totalChunks == 0) return 0.0;
    return _receivedChunks.length / totalChunks;
  }
  /*
    getBytesReceived:
    - Returns the number of bytes received so far.
  */
  int getBytesReceived() {
    return _receivedChunks.length * chunkSize;
  }
  /*
    getReceivedChunks:
    - Returns the count of chunks received.
  */
  int getReceivedChunks() {
    return _receivedChunks.length;
  }
/*
    isComplete:
    - Returns true if all chunks are received.
  */
  bool isComplete() {
    return _receivedChunks.length == totalChunks;
  }

  /*
    verifyFile:

    - Waits for all ongoing chunk writes to finish.
    - Closes the file.
    - Reads the file and computes its hash.
    - Compares it with the expected hash to verify integrity.
  */
  Future<bool> verifyFile() async {
    try {
    
      while (_operationQueue.isNotEmpty) {
        await Future.delayed(Duration(milliseconds: 10));
      }

      if (_writeFile != null) {
        await _writeFile!.close();
        _writeFile = null;
        _isFileOpen = false;
      }

      final bytes = await targetFile.readAsBytes();
      final computedHash = sha256.convert(bytes).toString();

      return computedHash == fileHash;
    } catch (e) {
      print('Error verifying file: $e');
      return false;
    }
  }

  /*
    cleanup:

    - Closes file stream safely.
    - Clears the write queue and resets flags.
    - Should be called on failure or app close.
  */
  void cleanup() {
    try {
      _writeFile?.close();
      _writeFile = null;
      _isFileOpen = false;
      _operationQueue.clear();
    } catch (e) {
      print('Error during cleanup: $e');
    }
  }
}
