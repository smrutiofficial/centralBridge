import 'package:flutter/material.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _selectedIndex = 0;

  final List<String> sidebarItems = [
    "File Transfer",
    "Clipboard Sync",
    "Phone Sync",
    "SMS History",
    "Camera Cast",
    "Screen Cast",
  ];

  final List<IconData> sidebarIcons = [
    Icons.folder_copy_outlined,
    Icons.content_paste_outlined,
    Icons.phone_outlined,
    Icons.sms_outlined,
    Icons.photo_camera_outlined,
    Icons.cast_outlined,
  ];

  final List<Widget> pageWidgets = const [
    Center(child: Text("File Transfer Page")),
    Center(child: Text("Clipboard Sync Page")),
    Center(child: Text("Phone Sync Page")),
    Center(child: Text("SMS History Page")),
    Center(child: Text("Camera Cast Page")),
    Center(child: Text("Screen Cast Page")),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // no back button
        backgroundColor: Colors.white,
        title: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Colors.orange, Colors.pinkAccent],
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.compare_arrows, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Text(
              'Dashboard',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black.withOpacity(0.6),
              ),
            ),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color.fromARGB(60, 255, 153, 0),
                  Color.fromARGB(60, 255, 64, 128),
                ],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: const [
                Icon(Icons.phone_android, size: 20),
                SizedBox(width: 6),
                Text("Galaxy S24"),
                SizedBox(width: 12),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: VerticalDivider(width: 1, color: Colors.black54),
                ),
                SizedBox(width: 10),
                Icon(
                  Icons.battery_charging_full_rounded,
                  color: Color(0xff75a78e),
                  size: 20,
                ),
                SizedBox(width: 6),
                Text('40%'),
                SizedBox(width: 12),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: VerticalDivider(width: 1, color: Colors.black54),
                ),
                SizedBox(width: 10),
                Icon(Icons.wifi, color: Colors.blue, size: 20),
                SizedBox(width: 12),
                Text("192.168.1.42"),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
            decoration: BoxDecoration(
              color: Color(0xff7777cd),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: const [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: Colors.white,
                ),
                SizedBox(width: 6),
                Text(
                  "Connected",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 60),
          IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
          const SizedBox(width: 6),
        ],
      ),
      body: SizedBox(
        height: MediaQuery.of(context).size.height - kToolbarHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sidebar
            Container(
              width: 300,
              decoration: BoxDecoration(
                color: Colors.white,
                // border: const Border(
                //   right: BorderSide(color: Colors.grey, width: 0.5),
                // ),
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 16),
                children: List.generate(sidebarItems.length, (index) {
                  final isSelected = index == _selectedIndex;
                  return InkWell(
                    onTap: () => setState(() => _selectedIndex = index),
                    child: Container(
                      margin: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 8,
                      ),
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color:
                            isSelected
                                ? Color(0xff7777cd).withValues(alpha: 0.2)
                                : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            sidebarIcons[index],
                            color: isSelected ? Color(0xff7777cd) : Colors.black87,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              sidebarItems[index],
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                color:
                                    isSelected
                                        ? Color(0xff7777cd)
                                        : Colors.black.withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),

            // Page content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: pageWidgets[_selectedIndex],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
