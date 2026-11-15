import 'dart:typed_data';

class Visca {
  static List<int> drive(int pan, int tilt, int horizontal, int vertical) {
    RangeError.checkValueInInterval(pan, 1, 24, 'pan');
    RangeError.checkValueInInterval(tilt, 1, 20, 'tilt');
    RangeError.checkValueInInterval(horizontal, 1, 3, 'horizontal');
    RangeError.checkValueInInterval(vertical, 1, 3, 'vertical');
    return [0x81, 1, 6, 1, pan, tilt, horizontal, vertical, 0xff];
  }

  static List<int> lens({
    required bool focus,
    required bool positive,
    required int speed,
  }) {
    RangeError.checkValueInInterval(speed, 0, 7, 'speed');
    return camera(focus ? 8 : 7, [(positive ? 0x20 : 0x30) | speed]);
  }

  static List<int> camera(int command, List<int> values) => [
    0x81,
    1,
    4,
    command,
    ...values,
    0xff,
  ];
  static const home = [0x81, 1, 6, 4, 0xff];
  static const panTiltInquiry = [0x81, 9, 6, 0x12, 0xff];
  static const zoomInquiry = [0x81, 9, 4, 0x47, 0xff];
  static const focusModeInquiry = [0x81, 9, 4, 0x38, 0xff];

  static const apertureInquiry = [0x81, 9, 4, 0x4b, 0xff];
  static const exposureModeInquiry = [0x81, 9, 4, 0x39, 0xff];

  static List<int> positionNibbles(int value, {bool signed = false}) {
    RangeError.checkValueInInterval(
      value,
      signed ? -32768 : 0,
      signed ? 32767 : 65535,
      'position',
    );
    final unsigned = value & 0xffff;
    return [
      for (final shift in [12, 8, 4, 0]) (unsigned >> shift) & 15,
    ];
  }

  static List<int> absolutePanTilt(
    int pan,
    int tilt,
    int panSpeed,
    int tiltSpeed,
  ) {
    RangeError.checkValueInInterval(panSpeed, 1, 24, 'pan speed');
    RangeError.checkValueInInterval(tiltSpeed, 1, 20, 'tilt speed');
    return [
      0x81,
      1,
      6,
      2,
      panSpeed,
      tiltSpeed,
      ...positionNibbles(pan, signed: true),
      ...positionNibbles(tilt, signed: true),
      0xff,
    ];
  }

  static List<int> absoluteZoom(int zoom) =>
      camera(0x47, positionNibbles(zoom));
  static List<int> absoluteAperture(int aperture) {
    RangeError.checkValueInInterval(aperture, 0, 255, 'aperture');
    return camera(0x4b, positionNibbles(aperture));
  }

  static Uint8List frame(List<int> payload, int sequence) {
    final bytes = Uint8List(8 + payload.length);
    final header = ByteData.sublistView(bytes);
    header.setUint16(0, payload[1] == 9 ? 0x0110 : 0x0100);
    header.setUint16(2, payload.length);
    header.setUint32(4, sequence);
    bytes.setRange(8, bytes.length, payload);
    return bytes;
  }

  static ({List<int> payload, int sequence})? unframe(List<int> bytes) {
    if (bytes.length < 11 || bytes[0] != 1 || bytes[1] != 0x11) return null;
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    if (data.getUint16(2) != bytes.length - 8) return null;
    return (payload: bytes.sublist(8), sequence: data.getUint32(4));
  }

  static bool validReply(List<int> bytes) {
    if (bytes.length < 3 || bytes[0] != 0x90 || bytes.last != 0xff) {
      return false;
    }
    return switch (bytes[1] & 0xf0) {
      0x40 => bytes.length == 3,
      0x50 => true,
      0x60 => bytes.length == 4,
      _ => false,
    };
  }

  static int nibbles(List<int> bytes, {bool signed = false}) {
    if (bytes.length != 4 || bytes.any((b) => b < 0 || b > 15)) {
      throw const FormatException('Expected four VISCA nibbles');
    }
    final value = bytes.fold(0, (v, b) => (v << 4) | b);
    return signed && value >= 0x8000 ? value - 0x10000 : value;
  }

  static String hex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  static String error(int code) => switch (code) {
    1 => 'Message length error',
    2 => 'Syntax error / unsupported command',
    3 => 'Command buffer full',
    4 => 'Command cancelled',
    5 => 'No socket',
    0x41 => 'Command not executable in current mode',
    _ => 'Camera error 0x${code.toRadixString(16)}',
  };
}
