import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_info.dart';
import 'package:ptz_control/models/camera_settings.dart';
import 'package:ptz_control/services/camera_store.dart';

import 'camera_settings_test.dart' show settingsCameras;

void main() {
  const info = CameraInfo(
    manufacturer: 'Maker',
    model: 'PTZ 20X',
    serialNumber: 'SN-123',
    macAddress: '02:AA:BB:CC:DD:01',
    sourceHost: '192.0.2.3',
  );

  test('device identity survives edits, persistence and sharing alongside limits and presets', () async {
    SharedPreferences.setMockInitialValues({});
    final camera = settingsCameras.first.withInfo(info);
    final updated = camera
        .withPresets(camera.presets)
        .withLimits(camera.limits!);
    expect(updated.info!.toJson(), info.toJson());
    final store = PreferencesCameraStore();
    await store.save([updated]);
    final restored = (await PreferencesCameraStore().load()).single;
    expect(restored.toJson(), updated.toJson());
    final shared = CameraSettings(cameras: [restored], nextId: 4).encode();
    expect(
      CameraSettings.decode(shared).cameras.single.toJson(),
      updated.toJson(),
    );
    final legacy = updated.toJson()..remove('info');
    expect(Camera.fromJson(legacy).info, isNull);
  });

  test(
    'normalizes valid hardware MACs and rejects malformed identity fields',
    () {
      expect(CameraInfo.normalizeMac('02-aa-bb-cc-dd-01'), '02:AA:BB:CC:DD:01');
      for (final mac in [
        '00:00:00:00:00:00',
        'FF:FF:FF:FF:FF:FF',
        '01:AA:BB:CC:DD:01',
        'not-a-mac',
      ]) {
        expect(CameraInfo.normalizeMac(mac), isNull);
        expect(
          () => CameraInfo.fromJson({'macAddress': mac}),
          throwsFormatException,
        );
      }
      expect(
        () => CameraInfo.fromJson({'serialNumber': 'x' * 257}),
        throwsFormatException,
      );
      expect(
        () => CameraInfo.fromJson({'manufacturer': 123}),
        throwsFormatException,
      );
    },
  );

  test(
    'does not combine old and new camera identities across an IP change',
    () {
      final partial = info.merge(
        const CameraInfo(model: 'Updated model', sourceHost: '192.0.2.3'),
      );
      expect(partial.serialNumber, info.serialNumber);
      expect(partial.model, 'Updated model');
      final different = info.merge(
        const CameraInfo(model: 'Another camera', sourceHost: '192.0.2.99'),
      );
      expect(different.model, 'Another camera');
      expect(different.serialNumber, isNull);
      expect(different.macAddress, isNull);
    },
  );
}
