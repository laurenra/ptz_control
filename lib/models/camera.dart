import 'dart:io';

enum ViscaTransport { raw, sony }

class Camera {
  const Camera({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.transport = ViscaTransport.raw,
    this.localPort = 0,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final ViscaTransport transport;
  final int localPort;

  String get endpoint => '$host:$port';
  String get protocolLabel => transport == ViscaTransport.raw
      ? 'Raw VISCA / UDP'
      : 'Sony VISCA over IP';

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
  };

  factory Camera.fromJson(Map<String, dynamic> json) {
    final camera = Camera(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      transport: ViscaTransport.values.byName(json['transport'] as String),
      localPort: json['localPort'] as int? ?? 0,
    );
    if (camera.id.isEmpty ||
        camera.name.trim().isEmpty ||
        validateHost(camera.host) != null ||
        camera.port < 1 ||
        camera.port > 65535 ||
        camera.localPort < 0 ||
        camera.localPort > 65535) {
      throw const FormatException('Invalid saved camera');
    }
    return camera;
  }
}
