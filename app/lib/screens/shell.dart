import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'feed.dart';
import 'inbox.dart';
import 'live.dart';
import 'market.dart';
import 'profile.dart';
import 'upload.dart';

/// Main navigation shell: Home / Shop / + (create) / Inbox / Profile —
/// plus a LIVE entry point in the Home app bar.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  void _onTap(int i) {
    // Center "+" is a create action, not a tab: open the upload/camera
    // full-screen and keep the current tab selected.
    if (i == 2) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UploadScreen()));
      return;
    }
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const FeedScreen(),
      const MarketplaceScreen(),
      const SizedBox.shrink(), // center "+" opens UploadScreen via _onTap; never shown
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
        onTap: _onTap,
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          const BottomNavigationBarItem(icon: Icon(Icons.storefront), label: 'Shop'),
          BottomNavigationBarItem(
            icon: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.add, color: Colors.black, size: 26),
            ),
            label: '',
          ),
          const BottomNavigationBarItem(icon: Icon(Icons.inbox_outlined), label: 'Inbox'),
          const BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'Profile'),
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
