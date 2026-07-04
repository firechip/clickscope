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
    final seg =
        cobsEncode(const [0x55, 0xFF, 0x08, 0x00, 0x08, 0x04, 0x00, 0x00]);
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

  group('classifyLinkError', () {
    test('an unplug reads as a recoverable disconnect, not a hard error', () {
      // Exactly what flusbserial throws from its read loop.
      final f =
          classifyLinkError('bulkTransferIn error: LIBUSB_ERROR_NO_DEVICE');
      expect(f.kind, LinkFaultKind.disconnected);
      expect(f.recoverable, isTrue);
      expect(f.code, 'LIBUSB_ERROR_NO_DEVICE');
      expect(f.message, 'Device disconnected');
      expect(f.codeSuffix, ' (LIBUSB_ERROR_NO_DEVICE)');
    });

    test('the WSL usb/ip URB reset (IO) is treated as a recoverable drop', () {
      final f = classifyLinkError('bulkTransferIn error: LIBUSB_ERROR_IO');
      expect(f.kind, LinkFaultKind.disconnected);
      expect(f.recoverable, isTrue);
    });

    test('permission and busy are user-fixable, not recoverable', () {
      final access =
          classifyLinkError('controlTransfer error: LIBUSB_ERROR_ACCESS');
      expect(access.kind, LinkFaultKind.permission);
      expect(access.recoverable, isFalse);

      final busy =
          classifyLinkError('busy: the device is in use by another program');
      expect(busy.kind, LinkFaultKind.busy);
      expect(busy.recoverable, isFalse);
    });

    test('every libusb_error name is mapped (no UNKNOWN fallthrough)', () {
      const names = [
        'LIBUSB_ERROR_IO',
        'LIBUSB_ERROR_INVALID_PARAM',
        'LIBUSB_ERROR_ACCESS',
        'LIBUSB_ERROR_NO_DEVICE',
        'LIBUSB_ERROR_NOT_FOUND',
        'LIBUSB_ERROR_BUSY',
        'LIBUSB_ERROR_TIMEOUT',
        'LIBUSB_ERROR_OVERFLOW',
        'LIBUSB_ERROR_PIPE',
        'LIBUSB_ERROR_INTERRUPTED',
        'LIBUSB_ERROR_NO_MEM',
        'LIBUSB_ERROR_NOT_SUPPORTED',
        'LIBUSB_ERROR_OTHER',
      ];
      for (final n in names) {
        final f = classifyLinkError('bulkTransferIn error: $n');
        expect(f.code, n, reason: '$n should carry its code');
        expect(f.message, isNotEmpty, reason: '$n should have a message');
      }
    });

    test('an unrecognised error degrades to a labelled unknown', () {
      final f = classifyLinkError('something weird happened');
      expect(f.kind, LinkFaultKind.unknown);
      expect(f.message, contains('something weird'));
      expect(f.codeSuffix, isEmpty);
    });
  });
}
