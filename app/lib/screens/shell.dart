import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'discover.dart';
import 'feed.dart';
import 'inbox.dart';
import 'live.dart';
import 'profile.dart';
import 'upload.dart';

/// Main navigation shell: Home / Discover / Upload / Inbox / Me —
/// plus a LIVE entry point in the Home app bar.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const FeedScreen(),
      const DiscoverScreen(),
      const UploadScreen(),
      const InboxScreen(),
      const ProfileScreen(self: true),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.black,
        selectedItemColor: const Color(0xFFFFC107),
        unselectedItemColor: Colors.white54,
        type: BottomNavigationBarType.fixed,
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Discover'),
          BottomNavigationBarItem(icon: Icon(Icons.add_box_outlined), label: 'Upload'),
          BottomNavigationBarItem(icon: Icon(Icons.inbox_outlined), label: 'Inbox'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'Me'),
        ],
      ),
    );
  }
}

/// Small LIVE entry button used on the Home app bar.
class LiveEntryButton extends StatelessWidget {
  const LiveEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) => IconButton(
        tooltip: 'LIVE',
        icon: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.radio_button_checked, color: Colors.redAccent, size: 16),
            SizedBox(width: 4),
            Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LiveListScreen())),
      ),
    );
  }
}
