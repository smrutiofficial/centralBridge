import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
//screens
import 'package:centralbridge/screen/castCameraScreen.dart';
import 'package:centralbridge/screen/castscreen.dart';
import 'package:centralbridge/screen/clipboardsync.dart';
import 'package:centralbridge/screen/fileshare.dart';
import 'package:centralbridge/screen/remoteinput.dart';
import 'package:centralbridge/battery.dart';
// Import your WebSocket manager
import 'package:centralbridge/global_socket_manager.dart';

class DashboardScreen extends StatefulWidget {
  final String serverUrl;
  final Map<String, dynamic> deviceInfo;

  DashboardScreen({required this.serverUrl, required this.deviceInfo});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Map<String, dynamic> _deviceInfo;
  String connectionStatus = "Connecting...";
  String lastMessage = "";
  
  // Stream subscriptions
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  StreamSubscription<String>? _connectionSubscription;

  int _selectedIndex = 2;

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  void initState() {
    super.initState();
    _deviceInfo = Map<String, dynamic>.from(widget.deviceInfo);
    _initializeWebSocket();
  }

  Future<void> _initializeWebSocket() async {
    // Connect to WebSocket using the manager
    await WebSocketManager.instance.connect(widget.serverUrl);
    
    // Set up stream listeners
    _setupStreamListeners();
    
    // Send fingerprint after a short delay
    Future.delayed(Duration(milliseconds: 500), _sendFingerprint);
  }

  void _setupStreamListeners() {
    // Listen to system info messages
    _messageSubscription = WebSocketManager.instance.listenToSystemInfo().listen(
      (data) {
        _handleSystemMessage(data);
      },
      onError: (error) {
        print('System message stream error: $error');
      },
    );

    // Listen to connection status
    _connectionSubscription = WebSocketManager.instance.connectionStream.listen(
      (status) {
        setState(() {
          connectionStatus = status;
          if (status == 'Disconnected') {
            lastMessage = 'Connection lost';
          } else if (status == 'Reconnecting...') {
            lastMessage = 'Reconnecting...';
          }
        });
      },
      onError: (error) {
        print('Connection stream error: $error');
      },
    );
  }

  void _handleSystemMessage(Map<String, dynamic> data) {
    // 🔐 Fingerprint Verification
    if (data['text'] == '[verified]' && data['device_info'] != null) {
      final deviceInfo = Map<String, dynamic>.from(data['device_info']);
      print("✅ Received verified device info: $deviceInfo");

      setState(() {
        _deviceInfo = deviceInfo;
        connectionStatus = "Connected";
        lastMessage = 'System info received.';
      });
    }
    // 🔄 System Info Update Channel
    else if (data['channel'] == 'system_info' && data['device_info'] != null) {
      final deviceInfo = Map<String, dynamic>.from(data['device_info']);
      print("📡 Received periodic update: $deviceInfo");

      setState(() {
        _deviceInfo = deviceInfo;
        lastMessage = 'System info updated.';
      });
    }
    // 💬 Fallback Message
    else {
      setState(() {
        lastMessage = data['text'] ?? 'Unknown';
      });
    }
  }

  Future<void> _sendFingerprint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trusted = prefs.getStringList('trusted_devices') ?? [];

      for (final item in trusted) {
        final device = jsonDecode(item);
        final fingerprint = device['fingerprint'];
        if (fingerprint != null && fingerprint.isNotEmpty) {
          final msg = {
            'fingerprint': fingerprint,
            'text': '[auto-verified]',
            'sender': 'Android',
            'timestamp': DateTime.now().toIso8601String(),
          };
          print("✅ Sending fingerprint: $fingerprint");
          WebSocketManager.instance.sendMessage(msg);
          return;
        }
      }
    } catch (e) {
      print("🔥 Error sending fingerprint: $e");
    }
  }

  @override
  void dispose() {
    // Clean up subscriptions
    _messageSubscription?.cancel();
    _connectionSubscription?.cancel();
    
    // Note: Don't dispose the WebSocket manager here as other screens might be using it
    // Only dispose when the entire app is closing
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _deviceInfo;
    return Scaffold(
      backgroundColor: Color(0xffd7dedb),
      appBar: AppBar(
        automaticallyImplyLeading: false, // <-- This removes the back button
        backgroundColor: Colors.white,
        title:
            Row(children: [
              Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.orange,
                    Colors.pinkAccent,
                  ],
                ),
                borderRadius: BorderRadius.circular(6),),
              padding: EdgeInsets.all(2),
              child: Icon(Icons.compare_arrows,color: Colors.white,),),
              SizedBox(width: 10,),
              Text('Dashboard',style: TextStyle(fontSize: 20,fontWeight: FontWeight.bold,color: Colors.black.withValues(alpha: 0.6)),),
            ] ,),
        

        actions: [
          Icon(Icons.ev_station,color: Color(0xff75a78e),),
          SizedBox(width: 6),
          Container(
            decoration: BoxDecoration(
              color: Color(0xff7777cd).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(7)
            ),
            padding: EdgeInsets.symmetric(vertical: 8,horizontal: 15),
            child: Row(children: [
            Icon(Icons.phone_android,size: 15,),
              BatteryLevelWidget(),
              SizedBox(width: 6),
            Icon(Icons.computer,size: 15,),
            Text('${info['battery'] ?? '-'}'),
          ],),),


          IconButton(
            icon: Icon(Icons.settings),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                // color: Color(0xff75a78e),
                gradient: LinearGradient(
                  colors: [
                    Color(0xffFFBE6F),
                    Color(0xffF66151),
                    Color(0xff7777cd),
                  ],
                ),
                boxShadow: [BoxShadow(color: Colors.grey,blurRadius: 10)],
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                ),
              ),
              padding: EdgeInsets.all(20),
              width: double.infinity,
              margin: EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.computer, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        connectionStatus,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Spacer(),
                      Text("2ms",style: TextStyle(color: Colors.white),),
                      SizedBox(width: 5,),
                      Container(
                        padding: EdgeInsets.all(4),
                        decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.all(Radius.circular(20))),
                        child:Icon(Icons.sync,color: Colors.white,) ,),

                    ],
                  ),
                  SizedBox(height: 5),
                  Text('${info['device_name']}', style: TextStyle(color: Colors.white)),
                  SizedBox(height: 5),
                  Text(
                    '${info['ip'] ?? 'N/A'}${lastMessage.isNotEmpty ? ' • Last: $lastMessage' : ''}',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.grey,blurRadius: 10)],
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(10),
                  bottomRight: Radius.circular(10),
                ),
              ),
              padding: EdgeInsets.symmetric(horizontal: 20,vertical: 12),
              width: double.infinity,
              margin: EdgeInsets.symmetric(horizontal: 20),
              child:
              Row(children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${info['os'] ?? 'Unknown'}',style: TextStyle(fontWeight: FontWeight.bold,fontSize: 16),),
                    Text('CPU: ${info['cpu'] ?? '-'} • RAM: ${info['ram'] ?? '-'}'),
                  ],
                ),
                Spacer(),
                ElevatedButton(
                      onPressed: ()=>{},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Color(0xff7777cd),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6), // <-- No border radius
                        ),
                      ),
                      child: Text("Disconnect",style: TextStyle(color: Colors.white),)),
              ],),


            ),
            SizedBox(height: 20),
            Padding(
              padding: EdgeInsets.only(left: 22),
              child: Align(
                alignment: Alignment.centerLeft,
                child:
                Row(children: [
                  Icon(Icons.attractions,color: Colors.black.withValues(alpha: 0.6),),
                  SizedBox(width: 5,),
                  Text(
                    "Quick Actions",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
                  ),
                ],)

              ),
            ),
            Padding(
              padding: EdgeInsets.all(22),
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 26,
                mainAxisSpacing: 20,
                shrinkWrap: true, // ✅ Important: Makes GridView take only needed height
                physics: NeverScrollableScrollPhysics(), // ✅ Prevent internal scroll
                children: [
                  _quickAction(Icons.camera, 'Cast Camera', "Phone camera to pc", Color(0xff7777cd),
                      () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => CastCameraScreen()),
                    );
                  }),
                  _quickAction(Icons.send, 'File Transfer', "Share files quickly", Color(0xffFFA348),() {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Fileshare(),
                      ),
                    );
                  }),
                  _quickAction(Icons.settings_remote_rounded, 'Remote Input', "Control mouse & keyboard", Color(0xff75a78e),() {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => Remoteinput()),
                    );
                  }),
                  _quickAction(Icons.pending_actions_rounded, 'Clipboard', "Sync text between devices", Color(0xffF66151),() {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => Clipboardsync()),
                    );
                  }),
                  _quickAction(Icons.computer, 'Cast Screen', "Share phone screen to pc", Color(0xffFFA348),() {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => CastScreen()),
                    );
                  }),
                ],
              ),
            ),
          //   Media controller
            Padding(
              padding: EdgeInsets.only(left: 22),
              child: Align(
                alignment: Alignment.centerLeft,
                child:
                Row(children: [
                  Icon(Icons.play_arrow,color: Colors.black.withValues(alpha: 0.6),),
                  SizedBox(width: 5,),
                  Text(
                    "Multimedia Control",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
                  ),
                ],)
              ),
            ),

            SizedBox(height: 20),
          Container(
            width: double.infinity,
            height: 200,
            margin: EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(80), // You can also reduce opacity if needed
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            child: MusicPlayerCard(),
          ),
            SizedBox(height: 15,),
            Row(
              children: [
                SizedBox(width: 22),
                ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xff6f7eaf), // Optional: set background if needed
                      foregroundColor: Colors.white, // ✅ text color
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5), // ✅ rounded corners
                      ),
                    ),
                    child:
                    Row(children: [
                      Icon(Icons.volume_down),
                      SizedBox(width: 5),
                      Text("Volume control"),
                    ])
                ),
                Spacer(),
                ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xfff59b57),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    child: Row(children: [
                      Icon(Icons.devices_other_outlined),
                      SizedBox(width: 5),
                      Text("Devices"),
                    ])
                ),
                SizedBox(width: 22),
              ],
            ),
            SizedBox(height: 20),
          // Scan Document
            SizedBox(height: 20),

            Padding(
              padding: EdgeInsets.only(left: 22),
              child: Align(
                alignment: Alignment.centerLeft,
                child:
                Row(children: [
                  Icon(Icons.document_scanner,color: Colors.black.withValues(alpha: 0.6),),
                  SizedBox(width: 5,),
                  Text(
                    "Scan Document",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
                  ),
                ],),
              ),
            ),
            SizedBox(height: 20),
            Container(
              width: double.infinity,
              height: 200,
              margin: EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                color: Colors.white,
                image: const DecorationImage(
                  image: AssetImage('assets/drawing.png'), // use your image here
                  fit: BoxFit.cover,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(80), // You can also reduce opacity if needed
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ],
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
            ),
            SizedBox(height: 20),
            Row(
              children: [
                SizedBox(width: 22),
                ElevatedButton(
                  onPressed: () {},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Color(0xffcd7778), // Optional: set background if needed
                    foregroundColor: Colors.white, // ✅ text color
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5), // ✅ rounded corners
                    ),
                  ),
                  child:
                  Row(children: [
                    Icon(Icons.image_outlined),
                    SizedBox(width: 5),
                    Text("Gallery"),
                  ])
                ),
                Spacer(),
                ElevatedButton(
                  onPressed: () {},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Color(0xff7777cd),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  child: Row(children: [
                    Icon(Icons.camera_alt_outlined),
                    SizedBox(width: 5),
                    Text("Capture"),
                  ])
                ),
                SizedBox(width: 22),
              ],
            ),
            SizedBox(height: 20),
          // Run Commands
            SizedBox(height: 20),
            Padding(
              padding: EdgeInsets.only(left: 22),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(children: [
                  Icon(Icons.code_rounded,color: Colors.black.withValues(alpha: 0.6),),
                  SizedBox(width: 5,),
                  Text(
                    "Quick Commands",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
                  ),
                ],)
              ),
            ),
            Padding(
              padding: EdgeInsets.all(25),
              child: GridView.count(
                crossAxisCount: 3,
                crossAxisSpacing: 15,
                mainAxisSpacing: 20,
                shrinkWrap: true, // ✅ Important: Makes GridView take only needed height
                physics: NeverScrollableScrollPhysics(), // ✅ Prevent internal scroll
                children: [
                  _quickRun(Icons.update, 'Update', Colors.blueAccent),
                  _quickRun(Icons.delete_forever_outlined, 'Clear Cache', Colors.orange),
                  _quickRun(Icons.coffee, 'Caffeine', Colors.redAccent),
                  _quickRun(Icons.lock, 'Lock', Color(0xff75a78e)),
                  _quickRun(Icons.power_settings_new, 'Shutdown', Colors.redAccent),
                  _quickRun(Icons.sync, 'Reboot', Colors.blueAccent),
                  _quickRun(Icons.logout, 'Logout', Colors.orange),
                ],
              ),
            ),
            // Container(
            //   margin: EdgeInsets.symmetric(horizontal: 22, vertical: 0),
            //   padding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            //   decoration: BoxDecoration(
            //     color: Colors.white,
            //     borderRadius: BorderRadius.circular(8),
            //     boxShadow: [
            //       BoxShadow(
            //         color: Colors.black12,
            //         blurRadius: 2,
            //         offset: Offset(0, 4),
            //       ),
            //     ],
            //   ),
            //   child: Row(
            //     children: [
            //       // Input Box
            //       Expanded(
            //         child: TextField(
            //           decoration: InputDecoration(
            //             hintText: 'Enter command...',
            //             border: InputBorder.none,
            //           ),
            //         ),
            //       ),
            //       Spacer (),
            //       // Terminal Icon
            //       Icon(Icons.terminal, color: Colors.deepPurpleAccent),
            //     ],
            //   ),
            // ),
            // SizedBox(height: 15),
            Row(
              children: [
                SizedBox(width: 22),
                // ElevatedButton(
                //     onPressed: () {},
                //     style: ElevatedButton.styleFrom(
                //       backgroundColor: Color(0xffcd7778), // Optional: set background if needed
                //       foregroundColor: Colors.white, // ✅ text color
                //       shape: RoundedRectangleBorder(
                //         borderRadius: BorderRadius.circular(5), // ✅ rounded corners
                //       ),
                //     ),
                //     child:
                //     Row(children: [
                //       Icon(Icons.image_outlined),
                //       SizedBox(width: 5),
                //       Text("Gallery"),
                //     ])
                // ),
                Spacer(),
                ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xff75a78e),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    child: Row(children: [
                      Icon(Icons.add),
                      SizedBox(width: 5),
                      Text("Quick Add"),
                    ])
                ),
                SizedBox(width: 22),
              ],
            ),
            SizedBox(height: 25),
            //   =======================================================================
          ],
        ),
      ),

      bottomNavigationBar: Container(
        padding: const EdgeInsets.only(top: 5, left: 20, right: 20), // Top and horizontal padding
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, -2),
            )
          ],
        ),
        child:
        Padding(padding: EdgeInsets.symmetric(horizontal: 15,vertical: 15),child:
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _navItem(icon: Icons.file_open_outlined, label: 'Files', index: 0),
            _navItem(icon: Icons.settings_remote, label: 'Remote', index: 1),
            _navItem(icon: Icons.home, label: 'Home', index: 2),
            _navItem(icon: Icons.terminal, label: 'Terminal', index: 3),
            _navItem(icon: Icons.info_outline_rounded, label: 'About', index: 4),
          ],
        )
          ,)
      ),


    );
  }

  Widget _quickAction(IconData icon, String label,String description,Color bcolor, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        padding: EdgeInsets.all(12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(15)),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center, // Align children to the left
        children: [
          Container(
            width: 55,
            height: 55,
            decoration: BoxDecoration(
              color: bcolor.withValues(alpha: 0.15), // fixed from withValues
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            child: Icon(icon, size: 22, color: bcolor),
          ),
          SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(color: Colors.black),
          ),
          SizedBox(height: 3),
          Text(
              description,
            textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black.withValues(alpha: 0.4),fontWeight: FontWeight.w400,fontSize: 12),
          ),

        ],
      ),
    );
  }
// run command widgets
  Widget _quickRun(IconData icon, String label,Color bcolor) {
    return ElevatedButton(
      onPressed: () {},
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        padding: EdgeInsets.all(12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center, // Align children to the left
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: bcolor.withValues(alpha: 0.15), // fixed from withValues
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            child: Icon(icon, size: 22, color: bcolor),
          ),
          SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(color: Colors.black,fontSize: 12),
          ),
        ],
      ),
    );
  }
  Widget _navItem({required IconData icon, required String label, required int index}) {
    final isSelected = _selectedIndex == index;

    return GestureDetector(
      onTap: () => _onItemTapped(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: isSelected ? Color(0xff75a78e) : Colors.grey,
          ),
          SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? Color(0xff75a78e) : Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}


//   media controller
class MusicPlayerCard extends StatelessWidget {
  const MusicPlayerCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 350,
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        image: const DecorationImage(
          image: AssetImage('assets/players_bg.jpg'), // use your image here
          fit: BoxFit.cover,
        ),
      ),
      child: Stack(
        children: [
          // Overlay gradient for better text readability
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: LinearGradient(
                colors: [
                  Colors.black.withValues(alpha: 0.4),
                  Colors.black.withValues(alpha: 0.2),
                ],
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.music_note, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text(
                      'Spotify',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                const Text(
                  'Mann Mera',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text(
                  'Gajendra Verma',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('00:57',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: Colors.orangeAccent,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.orangeAccent,
                        ),
                        child: Slider(
                          value: 57,
                          min: 0,
                          max: 200,
                          onChanged: (_) {},
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('03:20',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [

                    const Icon(Icons.skip_previous,
                        color: Colors.white, size: 30),
                    const Icon(Icons.play_arrow,
                        color: Colors.white, size: 30),
                    const Icon(Icons.skip_next,
                        color: Colors.white, size: 30),

                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}