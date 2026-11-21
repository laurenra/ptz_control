import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_limits.dart';
import 'package:ptz_control/models/camera_preset.dart';
import 'package:ptz_control/services/camera_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('all eight camera configurations survive storage round trip', () async {
    final cameras = List.generate(
      8,
      (i) => Camera(
        id: i + 1,
        name: 'Camera $i',
        host: '192.168.1.${i + 10}',
        port: 52381,
        localPort: i == 0 ? 52381 : 0,
        transport: ViscaTransport.sony,
        limits: const CameraLimits(
          panMin: -30,
          panMax: 40,
          tiltMin: -20,
          tiltMax: 50,
          zoomMin: 10,
          zoomMax: 80,
        ),
        presets: const [
          CameraPreset(
            slot: 1,
            name: 'Wide',
            pan: -2,
            tilt: 16,
            zoom: 0x1234,
            focus: 0x2345,
            aperture: 9,
          ),
        ],
      ),
    );
    await PreferencesCameraStore().save(cameras);
    final restored = await PreferencesCameraStore().load();
    expect(restored.map((c) => c.toJson()), cameras.map((c) => c.toJson()));
    expect(
      () => PreferencesCameraStore().save([...cameras, cameras.first]),
      throwsArgumentError,
    );
  });

  test(
    'corrupt saved data fails visibly instead of silently replacing setup',
    () async {
      SharedPreferences.setMockInitialValues({
        PreferencesCameraStore.key: 'broken json',
      });
      expect(PreferencesCameraStore().load(), throwsFormatException);
    },
  );

  test(
    'legacy migration changes only IDs and keeps an untouched backup',
    () async {
      final legacy = List.generate(
        3,
        (index) => {
          'id': '${1794731743702362 + index}',
          'name': 'Camera $index',
          'host': '192.168.1.${index + 10}',
          'port': 52381,
          'transport': index == 0 ? 'raw' : 'sony',
          'localPort': 52381,
          'limits': {
            'panMin': -2448,
            'panMax': 2448,
            'tiltMin': -432,
            'tiltMax': 1296,
            'zoomMin': 0,
            'zoomMax': 16384,
          },
          'presets': [
            {'slot': 1, 'name': 'Wide', 'pan': 2, 'tilt': -3, 'zoom': 42},
          ],
        },
      );
      final backup = jsonEncode(legacy);
      SharedPreferences.setMockInitialValues({
        PreferencesCameraStore.legacyKey: backup,
      });
      final store = PreferencesCameraStore();
      final cameras = await store.load();
      expect(cameras.map((camera) => camera.id), [1, 2, 3]);
      expect(store.nextId, 4);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PreferencesCameraStore.legacyKey), backup);
      final saved = jsonDecode(prefs.getString(PreferencesCameraStore.key)!);
      for (var i = 0; i < cameras.length; i++) {
        final entry = Map<String, dynamic>.from(saved['cameras'][i])
          ..remove('id');
        final original = Map<String, dynamic>.from(legacy[i])..remove('id');
        expect(entry, original);
        expect(cameras[i].presets.single.name, 'Wide');
        expect(cameras[i].presets.single.zoom, 42);
      }
      await store.save([cameras[2], cameras[0], cameras[1]]);
      final restarted = PreferencesCameraStore();
      expect((await restarted.load()).map((camera) => camera.id), [3, 1, 2]);
      expect(restarted.nextId, 4);
    },
  );

  test('deletion retains the ID sequence across restarts', () async {
    final store = PreferencesCameraStore();
    final first = Camera(id: 1, name: 'One', host: '192.0.2.1', port: 52381);
    final second = Camera(id: 2, name: 'Two', host: '192.0.2.2', port: 52381);
    await store.save([first, second]);
    await store.save([first]);
    final restarted = PreferencesCameraStore();
    await restarted.load();
    expect(restarted.nextId, 3);
  });

  test('invalid or duplicate IDs cannot replace a valid saved setup', () async {
    final store = PreferencesCameraStore();
    const camera = Camera(id: 1, name: 'One', host: '192.0.2.1', port: 52381);
    await store.save([camera]);
    await expectLater(store.save([camera, camera]), throwsFormatException);
    for (final id in [0, 256]) {
      expect(
        () => Camera.fromJson({...camera.toJson(), 'id': id}),
        throwsFormatException,
      );
    }
    expect((await store.load()).single.id, 1);
  });
}
