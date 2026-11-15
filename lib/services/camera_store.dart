import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera.dart';

abstract class CameraStore {
  Future<List<Camera>> load();
  Future<void> save(List<Camera> cameras);
}

class PreferencesCameraStore implements CameraStore {
  static const key = 'ptz.cameras.v1';

  @override
  Future<List<Camera>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(key);
    if (value == null) return [];
    final list = (jsonDecode(value) as List)
        .map((e) => Camera.fromJson(e as Map<String, dynamic>))
        .toList();
    if (list.length > 8 ||
        list.map((c) => c.id).toSet().length != list.length) {
      throw const FormatException('Invalid saved camera list');
    }
    return list;
  }

  @override
  Future<void> save(List<Camera> cameras) async {
    if (cameras.length > 8) {
      throw ArgumentError('Up to eight cameras supported');
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      key,
      jsonEncode(cameras.map((c) => c.toJson()).toList()),
    );
    if (!saved) throw StateError('Camera setup could not be saved');
  }
}
