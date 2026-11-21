import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/camera.dart';
import 'models/camera_settings.dart';
import 'models/camera_preset.dart';
import 'models/camera_limits.dart';
import 'services/camera_limit_tester.dart';
import 'services/camera_store.dart';
import 'services/visca_client.dart';
import 'services/visca_protocol.dart';

enum CameraConnection { none, connecting, connected, offline, paused }

class _PanTiltMotion {
  _PanTiltMotion(
    this.client,
    this.description,
    this.panSpeed,
    this.tiltSpeed,
    this.horizontal,
    this.vertical,
    this.limits,
  );

  final ViscaClient client;
  final String description;
  final int panSpeed, tiltSpeed;
  final CameraLimits? limits;
  int horizontal, vertical;
  int? lastPan, lastTilt;
  int stillPan = 0, stillTilt = 0;
  final elapsed = Stopwatch();
}

class PtzController extends ChangeNotifier {
  PtzController({
    CameraStore? store,
    CameraLimitTester Function(ViscaClient)? limitTesterFactory,
  }) : _store = store ?? PreferencesCameraStore(),
       _limitTesterFactory = limitTesterFactory ?? CameraLimitTester.new;
  final CameraStore _store;
  final CameraLimitTester Function(ViscaClient) _limitTesterFactory;
  CameraLimitTester? _limitTester;
  bool _testingLimits = false;
  bool _limitCancelled = false;
  List<Camera> cameras = [];
  final List<CommandLog> logs = [];
  Camera? selected;
  CameraConnection connection = CameraConnection.none;
  bool loading = true;
  bool saving = false;
  bool switching = false;
  bool debug = false;
  bool syncPanTilt = false;
  bool moveUntilStopped = false;
  bool savePresetMode = false;
  bool saveExposureWithPreset = false;
  bool presetBusy = false;
  bool _recalling = false;
  int _presetGeneration = 0;
  bool sideNavigation = false;
  bool _disposed = false;
  bool _paused = false;
  Future<void>? _queryFuture;
  final Set<int> _pendingQueries = {};
  bool _storageHealthy = true;
  String? message;
  // Speeds are controller selections included in movement commands. The common
  // VISCA inquiries do not report the camera's current command-speed settings.
  int panSpeed = 8, tiltSpeed = 6, zoomSpeed = 3, focusSpeed = 3;
  int? pan, tilt, zoom;
  bool? autofocus;
  final Map<int, int?> imageValues = {};
  int? get aperture => imageValues[0x4b];
  int? get shutterSpeed => imageValues[0x4a];
  int? get gain => imageValues[0x4c];
  int? get redGain => imageValues[0x43];
  int? get blueGain => imageValues[0x44];
  int? exposureMode, whiteBalanceMode;
  String get exposureModeLabel =>
      Visca.modeLabel(exposureMode, Visca.exposureModes);
  String get whiteBalanceModeLabel =>
      Visca.modeLabel(whiteBalanceMode, Visca.whiteBalanceModes);
  DateTime? lastReply;
  ViscaClient? _client;
  ViscaClient? _testClient;
  bool _testingConnection = false;
  ViscaClient? _motionClient;
  List<int>? _motionStop;
  Object? _motionOwner;
  _PanTiltMotion? _panTiltMotion;
  Timer? _pollTimer;
  Timer? _watchdog;

  bool get canControl => _client != null && !switching && !_paused;
  bool get canTransferCameraSettings =>
      !loading && !saving && !switching && !presetBusy && !_testingConnection;

  CameraSettings exportCameraSettings() =>
      CameraSettings(cameras: cameras, nextId: _store.nextId);

  Future<bool> importCameraSettings(CameraSettings settings) async {
    if (!canTransferCameraSettings || _disposed) return false;
    saving = switching = true;
    message = null;
    _notify();
    try {
      await endMotion();
      // Persist the entire validated setup and sequence in one write. Failure
      // leaves the existing list, selection, and UDP connection intact.
      await _store.save(settings.cameras, nextId: settings.nextId);
      if (_disposed) return false;
      final previous = selected;
      final next = settings.cameras.firstWhere(
        (camera) =>
            camera.id == previous?.id &&
            camera.host == previous?.host &&
            camera.port == previous?.port,
        orElse: () => settings.cameras.first,
      );
      cameras = List.of(settings.cameras);
      _storageHealthy = true;
      switching = false;
      await select(next);
      return true;
    } catch (error) {
      message = 'Could not import camera settings: $error';
      return false;
    } finally {
      saving = switching = false;
      _notify();
    }
  }

  int get nextCameraId {
    final used = cameras.map((camera) => camera.id).toSet();
    // Continue the saved sequence across removals and restarts. Once 255 has
    // been assigned, reuse vacant IDs without changing any existing camera.
    for (var id = _store.nextId; id <= 255; id++) {
      if (!used.contains(id)) return id;
    }
    return Iterable<int>.generate(
      255,
      (index) => index + 1,
    ).firstWhere((id) => !used.contains(id));
  }

  bool get canOperate => canControl && !presetBusy;
  bool get moving => _motionClient != null;
  bool motionOwnedBy(Object owner) => moving && _motionOwner == owner;
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
          DateTime.now().difference(reference).inSeconds >= 15 &&
          connection != CameraConnection.offline) {
        connection = CameraConnection.offline;
        pan = tilt = zoom = null;
        autofocus = null;
        exposureMode = whiteBalanceMode = null;
        imageValues.clear();
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
    await _client?.close();
    _client = null;
    await _queryFuture;
    selected = camera;
    pan = tilt = zoom = null;
    autofocus = null;
    exposureMode = whiteBalanceMode = null;
    imageValues.clear();
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
        await client.close();
        return;
      }
      _openedAt = DateTime.now();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_query([0x12, 0x47], scheduled: true)),
      );
    } catch (error) {
      await client.close();
      _client = null;
      connection = CameraConnection.offline;
      message = 'Could not open UDP socket: $error';
    } finally {
      switching = false;
      _notify();
    }
    await refresh();
  }

  /// Read focus mode first so manual controls reflect the selected camera promptly.
  /// A camera selection or explicit refresh reads every displayed setting.
  Future<void> refresh() =>
      _query([0x38, 0x12, 0x47, 0x39, 0x35, ...Visca.imageValueInquiries.keys]);

  /// Read only the settings displayed on the Image page, once on entry.
  Future<void> refreshImageSettings() =>
      _query([0x38, 0x39, 0x35, ...Visca.imageValueInquiries.keys]);

  /// The Control page displays focus, exposure, white balance, and iris values.
  Future<void> refreshControlStatus() => _query([0x38, 0x39, 0x35, 0x4b]);

  /// The preset dialog shows freshly queried exposure mode and iris values.
  Future<void> refreshPresetSettings() => _query([0x39, 0x4b]);

  /// Check unsaved network settings with a read-only pan/tilt inquiry.
  Future<bool> testCameraConnection(Camera camera) async {
    if (_disposed ||
        _paused ||
        switching ||
        presetBusy ||
        saving ||
        _testingConnection) {
      return false;
    }
    _testingConnection = true;
    var suspended = false;
    ViscaClient? temporary;
    try {
      await endMotion();
      final active = _client;
      final current = active?.camera;
      final sameEndpoint =
          current?.host == camera.host && current?.port == camera.port;
      final reuse =
          active != null &&
          sameEndpoint &&
          current!.transport == camera.transport &&
          current.localPort == camera.localPort;
      late final ViscaClient client;
      if (reuse) {
        client = active;
      } else {
        // Free an occupied fixed source port, and avoid resetting Sony's
        // sequence while another client is still using that camera endpoint.
        if (active != null &&
            ((camera.localPort != 0 &&
                    camera.localPort == current!.localPort) ||
                (sameEndpoint &&
                    (camera.transport == ViscaTransport.sony ||
                        current!.transport == ViscaTransport.sony)))) {
          suspended = true;
          switching = true;
          _pollTimer?.cancel();
          _client = null;
          await active.close();
          _notify();
          await _queryFuture;
        }
        if (_disposed || _paused) return false;
        client = ViscaClient(
          camera,
          onLog: (log) {
            if (_disposed) return;
            logs.insert(0, log);
            if (logs.length > 200) logs.removeLast();
            _notify();
          },
          onReply: () {},
          onError: (_) {},
        );
        temporary = _testClient = client;
        await client.open();
      }
      if (_disposed || _paused) return false;
      final reply = await client.send(
        'Test camera connection',
        Visca.panTiltInquiry,
      );
      if (_disposed || _paused || reply == null || reply.length != 11) {
        return false;
      }
      Visca.nibbles(reply.sublist(2, 6), signed: true);
      Visca.nibbles(reply.sublist(6, 10), signed: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      await temporary?.close();
      _testClient = null;
      if (suspended && !_disposed) {
        switching = false;
        if (selected != null) await select(selected!);
      }
      _testingConnection = false;
    }
  }

  Future<void> cancelLimitTest() async {
    if (_testingLimits) _limitCancelled = true;
    await _limitTester?.cancel();
  }

  /// Sweep the entered camera and persist all six bounds only after success.
  Future<CameraLimits> testAndSaveCameraLimits(Camera camera) async {
    if (_disposed ||
        _paused ||
        switching ||
        presetBusy ||
        saving ||
        _testingConnection) {
      throw StateError('Camera is busy');
    }
    if (!_storageHealthy ||
        (cameras.length >= 8 && !cameras.any((c) => c.id == camera.id))) {
      throw StateError('Camera configuration cannot be saved');
    }
    // Validate before moving or changing the stored camera configuration.
    Camera.fromJson(camera.toJson());
    _testingConnection = true;
    _testingLimits = true;
    _limitCancelled = false;
    switching = true;
    _pollTimer?.cancel();
    _notify();
    ViscaClient? client;
    try {
      await endMotion();
      await _client?.close();
      _client = null;
      await _queryFuture;
      if (_disposed || _paused || _limitCancelled) {
        throw StateError('Limit test stopped');
      }
      client = ViscaClient(
        camera,
        onLog: (log) {
          if (_disposed) return;
          logs.insert(0, log);
          if (logs.length > 200) logs.removeLast();
          _notify();
        },
        onReply: () {},
        onError: (_) {},
      );
      _limitTester = _limitTesterFactory(client);
      await client.open();
      if (_disposed || _paused || _limitCancelled) {
        throw StateError('Limit test stopped');
      }
      final limits = await _limitTester!.run();
      if (_disposed || _paused || _limitCancelled) {
        throw StateError('Limit test stopped');
      }
      final updatedCamera = camera.withLimits(limits);
      final updated = List<Camera>.of(cameras);
      final index = updated.indexWhere((c) => c.id == camera.id);
      if (index < 0) {
        updated.add(updatedCamera);
      } else {
        updated[index] = updatedCamera;
      }
      await _store.save(updated);
      cameras = updated;
      if (selected == null || selected?.id == camera.id) {
        selected = updatedCamera;
      }
      return limits;
    } finally {
      // Keep the socket alive until the final stop requests have finished.
      await _limitTester?.cancel();
      _limitTester = null;
      await client?.close();
      switching = false;
      _testingConnection = false;
      _testingLimits = false;
      if (!_disposed && selected != null) await select(selected!);
      _notify();
    }
  }

  Future<void> _query(Iterable<int> registers, {bool scheduled = false}) {
    if (!canOperate || moving || _client == null || _disposed) {
      return Future.value();
    }
    // Automatic ticks never extend an existing user-requested refresh.
    if (scheduled && _queryFuture != null) return Future.value();
    _pendingQueries.addAll(registers);
    return _queryFuture ??= _drainQueries(_client!);
  }

  Future<void> _drainQueries(ViscaClient client) async {
    try {
      while (_pendingQueries.isNotEmpty &&
          _client == client &&
          !_disposed &&
          !_paused &&
          canOperate &&
          !moving) {
        final register = _pendingQueries.first;
        _pendingQueries.remove(register);
        await _readValue(client, register);
      }
    } finally {
      _pendingQueries.clear();
      _queryFuture = null;
    }
  }

  Future<void> _readValue(ViscaClient client, int register) async {
    final (description, inquiry) = switch (register) {
      0x12 => ('pan / tilt position', Visca.panTiltInquiry),
      0x47 => ('zoom position', Visca.zoomInquiry),
      0x38 => ('autofocus mode', Visca.focusModeInquiry),
      0x39 => ('exposure mode', Visca.exposureModeInquiry),
      0x35 => ('white balance mode', Visca.whiteBalanceModeInquiry),
      _ => (
        Visca.imageValueInquiries[register]!,
        Visca.imageValueInquiry(register),
      ),
    };
    final reply = await client.send('Read $description', inquiry);
    if (_client != client || _disposed || _paused) return;
    try {
      switch (register) {
        case 0x12:
          if (reply != null && reply.length == 11) {
            pan = Visca.nibbles(reply.sublist(2, 6), signed: true);
            tilt = Visca.nibbles(reply.sublist(6, 10), signed: true);
          }
        case 0x47:
          if (reply != null && reply.length == 7) {
            zoom = Visca.nibbles(reply.sublist(2, 6));
          }
        case 0x38:
          autofocus =
              reply != null && reply.length == 4 && [2, 3].contains(reply[2])
              ? reply[2] == 2
              : null;
        case 0x39:
          exposureMode = reply != null && reply.length == 4 ? reply[2] : null;
        case 0x35:
          whiteBalanceMode = reply != null && reply.length == 4
              ? reply[2]
              : null;
        default:
          imageValues[register] = null;
          if (reply != null && reply.length == 7) {
            imageValues[register] = Visca.nibbles(reply.sublist(2, 6));
          }
      }
    } on FormatException {
      message = 'Invalid $description data received';
    }
    _notify();
  }

  List<int> _settingsChangedBy(List<int> bytes) {
    if (bytes.length < 5 || bytes[1] != 1 || bytes[2] != 4) return const [];
    return switch (bytes[3]) {
      0x38 => [0x38],
      0x39 => [0x39],
      0x35 => [0x35],
      0x0b || 0x4b => [0x4b],
      0x0a || 0x4a => [0x4a],
      0x0c || 0x4c => [0x4c],
      0x03 || 0x43 => [0x43],
      0x04 || 0x44 => [0x44],
      // One-push balance can change both color gains as well as mode status.
      0x10 => [0x35, 0x43, 0x44],
      _ => const [],
    };
  }

  Future<void> command(String description, List<int> bytes) async {
    if (!canOperate || moving) return;
    message = null;
    final client = _client!;
    final changedSettings = _settingsChangedBy(bytes);
    final reply = await client.send(
      description,
      bytes,
      motion: bytes.length > 3 && bytes[2] == 6 && bytes[3] == 4,
      waitForCompletion: changedSettings.isNotEmpty,
      replyTimeout: bytes.length > 3 && bytes[2] == 4 && bytes[3] == 0x10
          ? const Duration(seconds: 10)
          : null,
    );
    if (_client != client || _disposed) return;
    if (reply == null && message == null) {
      message = 'No acknowledgement: $description';
    }
    _notify();
    if (changedSettings.isNotEmpty) await _query(changedSettings);
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

  void setMoveUntilStopped(bool value) {
    if (moveUntilStopped == value) return;
    moveUntilStopped = value;
    unawaited(endMotion());
    _notify();
  }

  /// Start a direction-pad move, monitoring limits in both input modes.
  bool startPanTilt(
    String description,
    int horizontal,
    int vertical, {
    Object? owner,
  }) {
    if (_disposed || !canOperate || _client == null) return false;
    Visca.drive(panSpeed, tiltSpeed, horizontal, vertical);
    final motionOwner = owner ?? description;
    final previous = _panTiltMotion;
    if (moving &&
        (!moveUntilStopped ||
            previous == null ||
            _motionOwner == motionOwner)) {
      return false;
    }
    final motion = _PanTiltMotion(
      _client!,
      description,
      panSpeed,
      tiltSpeed,
      horizontal,
      vertical,
      selected?.limits,
    );
    _motionClient = motion.client;
    _motionStop = Visca.drive(panSpeed, tiltSpeed, 3, 3);
    _motionOwner = motionOwner;
    _panTiltMotion = motion;
    message = null;
    _notify();
    unawaited(_runPanTilt(motion, replacing: previous != null));
    return true;
  }

  bool _panTiltActive(_PanTiltMotion motion) =>
      _panTiltMotion == motion &&
      _motionClient == motion.client &&
      _client == motion.client &&
      !_disposed &&
      !_paused &&
      !switching;

  Future<({int pan, int tilt})?> _motionPosition(_PanTiltMotion motion) async {
    if (!_panTiltActive(motion)) return null;
    final reply = await motion.client.send(
      'Read moving pan / tilt',
      Visca.panTiltInquiry,
    );
    if (!_panTiltActive(motion)) return null;
    if (reply == null || reply.length != 11) {
      throw StateError('Could not read pan / tilt position');
    }
    final position = (
      pan: Visca.nibbles(reply.sublist(2, 6), signed: true),
      tilt: Visca.nibbles(reply.sublist(6, 10), signed: true),
    );
    pan = position.pan;
    tilt = position.tilt;
    _notify();
    return position;
  }

  void _applyMovementLimits(
    _PanTiltMotion motion,
    int pan,
    int tilt, {
    bool monitorStall = false,
  }) {
    if (monitorStall) {
      motion.stillPan = pan == motion.lastPan ? motion.stillPan + 1 : 0;
      motion.stillTilt = tilt == motion.lastTilt ? motion.stillTilt + 1 : 0;
    }
    motion.lastPan = pan;
    motion.lastTilt = tilt;
    final limits = motion.limits;
    if (limits != null) {
      if (motion.horizontal == 1 && pan <= limits.panMin ||
          motion.horizontal == 2 && pan >= limits.panMax) {
        motion.horizontal = 3;
      }
      if (motion.vertical == 1 && tilt >= limits.tiltMax ||
          motion.vertical == 2 && tilt <= limits.tiltMin) {
        motion.vertical = 3;
      }
    }
    // Also detect the camera's own end stops when no saved bounds exist.
    if (monitorStall && motion.elapsed.elapsed >= const Duration(seconds: 2)) {
      if (motion.stillPan >= 6) motion.horizontal = 3;
      if (motion.stillTilt >= 6) motion.vertical = 3;
    }
  }

  Future<bool> _sendPanTilt(_PanTiltMotion motion) async {
    if (!_panTiltActive(motion)) return false;
    final reply = await motion.client.send(
      motion.description,
      Visca.drive(
        motion.panSpeed,
        motion.tiltSpeed,
        motion.horizontal,
        motion.vertical,
      ),
      motion: true,
    );
    if (!_panTiltActive(motion)) return false;
    if (reply == null) {
      throw StateError('Camera did not acknowledge pan / tilt movement');
    }
    return true;
  }

  Future<void> _runPanTilt(
    _PanTiltMotion motion, {
    required bool replacing,
  }) async {
    try {
      if (replacing) {
        await motion.client.send(
          'Stop previous direction',
          Visca.drive(motion.panSpeed, motion.tiltSpeed, 3, 3),
          priority: true,
        );
      }
      await _queryFuture;
      if (!_panTiltActive(motion)) return;
      final initial = await _motionPosition(motion);
      if (initial == null || !_panTiltActive(motion)) return;
      _applyMovementLimits(motion, initial.pan, initial.tilt);
      if (motion.horizontal == 3 && motion.vertical == 3) {
        await endMotion();
        return;
      }
      if (!await _sendPanTilt(motion)) return;
      motion.elapsed.start();
      while (_panTiltActive(motion)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!_panTiltActive(motion)) return;
        final position = await _motionPosition(motion);
        if (position == null || !_panTiltActive(motion)) return;
        final previousHorizontal = motion.horizontal;
        final previousVertical = motion.vertical;
        _applyMovementLimits(
          motion,
          position.pan,
          position.tilt,
          monitorStall: true,
        );
        if (motion.horizontal == 3 && motion.vertical == 3) {
          await endMotion();
          return;
        }
        if ((motion.horizontal != previousHorizontal ||
                motion.vertical != previousVertical) &&
            !await _sendPanTilt(motion)) {
          return;
        }
      }
    } catch (error) {
      if (!_panTiltActive(motion)) return;
      await endMotion();
      if (!_disposed && _client == motion.client && !moving) {
        message = 'Movement stopped: $error';
        _notify();
      }
    }
  }

  Future<void> endMotion({Object? owner}) async {
    if (owner != null && owner != _motionOwner) return;
    if (owner == null && _recalling) {
      await stopAll();
      return;
    }
    final client = _motionClient;
    final stop = _motionStop;
    _panTiltMotion = null;
    _motionClient = null;
    _motionStop = null;
    _motionOwner = null;
    if (client == null || stop == null) return;
    _notify();
    // Stop is prioritized over polling, including an in-flight inquiry.
    await client.send('Stop movement', stop, priority: true);
  }

  Future<void> stopAll() async {
    if (_testingLimits) {
      await cancelLimitTest();
      return;
    }
    if (_client == null) return;
    _cancelPreset();
    _panTiltMotion = null;
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

  void setSaveExposureWithPreset(bool value) {
    saveExposureWithPreset = value;
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
    if (invalid != null || slot < 1 || slot > 9) {
      message = invalid ?? 'Preset cannot be saved to this slot.';
      _notify();
      return false;
    }
    final camera = selected!;
    final client = _client!;
    final generation = ++_presetGeneration;
    final includeExposure = saveExposureWithPreset;
    var snapshotStored = false;
    presetBusy = true;
    message = null;
    _notify();
    try {
      // Finish an in-flight refresh before collecting a consistent snapshot.
      await _queryFuture;
      final position = await _presetRequest(
        client,
        generation,
        'Read preset pan / tilt',
        Visca.panTiltInquiry,
      );
      final zoomReply = await _presetRequest(
        client,
        generation,
        'Read preset zoom',
        Visca.zoomInquiry,
      );
      final focusReply = await _presetRequest(
        client,
        generation,
        'Read preset focus',
        Visca.focusInquiry,
      );
      final modeReply = await _presetRequest(
        client,
        generation,
        'Read preset exposure mode',
        Visca.exposureModeInquiry,
      );
      if (position.length != 11 ||
          zoomReply.length != 7 ||
          focusReply.length != 7 ||
          modeReply.length != 4) {
        throw const FormatException('Invalid preset snapshot data');
      }
      int? savedAperture;
      if (includeExposure && modeReply[2] == 3) {
        final iris = await _presetRequest(
          client,
          generation,
          'Read preset aperture',
          Visca.apertureInquiry,
        );
        if (iris.length != 7) {
          throw const FormatException('Invalid aperture data');
        }
        savedAperture = Visca.nibbles(iris.sublist(2, 6));
        RangeError.checkValueInInterval(savedAperture, 0, 255, 'aperture');
      }
      final saved = CameraPreset(
        slot: slot,
        name: name.trim(),
        pan: Visca.nibbles(position.sublist(2, 6), signed: true),
        tilt: Visca.nibbles(position.sublist(6, 10), signed: true),
        zoom: Visca.nibbles(zoomReply.sublist(2, 6)),
        focus: Visca.nibbles(focusReply.sublist(2, 6)),
        aperture: savedAperture,
      );
      final updatedCamera = camera.withPresets(
        [...camera.presets.where((p) => p.slot != slot), saved]
          ..sort((a, b) => a.slot.compareTo(b.slot)),
      );
      final updated = cameras
          .map((c) => c.id == camera.id ? updatedCamera : c)
          .toList();
      // Persist the snapshot before asking the camera to overwrite its memory.
      if (!_storageHealthy) throw StateError('Setup storage is unavailable');
      await _store.save(updated);
      snapshotStored = true;
      await _presetRequest(
        client,
        generation,
        'Save camera preset $slot',
        Visca.storePreset(slot),
        completion: true,
      );
      cameras = updated;
      if (selected?.id == camera.id) selected = updatedCamera;
      return true;
    } catch (error) {
      String rollbackWarning = '';
      if (snapshotStored) {
        try {
          await _store.save(cameras);
        } catch (_) {
          rollbackWarning =
              ' The previous local snapshot could not be restored.';
        }
      }
      if (_presetActive(generation, client)) {
        message = 'Preset was not saved: $error$rollbackWarning';
      }
      return false;
    } finally {
      if (generation == _presetGeneration) presetBusy = false;
      _notify();
    }
  }

  Future<bool> recallPreset(int slot) async {
    if (!canOperate || moving || slot < 1 || slot > 9) return false;
    final client = _client!;
    final savedAperture = saveExposureWithPreset
        ? preset(slot)?.aperture
        : null;
    final generation = ++_presetGeneration;
    presetBusy = true;
    _recalling = true;
    message = null;
    _notify();
    try {
      await _presetRequest(
        client,
        generation,
        'Recall camera preset $slot',
        Visca.recallPreset(slot),
        completion: true,
        motion: true,
      );
      if (savedAperture != null) {
        await _presetRequest(
          client,
          generation,
          'Restore preset aperture',
          Visca.absoluteAperture(savedAperture),
          completion: true,
        );
        imageValues[0x4b] = savedAperture;
      }
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

  Future<bool> reorderCamera(int oldIndex, int newIndex) async {
    if (saving ||
        switching ||
        presetBusy ||
        _testingConnection ||
        !_storageHealthy ||
        _disposed) {
      return false;
    }
    if (oldIndex < 0 ||
        oldIndex >= cameras.length ||
        newIndex < 0 ||
        newIndex >= cameras.length) {
      return false;
    }
    if (newIndex == oldIndex) return true;
    final updated = List<Camera>.of(cameras);
    updated.insert(newIndex, updated.removeAt(oldIndex));
    // Order is independent of identity; keep the selected camera and socket.
    return _persist(updated);
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
        await _client?.close();
        _client = null;
        selected = null;
        pan = tilt = zoom = null;
        autofocus = null;
        exposureMode = whiteBalanceMode = null;
        imageValues.clear();
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
      await cancelLimitTest();
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
    unawaited(cancelLimitTest());
    unawaited(_testClient?.close());
    _pollTimer?.cancel();
    _watchdog?.cancel();
    final client = _client;
    // Keep the socket alive until the final stop is sent on graceful teardown.
    unawaited(endMotion().whenComplete(() => client?.close()));
    super.dispose();
  }
}
