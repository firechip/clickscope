import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flusbserial/flusbserial.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'telemetry.dart';

/// Verbose serial log — prints to the `flutter run` console so we can trace
/// exactly what the flusbserial/libusb layer does on connect/disconnect.
void _slog(String m) => debugPrint('[clickscope] $m');

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

enum ConnStatus { disconnected, connecting, connected, reconnecting, error }

final telemetryProvider =
    NotifierProvider<TelemetryController, TelemetryState>(TelemetryController.new);

class TelemetryController extends Notifier<TelemetryState> {
  UsbSerialDevice? _device;
  bool _reading = false;
  bool _disposed = false;
  Future<void>? _readFuture;
  final List<int> _rx = [];

  Timer? _renderTimer;
  Timer? _reconnectTimer;
  bool _reconnecting = false;
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
      _reconnectTimer?.cancel();
      _reading = false;
      _device?.close();
      _recordSink?.close();
    });
    return const TelemetryState();
  }

  /// Synchronous quiesce for app exit, called from [onExitRequested] which
  /// fires on window close (the engine wires the Yaru/WM/Wayland close through
  /// System.requestAppExit).
  ///
  /// Cancelling the 16 ms render timer FIRST is the actual fix for the
  /// window-close CRITICAL cascade: on Flutter 3.44 every presented frame posts
  /// a `g_idle_add(redraw_cb, view)` that fl_view_dispose never removes, so a
  /// queued redraw_cb fires on the freed FlView during teardown. Stop producing
  /// frames and none is pending at teardown → no cascade.
  ///
  /// The device close and CSV flush are fire-and-forget — never awaited on the
  /// UI isolate, where a blocking libusb_close under WSLg could stall exit; the
  /// kernel reclaims the handle on process exit regardless. Idempotent.
  void quiesce() {
    if (_disposed) return;
    _disposed = true;
    _renderTimer?.cancel();
    _renderTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reading = false;
    _slog('quiesce: render pump stopped for exit');
    final d = _device;
    _device = null;
    if (d != null) unawaited(_closeQuietly(d));
    final sink = _recordSink;
    _recordSink = null;
    if (sink != null) {
      unawaited(() async {
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {}
      }());
    }
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
    _slog('connect: ${dev.vendorId.toRadixString(16)}:'
        '${dev.productId.toRadixString(16)} addr=${dev.identifier}');
    try {
      // Open with a FRESH device object per attempt. flusbserial's open() by
      // VID:PID finds the board's current instance even after it re-enumerates
      // (its libusb address changes on every reset), so a stale address in
      // `dev` is harmless; a used device object, however, is not reusable —
      // hence a new createDevice() each try. Up to 3 tries because a
      // just-disconnected port can briefly report busy while the kernel
      // re-attaches then lets us re-detach its cdc-acm driver.
      UsbSerialDevice? device;
      for (var attempt = 1; attempt <= 3 && device == null; attempt++) {
        device = await _tryOpen(dev, attempt);
        if (device == null && attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      if (device == null) {
        throw Exception('busy: the device is in use by another program');
      }
      await device.setBaudRate(115200).timeout(const Duration(seconds: 3));
      _slog('setBaudRate(115200) ok');
      await device.setDtr(true).timeout(const Duration(seconds: 3));
      _slog('setDtr(true) ok — connected, starting read loop');
      _device = device;
      _reading = true;
      _reconnectTimer?.cancel(); // connected — stop any reconnect watch
      _reconnectTimer = null;
      state = state.copyWith(
        status: ConnStatus.connected,
        message: 'Streaming · 115200 8N1',
      );
      _readFuture = _readLoop();
    } catch (e, st) {
      _slog('CONNECT ERROR: $e');
      _slog('stack: $st');
      try {
        await _device?.close();
      } catch (e2) {
        _slog('close-after-error also failed: $e2');
      }
      _device = null;
      final fault = classifyLinkError(e);
      // If an auto-reconnect watch is running, keep the "reconnecting" status
      // for a recoverable fault so the UI doesn't flicker to a hard error
      // between attempts.
      final reconnecting = _reconnectTimer != null && fault.recoverable;
      state = state.copyWith(
        status: reconnecting ? ConnStatus.reconnecting : ConnStatus.error,
        message: reconnecting
            ? '${fault.message}${fault.codeSuffix} — reconnecting…'
            : '${fault.message}${fault.codeSuffix}',
      );
    }
  }

  /// One open attempt on a fresh device object. Returns the opened device, or
  /// null (having closed it) on any failure — so the caller can retry cleanly.
  Future<UsbSerialDevice?> _tryOpen(UsbDevice dev, int attempt) async {
    final device = UsbSerialDevice.createDevice(dev, type: UsbSerialDevice.cdc);
    if (device == null) {
      throw Exception('createDevice returned null (unsupported device)');
    }
    _slog('open() attempt $attempt…');
    var opened = false;
    try {
      opened = await device.open().timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          _slog('open() attempt $attempt timed out after 4s');
          return false;
        },
      );
    } catch (e) {
      _slog('open() attempt $attempt threw: $e');
      opened = false;
    }
    _slog('open() attempt $attempt -> $opened');
    if (opened) return device;
    // Failed: make sure the handle/interface are released before the next try.
    try {
      await device.close();
    } catch (_) {}
    return null;
  }

  Future<void> disconnect({bool silent = false}) async {
    if (_device != null || _reading) _slog('disconnect(silent=$silent)…');
    // A user-initiated disconnect must stop auto-reconnect; the internal silent
    // disconnect from connect() leaves the watch alone.
    if (!silent) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    _reading = false;
    // Let the in-flight blocking read return and the loop exit BEFORE closing
    // the handle. Closing libusb under a pending transfer leaves the interface
    // claimed, so the next connect fails with "device in use".
    try {
      await _readFuture;
    } catch (e) {
      _slog('read loop ended with: $e');
    }
    _readFuture = null;
    final d = _device;
    _device = null;
    if (d != null) {
      _slog('closing device handle…');
      try {
        await d.close();
        _slog('close() ok');
      } catch (e) {
        _slog('close() ERROR: $e');
      }
      // Give the kernel a moment to re-settle its cdc-acm driver on the port
      // before a reconnect claims it again.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
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
      // flusbserial.read() is a blocking libusb call on this isolate, so keep
      // the timeout tiny and yield with a real timer between empty polls —
      // otherwise a long blocking read freezes the whole UI between frames.
      Uint8List data = Uint8List(0);
      try {
        data = await dev.read(256, 5);
      } catch (e) {
        // A short read timeout is the normal "no data yet" case, not an error.
        if (e.toString().toLowerCase().contains('timeout')) {
          // fall through — data stays empty, the delay below yields the isolate
        } else {
          _slog('read() error (loop exiting): $e');
          if (_reading) {
            _reading = false;
            final fault = classifyLinkError(e);
            _slog('  → ${fault.kind.name} ${fault.code} recoverable=${fault.recoverable}');
            // Free our handle so the port is available for a reconnect.
            final d = _device;
            _device = null;
            if (d != null) unawaited(_closeQuietly(d));
            if (fault.recoverable) {
              // Device gone / link reset (unplug, board reset, or the WSL usb/ip
              // transport dropping URBs) — show it as a disconnect and watch for
              // it to come back rather than flagging a hard error.
              state = state.copyWith(
                status: ConnStatus.reconnecting,
                message: '${fault.message}${fault.codeSuffix} — reconnecting…',
              );
              _startReconnectWatch();
            } else {
              state = state.copyWith(
                status: ConnStatus.error,
                message: '${fault.message}${fault.codeSuffix}',
              );
            }
          }
          return;
        }
      }
      if (data.isNotEmpty) {
        _onData(data); // got a burst — loop again immediately to drain it
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<void> _closeQuietly(UsbSerialDevice d) async {
    try {
      await d.close();
    } catch (_) {}
  }

  /// After an unexpected link loss, poll for the board and reconnect when it
  /// reappears. A manual Disconnect cancels this; a successful connect() too.
  void _startReconnectWatch() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_disposed || _device != null || _reconnecting) return;
      _reconnecting = true;
      try {
        UsbDevice? board;
        for (final d in await scan()) {
          if (isLikelyBoard(d.vendorId)) {
            board = d;
            break;
          }
        }
        if (board != null) {
          _slog('reconnect: board reappeared, reconnecting…');
          await connect(board);
        }
      } catch (_) {
      } finally {
        _reconnecting = false;
      }
    });
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
