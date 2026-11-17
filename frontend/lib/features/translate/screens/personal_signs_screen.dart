import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../../core/services/session_guard.dart';
import '../../auth/providers/auth_provider.dart';

class PersonalSignsScreen extends StatefulWidget {
  const PersonalSignsScreen({
    super.key,
    this.initialCameras,
    this.initialCameraIndex = 0,
  });

  final List<CameraDescription>? initialCameras;
  final int initialCameraIndex;

  @override
  State<PersonalSignsScreen> createState() => _PersonalSignsScreenState();
}

class _PersonalSignsScreenState extends State<PersonalSignsScreen> {
  CameraController? _camera;
  List<CameraDescription> _cameras = [];
  int _selectedCamera = 0;
  Map<String, dynamic> _samples = {};
  Map<String, dynamic> _details = {};
  bool _busy = false;
  bool _cameraLoading = true;
  String _status = 'Preparing camera…';
  String _result = '';

  String get _baseUrl => dotenv.env['API_BASE_URL']!;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadSamples();
    final supplied = widget.initialCameras;
    if (supplied != null && supplied.isNotEmpty) {
      _cameras = List<CameraDescription>.from(supplied);
      _selectedCamera =
          widget.initialCameraIndex.clamp(0, _cameras.length - 1).toInt();
      try {
        await _openCamera(_selectedCamera);
        if (mounted) setState(() => _cameraLoading = false);
        return;
      } catch (_) {
        // The virtual camera may have changed while the first screen closed.
        // Refresh the browser's device list and try every available camera.
      }
    }
    await _refreshCameras();
  }

  Future<void> _refreshCameras() async {
    if (_busy) return;
    if (mounted) {
      setState(() {
        _cameraLoading = true;
        _status = 'Searching for available cameras…';
      });
    }
    final old = _camera;
    _camera = null;
    await old?.dispose();
    try {
      final cameras = await availableCameras();
      _cameras = cameras;
      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _status = _cameraHelpText;
            _cameraLoading = false;
          });
        }
        return;
      }
      final firstTry =
          widget.initialCameraIndex.clamp(0, _cameras.length - 1).toInt();
      final order = <int>[
        firstTry,
        ...List<int>.generate(_cameras.length, (index) => index)
            .where((index) => index != firstTry),
      ];
      Object? lastError;
      for (final index in order) {
        try {
          _selectedCamera = index;
          await _openCamera(index);
          if (mounted) setState(() => _cameraLoading = false);
          return;
        } catch (error) {
          lastError = error;
        }
      }
      if (mounted) {
        setState(() {
          _cameraLoading = false;
          _status =
              'Camera was listed but could not start: $lastError\n\n$_cameraHelpText';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _cameraLoading = false;
          _status = 'Camera scan failed: $error\n\n$_cameraHelpText';
        });
      }
    }
  }

  static const String _cameraHelpText =
      'In Chrome, open the site controls beside the address bar → Site settings → Camera → Allow. Select vivo Virtual Camera as Chrome’s camera, reload this page, then tap Refresh cameras.';

  Future<void> _openCamera(int index) async {
    final previous = _camera;
    _camera = null;
    await previous?.dispose();
    if (!mounted) return;
    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _camera = controller;
    try {
      await controller.initialize();
    } catch (_) {
      if (identical(_camera, controller)) _camera = null;
      await controller.dispose();
      rethrow;
    }
    if (mounted) setState(() => _status = 'Camera ready.');
  }

  Map<String, String> _headers() {
    final token = context.read<AuthProvider>().token ?? '';
    return {'Authorization': 'Bearer $token'};
  }

  /// Signs the user out if the server rejected the login this request sent.
  http.Response _checked(http.Response response) {
    SessionGuard.check(response);
    return response;
  }

  Future<void> _loadSamples() async {
    try {
      final response = _checked(await http.get(
        Uri.parse('$_baseUrl/me/signs/samples'),
        headers: _headers(),
      ));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _samples = Map<String, dynamic>.from(data['samples'] as Map);
          _details = Map<String, dynamic>.from(data['details'] as Map? ?? {});
        });
      }
    } catch (_) {
      // The camera page can still open when the local API is offline.
    }
  }

  static String _kindNote(Object? kind) => kind == 'custom_gesture'
      ? 'personal gesture — not standard ISL'
      : kind == 'isl'
          ? 'starter ISL sign'
          : 'your way of an ISL sign';

  static String _readable(String label) =>
      label.replaceAll('_', ' ').toUpperCase();

  Future<XFile?> _recordClip() async {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized || _busy)
      return null;
    setState(() {
      _busy = true;
      _status = 'Recording 3-second clip… Keep both hands visible.';
      _result = '';
    });
    try {
      await controller.startVideoRecording();
      await Future<void>.delayed(const Duration(seconds: 3));
      final clip = await controller.stopVideoRecording();
      if (mounted)
        setState(() => _status =
            'Clip ready. Sending only to your local SignBridge server…');
      return clip;
    } catch (error) {
      if (mounted) setState(() => _status = 'Recording failed: $error');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks for a sign name and whether it is an ISL sign or a custom gesture.
  Future<({String label, String kind})?> _askLabel(
      {String title = 'Name this sign', String action = 'Record'}) async {
    final controller = TextEditingController();
    var kind = 'isl_variant';
    return showDialog<({String label, String kind})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'Example: HELLO'),
              ),
              RadioGroup<String>(
                groupValue: kind,
                onChanged: (value) => setDialogState(() => kind = value!),
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      value: 'isl_variant',
                      contentPadding: EdgeInsets.zero,
                      title: Text('My way of an ISL sign'),
                    ),
                    RadioListTile<String>(
                      value: 'custom_gesture',
                      contentPadding: EdgeInsets.zero,
                      title: Text('My own custom gesture'),
                      subtitle: Text('Not shown as standard ISL'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () {
                  final label = controller.text.trim();
                  if (label.isEmpty) return;
                  Navigator.pop(context, (label: label, kind: kind));
                },
                child: Text(action)),
          ],
        ),
      ),
    );
  }

  Future<void> _recordExample() async {
    if (_busy) return;
    final choice = await _askLabel();
    if (choice == null) return;
    final clip = await _recordClip();
    if (clip == null || !mounted) return;
    await _uploadSample(await clip.readAsBytes(), choice.label,
        kind: choice.kind);
  }

  /// Sends a clip through the server's reliability gate. A warning is shown
  /// to the user, and the clip is only saved if they choose "Save anyway".
  Future<void> _uploadSample(Uint8List bytes, String label,
      {String? kind, bool confirm = false}) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = 'Checking this example before saving…';
    });
    Map<String, dynamic>? data;
    try {
      final uri = Uri.parse('$_baseUrl/me/signs/samples').replace(
        queryParameters: {
          'label': label,
          if (kind != null) 'kind': kind,
          if (confirm) 'confirm': 'true',
        },
      );
      final response = _checked(await http.post(uri,
          headers: {
            ..._headers(),
            'Content-Type': 'application/octet-stream',
          },
          body: bytes));
      data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200)
        throw Exception(data['error'] ?? data['detail'] ?? 'Upload failed');
    } catch (error) {
      data = null;
      if (mounted) setState(() => _status = 'Could not save clip: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (data == null || !mounted) return;

    final reasons = List<String>.from(data['reasons'] as List? ?? const []);
    if (data['saved'] == true) {
      await _loadSamples();
      if (!mounted) return;
      final saved = data;
      setState(() => _status =
          'Saved ${saved['label']} example ${saved['samples_for_sign']} (${_kindNote(saved['kind'])}).');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved ${saved['label']} example.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _deleteSample(
              saved['label'] as String, saved['sample_id'] as String),
        ),
      ));
    } else if (data['decision'] == 'needs_confirmation') {
      final saveAnyway = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Check this ${data!['label']} example'),
          content: Text(
              '${reasons.join('\n')}\n\nSave it only if you made the sign the way you meant to.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Discard')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save anyway')),
          ],
        ),
      );
      if (saveAnyway == true) {
        await _uploadSample(bytes, label, kind: kind, confirm: true);
      } else if (mounted) {
        setState(() => _status = 'Example discarded. Nothing was saved.');
      }
    } else {
      setState(() => _status = 'Not saved: ${reasons.join(' ')}');
    }
  }

  Future<void> _deleteSample(String label, String sampleId) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Removing example…';
    });
    try {
      final response = _checked(await http.delete(
          Uri.parse(
              '$_baseUrl/me/signs/samples/${Uri.encodeComponent(label)}/$sampleId'),
          headers: _headers()));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200)
        throw Exception(data['error'] ?? data['detail'] ?? 'Delete failed');
      final model = switch (data['model']) {
        'rebuilt' => ' Your personal model was updated.',
        'removed' =>
          ' Too few examples remain, so the starter model is used until you train again.',
        _ => '',
      };
      if (mounted) setState(() => _status = 'Example removed.$model');
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not remove: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _loadSamples();
  }

  Future<void> _train() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Training the local sign recognizer…';
      _result = '';
    });
    try {
      final response = _checked(await http.post(
          Uri.parse('$_baseUrl/me/signs/train'),
          headers: _headers()));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200)
        throw Exception(data['error'] ?? data['detail'] ?? 'Training failed');
      final validation = data['validation'] as Map<String, dynamic>?;
      final validationText = validation == null
          ? ''
          : ' Isolated-clip check: ${((validation['accuracy'] as num) * 100).round()}% '
              '(${validation['correct']}/${validation['total']}); continuous sentence score not measured.';
      if (mounted) {
        setState(() => _status =
            'Ready: ${data['sign_count']} signs learned from ${data['clip_count']} clips.$validationText');
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not train yet: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recognizeClip() async {
    if (_busy) return;
    final clip = await _recordClip();
    if (clip == null || !mounted) return;
    final bytes = await clip.readAsBytes();
    Map<String, dynamic>? data;
    try {
      setState(() {
        _busy = true;
        _status = 'Checking this clip against your personal signs…';
      });
      final response = _checked(await http.post(
          Uri.parse('$_baseUrl/me/signs/predict'),
          headers: {
            ..._headers(),
            'Content-Type': 'application/octet-stream',
          },
          body: bytes));
      data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200)
        throw Exception(
            data['error'] ?? data['detail'] ?? 'Recognition failed');
      final suggestion = (data['suggestion'] ?? data['label'] ?? '').toString();
      final decision = data['decision'] ??
          (data['accepted'] == true ? 'accepted' : 'rejected');
      // The server's "confidence" is a rescaled match distance, not a
      // probability (a correct sign can score under 50%), so show the decision.
      setState(() {
        _result = switch (decision) {
          'accepted' =>
            '✓ Recognized: ${_readable(suggestion)} · ${_kindNote(data!['kind'])}',
          'confirm' => '? Not sure. Maybe ${_readable(suggestion)}',
          _ => '✗ ${data!['reason'] ?? 'Not recognized.'}'
              '${suggestion.isEmpty ? '' : ' Closest sign: ${_readable(suggestion)}.'}',
        };
        _status = 'Recognition stays on this laptop.';
      });
    } catch (error) {
      data = null;
      if (mounted) setState(() => _status = 'Could not recognize: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (data != null && data['decision'] == 'confirm' && mounted) {
      await _confirmPrediction(bytes, data['suggestion'].toString());
    }
  }

  /// Middle band: the user says whether the guess was right. A confirmed clip
  /// becomes a candidate example and still goes through the reliability gate.
  Future<void> _confirmPrediction(Uint8List bytes, String suggestion) async {
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Was this ${_readable(suggestion)}?'),
        content: const Text(
            'If you confirm, this clip is checked and added to your personal examples.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'no'),
              child: const Text('No')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'other'),
              child: const Text('Different sign')),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'yes'),
              child: const Text('Yes')),
        ],
      ),
    );
    if (!mounted) return;
    if (answer == 'yes') {
      await _uploadSample(bytes, suggestion);
    } else if (answer == 'other') {
      final choice = await _askLabel(
          title: 'Which sign was it?', action: 'Save example');
      if (choice != null) {
        await _uploadSample(bytes, choice.label, kind: choice.kind);
      }
    } else {
      setState(() => _result = 'Not recognized. Please repeat the sign.');
    }
  }

  @override
  void dispose() {
    unawaited(_camera?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _camera;
    return Scaffold(
      appBar: AppBar(title: const Text('Teach it your signs')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: controller != null && controller.value.isInitialized
                  ? CameraPreview(controller)
                  : ColoredBox(
                      color: const Color(0xFF202338),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _cameraLoading
                                    ? Icons.camera_alt
                                    : Icons.videocam_off,
                                color: Colors.white70,
                                size: 40,
                              ),
                              const SizedBox(height: 10),
                              Text(_status,
                                  textAlign: TextAlign.center,
                                  style:
                                      const TextStyle(color: Colors.white70)),
                              if (_cameraLoading) ...[
                                const SizedBox(height: 12),
                                const CircularProgressIndicator(),
                              ] else ...[
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: _refreshCameras,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Refresh cameras'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            value: _cameras.isEmpty ? -1 : _selectedCamera,
            decoration: const InputDecoration(labelText: 'Camera'),
            items: [
              if (_cameras.isEmpty)
                DropdownMenuItem(
                  value: -1,
                  child: Text(_cameraLoading
                      ? 'Searching for cameras…'
                      : 'No camera found — tap to search again'),
                )
              else
                for (var i = 0; i < _cameras.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(_cameras[i].name.isEmpty
                        ? 'Camera ${i + 1}'
                        : _cameras[i].name),
                  )
            ],
            onChanged: _busy || _cameraLoading
                ? null
                : (index) async {
                    if (index == null) return;
                    if (index == -1) {
                      await _refreshCameras();
                      return;
                    }
                    setState(() => _selectedCamera = index);
                    try {
                      await _openCamera(index);
                    } catch (error) {
                      if (mounted) {
                        setState(() => _status =
                            'Camera could not start: $error. Check Chrome camera access, then refresh.');
                      }
                    }
                  },
          ),
          if (!_cameraLoading && _camera == null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _refreshCameras,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh cameras'),
              ),
            ),
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(color: Colors.black54)),
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_result,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _recordExample,
            icon: const Icon(Icons.fiber_manual_record),
            label: const Text('Record a sign example'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _train,
            icon: const Icon(Icons.model_training),
            label: const Text('Train local sign model'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _recognizeClip,
            icon: const Icon(Icons.sign_language),
            label: const Text('Recognize my sign'),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Camera framing',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 6),
                  Text(
                    'For most signs, frame from head to waist so the face is large enough to read; keep both shoulders, elbows and hands visible. For a pointing sign, include the body part you point to and the whole pointing hand. Step back only when the sign needs more space. Use a steady camera at chest or eye height, good light and a plain background.',
                    style: TextStyle(height: 1.4, color: Colors.black54),
                  ),
                  SizedBox(height: 10),
                  Text('Training clips',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 6),
                  Text(
                    'The starter dataset has four signs: HELLO, THANK YOU, ALL RIGHT and GOOD MORNING. The model uses hand and pose landmarks plus facial blendshapes for expression movement. These are sign cues, not labels for a person’s emotional state. Record one sign per clip. Start relaxed, make the sign once, then hold the final pose briefly. For pointing, give each target its own label, such as POINT_HEAD or POINT_CHEST. Save at least 3 clips per sign (5 is better); future samples can personalize the model. Use this page’s camera recording; a screen recording of another app makes the signer too small for reliable learning. The matcher is used on rolling camera clips to build a phrase; it is not yet a validated continuous ISL translator.',
                    style: TextStyle(height: 1.4, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          if (_samples.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Saved examples',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ..._samples.entries.map((entry) {
              final detail = _details[entry.key] as Map<String, dynamic>?;
              final clips = (detail?['samples'] as List? ?? const [])
                  .cast<Map<String, dynamic>>();
              return ExpansionTile(
                leading: const Icon(Icons.video_library_outlined),
                title: Text(entry.key.replaceAll('_', ' ')),
                subtitle: Text(_kindNote(detail?['kind'])),
                trailing: Text('${entry.value} clips'),
                children: [
                  for (var i = 0; i < clips.length; i++)
                    ListTile(
                      dense: true,
                      title: Text('Example ${i + 1}'),
                      subtitle: Text(switch (clips[i]['gate']) {
                        {'confirmed_by_user': true} =>
                          'Saved after your confirmation',
                        Map() => 'Passed the reliability check',
                        _ => 'Saved before reliability checks',
                      }),
                      trailing: IconButton(
                        tooltip: 'Delete this example',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy
                            ? null
                            : () => _deleteSample(
                                entry.key, clips[i]['id'] as String),
                      ),
                    ),
                ],
              );
            }),
          ],
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
