import 'dart:math';
import 'dart:typed_data';

import 'package:cobs_codec/cobs_codec.dart';

/// One decoded accelerometer sample. X/Y/Z are already in **milli-g** — the
/// firmware transmits `raw16 >> 4`, which equals mg in high-resolution ±2 g
/// mode, so the host applies no further scaling. See TELEMETRY_PROTOCOL.md.
class Sample {
  Sample(this.t, this.x, this.y, this.z)
      : magnitude = sqrt(x * x.toDouble() + y * y.toDouble() + z * z.toDouble());

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
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
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
