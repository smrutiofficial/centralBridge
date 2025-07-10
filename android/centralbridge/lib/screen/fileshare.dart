import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart';
import 'dart:async';
import 'package:crypto/crypto.dart';

// Import your WebSocket manager
import 'package:centralbridge/global_socket_manager.dart';

class Fileshare extends StatefulWidget {
  Fileshare();

  @override
  _FileshareState createState() => _FileshareState();
}

class _FileshareState extends State<Fileshare> {
  List<File> _selectedFiles = [];
  List<FileTransferStatus> _fileTransferStatus = [];
  List<FileTransferStatus> _completedTransfers = [];
  bool _isTransferring = false;

  // Chunking configuration
  static const int CHUNK_SIZE = 64 * 1024; // 64KB chunks
  static const int MAX_CONCURRENT_CHUNKS = 2; // Reduced from 3 to 2 for better reliability
  static const int MAX_RETRIES = 3; // Maximum retries per chunk

  // Stream subscriptions
  StreamSubscription<Map<String, dynamic>>? _fileAckSubscription;
  StreamSubscription<String>? _connectionSubscription;

  // Active transfers tracking
  Map<String, ChunkedTransfer> _activeTransfers = {};

  @override
  void initState() {
    super.initState();
    _setupStreamListeners();
  }

  void _setupStreamListeners() {
    // Listen to file transfer acknowledgments
    _fileAckSubscription = WebSocketManager.instance.listenToFileTransferAcks().listen(
          (data) {
        print('📥 Received file ack: $data');
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
          _handleConnectionLost();
        }
      },
    );
  }

  void _handleConnectionLost() {
    setState(() {
      _isTransferring = false;
      // Cancel all active transfers
      _activeTransfers.clear();

      // Mark sending files as error
      for (int i = 0; i < _fileTransferStatus.length; i++) {
        if (_fileTransferStatus[i].status == TransferStatus.sending) {
          _fileTransferStatus[i].status = TransferStatus.error;
        }
      }
    });
  }

  void _handleFileAcknowledgment(Map<String, dynamic> data) {
    final String? filename = data['filename'];
    final String? status = data['status'];
    final String? chunkId = data['chunk_id'];
    final int? chunkIndex = data['chunk_index'];

    print('🔍 Processing ack - filename: $filename, status: $status, chunk: $chunkIndex');

    if (filename == null) return;

    // Handle chunk acknowledgment
    if (chunkId != null && chunkIndex != null) {
      final transfer = _activeTransfers[filename];
      if (transfer != null) {
        transfer.handleChunkAck(chunkIndex, status == 'success');
        _updateTransferProgress(filename, transfer);

        // Continue sending next chunks
        if (status == 'success') {
          _sendNextChunks(filename, transfer);
        } else {
          // Handle chunk failure - retry if within limits
          if (transfer.shouldRetryChunk(chunkIndex)) {
            print('🔄 Retrying chunk $chunkIndex for $filename');
            _retryChunk(filename, transfer, chunkIndex);
          } else {
            print('❌ Chunk $chunkIndex failed permanently for $filename');
            // Mark transfer as failed if too many chunks failed
            if (transfer.hasFailed()) {
              _markTransferAsFailed(filename, 'Too many chunk failures');
            }
          }
        }
      }
      return;
    }

    // Handle final file status
    if (status != null) {
      setState(() {
        int targetIndex = _fileTransferStatus.indexWhere((f) => f.filename == filename);

        if (targetIndex >= 0) {
          if (status == 'success') {
            // Move to completed
            FileTransferStatus completedFile = _fileTransferStatus[targetIndex];
            completedFile.status = TransferStatus.completed;
            completedFile.progress = 1.0;
            completedFile.transferSpeed = _calculateFinalSpeed(completedFile);

            _completedTransfers.add(completedFile);
            _fileTransferStatus.removeAt(targetIndex);

            // Clean up active transfer
            _activeTransfers.remove(filename);

            print('✅ File $filename completed successfully');
          } else if (status == 'error') {
            _fileTransferStatus[targetIndex].status = TransferStatus.error;
            _activeTransfers.remove(filename);
            print('❌ File $filename failed: ${data['message']}');
          }
        }
      });
    }
  }

  void _markTransferAsFailed(String filename, String reason) {
    setState(() {
      int targetIndex = _fileTransferStatus.indexWhere((f) => f.filename == filename);
      if (targetIndex >= 0) {
        _fileTransferStatus[targetIndex].status = TransferStatus.error;
      }
    });
    _activeTransfers.remove(filename);
    print('❌ Transfer failed for $filename: $reason');
  }

  Future<void> _retryChunk(String filename, ChunkedTransfer transfer, int chunkIndex) async {
    if (!WebSocketManager.instance.isConnected) return;

    try {
      await Future.delayed(Duration(milliseconds: 500)); // Small delay before retry

      final chunkData = await transfer.getChunkData(chunkIndex);
      final chunkMessage = {
        'channel': 'file_transfer',
        'type': 'chunk',
        'filename': filename,
        'chunk_index': chunkIndex,
        'chunk_id': '${filename}_${chunkIndex}_${DateTime.now().millisecondsSinceEpoch}', // Unique ID for retry
        'data': base64Encode(chunkData),
        'chunk_size': chunkData.length,
        'is_last_chunk': chunkIndex == transfer.totalChunks - 1,
        'is_retry': true,
        'retry_count': transfer.getRetryCount(chunkIndex),
        'timestamp': DateTime.now().toIso8601String(),
      };

      print('🔄 Retrying chunk $chunkIndex/${transfer.totalChunks} for $filename (attempt ${transfer.getRetryCount(chunkIndex) + 1})');
      WebSocketManager.instance.sendMessage(chunkMessage);

      transfer.markChunkAsRetry(chunkIndex);

    } catch (e) {
      print('Error retrying chunk $chunkIndex: $e');
      transfer.markChunkAsError(chunkIndex);
    }
  }

  void _updateTransferProgress(String filename, ChunkedTransfer transfer) {
    setState(() {
      int targetIndex = _fileTransferStatus.indexWhere((f) => f.filename == filename);
      if (targetIndex >= 0) {
        final progress = transfer.getProgress();
        _fileTransferStatus[targetIndex].progress = progress;
        _fileTransferStatus[targetIndex].transferSpeed = transfer.getTransferSpeed();
        _fileTransferStatus[targetIndex].eta = transfer.getETA();

        // Update bytes transferred
        _fileTransferStatus[targetIndex].bytesTransferred = transfer.getBytesTransferred();
      }
    });
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
        _fileTransferStatus = _selectedFiles.map((file) {
          final fileStats = file.statSync();
          return FileTransferStatus(
            filename: basename(file.path),
            status: TransferStatus.pending,
            progress: 0.0,
            fileSize: fileStats.size,
            bytesTransferred: 0,
            transferSpeed: 0.0,
            eta: Duration.zero,
          );
        }).toList();

        // Clear completed transfers when new files are selected
        _completedTransfers.clear();
        _activeTransfers.clear();
      });
    }
  }

  Future<void> _sendFiles() async {
    if (_selectedFiles.isEmpty || _isTransferring) return;

    if (!WebSocketManager.instance.isConnected) {
      _showErrorSnackBar('Not connected to server');
      return;
    }

    setState(() {
      _isTransferring = true;
    });

    try {
      // Send files one by one
      for (int i = 0; i < _selectedFiles.length; i++) {
        if (!WebSocketManager.instance.isConnected) {
          _handleConnectionLost();
          break;
        }

        await _sendSingleFileChunked(i);
      }
    } catch (e) {
      print('Error during file transfer: $e');
      _showErrorSnackBar('Error during file transfer: $e');
    } finally {
      setState(() {
        _isTransferring = false;
      });
    }
  }

  Future<void> _sendSingleFileChunked(int index) async {
    final file = _selectedFiles[index];
    final filename = basename(file.path);

    int progressIndex = _fileTransferStatus.indexWhere((f) => f.filename == filename);
    if (progressIndex < 0) return;

    try {
      final fileSize = await file.length();
      final fileHash = await _calculateFileHash(file);

      setState(() {
        _fileTransferStatus[progressIndex].status = TransferStatus.sending;
        _fileTransferStatus[progressIndex].progress = 0.0;
        _fileTransferStatus[progressIndex].startTime = DateTime.now();
      });

      // Create chunked transfer
      final transfer = ChunkedTransfer(
        file: file,
        filename: filename,
        fileSize: fileSize,
        fileHash: fileHash,
        chunkSize: CHUNK_SIZE,
      );

      _activeTransfers[filename] = transfer;

      // Send file metadata first
      await _sendFileMetadata(transfer);

      // Wait a bit for metadata to be processed
      await Future.delayed(Duration(milliseconds: 100));

      // Start sending chunks
      await _sendNextChunks(filename, transfer);

      // Wait for transfer completion or timeout
      await _waitForTransferCompletion(filename, transfer);

    } catch (e) {
      print('Error sending file $filename: $e');
      setState(() {
        if (progressIndex < _fileTransferStatus.length) {
          _fileTransferStatus[progressIndex].status = TransferStatus.error;
        }
      });
      _activeTransfers.remove(filename);
    }
  }

  Future<void> _sendFileMetadata(ChunkedTransfer transfer) async {
    final metadata = {
      'channel': 'file_transfer',
      'type': 'metadata',
      'filename': transfer.filename,
      'file_size': transfer.fileSize,
      'file_hash': transfer.fileHash,
      'total_chunks': transfer.totalChunks,
      'chunk_size': transfer.chunkSize,
      'sender': 'Android',
      'timestamp': DateTime.now().toIso8601String(),
    };

    print('📤 Sending metadata for ${transfer.filename}: ${transfer.totalChunks} chunks');
    WebSocketManager.instance.sendMessage(metadata);
  }

  Future<void> _sendNextChunks(String filename, ChunkedTransfer transfer) async {
    final chunksToSend = transfer.getNextChunksToSend(MAX_CONCURRENT_CHUNKS);

    if (chunksToSend.isEmpty) return;

    print('📤 Sending ${chunksToSend.length} chunks for $filename');

    for (final chunkIndex in chunksToSend) {
      if (!WebSocketManager.instance.isConnected) break;

      try {
        final chunkData = await transfer.getChunkData(chunkIndex);
        final chunkMessage = {
          'channel': 'file_transfer',
          'type': 'chunk',
          'filename': filename,
          'chunk_index': chunkIndex,
          'chunk_id': '${filename}_${chunkIndex}_${DateTime.now().millisecondsSinceEpoch}',
          'data': base64Encode(chunkData),
          'chunk_size': chunkData.length,
          'is_last_chunk': chunkIndex == transfer.totalChunks - 1,
          'is_retry': false,
          'timestamp': DateTime.now().toIso8601String(),
        };

        print('📤 Sending chunk $chunkIndex/${transfer.totalChunks} for $filename (${chunkData.length} bytes)');
        WebSocketManager.instance.sendMessage(chunkMessage);

        transfer.markChunkAsSent(chunkIndex);

        // Small delay between chunks to avoid overwhelming the connection
        await Future.delayed(Duration(milliseconds: 50));

      } catch (e) {
        print('Error sending chunk $chunkIndex: $e');
        transfer.markChunkAsError(chunkIndex);
      }
    }
  }

  Future<void> _waitForTransferCompletion(String filename, ChunkedTransfer transfer) async {
    final completer = Completer<void>();
    Timer? timeoutTimer;
    Timer? progressTimer;

    // Set up timeout (10 minutes for large files)
    timeoutTimer = Timer(Duration(minutes: 10), () {
      if (!completer.isCompleted) {
        print('⏰ Transfer timeout for $filename');
        _markTransferAsFailed(filename, 'Transfer timeout');
        completer.completeError('Transfer timeout');
      }
    });

    // Monitor transfer progress more frequently
    // In your _waitForTransferCompletion method, replace the monitoring logic:
    progressTimer = Timer.periodic(Duration(milliseconds: 500), (timer) { // Increased interval
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }

      final transfer = _activeTransfers[filename];
      if (transfer == null) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError('Transfer cancelled');
        }
        return;
      }

      // Log transfer stats for debugging
      final stats = transfer.getTransferStats();
      print('📊 Transfer stats for $filename: $stats');

      if (transfer.isCompleted()) {
        print('✅ Transfer completed for $filename');
        timeoutTimer?.cancel();
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete();
        }
      } else if (transfer.hasFailed()) {
        print('❌ Transfer failed for $filename');
        timeoutTimer?.cancel();
        timer.cancel();
        if (!completer.isCompleted) {
          _markTransferAsFailed(filename, 'Too many chunk failures');
          completer.completeError('Transfer failed');
        }
      } else if (transfer.hasMoreChunksToSend()) {
        // Continue sending chunks if there are more to send
        _sendNextChunks(filename, transfer);
      }
    });

    try {
      await completer.future;
    } finally {
      timeoutTimer?.cancel();
      progressTimer?.cancel();
    }
  }

  Future<String> _calculateFileHash(File file) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  double _calculateFinalSpeed(FileTransferStatus status) {
    if (status.startTime != null) {
      final duration = DateTime.now().difference(status.startTime!);
      if (duration.inSeconds > 0) {
        return status.fileSize / duration.inSeconds;
      }
    }
    return 0.0;
  }

  void _showErrorSnackBar(String message) {
    // ScaffoldMessenger.of(context).showSnackBar(
    //   SnackBar(
    //     content: Text(message),
    //     backgroundColor: Colors.red,
    //     duration: Duration(seconds: 5),
    //   ),
    // );
  }

  // Retry single file transfer
  Future<void> _retrySingleFile(int index) async {
    if (!WebSocketManager.instance.isConnected) {
      _showErrorSnackBar('Not connected to server');
      return;
    }

    setState(() {
      _fileTransferStatus[index].status = TransferStatus.pending;
      _fileTransferStatus[index].progress = 0.0;
      _fileTransferStatus[index].bytesTransferred = 0;
      _fileTransferStatus[index].transferSpeed = 0.0;
      _fileTransferStatus[index].eta = Duration.zero;
    });

    // Find the original file index
    String filename = _fileTransferStatus[index].filename;
    int originalIndex = _selectedFiles.indexWhere((file) => basename(file.path) == filename);

    if (originalIndex >= 0) {
      await _sendSingleFileChunked(originalIndex);
    }
  }

  @override
  void dispose() {
    _fileAckSubscription?.cancel();
    _connectionSubscription?.cancel();
    _activeTransfers.clear();
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
              Tab(text: 'Progress (${_fileTransferStatus.length})'),
              Tab(text: 'Completed (${_completedTransfers.length})'),
            ],
          ),
        ),
        body: Column(
          children: [
            // Top: File Picker and Controls
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
                              ? "${_selectedFiles.length} file(s) selected (${_formatTotalSize()})"
                              : "No files selected",
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (_selectedFiles.isNotEmpty) SizedBox(height: 8),
                  if (_selectedFiles.isNotEmpty)
                    SizedBox(
                      height: 60,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _selectedFiles.length,
                        separatorBuilder: (_, __) => SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          final file = _selectedFiles[index];
                          final name = basename(file.path);
                          final size = file.statSync().size;

                          return Container(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 2),
                                Text(
                                  _formatFileSize(size),
                                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                ),
                              ],
                            ),
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
                  _buildProgressTab(),
                  // Completed Tab
                  _buildCompletedTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressTab() {
    if (_fileTransferStatus.isEmpty) {
      return Center(child: Text('No files in progress'));
    }

    return ListView.builder(
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
                    status.status == TransferStatus.error ? Colors.red : Colors.blue,
                  ),
                ),
                SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _getStatusText(status.status),
                      style: TextStyle(fontSize: 12),
                    ),
                    Text(
                      '${(status.progress * 100).toInt()}%',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                if (status.status == TransferStatus.sending) ...[
                  SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_formatFileSize(status.bytesTransferred)} / ${_formatFileSize(status.fileSize)}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                      Text(
                        _formatSpeed(status.transferSpeed),
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                  if (status.eta.inSeconds > 0)
                    Text(
                      'ETA: ${_formatDuration(status.eta)}',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                ],
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
    );
  }

  Widget _buildCompletedTab() {
    if (_completedTransfers.isEmpty) {
      return Center(child: Text('No completed transfers'));
    }

    return ListView.builder(
      itemCount: _completedTransfers.length,
      itemBuilder: (context, index) {
        final status = _completedTransfers[index];
        return Card(
          margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: Icon(Icons.check_circle, color: Colors.green),
            title: Text(status.filename),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Transfer completed'),
                Text(
                  '${_formatFileSize(status.fileSize)} • ${_formatSpeed(status.transferSpeed)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            trailing: Text(
              '100%',
              style: TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      },
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
        return 'Error - Tap retry';
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatTotalSize() {
    int totalSize = _selectedFiles.fold(0, (sum, file) => sum + file.statSync().size);
    return _formatFileSize(totalSize);
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    } else {
      return '${duration.inSeconds}s';
    }
  }
}

// Enhanced file transfer status class
class FileTransferStatus {
  final String filename;
  TransferStatus status;
  double progress;
  final int fileSize;
  int bytesTransferred;
  double transferSpeed;
  Duration eta;
  DateTime? startTime;

  FileTransferStatus({
    required this.filename,
    required this.status,
    required this.progress,
    required this.fileSize,
    required this.bytesTransferred,
    required this.transferSpeed,
    required this.eta,
    this.startTime,
  });
}

enum TransferStatus {
  pending,
  sending,
  completed,
  error,
}

// Enhanced chunked transfer management class
class ChunkedTransfer {
  final File file;
  final String filename;
  final int fileSize;
  final String fileHash;
  final int chunkSize;
  final int totalChunks;

  final Set<int> _sentChunks = {};
  final Set<int> _acknowledgedChunks = {};
  final Set<int> _errorChunks = {};
  final Map<int, int> _chunkRetryCount = {}; // Track retry count per chunk

  DateTime? _transferStart;
  DateTime? _lastProgressUpdate;
  int _lastBytesTransferred = 0;

  static const int MAX_RETRIES = 3;

  ChunkedTransfer({
    required this.file,
    required this.filename,
    required this.fileSize,
    required this.fileHash,
    required this.chunkSize,
  }) : totalChunks = (fileSize / chunkSize).ceil();

  List<int> getNextChunksToSend(int maxChunks) {
    final chunksToSend = <int>[];

    for (int i = 0; i < totalChunks && chunksToSend.length < maxChunks; i++) {
      // Only send chunks that haven't been sent or acknowledged, and haven't failed permanently
      if (!_sentChunks.contains(i) &&
          !_acknowledgedChunks.contains(i) &&
          !_errorChunks.contains(i)) {
        chunksToSend.add(i);
      }
    }

    return chunksToSend;
  }

// ===========================================================
  Future<Uint8List> getChunkData(int chunkIndex) async {
    final start = chunkIndex * chunkSize;
    final end = (start + chunkSize > fileSize) ? fileSize : start + chunkSize;

    final randomAccessFile = await file.open(mode: FileMode.read);
    await randomAccessFile.setPosition(start);
    final data = await randomAccessFile.read(end - start);
    await randomAccessFile.close();

    return data;
  }

  void markChunkAsSent(int chunkIndex) {
    _sentChunks.add(chunkIndex);
    _transferStart ??= DateTime.now();
  }

  void markChunkAsError(int chunkIndex) {
    _sentChunks.remove(chunkIndex);
    // Don't add to _errorChunks immediately - let retry logic handle it
  }

  void markChunkAsRetry(int chunkIndex) {
    _chunkRetryCount[chunkIndex] = (_chunkRetryCount[chunkIndex] ?? 0) + 1;
    _sentChunks.add(chunkIndex);
  }

  bool shouldRetryChunk(int chunkIndex) {
    final retryCount = _chunkRetryCount[chunkIndex] ?? 0;
    return retryCount < MAX_RETRIES;
  }

  int getRetryCount(int chunkIndex) {
    return _chunkRetryCount[chunkIndex] ?? 0;
  }

  void handleChunkAck(int chunkIndex, bool success) {
    if (success) {
      _acknowledgedChunks.add(chunkIndex);
      _errorChunks.remove(chunkIndex);
      _chunkRetryCount.remove(chunkIndex); // Clear retry count on success
      print('✅ Chunk $chunkIndex acknowledged (${_acknowledgedChunks.length}/${totalChunks})');
    } else {
      _sentChunks.remove(chunkIndex);
      // Only mark as permanently failed if we've exceeded retry limit
      if (!shouldRetryChunk(chunkIndex)) {
        _errorChunks.add(chunkIndex);
        print('❌ Chunk $chunkIndex permanently failed after ${getRetryCount(chunkIndex)} retries');
      } else {
        print('⚠️ Chunk $chunkIndex failed, will retry (attempt ${getRetryCount(chunkIndex) + 1}/${MAX_RETRIES})');
      }
    }
  }

  double getProgress() {
    if (totalChunks == 0) return 0.0;
    return _acknowledgedChunks.length / totalChunks;
  }

  int getBytesTransferred() {
    return _acknowledgedChunks.length * chunkSize;
  }

  double getTransferSpeed() {
    if (_transferStart == null) return 0.0;

    final now = DateTime.now();
    final duration = now.difference(_transferStart!);
    final bytesTransferred = getBytesTransferred();

    if (duration.inSeconds > 0) {
      return bytesTransferred / duration.inSeconds;
    }
    return 0.0;
  }

  Duration getETA() {
    final speed = getTransferSpeed();
    if (speed <= 0) return Duration.zero;

    final remainingBytes = fileSize - getBytesTransferred();
    final secondsRemaining = remainingBytes / speed;

    return Duration(seconds: secondsRemaining.round());
  }

  bool isCompleted() {
    final isComplete = _acknowledgedChunks.length == totalChunks;
    if (isComplete) {
      print('🎉 Transfer completed: ${_acknowledgedChunks.length}/${totalChunks} chunks acknowledged');
    }
    return isComplete;
  }

  bool hasFailed() {
    // More conservative failure detection
    final failedChunks = _errorChunks.length;
    final totalFailed = failedChunks > (totalChunks * 0.3); // 30% failure threshold

    if (totalFailed) {
      print('💥 Transfer failed: $failedChunks permanently failed chunks (${(failedChunks/totalChunks*100).toStringAsFixed(1)}%)');
    }

    return totalFailed;
  }

  bool hasMoreChunksToSend() {
    // Check if there are chunks that need to be sent or retried
    for (int i = 0; i < totalChunks; i++) {
      if (!_acknowledgedChunks.contains(i) && !_errorChunks.contains(i)) {
        return true;
      }
    }
    return false;
  }

// Add method to get transfer statistics
  Map<String, dynamic> getTransferStats() {
    return {
      'total_chunks': totalChunks,
      'acknowledged': _acknowledgedChunks.length,
      'sent': _sentChunks.length,
      'error': _errorChunks.length,
      'pending': totalChunks - _acknowledgedChunks.length - _errorChunks.length,
      'progress': getProgress(),
      'bytes_transferred': getBytesTransferred(),
      'transfer_speed': getTransferSpeed(),
    };
  }}