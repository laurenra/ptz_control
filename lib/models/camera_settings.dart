import 'dart:convert';

import 'camera.dart';

/// Portable camera configuration. Array order is the user's display order.
class CameraSettings {
  CameraSettings({required List<Camera> cameras, required this.nextId})
    : cameras = List.unmodifiable(cameras) {
    if (cameras.isEmpty || cameras.length > 8) {
      throw const FormatException(
        'The file must contain between 1 and 8 cameras.',
      );
    }
    if (cameras.map((camera) => camera.id).toSet().length != cameras.length) {
      throw const FormatException('Each camera must have a different ID.');
    }
    for (final (index, camera) in cameras.indexed) {
      try {
        Camera.fromJson(camera.toJson());
      } catch (_) {
        throw FormatException(
          'Camera ${index + 1} has invalid settings. Check its ID, address, ports, limits, and presets.',
        );
      }
    }
    if (nextId < 1 ||
        nextId > 256 ||
        cameras.any((camera) => camera.id >= nextId)) {
      throw const FormatException(
        'The next camera ID must follow the saved camera IDs.',
      );
    }
  }

  static const format = 'ptz-control-camera-settings';
  static const version = 1;
  final List<Camera> cameras;
  final int nextId;

  String encode({DateTime? exportedAt}) {
    final data = {
      'format': format,
      'version': version,
      'exportedAt': (exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'nextId': nextId,
      'cameras': cameras.map((camera) => camera.toJson()).toList(),
    };
    return '${const JsonEncoder.withIndent('  ').convert(data)}\n';
  }

  factory CameraSettings.decode(String source) {
    final dynamic data;
    try {
      data = jsonDecode(source);
    } on FormatException {
      throw const FormatException('The selected file is not valid JSON.');
    }
    if (data is! Map<String, dynamic> || data['format'] != format) {
      throw const FormatException(
        'Choose a PTZ Control camera settings export.',
      );
    }
    if (data['version'] is! int || data['version'] != version) {
      throw const FormatException(
        'This settings file version is not supported.',
      );
    }
    if (data['cameras'] is! List || data['nextId'] is! int) {
      throw const FormatException(
        'The settings file is missing cameras or the next camera ID.',
      );
    }
    final entries = data['cameras'] as List;
    if (entries.isEmpty || entries.length > 8) {
      throw const FormatException(
        'The file must contain between 1 and 8 cameras.',
      );
    }
    final cameras = <Camera>[];
    for (final (index, entry) in entries.indexed) {
      try {
        cameras.add(Camera.fromJson(entry as Map<String, dynamic>));
      } catch (_) {
        throw FormatException(
          'Camera ${index + 1} has invalid settings. Check its ID, address, ports, limits, and presets.',
        );
      }
    }
    return CameraSettings(cameras: cameras, nextId: data['nextId'] as int);
  }
}
