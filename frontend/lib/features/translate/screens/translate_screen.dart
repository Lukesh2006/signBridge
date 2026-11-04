import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import '../../../core/services/camera_frame_converter.dart';

import '../../auth/providers/auth_provider.dart';
import '../providers/translation_provider.dart';
import '../../../core/services/websocket_service.dart';
import 'personal_signs_screen.dart';

class TranslateScreen extends StatefulWidget {
  const TranslateScreen({super.key, this.webSocketService});

  final WebSocketService? webSocketService;

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  int _selectedCamera = 0;

  late final WebSocketService _wsService;
  final FlutterTts _tts = FlutterTts();

  bool _cameraInitialized = false;
  bool _isStreaming = false;
  bool _webRecognitionRunning = false;
  bool _isSpeaking = false;
  bool _apiServerReachable = false;
  Timer? _apiHealthTimer;
  String _recognitionStage = 'Waiting for camera';
  String _signalSummary = 'No clip analyzed yet';
  String _modelReadout = 'Waiting for a sign';
  String _statusMessage = 'Camera not started';
  double _confidence = 0;
  Future<void> _cameraTask = Future<void>.value();
  Future<void>? _webRecognitionTask;
  int _cameraOperations = 0;
  bool _cameraActive = true;
  final Stopwatch _frameClock = Stopwatch()..start();

  // Inference Configuration
  String _inferenceMode = 'hybrid'; // frames, video, hybrid

  // Frame Throttling
  int? _lastFrameTime;
  static const int _frameIntervalMs = 80; // ~12 FPS
  final List<String> _continuousWords = [];
  String _lastContinuousLabel = '';

  // static const primaryColor = Color(0xFF2B2D5D);
  // static const accentColor = Color(0xFF4B6CF7);

  @override
  void initState() {
    super.initState();
    _wsService = widget.webSocketService ?? WebSocketService();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _loadCameras();
    _setupWebSocket();
    if (kIsWeb) {
      unawaited(_refreshApiHealth());
      _apiHealthTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_refreshApiHealth()),
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final token = context.read<AuthProvider>().token ?? '';
        _wsService.connect(token);
      });
    }
  }

  Future<void> _refreshApiHealth() async {
    final apiBase = dotenv.env['API_BASE_URL'];
    if (apiBase == null || apiBase.isEmpty) return;
    var reachable = false;
    try {
      final response = await http
          .get(Uri.parse('$apiBase/'))
          .timeout(const Duration(seconds: 3));
      reachable = response.statusCode == 200;
    } catch (_) {
      reachable = false;
    }
    if (!mounted || reachable == _apiServerReachable) return;
    setState(() => _apiServerReachable = reachable);
    context.read<TranslationProvider>().setConnected(reachable);
  }

  void _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    if (!mounted) return;
    _tts.setStartHandler(() {
      if (mounted) setState(() => _isSpeaking = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
  }

  // Native camera operations must finish in order, including disposal.
  Future<void> _queueCameraOperation(Future<void> Function() action) {
    _cameraOperations++;
    if (mounted) setState(() {});
    _cameraTask = _cameraTask.then((_) => action()).catchError((Object error) {
      if (mounted) {
        setState(() => _statusMessage = 'Camera error: $error');
      }
    }).whenComplete(() {
      _cameraOperations--;
      if (mounted) setState(() {});
    });
    return _cameraTask;
  }

  Future<void> _loadCameras() async {
    try {
      final cameras = await availableCameras();
      if (!mounted) return;
      _cameras = cameras;
      if (_cameras.isEmpty) {
        setState(() => _statusMessage =
            'No camera found. In Chrome, allow camera access for this site and select vivo Virtual Camera; then refresh the camera list.');
        return;
      }
      await _queueCameraOperation(() => _initCamera(_cameras[_selectedCamera]));
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  Future<void> _refreshCameraList() async {
    if (_cameraOperations != 0 || !_cameraActive) return;
    setState(() {
      _cameraInitialized = false;
      _statusMessage = 'Searching for cameras…';
    });
    await _queueCameraOperation(() async {
      await _releaseCamera();
      try {
        final cameras = await availableCameras();
        if (!mounted || !_cameraActive) return;
        _cameras = cameras;
        if (_cameras.isEmpty) {
          setState(() => _statusMessage =
              'No camera found. Turn on vivo Virtual Camera, allow Chrome camera access, then tap Refresh camera list.');
          return;
        }
        _selectedCamera = _selectedCamera.clamp(0, _cameras.length - 1).toInt();
        await _initCamera(_cameras[_selectedCamera]);
      } catch (error) {
        if (mounted) {
          setState(() => _statusMessage =
              'Camera could not start: $error. Reconnect vivo Virtual Camera and tap Refresh camera list.');
        }
      }
    });
  }

  Future<void> _releaseCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    _cameraInitialized = false;
    _isStreaming = false;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } finally {
      await controller.dispose();
    }
  }

  Future<void> _initCamera(CameraDescription cam) async {
    await _releaseCamera();
    if (!mounted || !_cameraActive) return;
    final controller = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    _cameraController = controller;
    try {
      await controller.initialize();
      if (!mounted || !_cameraActive) return;
      setState(() {
        _cameraInitialized = true;
        _statusMessage = 'Camera ready. Tap Start to begin.';
      });
    } catch (_) {
      await _releaseCamera();
      rethrow;
    }
  }

  void _setupWebSocket() {
    _wsService.onTranslation = (label, confidence) {
      if (!mounted) return;
      setState(() {
        _confidence = confidence;
      });
      context.read<TranslationProvider>().updateTranslation(label);
    };

    _wsService.onConnectionChange = (connected) {
      if (!mounted) return;
      context.read<TranslationProvider>().setConnected(connected);
      if (connected) _wsService.sendConfig(_inferenceMode);
      setState(() {
        _statusMessage = connected
            ? (_isStreaming
                ? 'Connected to server. Streaming...'
                : 'Connected to server. Ready.')
            : 'Disconnected';
      });
    };

    _wsService.onError = (err) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Error: $err');
    };
  }

  Future<void> _startStreaming() {
    if (kIsWeb) {
      // Keep the rolling recorder outside the serialized camera-operation
      // queue so the Stop button remains usable while a clip is analyzed.
      final task = _cameraTask.then((_) => _startCameraStream());
      _webRecognitionTask = task;
      return task.whenComplete(() => _webRecognitionTask = null);
    }
    return _queueCameraOperation(_startCameraStream);
  }

  Future<void> _startCameraStream() async {
    final controller = _cameraController;
    if (!mounted ||
        !_cameraActive ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isStreamingImages) {
      return;
    }
    if (kIsWeb) {
      await _startWebContinuousRecognition(controller);
      return;
    }
    if (!_wsService.isConnected) {
      setState(() => _statusMessage = 'Connect to the server before starting.');
      return;
    }
    _lastFrameTime = null;
    await controller.startImageStream((CameraImage image) {
      if (!mounted ||
          !_cameraActive ||
          !_isStreaming ||
          controller != _cameraController ||
          !_wsService.isConnected) {
        return;
      }
      final now = _frameClock.elapsedMilliseconds;
      if (_lastFrameTime != null && now - _lastFrameTime! < _frameIntervalMs) {
        return;
      }
      _lastFrameTime = now;
      try {
        _wsService.sendFrame(CameraFrameConverter.toJpeg(image));
      } catch (e) {
        // Stop a broken stream instead of silently showing "Analyzing" forever.
        setState(() {
          _isStreaming = false;
          _statusMessage = 'Frame conversion failed: $e';
        });
        unawaited(_queueCameraOperation(_stopCameraStream));
      }
    });
    if (!mounted || !_cameraActive) return;
    setState(() {
      _isStreaming = true;
      _statusMessage = 'Streaming to server...';
    });
  }

  Future<void> _startWebContinuousRecognition(
    CameraController controller,
  ) async {
    await _refreshApiHealth();
    if (!_apiServerReachable) {
      setState(() {
        _recognitionStage = 'Server offline';
        _statusMessage =
            'Recognition server is not reachable. Start it and retry.';
      });
      return;
    }
    final auth = context.read<AuthProvider>();
    final token = auth.token ?? '';
    if (token.isEmpty) {
      setState(() => _statusMessage = 'Please sign in before translating.');
      return;
    }
    final apiBase = dotenv.env['API_BASE_URL'];
    if (apiBase == null || apiBase.isEmpty) {
      setState(
          () => _statusMessage = 'Local recognition server is not configured.');
      return;
    }

    _continuousWords.clear();
    _lastContinuousLabel = '';
    _webRecognitionRunning = true;
    context.read<TranslationProvider>().clearCurrentTranslation();
    setState(() {
      _isStreaming = true;
      _confidence = 0;
      _recognitionStage = 'Capturing camera';
      _signalSummary = 'Waiting for an 8-frame sample';
      _modelReadout = 'Waiting for a sign';
      _statusMessage =
          'Continuous mode: make one sign at a time. Building phrase…';
    });

    final uri = Uri.parse('$apiBase/me/signs/predict');
    while (mounted &&
        _cameraActive &&
        _isStreaming &&
        controller == _cameraController) {
      try {
        if (mounted) {
          setState(() => _recognitionStage = 'Capturing camera clip…');
        }
        await controller.startVideoRecording();
        await Future<void>.delayed(const Duration(seconds: 2));
        final clip = await controller.stopVideoRecording();
        if (!mounted || !_isStreaming || controller != _cameraController) break;

        setState(() => _recognitionStage = 'Finding body, hands and face…');

        final response = await http
            .post(
              uri,
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/octet-stream',
              },
              body: await clip.readAsBytes(),
            )
            .timeout(const Duration(seconds: 25));
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode != 200) {
          throw Exception(
              data['error'] ?? data['detail'] ?? 'Recognition request failed');
        }

        final accepted = data['accepted'] == true;
        final label = data['label']?.toString() ?? '';
        final confidence = (data['confidence'] as num?)?.toDouble() ?? 0;
        final signals =
            (data['signals'] as Map?)?.cast<String, dynamic>() ?? {};
        final frames = signals['frames_analyzed'] ?? 0;
        final bodyFrames = signals['body_frames'] ?? 0;
        final handFrames = signals['hands_frames'] ?? 0;
        final faceFrames = signals['face_frames'] ?? 0;
        final candidate = data['suggestion']?.toString() ?? '';
        final detectedName =
            candidate.isEmpty ? 'none' : _displaySignLabel(candidate);
        if (accepted && label.isNotEmpty) {
          if (label != _lastContinuousLabel) {
            _continuousWords.add(_displaySignLabel(label));
            _lastContinuousLabel = label;
            context.read<TranslationProvider>().updateTranslation(
                  _continuousWords.join(' '),
                );
          }
          setState(() {
            _confidence = confidence;
            _signalSummary =
                '$frames frames • body $bodyFrames/$frames • hands $handFrames/$frames • face $faceFrames/$frames';
            _modelReadout =
                '$detectedName • ${(confidence * 100).toStringAsFixed(0)}% • MATCH';
            _recognitionStage = 'Sign matched';
            _statusMessage =
                'Detected ${_displaySignLabel(label)}. Continue signing…';
          });
        } else {
          // An uncertain/no-sign window releases the duplicate guard so the
          // same word can be signed again after a short pause.
          _lastContinuousLabel = '';
          setState(() {
            _signalSummary =
                '$frames frames • body $bodyFrames/$frames • hands $handFrames/$frames • face $faceFrames/$frames';
            _modelReadout = '$detectedName • UNCERTAIN — repeat the sign';
            _recognitionStage = 'Signals found; no safe match';
            _statusMessage = 'Listening for the next clear sign…';
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _recognitionStage = 'Recognition error';
            _modelReadout = error.toString();
            _statusMessage = 'Recognition stopped: $error';
            _isStreaming = false;
          });
        }
      }
    }

    if (mounted) {
      setState(() {
        _isStreaming = false;
        _webRecognitionRunning = false;
        if (_continuousWords.isNotEmpty) {
          _statusMessage = 'Phrase ready. Speaking it aloud…';
        } else if (!_statusMessage.startsWith('Recognition stopped:')) {
          _statusMessage =
              'No clear signs yet. Try a slower sign with hands in frame.';
        }
      });
    }
    if (mounted && _continuousWords.isNotEmpty) {
      await _speak(_continuousWords.join(' '));
    }
    if (mounted && !_cameraActive) {
      unawaited(_queueCameraOperation(_releaseCamera));
    }
  }

  String _displaySignLabel(String label) => switch (label) {
        'all_right' => 'All right',
        'good_morning' => 'Good morning',
        'thank_you' => 'Thank you',
        _ => label.replaceAll('_', ' '),
      };

  Future<void> _stopCameraStream() async {
    _isStreaming = false;
    final controller = _cameraController;
    if (controller != null && controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  Future<void> _stopStreaming() {
    _isStreaming = false;
    return _queueCameraOperation(() async {
      await _stopCameraStream();
      if (mounted)
        setState(() => _statusMessage = 'Stopped. Tap Start to resume.');
    });
  }

  Future<void> _openPersonalSigns() async {
    if (_isStreaming || _webRecognitionRunning) {
      await _stopStreaming();
      while (_webRecognitionRunning && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    _cameraActive = false;
    await _queueCameraOperation(_releaseCamera);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PersonalSignsScreen(
          initialCameras: _cameras,
          initialCameraIndex: _selectedCamera,
        ),
      ),
    );
    if (!mounted) return;
    _cameraActive = true;
    if (_cameras.isNotEmpty) {
      await _queueCameraOperation(() => _initCamera(_cameras[_selectedCamera]));
    }
  }

  Future<void> _speak(String text) async {
    if (text.isEmpty) return;
    await _tts.speak(text);
  }

  Future<void> _saveTranslation() async {
    final translationProvider = context.read<TranslationProvider>();
    final authProvider = context.read<AuthProvider>();
    final current = translationProvider.currentTranslation;
    if (current.isEmpty) return;
    final userId = authProvider.userId ?? 'guest';
    final token = authProvider.token;
    try {
      await translationProvider.saveTranslation(userId, current, token: token);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Translation saved to history!'),
            backgroundColor: Color(0xFF2BB673),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save translation: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _selectCamera(int? cameraIndex) =>
      _queueCameraOperation(() async {
        if (!mounted ||
            !_cameraActive ||
            cameraIndex == null ||
            cameraIndex < 0 ||
            cameraIndex >= _cameras.length ||
            cameraIndex == _selectedCamera) {
          return;
        }

        final wasStreaming = _isStreaming;
        setState(() {
          _cameraInitialized = false;
          _statusMessage = 'Switching camera...';
        });
        _selectedCamera = cameraIndex;
        await _initCamera(_cameras[_selectedCamera]);
        if (wasStreaming && mounted && _cameraActive && _cameraInitialized) {
          await _startCameraStream();
        }
      });

  String _cameraLabel(CameraDescription camera) {
    final name = camera.name.trim();
    if (name.isNotEmpty) return name;
    switch (camera.lensDirection) {
      case CameraLensDirection.front:
        return 'Front camera';
      case CameraLensDirection.back:
        return 'Back camera';
      case CameraLensDirection.external:
        return 'External camera';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cameraActive = true;
      if (_cameras.isNotEmpty) {
        unawaited(_queueCameraOperation(
            () => _initCamera(_cameras[_selectedCamera])));
      }
    } else {
      _cameraActive = false;
      _isStreaming = false;
      if (kIsWeb && _webRecognitionRunning) return;
      unawaited(_queueCameraOperation(_releaseCamera));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _apiHealthTimer?.cancel();
    _cameraActive = false;
    _isStreaming = false;
    _wsService.onTranslation = null;
    _wsService.onConnectionChange = null;
    _wsService.onError = null;
    unawaited(_wsService.disconnect());
    // Chain cleanup after an in-progress start/stop/initialization operation.
    _cameraTask = (_webRecognitionTask ?? _cameraTask)
        .then((_) => _releaseCamera())
        .catchError((Object e) {
      debugPrint('Camera cleanup failed: $e');
    });
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final translationProvider = context.watch<TranslationProvider>();
    final currentTranslation = translationProvider.currentTranslation;
    final serverConnected =
        kIsWeb ? _apiServerReachable : translationProvider.isConnected;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera Preview ──
          if (_cameraInitialized && _cameraController != null)
            Positioned.fill(
              child: CameraPreview(_cameraController!),
            )
          else
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.camera_alt,
                        color: Colors.white54, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      _statusMessage,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed:
                          _cameraOperations == 0 ? _refreshCameraList : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh camera list'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Top Overlay ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8,
                left: 16,
                right: 16,
                bottom: 12,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3), width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color:
                                _isStreaming ? Colors.greenAccent : Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isStreaming ? 'LIVE' : 'OFFLINE',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // Connection indicator
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: serverConnected
                          ? Colors.green.withValues(alpha: 0.3)
                          : Colors.red.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          serverConnected ? Icons.cloud_done : Icons.cloud_off,
                          color: serverConnected
                              ? Colors.greenAccent
                              : Colors.redAccent,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          serverConnected ? 'Server' : 'No Server',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Inference Mode Toggle
                  GestureDetector(
                    onTap: () {
                      final modes = ['frames', 'video', 'hybrid'];
                      final next = modes[
                          (modes.indexOf(_inferenceMode) + 1) % modes.length];
                      setState(() => _inferenceMode = next);
                      _wsService.sendConfig(next);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Mode: ${next.toUpperCase()}'),
                          duration: const Duration(milliseconds: 500),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.blueAccent.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: Colors.blueAccent.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _inferenceMode == 'frames'
                                ? Icons.bolt
                                : _inferenceMode == 'video'
                                    ? Icons.movie
                                    : Icons.auto_awesome,
                            color: Colors.blueAccent,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _inferenceMode.toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Select a camera by its browser/device name. This also
                  // exposes external cameras supplied by phone-link apps.
                  Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.42,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: _cameras.isEmpty
                            ? -1
                            : _selectedCamera < _cameras.length
                                ? _selectedCamera
                                : null,
                        isDense: true,
                        isExpanded: false,
                        dropdownColor: const Color(0xFF25264F),
                        iconEnabledColor: Colors.white,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        hint: Text(
                          _cameras.isEmpty
                              ? 'Search for cameras'
                              : 'Choose camera',
                          style: TextStyle(color: Colors.white),
                        ),
                        onChanged:
                            _cameraOperations == 0 && !_webRecognitionRunning
                                ? (index) => index == -1
                                    ? _refreshCameraList()
                                    : _selectCamera(index)
                                : null,
                        items: _cameras.isEmpty
                            ? const [
                                DropdownMenuItem<int>(
                                  value: -1,
                                  child: Text('Search cameras again'),
                                ),
                              ]
                            : List.generate(_cameras.length, (index) {
                                final camera = _cameras[index];
                                return DropdownMenuItem<int>(
                                  value: index,
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth:
                                          MediaQuery.of(context).size.width *
                                              0.38,
                                    ),
                                    child: Text(
                                      _cameraLabel(camera),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                );
                              }),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (kIsWeb)
            Positioned(
              top: MediaQuery.of(context).padding.top + 62,
              left: 16,
              right: 16,
              child: _buildRecognitionFlow(serverConnected),
            ),

          // ── Bottom Translation Panel ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).padding.bottom + 20,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Translation result box
                  if (currentTranslation.isNotEmpty) ...[
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                            width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'DETECTED',
                                style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5),
                              ),
                              const Spacer(),
                              if (_confidence > 0)
                                Text(
                                  '${(_confidence * 100).toStringAsFixed(0)}%',
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            currentTranslation,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          // Confidence bar
                          if (_confidence > 0) ...[
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: _confidence,
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.2),
                                valueColor: const AlwaysStoppedAnimation(
                                    Colors.greenAccent),
                                minHeight: 4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Action buttons
                    Row(
                      children: [
                        _actionButton(
                          icon: _isSpeaking
                              ? Icons.volume_up
                              : Icons.volume_up_outlined,
                          label: 'Speak',
                          color: const Color(0xFFE67E22),
                          onTap: () => _speak(currentTranslation),
                          isActive: _isSpeaking,
                        ),
                        const SizedBox(width: 8),
                        _actionButton(
                          icon: Icons.save_outlined,
                          label: 'Save',
                          color: const Color(0xFF2BB673),
                          onTap: _saveTranslation,
                        ),
                        const SizedBox(width: 8),
                        _actionButton(
                          icon: Icons.clear,
                          label: 'Clear',
                          color: Colors.red.shade400,
                          onTap: () => context
                              .read<TranslationProvider>()
                              .clearCurrentTranslation(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ] else if (_isStreaming) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Analyzing gestures...',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],

                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed:
                          _cameraOperations == 0 ? _openPersonalSigns : null,
                      icon: const Icon(Icons.sign_language),
                      label: const Text(
                          'Teach it your signs / Personal recognition'),
                      style:
                          TextButton.styleFrom(foregroundColor: Colors.white),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_statusMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ),
                  // Start / Stop button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isStreaming || _webRecognitionRunning
                            ? Colors.red.shade600
                            : const Color(0xFF4B6CF7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 4,
                      ),
                      onPressed: _cameraInitialized &&
                              (_cameraOperations == 0 || _webRecognitionRunning)
                          ? (_isStreaming || _webRecognitionRunning
                              ? _stopStreaming
                              : _startStreaming)
                          : null,
                      icon: Icon(_isStreaming || _webRecognitionRunning
                          ? Icons.stop_circle_outlined
                          : Icons.play_circle_outlined),
                      label: Text(
                        _isStreaming || _webRecognitionRunning
                            ? 'Stop Streaming'
                            : 'Start Translating',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecognitionFlow(bool serverConnected) {
    final analyzed = _signalSummary != 'No clip analyzed yet' &&
        _signalSummary != 'Waiting for an 8-frame sample';
    final matched = _recognitionStage == 'Sign matched';
    final uncertain = _recognitionStage == 'Signals found; no safe match';
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.68),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'SIGN RECOGNITION FLOW',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 7),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [
                _flowChip('CAMERA', _cameraInitialized, Icons.camera_alt),
                _flowChip('BODY', analyzed, Icons.accessibility_new),
                _flowChip('HANDS', analyzed, Icons.back_hand),
                _flowChip('FACE', analyzed, Icons.face),
                _flowChip(
                  'MODEL',
                  matched,
                  matched ? Icons.check_circle : Icons.psychology,
                  warning: uncertain || !serverConnected,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _recognitionStage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: uncertain
                    ? Colors.orangeAccent
                    : matched
                        ? Colors.greenAccent
                        : Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              _signalSummary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
            Text(
              'Model: $_modelReadout',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _flowChip(String label, bool complete, IconData icon,
      {bool warning = false}) {
    final color = warning
        ? Colors.orangeAccent
        : complete
            ? Colors.greenAccent
            : Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 9, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool isActive = false,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? color.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? color : Colors.white.withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isActive ? color : Colors.white, size: 22),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                    color: isActive ? color : Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
