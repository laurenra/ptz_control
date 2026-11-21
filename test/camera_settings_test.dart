import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_limits.dart';
import 'package:ptz_control/models/camera_preset.dart';
import 'package:ptz_control/models/camera_settings.dart';
import 'package:ptz_control/services/camera_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'visca_client_test.dart' show MemoryStore;

const settingsCameras = [
  Camera(
    id: 3,
    name: 'Stage – 三',
    host: '192.0.2.3',
    port: 52381,
    localPort: 52381,
    transport: ViscaTransport.sony,
    limits: CameraLimits(
      panMin: -2448,
      panMax: 2448,
      tiltMin: -432,
      tiltMax: 1296,
      zoomMin: 0,
      zoomMax: 16384,
    ),
    presets: [
      CameraPreset(
        slot: 1,
        name: 'Wide\nStage',
        pan: -2,
        tilt: 3,
        zoom: 40,
        focus: 50,
        aperture: 7,
      ),
    ],
  ),
  Camera(id: 1, name: 'Other', host: '192.0.2.1', port: 1259),
];

class _FailingImportStore extends MemoryStore {
  _FailingImportStore(super.cameras);
  @override
  Future<void> save(List<Camera> cameras, {int? nextId}) async =>
      throw StateError('Disk full');
}

void main() {
  test(
    'readable versioned JSON retains order, IDs, counter and all camera fields',
    () {
      final settings = CameraSettings(cameras: settingsCameras, nextId: 10);
      final source = settings.encode(exportedAt: DateTime.utc(2026, 11, 21));
      expect(source, contains('\n  "format": "ptz-control-camera-settings",'));
      final json = jsonDecode(source);
      expect(json['version'], 1);
      expect(json['exportedAt'], '2026-11-21T00:00:00.000Z');
      final restored = CameraSettings.decode(source);
      expect(restored.nextId, 10);
      expect(
        restored.cameras.map((camera) => camera.toJson()),
        settingsCameras.map((camera) => camera.toJson()),
      );
      expect(() => restored.cameras.clear(), throwsUnsupportedError);
    },
  );

  test('rejects invalid JSON, formats, versions, counters and camera data', () {
    final valid = CameraSettings(cameras: settingsCameras, nextId: 10).encode();
    final parsed = jsonDecode(valid) as Map<String, dynamic>;
    final invalid = <String>[
      '{',
      '[]',
      '{}',
      jsonEncode({...parsed, 'format': 'something-else'}),
      jsonEncode({...parsed, 'version': 2}),
      jsonEncode({...parsed, 'version': 1.0}),
      jsonEncode({...parsed, 'cameras': []}),
      jsonEncode({
        ...parsed,
        'cameras': List.filled(9, settingsCameras.first.toJson()),
      }),
      jsonEncode({
        ...parsed,
        'cameras': List.filled(2, settingsCameras.first.toJson()),
      }),
      for (final next in [0, 3, 257, '10', null])
        jsonEncode({...parsed, 'nextId': next}),
      for (final edit in [
        {'id': 0},
        {'id': 256},
        {'id': '3'},
        {'host': 'not-an-ip'},
        {'port': 0},
        {'localPort': 65536},
        {'transport': 'tcp'},
        {
          'limits': {'panMin': 5},
        },
        {
          'presets': [
            {'slot': 10, 'name': 'Invalid'},
          ],
        },
      ])
        jsonEncode({
          ...parsed,
          'cameras': [
            {...settingsCameras.first.toJson(), ...edit},
          ],
        }),
    ];
    for (final source in invalid) {
      expect(
        () => CameraSettings.decode(source),
        throwsFormatException,
        reason: source,
      );
    }
  });

  test('import restores the full setup and next ID across restart', () async {
    SharedPreferences.setMockInitialValues({});
    final c = PtzController(store: PreferencesCameraStore());
    addTearDown(c.dispose);
    await c.setPaused(true);
    await c.initialize();
    await c.saveCamera(settingsCameras[1]);
    expect(
      await c.importCameraSettings(
        CameraSettings(cameras: settingsCameras, nextId: 10),
      ),
      true,
    );
    // The same physical camera stays selected despite changing its position.
    expect(c.selected!.id, 1);
    expect(c.nextCameraId, 10);
    final restarted = PreferencesCameraStore();
    final restored = await restarted.load();
    expect(
      restored.map((camera) => camera.toJson()),
      settingsCameras.map((camera) => camera.toJson()),
    );
    expect(restarted.nextId, 10);
  });

  test('failed import leaves old settings, selection, connection and counter intact', () async {
    final store = _FailingImportStore([settingsCameras[1]]);
    final c = PtzController(store: store);
    addTearDown(c.dispose);
    await c.setPaused(true);
    await c.initialize();
    final selected = c.selected;
    expect(
      await c.importCameraSettings(
        CameraSettings(cameras: settingsCameras, nextId: 10),
      ),
      false,
    );
    expect(c.cameras, [settingsCameras[1]]);
    expect(c.selected, same(selected));
    expect(c.connection, CameraConnection.paused);
    expect(c.nextCameraId, 2);
    expect(store.cameras, [settingsCameras[1]]);
    expect(c.saving, false);
    expect(c.switching, false);
  });

  test(
    'a reused ID at another address is not mistaken for the selected camera',
    () async {
      final c = PtzController(store: MemoryStore([settingsCameras[1]]));
      addTearDown(c.dispose);
      await c.setPaused(true);
      await c.initialize();
      final imported = [
        settingsCameras.first,
        const Camera(
          id: 1,
          name: 'Different camera',
          host: '192.0.2.99',
          port: 1259,
        ),
      ];
      expect(
        await c.importCameraSettings(
          CameraSettings(cameras: imported, nextId: 4),
        ),
        true,
      );
      expect(c.selected!.id, 3);
    },
  );
}
