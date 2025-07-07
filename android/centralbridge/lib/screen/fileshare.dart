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
      });
    }
  }

  Future<void> _sendFiles() async {
    if (_selectedFiles.isEmpty) return;

    int currentFileIndex = 0;

    void sendNextFile() async {
      if (currentFileIndex >= _selectedFiles.length) {
        print("✅ All files sent successfully");
        return;
      }

      final file = _selectedFiles[currentFileIndex];
      final bytes = await file.readAsBytes();
      final base64Data = base64Encode(bytes);
      final filename = basename(file.path);

      final fileMessage = jsonEncode({
        'channel': 'file_transfer',
        'filename': filename,
        'data': base64Data,
        'sender': 'Android',
        'timestamp': DateTime.now().toIso8601String(),
      });

      print("📤 Sending file ${currentFileIndex + 1}/${_selectedFiles.length}: $filename");
      widget.webSocketChannel.sink.add(fileMessage);
    }

    // Listen for acknowledgment
    widget.webSocketChannel.stream.listen((message) {
      try {
        final decoded = jsonDecode(message);
        if (decoded['channel'] == 'file_ack') {
          print("✅ Acknowledged: ${decoded['filename']}");
          currentFileIndex++;
          sendNextFile(); // Send next
        }
      } catch (e) {
        print("❌ Error parsing acknowledgment: $e");
      }
    });

    // Start with first file
    sendNextFile();
  }


  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2, // 2 tabs: Progress & Completed
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
                        onPressed: _pickFiles,
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
                          onPressed: _sendFiles,
                          icon: Icon(Icons.send, color: Colors.white),
                          label: Text("Send to PC", style: TextStyle(color: Colors.white)),
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
                  Center(child: Text('In Progress Files')),
                  Center(child: Text('Completed Files')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}