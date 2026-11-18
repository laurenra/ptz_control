/// A local snapshot and display name for a preset in the camera’s memory.
class CameraPreset {
  const CameraPreset({
    required this.slot,
    required this.name,
    this.pan,
    this.tilt,
    this.zoom,
    this.focus,
    this.aperture,
  });

  final int slot;
  final String name;
  final int? pan, tilt, zoom, focus, aperture;

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
    if (pan != null) 'pan': pan,
    if (tilt != null) 'tilt': tilt,
    if (zoom != null) 'zoom': zoom,
    if (focus != null) 'focus': focus,
    if (aperture != null) 'aperture': aperture,
  };

  factory CameraPreset.fromJson(Map<String, dynamic> json) {
    // Name-only presets from older versions remain usable via camera memory.
    final preset = CameraPreset(
      slot: json['slot'] as int,
      name: json['name'] as String,
      pan: json['pan'] as int?,
      tilt: json['tilt'] as int?,
      zoom: json['zoom'] as int?,
      focus: json['focus'] as int?,
      aperture: json['aperture'] as int?,
    );
    if (preset.slot < 1 ||
        preset.slot > 9 ||
        validateName(preset.name) != null ||
        !_inRange(preset.pan, -32768, 32767) ||
        !_inRange(preset.tilt, -32768, 32767) ||
        !_inRange(preset.zoom, 0, 65535) ||
        !_inRange(preset.focus, 0, 65535) ||
        !_inRange(preset.aperture, 0, 255)) {
      throw const FormatException('Invalid saved preset');
    }
    return preset;
  }

  static bool _inRange(int? value, int min, int max) =>
      value == null || (value >= min && value <= max);
}
