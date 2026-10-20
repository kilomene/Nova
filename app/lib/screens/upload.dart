import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';
import '../widgets/ai_badge.dart';
import '../widgets/nova_filters.dart';
import 'hashtag.dart';
import 'live.dart';
import '../utils/io_compat.dart';

/// Maximum gallery video length: 2:00 (user spec).
const _maxGalleryVideoSecs = 120;

/// Recording duration presets in seconds (index 0..2). Index 3 = PHOTO, 4 = TEXT.
const _recDurations = [600, 60, 15];
const _durationLabels = ['10m', '60s', '15s', 'PHOTO', 'TEXT'];

// ---------------------------------------------------------------------------
// UploadScreen: CAMERA | CREATE | LIVE tabs.
// ---------------------------------------------------------------------------

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  int _mode = 0; // 0=CAMERA, 1=CREATE, 2=LIVE

  @override
  void initState() {
    super.initState();
    pendingUploadTab.addListener(_onTabRequest);
  }

  @override
  void dispose() {
    pendingUploadTab.removeListener(_onTabRequest);
    super.dispose();
  }

  void _onTabRequest() {
    final t = pendingUploadTab.value;
    if (t >= 0 && mounted) {
      setState(() => _mode = t);
      pendingUploadTab.value = -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_mode == 0)
            const CameraCaptureScreen()
          else if (_mode == 1)
            const CreateEffectsScreen()
          else
            const LiveListScreen(),
          // Bottom mode tabs overlay.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildModeTabs(),
          ),
        ],
      ),
    );
  }

  Widget _buildModeTabs() {
    return Container(
      padding: const EdgeInsets.only(bottom: 24, top: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _modeTab(0, 'CAMERA'),
          const SizedBox(width: 28),
          _modeTab(1, 'CREATE'),
          const SizedBox(width: 28),
          _modeTab(2, 'LIVE'),
        ],
      ),
    );
  }

  Widget _modeTab(int index, String label) {
    final selected = _mode == index;
    return GestureDetector(
      onTap: () => setState(() => _mode = index),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : Colors.white54,
          fontSize: selected ? 15 : 13,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CREATE tab: real filter-effect browser. Tapping an effect selects it and
// jumps to the camera with that filter applied.
// ---------------------------------------------------------------------------

class CreateEffectsScreen extends StatelessWidget {
  const CreateEffectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Create with effects',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('Pick an effect to open the camera with it applied.',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.85,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: NovaFilter.all.length,
              itemBuilder: (context, i) {
                final f = NovaFilter.all[i];
                return GestureDetector(
                  onTap: () {
                    // Jump to the camera tab with this filter pre-selected.
                    pendingCameraFilter.value = f;
                    pendingUploadTab.value = 0;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('Effect "${f.name}" selected'),
                          duration: const Duration(seconds: 1)),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(13),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          NovaFiltered(
                            filter: f,
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFF4A90D9),
                                    Color(0xFF9B59B6),
                                    Color(0xFFE74C3C)
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 10,
                            bottom: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(f.name,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Carries a filter chosen on the CREATE tab into the camera screen.
final ValueNotifier<NovaFilter?> pendingCameraFilter =
    ValueNotifier<NovaFilter?>(null);

/// Requests the UploadScreen switch to the camera tab (0).
final ValueNotifier<int> pendingUploadTab = ValueNotifier<int>(-1);

// ---------------------------------------------------------------------------
// CameraCaptureScreen: REAL live camera via the `camera` package.
// ---------------------------------------------------------------------------

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _initializing = true;
  String? _error;

  NovaFilter _filter = NovaFilter.all[0];
  bool _showFilters = false;
  bool _retouchOn = false;

  double _speed = 1.0; // preview playback speed in the editor
  bool _flashOn = false;
  int? _timerSecs; // null | 3 | 10

  int _durationIndex = 2; // 15s default
  bool _isRecording = false;
  int _recordedSecs = 0;
  Timer? _recordTimer;
  Timer? _countdownTimer;
  int _countdown = 0;

  String _soundLabel = '';
  String _audioKey = '';

  // Subtle beautify matrix (real, visible): lift + warmth + soft contrast.
  static const _retouchMatrix = <double>[
    1.02, 0.02, 0.01, 0, 14,
    0.01, 1.03, 0.01, 0, 10,
    0.01, 0.01, 1.0, 0, 6,
    0, 0, 0, 1, 0,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pendingCameraFilter.addListener(_applyPendingFilter);
    _applyPendingFilter();
    _initCamera();
  }

  void _applyPendingFilter() {
    final f = pendingCameraFilter.value;
    if (f != null && mounted) {
      setState(() => _filter = f);
      pendingCameraFilter.value = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pendingCameraFilter.removeListener(_applyPendingFilter);
    _recordTimer?.cancel();
    _countdownTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera when backgrounded, re-acquire on resume.
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _error = 'No camera found on this device.';
          _initializing = false;
        });
        return;
      }
      // Default to the rear camera.
      _cameraIndex = _cameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _startController(_cameras[_cameraIndex]);
    } catch (e) {
      setState(() {
        _error = 'Camera unavailable: $e';
        _initializing = false;
      });
    }
  }

  Future<void> _startController(CameraDescription desc) async {
    final old = _controller;
    await old?.dispose();
    // Max resolution: uploads keep full quality (user: high-res output).
    final controller = CameraController(
      desc,
      ResolutionPreset.max,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not start camera: $e';
          _initializing = false;
        });
      }
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _initializing = false;
      _flashOn = false;
    });
  }

  bool get _isPhotoMode => _durationIndex == 3;
  bool get _isTextMode => _durationIndex == 4;

  int get _maxRecSecs =>
      _durationIndex < 3 ? _recDurations[_durationIndex] : 15;

  // -- controls --------------------------------------------------------

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _isRecording) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    setState(() => _initializing = true);
    await _startController(_cameras[_cameraIndex]);
  }

  Future<void> _toggleFlash() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final next = !_flashOn;
    try {
      await c.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      setState(() => _flashOn = next);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Flash not available on this camera.')));
      }
    }
  }

  void _cycleTimer() {
    setState(() {
      _timerSecs = _timerSecs == null
          ? 3
          : _timerSecs == 3
              ? 10
              : null;
    });
  }

  void _cycleSpeed() {
    const speeds = [0.5, 1.0, 2.0];
    final i = speeds.indexOf(_speed);
    setState(() => _speed = speeds[(i + 1) % speeds.length]);
  }

  // -- capture ----------------------------------------------------------

  void _onShutter() {
    if (_isTextMode) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TextPostScreen(
          filter: _filter,
          soundLabel: _soundLabel,
          audioKey: _audioKey,
        ),
      ));
      return;
    }
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isRecording) {
      _stopRecording();
      return;
    }
    if (_timerSecs != null) {
      // Real countdown before capture.
      setState(() => _countdown = _timerSecs!);
      _countdownTimer?.cancel();
      _countdownTimer =
          Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _countdown--);
        if (_countdown <= 0) {
          t.cancel();
          setState(() => _countdown = 0);
          _doCapture();
        }
      });
    } else {
      _doCapture();
    }
  }

  Future<void> _doCapture() async {
    if (_isPhotoMode) {
      await _takePhoto();
    } else {
      await _startRecording();
    }
  }

  Future<void> _takePhoto() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _isRecording) return;
    try {
      if (_flashOn) await c.setFlashMode(FlashMode.always);
      final pic = await c.takePicture();
      if (_flashOn) {
        try {
          await c.setFlashMode(FlashMode.torch);
        } catch (_) {}
      }
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PostEditorScreen(
          filePath: pic.path,
          isVideo: false,
          filter: _filter,
          retouchOn: _retouchOn,
          soundLabel: _soundLabel,
          audioKey: _audioKey,
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Photo failed: $e')));
      }
    }
  }

  Future<void> _startRecording() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _isRecording) return;
    try {
      await c.startVideoRecording();
      setState(() {
        _isRecording = true;
        _recordedSecs = 0;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _recordedSecs++);
        if (_recordedSecs >= _maxRecSecs) _stopRecording();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Recording failed: $e')));
      }
    }
  }

  Future<void> _stopRecording() async {
    final c = _controller;
    if (c == null || !_isRecording) return;
    _recordTimer?.cancel();
    setState(() => _isRecording = false);
    try {
      final file = await c.stopVideoRecording();
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PostEditorScreen(
          filePath: file.path,
          isVideo: true,
          filter: _filter,
          retouchOn: _retouchOn,
          soundLabel: _soundLabel,
          audioKey: _audioKey,
          playbackSpeed: _speed,
          recordedSecs: _recordedSecs,
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save video: $e')));
      }
    }
  }

  // -- gallery ------------------------------------------------------------

  Future<void> _pickFromGallery() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1a1a1a),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.videocam_outlined, color: Theme.of(context).colorScheme.primary),
              title: Text('Video (up to 2:00)',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(context).pop('video'),
            ),
            ListTile(
              leading: Icon(Icons.photo_outlined, color: Theme.of(context).colorScheme.primary),
              title: const Text('Photo',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(context).pop('photo'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final picker = ImagePicker();
    try {
      if (choice == 'video') {
        final v = await picker.pickVideo(source: ImageSource.gallery);
        if (v == null || !mounted) return;
        // Enforce the 2:00 maximum on the real file duration.
        final probe = fileVideoController(v.path);
        await probe.initialize();
        final secs = probe.value.duration.inSeconds;
        await probe.dispose();
        if (!mounted) return;
        if (secs > _maxGalleryVideoSecs) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Video is too long — maximum is 2:00. Please pick a shorter one.')));
          return;
        }
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PostEditorScreen(
            filePath: v.path,
            isVideo: true,
            filter: _filter,
            retouchOn: _retouchOn,
            soundLabel: _soundLabel,
            audioKey: _audioKey,
            playbackSpeed: _speed,
            recordedSecs: secs,
          ),
        ));
      } else {
        final p = await picker.pickImage(
            source: ImageSource.gallery); // original quality
        if (p == null || !mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PostEditorScreen(
            filePath: p.path,
            isVideo: false,
            filter: _filter,
            retouchOn: _retouchOn,
            soundLabel: _soundLabel,
            audioKey: _audioKey,
          ),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Gallery pick failed: $e')));
      }
    }
  }

  // -- sound ----------------------------------------------------------------

  Future<void> _openSoundPicker() async {
    final sel = await Navigator.of(context).push<_PickedSound>(
      MaterialPageRoute(builder: (_) => const SoundPickerScreen()),
    );
    if (sel != null && mounted) {
      setState(() {
        _soundLabel = sel.label;
        _audioKey = sel.audioKey;
      });
    }
  }

  // -- build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _buildPreview(),
        _buildTopBar(),
        _buildRightToolbar(),
        _buildBottomArea(),
        if (_countdown > 0) _buildCountdown(),
        if (_isRecording) _buildRecordingBadge(),
      ],
    );
  }

  Widget _buildPreview() {
    Widget child;
    if (_initializing) {
      child = Center(
          child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary));
    } else if (_error != null) {
      child = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white24, size: 56),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Colors.white54, fontSize: 13)),
              SizedBox(height: 12),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Theme.of(context).colorScheme.onPrimary),
                onPressed: _initCamera,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else if (_controller != null && _controller!.value.isInitialized) {
      child = SizedBox.expand(child: CameraPreview(_controller!));
    } else {
      child = const SizedBox.expand();
    }
    // Real filters on the live preview (+ optional retouch layer).
    return NovaFiltered(
      filter: _filter,
      child: _retouchOn
          ? ColorFiltered(
              colorFilter:
                  const ColorFilter.matrix(_retouchMatrix),
              child: child,
            )
          : child,
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 26),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _openSoundPicker,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_note,
                        color: Colors.white, size: 16),
                    const SizedBox(width: 6),
                    Text(
                        _soundLabel.isEmpty ? 'Add sound' : _soundLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(
                  _flashOn ? Icons.flash_on : Icons.flash_off,
                  color: Colors.white,
                  size: 22),
              onPressed: _toggleFlash,
              tooltip: 'Flash',
            ),
            IconButton(
              icon: const Icon(Icons.flip_camera_android,
                  color: Colors.white, size: 22),
              onPressed: _flipCamera,
              tooltip: 'Flip camera',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRightToolbar() {
    return Positioned(
      right: 8,
      top: MediaQuery.of(context).size.height * 0.22,
      child: Column(
        children: [
          _toolButton(
            Icons.timer_outlined,
            _timerSecs == null ? 'Timer' : '${_timerSecs}s',
            _cycleTimer,
            active: _timerSecs != null,
          ),
          _toolButton(Icons.speed, '${_speed}x', _cycleSpeed),
          _toolButton(Icons.tune, 'Filters',
              () => setState(() => _showFilters = !_showFilters),
              active: _showFilters),
          _toolButton(Icons.face_retouching_natural, 'Retouch',
              () => setState(() => _retouchOn = !_retouchOn),
              active: _retouchOn),
        ],
      ),
    );
  }

  Widget _toolButton(IconData icon, String label, VoidCallback onTap,
      {bool active = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Icon(icon,
                color: active ? Theme.of(context).colorScheme.primary : Colors.white, size: 26),
            SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: active ? Theme.of(context).colorScheme.primary : Colors.white,
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomArea() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 70,
      child: Column(
        children: [
          if (_showFilters) ...[
            FilterSelector(
              selected: _filter,
              onSelect: (f) => setState(() => _filter = f),
            ),
            const SizedBox(height: 8),
          ],
          _buildDurationSelector(),
          const SizedBox(height: 10),
          _buildCameraControls(),
        ],
      ),
    );
  }

  Widget _buildDurationSelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_durationLabels.length, (i) {
        final selected = i == _durationIndex;
        return GestureDetector(
          onTap: () => setState(() => _durationIndex = i),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              _durationLabels[i],
              style: TextStyle(
                color: selected ? Theme.of(context).colorScheme.primary : Colors.white60,
                fontSize: selected ? 15 : 13,
                fontWeight:
                    selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildCameraControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // #1 Gallery.
        GestureDetector(
          onTap: _pickFromGallery,
          child: Column(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF2a2a2a),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(Icons.photo_library_outlined,
                    color: Colors.white70),
              ),
              const SizedBox(height: 4),
              const Text('Gallery',
                  style: TextStyle(color: Colors.white60, fontSize: 10)),
            ],
          ),
        ),
        const SizedBox(width: 40),
        // #3 Shutter.
        GestureDetector(
          onTap: _onShutter,
          child: Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
            ),
            child: Center(
              child: _isRecording
                  ? Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5A5A),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    )
                  : Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: _isPhotoMode
                            ? BoxShape.circle
                            : BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFFFF5A5A),
                            Color(0xFFD32F2F)
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: _isPhotoMode
                          ? const Icon(Icons.camera_alt,
                              color: Colors.white, size: 28)
                          : null,
                    ),
            ),
          ),
        ),
        const SizedBox(width: 88), // balance the gallery button
      ],
    );
  }

  Widget _buildCountdown() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Text(
          '$_countdown',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 96,
              fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildRecordingBadge() {
    final max = _maxRecSecs;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 56,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                '${_fmt(_recordedSecs)} / ${_fmt(max)}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Result of the sound picker.
class _PickedSound {
  final String label;
  final String audioKey;
  const _PickedSound(this.label, this.audioKey);
}

// ---------------------------------------------------------------------------
// SoundPickerScreen: real list from /api/sounds + original-audio option.
// Previews play via signed /api/media/url URLs.
// ---------------------------------------------------------------------------

class SoundPickerScreen extends StatefulWidget {
  const SoundPickerScreen({super.key});

  @override
  State<SoundPickerScreen> createState() => _SoundPickerScreenState();
}

class _SoundPickerScreenState extends State<SoundPickerScreen> {
  List<Map<String, dynamic>> _sounds = [];
  bool _loading = true;
  String? _error;
  final _player = AudioPlayer();
  String? _playingKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = context.read<AppState>();
      final r = await state.api.get('/api/sounds');
      final list = (r['sounds'] as List?) ?? [];
      setState(() {
        _sounds = list
            .map((e) => {
                  'label': '${e['sound_label'] ?? 'Untitled'}',
                  'audioKey': '${e['audio_key'] ?? ''}',
                  'uses': e['uses'] ?? 0,
                })
            .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _togglePreview(Map<String, dynamic> s) async {
    final key = s['audioKey'] as String;
    if (_playingKey == key) {
      await _player.stop();
      setState(() => _playingKey = null);
      return;
    }
    try {
      final state = context.read<AppState>();
      final r = await state.api.get('/api/media/url?key=${Uri.encodeComponent(key)}');
      final url = '${r['url']}';
      await _player.stop();
      await _player.play(UrlSource(url));
      setState(() => _playingKey = key);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Preview failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
            icon: Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop()),
        title: Text('Add sound', style: TextStyle(color: Colors.white)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Could not load sounds.\n$_error',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54)),
                      SizedBox(height: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            foregroundColor: Theme.of(context).colorScheme.onPrimary),
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });
                          _load();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.mic_outlined,
                          color: Colors.white70),
                      title: const Text('Original audio',
                          style: TextStyle(color: Colors.white)),
                      subtitle: const Text('No added sound',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 12)),
                      onTap: () => Navigator.of(context)
                          .pop(const _PickedSound('', '')),
                    ),
                    const Divider(color: Colors.white12),
                    if (_sounds.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                            'No sounds yet. Sounds appear here once creators add them.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54)),
                      ),
                    for (final s in _sounds)
                      ListTile(
                        leading: IconButton(
                          icon: Icon(
                            _playingKey == s['audioKey']
                                ? Icons.stop_circle_outlined
                                : Icons.play_circle_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          onPressed: () => _togglePreview(s),
                        ),
                        title: Text('${s['label']}',
                            style:
                                const TextStyle(color: Colors.white)),
                        subtitle: Text('${s['uses']} videos',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                        trailing: const Icon(Icons.chevron_right,
                            color: Colors.white54),
                        onTap: () => Navigator.of(context).pop(_PickedSound(
                            '${s['label']}', '${s['audioKey']}')),
                      ),
                  ],
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// TextPostScreen: TEXT mode — compose styled text, render to a real image,
// continue to the post editor as a photo post.
// ---------------------------------------------------------------------------

class TextPostScreen extends StatefulWidget {
  final NovaFilter filter;
  final String soundLabel;
  final String audioKey;
  const TextPostScreen(
      {super.key,
      required this.filter,
      this.soundLabel = '',
      this.audioKey = ''});

  @override
  State<TextPostScreen> createState() => _TextPostScreenState();
}

class _TextPostScreenState extends State<TextPostScreen> {
  final _text = TextEditingController();
  final _key = GlobalKey();
  int _bgIndex = 0;
  bool _busy = false;

  static const _bgs = [
    [Color(0xFF1a1a2e), Color(0xFF16213e)],
    [Color(0xFF3a1c00), Color(0xFF1a1a1a)],
    [Color(0xFF0f2027), Color(0xFF2c5364)],
    [Color(0xFF200122), Color(0xFF6f0000)],
  ];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_text.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Write something first.')));
      return;
    }
    setState(() => _busy = true);
    try {
      // Render the styled text card to a real PNG file.
      final boundary =
          _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 3.0);
      final bytes =
          await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('render failed');
      final fPath = await writeTempBytes(
          'nova_text_${DateTime.now().millisecondsSinceEpoch}.png',
          bytes.buffer.asUint8List());
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PostEditorScreen(
          filePath: fPath,
          isVideo: false,
          filter: widget.filter,
          retouchOn: false,
          soundLabel: widget.soundLabel,
          audioKey: widget.audioKey,
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create image: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = _bgs[_bgIndex];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop()),
        title: const Text('Text post', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: _busy ? null : _next,
            child: Text(_busy ? '…' : 'Next',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: RepaintBoundary(
                key: _key,
                child: Container(
                  width: MediaQuery.of(context).size.width - 48,
                  height: 420,
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        colors: bg,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Center(
                    child: Text(
                      _text.text.isEmpty ? 'Your text…' : _text.text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _text.text.isEmpty
                            ? Colors.white38
                            : Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Background choices (real — changes the rendered card).
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _bgs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => setState(() => _bgIndex = i),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: _bgs[i]),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: i == _bgIndex ? Theme.of(context).colorScheme.primary : Colors.white24,
                        width: i == _bgIndex ? 2.5 : 1),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _text,
              maxLines: 3,
              maxLength: 280,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Write your text…',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF1a1a1a),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Drafts: saved locally in SharedPreferences as JSON.
// ---------------------------------------------------------------------------

class PostDraft {
  final String id;
  final String filePath;
  final bool isVideo;
  final String filterName;
  final bool retouchOn;
  final String soundLabel;
  final String audioKey;
  final String title;
  final String description;
  final String visibility;
  final bool allowComments;
  final bool isAiGenerated;
  final String audienceControl;
  final bool tagProducts;
  final double playbackSpeed;
  final int savedAt;

  PostDraft({
    required this.id,
    required this.filePath,
    required this.isVideo,
    required this.filterName,
    required this.retouchOn,
    required this.soundLabel,
    required this.audioKey,
    required this.title,
    required this.description,
    required this.visibility,
    required this.allowComments,
    required this.isAiGenerated,
    required this.audienceControl,
    required this.tagProducts,
    required this.playbackSpeed,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'isVideo': isVideo,
        'filterName': filterName,
        'retouchOn': retouchOn,
        'soundLabel': soundLabel,
        'audioKey': audioKey,
        'title': title,
        'description': description,
        'visibility': visibility,
        'allowComments': allowComments,
        'isAiGenerated': isAiGenerated,
        'audienceControl': audienceControl,
        'tagProducts': tagProducts,
        'playbackSpeed': playbackSpeed,
        'savedAt': savedAt,
      };

  factory PostDraft.fromJson(Map<String, dynamic> j) => PostDraft(
        id: '${j['id']}',
        filePath: '${j['filePath']}',
        isVideo: j['isVideo'] == true,
        filterName: '${j['filterName'] ?? 'Normal'}',
        retouchOn: j['retouchOn'] == true,
        soundLabel: '${j['soundLabel'] ?? ''}',
        audioKey: '${j['audioKey'] ?? ''}',
        title: '${j['title'] ?? ''}',
        description: '${j['description'] ?? ''}',
        visibility: '${j['visibility'] ?? 'public'}',
        allowComments: j['allowComments'] != false,
        isAiGenerated: j['isAiGenerated'] == true,
        audienceControl: '${j['audienceControl'] ?? 'everyone'}',
        tagProducts: j['tagProducts'] == true,
        playbackSpeed: (j['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
        savedAt: (j['savedAt'] as num?)?.toInt() ?? 0,
      );
}

class DraftStore {
  static const _key = 'nova_post_drafts_v1';

  static Future<List<PostDraft>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final drafts = list.map(PostDraft.fromJson).toList();
      // Drop drafts whose media file no longer exists.
      final alive = <PostDraft>[];
      for (final d in drafts) {
        if (await pathExists(d.filePath)) alive.add(d);
      }
      if (alive.length != drafts.length) await save(alive);
      alive.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return alive;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<PostDraft> drafts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(drafts.map((d) => d.toJson()).toList()));
  }

  static Future<void> add(PostDraft draft) async {
    final drafts = await load();
    drafts.removeWhere((d) => d.id == draft.id);
    drafts.insert(0, draft);
    await save(drafts.take(20).toList()); // keep max 20
  }

  static Future<void> remove(String id) async {
    final drafts = await load();
    drafts.removeWhere((d) => d.id == id);
    await save(drafts);
  }
}

// ---------------------------------------------------------------------------
// PostEditorScreen: cover, title, description, hashtags/mentions, privacy,
// more options, drafts, post. Everything functional.
// ---------------------------------------------------------------------------

class PostEditorScreen extends StatefulWidget {
  final String filePath;
  final bool isVideo;
  final NovaFilter filter;
  final bool retouchOn;
  final String soundLabel;
  final String audioKey;
  final double playbackSpeed;
  final int recordedSecs;
  // Draft resume values.
  final String? initialTitle;
  final String? initialDescription;
  final String? initialVisibility;
  final bool? initialAllowComments;
  final bool? initialIsAiGenerated;
  final String? initialAudienceControl;
  final bool? initialTagProducts;

  const PostEditorScreen({
    super.key,
    required this.filePath,
    this.isVideo = true,
    required this.filter,
    this.retouchOn = false,
    this.soundLabel = '',
    this.audioKey = '',
    this.playbackSpeed = 1.0,
    this.recordedSecs = 0,
    this.initialTitle,
    this.initialDescription,
    this.initialVisibility,
    this.initialAllowComments,
    this.initialIsAiGenerated,
    this.initialAudienceControl,
    this.initialTagProducts,
  });

  @override
  State<PostEditorScreen> createState() => _PostEditorScreenState();
}

class _PostEditorScreenState extends State<PostEditorScreen> {
  VideoPlayerController? _preview;
  Duration _videoDuration = Duration.zero;

  final _title = TextEditingController();
  final _desc = TextEditingController();

  // Cover frame (video only): timestamp in ms + generated thumbnail bytes.
  double _coverMs = 0;
  Uint8List? _coverBytes;
  bool _coverLoading = false;

  String _visibility = 'public'; // public | friends | private
  bool _allowComments = true;
  bool? _isAiGenerated;
  String _audienceControl = 'everyone'; // everyone | 18+
  bool _tagProducts = false;

  bool _rightsAffirmed = false;
  bool _posting = false;
  bool _mutedPreview = false;

  static const _visLabels = {
    'public': 'Everyone',
    'friends': 'Friends',
    'private': 'Private',
  };

  @override
  void initState() {
    super.initState();
    // Resume draft values when provided.
    if (widget.initialTitle != null) _title.text = widget.initialTitle!;
    if (widget.initialDescription != null) {
      _desc.text = widget.initialDescription!;
    }
    if (widget.initialVisibility != null) {
      _visibility = widget.initialVisibility!;
    }
    if (widget.initialAllowComments != null) {
      _allowComments = widget.initialAllowComments!;
    }
    if (widget.initialIsAiGenerated != null) {
      _isAiGenerated = widget.initialIsAiGenerated;
    }
    if (widget.initialAudienceControl != null) {
      _audienceControl = widget.initialAudienceControl!;
    }
    if (widget.initialTagProducts != null) {
      _tagProducts = widget.initialTagProducts!;
    }
    if (widget.isVideo) {
      _preview = fileVideoController(widget.filePath);
      _preview!.initialize().then((_) {
        if (!mounted) return;
        setState(() {
          _videoDuration = _preview!.value.duration;
        });
        _preview!
          ..setLooping(true)
          ..setPlaybackSpeed(widget.playbackSpeed)
          ..setVolume(_mutedPreview ? 0 : 1)
          ..play();
        _generateCover(0);
      });
    }
  }

  @override
  void dispose() {
    _preview?.dispose();
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  // -- cover ---------------------------------------------------------------

  Future<void> _generateCover(double ms) async {
    if (!widget.isVideo) return;
    setState(() {
      _coverMs = ms;
      _coverLoading = true;
    });
    try {
      final plugin = FcNativeVideoThumbnail();
      final bytes = await plugin.saveThumbnailToBytes(
        srcFile: widget.filePath,
        width: 360,
        height: 360,
        at: FcVideoThumbnailTime(
            ms.toInt(), FcVideoThumbnailTimeUnit.milliseconds),
        quality: 80,
      );
      if (mounted) {
        setState(() {
          _coverBytes = bytes;
          _coverLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _coverLoading = false);
    }
  }

  // -- hashtag / mention insertion ---------------------------------------------

  void _insertAtCursor(String token) {
    final text = _desc.text;
    final sel = _desc.selection;
    final pos = sel.isValid ? sel.baseOffset : text.length;
    final next = '${text.substring(0, pos)}$token${text.substring(pos)}';
    _desc.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: pos + token.length),
    );
  }

  // -- drafts -------------------------------------------------------------------

  Future<void> _saveDraft() async {
    final draft = PostDraft(
      id: 'draft_${DateTime.now().millisecondsSinceEpoch}',
      filePath: widget.filePath,
      isVideo: widget.isVideo,
      filterName: widget.filter.name,
      retouchOn: widget.retouchOn,
      soundLabel: widget.soundLabel,
      audioKey: widget.audioKey,
      title: _title.text.trim(),
      description: _desc.text.trim(),
      visibility: _visibility,
      allowComments: _allowComments,
      isAiGenerated: _isAiGenerated ?? false,
      audienceControl: _audienceControl,
      tagProducts: _tagProducts,
      playbackSpeed: widget.playbackSpeed,
      savedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await DraftStore.add(draft);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved to drafts.')));
    }
  }

  Future<void> _openDrafts() async {
    final draft = await Navigator.of(context).push<PostDraft>(
      MaterialPageRoute(builder: (_) => const DraftsScreen()),
    );
    if (draft == null || !mounted) return;
    // Resume the draft in a fresh editor.
    final filter = NovaFilter.all.firstWhere(
        (f) => f.name == draft.filterName,
        orElse: () => NovaFilter.all[0]);
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => PostEditorScreen(
        filePath: draft.filePath,
        isVideo: draft.isVideo,
        filter: filter,
        retouchOn: draft.retouchOn,
        soundLabel: draft.soundLabel,
        audioKey: draft.audioKey,
        playbackSpeed: draft.playbackSpeed,
        initialTitle: draft.title,
        initialDescription: draft.description,
        initialVisibility: draft.visibility,
        initialAllowComments: draft.allowComments,
        initialIsAiGenerated: draft.isAiGenerated,
        initialAudienceControl: draft.audienceControl,
        initialTagProducts: draft.tagProducts,
      ),
    ));
  }

  // -- post ----------------------------------------------------------------------

  Future<String?> _uploadCover() async {
    // Upload the chosen cover frame; returns the media key ('' if none).
    if (!widget.isVideo || _coverBytes == null || _coverBytes!.isEmpty) {
      return '';
    }
    final coverPath = await writeTempBytes(
        'nova_cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
        _coverBytes!);
    final state = context.read<AppState>();
    final up = await state.api.upload('/api/uploads', coverPath);
    return '${up['key'] ?? ''}';
  }

  Future<void> _post() async {
    if (_posting) return;
    if (_isAiGenerated == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please answer: is this AI-generated?')));
      return;
    }
    if (!_rightsAffirmed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please confirm you own the rights to this content.')));
      return;
    }
    setState(() => _posting = true);
    try {
      final state = context.read<AppState>();
      final caption = _title.text.trim().isEmpty
          ? _desc.text.trim()
          : '${_title.text.trim()}\n${_desc.text.trim()}'.trim();
      final tags = <String>{};
      for (final t in extractHashtags(_desc.text)) {
        tags.add(t);
      }
      for (final t in extractHashtags(_title.text)) {
        tags.add(t);
      }
      final coverKey = await _uploadCover();
      final durationSecs = widget.isVideo
          ? (_videoDuration.inSeconds > 0
              ? _videoDuration.inSeconds.toDouble()
              : widget.recordedSecs.toDouble())
          : 0.0;
      await state.uploadVideo(
        filePath: widget.filePath,
        caption: caption,
        hashtags: tags.toList(),
        soundLabel: widget.soundLabel,
        audioKey: widget.audioKey,
        rightsAffirmed: _rightsAffirmed,
        scanVerdict: '',
        isAiGenerated: _isAiGenerated ?? false,
        visibility: _visibility,
        allowComments: _allowComments,
        audienceControl: _audienceControl,
        tagProducts: _tagProducts,
        coverKey: coverKey ?? '',
        durationSec: durationSecs,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Posted!')));
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (e) {
      final msg =
          e is ApiException ? e.message : 'Upload failed. Please try again.';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  // -- build -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop()),
        title: const Text('New post', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: _openDrafts,
            child: const Text('Drafts',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPreview(),
            const SizedBox(height: 10),
            if (widget.isVideo) _buildCoverPicker(),
            const SizedBox(height: 12),
            // Title.
            TextField(
              controller: _title,
              maxLength: 100,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: 'Add a catchy title',
                hintStyle: TextStyle(color: Colors.white38),
                border: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.primary)),
              ),
            ),
            const SizedBox(height: 8),
            // Description.
            TextField(
              controller: _desc,
              maxLines: 4,
              maxLength: 500,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText:
                    'Write a description… long descriptions get more views on average.',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.primary)),
              ),
            ),
            const SizedBox(height: 8),
            // # and @ buttons.
            Row(
              children: [
                _tagButton('#', () => _insertAtCursor('#')),
                const SizedBox(width: 10),
                _tagButton('@', () => _insertAtCursor('@')),
                const SizedBox(width: 10),
                if (widget.soundLabel.isNotEmpty)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a1a1a),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.music_note,
                              color: Theme.of(context).colorScheme.primary, size: 16),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(widget.soundLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _buildPrivacyRow(),
            const Divider(color: Colors.white12, height: 24),
            _buildMoreOptions(),
            const SizedBox(height: 8),
            AiDeclarationToggle(
              isAiGenerated: _isAiGenerated,
              onChanged: (v) => setState(() => _isAiGenerated = v),
            ),
            CheckboxListTile(
              value: _rightsAffirmed,
              onChanged: (v) =>
                  setState(() => _rightsAffirmed = v ?? false),
              title: Text(
                  'I own or have rights to this content.',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              activeColor: Theme.of(context).colorScheme.primary,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _posting ? null : _saveDraft,
                    icon: const Icon(Icons.drafts_outlined, size: 18),
                    label: const Text('Drafts'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF3B5C),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                    ),
                    onPressed: (_posting ||
                            !_rightsAffirmed ||
                            _isAiGenerated == null)
                        ? null
                        : _post,
                    child: Text(_posting ? 'Posting…' : 'Post',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    Widget media;
    if (widget.isVideo) {
      media = (_preview != null && _preview!.value.isInitialized)
          ? AspectRatio(
              aspectRatio: _preview!.value.aspectRatio,
              child: VideoPlayer(_preview!),
            )
          : SizedBox(
              height: 320,
              child: Center(
                  child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)));
    } else {
      media = Image(image: pathImage(widget.filePath),
          height: 320, width: double.infinity, fit: BoxFit.cover);
    }
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 320,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.cover,
              child: _filtered(media),
            ),
          ),
        ),
        if (widget.isVideo)
          Positioned(
            right: 8,
            bottom: 8,
            child: GestureDetector(
              onTap: () {
                setState(() => _mutedPreview = !_mutedPreview);
                _preview?.setVolume(_mutedPreview ? 0 : 1);
              },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                    color: Colors.black54, shape: BoxShape.circle),
                child: Icon(
                    _mutedPreview ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white,
                    size: 18),
              ),
            ),
          ),
      ],
    );
  }

  Widget _filtered(Widget child) {
    final filtered = NovaFiltered(filter: widget.filter, child: child);
    if (!widget.retouchOn) return filtered;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(
          _CameraCaptureScreenState._retouchMatrix),
      child: filtered,
    );
  }

  Widget _buildCoverPicker() {
    final totalMs = _videoDuration.inMilliseconds.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5),
                color: const Color(0xFF1a1a1a),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: _coverLoading
                    ? Center(
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                color: Theme.of(context).colorScheme.primary, strokeWidth: 2)))
                    : (_coverBytes != null
                        ? Image.memory(_coverBytes!, fit: BoxFit.cover)
                        : const Center(
                            child: Text('Cover',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 11)))),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Cover — drag to pick the frame viewers see first.',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
          ],
        ),
        if (totalMs > 0)
          Slider(
            value: _coverMs.clamp(0, totalMs),
            max: totalMs,
            activeColor: Theme.of(context).colorScheme.primary,
            inactiveColor: Colors.white24,
            onChanged: (v) => _generateCover(v),
          ),
      ],
    );
  }

  Widget _tagButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF1f1f1f),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildPrivacyRow() {
    return GestureDetector(
      onTap: _pickPrivacy,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Icon(
                _visibility == 'public'
                    ? Icons.public
                    : _visibility == 'friends'
                        ? Icons.people_outline
                        : Icons.lock_outline,
                color: Colors.white70,
                size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${_visLabels[_visibility]} can view this post',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  Text(
                      _visibility == 'public'
                          ? 'Visible to everyone'
                          : _visibility == 'friends'
                              ? 'Only mutual followers'
                              : 'Only you',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPrivacy() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1a1a1a),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Who can view this post?',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            _privacyOption('public', Icons.public, 'Everyone',
                'Visible to everyone on Nova'),
            _privacyOption('friends', Icons.people_outline, 'Friends',
                'Only mutual followers can view'),
            _privacyOption('private', Icons.lock_outline, 'Private',
                'Only you can view'),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (v != null && mounted) setState(() => _visibility = v);
  }

  Widget _privacyOption(
      String value, IconData icon, String title, String sub) {
    final sel = _visibility == value;
    return ListTile(
      leading: Icon(icon, color: sel ? Theme.of(context).colorScheme.primary : Colors.white70),
      title: Text(title,
          style: TextStyle(
              color: sel ? Theme.of(context).colorScheme.primary : Colors.white,
              fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
      subtitle:
          Text(sub, style: TextStyle(color: Colors.white54, fontSize: 12)),
      trailing: sel
          ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () => Navigator.of(context).pop(value),
    );
  }

  Widget _buildMoreOptions() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 4),
            child: Text('More options',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          SwitchListTile(
            value: _allowComments,
            onChanged: (v) => setState(() => _allowComments = v),
            title: Text('Allow comments',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            activeThumbColor: Theme.of(context).colorScheme.primary,
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _tagProducts,
            onChanged: (v) => setState(() => _tagProducts = v),
            title: Text('Identify similar products',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text('Let viewers shop similar items',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            activeThumbColor: Theme.of(context).colorScheme.primary,
            contentPadding: EdgeInsets.zero,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Audience control',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
                _audienceControl == 'everyone'
                    ? 'Suitable for everyone'
                    : 'Restricted to 18+',
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white54),
            onTap: _pickAudience,
          ),
        ],
      ),
    );
  }

  Future<void> _pickAudience() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1a1a1a),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Audience control',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            ListTile(
              title: Text('Everyone',
                  style: TextStyle(color: Colors.white)),
              trailing: _audienceControl == 'everyone'
                  ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: () => Navigator.of(context).pop('everyone'),
            ),
            ListTile(
              title: Text('18+ only',
                  style: TextStyle(color: Colors.white)),
              subtitle: Text('Restrict to adult audiences',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              trailing: _audienceControl == '18+'
                  ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: () => Navigator.of(context).pop('18+'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (v != null && mounted) setState(() => _audienceControl = v);
  }
}

// ---------------------------------------------------------------------------
// DraftsScreen: list of locally saved drafts; tap to resume, swipe to delete.
// ---------------------------------------------------------------------------

class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key});

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  List<PostDraft> _drafts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final drafts = await DraftStore.load();
    if (mounted) {
      setState(() {
        _drafts = drafts;
        _loading = false;
      });
    }
  }

  Future<void> _delete(PostDraft d) async {
    await DraftStore.remove(d.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
            icon: Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop()),
        title: Text('Drafts', style: TextStyle(color: Colors.white)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
          : _drafts.isEmpty
              ? const Center(
                  child: Text('No drafts yet.',
                      style: TextStyle(color: Colors.white54)))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _drafts.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final d = _drafts[i];
                    final date = DateTime.fromMillisecondsSinceEpoch(
                        d.savedAt);
                    return Dismissible(
                      key: ValueKey(d.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding:
                            const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.delete,
                            color: Colors.white),
                      ),
                      onDismissed: (_) => _delete(d),
                      child: GestureDetector(
                        onTap: () =>
                            Navigator.of(context).pop<PostDraft>(d),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF141414),
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 64,
                                  height: 64,
                                  child: d.isVideo
                                      ? const Icon(
                                          Icons.videocam_outlined,
                                          color: Colors.white54)
                                      : Image(image: pathImage(d.filePath),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __,
                                                  ___) =>
                                              const Icon(
                                                  Icons.photo_outlined,
                                                  color: Colors
                                                      .white54)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      d.title.isEmpty
                                          ? (d.description.isEmpty
                                              ? 'Untitled draft'
                                              : d.description)
                                          : d.title,
                                      maxLines: 1,
                                      overflow:
                                          TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight:
                                              FontWeight.w600),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${d.isVideo ? 'Video' : 'Photo'} · ${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right,
                                  color: Colors.white54),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
