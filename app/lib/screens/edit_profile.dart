import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';

/// TikTok-style Edit Profile in Nova dark+gold skin.
///
/// KEEPS (per user spec): Profile photo, Name, Username (+ profile URL + copy),
/// Bio, Pronoun, Links, Change display order (Your orders, Watch history,
/// Subscription — reorderable).
/// REMOVED: AI Self, College, Fundraiser, TikTok Studio.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController _name;
  late TextEditingController _username;
  late TextEditingController _bio;
  late TextEditingController _pronoun;
  late TextEditingController _links;
  late List<String> _displayOrder;
  bool _saving = false;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    final me = context.read<AppState>().me;
    _name = TextEditingController(text: me?.displayName ?? '');
    _username = TextEditingController(text: me?.handle ?? '');
    _bio = TextEditingController(text: me?.bio ?? '');
    _pronoun = TextEditingController();
    _links = TextEditingController();
    // TikTok "Change display order" items (user-specified, reorderable).
    // Load persisted order; fall back to default.
    _displayOrder = ['Your orders', 'Watch history', 'Subscription'];
    _loadDisplayOrder();
  }

  Future<void> _loadDisplayOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('profile_display_order');
    if (saved != null && saved.length == 3 && saved.toSet().containsAll(_displayOrder)) {
      setState(() => _displayOrder = saved);
    }
  }

  Future<void> _saveDisplayOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('profile_display_order', _displayOrder);
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _bio.dispose();
    _pronoun.dispose();
    _links.dispose();
    super.dispose();
  }

  /// Pick a photo from the gallery, upload it to the backend, and persist
  /// the returned URL on the profile. The UI refreshes via AppState's
  /// notifyListeners (this screen watches AppState).
  Future<void> _pickPhoto() async {
    final state = context.read<AppState>();
    final result = await ImagePicker().pickImage(source: ImageSource.gallery);
    final path = result?.path;
    if (path == null || path.isEmpty) return; // user cancelled
    setState(() => _uploadingPhoto = true);
    try {
      await state.uploadAvatar(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile photo updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not upload photo: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _save() async {    setState(() => _saving = true);
    final state = context.read<AppState>();
    try {
      await state.updateProfile(
        displayName: _name.text.trim(),
        handle: _username.text.trim().replaceAll('@', ''),
        bio: _bio.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile updated')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;
    const gold = Color(0xFFFFC107);
    final state = context.watch<AppState>();
    final u = state.me;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        iconTheme: IconThemeData(color: fg),
        title: Text('Edit profile',
            style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: gold))
                : const Text('Save',
                    style: TextStyle(
                        color: gold,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // Profile photo — tap to pick a new one from the gallery.
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: _uploadingPhoto ? null : _pickPhoto,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundColor:
                            isDark ? Colors.white12 : Colors.black12,
                        backgroundImage: (u?.avatarUrl.isNotEmpty ?? false)
                            ? NetworkImage(u!.avatarUrl)
                            : null,
                        child: _uploadingPhoto
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: Color(0xFFFFC107)))
                            : (u?.avatarUrl.isEmpty ?? true)
                                ? Text(
                                    (u?.handle.isNotEmpty ?? false)
                                        ? u!.handle[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                        fontSize: 36, color: fg))
                                : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: gold,
                          ),
                          child: const Icon(Icons.edit,
                              size: 15, color: Colors.black),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text('Edit photo or avatar',
                    style: TextStyle(color: sub, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Field(
              label: 'Name',
              controller: _name,
              fg: fg,
              sub: sub,
              hint: 'Your display name'),
          _Field(
              label: 'Username',
              controller: _username,
              fg: fg,
              sub: sub,
              hint: 'username',
              prefix: '@'),
          // Profile URL + copy (TikTok style).
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text('user.novamail.store/${_username.text}',
                      style: TextStyle(color: sub, fontSize: 13)),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(
                        text: 'https://user.novamail.store/${_username.text}'));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Profile link copied')));
                    }
                  },
                  icon: const Icon(Icons.copy, size: 14, color: gold),
                  label: const Text('Copy',
                      style: TextStyle(color: gold, fontSize: 13)),
                ),
              ],
            ),
          ),
          _SectionTitle('Basic info', sub),
          _Field(
              label: 'Bio',
              controller: _bio,
              fg: fg,
              sub: sub,
              hint: 'Tell people about yourself',
              maxLines: 3),
          _Field(
              label: 'Pronoun',
              controller: _pronoun,
              fg: fg,
              sub: sub,
              hint: 'e.g. he/him, she/her, they/them'),
          _Field(
              label: 'Links',
              controller: _links,
              fg: fg,
              sub: sub,
              hint: 'Add a link'),
          _SectionTitle('Change display order', sub),
          Text('Drag to reorder how these appear on your profile',
              style: TextStyle(color: sub, fontSize: 12)),
          const SizedBox(height: 8),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: (oldIndex, newIndex) {
              // onReorderItem already adjusts newIndex for the removed item.
              setState(() {
                final item = _displayOrder.removeAt(oldIndex);
                _displayOrder.insert(newIndex, item);
              });
              _saveDisplayOrder();
            },
            children: [
              for (final item in _displayOrder)
                ListTile(
                  key: ValueKey(item),
                  contentPadding: EdgeInsets.zero,
                  title: Text(item,
                      style: TextStyle(color: fg, fontSize: 15)),
                  trailing: Icon(Icons.drag_handle, color: sub),
                ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final Color sub;
  const _SectionTitle(this.title, this.sub);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(title,
          style: TextStyle(
              color: sub, fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final Color fg;
  final Color sub;
  final String hint;
  final String? prefix;
  final int maxLines;
  const _Field({
    required this.label,
    required this.controller,
    required this.fg,
    required this.sub,
    required this.hint,
    this.prefix,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: TextStyle(color: fg),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: sub),
              prefixText: prefix,
              prefixStyle: TextStyle(color: sub),
              filled: true,
              fillColor: isDark ? const Color(0xFF161616) : Colors.black12,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}
