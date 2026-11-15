import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/camera.dart';
import 'services/camera_store.dart';
import 'services/visca_client.dart';
import 'services/visca_protocol.dart';

enum CameraConnection { none, connecting, connected, offline, paused }

class PtzController extends ChangeNotifier {
  PtzController({CameraStore? store})
    : _store = store ?? PreferencesCameraStore();
  final CameraStore _store;
  List<Camera> cameras = [];
  final List<CommandLog> logs = [];
  Camera? selected;
  CameraConnection connection = CameraConnection.none;
  bool loading = true;
  bool saving = false;
  bool switching = false;
  bool debug = false;
  bool sideNavigation = false;
  bool _disposed = false;
  bool _paused = false;
  bool _polling = false;
  bool _storageHealthy = true;
  String? message;
  int panSpeed = 8, tiltSpeed = 6, zoomSpeed = 3, focusSpeed = 3;
  int? pan, tilt, zoom;
  bool? autofocus;
  DateTime? lastReply;
  ViscaClient? _client;
  ViscaClient? _motionClient;
  List<int>? _motionStop;
  Object? _motionOwner;
  Timer? _pollTimer;
  Timer? _watchdog;

  bool get canControl => _client != null && !switching && !_paused;
  bool get moving => _motionClient != null;
  String get statusLabel => switch (connection) {
    CameraConnection.none => 'No camera selected',
    CameraConnection.connecting => 'Waiting for camera',
    CameraConnection.connected => 'Connected',
    CameraConnection.offline => 'No response',
    CameraConnection.paused => 'Paused',
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      cameras = await _store.load();
    } catch (_) {
      _storageHealthy = false;
      message =
          'Saved setup could not be read. Check storage before saving changes.';
    }
    loading = false;
    _notify();
    if (!_disposed && cameras.isNotEmpty) await select(cameras.first);
    if (_disposed) return;
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_paused || _client == null) return;
      final reference = lastReply ?? _openedAt;
      if (reference != null &&
          DateTime.now().difference(reference).inSeconds >= 5 &&
          connection != CameraConnection.offline) {
        connection = CameraConnection.offline;
        pan = tilt = zoom = null;
        autofocus = null;
        _notify();
      }
    });
  }

  DateTime? _openedAt;

  Future<void> select(Camera camera) async {
    if (switching || _disposed) return;
    switching = true;
    _pollTimer?.cancel();
    _notify();
    await endMotion();
    _client?.close();
    _client = null;
    selected = camera;
    pan = tilt = zoom = null;
    autofocus = null;
    lastReply = null;
    message = null;
    connection = _paused
        ? CameraConnection.paused
        : CameraConnection.connecting;
    if (_paused || _disposed) {
      switching = false;
      _notify();
      return;
    }
    late final ViscaClient client;
    client = ViscaClient(
      camera,
      onLog: (log) {
        if (_disposed) return;
        logs.insert(0, log);
        if (logs.length > 200) logs.removeLast();
        _notify();
      },
      onReply: () {
        if (_client != client || _disposed || _paused) return;
        lastReply = DateTime.now();
        connection = CameraConnection.connected;
        _notify();
      },
      onError: (error) {
        if (_client != client || _disposed) return;
        message = error;
        _notify();
      },
    );
    _client = client;
    try {
      await client.open();
      if (_disposed || _paused || _client != client) {
        client.close();
        return;
      }
      _openedAt = DateTime.now();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(refresh()),
      );
    } catch (error) {
      client.close();
      _client = null;
      connection = CameraConnection.offline;
      message = 'Could not open UDP socket: $error';
    } finally {
      switching = false;
      _notify();
    }
    await refresh();
  }

  Future<void> refresh() async {
    if (!canControl || _polling || moving) return;
    final client = _client!;
    _polling = true;
    try {
      final position = await client.send(
        'Read pan / tilt position',
        Visca.panTiltInquiry,
      );
      if (_client != client || _disposed || _paused) return;
      if (position != null && position.length == 11) {
        try {
          pan = Visca.nibbles(position.sublist(2, 6), signed: true);
          tilt = Visca.nibbles(position.sublist(6, 10), signed: true);
        } on FormatException {
          message = 'Invalid position data received';
        }
      }
      if (moving) return;
      final z = await client.send('Read zoom position', Visca.zoomInquiry);
      if (_client != client || _disposed || _paused) return;
      if (z != null && z.length == 7) {
        try {
          zoom = Visca.nibbles(z.sublist(2, 6));
        } on FormatException {
          message = 'Invalid zoom data received';
        }
      }
      if (moving) return;
      final focus = await client.send(
        'Read autofocus mode',
        Visca.focusModeInquiry,
      );
      if (_client != client || _disposed || _paused) return;
      if (focus != null && focus.length == 4 && [2, 3].contains(focus[2])) {
        autofocus = focus[2] == 2;
      }
      _notify();
    } finally {
      _polling = false;
    }
  }

  Future<void> command(String description, List<int> bytes) async {
    if (!canControl || moving) return;
    message = null;
    final client = _client!;
    final reply = await client.send(
      description,
      bytes,
      motion: bytes.length > 3 && bytes[2] == 6 && bytes[3] == 4,
    );
    if (_client != client || _disposed) return;
    if (reply == null && message == null) {
      message = 'No acknowledgement: $description';
    }
    _notify();
  }

  bool startMotion(
    String description,
    List<int> bytes,
    List<int> stop, {
    Object? owner,
  }) {
    if (!canControl || moving) return false;
    final client = _client!;
    _motionClient = client;
    _motionStop = stop;
    _motionOwner = owner;
    message = null;
    unawaited(client.send(description, bytes, motion: true));
    _notify();
    return true;
  }

  Future<void> endMotion({Object? owner}) async {
    if (owner != null && owner != _motionOwner) return;
    final client = _motionClient;
    final stop = _motionStop;
    _motionClient = null;
    _motionStop = null;
    _motionOwner = null;
    if (client == null || stop == null) return;
    _notify();
    // Stop is prioritized over polling, including an in-flight inquiry.
    await client.send('Stop movement', stop, priority: true);
  }

  Future<void> stopAll() async {
    if (!canControl) return;
    _motionClient = null;
    _motionStop = null;
    _motionOwner = null;
    final client = _client!;
    await Future.wait([
      client.send(
        'Stop pan / tilt',
        Visca.drive(panSpeed, tiltSpeed, 3, 3),
        priority: true,
      ),
      client.send('Stop zoom', Visca.camera(7, [0]), priority: true),
      client.send('Stop focus', Visca.camera(8, [0]), priority: true),
    ]);
    _notify();
  }

  void setSpeed(String axis, int value) {
    switch (axis) {
      case 'Pan':
        panSpeed = value.clamp(1, 24);
      case 'Tilt':
        tiltSpeed = value.clamp(1, 20);
      case 'Zoom':
        zoomSpeed = value.clamp(0, 7);
      case 'Focus':
        focusSpeed = value.clamp(0, 7);
    }
    _notify();
  }

  Future<bool> saveCamera(Camera camera) async {
    if (saving || !_storageHealthy) return false;
    final updated = List<Camera>.of(cameras);
    final index = updated.indexWhere((c) => c.id == camera.id);
    if (index < 0) {
      if (updated.length >= 8) return false;
      updated.add(camera);
    } else {
      updated[index] = camera;
    }
    return _persist(updated, selectAfter: camera);
  }

  Future<bool> removeCamera(Camera camera) async {
    if (saving || !_storageHealthy) return false;
    return _persist(
      cameras.where((c) => c.id != camera.id).toList(),
      removed: camera,
    );
  }

  Future<bool> _persist(
    List<Camera> updated, {
    Camera? selectAfter,
    Camera? removed,
  }) async {
    saving = true;
    _notify();
    try {
      await _store.save(updated);
      if (_disposed) return false;
      cameras = updated;
      if (selectAfter != null) await select(selectAfter);
      if (removed?.id == selected?.id && removed != null) {
        await endMotion();
        _pollTimer?.cancel();
        _client?.close();
        _client = null;
        selected = null;
        pan = tilt = zoom = null;
        autofocus = null;
        connection = CameraConnection.none;
        if (cameras.isNotEmpty) await select(cameras.first);
      }
      return true;
    } catch (error) {
      message = 'Could not save camera setup: $error';
      return false;
    } finally {
      saving = false;
      _notify();
    }
  }

  void toggleDebug() {
    debug = !debug;
    _notify();
  }

  void toggleNavigation() {
    sideNavigation = !sideNavigation;
    _notify();
  }

  void clearLogs() {
    logs.clear();
    _notify();
  }

  void clearMessage() {
    message = null;
    _notify();
  }

  Future<void> setPaused(bool paused) async {
    if (_paused == paused) return;
    _paused = paused;
    if (paused) {
      _pollTimer?.cancel();
      connection = CameraConnection.paused;
      await endMotion();
      _notify();
    } else if (selected != null && !switching) {
      await select(selected!);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _watchdog?.cancel();
    final client = _client;
    // Keep the socket alive until the final stop is sent on graceful teardown.
    unawaited(endMotion().whenComplete(() => client?.close()));
    super.dispose();
  }
}
