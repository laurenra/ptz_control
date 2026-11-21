import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../models/discovered_camera.dart';
import '../services/onvif_discovery.dart';

class CameraDiscoveryDialog extends StatefulWidget {
  const CameraDiscoveryDialog({
    super.key,
    this.discovery = const OnvifDiscoveryService(),
  });
  final OnvifDiscoveryService discovery;

  @override
  State<CameraDiscoveryDialog> createState() => _CameraDiscoveryDialogState();
}

class _CameraDiscoveryDialogState extends State<CameraDiscoveryDialog> {
  late final CameraDiscoveryScan _scan;
  late final StreamSubscription<List<DiscoveredCamera>> _subscription;
  List<DiscoveredCamera> _devices = const [];
  bool _searching = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan = widget.discovery.start();
    _subscription = _scan.results.listen(
      (devices) {
        if (mounted) setState(() => _devices = devices);
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = 'Could not search for cameras: $error';
            _searching = false;
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _searching = false);
      },
    );
  }

  @override
  void dispose() {
    _scan.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.all(16),
    title: const Text('Find cameras'),
    content: SizedBox(
      width: 340,
      height: 480,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_searching ? 'Searching for ONVIF devices…' : 'Search finished'),
          const SizedBox(height: 8),
          if (_searching) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
          ],
          Text(
            '${_devices.length} ${_devices.length == 1 ? 'device' : 'devices'} found',
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: _devices.isEmpty
                ? SingleChildScrollView(
                    child: Text(
                      _searching
                          ? 'Waiting for cameras to respond…'
                          : _error == null
                          ? 'No ONVIF devices responded. Check your network connection and that ONVIF discovery is enabled on the cameras.'
                          : 'Check local network access and try again.',
                    ),
                  )
                : ListView.separated(
                    itemCount: _devices.length,
                    separatorBuilder: (_, _) => const Divider(height: 28),
                    itemBuilder: (_, index) {
                      final device = _devices[index];
                      return Column(
                        key: ValueKey(device.address),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Device ${index + 1}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          for (final field in [
                            ('EndpointReference (address)', device.address),
                            ('Types', device.types.join('\n')),
                            ('Scopes', device.scopes.join('\n')),
                            ('XAddrs', device.xAddrs.join('\n')),
                          ]) ...[
                            const SizedBox(height: 10),
                            Text(
                              field.$1,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 3),
                            SelectableText(
                              field.$2.isEmpty ? 'Not reported' : field.$2,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          _scan.cancel();
          Navigator.pop(context);
        },
        child: const Text('Cancel'),
      ),
    ],
  );
}
