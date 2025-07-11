import 'package:flutter/material.dart';
// screen
import 'package:sinergia/screens/filetranfer.dart';
import 'package:sinergia/screens/clipboard.dart';
import 'package:sinergia/screens/phone.dart';
import 'package:sinergia/screens/sms.dart';
import 'package:sinergia/screens/camera.dart';
import 'package:sinergia/screens/screen.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _selectedIndex = 0;
  bool _isExpanded = true;
  double _sidebarWidth = 280.0;

  static const double _expandedWidth = 280.0;
  static const double _collapsedWidth = 80.0;

  final List<SidebarItem> _sidebarItems = [
    SidebarItem(
      title: "File Transfer",
      icon: Icons.folder_copy_outlined,
      page: const FileTransferPage(),
    ),
    SidebarItem(
      title: "Clipboard Sync",
      icon: Icons.content_paste_outlined,
      page: const ClipboardSyncPage(),
    ),
    SidebarItem(
      title: "Phone Sync",
      icon: Icons.phone_outlined,
      page: const PhoneSyncPage(),
    ),
    SidebarItem(
      title: "SMS History",
      icon: Icons.sms_outlined,
      page: const SmsHistoryPage(),
    ),
    SidebarItem(
      title: "Camera Cast",
      icon: Icons.photo_camera_outlined,
      page: const CameraCastPage(),
    ),
    SidebarItem(
      title: "Screen Cast",
      icon: Icons.cast_outlined,
      page: const ScreenCastPage(),
    ),
  ];

  void _toggleSidebar() {
    setState(() {
      _isExpanded = !_isExpanded;
      _sidebarWidth = _isExpanded ? _expandedWidth : _collapsedWidth;
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
    print('Navigation: Selected ${_sidebarItems[index].title} (index: $index)');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Row(
        children: [
          _buildSidebar(),
          _buildMainContent(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      elevation: 0,
      title: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Colors.orange, Colors.pinkAccent],
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.all(8),
            child: const Icon(Icons.compare_arrows, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Text(
            'Dashboard',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.black.withOpacity(0.8),
            ),
          ),
        ],
      ),
      actions: [
        _buildDeviceInfo(),
        const SizedBox(width: 16),
        _buildConnectionStatus(),
        const SizedBox(width: 40),
        IconButton(
          icon: const Icon(Icons.settings, color: Colors.black54),
          onPressed: () {},
        ),
        const SizedBox(width: 16),
      ],
    );
  }

  Widget _buildDeviceInfo() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.phone_android, size: 18, color: Colors.black87),
          SizedBox(width: 8),
          Text("Galaxy S24", style: TextStyle(fontWeight: FontWeight.w500)),
          SizedBox(width: 12),
          Icon(Icons.battery_charging_full_rounded, color: Color(0xff75a78e), size: 18),
          SizedBox(width: 4),
          Text('40%', style: TextStyle(fontWeight: FontWeight.w500)),
          SizedBox(width: 12),
          Icon(Icons.wifi, color: Colors.blue, size: 18),
          SizedBox(width: 4),
          Text("192.168.1.42", style: TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xff7777cd),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.circle, size: 8, color: Colors.white),
          SizedBox(width: 8),
          Text(
            "Connected",
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      width: _sidebarWidth,
      height: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildSidebarHeader(),
          Expanded(child: _buildSidebarItems()),
          // if (_isExpanded) _buildSidebarFooter(),
        ],
      ),
    );
  }

  Widget _buildSidebarHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        // border: Border(
        //   bottom: BorderSide(color: Colors.grey.shade200, width: 1),
        // ),
      ),
      child: Row(
        children: [
          if (_isExpanded) ...[
            const Icon(Icons.dashboard, color: Color(0xff7777cd), size: 20),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Navigation',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xff7777cd),
                ),
              ),
            ),
          ],
          Spacer(),
          IconButton(
            icon: Icon(
              _isExpanded ? Icons.menu_open : Icons.menu,
              color: const Color(0xff7777cd),
              size: 20,
            ),
            onPressed: _toggleSidebar,
            tooltip: _isExpanded ? 'Collapse' : 'Expand',
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarItems() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _sidebarItems.length,
      itemBuilder: (context, index) {
        final item = _sidebarItems[index];
        final isSelected = _selectedIndex == index;
        
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Tooltip(
            message: _isExpanded ? '' : item.title,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _onItemTapped(index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected 
                        ? const Color(0xff7777cd).withOpacity(0.1) 
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: isSelected 
                        ? Border.all(color: const Color(0xff7777cd).withOpacity(0.2))
                        : null,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        item.icon,
                        color: isSelected ? const Color(0xff7777cd) : Colors.grey.shade600,
                        size: 22,
                      ),
                      if (_isExpanded) ...[
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                              color: isSelected 
                                  ? const Color(0xff7777cd) 
                                  : Colors.grey.shade700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Widget _buildSidebarFooter() {
  //   return AnimatedOpacity(
  //     opacity: _isExpanded ? 1.0 : 0.0,
  //     duration: const Duration(milliseconds: 300),
  //     child: Container(
  //       padding: const EdgeInsets.all(16),
  //       decoration: BoxDecoration(
  //         color: Colors.white,
  //         border: Border(
  //           top: BorderSide(color: Colors.grey.shade200, width: 1),
  //         ),
  //       ),
  //       child: Row(
  //         children: [
  //           CircleAvatar(
  //             radius: 16,
  //             backgroundColor: const Color(0xff7777cd).withOpacity(0.1),
  //             child: const Icon(
  //               Icons.info,
  //               color: Color(0xff7777cd),
  //               size: 18,
  //             ),
  //           ),
  //           const SizedBox(width: 12),
  //           const Expanded(
  //             child: Text(
  //               'About',
  //               style: TextStyle(
  //                 fontSize: 14,
  //                 fontWeight: FontWeight.w500,
  //                 color: Colors.black87,
  //               ),
  //             ),
  //           ),
  //         ],
  //       ),
  //     ),
  //   );
  // }

  Widget _buildMainContent() {
    return Expanded(
      child: Container(
        color: Colors.grey.shade50,
        child: Column(
          children: [
            // Page Title Bar
            // Container(
            //   padding: const EdgeInsets.all(24),
            //   child: Row(
            //     children: [
            //       Icon(
            //         _sidebarItems[_selectedIndex].icon,
            //         color: const Color(0xff7777cd),
            //         size: 24,
            //       ),
            //       const SizedBox(width: 12),
            //       Text(
            //         _sidebarItems[_selectedIndex].title,
            //         style: const TextStyle(
            //           fontSize: 24,
            //           fontWeight: FontWeight.bold,
            //           color: Color(0xff7777cd),
            //         ),
            //       ),
            //     ],
            //   ),
            // ),
            // Page Content
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.1, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: Container(
                      key: ValueKey('page_$_selectedIndex'),
                      width: double.infinity,
                      height: double.infinity,
                      child: _sidebarItems[_selectedIndex].page,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SidebarItem {
  final String title;
  final IconData icon;
  final Widget page;

  const SidebarItem({
    required this.title,
    required this.icon,
    required this.page,
  });
}