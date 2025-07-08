import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart';
import 'dart:async';

// Import your WebSocket manager
import 'package:centralbridge/global_socket_manager.dart';

class Fileshare extends StatefulWidget {
  // Remove the webSocketChannel parameter since we'll use the manager
  Fileshare();

  @override
  _FileshareState createState() => _FileshareState();
}

class _FileshareState extends State<Fileshare> {
  List<File> _selectedFiles = [];
  List<FileTransferStatus> _fileTransferStatus = [];
  int _currentFileIndex = 0;
  bool _isTransferring = false;

  // Stream subscriptions
  StreamSubscription<Map<String, dynamic>>? _fileAckSubscription;
  StreamSubscription<String>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    _setupStreamListeners();
  }

  void _setupStreamListeners() {
    // Listen to file transfer acknowledgments
    _fileAckSubscription = WebSocketManager.instance.listenToFileTransferAcks().listen(
          (data) {
        print('📥 Received file ack: $data'); // Debug print
        _handleFileAcknowledgment(data);
      },
      onError: (error) {
        print('File ack stream error: $error');
      },
    );

    // Listen to connection status
    _connectionSubscription = WebSocketManager.instance.connectionStream.listen(
          (status) {
        if (status == 'Disconnected' && _isTransferring) {
          // Handle disconnection during transfer
          setState(() {
            _isTransferring = false;
            // Mark pending files as error
            for (int i = 0; i < _fileTransferStatus.length; i++) {
              if (_fileTransferStatus[i].status == TransferStatus.sending) {
                _fileTransferStatus[i].status = TransferStatus.error;
              }
            }
          });
        }
      },
    );
  }

  void _handleFileAcknowledgment(Map<String, dynamic> data) {
    // Handle different types of file acknowledgments
    String? filename = data['filename'];
    String? status = data['status'];
    String? message = data['message'];

    print('🔍 Processing ack for: $filename, status: $status, message: $message');

    if (filename != null && status != null) {
      setState(() {
        // Find the file by filename
        int targetIndex = _fileTransferStatus.indexWhere((f) => f.filename == filename);

        if (targetIndex >= 0) {
          print('📊 Updating status for file at index $targetIndex: $filename -> $status');

          if (status == 'success') {
            _fileTransferStatus[targetIndex].status = TransferStatus.completed;
            _fileTransferStatus[targetIndex].progress = 1.0;
            print('✅ File $filename marked as completed');
          } else if (status == 'error') {
            _fileTransferStatus[targetIndex].status = TransferStatus.error;
            print('❌ File $filename marked as error: $message');
          }
        } else {
          print('⚠️ Could not find file $filename in transfer status list');
        }
      });
    } else {
      print('⚠️ Invalid acknowledgment data: missing filename or status');
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );

    if (result != null) {
      setState(() {
        _selectedFiles = result.paths
            .where((path) => path != null)
            .map((path) => File(path!))
            .toList();

        // Initialize transfer status for each file
        _fileTransferStatus = _selectedFiles.map((file) =>
            FileTransferStatus(
              filename: basename(file.path),
              status: TransferStatus.pending,
              progress: 0.0,
            )
        ).toList();
      });
    }
  }

  Future<void> _sendFiles() async {
    if (_selectedFiles.isEmpty || _isTransferring) return;

    // Check if connected
    if (!WebSocketManager.instance.isConnected) {
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(content: Text('Not connected to server')),
      // );
      return;
    }

    setState(() {
      _isTransferring = true;
      _currentFileIndex = 0;
    });

    try {
      // Send files one by one
      for (int i = 0; i < _selectedFiles.length; i++) {
        if (!WebSocketManager.instance.isConnected) {
          // Connection lost during transfer
          setState(() {
            _fileTransferStatus[i].status = TransferStatus.error;
          });
          break;
        }

        await _sendSingleFile(i);

        // Small delay between files to prevent overwhelming the connection
        if (i < _selectedFiles.length - 1) {
          await Future.delayed(Duration(milliseconds: 500));
        }
      }
    } catch (e) {
      print('Error during file transfer: $e');
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(content: Text('Error during file transfer: $e')),
      // );
    } finally {
      setState(() {
        _isTransferring = false;
      });
    }
  }

  Future<void> _sendSingleFile(int index) async {
    final file = _selectedFiles[index];

    try {
      final bytes = await file.readAsBytes();
      final base64Data = base64Encode(bytes);
      final filename = basename(file.path);

      setState(() {
        _fileTransferStatus[index].status = TransferStatus.sending;
        _fileTransferStatus[index].progress = 0.5;
      });

      final fileMessage = {
        'channel': 'file_transfer',
        'filename': filename,
        'data': base64Data,
        'sender': 'Android',
        'timestamp': DateTime.now().toIso8601String(),
        'file_index': index,
        'file_size': bytes.length,
        'total_files': _selectedFiles.length,
      };

      print("📤 Sending file ${index + 1}/${_selectedFiles.length}: $filename");

      // Send via WebSocket manager
      WebSocketManager.instance.sendMessage(fileMessage);

      // Set a timeout for acknowledgment (increased to 60 seconds)
      Timer(Duration(seconds: 60), () {
        if (_fileTransferStatus[index].status == TransferStatus.sending) {
          setState(() {
            _fileTransferStatus[index].status = TransferStatus.error;
          });
          print('⏰ Timeout waiting for acknowledgment for file: $filename');
        }
      });

    } catch (e) {
      print('Error sending file $index: $e');
      setState(() {
        _fileTransferStatus[index].status = TransferStatus.error;
      });
    }
  }

  @override
  void dispose() {
    // Clean up subscriptions
    _fileAckSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('File Share'),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Progress'),
              Tab(text: 'Completed'),
            ],
          ),
        ),
        body: Column(
          children: [
            // Top: File Picker Button + Selected Files Preview
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isTransferring ? null : _pickFiles,
                        icon: Icon(Icons.attach_file, color: Colors.white),
                        label: Text("Pick Files", style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Color(0xff7777cd),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _selectedFiles.isNotEmpty
                              ? "${_selectedFiles.length} file(s) selected"
                              : "No files selected",
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (_selectedFiles.isNotEmpty) SizedBox(height: 8),
                  if (_selectedFiles.isNotEmpty)
                    SizedBox(
                      height: 50,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _selectedFiles.length,
                        separatorBuilder: (_, __) => SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          final name = _selectedFiles[index].path.split('/').last;
                          return Container(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(name, style: TextStyle(fontSize: 13)),
                          );
                        },
                      ),
                    ),
                  if (_selectedFiles.isNotEmpty) SizedBox(height: 10),
                  if (_selectedFiles.isNotEmpty)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _isTransferring ? null : _sendFiles,
                          icon: _isTransferring
                              ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                              : Icon(Icons.send, color: Colors.white),
                          label: Text(
                            _isTransferring ? "Sending..." : "Send to PC",
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Color(0xff75a78e),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),

            // Bottom: Tab Views
            Expanded(
              child: TabBarView(
                children: [
                  // Progress Tab
                  _fileTransferStatus.isEmpty
                      ? Center(child: Text('No files selected'))
                      : ListView.builder(
                    itemCount: _fileTransferStatus.length,
                    itemBuilder: (context, index) {
                      final status = _fileTransferStatus[index];
                      return Card(
                        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: _getStatusIcon(status.status),
                          title: Text(status.filename),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinearProgressIndicator(
                                value: status.progress,
                                backgroundColor: Colors.grey[300],
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  status.status == TransferStatus.completed
                                      ? Colors.green
                                      : status.status == TransferStatus.error
                                      ? Colors.red
                                      : Colors.blue,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                _getStatusText(status.status),
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                          trailing: status.status == TransferStatus.error
                              ? IconButton(
                            icon: Icon(Icons.refresh, color: Colors.blue),
                            onPressed: () => _retrySingleFile(index),
                          )
                              : null,
                        ),
                      );
                    },
                  ),

                  // Completed Tab
                  _fileTransferStatus.where((s) => s.status == TransferStatus.completed).isEmpty
                      ? Center(child: Text('No completed transfers'))
                      : ListView.builder(
                    itemCount: _fileTransferStatus.where((s) => s.status == TransferStatus.completed).length,
                    itemBuilder: (context, index) {
                      final completedFiles = _fileTransferStatus.where((s) => s.status == TransferStatus.completed).toList();
                      final status = completedFiles[index];
                      return Card(
                        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: Icon(Icons.check_circle, color: Colors.green),
                          title: Text(status.filename),
                          subtitle: Text('Transfer completed'),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Retry single file transfer
  Future<void> _retrySingleFile(int index) async {
    if (!WebSocketManager.instance.isConnected) {
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(content: Text('Not connected to server')),
      // );
      return;
    }

    setState(() {
      _fileTransferStatus[index].status = TransferStatus.pending;
      _fileTransferStatus[index].progress = 0.0;
    });

    await _sendSingleFile(index);
  }

  Widget _getStatusIcon(TransferStatus status) {
    switch (status) {
      case TransferStatus.pending:
        return Icon(Icons.pending, color: Colors.grey);
      case TransferStatus.sending:
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case TransferStatus.completed:
        return Icon(Icons.check_circle, color: Colors.green);
      case TransferStatus.error:
        return Icon(Icons.error, color: Colors.red);
    }
  }

  String _getStatusText(TransferStatus status) {
    switch (status) {
      case TransferStatus.pending:
        return 'Waiting';
      case TransferStatus.sending:
        return 'Sending...';
      case TransferStatus.completed:
        return 'Completed';
      case TransferStatus.error:
        return 'Error - Tap retry';
    }
  }
}

// Helper classes for file transfer status
class FileTransferStatus {
  final String filename;
  TransferStatus status;
  double progress;

  FileTransferStatus({
    required this.filename,
    required this.status,
    required this.progress,
  });
}

enum TransferStatus {
  pending,
  sending,
  completed,
  error,
}