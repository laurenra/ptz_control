import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../models/camera.dart';
import 'connection_status.dart';

class CameraEditor extends StatefulWidget {
  const CameraEditor({
    super.key,
    this.camera,
    required this.onSave,
    required this.onTest,
  });
  final Camera? camera;
  final Future<bool> Function(Camera) onSave;
  final Future<bool> Function(Camera) onTest;

  @override
  State<CameraEditor> createState() => _CameraEditorState();
}

class _CameraEditorState extends State<CameraEditor> {
  final _form = GlobalKey<FormState>();
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
  bool _saving = false;
  bool _testing = false;
  bool _connected = false;
  bool get _busy => _saving || _testing;
  String? _error;

  @override
  void initState() {
    super.initState();
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
    if (_connected) setState(() => _connected = false);
  }

  @override
  void dispose() {
    for (final field in [_name, _host, _port, _local]) {
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
    id: widget.camera?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: _name.text.trim(),
    host: _host.text.trim(),
    port: int.parse(_port.text),
    localPort: int.parse(_local.text),
    transport: _transport,
    presets: widget.camera?.presets ?? const [],
  );

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
