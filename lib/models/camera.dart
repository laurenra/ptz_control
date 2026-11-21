import 'dart:io';

import 'camera_preset.dart';
import 'camera_limits.dart';

enum ViscaTransport { raw, sony }

class Camera {
  const Camera({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.transport = ViscaTransport.raw,
    this.localPort = 0,
    this.presets = const [],
    this.limits,
  });

  final int id;
  final String name;
  final String host;
  final int port;
  final ViscaTransport transport;
  final int localPort;
  final List<CameraPreset> presets;
  final CameraLimits? limits;

  Camera withPresets(List<CameraPreset> values) => Camera(
    id: id,
    name: name,
    host: host,
    port: port,
    transport: transport,
    localPort: localPort,
    presets: List.unmodifiable(values),
    limits: limits,
  );

  Camera withLimits(CameraLimits values) => Camera(
    id: id,
    name: name,
    host: host,
    port: port,
    transport: transport,
    localPort: localPort,
    presets: presets,
    limits: values,
  );

  String get endpoint => '$host:$port';
  String get protocolLabel =>
      transport == ViscaTransport.raw ? 'Raw VISCA / UDP' : 'VISCA over IP';

  static String? validateHost(String? value) {
    final address = InternetAddress.tryParse(value?.trim() ?? '');
    if (address == null || address.type != InternetAddressType.IPv4) {
      return 'Enter an IPv4 address, e.g. 192.168.1.100';
    }
    if (address.rawAddress[0] == 0 ||
        address.rawAddress[0] >= 224 ||
        address.rawAddress.every((b) => b == 255)) {
      return 'Use a unicast camera address';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'transport': transport.name,
    'localPort': localPort,
    'presets': presets.map((p) => p.toJson()).toList(),
    if (limits != null) 'limits': limits!.toJson(),
  };

  factory Camera.fromJson(Map<String, dynamic> json) {
    final camera = Camera(
      id: json['id'] as int,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      transport: ViscaTransport.values.byName(json['transport'] as String),
      localPort: json['localPort'] as int? ?? 0,
      limits: json['limits'] == null
          ? null
          : CameraLimits.fromJson(json['limits'] as Map<String, dynamic>),
      presets: List.unmodifiable(
        (json['presets'] as List? ?? []).map(
          (p) => CameraPreset.fromJson(p as Map<String, dynamic>),
        ),
      ),
    );
    if (camera.id < 1 ||
        camera.id > 255 ||
        camera.name.trim().isEmpty ||
        validateHost(camera.host) != null ||
        camera.port < 1 ||
        camera.port > 65535 ||
        camera.localPort < 0 ||
        camera.localPort > 65535 ||
        camera.presets.length > 9 ||
        camera.presets.map((p) => p.slot).toSet().length !=
            camera.presets.length) {
      throw const FormatException('Invalid saved camera');
    }
    return camera;
  }
}
