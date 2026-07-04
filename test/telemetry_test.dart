import 'package:cobs_codec/cobs_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clickscope/src/telemetry.dart';

void main() {
  test('decodes the reference frame to milli-g', () {
    // On-wire frame minus the trailing 0x00 delimiter.
    const seg = [0x04, 0x55, 0xff, 0x08, 0x05, 0x08, 0x04, 0xc4, 0x2b];
    final d = decodeSegment(seg, DateTime(2026));
    expect(d.sample, isNotNull);
    expect(d.crcError, isFalse);
    expect(d.sample!.x, -171);
    expect(d.sample!.y, 8);
    expect(d.sample!.z, 1032);
  });

  test('CRC-16/CCITT-FALSE matches the spec vector', () {
    // "123456789" -> 0x29B1 for CRC-16/CCITT-FALSE.
    expect(crc16Ccitt('123456789'.codeUnits), 0x29B1);
  });

  test('a bad-CRC frame is rejected, not plotted', () {
    // Valid COBS of an 8-byte payload whose CRC field (0x0000) is wrong.
    final seg = cobsEncode(const [0x55, 0xFF, 0x08, 0x00, 0x08, 0x04, 0x00, 0x00]);
    final d = decodeSegment(seg, DateTime(2026));
    expect(d.crcError, isTrue);
    expect(d.sample, isNull);
  });

  test('a non-frame segment surfaces as text (the banner)', () {
    final seg = 'WHO_AM_I=0x33 OK'.codeUnits;
    final d = decodeSegment(seg, DateTime(2026));
    expect(d.text, contains('WHO_AM_I=0x33'));
    expect(d.sample, isNull);
  });

  test('backend labels map known firmware VID:PIDs', () {
    expect(backendLabel(0x2E8A, 0x000B), contains('FreeRTOS'));
    expect(backendLabel(0x2E8A, 0x000C), contains('RT-Thread'));
    expect(isLikelyBoard(0x2E8A), isTrue);
    expect(isLikelyBoard(0x1234), isFalse);
  });
}
