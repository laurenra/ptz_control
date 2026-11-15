import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/services/camera_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('all eight camera configurations survive storage round trip', () async {
    final cameras = List.generate(
      8,
      (i) => Camera(
        id: '$i',
        name: 'Camera $i',
        host: '192.168.1.${i + 10}',
        port: 52381,
        localPort: i == 0 ? 52381 : 0,
        transport: ViscaTransport.sony,
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
}
