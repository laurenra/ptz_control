/// A local display name for a preset stored in the camera’s memory.
class CameraPreset {
  const CameraPreset({required this.slot, required this.name});

  final int slot;
  final String name;

  static String? validateName(String? name) {
    final value = name?.trim() ?? '';
    if (value.isEmpty) return 'Enter a preset name';
    if (value.length > 40) return 'Use up to 40 characters';
    if (value.split('\n').length > 2) return 'Use at most two lines';
    return null;
  }

  Map<String, dynamic> toJson() => {'slot': slot, 'name': name};

  factory CameraPreset.fromJson(Map<String, dynamic> json) {
    // Older configurations contain PTZ/aperture snapshots. Keep only names;
    // recalling a preset now always uses camera memory.
    final preset = CameraPreset(
      slot: json['slot'] as int,
      name: json['name'] as String,
    );
    if (preset.slot < 1 ||
        preset.slot > 9 ||
        validateName(preset.name) != null) {
      throw const FormatException('Invalid saved preset');
    }
    return preset;
  }
}
