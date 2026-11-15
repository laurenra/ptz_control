/// A named, app-managed snapshot. Coordinates stay in camera-native units.
class CameraPreset {
  const CameraPreset({
    required this.slot,
    required this.name,
    required this.pan,
    required this.tilt,
    required this.zoom,
    this.aperture,
  });

  final int slot;
  final String name;
  final int pan;
  final int tilt;
  final int zoom;
  final int? aperture;

  static String? validateName(String? name) {
    final value = name?.trim() ?? '';
    if (value.isEmpty) return 'Enter a preset name';
    if (value.length > 40) return 'Use up to 40 characters';
    if (value.split('\n').length > 2) return 'Use at most two lines';
    return null;
  }

  Map<String, dynamic> toJson() => {
    'slot': slot,
    'name': name,
    'pan': pan,
    'tilt': tilt,
    'zoom': zoom,
    if (aperture != null) 'aperture': aperture,
  };

  factory CameraPreset.fromJson(Map<String, dynamic> json) {
    final preset = CameraPreset(
      slot: json['slot'] as int,
      name: json['name'] as String,
      pan: json['pan'] as int,
      tilt: json['tilt'] as int,
      zoom: json['zoom'] as int,
      aperture: json['aperture'] as int?,
    );
    if (preset.slot < 1 ||
        preset.slot > 9 ||
        validateName(preset.name) != null ||
        preset.pan < -32768 ||
        preset.pan > 32767 ||
        preset.tilt < -32768 ||
        preset.tilt > 32767 ||
        preset.zoom < 0 ||
        preset.zoom > 65535 ||
        (preset.aperture != null &&
            (preset.aperture! < 0 || preset.aperture! > 255))) {
      throw const FormatException('Invalid saved preset');
    }
    return preset;
  }
}
