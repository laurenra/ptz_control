import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/services/visca_protocol.dart';

void main() {
  test('camera preset commands use zero-based memory addresses', () {
    expect(Visca.storePreset(1), [0x81, 1, 4, 0x3f, 1, 0, 255]);
    expect(Visca.storePreset(9), [0x81, 1, 4, 0x3f, 1, 8, 255]);
    expect(Visca.recallPreset(1), [0x81, 1, 4, 0x3f, 2, 0, 255]);
    expect(Visca.recallPreset(9), [0x81, 1, 4, 0x3f, 2, 8, 255]);
    expect(() => Visca.storePreset(0), throwsRangeError);
    expect(() => Visca.recallPreset(10), throwsRangeError);
  });

  test('encodes direction and speed boundaries', () {
    expect(Visca.drive(24, 20, 1, 2), [0x81, 1, 6, 1, 24, 20, 1, 2, 255]);
    expect(() => Visca.drive(0, 1, 1, 1), throwsRangeError);
    expect(() => Visca.drive(1, 21, 1, 1), throwsRangeError);
    expect(Visca.lens(focus: false, positive: true, speed: 0), [
      0x81,
      1,
      4,
      7,
      0x20,
      255,
    ]);
    expect(Visca.lens(focus: true, positive: false, speed: 7), [
      0x81,
      1,
      4,
      8,
      0x37,
      255,
    ]);
    expect(
      () => Visca.lens(focus: true, positive: true, speed: 8),
      throwsRangeError,
    );
  });

  test('encodes Sony headers and validates reply length', () {
    expect(Visca.frame(Visca.zoomInquiry, 0x12345678), [
      1,
      0x10,
      0,
      5,
      0x12,
      0x34,
      0x56,
      0x78,
      0x81,
      9,
      4,
      0x47,
      255,
    ]);
    expect(Visca.frame(Visca.home, 1).take(2), [1, 0]);
    final packet = [1, 0x11, 0, 3, 0, 0, 0, 8, 0x90, 0x41, 255];
    expect(Visca.unframe(packet)?.sequence, 8);
    expect(Visca.unframe(packet)?.payload, [0x90, 0x41, 255]);
    expect(Visca.unframe([...packet, 0]), isNull);
  });

  test('decodes signed camera-native positions without inventing degrees', () {
    expect(Visca.nibbles([15, 15, 15, 14], signed: true), -2);
    expect(Visca.nibbles([4, 0, 0, 0]), 0x4000);
    expect(() => Visca.nibbles([0, 16, 0, 0]), throwsFormatException);
  });

  test('rejects invalid camera endpoints and restores configuration', () {
    expect(Camera.validateHost('192.168.1.10'), isNull);
    for (final value in ['bad', '::1', '256.0.0.1', '0.0.0.0', '224.0.0.1']) {
      expect(Camera.validateHost(value), isNotNull);
    }
    const camera = Camera(
      id: 1,
      name: 'Stage',
      host: '192.168.1.10',
      port: 52381,
      transport: ViscaTransport.sony,
      localPort: 52381,
    );
    expect(Camera.fromJson(camera.toJson()).toJson(), camera.toJson());
  });
}
