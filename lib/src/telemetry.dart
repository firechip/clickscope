import 'dart:math';
import 'dart:typed_data';

import 'package:cobs_codec/cobs_codec.dart';

/// One decoded accelerometer sample. X/Y/Z are already in **milli-g** — the
/// firmware transmits `raw16 >> 4`, which equals mg in high-resolution ±2 g
/// mode, so the host applies no further scaling. See TELEMETRY_PROTOCOL.md.
class Sample {
  Sample(this.t, this.x, this.y, this.z)
      : magnitude =
            sqrt(x * x.toDouble() + y * y.toDouble() + z * z.toDouble());

  /// Host receive time (the wire carries no timestamp).
  final DateTime t;
  final int x;
  final int y;
  final int z;

  /// √(x²+y²+z²) in milli-g — computed once at decode so the UI never does it.
  final double magnitude;
}

/// A decoded 0x00-delimited segment: either a telemetry [sample] or a line of
/// ASCII [text] (the boot banner / error lines / anything that isn't a frame).
class Decoded {
  const Decoded.frame(this.sample)
      : text = null,
        crcError = false;
  const Decoded.text(this.text)
      : sample = null,
        crcError = false;
  const Decoded.badCrc()
      : sample = null,
        text = null,
        crcError = true;

  final Sample? sample;
  final String? text;
  final bool crcError;
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no final xor)
/// over the 6 axis bytes — byte-for-byte the firmware's `crc16_ccitt`.
int crc16Ccitt(List<int> data) {
  var crc = 0xFFFF;
  for (final b in data) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

int _i16(int lo, int hi) {
  final v = lo | (hi << 8);
  return v > 32767 ? v - 65536 : v;
}

/// Decode one 0x00-delimited segment. COBS via the published `cobs_codec`
/// package; a segment that isn't a valid 8-byte CRC-checked frame is surfaced
/// as text (the banner) or a CRC error.
Decoded decodeSegment(List<int> segment, DateTime now) {
  Uint8List payload;
  try {
    payload = cobsDecode(segment);
  } on CobsDecodeException {
    return Decoded.text(_asText(segment));
  }
  if (payload.length != 8) {
    return Decoded.text(_asText(segment));
  }
  final crcRx = payload[6] | (payload[7] << 8);
  if (crc16Ccitt(payload.sublist(0, 6)) != crcRx) {
    return const Decoded.badCrc();
  }
  return Decoded.frame(Sample(
    now,
    _i16(payload[0], payload[1]),
    _i16(payload[2], payload[3]),
    _i16(payload[4], payload[5]),
  ));
}

String _asText(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    if (b >= 0x20 && b < 0x7f) {
      sb.writeCharCode(b);
    } else if (b == 0x09) {
      sb.write('\t');
    }
  }
  return sb.toString().trim();
}

/// Known USB identities of the clickforge firmware backends, so the port picker
/// can label a discovered device by the language that produced it.
const Map<int, Map<int, String>> firmwareIds = {
  0x2E8A: {
    0x0003: 'RP2040 BOOTSEL',
    0x0005: 'Zephyr / Rust / MicroPython',
    0x0007: 'Ada',
    0x000A: 'TinyGo / Zig',
    0x000B: 'FreeRTOS',
    0x000C: 'RT-Thread',
  },
  0x16C0: {0x400E: 'Ruby (PicoRuby)'},
  0x1209: {0xCCCC: 'Forth (zeptoforth)'},
};

/// A friendly label for a VID:PID (falls back to the raw hex identity).
String backendLabel(int vid, int pid) {
  final name = firmwareIds[vid]?[pid];
  final hex = '${_hex4(vid)}:${_hex4(pid)}';
  return name == null ? hex : '$hex · $name';
}

/// True for the Raspberry Pi vendor id the reference boards enumerate under.
bool isLikelyBoard(int vid) => firmwareIds.containsKey(vid);

String _hex4(int v) => v.toRadixString(16).toUpperCase().padLeft(4, '0');

// ===================================================== link fault semantics ==

/// How a serial/USB failure should be surfaced to the user.
enum LinkFaultKind {
  /// The device went away (unplugged, reset, or the WSL usb/ip link dropped).
  /// Not really an "error" — the app releases the handle and auto-reconnects.
  disconnected,

  /// Permission problem opening the device.
  permission,

  /// Another program holds the interface.
  busy,

  /// The operation timed out (device not responding).
  timeout,

  /// A protocol-level fault (stall, overflow, bad parameter).
  protocol,

  /// The device/type isn't supported.
  unsupported,

  /// Anything not otherwise classified.
  unknown,
}

/// A flusbserial/libusb failure mapped to something a human can act on.
class LinkFault {
  const LinkFault(this.kind, this.code, this.message,
      {required this.recoverable});

  /// Semantic category, driving the connection status shown in the UI.
  final LinkFaultKind kind;

  /// The raw `LIBUSB_ERROR_*` name if the failure carried one (else '').
  final String code;

  /// Short, user-facing explanation.
  final String message;

  /// True when it makes sense to keep watching for the device to come back
  /// (a dropped/reset link), false for a fault the user must fix (permission,
  /// busy, unsupported).
  final bool recoverable;

  /// The libusb code in parentheses, for the detail line ('' when none).
  String get codeSuffix => code.isEmpty ? '' : ' ($code)';
}

/// Human descriptions for every `libusb_error` name (from libusb.h), plus the
/// category and whether the app should try to recover. flusbserial throws
/// strings like `bulkTransferIn error: LIBUSB_ERROR_NO_DEVICE`
/// (`_libusb.describeError` == `libusb_error_name`), so we key off that token.
const Map<String, LinkFault> _libusbFaults = {
  'LIBUSB_ERROR_IO': LinkFault(
      LinkFaultKind.disconnected, 'LIBUSB_ERROR_IO', 'Link dropped (I/O error)',
      recoverable: true),
  'LIBUSB_ERROR_INVALID_PARAM': LinkFault(LinkFaultKind.protocol,
      'LIBUSB_ERROR_INVALID_PARAM', 'Invalid USB parameter',
      recoverable: false),
  'LIBUSB_ERROR_ACCESS': LinkFault(
      LinkFaultKind.permission,
      'LIBUSB_ERROR_ACCESS',
      'Permission denied — add yourself to the "dialout" group, or grant the '
          'snap raw-usb, then reconnect',
      recoverable: false),
  'LIBUSB_ERROR_NO_DEVICE': LinkFault(LinkFaultKind.disconnected,
      'LIBUSB_ERROR_NO_DEVICE', 'Device disconnected',
      recoverable: true),
  'LIBUSB_ERROR_NOT_FOUND': LinkFault(LinkFaultKind.disconnected,
      'LIBUSB_ERROR_NOT_FOUND', 'Device interface not found',
      recoverable: true),
  'LIBUSB_ERROR_BUSY': LinkFault(LinkFaultKind.busy, 'LIBUSB_ERROR_BUSY',
      'Device is in use by another program',
      recoverable: false),
  'LIBUSB_ERROR_TIMEOUT': LinkFault(LinkFaultKind.timeout,
      'LIBUSB_ERROR_TIMEOUT', 'Timed out — the device is not responding',
      recoverable: true),
  'LIBUSB_ERROR_OVERFLOW': LinkFault(LinkFaultKind.protocol,
      'LIBUSB_ERROR_OVERFLOW', 'USB overflow (device sent more than requested)',
      recoverable: true),
  'LIBUSB_ERROR_PIPE': LinkFault(
      LinkFaultKind.disconnected, 'LIBUSB_ERROR_PIPE', 'Endpoint stalled',
      recoverable: true),
  'LIBUSB_ERROR_INTERRUPTED': LinkFault(LinkFaultKind.disconnected,
      'LIBUSB_ERROR_INTERRUPTED', 'Transfer interrupted',
      recoverable: true),
  'LIBUSB_ERROR_NO_MEM': LinkFault(
      LinkFaultKind.unknown, 'LIBUSB_ERROR_NO_MEM', 'Out of memory',
      recoverable: false),
  'LIBUSB_ERROR_NOT_SUPPORTED': LinkFault(LinkFaultKind.unsupported,
      'LIBUSB_ERROR_NOT_SUPPORTED', 'Not supported on this platform',
      recoverable: false),
  'LIBUSB_ERROR_OTHER': LinkFault(
      LinkFaultKind.unknown, 'LIBUSB_ERROR_OTHER', 'USB error',
      recoverable: true),
};

/// Map any flusbserial/libusb failure (a thrown String, Exception, or Dart
/// error) to a [LinkFault] with a semantic category and message. Recognises the
/// `LIBUSB_ERROR_*` token first, then flusbserial's own messages and the app's
/// own bounded-open timeout / unsupported-device exceptions.
LinkFault classifyLinkError(Object error) {
  final raw = error.toString();
  final token = RegExp(r'LIBUSB_ERROR_[A-Z_]+').firstMatch(raw)?.group(0);
  if (token != null) {
    final f = _libusbFaults[token];
    if (f != null) return f;
    return LinkFault(LinkFaultKind.unknown, token, 'USB error',
        recoverable: true);
  }
  final low = raw.toLowerCase();
  if (low.contains('unsupported') ||
      low.contains('createdevice returned null')) {
    return const LinkFault(LinkFaultKind.unsupported, '',
        'Unsupported device (no CDC serial interface)',
        recoverable: false);
  }
  if (low.contains('timed out') || low.contains('timeout')) {
    return const LinkFault(LinkFaultKind.timeout, '',
        'Timed out opening the device — is it still attached?',
        recoverable: true);
  }
  if (low.contains('busy') || low.contains('in use')) {
    return const LinkFault(
        LinkFaultKind.busy, '', 'Device is in use by another program',
        recoverable: false);
  }
  if (low.contains('permission') || low.contains('access')) {
    return const LinkFault(
        LinkFaultKind.permission, '', 'Permission denied opening the device',
        recoverable: false);
  }
  if (low.contains('libusb initialization')) {
    return const LinkFault(
        LinkFaultKind.unsupported, '', 'libusb is unavailable',
        recoverable: false);
  }
  return LinkFault(LinkFaultKind.unknown, '', 'Error: $raw',
      recoverable: false);
}
