import 'dart:io';

class CameraInfo {
  const CameraInfo({
    this.manufacturer,
    this.model,
    this.serialNumber,
    this.macAddress,
    this.sourceHost,
  });

  final String? manufacturer, model, serialNumber, macAddress, sourceHost;
  bool get isEmpty =>
      manufacturer == null &&
      model == null &&
      serialNumber == null &&
      macAddress == null;

  /// Do not combine identities from different addresses after an editor change.
  CameraInfo merge(CameraInfo newer) => sourceHost != newer.sourceHost
      ? newer
      : CameraInfo(
          manufacturer: newer.manufacturer ?? manufacturer,
          model: newer.model ?? model,
          serialNumber: newer.serialNumber ?? serialNumber,
          macAddress: newer.macAddress ?? macAddress,
          sourceHost: newer.sourceHost,
        );

  static String? reportedText(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty ||
        text.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(text) ||
        [
          'unknown',
          'n/a',
          'not available',
          'not reported',
          'null',
        ].contains(text.toLowerCase())) {
      return null;
    }
    return text;
  }

  static String? normalizeMac(Object? value) {
    if (value is! String) return null;
    final compact = value.trim().replaceAll(RegExp('[:-]'), '').toUpperCase();
    if (!RegExp(r'^[0-9A-F]{12}$').hasMatch(compact) ||
        compact == '000000000000' ||
        compact == 'FFFFFFFFFFFF' ||
        (int.parse(compact.substring(0, 2), radix: 16) & 1) != 0) {
      return null;
    }
    return [for (var i = 0; i < 12; i += 2) compact.substring(i, i + 2)]
        .join(':');
  }

  Map<String, dynamic> toJson() => {
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    if (serialNumber != null) 'serialNumber': serialNumber,
    if (macAddress != null) 'macAddress': macAddress,
    if (sourceHost != null) 'sourceHost': sourceHost,
  };

  factory CameraInfo.fromJson(Map<String, dynamic> json) {
    for (final field in ['manufacturer', 'model', 'serialNumber']) {
      if (json[field] != null && reportedText(json[field]) == null) {
        throw const FormatException('Invalid saved camera information');
      }
    }
    final mac = normalizeMac(json['macAddress']);
    if (json['macAddress'] != null && mac == null) {
      throw const FormatException('Invalid saved camera MAC address');
    }
    final host = json['sourceHost'];
    if (host != null &&
        (host is! String ||
            InternetAddress.tryParse(host)?.type != InternetAddressType.IPv4)) {
      throw const FormatException('Invalid camera information source address');
    }
    return CameraInfo(
      manufacturer: reportedText(json['manufacturer']),
      model: reportedText(json['model']),
      serialNumber: reportedText(json['serialNumber']),
      macAddress: mac,
      sourceHost: host as String?,
    );
  }
}
