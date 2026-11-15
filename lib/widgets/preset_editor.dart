import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../models/camera_preset.dart';

class PresetEditor extends StatefulWidget {
  const PresetEditor({super.key, required this.controller, required this.slot});
  final PtzController controller;
  final int slot;

  @override
  State<PresetEditor> createState() => _PresetEditorState();
}

class _PresetEditorState extends State<PresetEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.controller.preset(widget.slot)?.name ?? '${widget.slot}',
  );
  late final _cameraId = widget.controller.selected?.id;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _cancel() {
    if (!_saving) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final c = widget.controller;
    final success =
        c.selected?.id == _cameraId &&
        await c.savePreset(widget.slot, _name.text);
    if (!mounted) return;
    if (success) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = c.message ?? 'Could not save the preset. Check the camera connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
    child: PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('Save preset ${widget.slot}'),
        insetPadding: const EdgeInsets.all(16),
        content: SizedBox(
          width: 320,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) => widget.controller.exposureMode == 3
                      ? const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Manual exposure mode enabled. Exposure and image settings are also saved.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                TextFormField(
                  key: const Key('preset-name'),
                  controller: _name,
                  autofocus: true,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 2,
                  maxLength: 40,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Preset name',
                    hintText: '1 Podium\nWide',
                  ),
                  inputFormatters: [
                    TextInputFormatter.withFunction(
                      (old, value) =>
                          value.text.split('\n').length <= 2 ? value : old,
                    ),
                  ],
                  validator: CameraPreset.validateName,
                ),
                const SizedBox(height: 10),
                Text(
                  'Save the current shot to preset ${widget.slot} in the camera. This replaces that camera preset.',
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.orangeAccent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _cancel,
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    ),
  );
}
