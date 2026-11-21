import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera.dart';

abstract class CameraStore {
  int get nextId;
  Future<List<Camera>> load();
  Future<void> save(List<Camera> cameras);
}

class PreferencesCameraStore implements CameraStore {
  static const legacyKey = 'ptz.cameras.v1';
  static const key = 'ptz.cameras.v2';
  int _nextId = 1;

  @override
  int get nextId => _nextId;

  @override
  Future<List<Camera>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(key);
    if (value != null) {
      final setup = jsonDecode(value) as Map<String, dynamic>;
      final list = (setup['cameras'] as List)
          .map((e) => Camera.fromJson(e as Map<String, dynamic>))
          .toList();
      _validate(list);
      final next = setup['nextId'];
      if (next is! int ||
          next < 1 ||
          next > 256 ||
          list.any((camera) => camera.id >= next)) {
        throw const FormatException('Invalid saved camera ID sequence');
      }
      _nextId = next;
      return list;
    }

    final legacy = prefs.getString(legacyKey);
    if (legacy == null) return [];
    final entries = (jsonDecode(legacy) as List).cast<Map<String, dynamic>>();
    final ids = entries.map((e) => e['id']).toList();
    if (entries.length > 8 ||
        ids.any((id) => id is! String || id.isEmpty) ||
        ids.toSet().length != ids.length) {
      throw const FormatException('Invalid saved camera list');
    }
    final migrated = entries.indexed
        .map((entry) => Camera.fromJson({...entry.$2, 'id': entry.$1 + 1}))
        .toList();
    // Keep the original preference as a backup. Only use v2 after it saves.
    await save(migrated);
    return migrated;
  }

  static void _validate(List<Camera> cameras) {
    if (cameras.length > 8 ||
        cameras.map((c) => c.id).toSet().length != cameras.length) {
      throw const FormatException('Invalid saved camera list');
    }
    for (final camera in cameras) {
      Camera.fromJson(camera.toJson());
    }
  }

  @override
  Future<void> save(List<Camera> cameras) async {
    if (cameras.length > 8) {
      throw ArgumentError('Up to eight cameras supported');
    }
    _validate(cameras);
    final next = cameras.fold(
      _nextId,
      (id, camera) => math.max(id, camera.id + 1),
    );
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      key,
      jsonEncode({
        'nextId': next,
        'cameras': cameras.map((c) => c.toJson()).toList(),
      }),
    );
    if (!saved) throw StateError('Camera setup could not be saved');
    _nextId = next;
  }
}
