import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../models/camera.dart';
import '../models/camera_limits.dart';
import '../models/camera_info.dart';
import '../services/camera_info_service.dart';
import 'connection_status.dart';

class CameraEditor extends StatefulWidget {
  const CameraEditor({
    super.key,
    this.camera,
    required this.newCameraId,
    required this.onSave,
    required this.onTest,
    required this.onGetInfo,
    required this.onTestLimits,
    required this.onStopLimits,
  });
  final Camera? camera;
  final int newCameraId;
  final Future<bool> Function(Camera) onSave;
  final Future<bool> Function(Camera) onTest;
  final Future<CameraInfoResult> Function(Camera, CameraInfoOptions) onGetInfo;
  final Future<CameraLimits> Function(Camera) onTestLimits;
  final Future<void> Function() onStopLimits;

  @override
  State<CameraEditor> createState() => _CameraEditorState();
}

class _CameraEditorState extends State<CameraEditor> {
  final _form = GlobalKey<FormState>();
  late final _cameraId = widget.camera?.id ?? widget.newCameraId;
  late CameraLimits? _limits = widget.camera?.limits;
  late CameraInfo? _info = widget.camera?.info;
  final _infoPort = TextEditingController(text: '80');
  final _infoUsername = TextEditingController();
  final _infoPassword = TextEditingController();
  bool _infoHttps = false;
  bool _showInfoConnection = false;
  bool _gettingInfo = false;
  String? _infoMessage;
  final _hostKey = GlobalKey<FormFieldState<String>>();
  final _portKey = GlobalKey<FormFieldState<String>>();
  final _localKey = GlobalKey<FormFieldState<String>>();
  late final _name = TextEditingController(text: widget.camera?.name ?? '');
  late final _host = TextEditingController(text: widget.camera?.host ?? '');
  late final _port = TextEditingController(
    text: '${widget.camera?.port ?? 52381}',
  );
  late final _local = TextEditingController(
    text: '${widget.camera?.localPort ?? 0}',
  );
  late ViscaTransport _transport =
      widget.camera?.transport ?? ViscaTransport.sony;
  late (String, String, String, ViscaTransport) _lastConnectionSettings;
  bool _saving = false;
  bool _testing = false;
  bool _connected = false;
  bool _testingLimits = false;
  bool get _busy => _saving || _testing || _testingLimits || _gettingInfo;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lastConnectionSettings = (_host.text, _port.text, _local.text, _transport);
    for (final field in [_host, _port, _local]) {
      field.addListener(_connectionChanged);
    }
    if (widget.camera != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_testConnection());
      });
    }
  }

  void _connectionChanged() {
    final settings = (_host.text, _port.text, _local.text, _transport);
    if (settings == _lastConnectionSettings) return;
    _lastConnectionSettings = settings;
    if (_connected) {
      setState(() {
        _connected = false;
      });
    }
  }

  @override
  void dispose() {
    if (_testingLimits) unawaited(widget.onStopLimits());
    for (final field in [
      _name,
      _host,
      _port,
      _local,
      _infoPort,
      _infoUsername,
      _infoPassword,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await widget.onSave(_enteredCamera());
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = 'Could not save. See the status message for details.';
      });
    }
  }

  Camera _enteredCamera() => Camera(
    id: _cameraId,
    name: _name.text.trim(),
    host: _host.text.trim(),
    port: int.parse(_port.text),
    localPort: int.parse(_local.text),
    transport: _transport,
    presets: widget.camera?.presets ?? const [],
    limits: _limits,
    info: _info,
  );

  Future<void> _getCameraInfo() async {
    if (_busy) return;
    final valid = [
      _hostKey,
      _portKey,
      _localKey,
    ].map((key) => key.currentState!.validate()).toList();
    if (valid.contains(false)) return;
    final port = int.tryParse(_infoPort.text);
    if (port == null || port < 1 || port > 65535) {
      setState(() {
        _showInfoConnection = true;
        _infoMessage = 'Enter a web port between 1 and 65535.';
      });
      return;
    }
    setState(() {
      _gettingInfo = true;
      _infoMessage = null;
    });
    try {
      final result = await widget.onGetInfo(
        _enteredCamera(),
        CameraInfoOptions(
          port: port,
          https: _infoHttps,
          username: _infoUsername.text,
          password: _infoPassword.text,
        ),
      );
      if (!mounted) return;
      setState(() {
        if (result.info != null && !result.info!.isEmpty) {
          _info = _info?.merge(result.info!) ?? result.info;
        }
        _infoMessage = result.message;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _infoMessage = 'Could not retrieve camera information. Existing saved information was kept.',
        );
      }
    } finally {
      if (mounted) setState(() => _gettingInfo = false);
    }
  }

  Future<void> _testLimits() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _testingLimits = true;
      _error = null;
    });
    try {
      final limits = await widget.onTestLimits(_enteredCamera());
      if (!mounted) return;
      setState(() {
        _limits = limits;
        _connected = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Limits were not saved: $error');
    } finally {
      if (mounted) setState(() => _testingLimits = false);
    }
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    // A display name is optional when testing the network settings.
    final valid = [
      _hostKey,
      _portKey,
      _localKey,
    ].map((key) => key.currentState!.validate()).toList();
    if (valid.contains(false)) return;
    setState(() {
      _testing = true;
      _connected = false;
    });
    var connected = false;
    try {
      connected = await widget.onTest(_enteredCamera());
    } catch (_) {
      connected = false;
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _connected = connected;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      insetPadding: const EdgeInsets.all(16),
      title: Text(widget.camera == null ? 'Add camera' : 'Edit camera'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  maxLength: 32,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Camera name'),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter a camera name'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: _hostKey,
                  controller: _host,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'IPv4 address',
                    hintText: '192.168.1.100',
                  ),
                  validator: Camera.validateHost,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ViscaTransport>(
                  initialValue: _transport,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'UDP packet format',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: ViscaTransport.raw,
                      child: Text('Raw VISCA'),
                    ),
                    DropdownMenuItem(
                      value: ViscaTransport.sony,
                      child: Text('VISCA over IP'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _transport = value!;
                          _connected = false;
                          if (_port.text == '1259' || _port.text == '52381') {
                            _port.text = value == ViscaTransport.sony
                                ? '52381'
                                : '1259';
                          }
                        }),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _portField(_port, 'Camera port', false, _portKey),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _portField(_local, 'Local port', true, _localKey),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Local port 0 chooses an available port. Set a fixed local port if your camera requires it.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : _testConnection,
                      child: const Text('Test connection'),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: ConnectionStatus(
                        connected: _connected,
                        label: _testing
                            ? 'Testing…'
                            : _connected
                            ? 'Connected'
                            : 'Not connected',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _getCameraInfo,
                    child: Text(
                      _gettingInfo ? 'Getting camera info…' : 'Get camera info',
                    ),
                  ),
                ),
                if (_infoMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _infoMessage!,
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ],
                const SizedBox(height: 8),
                Table(
                  columnWidths: const {
                    0: FixedColumnWidth(110),
                    1: FlexColumnWidth(),
                  },
                  children: [
                    for (final item in [
                      ('manufacturer', 'Manufacturer', _info?.manufacturer),
                      ('model', 'Model', _info?.model),
                      ('serial', 'Serial number', _info?.serialNumber),
                      ('mac', 'MAC address', _info?.macAddress),
                    ])
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              item.$2,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white60,
                              ),
                            ),
                          ),
                          Text(
                            item.$3 ??
                                (_info == null
                                    ? 'Not retrieved'
                                    : 'Not reported'),
                            key: ValueKey('camera-info-${item.$1}'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                  ],
                ),
                if (_info?.sourceHost != null)
                  Text(
                    'Last retrieved from ${_info!.sourceHost}',
                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(
                            () => _showInfoConnection = !_showInfoConnection,
                          ),
                    child: const Text('Camera info connection'),
                  ),
                ),
                if (_showInfoConnection) ...[
                  TextField(
                    controller: _infoPort,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Web / ONVIF port',
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use HTTPS'),
                    value: _infoHttps,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _infoHttps = value!;
                            if (_infoPort.text == '80' ||
                                _infoPort.text == '443') {
                              _infoPort.text = _infoHttps ? '443' : '80';
                            }
                          }),
                  ),
                  TextField(
                    controller: _infoUsername,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Camera username',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _infoPassword,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Camera password',
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Login details are used for this lookup only and are not saved or exported.',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : _testLimits,
                      child: const Text('Test & save limits'),
                    ),
                    if (_testingLimits) ...[
                      TextButton(
                        onPressed: () => unawaited(widget.onStopLimits()),
                        child: const Text('Stop test'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _testingLimits ? 'Please wait. Testing limits...' : 'Moves the camera through its full range and saves this camera’s settings.',
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
                const SizedBox(height: 8),
                Table(
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    const TableRow(
                      children: [Text(''), Text('Min'), Text('Max')],
                    ),
                    for (final row in [
                      ('Pan', _limits?.panMin, _limits?.panMax),
                      ('Tilt', _limits?.tiltMin, _limits?.tiltMax),
                      ('Zoom', _limits?.zoomMin, _limits?.zoomMax),
                    ])
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(row.$1),
                          ),
                          Text(
                            '${row.$2 ?? '—'}',
                            key: ValueKey('limit-${row.$1.toLowerCase()}-min'),
                          ),
                          Text(
                            '${row.$3 ?? '—'}',
                            key: ValueKey('limit-${row.$1.toLowerCase()}-max'),
                          ),
                        ],
                      ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save camera'),
        ),
      ],
    ),
  );

  Widget _portField(
    TextEditingController controller,
    String label,
    bool zero,
    GlobalKey<FormFieldState<String>> key,
  ) => TextFormField(
    key: key,
    controller: controller,
    enabled: !_busy,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label),
    validator: (v) {
      final n = int.tryParse(v ?? '');
      return n == null || n < (zero ? 0 : 1) || n > 65535
          ? '${zero ? 0 : 1}–65535'
          : null;
    },
  );
}
