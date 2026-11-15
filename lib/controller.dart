import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/camera.dart';
import 'models/camera_preset.dart';
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
  bool syncPanTilt = false;
  bool savePresetMode = false;
  bool saveApertureWithPreset = false;
  bool presetBusy = false;
  bool _recalling = false;
  int _presetGeneration = 0;
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
  bool get canOperate => canControl && !presetBusy;
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
      if (_paused || _client == null || _recalling) return;
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
    _cancelPreset();
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
    if (!canOperate || _polling || moving) return;
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
      if (moving || presetBusy) return;
      final z = await client.send('Read zoom position', Visca.zoomInquiry);
      if (_client != client || _disposed || _paused) return;
      if (z != null && z.length == 7) {
        try {
          zoom = Visca.nibbles(z.sublist(2, 6));
        } on FormatException {
          message = 'Invalid zoom data received';
        }
      }
      if (moving || presetBusy) return;
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
    if (!canOperate || moving) return;
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
    if (!canOperate || moving) return false;
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
    if (owner == null && _recalling) {
      await stopAll();
      return;
    }
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
    if (_client == null) return;
    _cancelPreset();
    _motionClient = null;
    _motionStop = null;
    _motionOwner = null;
    final client = _client!;
    _notify();
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
        panSpeed = value.clamp(1, syncPanTilt ? 20 : 24);
        if (syncPanTilt) tiltSpeed = panSpeed;
      case 'Tilt':
        tiltSpeed = value.clamp(1, 20);
        if (syncPanTilt) panSpeed = tiltSpeed;
      case 'Zoom':
        zoomSpeed = value.clamp(0, 7);
      case 'Focus':
        focusSpeed = value.clamp(0, 7);
    }
    _notify();
  }

  void setSyncPanTilt(bool value) {
    syncPanTilt = value;
    if (value) panSpeed = tiltSpeed = panSpeed.clamp(1, 20);
    _notify();
  }

  void setSavePresetMode(bool value) {
    savePresetMode = value;
    _notify();
  }

  void setSaveAperture(bool value) {
    saveApertureWithPreset = value;
    _notify();
  }

  CameraPreset? preset(int slot) {
    for (final p in selected?.presets ?? <CameraPreset>[]) {
      if (p.slot == slot) return p;
    }
    return null;
  }

  bool _presetActive(int generation, ViscaClient client) =>
      !_disposed &&
      !_paused &&
      generation == _presetGeneration &&
      _client == client;

  void _cancelPreset() {
    _presetGeneration++;
    presetBusy = false;
    _recalling = false;
  }

  Future<List<int>> _presetRequest(
    ViscaClient client,
    int generation,
    String description,
    List<int> bytes, {
    bool completion = false,
    bool motion = false,
  }) async {
    if (!_presetActive(generation, client)) {
      throw StateError('Preset operation cancelled');
    }
    final reply = await client.send(
      description,
      bytes,
      motion: motion,
      waitForCompletion: completion,
      replyTimeout: completion ? const Duration(seconds: 30) : null,
    );
    if (!_presetActive(generation, client)) {
      throw StateError('Preset operation cancelled');
    }
    if (reply == null) throw StateError('No successful reply: $description');
    return reply;
  }

  Future<bool> savePreset(int slot, String name) async {
    if (!canOperate || moving || saving || selected == null) return false;
    final invalid = CameraPreset.validateName(name);
    if (invalid != null || slot < 1 || slot > 9 || !_storageHealthy) {
      message = invalid ?? 'Preset cannot be saved to this slot or storage.';
      _notify();
      return false;
    }
    final camera = selected!;
    final client = _client!;
    final generation = ++_presetGeneration;
    final includeAperture = saveApertureWithPreset;
    presetBusy = true;
    message = null;
    _notify();
    try {
      final pt = await _presetRequest(
        client,
        generation,
        'Read preset pan / tilt',
        Visca.panTiltInquiry,
      );
      final z = await _presetRequest(
        client,
        generation,
        'Read preset zoom',
        Visca.zoomInquiry,
      );
      int? iris;
      if (includeAperture) {
        final reply = await _presetRequest(
          client,
          generation,
          'Read preset aperture',
          Visca.apertureInquiry,
        );
        iris = Visca.nibbles(reply.sublist(2, 6));
        if (iris > 255) {
          throw const FormatException('Invalid aperture position');
        }
      }
      final saved = CameraPreset(
        slot: slot,
        name: name.trim(),
        pan: Visca.nibbles(pt.sublist(2, 6), signed: true),
        tilt: Visca.nibbles(pt.sublist(6, 10), signed: true),
        zoom: Visca.nibbles(z.sublist(2, 6)),
        aperture: iris,
      );
      final updatedCamera = camera.withPresets(
        [...camera.presets.where((p) => p.slot != slot), saved]
          ..sort((a, b) => a.slot.compareTo(b.slot)),
      );
      final updated = cameras
          .map((c) => c.id == camera.id ? updatedCamera : c)
          .toList();
      await _store.save(updated);
      if (_disposed) return false;
      cameras = updated;
      if (selected?.id == camera.id) {
        selected = updatedCamera;
        pan = saved.pan;
        tilt = saved.tilt;
        zoom = saved.zoom;
      }
      return true;
    } catch (error) {
      if (_presetActive(generation, client)) {
        message = 'Preset was not saved: $error';
      }
      return false;
    } finally {
      if (generation == _presetGeneration) presetBusy = false;
      _notify();
    }
  }

  Future<bool> recallPreset(int slot) async {
    if (!canOperate || moving) return false;
    final saved = preset(slot);
    if (saved == null) {
      message =
          'Preset $slot is empty. Check Save preset to store the current position.';
      _notify();
      return false;
    }
    final client = _client!;
    final generation = ++_presetGeneration;
    presetBusy = true;
    _recalling = true;
    message = null;
    _notify();
    try {
      if (saved.aperture != null) {
        final mode = await _presetRequest(
          client,
          generation,
          'Read exposure mode',
          Visca.exposureModeInquiry,
        );
        if (![3, 11].contains(mode[2])) {
          await _presetRequest(
            client,
            generation,
            'Use iris-priority exposure',
            Visca.camera(0x39, [11]),
            completion: true,
          );
        }
        await _presetRequest(
          client,
          generation,
          'Recall preset aperture',
          Visca.absoluteAperture(saved.aperture!),
          completion: true,
        );
      }
      await _presetRequest(
        client,
        generation,
        'Recall preset $slot pan / tilt',
        Visca.absolutePanTilt(saved.pan, saved.tilt, panSpeed, tiltSpeed),
        completion: true,
        motion: true,
      );
      await _presetRequest(
        client,
        generation,
        'Recall preset $slot zoom',
        Visca.absoluteZoom(saved.zoom),
        completion: true,
        motion: true,
      );
      return true;
    } catch (error) {
      if (_presetActive(generation, client)) {
        message = 'Preset recall did not finish: $error';
      }
      return false;
    } finally {
      if (generation == _presetGeneration) {
        presetBusy = false;
        _recalling = false;
      }
      _notify();
      if (canOperate) unawaited(refresh());
    }
  }

  Future<bool> saveCamera(Camera camera) async {
    if (saving || presetBusy || !_storageHealthy) return false;
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
    if (saving || presetBusy || !_storageHealthy) return false;
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
      _cancelPreset();
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
