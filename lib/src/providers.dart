import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flusbserial/flusbserial.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'telemetry.dart';

/// App theme mode (light / dark / system), toggled from Settings.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;
  void set(ThemeMode mode) => state = mode;
}

/// Immutable snapshot of the connection + telemetry the whole UI reads.
class TelemetryState {
  const TelemetryState({
    this.status = ConnStatus.disconnected,
    this.portLabel = '—',
    this.message = 'Not connected',
    this.whoAmI = '',
    this.whoAmIOk = false,
    this.framesOk = 0,
    this.crcErrors = 0,
    this.droppedFrames = 0,
    this.fps = 0,
    this.recording = false,
    this.recordPath = '',
    this.recordCount = 0,
    this.log = const [],
    this.samples = const [],
  });

  final ConnStatus status;
  final String portLabel;
  final String message;
  final String whoAmI;
  final bool whoAmIOk;
  final int framesOk;
  final int crcErrors;
  final int droppedFrames;
  final double fps;
  final bool recording;
  final String recordPath;
  final int recordCount;

  /// Recent ASCII lines from the device (boot banner, error lines).
  final List<String> log;

  /// Bounded window of the most recent samples, for plotting.
  final List<Sample> samples;

  bool get isConnected => status == ConnStatus.connected;

  double get crcRate {
    final total = framesOk + crcErrors;
    return total == 0 ? 0 : crcErrors / total;
  }

  Sample? get latest => samples.isEmpty ? null : samples.last;

  TelemetryState copyWith({
    ConnStatus? status,
    String? portLabel,
    String? message,
    String? whoAmI,
    bool? whoAmIOk,
    int? framesOk,
    int? crcErrors,
    int? droppedFrames,
    double? fps,
    bool? recording,
    String? recordPath,
    int? recordCount,
    List<String>? log,
    List<Sample>? samples,
  }) {
    return TelemetryState(
      status: status ?? this.status,
      portLabel: portLabel ?? this.portLabel,
      message: message ?? this.message,
      whoAmI: whoAmI ?? this.whoAmI,
      whoAmIOk: whoAmIOk ?? this.whoAmIOk,
      framesOk: framesOk ?? this.framesOk,
      crcErrors: crcErrors ?? this.crcErrors,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      fps: fps ?? this.fps,
      recording: recording ?? this.recording,
      recordPath: recordPath ?? this.recordPath,
      recordCount: recordCount ?? this.recordCount,
      log: log ?? this.log,
      samples: samples ?? this.samples,
    );
  }
}

enum ConnStatus { disconnected, connecting, connected, error }

final telemetryProvider =
    NotifierProvider<TelemetryController, TelemetryState>(TelemetryController.new);

class TelemetryController extends Notifier<TelemetryState> {
  UsbSerialDevice? _device;
  bool _reading = false;
  final List<int> _rx = [];

  Timer? _renderTimer;
  final List<Sample> _incoming = [];
  final ListQueue<Sample> _window = ListQueue<Sample>();
  final List<String> _log = [];

  static const int windowCapacity = 1800; // ~60 s at up to 30 Hz
  static const int logCapacity = 200;

  int _framesOk = 0;
  int _crcErrors = 0;
  int _dropped = 0;
  final ListQueue<int> _frameStamps = ListQueue<int>(); // ms, for fps
  String _whoAmI = '';
  bool _whoAmIOk = false;
  bool _dirty = false;

  IOSink? _recordSink;
  int _recordCount = 0;
  String _recordPath = '';

  @override
  TelemetryState build() {
    _renderTimer =
        Timer.periodic(const Duration(milliseconds: 16), (_) => _flush());
    ref.onDispose(() {
      _renderTimer?.cancel();
      _reading = false;
      _device?.close();
      _recordSink?.close();
    });
    return const TelemetryState();
  }

  // ---- device discovery -----------------------------------------------------

  Future<List<UsbDevice>> scan() async {
    try {
      return await UsbSerialDevice.listDevices();
    } catch (_) {
      return const [];
    }
  }

  // ---- connect / disconnect -------------------------------------------------

  Future<void> connect(UsbDevice dev) async {
    await disconnect(silent: true);
    _resetCounters();
    state = state.copyWith(
      status: ConnStatus.connecting,
      message: 'Opening ${backendLabel(dev.vendorId, dev.productId)}…',
      portLabel: backendLabel(dev.vendorId, dev.productId),
    );
    try {
      final device = UsbSerialDevice.createDevice(dev, type: UsbSerialDevice.cdc);
      if (device == null) throw Exception('unsupported device');
      if (!await device.open()) throw Exception('could not open');
      await device.setBaudRate(115200); // never 1200 — that reboots to BOOTSEL
      await device.setDtr(true);
      _device = device;
      _reading = true;
      state = state.copyWith(
        status: ConnStatus.connected,
        message: 'Streaming · 115200 8N1',
      );
      unawaited(_readLoop());
    } catch (e) {
      _device = null;
      state = state.copyWith(status: ConnStatus.error, message: 'Error: $e');
    }
  }

  Future<void> disconnect({bool silent = false}) async {
    _reading = false;
    final d = _device;
    _device = null;
    try {
      await d?.close();
    } catch (_) {}
    if (!silent) {
      state = state.copyWith(
        status: ConnStatus.disconnected,
        message: 'Disconnected',
      );
    }
  }

  Future<void> _readLoop() async {
    final dev = _device;
    while (_reading && dev != null) {
      try {
        final data = await dev.read(256, 40);
        if (data.isNotEmpty) _onData(data);
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('timeout')) continue; // no data this interval
        if (_reading) {
          _reading = false;
          state = state.copyWith(
            status: ConnStatus.error,
            message: 'Link lost: $e',
          );
        }
      }
    }
  }

  // ---- framing + decode -----------------------------------------------------

  void _onData(Uint8List data) {
    _rx.addAll(data);
    var zero = _rx.indexOf(0);
    while (zero >= 0) {
      final segment = _rx.sublist(0, zero);
      _rx.removeRange(0, zero + 1);
      if (segment.isNotEmpty) _handleSegment(segment);
      zero = _rx.indexOf(0);
    }
    if (_rx.length > 4096) _rx.clear(); // runaway guard
  }

  void _handleSegment(List<int> segment) {
    final now = DateTime.now();
    final d = decodeSegment(segment, now);
    if (d.crcError) {
      _crcErrors++;
      _dirty = true;
      return;
    }
    if (d.text != null) {
      _onText(d.text!);
      return;
    }
    final s = d.sample!;
    _framesOk++;
    _frameStamps.addLast(now.millisecondsSinceEpoch);
    _incoming.add(s);
    _recordSample(s);
    _dirty = true;
  }

  void _onText(String line) {
    if (line.isEmpty) return;
    _log.add(line);
    while (_log.length > logCapacity) {
      _log.removeAt(0);
    }
    final m = RegExp(r'WHO_AM_I=0x([0-9a-fA-F]+)').firstMatch(line);
    if (m != null) {
      _whoAmI = '0x${m.group(1)!.toUpperCase()}';
      _whoAmIOk = line.contains('OK');
    }
    _dirty = true;
  }

  // ---- ~60 fps flush into immutable state -----------------------------------

  void _flush() {
    // fps over a 2 s trailing window (recompute even when idle so it decays).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    while (_frameStamps.isNotEmpty && nowMs - _frameStamps.first > 2000) {
      _frameStamps.removeFirst();
    }
    final fps = _frameStamps.length / 2.0;

    if (_incoming.isNotEmpty) {
      _window.addAll(_incoming);
      _incoming.clear();
      while (_window.length > windowCapacity) {
        _window.removeFirst();
      }
    }
    if (!_dirty && (fps - state.fps).abs() < 0.05) return;
    _dirty = false;

    state = state.copyWith(
      framesOk: _framesOk,
      crcErrors: _crcErrors,
      droppedFrames: _dropped,
      fps: fps,
      whoAmI: _whoAmI,
      whoAmIOk: _whoAmIOk,
      recordCount: _recordCount,
      log: List.unmodifiable(_log),
      samples: List.unmodifiable(_window),
    );
  }

  void _resetCounters() {
    _framesOk = 0;
    _crcErrors = 0;
    _dropped = 0;
    _whoAmI = '';
    _whoAmIOk = false;
    _rx.clear();
    _incoming.clear();
    _window.clear();
    _frameStamps.clear();
    _log.clear();
    state = state.copyWith(
      framesOk: 0,
      crcErrors: 0,
      droppedFrames: 0,
      fps: 0,
      whoAmI: '',
      whoAmIOk: false,
      log: const [],
      samples: const [],
    );
  }

  void clearBuffers() => _resetCounters();

  // ---- CSV recording --------------------------------------------------------

  Future<void> toggleRecording() async {
    if (state.recording) {
      await _recordSink?.flush();
      await _recordSink?.close();
      _recordSink = null;
      state = state.copyWith(recording: false);
      return;
    }
    final home = Platform.environment['HOME'] ?? '.';
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    _recordPath = '$home/clickscope-$ts.csv';
    _recordCount = 0;
    final f = File(_recordPath);
    _recordSink = f.openWrite();
    _recordSink!.writeln('host_iso,x_mg,y_mg,z_mg,magnitude_mg');
    state = state.copyWith(
      recording: true,
      recordPath: _recordPath,
      recordCount: 0,
    );
  }

  void _recordSample(Sample s) {
    final sink = _recordSink;
    if (sink == null) return;
    sink.writeln(
      '${s.t.toIso8601String()},${s.x},${s.y},${s.z},${s.magnitude.toStringAsFixed(1)}',
    );
    _recordCount++;
  }
}
