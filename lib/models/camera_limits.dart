/// Measured travel limits in the camera's native position units.
class CameraLimits {
  const CameraLimits({
    required this.panMin,
    required this.panMax,
    required this.tiltMin,
    required this.tiltMax,
    required this.zoomMin,
    required this.zoomMax,
  });

  final int panMin, panMax, tiltMin, tiltMax, zoomMin, zoomMax;

  Map<String, dynamic> toJson() => {
    'panMin': panMin,
    'panMax': panMax,
    'tiltMin': tiltMin,
    'tiltMax': tiltMax,
    'zoomMin': zoomMin,
    'zoomMax': zoomMax,
  };

  factory CameraLimits.fromJson(Map<String, dynamic> json) {
    final limits = CameraLimits(
      panMin: json['panMin'] as int,
      panMax: json['panMax'] as int,
      tiltMin: json['tiltMin'] as int,
      tiltMax: json['tiltMax'] as int,
      zoomMin: json['zoomMin'] as int,
      zoomMax: json['zoomMax'] as int,
    );
    if (limits.panMin < -32768 ||
        limits.panMax > 32767 ||
        limits.panMin >= limits.panMax ||
        limits.tiltMin < -32768 ||
        limits.tiltMax > 32767 ||
        limits.tiltMin >= limits.tiltMax ||
        limits.zoomMin < 0 ||
        limits.zoomMax > 65535 ||
        limits.zoomMin >= limits.zoomMax) {
      throw const FormatException('Invalid camera limits');
    }
    return limits;
  }
}
