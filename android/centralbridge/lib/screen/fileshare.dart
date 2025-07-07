import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class Fileshare extends StatefulWidget {
  final WebSocketChannel webSocketChannel;

  Fileshare({required this.webSocketChannel});

  @override
  _FileshareState createState() => _FileshareState();
}

class _FileshareState extends State<Fileshare> {
  List<File> _selectedFiles = [];
  List<FileTransferStatus> _fileTransferStatus = [];
  int _currentFileIndex = 0;
  bool _isTransferring = false;

  @override
  void initState() {
    super.initState();
    // Set up a single stream listener for this screen
    _setupStreamListener();
  }

  void _setupStreamListener() {
    // Don't create a new listener, instead use a broadcast stream
    // or handle the acknowledgments differently
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

    setState(() {
      _isTransferring = true;
      _currentFileIndex = 0;
    });

    // Send files one by one with a simple approach
    for (int i = 0; i < _selectedFiles.length; i++) {
      await _sendSingleFile(i);
      await Future.delayed(Duration(milliseconds: 500)); // Small delay between files
    }

    setState(() {
      _isTransferring = false;
    });
  }

  Future<void> _sendSingleFile(int index) async {
    final file = _selectedFiles[index];
    final bytes = await file.readAsBytes();
    final base64Data = base64Encode(bytes);
    final filename = basename(file.path);

    setState(() {
      _fileTransferStatus[index].status = TransferStatus.sending;
      _fileTransferStatus[index].progress = 0.5;
    });

    final fileMessage = jsonEncode({
      'channel': 'file_transfer',
      'filename': filename,
      'data': base64Data,
      'sender': 'Android',
      'timestamp': DateTime.now().toIso8601String(),
      'file_index': index, // Add index to track which file this is
    });

    print("📤 Sending file ${index + 1}/${_selectedFiles.length}: $filename");
    widget.webSocketChannel.sink.add(fileMessage);

    // Mark as sent (you might want to wait for actual acknowledgment)
    setState(() {
      _fileTransferStatus[index].status = TransferStatus.completed;
      _fileTransferStatus[index].progress = 1.0;
    });
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
                          subtitle: LinearProgressIndicator(
                            value: status.progress,
                            backgroundColor: Colors.grey[300],
                            valueColor: AlwaysStoppedAnimation<Color>(
                              status.status == TransferStatus.completed
                                  ? Colors.green
                                  : Colors.blue,
                            ),
                          ),
                          trailing: Text(_getStatusText(status.status)),
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
        return 'Error';
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