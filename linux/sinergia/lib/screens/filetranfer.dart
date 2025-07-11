import 'dart:io';
import 'package:flutter/material.dart';

class FileTransferPage extends StatefulWidget {
  const FileTransferPage({super.key});

  @override
  State<FileTransferPage> createState() => _FileTransferPageState();
}

class _FileTransferPageState extends State<FileTransferPage> {
  String? selectedFile;

  Future<void> _pickFileWithZenity() async {
    try {
      final result = await Process.run(
        'zenity',
        ['--file-selection', '--title=Select a File to Transfer'],
      );

      if (result.exitCode == 0) {
        setState(() {
          selectedFile = result.stdout.toString().trim();
        });
        debugPrint('Selected file: $selectedFile');
        // TODO: Handle the selected file (send/upload it)
      } else {
        debugPrint('File selection cancelled.');
      }
    } catch (e) {
      debugPrint('Zenity error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Center(
        child: Container(
          width: 700,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.1),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "File Transfer",
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _pickFileWithZenity,
                        icon: const Icon(Icons.upload_file),
                        label: const Text("Upload Files"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton.icon(
                        onPressed: () {
                          // TODO: Implement "Download from Phone"
                        },
                        icon: const Icon(Icons.download),
                        label: const Text("Download from Phone"),
                      ),
                    ],
                  )
                ],
              ),
              const SizedBox(height: 30),

              // File drop area
              InkWell(
                onTap: _pickFileWithZenity,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 50),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blueAccent.withOpacity(0.3), width: 1.5),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_upload_outlined, size: 48, color: Colors.blue),
                      const SizedBox(height: 12),
                      const Text(
                        "Drag files here to transfer",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        "or click to browse files from your computer",
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Supports: Images, Videos, Documents, Archives   •   Max size: 500MB",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                      if (selectedFile != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Selected: ${selectedFile!.split('/').last}',
                          style: const TextStyle(fontSize: 14, color: Colors.black87),
                        ),
                      ]
                    ],
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
